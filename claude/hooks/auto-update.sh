#!/usr/bin/env bash
# claude-config:auto-update - SessionStart hook (macOS/Linux). Keeps session-related
#   components (Claude Code plugins + pwsh/node/gh/git runtimes) on latest, SAFELY.
#   Thin wrapper -> shared lib/auto-update.py engine (parity with auto-update.ps1).
#   Fast path only; the once/day update runs as a DETACHED probe (never blocks).
#   Off: CLAUDE_NO_AUTO_UPDATE=1 or pin file ~/.claude/auto-update/pin. FAIL-OPEN.
#   stdout (if any) = SessionStart additionalContext (update notice).
[ "$CLAUDE_NO_AUTO_UPDATE" = "1" ] && exit 0

PY="$HOME/.claude/lib/auto-update.py"
if [ ! -f "$PY" ]; then
  PY="$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)/lib/auto-update.py"
fi
[ -f "$PY" ] || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

python3 "$PY" start 2>/dev/null || true
exit 0
