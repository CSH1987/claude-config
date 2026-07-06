#!/usr/bin/env sh
# claude-config:metrics - derive PRIVATE metrics.md from events/*.jsonl union (mode-A).
#   Thin wrapper: resolves memdir, delegates aggregation to the shared metrics.py engine
#   (cross-platform parity with metrics.ps1). plan v9 0-J / v10 T1-G4 + G5.
#   Deterministic, FAIL-OPEN. Honors CLAUDE_EVENTS_OFF=1. Tune warn rate via REWORK_WARN_RATE.
set -u
[ "${CLAUDE_EVENTS_OFF:-}" = "1" ] && exit 0
dbg=0; [ "${1:-}" = "--debug" ] && dbg=1

self_dir="$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd)"
py="$self_dir/metrics.py"
[ -f "$py" ] || exit 0

memdir="${CLAUDE_MEMORY_DIR:-}"
if [ -z "$memdir" ]; then
  r="$HOME/.claude/lib/memdir.sh"
  [ -f "$r" ] && eval "$(bash "$r" --no-ensure --export 2>/dev/null || true)"
  memdir="${CLAUDE_MEMORY_DIR:-}"
fi
[ -n "$memdir" ] || exit 0
command -v cygpath >/dev/null 2>&1 && memdir="$(cygpath -u "$memdir" 2>/dev/null || printf '%s' "$memdir")"
command -v python3 >/dev/null 2>&1 || exit 0

python3 "$py" "$memdir" "${REWORK_WARN_RATE:-0.30}" "$dbg" 2>/dev/null || true
exit 0
