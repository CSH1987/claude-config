#!/usr/bin/env bash
# 파이프라인 성공 뒤에만 대화 커서와 Vault 분석 지문을 함께 확정한다.
set -euo pipefail

DIR="$HOME/.claude/learning-pipeline"
PENDING_CURSOR="$DIR/pending-cursor.json"
CURSOR_FILE="$DIR/cursor.json"
PENDING_VAULT_STATE="$DIR/pending-vault-state.json"
VAULT_STATE="$DIR/vault-state.json"

[ -f "$PENDING_CURSOR" ] || { echo "pending-cursor.json 없음 — 먼저 gather.sh 실행 필요" >&2; exit 1; }
temporary="$CURSOR_FILE.tmp.$$"
jq --arg committedAt "$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")" '.committedAt=$committedAt' \
  "$PENDING_CURSOR" > "$temporary"
chmod 600 "$temporary"
mv -f "$temporary" "$CURSOR_FILE"

if [ -f "$PENDING_VAULT_STATE" ]; then
  chmod 600 "$PENDING_VAULT_STATE"
  mv -f "$PENDING_VAULT_STATE" "$VAULT_STATE"
fi
rm -f "$PENDING_CURSOR"
echo "대화 커서와 Vault 분석 상태 커밋 완료" >&2
