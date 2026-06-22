#!/usr/bin/env sh
# claude-config:leakscan — wrapper for the leak-guard scan engine (leakscan.py).
#   Reads added-diff lines from STDIN, exits 1 on PII/secret (v9 gate2a + gate2b), else 0.
#   Delegates matching to python3 (robust, identical cross-platform; MSYS2 `grep -iF` aborts).
#   Resolves memdir (for gate2b .leakwords) via the resolver, passes it to the engine.
#   python3 부재 시: WARN + exit 0 (fail-open) — python3 는 이 시스템의 하드 의존(.pyshim)이라
#   부재는 예외적이며, 전면 차단(동기화 중단)보다 현 상태(가드 없음)보다 나은 쪽을 택함.
#   Kill-switch: CLAUDE_LEAKGUARD_OFF=1.
set -u
[ "${CLAUDE_LEAKGUARD_OFF:-}" = "1" ] && exit 0
d="$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd)"
[ -n "$d" ] || exit 0
py="$d/leakscan.py"
[ -f "$py" ] || exit 0

# resolve memdir for gate2b (.leakwords); cygpath-normalize Windows backslash paths
memdir="${CLAUDE_MEMORY_DIR:-}"
if [ -z "$memdir" ]; then
  r="$HOME/.claude/lib/memdir.sh"
  [ -f "$r" ] && eval "$(bash "$r" --no-ensure --export 2>/dev/null || true)"
  memdir="${CLAUDE_MEMORY_DIR:-}"
fi
[ -n "$memdir" ] && command -v cygpath >/dev/null 2>&1 && memdir="$(cygpath -u "$memdir" 2>/dev/null || printf '%s' "$memdir")"

if command -v python3 >/dev/null 2>&1; then
  CLAUDE_MEMORY_DIR="$memdir" python3 "$py"
else
  printf 'leak-guard: WARN — python3 부재 → 누출 스캔 건너뜀(시스템 python3 의존[.pyshim] 미충족). 설치 권고.\n' >&2
  exit 0
fi
