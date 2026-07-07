#!/usr/bin/env bash
# claude-config test: auto-update engine (lib/auto-update.py) - isolated, NO real updates.
# Every case runs the engine with a temp HOME + AUTO_UPDATE_DRY_RUN=1 + a PATH that resolves
# NO update tools, so no network call and no global install can ever happen. The real
# ~/.claude and system packages are never touched. Run: bash test/auto-update.sh
#
# NOTE: Windows Python resolves "~" from USERPROFILE (not HOME), so we set BOTH; on Windows
# git-bash USERPROFILE must be the native path form (cygpath -w). Harmless on macOS/Linux.
set -u
root="$(cd "$(dirname "$0")/.." && pwd)"
eng="$root/claude/lib/auto-update.py"
PY="$(command -v python3)"
tmp="$(mktemp -d)"
today="$(date -u +%Y%m%d)"
pass=0; fail=0
assert(){ if [ "$2" = "0" ]; then pass=$((pass+1)); echo "PASS  $1"; else fail=$((fail+1)); echo "FAIL  $1"; fi; }
audir(){ printf '%s' "$1/.claude/auto-update"; }
seed(){ mkdir -p "$(audir "$1")"; printf '%s' "$2" > "$(audir "$1")/state.json"; }
winform(){ cygpath -w "$1" 2>/dev/null || printf '%s' "$1"; }
# run engine hermetically: neutered PATH (no claude/winget/brew/git resolvable) + dry-run +
# both HOME and USERPROFILE redirected to the temp home. extra leading env via $3.
eng_run(){ local h="$1" mode="$2" extra="${3:-}"; local w; w="$(winform "$h")";
  env PATH="/nonexistent-claude-config-test" HOME="$h" USERPROFILE="$w" AUTO_UPDATE_DRY_RUN=1 $extra "$PY" "$eng" "$mode" 2>/dev/null; }

# T1: opt-out kill switch -> exit 0, no state written at all
h="$tmp/t1"; mkdir -p "$h"
eng_run "$h" start "CLAUDE_NO_AUTO_UPDATE=1" >/dev/null 2>&1; rc=$?
{ [ "$rc" = "0" ] && [ ! -f "$(audir "$h")/state.json" ]; }; assert "T1 opt-out: exit0 + no state.json" $?

# T2: pin file -> engine no-ops before touching state (exit 0, no state.json)
h="$tmp/t2"; mkdir -p "$(audir "$h")"; : > "$(audir "$h")/pin"
eng_run "$h" start >/dev/null 2>&1; rc=$?
{ [ "$rc" = "0" ] && [ ! -f "$(audir "$h")/state.json" ]; }; assert "T2 pin: exit0 + no probe/state" $?

# T3: pending notify -> surfaced on stdout AND cleared from state (checked=today => no spawn)
h="$tmp/t3"; seed "$h" "{\"checked\":\"$today\",\"notify\":[\"node v1->v2\"]}"
out="$(eng_run "$h" start)"; rc=$?
echo "$out" | grep -q 'auto-update'; g1=$?
grep -q 'notify' "$(audir "$h")/state.json"; g2=$?
{ [ "$rc" = "0" ] && [ "$g1" = "0" ] && [ "$g2" != "0" ]; }; assert "T3 notify: printed + cleared from state" $?

# T4: throttle (already checked today) -> start does NOT spawn a probe (no probe.log)
h="$tmp/t4"; seed "$h" "{\"checked\":\"$today\"}"
rm -f "$(audir "$h")/probe.log"
eng_run "$h" start >/dev/null 2>&1; rc=$?
{ [ "$rc" = "0" ] && [ ! -f "$(audir "$h")/probe.log" ]; }; assert "T4 throttle: same-day => no probe spawned" $?

# T5: stale (checked old) -> start DOES spawn a detached probe (probe.log created)
h="$tmp/t5"; seed "$h" "{\"checked\":\"20000101\"}"
eng_run "$h" start >/dev/null 2>&1; rc=$?
{ [ "$rc" = "0" ] && [ -f "$(audir "$h")/probe.log" ]; }; assert "T5 stale-day => detached probe spawned" $?

# T6: probe fail-open with no tools + dry-run -> exit0, state.checked=today, history written,
#     and NO real update ran (dry-run guards + neutered PATH)
h="$tmp/t6"; mkdir -p "$h"
eng_run "$h" probe >/dev/null 2>&1; rc=$?
c=1; [ -f "$(audir "$h")/state.json" ] && grep -q "\"$today\"" "$(audir "$h")/state.json" && c=0
hist=1; [ -f "$(audir "$h")/history.jsonl" ] && hist=0
{ [ "$rc" = "0" ] && [ "$c" = "0" ] && [ "$hist" = "0" ]; }; assert "T6 probe: fail-open exit0 + checked=today + history" $?

# T7: CLAUDE_EVENTS_OFF repo-wide kill switch -> exit0, no state
h="$tmp/t7"; mkdir -p "$h"
eng_run "$h" start "CLAUDE_EVENTS_OFF=1" >/dev/null 2>&1; rc=$?
{ [ "$rc" = "0" ] && [ ! -f "$(audir "$h")/state.json" ]; }; assert "T7 events-off: exit0 + no state" $?

# T8/T9 unit-test the NEW safety path (KNOWN_GOOD record + auto-rollback + loud notify) by
# monkeypatching the engine's command layer - portable, hermetic, no real package manager.
# T8: an update that BREAKS the runtime -> known_good recorded, rollback, LOUD notify surfaced.
h="$tmp/t8"; mkdir -p "$h"; w="$(winform "$h")"
out="$(HOME="$h" USERPROFILE="$w" AU_ENG="$eng" "$PY" - <<'PY' 2>/dev/null
import importlib.util, os
spec = importlib.util.spec_from_file_location("au", os.environ["AU_ENG"])
au = importlib.util.module_from_spec(spec); spec.loader.exec_module(au)
vals = iter(["v20", None, "v20"])            # before -> after(broken) -> restored
au.cmd_version = lambda argv: next(vals, None)
au.runtime_targets = lambda: ([{"key": "node", "ver": ["node", "--version"], "id": "X"}], "winget")
au.do_update = lambda t, pm: (0, "ok")
au.do_rollback = lambda t, pm, ver: (0, "rolled")
au.claude_cmdline = lambda: None             # skip plugins
au.probe()
st = au.read_state()
kg = st.get("known_good", {}); notify = st.get("notify", [])
print("T8-OK" if (kg.get("node") == "v20" and any("node" in n and "[!]" in n for n in notify)) else "T8-FAIL %r %r" % (kg, notify))
PY
)"
echo "$out" | grep -q 'T8-OK'; assert "T8 breakage(unit): known_good + rollback + loud notify" $?

# T9: a successful update -> known_good recorded + old->new surfaced in notify (no false rollback)
h="$tmp/t9"; mkdir -p "$h"; w="$(winform "$h")"
out="$(HOME="$h" USERPROFILE="$w" AU_ENG="$eng" "$PY" - <<'PY' 2>/dev/null
import importlib.util, os
spec = importlib.util.spec_from_file_location("au", os.environ["AU_ENG"])
au = importlib.util.module_from_spec(spec); spec.loader.exec_module(au)
vals = iter(["v20", "v21"])                  # before -> after(updated, not broken)
au.cmd_version = lambda argv: next(vals, None)
au.runtime_targets = lambda: ([{"key": "node", "ver": ["node", "--version"], "id": "X"}], "winget")
au.do_update = lambda t, pm: (0, "ok")
au.claude_cmdline = lambda: None
au.probe()
st = au.read_state()
kg = st.get("known_good", {}); notify = st.get("notify", [])
print("T9-OK" if (kg.get("node") == "v20" and any("v20" in n and "v21" in n for n in notify)) else "T9-FAIL %r %r" % (kg, notify))
PY
)"
echo "$out" | grep -q 'T9-OK'; assert "T9 updated(unit): known_good + old->new notify" $?

rm -rf "$tmp"
verdict=FAIL; [ "$fail" = "0" ] && verdict=ALL-OK
echo "RESULT: pass=$pass fail=$fail $verdict"
[ "$fail" = "0" ]
