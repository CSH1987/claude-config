# claude-config:morning-brief (Windows) - SessionStart hook. Once/day "morning brief":
#   surface (via Claude's context) what the user may have forgotten. Thin wrapper -> shared
#   brief.py engine (parity with morning-brief.sh). Deterministic, FAIL-OPEN, throttled in brief.py.
#   Kill-switch: CLAUDE_EVENTS_OFF=1. stdout (if any) = SessionStart additionalContext JSON.
#   ASCII no-BOM (PS 5.1 safe).
$ErrorActionPreference = 'SilentlyContinue'
if ($env:CLAUDE_EVENTS_OFF -eq '1') { exit 0 }
$dbg = ($args -contains '--debug')

try {
    $py = Join-Path $env:USERPROFILE '.claude\lib\brief.py'
    if (-not (Test-Path $py)) {
        $here = $PSScriptRoot
        if (-not $here) { $here = Split-Path -Parent $MyInvocation.MyCommand.Path }
        $py = Join-Path $here '..\lib\brief.py'
    }
    if (-not (Test-Path $py)) { exit 0 }

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

    $py3 = (Get-Command python3 -ErrorAction SilentlyContinue)
    if (-not $py3) { exit 0 }
    $today = (Get-Date).ToUniversalTime().ToString('yyyyMMdd')
    $d = if ($dbg) { '1' } else { '0' }
    if ($dbg) { & $py3.Source $py $memDir $today $d }
    else { & $py3.Source $py $memDir $today $d 2>$null }
} catch {}
exit 0
