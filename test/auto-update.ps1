# claude-config test: auto-update engine (lib/auto-update.py) - Windows, isolated, NO real updates.
# Every case runs the engine with a temp USERPROFILE/HOME + AUTO_UPDATE_DRY_RUN=1 + a neutered
# PATH, so no network call and no global install can ever happen. The real ~/.claude and system
# packages are never touched. ASCII-only (PS 5.1 safe). Run: powershell -File test\auto-update.ps1
$ErrorActionPreference = 'SilentlyContinue'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Definition)
$eng  = Join-Path $root 'claude\lib\auto-update.py'
$py = (Get-Command python3 -ErrorAction SilentlyContinue)
if (-not $py) { $py = (Get-Command python -ErrorAction SilentlyContinue) }
$py = $py.Source
$tmp = Join-Path $env:TEMP ('au-test-' + (Get-Random))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$today = (Get-Date).ToUniversalTime().ToString('yyyyMMdd')
$script:pass = 0; $script:fail = 0
$origPath = $env:PATH; $origUP = $env:USERPROFILE; $origHome = $env:HOME

function Assert([string]$n, $c) {
    if ($c) { $script:pass++; Write-Output ("PASS  " + $n) }
    else    { $script:fail++; Write-Output ("FAIL  " + $n) }
}
function AuDir([string]$h) { Join-Path $h '.claude\auto-update' }
function Seed([string]$h, [string]$json) {
    $d = AuDir $h; New-Item -ItemType Directory -Force -Path $d | Out-Null
    Set-Content -Path (Join-Path $d 'state.json') -Value $json -Encoding ASCII -NoNewline
}
function RunEng([string]$h, [string]$mode) {
    $env:HOME = $h; $env:USERPROFILE = $h; $env:AUTO_UPDATE_DRY_RUN = '1'; $env:PATH = 'C:\nonexistent-cc-test'
    $o = & $py $eng $mode 2>$null
    $rc = $LASTEXITCODE
    $env:PATH = $origPath
    Remove-Item Env:\AUTO_UPDATE_DRY_RUN -ErrorAction SilentlyContinue
    return @{ rc = $rc; out = (($o | Out-String)) }
}
function StateRaw([string]$h) { $p = Join-Path (AuDir $h) 'state.json'; if (Test-Path $p) { Get-Content $p -Raw } else { '' } }

# T1: opt-out kill switch -> exit 0, no state written at all
$h = Join-Path $tmp 't1'; New-Item -ItemType Directory -Force -Path $h | Out-Null
$env:CLAUDE_NO_AUTO_UPDATE = '1'; $r = RunEng $h 'start'; Remove-Item Env:\CLAUDE_NO_AUTO_UPDATE -ErrorAction SilentlyContinue
Assert 'T1 opt-out: exit0 + no state.json' (($r.rc -eq 0) -and (-not (Test-Path (Join-Path (AuDir $h) 'state.json'))))

# T2: pin file -> engine no-ops before touching state (exit 0, no state.json)
$h = Join-Path $tmp 't2'; New-Item -ItemType Directory -Force -Path (AuDir $h) | Out-Null; Set-Content (Join-Path (AuDir $h) 'pin') '' -Encoding ASCII
$r = RunEng $h 'start'
Assert 'T2 pin: exit0 + no probe/state' (($r.rc -eq 0) -and (-not (Test-Path (Join-Path (AuDir $h) 'state.json'))))

# T3: pending notify -> surfaced on stdout AND cleared from state (checked=today => no spawn)
$h = Join-Path $tmp 't3'; Seed $h ('{"checked":"' + $today + '","notify":["node v1->v2"]}')
$r = RunEng $h 'start'
Assert 'T3 notify: printed + cleared from state' (($r.rc -eq 0) -and ($r.out -match 'auto-update') -and ((StateRaw $h) -notmatch 'notify'))

# T4: throttle (already checked today) -> start does NOT spawn a probe (no probe.log)
$h = Join-Path $tmp 't4'; Seed $h ('{"checked":"' + $today + '"}')
Remove-Item (Join-Path (AuDir $h) 'probe.log') -ErrorAction SilentlyContinue
$r = RunEng $h 'start'
Assert 'T4 throttle: same-day => no probe spawned' (($r.rc -eq 0) -and (-not (Test-Path (Join-Path (AuDir $h) 'probe.log'))))

# T5: stale (checked old) -> start DOES spawn a detached probe (probe.log created)
$h = Join-Path $tmp 't5'; Seed $h '{"checked":"20000101"}'
$r = RunEng $h 'start'
Assert 'T5 stale-day => detached probe spawned' (($r.rc -eq 0) -and (Test-Path (Join-Path (AuDir $h) 'probe.log')))

# T6: probe fail-open with no tools + dry-run -> exit0, state.checked=today, history written
$h = Join-Path $tmp 't6'; New-Item -ItemType Directory -Force -Path $h | Out-Null
$r = RunEng $h 'probe'
$stateOk = ((StateRaw $h) -match ('"' + $today + '"'))
$histOk  = (Test-Path (Join-Path (AuDir $h) 'history.jsonl'))
Assert 'T6 probe: fail-open exit0 + checked=today + history' (($r.rc -eq 0) -and $stateOk -and $histOk)

# T7: CLAUDE_EVENTS_OFF repo-wide kill switch -> exit0, no state.json
$h = Join-Path $tmp 't7'; New-Item -ItemType Directory -Force -Path $h | Out-Null
$env:CLAUDE_EVENTS_OFF = '1'; $r = RunEng $h 'start'; Remove-Item Env:\CLAUDE_EVENTS_OFF -ErrorAction SilentlyContinue
Assert 'T7 events-off: exit0 + no state.json' (($r.rc -eq 0) -and (-not (Test-Path (Join-Path (AuDir $h) 'state.json'))))

# T8/T9 unit-test the NEW safety path (KNOWN_GOOD record + auto-rollback + loud notify) by
# monkeypatching the engine's command layer via a piped Python script - hermetic, no real pkg mgr.
function Unit([string]$h, [string]$code) {
    $env:HOME = $h; $env:USERPROFILE = $h; $env:AU_ENG = $eng
    $o = ($code | & $py -) 2>$null
    Remove-Item Env:\AU_ENG -ErrorAction SilentlyContinue
    return ($o | Out-String)
}
$t8 = @'
import importlib.util, os
spec = importlib.util.spec_from_file_location("au", os.environ["AU_ENG"])
au = importlib.util.module_from_spec(spec); spec.loader.exec_module(au)
vals = iter(["v20", None, "v20"])
au.cmd_version = lambda argv: next(vals, None)
au.runtime_targets = lambda: ([{"key": "node", "ver": ["node", "--version"], "id": "X"}], "winget")
au.do_update = lambda t, pm: (0, "ok")
au.do_rollback = lambda t, pm, ver: (0, "rolled")
au.claude_cmdline = lambda: None
au.probe()
st = au.read_state()
kg = st.get("known_good", {}); notify = st.get("notify", [])
print("T8-OK" if (kg.get("node") == "v20" and any("node" in n and "[!]" in n for n in notify)) else "FAIL")
'@
$h = Join-Path $tmp 't8'; New-Item -ItemType Directory -Force -Path $h | Out-Null
Assert 'T8 breakage(unit): known_good + rollback + loud notify' ((Unit $h $t8) -match 'T8-OK')

$t9 = @'
import importlib.util, os
spec = importlib.util.spec_from_file_location("au", os.environ["AU_ENG"])
au = importlib.util.module_from_spec(spec); spec.loader.exec_module(au)
vals = iter(["v20", "v21"])
au.cmd_version = lambda argv: next(vals, None)
au.runtime_targets = lambda: ([{"key": "node", "ver": ["node", "--version"], "id": "X"}], "winget")
au.do_update = lambda t, pm: (0, "ok")
au.claude_cmdline = lambda: None
au.probe()
st = au.read_state()
kg = st.get("known_good", {}); notify = st.get("notify", [])
print("T9-OK" if (kg.get("node") == "v20" and any("v20" in n and "v21" in n for n in notify)) else "FAIL")
'@
$h = Join-Path $tmp 't9'; New-Item -ItemType Directory -Force -Path $h | Out-Null
Assert 'T9 updated(unit): known_good + old->new notify' ((Unit $h $t9) -match 'T9-OK')

# restore the real environment (never leave USERPROFILE/HOME pointing at temp)
$env:USERPROFILE = $origUP; $env:HOME = $origHome; $env:PATH = $origPath
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
$verdict = 'FAIL'; if ($script:fail -eq 0) { $verdict = 'ALL-OK' }
Write-Output ('RESULT: pass=' + $script:pass + ' fail=' + $script:fail + ' ' + $verdict)
if ($script:fail -gt 0) { exit 1 }
exit 0
