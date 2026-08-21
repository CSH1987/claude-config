#!/usr/bin/env bash
# 파이프라인 성공 뒤에만 대화 커서와 Vault 분석 지문을 함께 확정한다.
set -euo pipefail

DIR="$HOME/.claude/learning-pipeline"
PENDING_CURSOR="$DIR/pending-cursor.json"
CURSOR_FILE="$DIR/cursor.json"
PENDING_VAULT_STATE="$DIR/pending-vault-state.json"
VAULT_STATE="$DIR/vault-state.json"

[ -f "$PENDING_CURSOR" ] || { echo "pending-cursor.json 없음 — 먼저 gather.sh 실행 필요" >&2; exit 1; }
[ -f "$PENDING_VAULT_STATE" ] || { echo "pending-vault-state.json 없음 — Vault 수집 상태를 확인해야 함" >&2; exit 1; }
temporary="$CURSOR_FILE.tmp.$$"
jq --arg committedAt "$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")" '.committedAt=$committedAt' \
  "$PENDING_CURSOR" > "$temporary"
chmod 600 "$temporary"

# 둘을 완전히 원자적으로 바꿀 수는 없으므로 Vault 상태를 먼저 확정하고 커서를
# 마지막에 전진시킨다. 중간 종료가 나도 재수집은 생길 수 있지만 대화 누락은 막는다.
chmod 600 "$PENDING_VAULT_STATE"
mv -f "$PENDING_VAULT_STATE" "$VAULT_STATE"
mv -f "$temporary" "$CURSOR_FILE"
rm -f "$PENDING_CURSOR"
echo "대화 커서와 Vault 분석 상태 커밋 완료" >&2
