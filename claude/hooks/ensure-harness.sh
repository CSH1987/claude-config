#!/usr/bin/env bash
set -uo pipefail
MARKER="$HOME/.claude/plugins/installed_plugins.json"
if [ -f "$MARKER" ] && grep -q "harness@harness-marketplace" "$MARKER" 2>/dev/null; then
  exit 0
fi
command -v claude >/dev/null 2>&1 || exit 0
claude plugin marketplace add revfactory/harness  >/dev/null 2>&1 || true
claude plugin install harness@harness-marketplace >/dev/null 2>&1 || true
exit 0
