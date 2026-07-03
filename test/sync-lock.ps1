# claude-config test: sync-lock.ps1 - isolated regression harness for config-sync.ps1:
#   lock reclaim (PID-liveness + 10-min age fallback), start-mode backlog self-heal,
#   stalled-backup warning, end-mode commit+push, lock cleanup.
# Local temp bare repos only (no network, no side effects outside %TEMP%).
# ASCII-only body (PS 5.1 safe, no BOM needed). Run: powershell -File test\sync-lock.ps1
$ErrorActionPreference = 'SilentlyContinue'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Definition)
$hook = Join-Path $root 'claude\hooks\config-sync.ps1'
$tmp  = Join-Path $env:TEMP ('sync-lock-test-' + (Get-Random))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

$script:pass = 0; $script:fail = 0
function Assert([string]$name, $cond) {
    if ($cond) { $script:pass++; Write-Output ("PASS  " + $name) }
    else       { $script:fail++; Write-Output ("FAIL  " + $name) }
}
function New-TestRepo([string]$name) {
    $bare = Join-Path $tmp ($name + '-origin.git')
    $work = Join-Path $tmp $name
    git init --bare --quiet $bare *> $null
    git init --quiet $work *> $null
    git -C $work config user.email 't@example.com' *> $null
    git -C $work config user.name 'tester' *> $null
    Set-Content (Join-Path $work 'f.txt') 'seed'
    git -C $work add -A *> $null
    git -C $work commit -m seed --quiet *> $null
    git -C $work remote add origin $bare *> $null
    git -C $work push -u origin HEAD --quiet *> $null
    return $work
}
function Get-Ahead([string]$work) { return [int](git -C $work rev-list --count '@{u}..HEAD' 2>$null) }
function Add-LocalCommit([string]$work) {
    Add-Content (Join-Path $work 'f.txt') 'more'
    git -C $work add -A *> $null
    git -C $work commit -m more --quiet *> $null
}
function Invoke-Hook([string]$work, [string]$mode) {
    return (& powershell -NoProfile -ExecutionPolicy Bypass -File $hook -Mode $mode -Repo $work 2>&1 | Out-String)
}
function Get-DeadPid {
    $p = Start-Process powershell -ArgumentList '-NoProfile', '-Command', 'exit' -PassThru -WindowStyle Hidden
    $p.WaitForExit()
    return $p.Id
}

# Case 1: lock owned by a DEAD pid is reclaimed immediately (age < 10 min) and backlog pushed.
#   This is the killed-SessionEnd -> immediate-next-SessionStart self-heal scenario.
$w = New-TestRepo 'case1'
Add-LocalCommit $w
$lock = Join-Path $w '.git\.config-sync.lock'
New-Item -ItemType Directory -Path $lock | Out-Null
Set-Content (Join-Path $lock 'pid') (Get-DeadPid)
Invoke-Hook $w 'start' | Out-Null
Assert 'case1: dead-pid lock reclaimed -> backlog pushed (ahead=0)' ((Get-Ahead $w) -eq 0)
Assert 'case1: lock removed after run' (-not (Test-Path $lock))

# Case 2: lock owned by a LIVE pid is respected (skip: no push, lock intact).
$w = New-TestRepo 'case2'
Add-LocalCommit $w
$lock = Join-Path $w '.git\.config-sync.lock'
New-Item -ItemType Directory -Path $lock | Out-Null
$sleeper = Start-Process powershell -ArgumentList '-NoProfile', '-Command', 'Start-Sleep 60' -PassThru -WindowStyle Hidden
Set-Content (Join-Path $lock 'pid') $sleeper.Id
Invoke-Hook $w 'start' | Out-Null
Assert 'case2: live-pid lock respected -> no push (ahead=1)' ((Get-Ahead $w) -eq 1)
Assert 'case2: lock still present' (Test-Path $lock)
Stop-Process -Id $sleeper.Id -Force

# Case 3: legacy lock without pid file, older than 10 min -> reclaimed (age fallback kept).
$w = New-TestRepo 'case3'
Add-LocalCommit $w
$lock = Join-Path $w '.git\.config-sync.lock'
New-Item -ItemType Directory -Path $lock | Out-Null
(Get-Item $lock).CreationTime = (Get-Date).AddMinutes(-15)
Invoke-Hook $w 'start' | Out-Null
Assert 'case3: old no-pid lock reclaimed -> backlog pushed (ahead=0)' ((Get-Ahead $w) -eq 0)

# Case 4: legacy lock without pid file, fresh (<10 min) -> respected (no over-aggressive reclaim).
$w = New-TestRepo 'case4'
Add-LocalCommit $w
$lock = Join-Path $w '.git\.config-sync.lock'
New-Item -ItemType Directory -Path $lock | Out-Null
Invoke-Hook $w 'start' | Out-Null
Assert 'case4: fresh no-pid lock respected -> no push (ahead=1)' ((Get-Ahead $w) -eq 1)

# Case 5: self-heal push cannot reach remote -> stalled-backup warning is emitted, once.
$w = New-TestRepo 'case5'
Add-LocalCommit $w
git -C $w remote set-url origin (Join-Path $tmp 'no-such-remote.git') *> $null
$out = Invoke-Hook $w 'start'
Assert 'case5: stalled backup emits warning line' ($out -match 'claude-config:')
Assert 'case5: still ahead (push impossible)' ((Get-Ahead $w) -eq 1)

# Case 6: end mode commits dirty tree, pushes, and cleans the lock.
$w = New-TestRepo 'case6'
Add-Content (Join-Path $w 'f.txt') 'dirty'
Invoke-Hook $w 'end' | Out-Null
Assert 'case6: end mode committed (clean tree)' (-not (git -C $w status --porcelain))
Assert 'case6: end mode pushed (ahead=0)' ((Get-Ahead $w) -eq 0)
Assert 'case6: lock cleaned up' (-not (Test-Path (Join-Path $w '.git\.config-sync.lock')))

# Cases 7-8: work-autosync twin carries the same PID-liveness lock fix.
$hookW = Join-Path $root 'claude\hooks\work-autosync.ps1'
function Invoke-HookW([string]$work, [string]$mode) {
    Push-Location $work
    $o = (& powershell -NoProfile -ExecutionPolicy Bypass -File $hookW -Mode $mode 2>&1 | Out-String)
    Pop-Location
    return $o
}

# Case 7: work-autosync dead-pid lock reclaimed immediately -> backlog pushed.
$w = New-TestRepo 'case7'
Set-Content (Join-Path $w '.claude-autosync') ''
Add-LocalCommit $w
$lock = Join-Path $w '.git\.work-autosync.lock'
New-Item -ItemType Directory -Path $lock | Out-Null
Set-Content (Join-Path $lock 'pid') (Get-DeadPid)
Invoke-HookW $w 'start' | Out-Null
Assert 'case7: work-autosync dead-pid lock reclaimed -> pushed (ahead=0)' ((Get-Ahead $w) -eq 0)
Assert 'case7: work-autosync lock removed' (-not (Test-Path $lock))

# Case 8: work-autosync live-pid lock respected (skip).
$w = New-TestRepo 'case8'
Set-Content (Join-Path $w '.claude-autosync') ''
Add-LocalCommit $w
$lock = Join-Path $w '.git\.work-autosync.lock'
New-Item -ItemType Directory -Path $lock | Out-Null
$sleeper = Start-Process powershell -ArgumentList '-NoProfile', '-Command', 'Start-Sleep 60' -PassThru -WindowStyle Hidden
Set-Content (Join-Path $lock 'pid') $sleeper.Id
Invoke-HookW $w 'start' | Out-Null
Assert 'case8: work-autosync live-pid lock respected -> no push (ahead=1)' ((Get-Ahead $w) -eq 1)
Stop-Process -Id $sleeper.Id -Force

Remove-Item $tmp -Recurse -Force
$verdict = 'FAIL'; if ($script:fail -eq 0) { $verdict = 'ALL-OK' }
Write-Output ('RESULT: pass=' + $script:pass + ' fail=' + $script:fail + ' ' + $verdict)
if ($script:fail -gt 0) { exit 1 }
exit 0
