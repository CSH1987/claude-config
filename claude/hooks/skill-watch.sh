#!/usr/bin/env bash
# claude-config:skill-watch - SessionStart hook (macOS/Linux). Weekly background
#   scan for Claude Skills relevant to this user's actual repos/domains, filtered
#   through a verification gate (official source, or real GitHub stars + recent
#   maintenance). Thin wrapper -> shared lib/skill-watch.py engine (parity with
#   skill-watch.ps1). Fast path only; the once/week scan runs as a DETACHED
#   probe (never blocks). NEVER installs anything - proposal only, user approves.
#   Kill-switch: CLAUDE_SKILL_WATCH_OFF=1 or pin file ~/.claude/skill-watch/pin.
#   FAIL-OPEN. stdout (if any) = SessionStart additionalContext (candidate list).
[ "$CLAUDE_SKILL_WATCH_OFF" = "1" ] && exit 0

PY="$HOME/.claude/lib/skill-watch.py"
if [ ! -f "$PY" ]; then
  PY="$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)/lib/skill-watch.py"
fi
[ -f "$PY" ] || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

python3 "$PY" start 2>/dev/null || true
exit 0
