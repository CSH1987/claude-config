#!/bin/bash
# hermes-sync: claude-config 규칙을 hermes-agent(~/.hermes)에 자동 적용
# - AGENTS.md에 마커 블록으로 portable-rules를 삽입/갱신 (hermes 자체 내용은 보존, 재실행 멱등)
# - hermes는 AGENTS.md를 "세션 작업 디렉터리(cwd)"에서만 로드한다
#   (hermes-agent agent/prompt_builder.py `_load_agents_md` — cwd only, v0.18.2 확인).
#   게이트웨이 기본 cwd = config.yaml terminal.cwd 이고, 플레이스홀더("."|"auto"|"cwd")면
#   홈 디렉터리로 폴백한다 (gateway/run.py + gateway/cwd_placeholder.py).
#   따라서 두 곳에 주입한다:
#     1) $HERMES_DIR/AGENTS.md — hermes 공식 프로필 아티팩트, cwd=HERMES_HOME 배포 대응
#     2) 실효 게이트웨이 cwd/AGENTS.md — terminal.cwd 가 절대경로면 그곳, 아니면 $HOME
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
TMP="$(mktemp)"
{ echo "$START"; cat "$RULES_FILE"; echo "$END"; } > "$TMP.block"

# 마커 블록 upsert: 블록 밖 내용 보존, 재실행 멱등
upsert_agents_md() {
  local agents_md="$1"
  if [ -f "$agents_md" ] && grep -qF "$START" "$agents_md"; then
    awk -v start="$START" -v end="$END" -v blockfile="$TMP.block" '
      $0 == start { skip=1; while ((getline line < blockfile) > 0) print line; close(blockfile); next }
      $0 == end   { skip=0; next }
      skip != 1   { print }
    ' "$agents_md" > "$TMP" && mv "$TMP" "$agents_md"
  else
    { [ -f "$agents_md" ] && cat "$agents_md" && echo ""; cat "$TMP.block"; } > "$TMP" && mv "$TMP" "$agents_md"
  fi
}

# 실효 게이트웨이 cwd 결정: config.yaml terminal.cwd(절대경로·비플레이스홀더·존재) → 그 외 $HOME 폴백
GATEWAY_CWD="$HOME"
CONFIG_YAML="$HERMES_DIR/config.yaml"
if [ -f "$CONFIG_YAML" ]; then
  CWD_VAL="$(awk '
    /^terminal:[[:space:]]*(#.*)?$/ { intr=1; next }
    intr && /^[^[:space:]]/ { exit }
    intr && /^[[:space:]]+cwd:/ {
      sub(/^[[:space:]]+cwd:[[:space:]]*/, ""); sub(/#.*$/, "");
      gsub(/^["'"'"'[:space:]]+/, ""); gsub(/["'"'"'[:space:]]+$/, "");
      print; exit
    }' "$CONFIG_YAML")"
  case "$CWD_VAL" in
    ""|.|auto|cwd) : ;;
    /*) [ -d "$CWD_VAL" ] && GATEWAY_CWD="$CWD_VAL" ;;
  esac
fi

TARGETS="$HERMES_DIR/AGENTS.md"
if [ "$(cd "$GATEWAY_CWD" && pwd)" != "$(cd "$HERMES_DIR" && pwd)" ]; then
  TARGETS="$TARGETS $GATEWAY_CWD/AGENTS.md"
fi
for t in $TARGETS; do
  upsert_agents_md "$t"
done
rm -f "$TMP.block"

SKILL_SRC="$SOURCE_DIR/skills/workload-optimization"
if [ -d "$SKILL_SRC" ]; then
  mkdir -p "$HERMES_DIR/skills/workload-optimization"
  cp -rf "$SKILL_SRC/." "$HERMES_DIR/skills/workload-optimization/"
fi

echo "hermes-sync: rules applied to $TARGETS"
exit 0
