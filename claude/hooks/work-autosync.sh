#!/usr/bin/env bash
# claude-config:work-autosync — opt-in cloud backup of the CURRENT project (NOT the config repo).
#   Gated on a `.claude-autosync` marker at the git repo root (created by `claude-newproj`).
#   start (SessionStart) -> git pull --rebase ; end (SessionEnd) -> commit + push.
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

lock="$top/.git/.work-autosync.lock"
if ! mkdir "$lock" 2>/dev/null; then
  if [ -n "$(find "$lock" -maxdepth 0 -mmin +10 2>/dev/null)" ]; then
    rmdir "$lock" 2>/dev/null || true
    mkdir "$lock" 2>/dev/null || exit 0
  else
    exit 0
  fi
fi
trap 'rmdir "$lock" 2>/dev/null || true' EXIT

TO=""
command -v timeout >/dev/null 2>&1 && TO="timeout 30"

pull() {
  $TO git pull --rebase --autostash --quiet >/dev/null 2>&1 \
    || git rebase --abort >/dev/null 2>&1 || true
}

case "$mode" in
  start)
    pull
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
    pull
    $TO git push --quiet >/dev/null 2>&1 || true
    ;;
esac
exit 0
