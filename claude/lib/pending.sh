#!/usr/bin/env sh
# claude-config:pending - stage a PRIVATE promotion proposal into _pending/<runId>/<slug>.md.
#   (plan v9 0-D hop1 staging / v10 T1-G1 retro distillation output.)
#   PRIVATE ONLY: writes under $CLAUDE_MEMORY_DIR only - NEVER under the PUBLIC claude-config tree.
#   Deterministic, FAIL-OPEN (any error -> exit 0; never blocks a hook/session). Body read from stdin.
#
# Usage:
#   echo "## Decision\n..." | sh pending.sh --kind decision --slug 20260622-foo --source retro
#   sh pending.sh --kind profile --slug pref-lang --source retro --run-id sess123 < body.md
# Frontmatter written: kind, slug, run_id, created_at, status:pending, source.
set -u
kind="note"; slug=""; runid="${CLAUDE_SESSION_ID:-}"; src="manual"; debug=0
while [ $# -gt 0 ]; do
  case "$1" in
    --kind)    kind="${2:-note}"; shift 2 ;;
    --slug)    slug="${2:-}"; shift 2 ;;
    --run-id)  runid="${2:-}"; shift 2 ;;
    --source)  src="${2:-manual}"; shift 2 ;;
    --debug)   debug=1; shift ;;
    *)         shift ;;
  esac
done
_f() { [ "$debug" = 1 ] && printf 'pending.sh: %s\n' "$1" >&2; exit 0; }

# --- resolve memdir (resolver = single source of truth) + Windows normalize ---
memdir="${CLAUDE_MEMORY_DIR:-}"
if [ -z "$memdir" ]; then
  r="$HOME/.claude/lib/memdir.sh"
  [ -f "$r" ] && eval "$(bash "$r" --no-ensure --export 2>/dev/null || true)"
  memdir="${CLAUDE_MEMORY_DIR:-}"
fi
[ -n "$memdir" ] || _f "cannot resolve CLAUDE_MEMORY_DIR"
command -v cygpath >/dev/null 2>&1 && memdir="$(cygpath -u "$memdir" 2>/dev/null || printf '%s' "$memdir")"

# --- sanitize identifiers (filename safety; block path traversal) ---
[ -n "$runid" ] || runid="local-$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || echo 0)"
runid="$(printf '%s' "$runid" | tr -c 'A-Za-z0-9._-' '_')"
[ -n "$slug" ] || slug="$(date -u +%Y%m%d 2>/dev/null || echo item)-$kind"
slug="$(printf '%s' "$slug" | tr -c 'A-Za-z0-9._-' '_')"
kind="$(printf '%s' "$kind" | tr -c 'A-Za-z0-9._-' '_')"
ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf '')"

dir="$memdir/_pending/$runid"
mkdir -p "$dir" 2>/dev/null || _f "mkdir failed"
out="$dir/$slug.md"
# body from stdin; guard against hang when no pipe is attached (interactive tty)
if [ -t 0 ]; then body=""; else body="$(cat 2>/dev/null || printf '')"; fi

{
  printf -- '---\n'
  printf 'kind: %s\n' "$kind"
  printf 'slug: %s\n' "$slug"
  printf 'run_id: %s\n' "$runid"
  printf 'created_at: %s\n' "$ts"
  printf 'status: pending\n'
  printf 'source: %s\n' "$src"
  printf -- '---\n\n'
  printf '%s\n' "$body"
} > "$out" 2>/dev/null || _f "write failed"

[ "$debug" = 1 ] && printf 'pending.sh: staged %s\n' "$out" >&2
exit 0
