#!/bin/bash
# hermes-sync: claude-config 규칙을 hermes-agent(~/.hermes)에 자동 적용
# - AGENTS.md에 마커 블록으로 portable-rules를 삽입/갱신 (hermes 자체 내용은 보존)
# - 이식 가능한 스킬(workload-optimization)을 hermes skills 디렉터리로 복사
# - hermes 미설치 시 무동작(exit 0) → SessionStart 체인에 안전하게 상주 가능
HERMES_DIR="${1:-}"
SOURCE_DIR="${2:-$HOME/.claude}"

if [ -z "$HERMES_DIR" ] && [ -d "$HOME/.hermes" ]; then
  HERMES_DIR="$HOME/.hermes"
fi
[ -z "$HERMES_DIR" ] || [ ! -d "$HERMES_DIR" ] && exit 0

RULES_FILE="$SOURCE_DIR/exports/portable-rules.md"
[ ! -f "$RULES_FILE" ] && exit 0

START='<!-- claude-config:portable-rules:start -->'
END='<!-- claude-config:portable-rules:end -->'
AGENTS_MD="$HERMES_DIR/AGENTS.md"
TMP="$(mktemp)"

{ echo "$START"; cat "$RULES_FILE"; echo "$END"; } > "$TMP.block"

if [ -f "$AGENTS_MD" ] && grep -qF "$START" "$AGENTS_MD"; then
  # 기존 블록 교체: 마커 밖 내용은 보존
  awk -v start="$START" -v end="$END" -v blockfile="$TMP.block" '
    $0 == start { skip=1; while ((getline line < blockfile) > 0) print line; close(blockfile); next }
    $0 == end   { skip=0; next }
    skip != 1   { print }
  ' "$AGENTS_MD" > "$TMP" && mv "$TMP" "$AGENTS_MD"
else
  # 블록 없음: 파일 끝에 추가(또는 신규 생성)
  { [ -f "$AGENTS_MD" ] && cat "$AGENTS_MD" && echo ""; cat "$TMP.block"; } > "$TMP" && mv "$TMP" "$AGENTS_MD"
fi
rm -f "$TMP.block"

SKILL_SRC="$SOURCE_DIR/skills/workload-optimization"
if [ -d "$SKILL_SRC" ]; then
  mkdir -p "$HERMES_DIR/skills/workload-optimization"
  cp -rf "$SKILL_SRC/." "$HERMES_DIR/skills/workload-optimization/"
fi

echo "hermes-sync: rules applied to $HERMES_DIR"
exit 0
