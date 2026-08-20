#!/bin/bash
# codex-sync: claude-config 규칙을 codex CLI(~/.codex)에 자동 적용
# - AGENTS.md에 마커 블록 3종을 upsert (codex 자체 내용은 보존, 재실행 멱등):
#   1) claude-config:portable-rules   — exports/portable-rules.md (규칙 정본)
#   2) claude-config:codex-vault-rules — exports/codex-vault-rules.md (Vault 연동 안내)
#   3) claude-config:vault-context    — Vault 10_컨텍스트 인덱스 캐시 (vault-index.py 재사용)
# - codex는 $CODEX_HOME/AGENTS.md(기본 ~/.codex/AGENTS.md)를 cwd 무관 전역 지침으로 로드한다
#   (2026-08-20 실측 검증: 테스트 마커를 넣고 다른 cwd에서 `codex exec --sandbox read-only`
#   실행 → 그대로 인용됨. hermes와 달리 게이트웨이 cwd 종속이 아니라 대상 파일 1곳으로 충분).
# - codex 미설치 시 exit 0 (SessionStart 체인에 안전하게 상주 — 코덱스 없는 머신 안전)
CODEX_DIR="${1:-$HOME/.codex}"
SOURCE_DIR="${2:-$HOME/.claude}"

[ ! -d "$CODEX_DIR" ] && exit 0

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

# ── 블록 2: codex-vault-rules (Vault 연동 안내) ────────────────────
VR_FILE="$SOURCE_DIR/exports/codex-vault-rules.md"
VR_START='<!-- claude-config:codex-vault-rules:start -->'
VR_END='<!-- claude-config:codex-vault-rules:end -->'
if [ -f "$VR_FILE" ]; then
  { echo "$VR_START"; cat "$VR_FILE"; echo "$VR_END"; } > "$TMP.vr"
fi

# ── 블록 3: vault-context (10_컨텍스트 인덱스 캐시) ────────────────
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
    echo "아래는 Vault \`10_컨텍스트\` 노트 인덱스다. 상세 내용은 파일시스템으로 해당 노트를 직접 읽어라. 이 블록은 codex-sync 가 재생성한다 — 직접 수정 금지."
    echo "$VC_BODY"
    echo "$VC_END"; } > "$TMP.vc"
fi

AGENTS_MD="$CODEX_DIR/AGENTS.md"
upsert_block "$AGENTS_MD" "$PR_START" "$PR_END" "$TMP.pr"
[ -f "$TMP.vr" ] && upsert_block "$AGENTS_MD" "$VR_START" "$VR_END" "$TMP.vr"
[ -f "$TMP.vc" ] && upsert_block "$AGENTS_MD" "$VC_START" "$VC_END" "$TMP.vc"

rm -f "$TMP" "$TMP.pr" "$TMP.vr" "$TMP.vc"

echo "codex-sync: rules applied to $AGENTS_MD"
exit 0
