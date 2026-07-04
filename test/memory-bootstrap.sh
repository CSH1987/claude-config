#!/usr/bin/env bash
# claude-config test: memory-bootstrap.sh - isolated harness for claude/lib/memory-bootstrap.sh.
# Local temp dirs + local bare "remotes" only. NEVER touches the real ~/claude-memory: every case
# injects CLAUDE_MEMORY_DIR (temp) + CLAUDE_MEMORY_REMOTE (local bare). Run: bash test/memory-bootstrap.sh
set -u
root="$(cd "$(dirname "$0")/.." && pwd)"
hook="$root/claude/lib/memory-bootstrap.sh"
tmp="$(mktemp -d)"
pass=0; fail=0
assert() { if [ "$2" = "0" ]; then pass=$((pass+1)); echo "PASS  $1"; else fail=$((fail+1)); echo "FAIL  $1"; fi; }

# seed a local bare "remote" with README.md + profile/user-profile.json(real); prints bare path
seed_remote() {
  bare="$tmp/$1-remote.git"; work="$tmp/$1-seed"
  git init --bare --quiet "$bare"
  git init --quiet "$work"
  git -C "$work" config user.email t@example.com; git -C "$work" config user.name tester
  echo REMOTE > "$work/README.md"
  mkdir -p "$work/profile"; echo '{"real":true}' > "$work/profile/user-profile.json"
  git -C "$work" add -A >/dev/null 2>&1; git -C "$work" commit -qm seed >/dev/null 2>&1
  git -C "$work" branch -M main >/dev/null 2>&1
  git -C "$work" remote add origin "$bare"; git -C "$work" push -qu origin main >/dev/null 2>&1
  git -C "$bare" symbolic-ref HEAD refs/heads/main 2>/dev/null || true   # so clone checks out main
  printf '%s' "$bare"
}
# run the helper isolated (empty overrides parent env; not "1" => feature enabled)
run() { CLAUDE_MEMORY_NO_BOOTSTRAP= CLAUDE_MEMORY_BOOTSTRAP_CREATE= \
        CLAUDE_MEMORY_DIR="$1" CLAUDE_MEMORY_REMOTE="$2" bash "$hook" >/dev/null 2>&1; }

# case1: target already a git repo -> skip (never re-clone / clobber existing store)
bare="$(seed_remote c1)"; t="$tmp/c1"
git init --quiet "$t"; git -C "$t" config user.email t@example.com; git -C "$t" config user.name t
echo LOCAL > "$t/LOCAL.txt"; git -C "$t" add -A >/dev/null 2>&1; git -C "$t" commit -qm local >/dev/null 2>&1
run "$t" "$bare"
[ -f "$t/LOCAL.txt" ] && [ ! -f "$t/README.md" ]; assert "case1: existing .git respected (no clobber)" $?

# case2: empty dir -> clone + upstream set
bare="$(seed_remote c2)"; t="$tmp/c2"; mkdir -p "$t"
run "$t" "$bare"
{ [ -d "$t/.git" ] && [ -f "$t/README.md" ]; }; assert "case2: empty dir cloned (README present)" $?
git -C "$t" rev-parse '@{u}' >/dev/null 2>&1; assert "case2: upstream set (@{u} resolves)" $?

# case3: scaffold-only dir -> clone (remote canonical wins over empty seed)
bare="$(seed_remote c3)"; t="$tmp/c3"; mkdir -p "$t/profile" "$t/decisions" "$t/omc-state"
echo '{}' > "$t/profile/user-profile.json"; printf 'events/*.jsonl merge=union\n' > "$t/.gitattributes"
run "$t" "$bare"
{ [ -d "$t/.git" ] && [ -f "$t/README.md" ]; }; assert "case3: scaffold-only cloned" $?
grep -q '"real":true' "$t/profile/user-profile.json" 2>/dev/null; assert "case3: remote profile won over empty seed" $?

# case4: non-scaffold real data present -> refuse (no clone, data preserved)
bare="$(seed_remote c4)"; t="$tmp/c4"; mkdir -p "$t"; echo keep > "$t/important.txt"
run "$t" "$bare"
{ [ ! -d "$t/.git" ] && [ -f "$t/important.txt" ]; }; assert "case4: non-scaffold data refused (no clone, kept)" $?

# case5: unreachable remote -> skip (no clone, no auto-create)
t="$tmp/c5"; mkdir -p "$t"
run "$t" "$tmp/does-not-exist.git"
[ ! -d "$t/.git" ]; assert "case5: unreachable remote skipped (no .git)" $?

# case6: kill switch -> skip even with a valid remote
bare="$(seed_remote c6)"; t="$tmp/c6"; mkdir -p "$t"
CLAUDE_MEMORY_NO_BOOTSTRAP=1 CLAUDE_MEMORY_DIR="$t" CLAUDE_MEMORY_REMOTE="$bare" bash "$hook" >/dev/null 2>&1
[ ! -d "$t/.git" ]; assert "case6: CLAUDE_MEMORY_NO_BOOTSTRAP=1 disables bootstrap" $?

rm -rf "$tmp"
verdict=FAIL; [ "$fail" = "0" ] && verdict=ALL-OK
echo "RESULT: pass=$pass fail=$fail $verdict"
[ "$fail" = "0" ]
