#!/usr/bin/env bash
# claude-config:model-watch - SessionStart hook (macOS/Linux). Keeps `model` in
#   ~/.claude/settings.json on the newest frontier Claude model automatically.
#   Thin wrapper -> shared lib/model-watch.py engine (parity with model-watch.ps1).
#   Fast path only; the once/day detection runs as a DETACHED probe (never blocks).
#   Kill-switch: CLAUDE_MODEL_WATCH_OFF=1 or pin file ~/.claude/model-watch/pin.
#   FAIL-OPEN. stdout (if any) = SessionStart additionalContext (switch notice).
[ "$CLAUDE_MODEL_WATCH_OFF" = "1" ] && exit 0

PY="$HOME/.claude/lib/model-watch.py"
if [ ! -f "$PY" ]; then
  PY="$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)/lib/model-watch.py"
fi
[ -f "$PY" ] || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

python3 "$PY" start 2>/dev/null || true
exit 0
