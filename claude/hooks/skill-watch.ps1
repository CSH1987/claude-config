# claude-config:skill-watch (Windows) - SessionStart hook. Weekly background scan
#   for Claude Skills relevant to this user's actual repos/domains, filtered
#   through a verification gate (official source, or real GitHub stars + recent
#   maintenance). Thin wrapper -> shared lib/skill-watch.py engine (parity with
#   skill-watch.sh). Fast path only; the actual once/week scan runs as a
#   DETACHED probe, so session start never waits. NEVER installs anything -
#   proposal only, user approves.
#   Kill-switch: CLAUDE_SKILL_WATCH_OFF=1 or pin file ~/.claude/skill-watch/pin.
#   FAIL-OPEN. stdout (if any) = SessionStart additionalContext (candidate list).
#   ASCII no-BOM (PS 5.1 safe).
$ErrorActionPreference = 'SilentlyContinue'
if ($env:CLAUDE_SKILL_WATCH_OFF -eq '1') { exit 0 }

try {
    $py = Join-Path $env:USERPROFILE '.claude\lib\skill-watch.py'
    if (-not (Test-Path $py)) {
        $here = $PSScriptRoot
        if (-not $here) { $here = Split-Path -Parent $MyInvocation.MyCommand.Path }
        $py = Join-Path $here '..\lib\skill-watch.py'
    }
    if (-not (Test-Path $py)) { exit 0 }

    $py3 = (Get-Command python3 -ErrorAction SilentlyContinue)
    if (-not $py3) { $py3 = (Get-Command python -ErrorAction SilentlyContinue) }
    if (-not $py3) { exit 0 }
    & $py3.Source $py start 2>$null
} catch {}
exit 0
