#!/usr/bin/env bash
# claude-config:work-autosync — opt-in cloud backup of the CURRENT project (NOT the config repo).
#   Gated on a `.claude-autosync` marker at the git repo root (created by `claude-newproj`).
#   start (SessionStart) -> git pull --rebase + push any unpushed backlog (self-heal).
#   end (SessionEnd) -> commit + push FIRST (the hook can be killed mid-run at session end;
#   a network step before push loses the backup) ; on push failure only: pull --rebase, retry once.
#   FAIL-CLOSED secret guard: before committing, unstages secret-looking files (.env, keys, tokens, ...)
#   so they are NEVER pushed to the cloud — a warning lists them; fix by adding to .gitignore.
#   Never blocks the session (GIT_TERMINAL_PROMPT=0, atomic lock, quiet skip on offline/conflict/no-upstream).
#   Kill-switch CLAUDE_AUTOSYNC_OFF=1. Skips config-sync's own repo to avoid a double-push race.
set -uo pipefail
mode="${1:-}"

[ "${CLAUDE_AUTOSYNC_OFF:-}" = "1" ] && exit 0
command -v git >/dev/null 2>&1 || exit 0
top="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
[ -n "$top" ] || exit 0                              # cwd not inside a git repo
[ -f "$top/.claude-autosync" ] || exit 0            # project not opted in

# don't double-act with config-sync on its own repo (different lock files would race)
cfg_file="$HOME/.claude/.config-sync-path"
if [ -f "$cfg_file" ]; then
  cfg="$(cat "$cfg_file" 2>/dev/null)"
  if [ -n "$cfg" ] && [ "$(cd "$cfg" 2>/dev/null && pwd -P)" = "$(cd "$top" 2>/dev/null && pwd -P)" ]; then exit 0; fi
fi

cd "$top" 2>/dev/null || exit 0
git rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1 || exit 0   # no upstream

export GIT_TERMINAL_PROMPT=0
# fail-closed secret denylist (case-insensitive)
secret_re='(^|/)\.env($|\.)|\.envrc$|\.(pem|key|p12|pfx|jks|keystore|ppk|p8)$|(^|/)id_(rsa|ed25519|dsa|ecdsa)$|\.(npmrc|netrc|pgpass|pypirc)$|(service[-_]account|credentials).*\.json$|token.*\.json$|(^|/)database\.(ya?ml|json)$|(^|/)\.(aws|kube|ssh)/|\.tfstate$|secrets?\.(ya?ml|json|env)$'

# lock with owner PID recorded inside (same fix as config-sync): a SessionEnd hook killed
# mid-push skips the trap and leaves the lock; age-only reclaim (10 min) would then block the
# very next session's start-mode self-heal. Dead-PID locks are reclaimed immediately; locks
# without a pid file keep the 10-min rule as the final safety net.
lock="$top/.git/.work-autosync.lock"
lock_stale() {
  p="$(cat "$lock/pid" 2>/dev/null || true)"
  if [ -n "$p" ] && ! kill -0 "$p" 2>/dev/null; then return 0; fi
  [ -n "$(find "$lock" -maxdepth 0 -mmin +10 2>/dev/null)" ]
}
if ! mkdir "$lock" 2>/dev/null; then
  if lock_stale; then
    rm -rf "$lock" 2>/dev/null || true
    mkdir "$lock" 2>/dev/null || exit 0
  else
    exit 0
  fi
fi
echo "$$" > "$lock/pid" 2>/dev/null || true
trap 'rm -rf "$lock" 2>/dev/null || true' EXIT

TO=""
command -v timeout >/dev/null 2>&1 && TO="timeout 30"

pull() {
  $TO git pull --rebase --autostash --quiet >/dev/null 2>&1 \
    || git rebase --abort >/dev/null 2>&1 || true
}

# push with lowSpeed guard (no hang on dead network); returns failure so callers can retry after pull
push_now() {
  $TO git -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=20 push --quiet >/dev/null 2>&1
}

case "$mode" in
  start)
    pull
    # self-heal: push any backlog left by a SessionEnd hook killed before its push completed
    ahead="$(git rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)"
    if [ "${ahead:-0}" -gt 0 ] 2>/dev/null; then
      push_now || { pull; push_now || true; }
      # stalled-backup visibility (same as config-sync): silent push failures once caused
      # a weeks-long backup gap - if still ahead after self-heal, say so.
      still="$(git rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)"
      if [ "${still:-0}" -gt 0 ] 2>/dev/null; then
        echo "claude-config work-autosync: $top backup is $still commit(s) ahead of remote (push still failing - check network/auth)." >&2
      fi
    fi
    ;;
  end)
    if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
      git add -A >/dev/null 2>&1 || true
      secrets="$(git diff --cached --name-only 2>/dev/null | grep -Ei "$secret_re" | grep -Eiv '\.(example|sample|template|dist)$' || true)"
      if [ -n "$secrets" ]; then
        printf '%s\n' "$secrets" | while IFS= read -r f; do [ -n "$f" ] && git reset -q -- "$f" >/dev/null 2>&1; done
        echo "claude-config work-autosync: NOT pushing secret-looking files: $(printf '%s ' $secrets)- add them to .gitignore" >&2
      fi
      if ! git diff --cached --quiet; then
        git commit -m "autosync: $(date '+%Y-%m-%d %H:%M:%S')" >/dev/null 2>&1 || true
      fi
    fi
    push_now || { pull; push_now || true; }
    ;;
esac
exit 0
