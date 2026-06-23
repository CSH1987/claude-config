# claude-config:edit-track (Windows) - PowerShell mirror of edit-track.sh.
#   PostToolUse hook: records the edited file path of Edit/Write/MultiEdit/NotebookEdit into
#   $OMC_STATE_DIR/edit-track/<session>.jsonl so stop-metrics can detect file-level rework
#   (plan v9 section 2 rework signal / recall-budget.md section 4).
#
# Principles (mirror of the .sh + existing hooks):
#   - Deterministic, model-independent. Path via resolver (memdir.ps1) only; never hardcode.
#   - FAIL-OPEN: on ANY error it stays silent and exits 0 (never blocks a hook/session).
#   - Kill-switch: CLAUDE_EVENTS_OFF=1 (shared with events). omc-state is gitignored (safe for state).
#   - Pure ASCII body (BOM-less PS 5.1 safe), like memory-inject.ps1 / events.ps1.
$ErrorActionPreference = 'SilentlyContinue'
if ($env:CLAUDE_EVENTS_OFF -eq '1') { exit 0 }
try {
    $raw = [Console]::In.ReadToEnd()
    if (-not $raw) { exit 0 }
    # Pre-filter (perf): skip non-edit tools before ConvertFrom-Json (avoid parsing large
    # tool_response on every PostToolUse; the exact check below re-confirms after parse).
    if ($raw -notmatch '"tool_name"\s*:\s*"(Edit|Write|MultiEdit|NotebookEdit)"') { exit 0 }
    $p = $raw | ConvertFrom-Json
    $tool = [string]$p.tool_name
    if (@('Edit', 'Write', 'MultiEdit', 'NotebookEdit') -notcontains $tool) { exit 0 }
    $fp = $null
    if ($p.tool_input) {
        if ($p.tool_input.file_path) { $fp = [string]$p.tool_input.file_path }
        elseif ($p.tool_input.notebook_path) { $fp = [string]$p.tool_input.notebook_path }
    }
    if (-not $fp) { exit 0 }
    $sess = [string]$p.session_id
    if (-not $sess) { $sess = $env:CLAUDE_SESSION_ID }
    if (-not $sess) { $sess = 'nosession' }
    $safe = ($sess -replace '[^A-Za-z0-9._-]', '_'); if (-not $safe) { $safe = 'nosession' }

    # --- resolve OMC_STATE_DIR: env > memdir/omc-state (resolver) ---
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

    $d = Join-Path $omc 'edit-track'
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d -ErrorAction SilentlyContinue | Out-Null }
    $ts = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $line = ([ordered]@{ path = $fp; ts = $ts } | ConvertTo-Json -Compress)
    [System.IO.File]::AppendAllText((Join-Path $d ($safe + '.jsonl')), $line + "`n", (New-Object System.Text.UTF8Encoding($false)))
} catch {}
exit 0
