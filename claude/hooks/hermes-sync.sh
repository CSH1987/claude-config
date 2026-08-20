#!/bin/bash
# hermes-sync: claude-config 규칙을 hermes-agent(~/.hermes)에 자동 적용
# - AGENTS.md에 마커 블록 4종을 upsert (hermes 자체 내용은 보존, 재실행 멱등):
#   1) claude-config:portable-rules     — exports/portable-rules.md (규칙 정본)
#   2) claude-config:hermes-vault-rules — exports/hermes-vault-rules.md (Vault 연동 안내 —
#      2026-08-19 정본화: 종전엔 ~/.hermes/AGENTS.md 블록 밖에만 있어 실효 로드 파일인
#      실효 게이트웨이 cwd/AGENTS.md 에는 전달되지 않던 결함 수정)
#   3) claude-config:vault-context      — Vault 10_컨텍스트 인덱스 캐시 (정본=옵시디언 Vault,
#      생성 로직은 vault-context.sh 와 동일하게 vault-index.py 재사용 — 중복 구현 금지)
#   4) claude-config:vault-catalog      — Vault 전체 파일 커버리지·변경 상태 요약
# - hermes는 AGENTS.md를 "세션 작업 디렉터리(cwd)"에서만 로드한다
#   (hermes-agent agent/prompt_builder.py `_load_agents_md` — cwd only, v0.18.2 확인).
#   게이트웨이 기본 cwd = config.yaml terminal.cwd 이고, 플레이스홀더("."|"auto"|"cwd")면
#   홈 디렉터리로 폴백한다 (gateway/run.py + gateway/cwd_placeholder.py).
#   따라서 두 곳에 주입한다:
#     1) $HERMES_DIR/AGENTS.md — hermes 공식 프로필 아티팩트, cwd=HERMES_HOME 배포 대응
#     2) 실효 게이트웨이 cwd/AGENTS.md — terminal.cwd 가 절대경로면 그곳, 아니면 $HOME
# - vault-context 블록은 인덱스가 실제로 생성될 때만 갱신(볼트 부재·인덱서 실패 시 기존 블록
#   유지 — 스테일 캐시가 삭제보다 안전). 타임스탬프는 넣지 않는다 — 매 실행 바이트가 바뀌면
#   멱등성이 깨지고 hermes 프롬프트 프리픽스 캐시가 무효화됨(hermes system_prompt.py 가 같은
#   이유로 date-only 타임스탬프를 채택함).
# - 이식 가능한 스킬(workload-optimization)을 hermes skills 디렉터리로 복사
# - hermes 미설치·볼트 부재 등 어떤 경우에도 exit 0 (SessionStart 체인에 안전하게 상주)
HERMES_DIR="${1:-}"
SOURCE_DIR="${2:-$HOME/.claude}"

if [ -z "$HERMES_DIR" ] && [ -d "$HOME/.hermes" ]; then
  HERMES_DIR="$HOME/.hermes"
fi
[ -z "$HERMES_DIR" ] || [ ! -d "$HERMES_DIR" ] && exit 0

RULES_FILE="$SOURCE_DIR/exports/portable-rules.md"
[ ! -f "$RULES_FILE" ] && exit 0

TMP="$(mktemp)"

# 마커 블록 upsert: 블록 밖 내용 보존, 재실행 멱등.
# $1=대상파일 $2=시작마커 $3=끝마커 $4=블록파일(마커 포함)
upsert_block() {
  local agents_md="$1" start="$2" end="$3" blockfile="$4"
  if [ -f "$agents_md" ] && grep -qF "$start" "$agents_md"; then
    awk -v start="$start" -v end="$end" -v blockfile="$blockfile" '
      $0 == start { skip=1; while ((getline line < blockfile) > 0) print line; close(blockfile); next }
      $0 == end   { skip=0; next }
      skip != 1   { print }
    ' "$agents_md" > "$TMP" && mv "$TMP" "$agents_md"
  else
    { [ -f "$agents_md" ] && cat "$agents_md" && echo ""; cat "$blockfile"; } > "$TMP" && mv "$TMP" "$agents_md"
  fi
}

# ── 블록 1: portable-rules (규칙 정본) ─────────────────────────────
PR_START='<!-- claude-config:portable-rules:start -->'
PR_END='<!-- claude-config:portable-rules:end -->'
{ echo "$PR_START"; cat "$RULES_FILE"; echo "$PR_END"; } > "$TMP.pr"

# ── 블록 2: hermes-vault-rules (Vault 연동 안내 정본) ──────────────
VR_FILE="$SOURCE_DIR/exports/hermes-vault-rules.md"
VR_START='<!-- claude-config:hermes-vault-rules:start -->'
VR_END='<!-- claude-config:hermes-vault-rules:end -->'
if [ -f "$VR_FILE" ]; then
  { echo "$VR_START"; cat "$VR_FILE"; echo "$VR_END"; } > "$TMP.vr"
fi

# ── 블록 3: vault-context (10_컨텍스트 인덱스 캐시) ────────────────
# vault-index.py 는 인덱스 텍스트를 stdout 으로 내는 게 기본 동작이라 수정 없이 재사용.
VC_START='<!-- claude-config:vault-context:start -->'
VC_END='<!-- claude-config:vault-context:end -->'
HOOK_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd)"
SCOPE_FILE="$HOME/.claude/vault-scope.json"
INDEXER="$HOOK_DIR/vault-index.py"
VC_BODY=""
if [ -n "$HOOK_DIR" ] && [ -f "$SCOPE_FILE" ] && [ -f "$INDEXER" ] && command -v python3 >/dev/null 2>&1; then
  VAULT="$(python3 -c "
import json, os, sys
try:
    cfg = json.load(open(sys.argv[1], encoding='utf-8'))
    v = cfg.get('vaultPath', '')
    print(os.path.expanduser(v) if v else '')
except Exception:
    print('')
" "$SCOPE_FILE" 2>/dev/null)"
  if [ -n "$VAULT" ] && [ -d "$VAULT/10_컨텍스트" ]; then
    VC_BODY="$(python3 "$INDEXER" "$VAULT/10_컨텍스트" 2>/dev/null)"
  fi
fi
if [ -n "$VC_BODY" ]; then
  { echo "$VC_START"
    echo "## Vault 10_컨텍스트 인덱스 (자동 생성 캐시 — 정본은 옵시디언 Vault)"
    echo "아래는 Vault \`10_컨텍스트\` 노트 인덱스다. 상세 내용은 obsidian 스킬로 해당 노트를 직접 읽어라. 이 블록은 hermes-sync 가 재생성한다 — 직접 수정 금지."
    echo "$VC_BODY"
    echo "$VC_END"; } > "$TMP.vc"
fi

# ── 블록 4: vault-catalog (전체 Vault 커버리지 지도) ───────────────
CAT_START='<!-- claude-config:vault-catalog:start -->'
CAT_END='<!-- claude-config:vault-catalog:end -->'
CATALOGER="$HOOK_DIR/vault-catalog.py"
CAT_BODY=""
if [ -n "${VAULT:-}" ] && [ -d "${VAULT:-}" ] && [ -f "$CATALOGER" ]; then
  STATE_FILE="$HOME/.claude/learning-pipeline/vault-state.json"
  CATALOG_FILE="$HOME/.claude/vault-state/full-vault-index.json"
  CAT_BODY="$(python3 "$CATALOGER" "$VAULT" --overview --state "$STATE_FILE" --catalog-out "$CATALOG_FILE" 2>/dev/null)"
fi
if [ -n "$CAT_BODY" ]; then
  { echo "$CAT_START"
    echo "## Vault 전체 지식 지도 (자동 생성 캐시 — 원문 정본은 옵시디언 Vault)"
    echo "$CAT_BODY"
    echo "$CAT_END"; } > "$TMP.cat"
fi

# ── 실효 게이트웨이 cwd 결정: terminal.cwd(절대경로·비플레이스홀더·존재) → 그 외 $HOME ──
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
  upsert_block "$t" "$PR_START" "$PR_END" "$TMP.pr"
  [ -f "$TMP.vr" ] && upsert_block "$t" "$VR_START" "$VR_END" "$TMP.vr"
  [ -f "$TMP.vc" ] && upsert_block "$t" "$VC_START" "$VC_END" "$TMP.vc"
  [ -f "$TMP.cat" ] && upsert_block "$t" "$CAT_START" "$CAT_END" "$TMP.cat"
done
rm -f "$TMP" "$TMP.pr" "$TMP.vr" "$TMP.vc" "$TMP.cat"

SKILL_SRC="$SOURCE_DIR/skills/workload-optimization"
if [ -d "$SKILL_SRC" ]; then
  mkdir -p "$HERMES_DIR/skills/workload-optimization"
  cp -rf "$SKILL_SRC/." "$HERMES_DIR/skills/workload-optimization/"
fi

echo "hermes-sync: rules applied to $TARGETS"
exit 0
