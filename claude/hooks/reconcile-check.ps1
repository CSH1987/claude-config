# claude-config:reconcile-check (Windows) - PowerShell mirror of reconcile-check.sh.
#   SessionStart hook: detect STALE _pending proposals (plan v9 0-G3 / v10 T1-G2 hop1).
#   If the oldest _pending\*\*.md is older than the threshold (default 7 days;
#   env RECONCILE_STALE_DAYS), emit a 'reconcile-stale' event via events.ps1.
#   Deterministic, FAIL-OPEN. Kill-switch: CLAUDE_EVENTS_OFF=1. ASCII no-BOM (PS 5.1 safe).
$ErrorActionPreference = 'SilentlyContinue'
if ($env:CLAUDE_EVENTS_OFF -eq '1') { exit 0 }
$dbg = ($args -contains '--debug')

try {
    $lib = Join-Path $env:USERPROFILE '.claude\lib\events.ps1'
    if (-not (Test-Path $lib)) { $lib = Join-Path $PSScriptRoot '..\lib\events.ps1' }
    if (-not (Test-Path $lib)) { exit 0 }

    $memDir = $env:CLAUDE_MEMORY_DIR
    if (-not $memDir) {
        $resolver = Join-Path $env:USERPROFILE '.claude\lib\memdir.ps1'
        if (Test-Path $resolver) {
            $lines = & powershell -NoProfile -ExecutionPolicy Bypass -File $resolver -NoEnsure -Export 2>$null
            foreach ($ln in @($lines)) {
                if ($ln -match "^\s*\`$env:CLAUDE_MEMORY_DIR\s*=\s*'(.*)'\s*$") { $memDir = $Matches[1] }
            }
        }
    }
    if (-not $memDir) { exit 0 }

    $thr = 7
    if ($env:RECONCILE_STALE_DAYS -match '^\d+$') { $thr = [int]$env:RECONCILE_STALE_DAYS }

    $count = 0; $age = 0
    $pend = Join-Path $memDir '_pending'
    if (Test-Path $pend) {
        $files = @(Get-ChildItem -Path $pend -Recurse -Filter *.md -File -ErrorAction SilentlyContinue)
        $count = $files.Count
        if ($count -gt 0) {
            $oldest = ($files | Sort-Object LastWriteTimeUtc | Select-Object -First 1).LastWriteTimeUtc
            $age = [int][math]::Floor((((Get-Date).ToUniversalTime()) - $oldest).TotalDays)
            if ($age -lt 0) { $age = 0 }
        }
    }

    if ($dbg) { [Console]::Error.WriteLine("reconcile-check.ps1: pending=$count oldest_age_days=$age threshold=$thr") }

    if ($count -gt 0 -and $age -ge $thr) {
        $setArr = @("backup.result=reconcile-stale", "pending_age_days=$age")
        if ($dbg) { & $lib -Type sync -Set $setArr -DebugMsg } else { & $lib -Type sync -Set $setArr }
    }
} catch {}
exit 0
