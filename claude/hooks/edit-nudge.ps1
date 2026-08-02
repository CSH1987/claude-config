# claude-config:edit-nudge (Windows) - PowerShell mirror of edit-nudge.sh.
#   PostToolUse hook: if Edit/Write/MultiEdit accumulate past a threshold (default 6) since the
#   most recent Skill/Agent/Task/mcp__* tool call, inject a one-time additionalContext reminder
#   suggesting code-review or a domain expert agent before finishing large code changes.
#   (2026-07-14 session audit: 89-132 action code sessions had 0% extended-tool usage -> a
#   CLAUDE.md prose policy alone was not reliably followed, so this deterministic hook backs it up.)
#
# Principles (mirror of edit-track.ps1 + edit-nudge.sh):
#   - Deterministic, model-independent. Path via resolver (memdir.ps1) only; never hardcode.
#   - FAIL-OPEN: on ANY error it stays silent and exits 0 (never blocks a hook/session).
#   - Kill-switch: EDIT_NUDGE_OFF=1 (this hook) or CLAUDE_EVENTS_OFF=1 (shared with events).
#   - Pure ASCII body (BOM-less PS 5.1 safe), like edit-track.ps1 / effort-reminder.ps1.
#   - Not a hard block (warn/nudge only). Fires at most once per session until reset.
$ErrorActionPreference = 'SilentlyContinue'
if ($env:CLAUDE_EVENTS_OFF -eq '1') { exit 0 }
if ($env:EDIT_NUDGE_OFF -eq '1') { exit 0 }
try {
    $raw = [Console]::In.ReadToEnd()
    if (-not $raw) { exit 0 }
    # Pre-filter (perf): skip tools this hook does not care about before ConvertFrom-Json.
    if ($raw -notmatch '"tool_name"\s*:\s*"(Edit|Write|MultiEdit|NotebookEdit|Skill|Agent|Task|mcp__[^"]*)"') { exit 0 }
    $p = $raw | ConvertFrom-Json
    $tool = [string]$p.tool_name

    $editTools = @('Edit', 'Write', 'MultiEdit', 'NotebookEdit')
    $resetTools = @('Skill', 'Agent', 'Task')
    $isEdit = $editTools -contains $tool
    $isReset = ($resetTools -contains $tool) -or ($tool -like 'mcp__*')
    if (-not $isEdit -and -not $isReset) { exit 0 }

    $sess = [string]$p.session_id
    if (-not $sess) { $sess = $env:CLAUDE_SESSION_ID }
    if (-not $sess) { $sess = 'nosession' }
    $safe = ($sess -replace '[^A-Za-z0-9._-]', '_'); if (-not $safe) { $safe = 'nosession' }

    $threshold = 6
    if ($env:EDIT_NUDGE_THRESHOLD) {
        $parsed = 0
        if ([int]::TryParse($env:EDIT_NUDGE_THRESHOLD, [ref]$parsed)) { $threshold = $parsed }
    }

    # --- resolve OMC_STATE_DIR: env > memdir/omc-state (resolver), same as edit-track.ps1 ---
    $omc = $env:OMC_STATE_DIR
    if (-not $omc) {
        $memDir = $env:CLAUDE_MEMORY_DIR
        if (-not $memDir) {
            $resolver = Join-Path $env:USERPROFILE '.claude\lib\memdir.ps1'
            if (Test-Path $resolver) {
                $lines = & powershell -NoProfile -ExecutionPolicy Bypass -File $resolver -NoEnsure -Export 2>$null
                foreach ($ln in @($lines)) {
                    if ($ln -match "OMC_STATE_DIR\s*=\s*'(.*)'") { $omc = $Matches[1] }
                    elseif ($ln -match "CLAUDE_MEMORY_DIR\s*=\s*'(.*)'") { $memDir = $Matches[1] }
                }
            }
        }
        if (-not $omc -and $memDir) { $omc = Join-Path $memDir 'omc-state' }
    }
    if (-not $omc) { exit 0 }

    $d = Join-Path $omc 'edit-nudge'
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d -ErrorAction SilentlyContinue | Out-Null }
    $statePath = Join-Path $d ($safe + '.json')

    $count = 0
    $fired = $false
    if (Test-Path $statePath) {
        try {
            $loaded = Get-Content $statePath -Raw | ConvertFrom-Json
            if ($loaded.count) { $count = [int]$loaded.count }
            if ($loaded.fired) { $fired = [bool]$loaded.fired }
        } catch { $count = 0; $fired = $false }
    }

    if ($isReset) {
        $count = 0
        $fired = $false
    } elseif ($isEdit) {
        $count = $count + 1
    }

    $shouldNudge = $isEdit -and ($count -ge $threshold) -and (-not $fired)
    if ($shouldNudge) { $fired = $true }

    # Save state (best-effort; write then move stands in for atomic replace on Windows too).
    try {
        $tmp = $statePath + '.tmp'
        ([ordered]@{ count = $count; fired = $fired } | ConvertTo-Json -Compress) | Set-Content -Path $tmp -NoNewline -Encoding UTF8
        Move-Item -Path $tmp -Destination $statePath -Force
    } catch {}

    if ($shouldNudge) {
        $msg = "This session has accumulated $count code edits with no Skill/Agent/MCP tool call in between. " +
               "CLAUDE.md policy: for commits/production code changes, new feature builds, or root-cause debugging, " +
               "the larger the change, the more you should route through the code-review skill (or a relevant domain " +
               "expert agent) before finishing. (Not a hard requirement -- ignore if it does not fit. Shown once per session.)"
        $out = [ordered]@{
            hookSpecificOutput = [ordered]@{
                hookEventName    = 'PostToolUse'
                additionalContext = $msg
            }
        } | ConvertTo-Json -Compress -Depth 5
        [Console]::Out.Write($out)
    }
} catch {}
exit 0
