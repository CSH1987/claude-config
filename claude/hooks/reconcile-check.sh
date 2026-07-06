#!/usr/bin/env sh
# claude-config:reconcile-check - SessionStart hook. Detect STALE _pending proposals.
#   (plan v9 0-G3 reconcile-stale gate / v10 T1-G2 hop1.) If the oldest _pending/*/*.md is
#   older than the threshold (default 7 days; env RECONCILE_STALE_DAYS), emit a
#   'reconcile-stale' event (via events.sh) so metrics.md surfaces unreconciled backlog.
#   Deterministic, FAIL-OPEN (exit 0 on any error). Kill-switch: CLAUDE_EVENTS_OFF=1.
set -u
[ "${CLAUDE_EVENTS_OFF:-}" = "1" ] && exit 0
dbg=0; [ "${1:-}" = "--debug" ] && dbg=1

# --- events.sh location: deployed > repo-relative ---
lib="$HOME/.claude/lib/events.sh"
if [ ! -f "$lib" ]; then
  d="$(CDPATH= cd -- "$(dirname -- "$0")/../lib" 2>/dev/null && pwd)"
  [ -n "$d" ] && lib="$d/events.sh"
fi
[ -f "$lib" ] || exit 0

# --- resolve memdir + Windows normalize ---
memdir="${CLAUDE_MEMORY_DIR:-}"
if [ -z "$memdir" ]; then
  r="$HOME/.claude/lib/memdir.sh"
  [ -f "$r" ] && eval "$(bash "$r" --no-ensure --export 2>/dev/null || true)"
  memdir="${CLAUDE_MEMORY_DIR:-}"
fi
[ -n "$memdir" ] || exit 0
command -v cygpath >/dev/null 2>&1 && memdir="$(cygpath -u "$memdir" 2>/dev/null || printf '%s' "$memdir")"
command -v python3 >/dev/null 2>&1 || exit 0

thr="${RECONCILE_STALE_DAYS:-7}"
res="$(python3 - "$memdir/_pending" <<'PY' 2>/dev/null
import os, sys, time
root = sys.argv[1]; oldest = None; n = 0
if os.path.isdir(root):
    for dp, _, fs in os.walk(root):
        for f in fs:
            if f.endswith('.md'):
                n += 1
                m = os.path.getmtime(os.path.join(dp, f))
                if oldest is None or m < oldest: oldest = m
age = -1 if oldest is None else int((time.time() - oldest) // 86400)
print("%d %d" % (n, age))
PY
)"
[ -n "$res" ] || exit 0
count="${res%% *}"; age="${res##* }"
case "$count" in ''|*[!0-9]*) exit 0 ;; esac
case "$age" in ''|*[!0-9]*) age=0 ;; esac

[ "$dbg" = 1 ] && printf 'reconcile-check: pending=%s oldest_age_days=%s threshold=%s\n' "$count" "$age" "$thr" >&2

if [ "$count" -gt 0 ] && [ "$age" -ge "$thr" ]; then
  d2=""; [ "$dbg" = 1 ] && d2="--debug"
  bash "$lib" --type sync --set "backup.result=reconcile-stale" --set "pending_age_days=$age" $d2
fi
exit 0
