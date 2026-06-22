# claude-config:claude-ultra — `claude` 를 항상 ultracode 로 실행 (bash/zsh).
# 실제 바이너리를 호출(command)해 함수 재귀를 방지하고,
# ultracode.json 이 없으면 평범한 claude 로 폴백한다.
claude() {
  local _s="$HOME/.claude/ultracode.json"
  # github MCP 토큰: 명시적으로 설정돼 있지 않으면 로그인된 gh 에서 런타임으로 가져옴 (레포엔 비밀 미포함)
  if [ -z "${GITHUB_PERSONAL_ACCESS_TOKEN:-}" ] && command -v gh >/dev/null 2>&1; then
    local _gt; _gt="$(gh auth token 2>/dev/null)"
    [ -n "$_gt" ] && export GITHUB_PERSONAL_ACCESS_TOKEN="$_gt"
  fi
  if [ -f "$_s" ]; then
    command claude --settings "$_s" "$@"
  else
    command claude "$@"
  fi
}

# claude-config:newproj — turn the CURRENT folder into a private GitHub repo (cloud backup from day one).
#   Usage:  claude-newproj [repo-name]   (defaults to the folder name)
#   Seeds a secret-safe .gitignore + a .claude-autosync marker so the work-autosync hook auto-pushes thereafter.
claude-newproj() {
  command -v git >/dev/null 2>&1 || { echo "git not found"; return 1; }
  command -v gh  >/dev/null 2>&1 || { echo "gh not found - install gh then run: gh auth login"; return 1; }
  gh auth status >/dev/null 2>&1 || { echo "gh not logged in - run: gh auth login"; return 1; }
  local name; name="$(printf '%s' "${1:-$(basename "$PWD")}" | tr -c 'A-Za-z0-9._-' '-')"   # GitHub-safe name
  [ -d .git ] || git init -q
  # ALWAYS ensure secret-safe ignore patterns (append missing even if a .gitignore already exists)
  touch .gitignore
  local p
  for p in .env '.env.*' .envrc '*.key' '*.pem' '*.p12' '*.pfx' '*.jks' '*.keystore' '*.ppk' '*.p8' id_rsa id_ed25519 id_dsa id_ecdsa .npmrc .netrc .pgpass .pypirc '*service-account*.json' '*credentials*.json' '*token*.json' database.yml '.aws/' '.kube/' '.ssh/' '*.tfstate' '*.tfstate.*' secrets.yml secrets.yaml secrets.json 'node_modules/' '.venv/' '__pycache__/' .DS_Store '.omc/' '*.log' '!.env.example' '!.env.sample' '!.env.template'; do
    grep -qxF "$p" .gitignore 2>/dev/null || printf '%s\n' "$p" >> .gitignore
  done
  [ -f .claude-autosync ] || echo "claude-config work-autosync marker - auto commit+push on session end. Delete to opt out." > .claude-autosync
  git add -A
  # fail-closed: never let secret-looking files into the first commit
  local secret_re='(^|/)\.env($|\.)|\.envrc$|\.(pem|key|p12|pfx|jks|keystore|ppk|p8)$|(^|/)id_(rsa|ed25519|dsa|ecdsa)$|\.(npmrc|netrc|pgpass|pypirc)$|(service[-_]account|credentials).*\.json$|token.*\.json$|(^|/)database\.(ya?ml|json)$|(^|/)\.(aws|kube|ssh)/|\.tfstate$|secrets?\.(ya?ml|json|env)$'
  local secrets; secrets="$(git diff --cached --name-only 2>/dev/null | grep -Ei "$secret_re" | grep -Eiv '\.(example|sample|template|dist)$' || true)"
  if [ -n "$secrets" ]; then
    printf '%s\n' "$secrets" | while IFS= read -r f; do [ -n "$f" ] && git reset -q -- "$f" >/dev/null 2>&1; done
    echo "  ! excluded secret-looking files (not committed/pushed): $(printf '%s ' $secrets)" >&2
  fi
  git diff --cached --quiet || git commit -q -m "initial commit (claude-newproj)"
  if git rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
    git push -q || { echo "push failed - NOT backed up" >&2; return 1; }
  else
    gh repo create "$name" --private --source=. --remote=origin --push || { echo "gh repo create failed - NOT backed up (name conflict? auth?)" >&2; return 1; }
  fi
  echo "  + '$name' pushed to a private GitHub repo. Auto-backup on every session end is now ON."
}

# claude-config:review — enable Claude auto code-review + opt-in auto-fix (GitHub Action) on the CURRENT repo.
#   Reviews EVERY pull request using YOUR Claude subscription via an OAuth token (no API billing).
#   Also installs an opt-in auto-fix workflow: add the 'claude-autofix' label to a PR to have Claude fix it.
#   Usage:  claude-review            enable/refresh on this repo
#           claude-review --status   show current setup state (read-only)
claude-review() {
  command -v git >/dev/null 2>&1 || { echo "git not found"; return 1; }
  command -v gh  >/dev/null 2>&1 || { echo "gh not found - install gh then: gh auth login"; return 1; }
  gh auth status >/dev/null 2>&1 || { echo "gh not logged in - run: gh auth login"; return 1; }
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "not inside a git repo - cd into your project first"; return 1; }
  local slug; slug="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)"
  [ -n "$slug" ] || { echo "no GitHub remote for this repo - create one first (e.g. claude-newproj), then re-run"; return 1; }
  local out=".github/workflows/claude-auto-review.yml"

  if [ "${1:-}" = "--status" ]; then
    echo "claude-review status - $slug"
    [ -f "$out" ] && echo "  [OK]   review workflow present" || echo "  [MISS] review workflow $out"
    [ -f ".github/workflows/claude-autofix.yml" ] && echo "  [OK]   auto-fix workflow present (opt-in)" || echo "  [--]   auto-fix workflow not installed"
    gh secret list 2>/dev/null | grep -q '^CLAUDE_CODE_OAUTH_TOKEN' && echo "  [OK]   secret CLAUDE_CODE_OAUTH_TOKEN set" || echo "  [MISS] secret CLAUDE_CODE_OAUTH_TOKEN"
    gh label list -R "$slug" 2>/dev/null | grep -q 'claude-autofix' && echo "  [OK]   label claude-autofix exists" || echo "  [--]   label claude-autofix missing"
    return 0
  fi

  # 1) write the workflow (prefer the config-repo template; fall back to an embedded copy)
  mkdir -p .github/workflows
  local tmpl="" cfp="$HOME/.claude/.config-sync-path"
  [ -f "$cfp" ] && tmpl="$(cat "$cfp" 2>/dev/null)/claude/github/claude-auto-review.yml"
  if [ -n "$tmpl" ] && [ -f "$tmpl" ]; then
    cp "$tmpl" "$out"
  else
    cat > "$out" <<'YML'
# Claude 자동 코드 리뷰 — 모든 Pull Request 에서 실행. (claude-config / claude-review)
# 인증: Claude 구독 OAuth 토큰을 레포 시크릿 CLAUDE_CODE_OAUTH_TOKEN 으로 저장.
#   발급:  claude setup-token   저장:  gh secret set CLAUDE_CODE_OAUTH_TOKEN  (또는 claude-review)
# 주의: 구독 OAuth 는 anthropic_api_key 가 아니라 claude_code_oauth_token 입력을 써야 함.
name: Claude Auto Review
on:
  pull_request:
    types: [opened, synchronize, reopened]
permissions:
  contents: read
  pull-requests: write
  issues: write
  id-token: write
jobs:
  claude-review:
    runs-on: ubuntu-latest
    if: github.event.pull_request.draft == false && github.actor != 'dependabot[bot]'
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - uses: anthropics/claude-code-action@v1
        with:
          claude_code_oauth_token: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
          track_progress: true
          prompt: |
            REPO: ${{ github.repository }}
            PR NUMBER: ${{ github.event.pull_request.number }}
            이 PR을 코드 리뷰해줘. 정확성 버그·로직 오류·엣지케이스·보안·단순화 위주로.
            구체적 라인은 mcp__github_inline_comment__create_inline_comment (confirmed: true),
            총평은 `gh pr comment` 로 반드시 GitHub 코멘트로 게시. 한국어로, 사소한 건 최소화.
          claude_args: '--allowedTools "mcp__github_inline_comment__create_inline_comment,Bash(gh pr comment:*),Bash(gh pr diff:*),Bash(gh pr view:*)" --max-turns 15 --model claude-sonnet-4-6'
YML
  fi
  echo "  + wrote $out"

  # 1b) also install the opt-in auto-fix workflow (label-triggered) + ensure the label exists
  local afout=".github/workflows/claude-autofix.yml" cfgdir=""
  [ -f "$cfp" ] && cfgdir="$(cat "$cfp" 2>/dev/null)"
  if [ -n "$cfgdir" ] && [ -f "$cfgdir/claude/github/claude-autofix.yml" ]; then
    cp "$cfgdir/claude/github/claude-autofix.yml" "$afout"
    gh label create claude-autofix -R "$slug" --color 1f6feb --description "Claude가 이 PR을 자동 수정" >/dev/null 2>&1 || true
    echo "  + wrote $afout  (opt-in: PR에 'claude-autofix' 라벨을 달면 자동 수정)"
  else
    afout=""
    echo "  i auto-fix 템플릿 못 찾음 (claude-update 후 재시도) - 리뷰만 설치"
  fi

  # 2) ensure the subscription OAuth token secret exists on the repo (never stored in the repo)
  if gh secret list 2>/dev/null | grep -q '^CLAUDE_CODE_OAUTH_TOKEN'; then
    echo "  + secret CLAUDE_CODE_OAUTH_TOKEN already set on $slug"
  else
    echo "  This review runs on YOUR Claude subscription via an OAuth token."
    echo "  In ANOTHER terminal run:  claude setup-token   (1-year token; copy the output)"
    printf "  Paste token here (hidden), or press Enter to skip: "
    local tok; read -rs tok; echo ""
    if [ -n "$tok" ]; then
      printf '%s' "$tok" | gh secret set CLAUDE_CODE_OAUTH_TOKEN >/dev/null 2>&1 \
        && echo "  + secret CLAUDE_CODE_OAUTH_TOKEN set on $slug" \
        || echo "  ! failed - set manually: claude setup-token then  gh secret set CLAUDE_CODE_OAUTH_TOKEN"
    else
      echo "  i skipped - later:  claude setup-token  then  gh secret set CLAUDE_CODE_OAUTH_TOKEN"
    fi
  fi

  # 3) commit + push the workflow(s) (contains no secret)
  git add "$out" ${afout:+"$afout"} 2>/dev/null
  if ! git diff --cached --quiet 2>/dev/null; then
    git commit -q -m "ci: Claude auto-review + opt-in auto-fix (claude-review)" 2>/dev/null
    git push -q 2>/dev/null && echo "  + workflow committed & pushed" || echo "  i committed locally - run 'git push' when ready"
  else
    echo "  i workflow already current"
  fi

  # 4) one-time browser step: install the Claude GitHub App so PRs trigger the action
  echo ""
  echo "  Last step (one-time, browser): install the Claude GitHub App on this repo:"
  echo "     https://github.com/apps/claude      (or run once:  claude /install-github-app)"
  echo "  Done - every PR on $slug then gets an automatic Claude review (uses your subscription)."
  [ -n "$afout" ] && echo "  Auto-fix (opt-in): PR에 'claude-autofix' 라벨을 달면 Claude가 직접 고쳐 커밋합니다."
}

# claude-config:update — pull the latest config repo + re-run the installer (one command).
claude-update() {
  local cf="$HOME/.claude/.config-sync-path" repo
  [ -f "$cf" ] || { echo "config repo path unknown (~/.claude/.config-sync-path) - run install.sh once" >&2; return 1; }
  repo="$(cat "$cf" 2>/dev/null)"
  [ -d "$repo/.git" ] || { echo "config repo not found: $repo" >&2; return 1; }
  echo "  updating $repo ..."
  git -C "$repo" pull --ff-only || git -C "$repo" pull --rebase --autostash || true
  bash "$repo/install.sh"
  echo "  + updated. Open a NEW terminal for shell changes to take effect."
}

# claude-config:doctor — read-only health-check of THIS machine's setup.
claude-doctor() {
  local dst="$HOME/.claude" ok=0 warn=0 fail=0
  _row() {
    local s="$1" m="$2" h="${3:-}"
    printf '  [%-4s] %s\n' "$s" "$m"
    case "$s" in
      OK)   ok=$((ok+1)) ;;
      WARN) warn=$((warn+1)); [ -n "$h" ] && printf '         -> %s\n' "$h" ;;
      *)    fail=$((fail+1)); [ -n "$h" ] && printf '         -> %s\n' "$h" ;;
    esac
  }
  printf '\nclaude-doctor:\n'
  command -v claude >/dev/null 2>&1 && _row OK "claude CLI found" || _row FAIL "claude CLI not found" "npm i -g @anthropic-ai/claude-code"
  if [ -f "$dst/settings.json" ]; then
    if command -v python3 >/dev/null 2>&1; then
      if python3 - "$dst/settings.json" >/dev/null 2>&1 <<'PY'
import json,sys; json.load(open(sys.argv[1]))
PY
      then _row OK "settings.json valid JSON"; else _row FAIL "settings.json invalid" "claude-update"; fi
    else _row OK "settings.json present"; fi
  else _row FAIL "settings.json missing" "run install.sh"; fi
  for h in ensure-harness.sh effort-reminder.sh config-sync.sh work-autosync.sh; do
    [ -e "$dst/hooks/$h" ] && _row OK "hook: $h" || _row WARN "hook missing: $h" "claude-update"
  done
  if command -v gh >/dev/null 2>&1; then gh auth status >/dev/null 2>&1 && _row OK "gh authenticated" || _row WARN "gh not authenticated" "gh auth login (github MCP token)"; else _row WARN "gh not installed" "brew/apt install gh"; fi
  command -v python3 >/dev/null 2>&1 && _row OK "python3 available (hookify)" || _row WARN "python3 missing" "install python3"
  [ -e "$dst/ultracode.json" ] && _row OK "ultracode.json present" || _row WARN "ultracode.json missing" "claude-update"
  git config --global --get core.excludesfile >/dev/null 2>&1 && _row OK "git core.excludesfile set (global gitignore)" || _row WARN "global gitignore not set" "claude-update"
  local cf="$dst/.config-sync-path"
  if [ -f "$cf" ]; then local r; r="$(cat "$cf")"; [ -d "$r/.git" ] && _row OK "config repo: $r" || _row WARN "config repo missing: $r"; else _row WARN ".config-sync-path missing"; fi
  printf '\n  %d OK / %d WARN / %d FAIL\n\n' "$ok" "$warn" "$fail"
}

# claude-config:status — read-only growth dashboard (lifelong-memory snapshot).
claude-status() {
  local py="$HOME/.claude/lib/dashboard.py"
  [ -f "$py" ] || { echo "dashboard not installed - run claude-update"; return 1; }
  command -v python3 >/dev/null 2>&1 || { echo "python3 not found"; return 1; }
  local mem="${CLAUDE_MEMORY_DIR:-}"
  if [ -z "$mem" ] && [ -f "$HOME/.claude/lib/memdir.sh" ]; then
    eval "$(bash "$HOME/.claude/lib/memdir.sh" --no-ensure --export 2>/dev/null || true)"; mem="${CLAUDE_MEMORY_DIR:-}"
  fi
  [ -n "$mem" ] && command -v cygpath >/dev/null 2>&1 && mem="$(cygpath -u "$mem" 2>/dev/null || printf '%s' "$mem")"
  python3 "$py" "$mem"
}

# claude-config:rate — record a 1-5 quality rating of the current output (feeds the objective fn).
claude-rate() {
  case "${1:-}" in 1|2|3|4|5) ;; *) echo "usage: claude-rate <1-5>  (현재 산출물 품질 평가 -> metrics)"; return 1 ;; esac
  local lib="$HOME/.claude/lib/events.sh"
  [ -f "$lib" ] || { echo "events lib not installed - run claude-update"; return 1; }
  bash "$lib" --type task --set "user_rating=$1" && echo "  + rated $1/5 (metrics 의 user_rating_avg 에 반영)"
}

# claude-config:help — cheatsheet of commands, modes, and kill-switches.
claude-help() {
  cat <<'EOF'

claude-config — commands & modes
  claude            launch Claude Code in ultracode (auto via this wrapper)
  claude-newproj    current folder -> private GitHub repo + opt-in auto-backup
  claude-review     enable Claude auto code-review (GitHub Action) on the current repo
  claude-update     pull latest config + re-run installer
  claude-doctor     health-check this machine's setup
  claude-status     growth dashboard (memory/decisions/pending/metrics snapshot)
  claude-rate <1-5> rate current output quality (feeds growth metrics)
  claude-help       this cheatsheet

  work-autosync (opt-in project backup): add a .claude-autosync marker at the repo root.
    off (project): delete .claude-autosync   |   off (global): CLAUDE_AUTOSYNC_OFF=1
  config auto-sync: SessionStart=pull / SessionEnd=push.  off: CLAUDE_CONFIG_NO_SYNC=1

OMC modes (you run the slash command; Claude suggests them proactively):
  /deep-interview  crystallize vague requirements
  /ralph           persist until done + reviewer-verified
  /autopilot       idea -> code pipeline     /ultrawork  parallel throughput

EOF
}
