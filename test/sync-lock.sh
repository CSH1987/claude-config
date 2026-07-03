#!/usr/bin/env bash
# claude-config test: sync-lock.sh - isolated regression harness for config-sync.sh:
#   lock reclaim (PID-liveness + 10-min age fallback), start-mode backlog self-heal,
#   stalled-backup warning, end-mode commit+push, lock cleanup.
# Local temp bare repos only (no network). Run: bash test/sync-lock.sh
set -u
root="$(cd "$(dirname "$0")/.." && pwd)"
hook="$root/claude/hooks/config-sync.sh"
tmp="$(mktemp -d)"
pass=0; fail=0
assert() { if [ "$2" = "0" ]; then pass=$((pass+1)); echo "PASS  $1"; else fail=$((fail+1)); echo "FAIL  $1"; fi; }
new_repo() {
  name="$1"; bare="$tmp/$name-origin.git"; work="$tmp/$name"
  git init --bare --quiet "$bare"
  git init --quiet "$work"
  git -C "$work" config user.email t@example.com
  git -C "$work" config user.name tester
  echo seed > "$work/f.txt"
  git -C "$work" add -A >/dev/null 2>&1
  git -C "$work" commit -qm seed >/dev/null 2>&1
  git -C "$work" remote add origin "$bare"
  git -C "$work" push -qu origin HEAD >/dev/null 2>&1
  printf '%s' "$work"
}
ahead() { git -C "$1" rev-list --count '@{u}..HEAD' 2>/dev/null || echo 99; }
add_commit() { echo more >> "$1/f.txt"; git -C "$1" add -A >/dev/null 2>&1; git -C "$1" commit -qm more >/dev/null 2>&1; }

# case1: dead-pid lock reclaimed immediately -> backlog pushed
# (killed-SessionEnd -> immediate-next-SessionStart self-heal scenario)
w="$(new_repo case1)"; add_commit "$w"
lock="$w/.git/.config-sync.lock"; mkdir "$lock"
( : ) & deadpid=$!; wait "$deadpid" 2>/dev/null
echo "$deadpid" > "$lock/pid"
sh "$hook" start "$w" >/dev/null 2>&1
[ "$(ahead "$w")" = "0" ]; assert "case1: dead-pid lock reclaimed -> pushed (ahead=0)" $?
[ ! -d "$lock" ]; assert "case1: lock removed after run" $?

# case2: live-pid lock respected (skip: no push, lock intact)
w="$(new_repo case2)"; add_commit "$w"
lock="$w/.git/.config-sync.lock"; mkdir "$lock"
sleep 60 & live=$!
echo "$live" > "$lock/pid"
sh "$hook" start "$w" >/dev/null 2>&1
[ "$(ahead "$w")" = "1" ]; assert "case2: live-pid lock respected -> skip (ahead=1)" $?
[ -d "$lock" ]; assert "case2: lock intact" $?
kill "$live" 2>/dev/null

# case3: legacy no-pid lock older than 10 min -> reclaimed (age fallback kept)
w="$(new_repo case3)"; add_commit "$w"
lock="$w/.git/.config-sync.lock"; mkdir "$lock"
touch -d '20 minutes ago' "$lock" 2>/dev/null \
  || touch -t "$(date -v-20M +%Y%m%d%H%M 2>/dev/null)" "$lock" 2>/dev/null
sh "$hook" start "$w" >/dev/null 2>&1
[ "$(ahead "$w")" = "0" ]; assert "case3: old no-pid lock reclaimed -> pushed (ahead=0)" $?

# case4: legacy no-pid lock, fresh (<10 min) -> respected (no over-aggressive reclaim)
w="$(new_repo case4)"; add_commit "$w"
lock="$w/.git/.config-sync.lock"; mkdir "$lock"
sh "$hook" start "$w" >/dev/null 2>&1
[ "$(ahead "$w")" = "1" ]; assert "case4: fresh no-pid lock respected -> skip (ahead=1)" $?

# case5: self-heal push cannot reach remote -> stalled-backup warning emitted
w="$(new_repo case5)"; add_commit "$w"
git -C "$w" remote set-url origin "$tmp/no-such-remote.git"
out="$(sh "$hook" start "$w" 2>&1)"
case "$out" in *claude-config:*) r=0;; *) r=1;; esac
assert "case5: stalled backup warning emitted" $r
[ "$(ahead "$w")" = "1" ]; assert "case5: still ahead (push impossible)" $?

# case6: end mode commits dirty tree, pushes, cleans lock
w="$(new_repo case6)"; echo dirty >> "$w/f.txt"
sh "$hook" end "$w" >/dev/null 2>&1
[ -z "$(git -C "$w" status --porcelain 2>/dev/null)" ]; assert "case6: end mode committed (clean tree)" $?
[ "$(ahead "$w")" = "0" ]; assert "case6: end mode pushed (ahead=0)" $?
[ ! -d "$w/.git/.config-sync.lock" ]; assert "case6: lock cleaned up" $?

rm -rf "$tmp"
verdict=FAIL; [ "$fail" = "0" ] && verdict=ALL-OK
echo "RESULT: pass=$pass fail=$fail $verdict"
[ "$fail" = "0" ]
