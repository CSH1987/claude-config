#!/usr/bin/env bash
# Claude Code + Hermes + Codex 사용자 발화와 Vault 전체 변경 문서를 증분 수집한다.
# 커서와 Vault 분석 상태는 워크플로 성공 뒤 commit-cursor.sh가 한 번에 확정한다.
set -uo pipefail

DIR="$HOME/.claude/learning-pipeline"
CURSOR_FILE="$DIR/cursor.json"
OUT="$DIR/gathered-utterances.json"
VAULT_OUT="$DIR/gathered-vault-documents.json"
PENDING_CURSOR="$DIR/pending-cursor.json"
VAULT_STATE="$DIR/vault-state.json"
PENDING_VAULT_STATE="$DIR/pending-vault-state.json"
DEFAULT_LOOKBACK="7 days ago"

mkdir -p "$DIR"
chmod 700 "$DIR" 2>/dev/null || true

DEFAULT_CURSOR=$(date -u -v-7d +"%Y-%m-%dT%H:%M:%S.000Z" 2>/dev/null || date -u -d "$DEFAULT_LOOKBACK" +"%Y-%m-%dT%H:%M:%S.000Z")
LEGACY_CURSOR=""
[ -f "$CURSOR_FILE" ] && LEGACY_CURSOR=$(jq -r '.lastProcessed // empty' "$CURSOR_FILE" 2>/dev/null || true)

source_cursor() {
  local source_name="$1" fallback="$2"
  if [ -f "$CURSOR_FILE" ]; then
    jq -r --arg source "$source_name" --arg fallback "$fallback" \
      '.sources[$source] // $fallback' "$CURSOR_FILE" 2>/dev/null || printf '%s\n' "$fallback"
  else
    printf '%s\n' "$fallback"
  fi
}

# 기존 두 소스는 v1 커서를 이어받는다. 새로 추가된 Codex는 첫 실행에 최근 7일을 되짚는다.
BASE_CURSOR="${LEGACY_CURSOR:-$DEFAULT_CURSOR}"
CC_CURSOR="$(source_cursor claude-code "$BASE_CURSOR")"
HERMES_CURSOR="$(source_cursor hermes "$BASE_CURSOR")"
CODEX_CURSOR="$(source_cursor codex "$DEFAULT_CURSOR")"
echo "소스별 커서 이후분 수집 시작(값은 로컬 상태 파일에만 보관)" >&2

# --- Claude Code: 사람이 입력한 root 대화만 ---
CC_DIR="$HOME/.claude/projects"
CC="[]"
if [ -d "$CC_DIR" ]; then
  CC=$(jq -c -s --arg cursor "$CC_CURSOR" '
    [.[] | select(.type=="user" and .origin.kind=="human" and .isSidechain==false
      and (.timestamp > $cursor) and (.message.content|type=="string"))
     | {source: "claude-code", session: .sessionId, ts: .timestamp, text: .message.content}]
  ' "$CC_DIR"/*/*.jsonl 2>/dev/null)
  [ -z "$CC" ] && CC="[]"
fi

# --- Hermes: export 후 메시지 시각으로 필터 ---
HERMES_RAW="$DIR/.hermes-raw-export.jsonl.tmp"
HERMES="[]"
HERMES_BIN=""
command -v hermes >/dev/null 2>&1 && HERMES_BIN="$(command -v hermes)"
[ -z "$HERMES_BIN" ] && [ -x "$HOME/.local/bin/hermes" ] && HERMES_BIN="$HOME/.local/bin/hermes"
if [ -n "$HERMES_BIN" ]; then
  if "$HERMES_BIN" sessions export --format jsonl --only user-prompts --yes "$HERMES_RAW" >/dev/null 2>&1; then
    HERMES=$(jq -c -s --arg cursor "$HERMES_CURSOR" '
      [.[] | select((.created_at > $cursor) and (.text | startswith("[") | not))
       | {source: "hermes", session: .session_id, ts: .created_at, text: .text}]
    ' "$HERMES_RAW" 2>/dev/null)
    [ -z "$HERMES" ] && HERMES="[]"
  fi
  rm -f "$HERMES_RAW"
fi

# --- Codex: root rollout의 role=user/input_text만 ---
CODEX_FILE="$DIR/.codex-user-prompts.json.tmp"
CODEX="[]"
COLLECTOR="$DIR/collect-codex-user-prompts.py"
if [ -f "$COLLECTOR" ] && [ -d "$HOME/.codex/sessions" ]; then
  python3 "$COLLECTOR" \
    --sessions-root "$HOME/.codex/sessions" \
    --cursor "$CODEX_CURSOR" \
    --output "$CODEX_FILE" 2>/dev/null || true
  [ -f "$CODEX_FILE" ] && CODEX=$(jq -c '.' "$CODEX_FILE" 2>/dev/null || echo '[]')
fi
rm -f "$CODEX_FILE"

jq -c -n --argjson cc "$CC" --argjson hermes "$HERMES" --argjson codex "$CODEX" \
  '$cc + $hermes + $codex | unique_by([.source,.session,.ts,.text]) | sort_by(.ts)' > "$OUT"
chmod 600 "$OUT" 2>/dev/null || true

# --- Vault: `.git`을 제외한 모든 파일을 목록화하고, 변경된 서술형 문서는 본문까지 수집 ---
CATALOGER="$DIR/vault-catalog.py"
SCOPE_FILE="$HOME/.claude/vault-scope.json"
VAULT_PATH=""
[ -f "$SCOPE_FILE" ] && VAULT_PATH=$(jq -r '.vaultPath // empty' "$SCOPE_FILE" 2>/dev/null || true)
if [ -f "$CATALOGER" ] && [ -d "$VAULT_PATH" ]; then
  python3 "$CATALOGER" "$VAULT_PATH" \
    --state "$VAULT_STATE" \
    --pending-state "$PENDING_VAULT_STATE" \
    --documents-out "$VAULT_OUT" \
    --catalog-out "$HOME/.claude/vault-state/full-vault-index.json" 2>/dev/null || true
fi
if [ ! -f "$VAULT_OUT" ]; then
  printf '{"version":1,"initialFullScan":false,"inventory":{},"vaultFingerprint":"","metadataOnlyChanges":0,"changes":[]}\n' > "$VAULT_OUT"
fi
chmod 600 "$VAULT_OUT" "$PENDING_VAULT_STATE" 2>/dev/null || true

max_ts() {
  local json="$1" fallback="$2"
  printf '%s\n' "$json" | jq -r --arg fallback "$fallback" 'if length > 0 then ([.[].ts] | max) else $fallback end'
}
NEW_CC_CURSOR="$(max_ts "$CC" "$CC_CURSOR")"
NEW_HERMES_CURSOR="$(max_ts "$HERMES" "$HERMES_CURSOR")"
NEW_CODEX_CURSOR="$(max_ts "$CODEX" "$CODEX_CURSOR")"
jq -n \
  --arg cc "$NEW_CC_CURSOR" \
  --arg hermes "$NEW_HERMES_CURSOR" \
  --arg codex "$NEW_CODEX_CURSOR" \
  '{version:2, lastProcessed: ([$cc,$hermes,$codex] | max), sources:{"claude-code":$cc,hermes:$hermes,codex:$codex}, committedAt:null}' \
  > "$PENDING_CURSOR"
chmod 600 "$PENDING_CURSOR" 2>/dev/null || true

COUNT=$(jq 'length' "$OUT")
CC_COUNT=$(printf '%s\n' "$CC" | jq 'length')
HERMES_COUNT=$(printf '%s\n' "$HERMES" | jq 'length')
CODEX_COUNT=$(printf '%s\n' "$CODEX" | jq 'length')
VAULT_COUNT=$(jq '.changes | length' "$VAULT_OUT" 2>/dev/null || echo 0)
echo "수집 완료 — 대화 ${COUNT}건(Claude ${CC_COUNT} + Hermes ${HERMES_COUNT} + Codex ${CODEX_COUNT}), Vault 변경 문서 ${VAULT_COUNT}건" >&2
