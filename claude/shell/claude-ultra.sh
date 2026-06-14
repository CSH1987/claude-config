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

# claude-config:help — cheatsheet of commands, modes, and kill-switches.
claude-help() {
  cat <<'EOF'

claude-config — commands & modes
  claude            launch Claude Code in ultracode (auto via this wrapper)
  claude-newproj    current folder -> private GitHub repo + opt-in auto-backup
  claude-update     pull latest config + re-run installer
  claude-doctor     health-check this machine's setup
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
