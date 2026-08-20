#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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
printf '[]\n' > "$SEED_DIR/.obsidian/community-plugins.json"
printf '{}\n' > "$SEED_DIR/.obsidian/plugins/obsidian-git/data.json"
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
  "repo view") printf 'test-user/vault-backup|PRIVATE\n' ;;
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
[ "${1:-}" = "--version" ] && printf 'hermes-test\n'
exit 0
EOF
chmod +x "$BIN_DIR/gh" "$BIN_DIR/codex" "$BIN_DIR/claude" "$BIN_DIR/hermes"

mkdir -p "$TEST_HOME/.codex" "$TEST_HOME/.hermes" "$TEST_HOME/Applications/Obsidian.app"
printf 'model: test\n' > "$TEST_HOME/.hermes/config.yaml"
printf 'SECRET_KEY=keep-me\nOBSIDIAN_VAULT_PATH="/old/path"\nOBSIDIAN_VAULT_PATH="/duplicate"\n' > "$TEST_HOME/.hermes/.env"

export HOME="$TEST_HOME"
export PATH="$BIN_DIR:/usr/bin:/bin:/usr/sbin:/sbin"
export TEST_VAULT_REMOTE="$REMOTE_DIR"
export CLAUDE_CONFIG_DIR="$REPO_DIR"
export ONLINE_BOOTSTRAP_SKIP_BASE=1
export ONLINE_BOOTSTRAP_NONINTERACTIVE=1
export ONLINE_BOOTSTRAP_OS_OVERRIDE=Darwin
export OBSIDIAN_APP_PATH_OVERRIDE="$TEST_HOME/Applications/Obsidian.app"

VAULT_PATH="$TEST_HOME/Documents/Vault"
SENTINEL_HASH="$(git --git-dir="$REMOTE_DIR" show main:00_홈.md | shasum -a 256 | awk '{print $1}')"

bash "$REPO_DIR/online-bootstrap.sh" --with-hermes --skip-install --no-open
bash "$REPO_DIR/online-bootstrap.sh" --with-hermes --skip-install --no-open

[ -d "$VAULT_PATH/.git" ]
[ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["vaultPath"])' "$TEST_HOME/.claude/vault-scope.json")" = "$VAULT_PATH" ]
[ "$(grep -c '^OBSIDIAN_VAULT_PATH=' "$TEST_HOME/.hermes/.env")" = "1" ]
grep -q '^SECRET_KEY=keep-me$' "$TEST_HOME/.hermes/.env"
[ "$(grep -cF '<!-- claude-config:portable-rules:start -->' "$TEST_HOME/.codex/AGENTS.md")" = "1" ]
[ "$(grep -cF '<!-- claude-config:portable-rules:start -->' "$TEST_HOME/.hermes/AGENTS.md")" = "1" ]
[ "$(shasum -a 256 "$VAULT_PATH/00_홈.md" | awk '{print $1}')" = "$SENTINEL_HASH" ]
[ "$(git -C "$VAULT_PATH" rev-list --left-right --count '@{upstream}...HEAD')" = $'0\t0' ]

if rg -n '/Users/evershongdae1|gh[pousr]_[A-Za-z0-9]|sk-[A-Za-z0-9]' \
  "$REPO_DIR/online-bootstrap.sh" "$REPO_DIR/test/online-bootstrap.sh"; then
  echo 'public bootstrap contains a forbidden local path or secret-like value' >&2
  exit 1
fi

echo 'PASS: online-bootstrap clone/config/sync/idempotency/sentinel preservation'
