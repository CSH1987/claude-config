# claude-config:metrics (Windows) - derive PRIVATE metrics.md from events/*.jsonl union.
#   Thin wrapper: resolves memdir, delegates aggregation to the shared metrics.py engine
#   (cross-platform parity with metrics.sh). plan v9 0-J / v10 T1-G4 + G5.
#   Deterministic, FAIL-OPEN. Honors CLAUDE_EVENTS_OFF=1. ASCII no-BOM (PS 5.1 safe).
$ErrorActionPreference = 'SilentlyContinue'
if ($env:CLAUDE_EVENTS_OFF -eq '1') { exit 0 }
$dbg = ($args -contains '--debug')

try {
    $here = $PSScriptRoot
    if (-not $here) { $here = Split-Path -Parent $MyInvocation.MyCommand.Path }
    $py = Join-Path $here 'metrics.py'
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

    $warn = '0.30'
    if ($env:REWORK_WARN_RATE) { $warn = $env:REWORK_WARN_RATE }
    $d = if ($dbg) { '1' } else { '0' }

    # python3 is the shared engine (same .pyshim used by other hooks). Fail-open if absent.
    $py3 = (Get-Command python3 -ErrorAction SilentlyContinue)
    if (-not $py3) { exit 0 }
    & $py3.Source $py $memDir $warn $d 2>$null
} catch {}
exit 0
