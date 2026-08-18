#!/usr/bin/env bash
# vault-learning-pipeline: 수집 단계 — 클로드코드 + 헤르메스 사용자 발화를 커서 이후분만 모아
# gathered-utterances.json 으로 쓴다. 커서 자체는 여기서 갱신하지 않는다 —
# 실행이 성공한 뒤에만 commit-cursor.sh 로 별도 커밋한다(실패 시 유실 방지).
# 전부 $HOME 기준(계정명 하드코딩 없음) — 어느 머신에서 돌려도 그 머신의 홈 기준으로 동작.
set -uo pipefail

DIR="$HOME/.claude/learning-pipeline"
CURSOR_FILE="$DIR/cursor.json"
OUT="$DIR/gathered-utterances.json"
PENDING_CURSOR="$DIR/pending-cursor.txt"
DEFAULT_LOOKBACK="7 days ago"

mkdir -p "$DIR"

if [ -f "$CURSOR_FILE" ]; then
  CURSOR=$(jq -r '.lastProcessed' "$CURSOR_FILE" 2>/dev/null)
else
  CURSOR=""
fi
if [ -z "$CURSOR" ] || [ "$CURSOR" = "null" ]; then
  CURSOR=$(date -u -v-7d +"%Y-%m-%dT%H:%M:%S.000Z" 2>/dev/null || date -u -d "$DEFAULT_LOOKBACK" +"%Y-%m-%dT%H:%M:%S.000Z")
fi
echo "커서(이 시각 이후만 수집): $CURSOR" >&2

# --- 클로드코드: 진짜 사람 타이핑만(origin.kind==human), 사이드체인 제외, 문자열 콘텐츠만 ---
CC_DIR="$HOME/.claude/projects"
CC="[]"
if [ -d "$CC_DIR" ]; then
  CC=$(jq -c -s --arg cursor "$CURSOR" '
    [.[] | select(.type=="user" and .origin.kind=="human" and .isSidechain==false
      and (.timestamp > $cursor) and (.message.content|type=="string"))
     | {source: "claude-code", session: .sessionId, ts: .timestamp, text: .message.content}]
  ' "$CC_DIR"/*/*.jsonl 2>/dev/null)
  [ -z "$CC" ] && CC="[]"
fi

# --- 헤르메스: sessions export 는 세션 "시작시각" 기준 필터라 메시지 단위 커서에 못 씀 ---
# 전체 user-prompts 를 뽑은 뒤 여기서 메시지 단위로 커서 필터링. Hermes 없는 머신이면 조용히 스킵.
HERMES_RAW="$DIR/.hermes-raw-export.jsonl.tmp"
HERMES="[]"
HERMES_BIN=""
command -v hermes >/dev/null 2>&1 && HERMES_BIN="$(command -v hermes)"
[ -z "$HERMES_BIN" ] && [ -x "$HOME/.local/bin/hermes" ] && HERMES_BIN="$HOME/.local/bin/hermes"
if [ -n "$HERMES_BIN" ]; then
  if "$HERMES_BIN" sessions export --format jsonl --only user-prompts --yes "$HERMES_RAW" >/dev/null 2>&1; then
    HERMES=$(jq -c -s --arg cursor "$CURSOR" '
      [.[] | select((.created_at > $cursor) and (.text | startswith("[") | not))
       | {source: "hermes", session: .session_id, ts: .created_at, text: .text}]
    ' "$HERMES_RAW" 2>/dev/null)
    [ -z "$HERMES" ] && HERMES="[]"
  fi
  rm -f "$HERMES_RAW"
fi

jq -c -n --argjson cc "$CC" --argjson hermes "$HERMES" '$cc + $hermes | sort_by(.ts)' > "$OUT"

COUNT=$(jq 'length' "$OUT")
CC_COUNT=$(echo "$CC" | jq 'length')
HERMES_COUNT=$(echo "$HERMES" | jq 'length')
echo "수집 완료 — 총 ${COUNT}건 (클로드코드 ${CC_COUNT} + 헤르메스 ${HERMES_COUNT})" >&2

if [ "$COUNT" -gt 0 ]; then
  MAX_TS=$(jq -r '[.[].ts] | max' "$OUT")
else
  MAX_TS="$CURSOR"
fi
echo -n "$MAX_TS" > "$PENDING_CURSOR"
echo "새 발화 없으면 커서 그대로, 있으면 커밋 대기 중인 새 커서: $MAX_TS" >&2
