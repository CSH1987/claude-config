#!/usr/bin/env sh
# claude-config:edit-nudge — PostToolUse 훅. 최근 Skill/Agent/Task/mcp__* 호출
#   이후로 Edit/Write/MultiEdit 가 임계치(기본 6회) 이상 누적되면, code-review 나
#   관련 전문 에이전트 경유를 고려하라는 리마인더(additionalContext)를 1회만 주입한다.
#   (2026-07-14 세션감사: 89~132회 액션짜리 대형 코드작업일수록 확장도구 사용률이
#   0%로 떨어지는 역설 발견 → CLAUDE.md 프롬프트 지침만으론 안 지켜져 결정적 훅으로 보강.)
#
# 설계 원칙(edit-track.sh 계승):
#   · 결정적·모델 무관. 경로는 resolver(memdir.sh)만 사용(하드코딩 금지).
#   · FAIL-OPEN: 어떤 오류에도 조용히 exit 0 — 세션을 절대 막지 않는다.
#   · 끄기: EDIT_NUDGE_OFF=1 (개별) 또는 CLAUDE_EVENTS_OFF=1 (전역 이벤트 킬스위치).
#   · omc-state(=OMC_STATE_DIR)는 gitignore 된 라이브 티어라 상태 두기에 적합(커밋 안 됨).
#   · 하드블록 아님(경고만) — 작업 흐름을 막지 않는다. 임계치 도달 후 리셋 전까지 1회만 발화(스팸 금지).
set -u
[ "${CLAUDE_EVENTS_OFF:-}" = "1" ] && exit 0
[ "${EDIT_NUDGE_OFF:-}" = "1" ] && exit 0
command -v python3 >/dev/null 2>&1 || exit 0

payload="$(cat 2>/dev/null || true)"
[ -n "$payload" ] || exit 0

# 사전필터(성능): 이 훅이 관심있는 도구 호출이 아니면 python 파싱 전에 즉시 종료.
printf '%s' "$payload" | grep -Eq '"tool_name"[[:space:]]*:[[:space:]]*"(Edit|Write|MultiEdit|NotebookEdit|Skill|Agent|Task|mcp__[^"]*)"' || exit 0

# --- OMC_STATE_DIR 해석: env > memdir/omc-state(resolver) (edit-track.sh 와 동일) ---
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

threshold="${EDIT_NUDGE_THRESHOLD:-6}"

# 주의(2026-07-14 테스트로 발견): `printf ... | python3 - <<'PY'` 처럼 파이프와
# heredoc-as-stdin(`python3 -`)을 동시에 쓰면 파이프로 들어온 데이터와 heredoc
# 본문이 같은 stdin 스트림에서 충돌해 python 이 그 둘을 이어붙인 걸 소스코드로
# 읽으려다 실패한다(edit-track.sh 도 동일 버그로 실측 확인 — 별도 이슈로 보고).
# 그래서 여기선 python 소스를 임시파일로 먼저 떠낸 뒤, payload 는 별도로 그 파일의
# stdin 으로 파이프한다(소스와 데이터의 스트림을 분리).
tmp_py="$(mktemp 2>/dev/null || echo /tmp/edit-nudge-$$.py)"
trap 'rm -f "$tmp_py"' EXIT INT TERM

cat > "$tmp_py" <<'PY'
import sys, os, json

def done():
    sys.exit(0)

try:
    p = json.load(sys.stdin)
except Exception:
    done()
if not isinstance(p, dict):
    done()

tool = p.get("tool_name") or ""
EDIT_TOOLS = ("Edit", "Write", "MultiEdit", "NotebookEdit")
RESET_TOOLS = ("Skill", "Agent", "Task")
is_edit = tool in EDIT_TOOLS
is_reset = tool in RESET_TOOLS or (isinstance(tool, str) and tool.startswith("mcp__"))
if not is_edit and not is_reset:
    done()

sess = p.get("session_id") or os.environ.get("CLAUDE_SESSION_ID") or "nosession"
safe = "".join(c if (c.isalnum() or c in "._-") else "_" for c in str(sess)) or "nosession"
omc = os.environ.get("OMC_DIR") or ""
if not omc:
    done()
try:
    threshold = int(os.environ.get("NUDGE_THRESHOLD", "6"))
except Exception:
    threshold = 6

d = os.path.join(omc, "edit-nudge")
state_path = os.path.join(d, safe + ".json")

state = {"count": 0, "fired": False}
try:
    if os.path.isfile(state_path):
        with open(state_path, encoding="utf-8") as f:
            loaded = json.load(f)
            if isinstance(loaded, dict):
                state["count"] = int(loaded.get("count", 0) or 0)
                state["fired"] = bool(loaded.get("fired", False))
except Exception:
    state = {"count": 0, "fired": False}

if is_reset:
    state["count"] = 0
    state["fired"] = False
elif is_edit:
    state["count"] += 1

should_nudge = is_edit and state["count"] >= threshold and not state["fired"]
if should_nudge:
    state["fired"] = True

# 상태 저장(원자적 교체 — stop-metrics.sh 와 동일 패턴).
try:
    os.makedirs(d, exist_ok=True)
    tmp = state_path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(state, f, ensure_ascii=False, separators=(",", ":"))
    os.replace(tmp, state_path)
except Exception:
    pass

if should_nudge:
    msg = (
        f"이번 세션에서 확장도구(Skill/Agent/MCP) 호출 없이 코드 편집이 {state['count']}회 "
        "누적됐습니다. CLAUDE.md 정책: 커밋/프로덕션 코드 변경·신규 기능 빌드·근본원인 "
        "디버깅은 규모가 클수록 마무리 전 code-review 스킬(또는 해당 도메인 전문 에이전트) "
        "경유를 고려하세요. (하드 요구사항 아님 — 상황에 안 맞으면 무시 가능. "
        "이 세션에서 한 번만 표시됩니다.)"
    )
    out = {"hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": msg}}
    try:
        sys.stdout.write(json.dumps(out, ensure_ascii=False))
    except Exception:
        pass

sys.exit(0)
PY

printf '%s' "$payload" | OMC_DIR="$omc" NUDGE_THRESHOLD="$threshold" python3 "$tmp_py"
exit 0
