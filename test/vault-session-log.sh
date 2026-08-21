#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/vault-session-log-test.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT
TEST_HOME="$TEST_ROOT/local-account"
VAULT="$TEST_HOME/Documents/Vault"
FAKE_BIN="$TEST_ROOT/bin"
mkdir -p "$TEST_HOME/.claude" "$VAULT/90_Hermes/로그" "$FAKE_BIN"
printf '# 에버스 위키 홈\n' > "$VAULT/00_홈.md"
printf '{"vaultPath":"%s","projects":[]}\n' "$VAULT" > "$TEST_HOME/.claude/vault-scope.json"
cat > "$FAKE_BIN/hostname" <<'EOF'
#!/bin/sh
printf '%s\n' 'fixture-macmini'
EOF
chmod +x "$FAKE_BIN/hostname"

PAYLOAD=$(jq -cn \
  --arg id '123e4567-e89b-12d3-a456-426614174000' \
  --arg cwd "$TEST_HOME" \
  --arg transcript "$TEST_HOME/.claude/projects/-Users-local-account/123e4567-e89b-12d3-a456-426614174000.jsonl" \
  '{session_id:$id,cwd:$cwd,transcript_path:$transcript,reason:"other"}')
printf '%s\n' "$PAYLOAD" | HOME="$TEST_HOME" PATH="$FAKE_BIN:/usr/bin:/bin" \
  bash "$REPO_DIR/claude/hooks/vault-session-log.sh" codex

LOG_FILE=$(find "$VAULT/90_Hermes/로그" -maxdepth 1 -name 'session-codex-*.md' -type f -print -quit)
[ -n "$LOG_FILE" ]
grep -q 'title: 세션 로그 .* (codex)' "$LOG_FILE"
grep -q -- '- 작업 위치: 홈' "$LOG_FILE"
grep -q '~/.codex/sessions/YYYY/MM/DD/\*.jsonl' "$LOG_FILE"
! grep -q 'local-account\|123e4567-e89b-12d3-a456-426614174000\|/Users/\|session_id' "$LOG_FILE"

# 같은 세션을 다시 종료해도 로컬 전용 해시 상태가 중복 Vault 로그를 막는다.
LOG_COUNT_BEFORE=$(find "$VAULT/90_Hermes/로그" -maxdepth 1 -type f -name 'session-*.md' | wc -l | tr -d ' ')
printf '%s\n' "$PAYLOAD" | HOME="$TEST_HOME" PATH="$FAKE_BIN:/usr/bin:/bin" \
  bash "$REPO_DIR/claude/hooks/vault-session-log.sh" codex
LOG_COUNT_DUPLICATE=$(find "$VAULT/90_Hermes/로그" -maxdepth 1 -type f -name 'session-*.md' | wc -l | tr -d ' ')
[ "$LOG_COUNT_BEFORE" = "$LOG_COUNT_DUPLICATE" ]

# 같은 초에 서로 다른 세션이 끝나도 무작위 nonce 파일명으로 둘 다 보존한다. 자유형
# reason과 프로젝트 경로는 allowlist/범주화돼 본문에 복사되지 않는다.
PAYLOAD_2=$(jq -cn \
  --arg id '223e4567-e89b-12d3-a456-426614174001' \
  --arg cwd "$TEST_HOME/private-project" \
  '{session_id:$id,cwd:$cwd,reason:"project-secret-reason"}')
printf '%s\n' "$PAYLOAD_2" | HOME="$TEST_HOME" PATH="$FAKE_BIN:/usr/bin:/bin" \
  bash "$REPO_DIR/claude/hooks/vault-session-log.sh" codex
LOG_COUNT_DISTINCT=$(find "$VAULT/90_Hermes/로그" -maxdepth 1 -type f -name 'session-*.md' | wc -l | tr -d ' ')
[ "$LOG_COUNT_DISTINCT" -eq $((LOG_COUNT_BEFORE + 1)) ]
LOG_FILE_2=$(find "$VAULT/90_Hermes/로그" -maxdepth 1 -type f -name 'session-codex-*.md' ! -path "$LOG_FILE" -print -quit)
grep -q -- '- 작업 위치: 홈 내부 작업공간' "$LOG_FILE_2"
grep -q -- '- 종료 사유: other' "$LOG_FILE_2"
! grep -q 'private-project\|project-secret-reason\|223e4567-e89b-12d3-a456-426614174001' "$LOG_FILE_2"

printf '%s\n' "$PAYLOAD" | HOME="$TEST_HOME" PATH="$FAKE_BIN:/usr/bin:/bin" \
  CLAUDE_VAULT_SESSION_LOG_OFF=1 bash "$REPO_DIR/claude/hooks/vault-session-log.sh" codex
LOG_COUNT_AFTER=$(find "$VAULT/90_Hermes/로그" -maxdepth 1 -type f -name 'session-*.md' | wc -l | tr -d ' ')
[ "$LOG_COUNT_DISTINCT" = "$LOG_COUNT_AFTER" ]

echo 'PASS: SessionEnd breadcrumb redacts identifiers, deduplicates a session, and preserves concurrent sessions'
