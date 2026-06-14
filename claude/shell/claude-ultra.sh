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
