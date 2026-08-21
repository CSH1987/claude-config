#!/usr/bin/env bash
# Claude Code + Hermes + Codex 사용자 발화와 Vault 전체 변경 문서를 증분 수집한다.
# 커서와 Vault 분석 상태는 워크플로 성공 뒤 commit-cursor.sh가 한 번에 확정한다.
set -euo pipefail

DIR="$HOME/.claude/learning-pipeline"
CURSOR_FILE="$DIR/cursor.json"
OUT="$DIR/gathered-utterances.json"
VAULT_OUT="$DIR/gathered-vault-documents.json"
PENDING_CURSOR="$DIR/pending-cursor.json"
VAULT_STATE="$DIR/vault-state.json"
PENDING_VAULT_STATE="$DIR/pending-vault-state.json"
DEFAULT_LOOKBACK="7 days ago"
CC_FILE="$DIR/.claude-user-prompts.json.tmp"
CC_PATHS_FILE="$DIR/.claude-session-paths.tmp"
CC_LINKS_FILE="$DIR/.claude-session-links.tmp"
HERMES_RAW="$DIR/.hermes-raw-export.jsonl.tmp"
HERMES_FILE="$DIR/.hermes-user-prompts.json.tmp"
CODEX_FILE="$DIR/.codex-user-prompts.json.tmp"
OUT_TMP="$DIR/.gathered-utterances.json.tmp.$$"
SOURCE_STATUS="$DIR/gather-source-status.json"
SOURCE_STATUS_TMP="$DIR/.gather-source-status.json.tmp.$$"
FINALIZER="$DIR/finalize-gathered-prompts.py"
GATHER_SUCCEEDED=0
CC_STATUS="unavailable"
HERMES_STATUS="unavailable"
CODEX_STATUS="unavailable"
SOURCE_ERROR_COUNT=0
OVERLAP_HOURS=24

cleanup() {
  rm -f "$CC_FILE" "$CC_PATHS_FILE" "$CC_LINKS_FILE" "$HERMES_RAW" "$HERMES_FILE" \
    "$CODEX_FILE" "$OUT_TMP" "$SOURCE_STATUS_TMP"
  if [ "$GATHER_SUCCEEDED" -ne 1 ]; then
    rm -f "$OUT" "$VAULT_OUT" "$PENDING_CURSOR" "$PENDING_VAULT_STATE"
  fi
}
trap cleanup EXIT

mkdir -p "$DIR"
chmod 700 "$DIR" 2>/dev/null || true
# gather 단독 실행도 이전 실패의 staging 산출물을 재사용하지 않는다. 확정 상태인
# cursor.json·vault-state.json은 건드리지 않아 실패 시 다음 실행에서 다시 수집한다.
rm -f "$OUT" "$VAULT_OUT" "$PENDING_CURSOR" "$PENDING_VAULT_STATE"
printf '[]\n' > "$CC_FILE"
printf '[]\n' > "$HERMES_FILE"
printf '[]\n' > "$CODEX_FILE"

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

canonical_timestamp() {
  jq -nr --arg value "$1" '
    if ($value | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]{3,6})?Z$")) then
      ($value | capture("^(?<base>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(?:\\.(?<fraction>[0-9]{3,6}))?Z$"))
      | .base + "." + (((.fraction // "") + "000000")[0:6]) + "Z"
    else $value end
  '
}

# 기존 두 소스는 v1 커서를 이어받는다. 새로 추가된 Codex는 첫 실행에 최근 7일을 되짚는다.
BASE_CURSOR="${LEGACY_CURSOR:-$DEFAULT_CURSOR}"
CC_CURSOR="$(canonical_timestamp "$(source_cursor claude-code "$BASE_CURSOR")")"
HERMES_CURSOR="$(canonical_timestamp "$(source_cursor hermes "$BASE_CURSOR")")"
CODEX_CURSOR="$(canonical_timestamp "$(source_cursor codex "$DEFAULT_CURSOR")")"
FUTURE_TIMESTAMP_LIMIT="$(canonical_timestamp "$(date -u -v+5M +"%Y-%m-%dT%H:%M:%S.000Z" 2>/dev/null || date -u -d '5 minutes' +"%Y-%m-%dT%H:%M:%S.000Z")")"
echo "소스별 커서 이후분 수집 시작(값은 로컬 상태 파일에만 보관)" >&2

# --- Claude Code: 사람이 입력한 root 대화만 ---
CC_DIR="$HOME/.claude/projects"
if [ -d "$CC_DIR" ]; then
  : > "$CC_PATHS_FILE"
  : > "$CC_LINKS_FILE"
  chmod 600 "$CC_PATHS_FILE" "$CC_LINKS_FILE" 2>/dev/null || true
  CC_INPUTS=()
  if ! find "$CC_DIR" -type l -print0 > "$CC_LINKS_FILE" 2>/dev/null \
    || [ -s "$CC_LINKS_FILE" ] \
    || ! find "$CC_DIR" -type f -name '*.jsonl' -print0 > "$CC_PATHS_FILE" 2>/dev/null; then
    CC_STATUS="error"
    SOURCE_ERROR_COUNT=$((SOURCE_ERROR_COUNT + 1))
  else
    while IFS= read -r -d '' cc_input; do
      CC_INPUTS+=("$cc_input")
    done < "$CC_PATHS_FILE"
  fi
  if [ "$CC_STATUS" = "error" ]; then
    :
  elif [ "${#CC_INPUTS[@]}" -eq 0 ]; then
    CC_STATUS="ok"
  elif jq -c -s '
    def target: .type=="user" and .origin.kind=="human" and .isSidechain==false;
    def valid_timestamp:
      (type=="string") and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]{3,6})?Z$");
    if any(.[]; target and (
      ((.timestamp | valid_timestamp) | not)
      or ((.sessionId | type) != "string")
      or ((.message.content | type) != "string")
    )) then error("invalid Claude user record")
    else
      [.[] | select(target
        and ((.message.content | startswith("[claude-config:learning-pipeline-internal]")) | not))
       | {source: "claude-code", session: .sessionId, ts: .timestamp, text: .message.content}]
    end
  ' "${CC_INPUTS[@]}" > "$CC_FILE" 2>/dev/null; then
    CC_STATUS="ok"
  else
    printf '[]\n' > "$CC_FILE"
    CC_STATUS="error"
    SOURCE_ERROR_COUNT=$((SOURCE_ERROR_COUNT + 1))
  fi
fi

# --- Hermes: export 후 메시지 시각으로 필터 ---
HERMES_BIN=""
command -v hermes >/dev/null 2>&1 && HERMES_BIN="$(command -v hermes)"
[ -z "$HERMES_BIN" ] && [ -x "$HOME/.local/bin/hermes" ] && HERMES_BIN="$HOME/.local/bin/hermes"
if [ -n "$HERMES_BIN" ]; then
  if "$HERMES_BIN" sessions export --format jsonl --only user-prompts --yes "$HERMES_RAW" >/dev/null 2>&1; then
    if jq -c -s '
      def valid_timestamp:
        (type=="string") and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]{3,6})?Z$");
      if any(.[];
        ((.created_at | valid_timestamp) | not)
        or ((.session_id | type) != "string")
        or ((.text | type) != "string")
      ) then error("invalid Hermes user record")
      else
        [.[] | select(((.text | startswith("[claude-config:learning-pipeline-internal]")) | not))
         | {source: "hermes", session: .session_id, ts: .created_at, text: .text}]
      end
    ' "$HERMES_RAW" > "$HERMES_FILE" 2>/dev/null; then
      HERMES_STATUS="ok"
    else
      printf '[]\n' > "$HERMES_FILE"
      HERMES_STATUS="error"
      SOURCE_ERROR_COUNT=$((SOURCE_ERROR_COUNT + 1))
    fi
  else
    HERMES_STATUS="error"
    SOURCE_ERROR_COUNT=$((SOURCE_ERROR_COUNT + 1))
  fi
fi

# --- Codex: root rollout의 role=user/input_text만 ---
COLLECTOR="$DIR/collect-codex-user-prompts.py"
if [ -f "$COLLECTOR" ] && [ -d "$HOME/.codex/sessions" ]; then
  if python3 "$COLLECTOR" \
    --sessions-root "$HOME/.codex/sessions" \
    --cursor "$CODEX_CURSOR" \
    --overlap-hours "$OVERLAP_HOURS" \
    --output "$CODEX_FILE" 2>/dev/null; then
    CODEX_STATUS="ok"
  else
    printf '[]\n' > "$CODEX_FILE"
    CODEX_STATUS="error"
    SOURCE_ERROR_COUNT=$((SOURCE_ERROR_COUNT + 1))
  fi
elif [ -d "$HOME/.codex/sessions" ]; then
  CODEX_STATUS="error"
  SOURCE_ERROR_COUNT=$((SOURCE_ERROR_COUNT + 1))
fi

if ! jq -n \
    --arg claudeCode "$CC_STATUS" \
    --arg hermes "$HERMES_STATUS" \
    --arg codex "$CODEX_STATUS" \
    '{version:1,sources:{"claude-code":$claudeCode,hermes:$hermes,codex:$codex}}' \
    > "$SOURCE_STATUS_TMP" \
  || ! chmod 600 "$SOURCE_STATUS_TMP" \
  || ! mv -f "$SOURCE_STATUS_TMP" "$SOURCE_STATUS"; then
  echo "ERROR: 소스 상태 기록 실패" >&2
  exit 1
fi
if [ "$SOURCE_ERROR_COUNT" -ne 0 ]; then
  echo "ERROR: 설치된 대화 소스 ${SOURCE_ERROR_COUNT}개 수집 실패 — 부분 성공으로 커밋하지 않음" >&2
  exit 1
fi

# 같은 timestamp에 늦게 저장된 발화도 boundary identity로 구분한다. identity는 로컬
# 커서에 SHA-256만 남기며 분석 파일의 실제 session ID는 소스별 익명 순번으로 바꾼다.
if [ ! -f "$FINALIZER" ] \
  || ! python3 "$FINALIZER" \
    --claude-file "$CC_FILE" \
    --hermes-file "$HERMES_FILE" \
    --codex-file "$CODEX_FILE" \
    --cursor-file "$CURSOR_FILE" \
    --claude-cursor "$CC_CURSOR" \
    --hermes-cursor "$HERMES_CURSOR" \
    --codex-cursor "$CODEX_CURSOR" \
    --future-limit "$FUTURE_TIMESTAMP_LIMIT" \
    --overlap-hours "$OVERLAP_HOURS" \
    --output "$OUT_TMP" \
    --pending-cursor "$PENDING_CURSOR"; then
  echo "ERROR: 대화 소스 경계 병합 실패" >&2
  exit 1
fi
mv -f "$OUT_TMP" "$OUT"
chmod 600 "$OUT" 2>/dev/null || true

# --- Vault: `.git`을 제외한 모든 파일을 목록화하고, 변경된 서술형 문서는 본문까지 수집 ---
CATALOGER="$DIR/vault-catalog.py"
SCOPE_FILE="$HOME/.claude/vault-scope.json"
VAULT_PATH=""
[ -f "$SCOPE_FILE" ] && VAULT_PATH=$(jq -r '.vaultPath // empty' "$SCOPE_FILE" 2>/dev/null || true)
if [ ! -f "$CATALOGER" ] || [ -z "$VAULT_PATH" ] || [ ! -d "$VAULT_PATH" ]; then
  echo "ERROR: Vault 카탈로그 또는 vaultPath를 찾지 못함" >&2
  exit 1
fi
python3 "$CATALOGER" "$VAULT_PATH" --strict \
  --state "$VAULT_STATE" \
  --pending-state "$PENDING_VAULT_STATE" \
  --documents-out "$VAULT_OUT" \
  --catalog-out "$HOME/.claude/vault-state/full-vault-index.json" 2>/dev/null
if ! PENDING_VAULT_FINGERPRINT=$(jq -er '
    select(.version == 1 and ((.files | type) == "object"))
    | .vaultFingerprint | select(type == "string" and length > 0)
  ' "$PENDING_VAULT_STATE" 2>/dev/null) \
  || ! DOCUMENTS_VAULT_FINGERPRINT=$(jq -er '
    select(.version == 1 and ((.changes | type) == "array"))
    | .vaultFingerprint | select(type == "string" and length > 0)
  ' "$VAULT_OUT" 2>/dev/null) \
  || [ "$PENDING_VAULT_FINGERPRINT" != "$DOCUMENTS_VAULT_FINGERPRINT" ]; then
  echo "ERROR: Vault 상태와 학습 문서 산출물이 완전한 같은 스냅샷이 아님" >&2
  exit 1
fi
chmod 600 "$VAULT_OUT" "$PENDING_VAULT_STATE" 2>/dev/null || true

chmod 600 "$PENDING_CURSOR" 2>/dev/null || true

COUNT=$(jq 'length' "$OUT")
CC_COUNT=$(jq '[.[] | select(.source == "claude-code")] | length' "$OUT")
HERMES_COUNT=$(jq '[.[] | select(.source == "hermes")] | length' "$OUT")
CODEX_COUNT=$(jq '[.[] | select(.source == "codex")] | length' "$OUT")
VAULT_CHANGE_COUNT=$(jq '.changes | length' "$VAULT_OUT" 2>/dev/null || echo 0)
VAULT_COUNT=$(jq '[.changes[] | select(.authorship != "generated" and .contentPolicy != "canonical-read-separately")] | length' "$VAULT_OUT" 2>/dev/null || echo 0)
echo "수집 완료 — 대화 ${COUNT}건(Claude ${CC_COUNT} + Hermes ${HERMES_COUNT} + Codex ${CODEX_COUNT}), Vault 학습 본문 ${VAULT_COUNT}건(전체 변경 ${VAULT_CHANGE_COUNT}건)" >&2
GATHER_SUCCEEDED=1
