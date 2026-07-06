#!/usr/bin/env sh
# claude-config:events — 평생 오케스트레이터 "공용 계측기".
#   events/<machineId>.jsonl 에 SCHEMA.md §3 형식의 이벤트 1줄을 append 한다.
#   (plan v9 §2 "공용 계측기" · v10 T1-G4 성장루프 측정 백본의 토대.)
#
# 설계 원칙(기존 훅 계승):
#   · 결정적·모델 무관. 경로는 resolver(memdir.sh)만 사용(하드코딩 금지·단일 진실원).
#   · FAIL-OPEN: 어떤 오류(env 미설정·python3 부재·경로 불가)에도 조용히 exit 0.
#     → 훅에서 호출돼도 세션을 절대 막지 않는다.
#   · machineId = $CLAUDE_MEMORY_DIR/_resolver-manifest.json 의 machine_id > hostname 폴백.
#   · Windows 백슬래시 경로는 cygpath 로 정규화(있으면).
#
# 사용:
#   bash events.sh --type task                         # 기본 task 이벤트 1줄
#   bash events.sh --type recall --set recall_hit=true --set recall_anchor=decision:HOME/20260621-x
#   bash events.sh --type backup --set backup.result=success --set backup.sha=abc123
#   bash events.sh --type task --debug                 # 성공/실패를 stderr 로 표시(테스트용)
# 키 표기: 점(.)으로 중첩 지정(backup.result, counts.skills). 값은 JSON 파싱 시도 후 실패 시 문자열.
set -u

debug=0
ev_type="task"
# 오버라이드 수집(개행 구분으로 python 에 전달)
overrides=""
add_override() { overrides="$overrides$1
"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --type)  ev_type="${2:-task}"; shift 2 ;;
    --set)   add_override "${2:-}"; shift 2 ;;
    --debug) debug=1; shift ;;
    *)       shift ;;   # 알 수 없는 인자 무시(fail-open 정신)
  esac
done

_fail() { [ "$debug" = "1" ] && printf 'events.sh: %s\n' "$1" >&2; exit 0; }

# --- 1) memdir 해석(resolver = 단일 진실원) ---
memdir="${CLAUDE_MEMORY_DIR:-}"
if [ -z "$memdir" ]; then
  resolver="$HOME/.claude/lib/memdir.sh"
  [ -f "$resolver" ] || _fail "no resolver, no CLAUDE_MEMORY_DIR"
  eval "$(bash "$resolver" --no-ensure --export 2>/dev/null || true)"
  memdir="${CLAUDE_MEMORY_DIR:-}"
fi
[ -n "$memdir" ] || _fail "cannot resolve CLAUDE_MEMORY_DIR"

# Windows 백슬래시 경로 → POSIX 정규화(cygpath 있으면). 없으면 원본 사용.
if command -v cygpath >/dev/null 2>&1; then
  memdir_u="$(cygpath -u "$memdir" 2>/dev/null || printf '%s' "$memdir")"
else
  memdir_u="$memdir"
fi
[ -n "$memdir_u" ] || _fail "empty memdir after normalize"

# --- 2) python3(정확한 JSON 이스케이프 — memory-inject.sh 와 동일 의존 관례) ---
command -v python3 >/dev/null 2>&1 || _fail "no python3 (fail-open)"

# --- 3) 컨텍스트 수집(셸에서 결정적으로) ---
ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf '')"
host="$(hostname 2>/dev/null || printf 'unknown')"
sess="${CLAUDE_SESSION_ID:-}"
omc="${OMC_STATE_DIR:-}"
# cwd 레포(있으면 toplevel, 없으면 PWD)
cwd_repo="$(git rev-parse --show-toplevel 2>/dev/null || pwd 2>/dev/null || printf '')"

# --- 4) python3 가 machineId 해석(manifest>host) + 스키마 기본 + 오버라이드 + append ---
#     오버라이드는 ENV 로 전달(stdin 은 heredoc 프로그램이 점유하므로 충돌 회피).
EV_OVERRIDES="$overrides" python3 - \
  "$memdir_u" "$ev_type" "$ts" "$host" "$sess" "$omc" "$cwd_repo" "$debug" <<'PY' || _fail "python build/append failed"
import sys, os, json

memdir, ev_type, ts, host, sess, omc, cwd_repo, debug = sys.argv[1:9]
debug = (debug == "1")

def err(m):
    if debug: sys.stderr.write("events.sh(py): %s\n" % m)
    sys.exit(0)   # fail-open

# machineId: manifest.machine_id > hostname > unknown
machine_id = host or "unknown"
try:
    mpath = os.path.join(memdir, "_resolver-manifest.json")
    if os.path.isfile(mpath):
        with open(mpath, "r", encoding="utf-8") as f:
            mid = (json.load(f) or {}).get("machine_id")
            if isinstance(mid, str) and mid.strip():
                machine_id = mid.strip()
except Exception:
    pass  # 폴백 유지

# 파일명 안전화(경로 인젝션 방지)
safe = "".join(c if (c.isalnum() or c in "._-") else "_" for c in machine_id) or "unknown"

# SCHEMA.md §3 완전 기본 스켈레톤(소비자가 필드 존재를 신뢰할 수 있게 전부 채움)
ev = {
    "ts": ts or None,
    "session_id": sess or None,
    "cwd_repo": cwd_repo or None,
    "omc_state_dir": omc or None,
    "machine_id": safe,
    "resolver_mode": "local-env",     # mode-A
    "runner_verified": False,         # mode-A(클라우드 러너 아님)
    "type": ev_type or "task",
    "skill_id": None,
    "skill_reused": False,
    "rework": False,
    "rework_anchor": None,
    "recall_query": None,
    "recall_hit": False,
    "recall_anchor": None,
    "recall_source": "decisions",
    "reask_count": 0,
    "anchor_reinject_count": 0,
    "label_n": 0,
    "gate_suspended": True,
    "degraded_to_proxy": False,
    "decision_writer": None,
    "pending_age_days": None,
    "outcome": None,        # success|fail|partial|null — 산출물 결과(선택; /retro·명령이 설정)
    "duration_ms": None,    # 작업/세션 소요(ms, 측정 시)
    "token_cost": None,     # 토큰 비용(알 때)
    "user_rating": None,    # 1-5 사용자 품질 평가(선택; claude-rate)
    "counts": {"skills": 0, "wiki": 0, "profile_keys": 0, "digest_files": 0},
    "backup": {
        "result": "skip", "sha": None, "ahead_count": 0, "last_snapshot_ts": None,
        "actions_minutes_left": None, "actions_budget_used": None,
        "ratelimit_headroom": None, "token_days_left": None, "reason": None,
    },
}

def coerce(v):
    try:
        return json.loads(v)   # true/false/숫자/"문자"/null
    except Exception:
        return v               # 평문 문자열

def set_dotted(obj, dotted, val):
    parts = dotted.split(".")
    cur = obj
    for p in parts[:-1]:
        if not isinstance(cur.get(p), dict):
            cur[p] = {}
        cur = cur[p]
    cur[parts[-1]] = val

# 오버라이드(개행구분 KEY=VALUE) 적용 — ENV 로 전달(stdin 은 heredoc 프로그램이 점유)
for line in os.environ.get("EV_OVERRIDES", "").splitlines():
    line = line.strip()
    if not line or "=" not in line:
        continue
    k, _, raw = line.partition("=")
    k = k.strip()
    if not k:
        continue
    set_dotted(ev, k, coerce(raw.strip()))

# append (events/ 디렉터리 멱등 생성)
try:
    edir = os.path.join(memdir, "events")
    os.makedirs(edir, exist_ok=True)
    path = os.path.join(edir, safe + ".jsonl")
    with open(path, "a", encoding="utf-8") as f:
        f.write(json.dumps(ev, ensure_ascii=False, separators=(",", ":")) + "\n")
    if debug:
        sys.stderr.write("events.sh: appended type=%s -> %s\n" % (ev["type"], path))
except Exception as e:
    err("append failed: %r" % (e,))
PY

exit 0
