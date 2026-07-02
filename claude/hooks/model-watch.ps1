# claude-config:model-watch (Windows) - SessionStart hook. Keeps `model` in
#   ~/.claude/settings.json on the newest frontier Claude model automatically
#   (e.g. jumps Opus->Fable when a new top family ships). Thin wrapper -> shared
#   lib/model-watch.py engine (parity with model-watch.sh). Fast path only; the
#   actual once/day detection runs as a DETACHED probe, so session start never waits.
#   Kill-switch: CLAUDE_MODEL_WATCH_OFF=1 or pin file ~/.claude/model-watch/pin.
#   FAIL-OPEN. stdout (if any) = SessionStart additionalContext (switch notice).
#   ASCII no-BOM (PS 5.1 safe).
$ErrorActionPreference = 'SilentlyContinue'
if ($env:CLAUDE_MODEL_WATCH_OFF -eq '1') { exit 0 }

try {
    $py = Join-Path $env:USERPROFILE '.claude\lib\model-watch.py'
    if (-not (Test-Path $py)) {
        $here = $PSScriptRoot
        if (-not $here) { $here = Split-Path -Parent $MyInvocation.MyCommand.Path }
        $py = Join-Path $here '..\lib\model-watch.py'
    }
    if (-not (Test-Path $py)) { exit 0 }

    $py3 = (Get-Command python3 -ErrorAction SilentlyContinue)
    if (-not $py3) { $py3 = (Get-Command python -ErrorAction SilentlyContinue) }
    if (-not $py3) { exit 0 }
    & $py3.Source $py start 2>$null
} catch {}
exit 0
