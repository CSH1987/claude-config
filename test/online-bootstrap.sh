#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RG_BIN="$(command -v rg)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/online-bootstrap-test.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

TEST_HOME="$TEST_ROOT/home"
BIN_DIR="$TEST_ROOT/bin"
REMOTE_DIR="$TEST_ROOT/vault-backup.git"
SEED_DIR="$TEST_ROOT/seed"
mkdir -p "$TEST_HOME" "$BIN_DIR" "$SEED_DIR"

git init -q --bare "$REMOTE_DIR"
git -C "$SEED_DIR" init -q
git -C "$SEED_DIR" config user.name test-user
git -C "$SEED_DIR" config user.email test@example.invalid
printf '# 에버스 위키 홈\n' > "$SEED_DIR/00_홈.md"
mkdir -p "$SEED_DIR/10_컨텍스트" "$SEED_DIR/.obsidian/plugins/obsidian-git"
printf '# test context\n' > "$SEED_DIR/10_컨텍스트/test.md"
printf '["obsidian-git","obsidian-local-rest-api"]\n' > "$SEED_DIR/.obsidian/community-plugins.json"
printf '{}\n' > "$SEED_DIR/.obsidian/plugins/obsidian-git/data.json"
printf '{"id":"obsidian-git"}\n' > "$SEED_DIR/.obsidian/plugins/obsidian-git/manifest.json"
mkdir -p "$SEED_DIR/.obsidian/plugins/obsidian-local-rest-api"
printf '{"id":"obsidian-local-rest-api"}\n' > "$SEED_DIR/.obsidian/plugins/obsidian-local-rest-api/manifest.json"
git -C "$SEED_DIR" add .
git -C "$SEED_DIR" commit -qm seed
git -C "$SEED_DIR" branch -M main
git -C "$SEED_DIR" remote add origin "$REMOTE_DIR"
git -C "$SEED_DIR" push -q -u origin main
git --git-dir="$REMOTE_DIR" symbolic-ref HEAD refs/heads/main

cat > "$BIN_DIR/gh" <<'EOF'
#!/usr/bin/env bash
set -eu
case "${1:-} ${2:-}" in
  "auth status"|"auth setup-git") exit 0 ;;
  "api user")
    case "$*" in
      *".login"*) printf 'test-user\n' ;;
      *".id"*) printf '12345\n' ;;
      *) exit 1 ;;
    esac ;;
  "repo view")
    case "$*" in
      *viewerPermission*nameWithOwner*) printf 'test-user/vault-backup|%s|%s\n' "${TEST_VAULT_VISIBILITY:-PRIVATE}" "${TEST_REPO_PERMISSION:-ADMIN}" ;;
      *viewerPermission*) printf '%s\n' "${TEST_REPO_PERMISSION:-ADMIN}" ;;
      *) exit 1 ;;
    esac ;;
  "repo clone") /usr/bin/git clone -q "$TEST_VAULT_REMOTE" "$4" ;;
  *) printf 'unexpected gh call: %s\n' "$*" >&2; exit 1 ;;
esac
EOF

cat > "$BIN_DIR/codex" <<'EOF'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "login status") exit 0 ;;
  "--version ") printf 'codex-test\n'; exit 0 ;;
esac
exit 0
EOF

cat > "$BIN_DIR/claude" <<'EOF'
#!/usr/bin/env bash
[ "${1:-} ${2:-}" = "auth status" ] && exit 0
exit 0
EOF

cat > "$BIN_DIR/hermes" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = "status" ] && {
  if [ "${TEST_HERMES_AUTH_READY:-1}" = "1" ]; then
    printf '  Model: test-model\n  Provider: Test Provider\n\n◆ Auth Providers\n  Test Provider  ✓ logged in\n'
  else
    printf '  Model: test-model\n  Provider: Test Provider\n\n◆ Auth Providers\n  Test Provider  ✗ not logged in\n\n◆ Messaging Platforms\n  Telegram  ✓ configured\n'
  fi
  exit 0
}
[ "${1:-}" = "doctor" ] && {
  printf '  ✓ API key or custom endpoint configured\n'
  exit 0
}
[ "${1:-}" = "--version" ] && printf 'hermes-test\n'
exit 0
EOF
chmod +x "$BIN_DIR/gh" "$BIN_DIR/codex" "$BIN_DIR/claude" "$BIN_DIR/hermes"

# 현재 개발 작업트리가 아직 push 전이어도 production 로직의 config 0/0 분기를
# 격리 테스트할 수 있게, 정확히 이 소스 repo의 최종 상태 조회만 고정한다.
cat > "$BIN_DIR/git" <<'EOF'
#!/usr/bin/env bash
set -eu
if [ "${1:-}" = "-C" ] && [ "${2:-}" = "${TEST_CONFIG_DIR:-}" ]; then
  case "${3:-} ${4:-}" in
    "rev-list --left-right") printf '0\t0\n'; exit 0 ;;
    "status --porcelain") exit 0 ;;
  esac
fi
exec /usr/bin/git "$@"
EOF
chmod +x "$BIN_DIR/git"

mkdir -p "$TEST_HOME/.codex" "$TEST_HOME/.hermes" "$TEST_HOME/.claude/skills/playbooks" \
  "$TEST_HOME/.claude/agents" "$TEST_HOME/.claude/exports" "$TEST_HOME/Applications/Obsidian.app"
printf 'model: test\n' > "$TEST_HOME/.hermes/config.yaml"
printf 'SECRET_KEY=keep-me\nOBSIDIAN_VAULT_PATH="/old/path"\nOBSIDIAN_VAULT_PATH="/duplicate"\n' > "$TEST_HOME/.hermes/.env"
printf 'keep skill\n' > "$TEST_HOME/.claude/skills/playbooks/user-file.txt"
printf 'keep agent\n' > "$TEST_HOME/.claude/agents/hermes-liaison.md"
printf 'keep exports\n' > "$TEST_HOME/.claude/exports/user-file.txt"

export HOME="$TEST_HOME"
export PATH="$BIN_DIR:/usr/bin:/bin:/usr/sbin:/sbin"
export TEST_VAULT_REMOTE="$REMOTE_DIR"
export TEST_CONFIG_DIR="$REPO_DIR"
export CLAUDE_CONFIG_DIR="$REPO_DIR"
export ONLINE_BOOTSTRAP_SKIP_BASE=1
export ONLINE_BOOTSTRAP_NONINTERACTIVE=1
export ONLINE_BOOTSTRAP_OS_OVERRIDE=Darwin
export OBSIDIAN_APP_PATH_OVERRIDE="$TEST_HOME/Applications/Obsidian.app"

VAULT_PATH="$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$TEST_HOME/Documents/Vault")"
SENTINEL_HASH="$(git --git-dir="$REMOTE_DIR" show main:00_홈.md | shasum -a 256 | awk '{print $1}')"

# 실제 base install의 deploy-only 경로와 통합해, Codex 홈 override까지
# 새 HOME에 배포되는지 먼저 확인한다.
CLAUDE_INSTALL_DEPLOY_ONLY=1 bash "$REPO_DIR/install.sh"
[ -L "$TEST_HOME/AGENTS.override.md" ]
[ "$(readlink "$TEST_HOME/AGENTS.override.md")" = "$REPO_DIR/codex/home-AGENTS.override.md" ]
[ -L "$TEST_HOME/.codex/hooks/session-context.sh" ]
[ -L "$TEST_HOME/.codex/hooks/session-end.sh" ]
[ -L "$TEST_HOME/.codex/skills/workload-optimization" ]
[ -f "$TEST_HOME/.codex/hooks.json" ]
[ -L "$TEST_HOME/.claude/skills/playbooks" ]
[ -L "$TEST_HOME/.claude/agents/hermes-liaison.md" ]
[ -L "$TEST_HOME/.claude/exports" ]
[ "$(find "$TEST_HOME/.claude/skills" -maxdepth 2 -path '*.pre-claude-config.*/user-file.txt' -print -quit | wc -l | tr -d ' ')" = "1" ]
[ "$(find "$TEST_HOME/.claude/agents" -maxdepth 1 -name 'hermes-liaison.md.pre-claude-config.*' -type f -print -quit | wc -l | tr -d ' ')" = "1" ]
[ "$(find "$TEST_HOME/.claude" -maxdepth 2 -path '*/exports.pre-claude-config.*/user-file.txt' -print -quit | wc -l | tr -d ' ')" = "1" ]

bash "$REPO_DIR/online-bootstrap.sh" --with-hermes --skip-install --no-open
bash "$REPO_DIR/online-bootstrap.sh" --with-hermes --skip-install --no-open

[ -d "$VAULT_PATH/.git" ]
[ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["vaultPath"])' "$TEST_HOME/.claude/vault-scope.json")" = "$VAULT_PATH" ]
[ "$(grep -c '^OBSIDIAN_VAULT_PATH=' "$TEST_HOME/.hermes/.env")" = "1" ]
grep -q '^SECRET_KEY=keep-me$' "$TEST_HOME/.hermes/.env"
[ "$(grep -cF '<!-- claude-config:portable-rules:start -->' "$TEST_HOME/.codex/AGENTS.md")" = "1" ]
[ "$(grep -cF '<!-- claude-config:portable-rules:start -->' "$TEST_HOME/.hermes/AGENTS.md")" = "1" ]
[ "$(grep -cF '<!-- claude-config:codex-vault-rules:start -->' "$TEST_HOME/.codex/AGENTS.md")" = "1" ]
[ "$(grep -cF '<!-- claude-config:hermes-vault-rules:start -->' "$TEST_HOME/.hermes/AGENTS.md")" = "1" ]
[ "$(grep -cF '<!-- claude-config:vault-context:start -->' "$TEST_HOME/.codex/AGENTS.md")" = "1" ]
[ "$(grep -cF '<!-- claude-config:vault-context:start -->' "$TEST_HOME/.hermes/AGENTS.md")" = "1" ]
[ "$(grep -cF '<!-- claude-config:vault-catalog:start -->' "$TEST_HOME/.codex/AGENTS.md")" = "1" ]
[ "$(grep -cF '<!-- claude-config:vault-catalog:start -->' "$TEST_HOME/.hermes/AGENTS.md")" = "1" ]
grep -q '^hooks = true$' "$TEST_HOME/.codex/config.toml"
grep -q '^memories = true$' "$TEST_HOME/.codex/config.toml"
grep -q '^generate = true$' "$TEST_HOME/.codex/config.toml"
python3 - "$TEST_HOME/.codex/hooks.json" "$TEST_HOME/.claude/vault-state/full-vault-index.json" <<'PY'
import json, sys
hooks=json.load(open(sys.argv[1]))['hooks']
commands=[h['command'] for groups in hooks.values() for group in groups for h in group['hooks']]
assert commands.count('bash "$HOME/.codex/hooks/session-context.sh"') == 1
assert commands.count('bash "$HOME/.codex/hooks/session-end.sh"') == 1
catalog=json.load(open(sys.argv[2]))
assert catalog['version'] == 1
assert catalog['counts']['semanticDocuments'] > 0
PY
extract_managed_block() {
  awk -v start="$2" -v end="$3" '
    $0 == start { capture=1; next }
    $0 == end   { capture=0; exit }
    capture == 1 { print }
  ' "$1"
}
extract_managed_block "$TEST_HOME/.codex/AGENTS.md" \
  '<!-- claude-config:portable-rules:start -->' \
  '<!-- claude-config:portable-rules:end -->' > "$TEST_ROOT/codex-portable.md"
extract_managed_block "$TEST_HOME/.hermes/AGENTS.md" \
  '<!-- claude-config:portable-rules:start -->' \
  '<!-- claude-config:portable-rules:end -->' > "$TEST_ROOT/hermes-portable.md"
cmp -s "$REPO_DIR/claude/exports/portable-rules.md" "$TEST_ROOT/codex-portable.md"
cmp -s "$REPO_DIR/claude/exports/portable-rules.md" "$TEST_ROOT/hermes-portable.md"
[ "$(shasum -a 256 "$VAULT_PATH/00_홈.md" | awk '{print $1}')" = "$SENTINEL_HASH" ]
[ "$(git -C "$VAULT_PATH" rev-list --left-right --count '@{upstream}...HEAD')" = $'0\t0' ]

# PRIVATE가 아닌 저장소는 clone 전에 fail-closed여야 한다.
if TEST_VAULT_VISIBILITY=PUBLIC bash "$REPO_DIR/online-bootstrap.sh" \
  --without-hermes --skip-install --no-open --vault-path "$TEST_HOME/Documents/PublicVault" \
  >/dev/null 2>&1; then
  echo 'public Vault repository was not rejected' >&2
  exit 1
fi
[ ! -e "$TEST_HOME/Documents/PublicVault" ]

# 읽기 전용 권한도 clone 전에 fail-closed여야 한다.
if TEST_REPO_PERMISSION=READ bash "$REPO_DIR/online-bootstrap.sh" \
  --without-hermes --skip-install --no-open --vault-path "$TEST_HOME/Documents/ReadOnlyVault" \
  >/dev/null 2>&1; then
  echo 'read-only Vault repository was not rejected' >&2
  exit 1
fi
[ ! -e "$TEST_HOME/Documents/ReadOnlyVault" ]

# Telegram 같은 별도 연동만 준비되고 선택 모델 provider가 미인증이면 완료로 오인하면 안 된다.
if TEST_HERMES_AUTH_READY=0 bash "$REPO_DIR/online-bootstrap.sh" \
  --with-hermes --skip-install --no-open >/dev/null 2>&1; then
  echo 'Hermes with an unauthenticated model provider was accepted' >&2
  exit 1
fi

if "$RG_BIN" -n '/Users/[A-Za-z0-9._-]+/|gh[pousr]_[A-Za-z0-9]|sk-[A-Za-z0-9]' \
  "$REPO_DIR/online-bootstrap.sh" "$REPO_DIR/test/online-bootstrap.sh" \
  "$REPO_DIR/README.md" "$REPO_DIR/RECOVERY.md"; then
  echo 'public bootstrap contains a forbidden local path or secret-like value' >&2
  exit 1
fi

echo 'PASS: base+online clone/config/sync/idempotency/private-gate/override/sentinel preservation'
