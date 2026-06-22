#!/usr/bin/env sh
# claude-config:session-events — SessionEnd 훅. 세션당 1 "성장 스냅샷" 이벤트 기록.
#   deep-interview AC#4(메모리·스킬·wiki 엔트리 수 증가 추적)의 시계열 토대 +
#   성장루프(④·v10 T1) 측정의 첫 실데이터. events.sh(공용 계측기)에 counts 를 넘겨 append.
#
# 원칙(기존 훅 계승):
#   · 결정적·모델 무관. 경로는 resolver(memdir.sh)만 사용.
#   · FAIL-OPEN: 어떤 오류에도 조용히 exit 0 — 세션을 절대 막지 않는다.
#   · 끄기: CLAUDE_EVENTS_OFF=1 (전역 킬스위치).
#   · --debug 로 카운트를 stderr 에 표시(테스트용).
set -u
[ "${CLAUDE_EVENTS_OFF:-}" = "1" ] && exit 0

# --- events.sh 위치: 배포본(~/.claude/lib) > 레포 상대경로 ---
lib="$HOME/.claude/lib/events.sh"
if [ ! -f "$lib" ]; then
  d="$(CDPATH= cd -- "$(dirname -- "$0")/../lib" 2>/dev/null && pwd)"
  [ -n "$d" ] && lib="$d/events.sh"
fi
[ -f "$lib" ] || exit 0

# --- memdir 해석(resolver = 단일 진실원) + Windows 백슬래시 정규화 ---
memdir="${CLAUDE_MEMORY_DIR:-}"
if [ -z "$memdir" ]; then
  r="$HOME/.claude/lib/memdir.sh"
  [ -f "$r" ] && eval "$(bash "$r" --no-ensure --export 2>/dev/null || true)"
  memdir="${CLAUDE_MEMORY_DIR:-}"
fi
[ -n "$memdir" ] || exit 0
if command -v cygpath >/dev/null 2>&1; then
  memdir="$(cygpath -u "$memdir" 2>/dev/null || printf '%s' "$memdir")"
fi

# --- 결정적 카운트(실패→0) ---
# profile_keys: 프로필 top-level 키 수(메타 제외)
pk=0
prof="$memdir/profile/user-profile.json"
if command -v python3 >/dev/null 2>&1 && [ -s "$prof" ]; then
  val="$(python3 - "$prof" <<'PY' 2>/dev/null
import sys, json
try:
    o = json.load(open(sys.argv[1], encoding="utf-8"))
    META = {"schema_version", "updated_at", "updated_by"}
    print(sum(1 for k in o if k not in META) if isinstance(o, dict) else 0)
except Exception:
    print(0)
PY
)"
  case "$val" in ''|*[!0-9]*) pk=0 ;; *) pk="$val" ;; esac
fi

# digest_files: cloud-digest/*.md 수
df=0
if [ -d "$memdir/cloud-digest" ]; then
  df="$(find "$memdir/cloud-digest" -maxdepth 1 -name '*.md' 2>/dev/null | wc -l | tr -d ' ')"
  case "$df" in ''|*[!0-9]*) df=0 ;; esac
fi

# --debug: decisions 수도 echo(스키마 counts 에 decisions 필드 없음 → 이벤트엔 미포함, 관측 echo 만)
dbg=""
if [ "${1:-}" = "--debug" ]; then
  dc=0
  [ -d "$memdir/decisions" ] && dc="$(find "$memdir/decisions" -name '*.md' 2>/dev/null | wc -l | tr -d ' ')"
  printf 'session-events: profile_keys=%s digest_files=%s decisions=%s memdir=%s\n' "$pk" "$df" "$dc" "$memdir" >&2
  dbg="--debug"
fi

# --- events.sh 로 스냅샷 이벤트 append ---
bash "$lib" --type snapshot --set "counts.profile_keys=$pk" --set "counts.digest_files=$df" $dbg
exit 0
