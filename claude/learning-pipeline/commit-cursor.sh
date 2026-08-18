#!/usr/bin/env bash
# 파이프라인(gather.sh → Workflow)이 성공적으로 끝난 뒤에만 호출한다.
# pending-cursor.txt 를 cursor.json 에 반영해 다음 실행이 이번 처리분을 건너뛰게 한다.
set -uo pipefail
DIR="$HOME/.claude/learning-pipeline"
PENDING="$DIR/pending-cursor.txt"
CURSOR_FILE="$DIR/cursor.json"

[ -f "$PENDING" ] || { echo "pending-cursor.txt 없음 — 먼저 gather.sh 실행 필요" >&2; exit 1; }
NEW_CURSOR=$(cat "$PENDING")
jq -n --arg lastProcessed "$NEW_CURSOR" --arg committedAt "$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")" \
  '{lastProcessed: $lastProcessed, committedAt: $committedAt}' > "$CURSOR_FILE"
echo "커서 커밋 완료: $NEW_CURSOR" >&2
