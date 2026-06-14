#!/usr/bin/env bash
# claude-config global PreToolUse guardrail (Mac/Linux wrapper). FAIL-OPEN.
# Forwards the hook stdin JSON to guardrails.py. If python3 is missing or anything errors,
# prints nothing and exits 0 -> the tool is ALLOWED (the guardrail never breaks a tool itself).
if command -v python3 >/dev/null 2>&1; then
  dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
  if [ -f "$dir/guardrails.py" ]; then
    python3 "$dir/guardrails.py" 2>/dev/null || true
  fi
fi
exit 0
