#!/usr/bin/env bash
# SessionStart hook (Mac/Linux) - deterministically inject the user's canonical profile
# (profile/user-profile.json from the lifelong memory store) into Claude's context each
# session, so stable preferences/identity need not be re-explained (plan v9 0-I / A1).
#
# Determinism: model-independent. Resolves CLAUDE_MEMORY_DIR via the memdir resolver
# (~/.claude/lib/memdir.sh), reads profile/user-profile.json, and emits its contents as
# additionalContext (same stdout JSON shape as effort-reminder.sh, per the SessionStart
# hooks docs).
#
# Fail-safe (never blocks a session): on ANY problem - resolver missing, env unset, python3
# absent, file absent/empty/unparseable - it stays silent and exits 0 with no stdout.
#
# JSON correctness: profile values may contain quotes/backslashes/newlines/unicode, so unlike
# the fixed-text effort-reminder.sh we cannot inline the body into the JSON by hand. We use
# python3 (same dependency convention as guardrails.sh) to parse the profile, flatten it, and
# emit fully-escaped additionalContext JSON. If python3 is missing, we exit 0 silently.
set -uo pipefail

# --- 1. Resolve CLAUDE_MEMORY_DIR (resolver = single source of truth; never hardcode) ---
#     --no-ensure: read-only caller, do not create dirs. --export: emit 'export K=V' lines.
#     Resolver prints a Korean fallback notice to stderr when env is unset; discard stderr.
memdir="${CLAUDE_MEMORY_DIR:-}"
if [ -z "$memdir" ]; then
  resolver="$HOME/.claude/lib/memdir.sh"
  if [ -f "$resolver" ]; then
    eval "$(bash "$resolver" --no-ensure --export 2>/dev/null || true)"
    memdir="${CLAUDE_MEMORY_DIR:-}"
  fi
fi
[ -n "$memdir" ] || exit 0   # fail-safe: cannot resolve store -> silent

profile="$memdir/profile/user-profile.json"
[ -f "$profile" ] || exit 0          # no profile yet -> silent
[ -s "$profile" ] || exit 0          # empty file    -> silent
command -v python3 >/dev/null 2>&1 || exit 0   # no parser -> silent (fail-open)

# --- 2/3/4. Parse + flatten (schema-agnostic) + emit additionalContext JSON, all in python3 ---
#     Flattening mirrors memory-inject.ps1: top-level scalars shown directly; arrays
#     comma-joined; nested objects rendered as key=val; pairs; blanks skipped. Any error or
#     empty result -> print nothing -> session unaffected. json.dumps guarantees correct
#     escaping of the additionalContext string (quotes/backslashes/newlines/unicode).
python3 - "$profile" <<'PY' 2>/dev/null || true
import sys, json

def fmt(v):
    if v is None: return ""
    if isinstance(v, bool): return "true" if v else "false"
    if isinstance(v, (int, float)): return str(v)
    if isinstance(v, str): return v.strip()
    if isinstance(v, list):
        return ", ".join(s for s in (fmt(e) for e in v) if s)
    if isinstance(v, dict):
        return "; ".join("%s=%s" % (k, s) for k, s in ((k, fmt(val)) for k, val in v.items()) if s)
    return str(v).strip()

try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        obj = json.load(f)
except Exception:
    sys.exit(0)

if not isinstance(obj, dict):
    sys.exit(0)

# cold-start guard: never inject meta keys (empty seed -> no body -> silent exit 0).
META = {"schema_version", "updated_at", "updated_by"}
lines = []
for k, val in obj.items():
    if k in META:
        continue
    s = fmt(val)
    if s:
        lines.append("- %s: %s" % (k, s))

if not lines:
    sys.exit(0)

header = ("User profile (canonical lifelong memory; injected deterministically each session). "
          "These are stable, already-established facts/preferences - honor them without asking again:")
ctx = header + "\n" + "\n".join(lines)
out = {"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": ctx}}
sys.stdout.write(json.dumps(out, ensure_ascii=False))
PY
exit 0
