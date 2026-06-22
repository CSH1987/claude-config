#!/usr/bin/env sh
# claude-config:morning-brief - SessionStart hook. Once/day "morning brief": surface (via Claude's
#   context) what the user may have forgotten (unreconciled _pending, recent decisions, growth
#   health). System->human reminding channel (v10 T2). Thin wrapper -> shared brief.py engine
#   (parity with morning-brief.ps1). Deterministic, FAIL-OPEN, throttled in brief.py.
#   Kill-switch: CLAUDE_EVENTS_OFF=1. stdout (if any) = SessionStart additionalContext JSON.
set -u
[ "${CLAUDE_EVENTS_OFF:-}" = "1" ] && exit 0
dbg=0; [ "${1:-}" = "--debug" ] && dbg=1

# brief.py: deployed (~/.claude/lib) > repo-relative
py="$HOME/.claude/lib/brief.py"
if [ ! -f "$py" ]; then
  d="$(CDPATH= cd -- "$(dirname -- "$0")/../lib" 2>/dev/null && pwd)"
  [ -n "$d" ] && py="$d/brief.py"
fi
[ -f "$py" ] || exit 0

# resolve memdir + Windows normalize
memdir="${CLAUDE_MEMORY_DIR:-}"
if [ -z "$memdir" ]; then
  r="$HOME/.claude/lib/memdir.sh"
  [ -f "$r" ] && eval "$(bash "$r" --no-ensure --export 2>/dev/null || true)"
  memdir="${CLAUDE_MEMORY_DIR:-}"
fi
[ -n "$memdir" ] || exit 0
command -v cygpath >/dev/null 2>&1 && memdir="$(cygpath -u "$memdir" 2>/dev/null || printf '%s' "$memdir")"
command -v python3 >/dev/null 2>&1 || exit 0

today="$(date -u +%Y%m%d 2>/dev/null || printf '')"
if [ "$dbg" = 1 ]; then
  python3 "$py" "$memdir" "$today" 1 || true
else
  python3 "$py" "$memdir" "$today" 0 2>/dev/null || true
fi
exit 0
