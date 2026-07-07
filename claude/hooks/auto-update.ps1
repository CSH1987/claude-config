# claude-config:auto-update (Windows) - SessionStart hook. Keeps session-related
#   components (Claude Code plugins + pwsh/node/gh/git runtimes) on latest, SAFELY.
#   Thin wrapper -> shared lib/auto-update.py engine (parity with auto-update.sh).
#   Fast path only; the once/day update runs as a DETACHED probe, so session start never waits.
#   Off: CLAUDE_NO_AUTO_UPDATE=1 or pin file ~/.claude/auto-update/pin. FAIL-OPEN.
#   stdout (if any) = SessionStart additionalContext (update notice). ASCII no-BOM (PS 5.1 safe).
$ErrorActionPreference = 'SilentlyContinue'
if ($env:CLAUDE_NO_AUTO_UPDATE -eq '1') { exit 0 }

try {
    $py = Join-Path $env:USERPROFILE '.claude\lib\auto-update.py'
    if (-not (Test-Path $py)) {
        $here = $PSScriptRoot
        if (-not $here) { $here = Split-Path -Parent $MyInvocation.MyCommand.Path }
        $py = Join-Path $here '..\lib\auto-update.py'
    }
    if (-not (Test-Path $py)) { exit 0 }

    $py3 = (Get-Command python3 -ErrorAction SilentlyContinue)
    if (-not $py3) { $py3 = (Get-Command python -ErrorAction SilentlyContinue) }
    if (-not $py3) { exit 0 }
    & $py3.Source $py start 2>$null
} catch {}
exit 0
