#!/usr/bin/env bash
# claude-config:eversvault-context — EversVault(옵시디언 LLM위키) 인덱스를 SessionStart에 주입.
# 실행계획: ~/.omc/plans/eversvault-llm-wiki.md (Phase 1)
# 머신게이트: 맥미니가 아니면 조용히 스킵(다른 머신엔 볼트가 없는 게 정상 상태 — fail-silent).
# 맥미니인데 scope.json/센티널이 없으면 이상상태이므로 경고 주입(fail-loud, "쓰기차단"과는 별개 원칙).
# 세션은 절대 막지 않는다 — 항상 exit 0.
set -u

host="$(hostname 2>/dev/null || echo '')"
case "$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')" in
  *macmini*) : ;;
  *) exit 0 ;;
esac

emit() {
  python3 -c "
import json, sys
print(json.dumps({'hookSpecificOutput': {'hookEventName': 'SessionStart', 'additionalContext': sys.argv[1]}}))
" "$1"
  exit 0
}

HOOK_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd)"
[ -n "$HOOK_DIR" ] || exit 0
INDEXER="$HOOK_DIR/eversvault-index.py"
SCOPE_FILE="$HOME/.claude/eversvault-scope.json"

command -v python3 >/dev/null 2>&1 || exit 0
[ -f "$SCOPE_FILE" ] || emit "[EversVault] 맥미니인데 eversvault-scope.json이 없습니다 — Phase1 설치를 확인하세요."

VAULT="$(python3 -c "
import json, os, sys
try:
    cfg = json.load(open(sys.argv[1], encoding='utf-8'))
    v = cfg.get('vaultPath', '')
    print(os.path.expanduser(v) if v else '')
except Exception:
    print('')
" "$SCOPE_FILE" 2>/dev/null)"
[ -n "$VAULT" ] || emit "[EversVault] eversvault-scope.json의 vaultPath가 비어있거나 파싱 실패."

SENTINEL="$VAULT/00_홈.md"
if [ ! -f "$SENTINEL" ] || ! head -1 "$SENTINEL" 2>/dev/null | grep -q "에버스 위키 홈"; then
  emit "[EversVault] 볼트 센티널(00_홈.md)을 찾지 못했습니다 — vaultPath 확인 필요: $VAULT"
fi

[ -f "$INDEXER" ] || exit 0
CONTEXT_10="$(python3 "$INDEXER" "$VAULT/10_컨텍스트" 2>/dev/null)"
[ -n "$CONTEXT_10" ] || CONTEXT_10="[EversVault 10_컨텍스트] 인덱스 생성 실패"

PROJECTS="$(python3 -c "
import json, sys
try:
    cfg = json.load(open(sys.argv[1], encoding='utf-8'))
    print('\n'.join(cfg.get('projects', [])))
except Exception:
    pass
" "$SCOPE_FILE" 2>/dev/null)"

CWD_LOWER="$(pwd | tr '[:upper:]' '[:lower:]')"
IN_SCOPE=0
if [ -n "$PROJECTS" ]; then
  while IFS= read -r proj; do
    [ -z "$proj" ] && continue
    proj_lower="$(printf '%s' "$proj" | tr '[:upper:]' '[:lower:]')"
    case "$CWD_LOWER" in
      *"$proj_lower"*) IN_SCOPE=1 ;;
    esac
  done <<PROJ_EOF
$PROJECTS
PROJ_EOF
fi

FULL="$CONTEXT_10"
if [ "$IN_SCOPE" = "1" ]; then
  CONTEXT_20="$(python3 "$INDEXER" "$VAULT/20_업무위키" --recursive 2>/dev/null)"
  [ -n "$CONTEXT_20" ] && FULL="$FULL

$CONTEXT_20"
fi

emit "$FULL"
