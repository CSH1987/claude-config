#!/usr/bin/env sh
# claude-config:stop-metrics — Stop 훅. 이번 세션이 편집한 파일 중 "다른(이전) 세션이
#   편집한 적 있는" 파일을 file-level rework 로 감지해 events.sh 에 task(rework=true) 1줄을 남긴다.
#   (plan v9 §2 · recall-budget.md §4 "PostToolUse/Stop 훅이 rework 를 결정적으로 채움".)
#
# 정직 라벨(M5):
#   · file-level heuristic 일 뿐(symbol-level 아님). rework_anchor=file:<path>.
#   · precision/recall 게이트는 N≥30 까지 suspended(신호일 뿐, 진실 아님; recall-budget.md §5).
#   · recall_hit / reask_count 는 이 훅이 채우지 않는다 — recall 스킬·손라벨링이 채움(§4/§7).
#
# 설계 원칙(기존 훅 계승): 결정적·모델 무관·FAIL-OPEN(어떤 오류에도 exit 0). 끄기: CLAUDE_EVENTS_OFF=1.
#   세션 간 추적은 $OMC_STATE_DIR/edit-history.json(path→last_session)로 유지(gitignore 라 커밋 안 됨).
#   TODO(v2): edit-history.json TTL/cap + 고아 edit-track/ 샤드 GC (현재 무계 — omc-state 로컬 비용). + window/diff 도입.
set -u
[ "${CLAUDE_EVENTS_OFF:-}" = "1" ] && exit 0
command -v python3 >/dev/null 2>&1 || exit 0

payload="$(cat 2>/dev/null || true)"

# --- events.sh 위치: 배포본(~/.claude/lib) > 레포 상대경로 ---
ev="$HOME/.claude/lib/events.sh"
if [ ! -f "$ev" ]; then
  d="$(CDPATH= cd -- "$(dirname -- "$0")/../lib" 2>/dev/null && pwd)"
  [ -n "$d" ] && ev="$d/events.sh"
fi
[ -f "$ev" ] || exit 0

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

# python3: 이번 세션 편집 고유 path → history(다른 세션 편집) 대조 → rework path 출력 + history 갱신 + track truncate
rework_paths="$(printf '%s' "$payload" | OMC_DIR="$omc" python3 - <<'PY' 2>/dev/null || true
import sys, os, json
try:
    p = json.load(sys.stdin)
    if not isinstance(p, dict):
        p = {}
except Exception:
    p = {}
sess = p.get("session_id") or os.environ.get("CLAUDE_SESSION_ID") or "nosession"
sess = str(sess)
safe = "".join(c if (c.isalnum() or c in "._-") else "_" for c in sess) or "nosession"
omc = os.environ.get("OMC_DIR") or ""
if not omc:
    sys.exit(0)
track = os.path.join(omc, "edit-track", safe + ".jsonl")
if not os.path.isfile(track):
    sys.exit(0)

edited, seen = [], set()
try:
    with open(track, encoding="utf-8") as f:
        for ln in f:
            ln = ln.strip()
            if not ln:
                continue
            try:
                o = json.loads(ln)
            except Exception:
                continue
            fp = o.get("path")
            if fp and fp not in seen:
                seen.add(fp); edited.append(fp)
except Exception:
    sys.exit(0)
if not edited:
    sys.exit(0)

hpath = os.path.join(omc, "edit-history.json")
hist = {}
try:
    if os.path.isfile(hpath):
        with open(hpath, encoding="utf-8") as f:
            hist = json.load(f) or {}
            if not isinstance(hist, dict):
                hist = {}
except Exception:
    hist = {}

# rework = 이번 세션 편집 파일 중, 과거에 '다른 세션'이 편집한 것 (file-level)
rework = [fp for fp in edited if fp in hist and hist.get(fp) != sess]

# history 갱신: 이번 세션 편집 전부 현재 세션으로 (같은 세션 후속 Stop 에서 재검출 방지)
for fp in edited:
    hist[fp] = sess
try:
    tmp = hpath + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(hist, f, ensure_ascii=False, separators=(",", ":"))
    os.replace(tmp, hpath)  # atomic replace on same FS (concurrent-Stop safe)
except Exception:
    pass

# track truncate (처리 완료 — 다음 Stop 은 이후 편집만 본다 → 폭증/중복 방지)
try:
    open(track, "w", encoding="utf-8").close()
except Exception:
    pass

for fp in rework:
    sys.stdout.write(fp + "\n")
PY
)"

[ -n "$rework_paths" ] || exit 0
# 각 rework 파일 → events task(rework=true). gate_suspended 는 events 기본값(true) 유지.
printf '%s\n' "$rework_paths" | while IFS= read -r fp; do
  [ -n "$fp" ] || continue
  bash "$ev" --type task --set rework=true --set "rework_anchor=file:$fp" >/dev/null 2>&1 || true
done
exit 0
