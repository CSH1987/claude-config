#!/usr/bin/env sh
# claude-config:edit-track — PostToolUse 훅. Edit/Write/MultiEdit/NotebookEdit 의
#   편집 파일 경로를 $OMC_STATE_DIR/edit-track/<session>.jsonl 에 1줄 append 한다.
#   stop-metrics.sh 가 이 기록으로 file-level rework(같은 파일 재편집)를 감지한다.
#   (plan v9 §2 rework 신호 · recall-budget.md §4 "PostToolUse/Stop 훅이 rework 를 채움".)
#
# 설계 원칙(기존 훅 계승):
#   · 결정적·모델 무관. 경로는 resolver(memdir.sh)만 사용(하드코딩 금지).
#   · FAIL-OPEN: 어떤 오류에도 조용히 exit 0 — 세션을 절대 막지 않는다.
#   · 끄기: CLAUDE_EVENTS_OFF=1 (events 전역 킬스위치 계승).
#   · omc-state(=OMC_STATE_DIR)는 gitignore 된 라이브 티어라 추적상태를 두기에 적합(커밋 안 됨).
set -u
[ "${CLAUDE_EVENTS_OFF:-}" = "1" ] && exit 0
command -v python3 >/dev/null 2>&1 || exit 0

payload="$(cat 2>/dev/null || true)"
[ -n "$payload" ] || exit 0

# 사전필터(성능): 편집 도구 호출이 아니면 python 파싱 전에 즉시 종료
# (비편집 도구의 대용량 tool_response 를 매번 파싱하지 않도록; 정확 판정은 python 이 재확인).
printf '%s' "$payload" | grep -Eq '"tool_name"[[:space:]]*:[[:space:]]*"(Edit|Write|MultiEdit|NotebookEdit)"' || exit 0

# --- OMC_STATE_DIR 해석: env > memdir/omc-state(resolver) ---
omc="${OMC_STATE_DIR:-}"
if [ -z "$omc" ]; then
  memdir="${CLAUDE_MEMORY_DIR:-}"
  if [ -z "$memdir" ]; then
    r="$HOME/.claude/lib/memdir.sh"
    [ -f "$r" ] && eval "$(bash "$r" --no-ensure --export 2>/dev/null || true)"
    memdir="${CLAUDE_MEMORY_DIR:-}"
    omc="${OMC_STATE_DIR:-}"
  fi
  [ -z "$omc" ] && [ -n "$memdir" ] && omc="$memdir/omc-state"
fi
[ -n "$omc" ] || exit 0
if command -v cygpath >/dev/null 2>&1; then
  omc="$(cygpath -u "$omc" 2>/dev/null || printf '%s' "$omc")"
fi

# python3: payload 파싱 → tool 필터 → file_path 추출 → edit-track/<session>.jsonl append
printf '%s' "$payload" | OMC_DIR="$omc" python3 - <<'PY' || exit 0
import sys, os, json, time
try:
    p = json.load(sys.stdin)
except Exception:
    sys.exit(0)
if not isinstance(p, dict):
    sys.exit(0)
tool = p.get("tool_name") or ""
if tool not in ("Edit", "Write", "MultiEdit", "NotebookEdit"):
    sys.exit(0)
ti = p.get("tool_input") or {}
fp = ""
if isinstance(ti, dict):
    fp = ti.get("file_path") or ti.get("notebook_path") or ""
if not fp:
    sys.exit(0)
sess = p.get("session_id") or os.environ.get("CLAUDE_SESSION_ID") or "nosession"
safe = "".join(c if (c.isalnum() or c in "._-") else "_" for c in str(sess)) or "nosession"
omc = os.environ.get("OMC_DIR") or ""
if not omc:
    sys.exit(0)
d = os.path.join(omc, "edit-track")
try:
    os.makedirs(d, exist_ok=True)
    line = json.dumps({"path": fp, "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())},
                      ensure_ascii=False, separators=(",", ":"))
    with open(os.path.join(d, safe + ".jsonl"), "a", encoding="utf-8") as f:
        f.write(line + "\n")
except Exception:
    pass
sys.exit(0)
PY
exit 0
