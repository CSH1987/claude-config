# claude-config:stop-metrics (Windows) - PowerShell mirror of stop-metrics.sh.
#   Stop hook: detects file-level rework (a file edited in THIS session that a DIFFERENT prior
#   session also edited) and records a task event with rework=true via events.ps1
#   (plan v9 section 2 / recall-budget.md section 4).
#
# Honesty (M5):
#   - file-level heuristic only (NOT symbol-level). rework_anchor=file:<path>.
#   - precision/recall gate stays suspended until N>=30 (signal, not truth; recall-budget.md section 5).
#   - recall_hit / reask_count are NOT filled here - recall skill / hand-labeling do (section 4/7).
#
# Principles: deterministic, model-independent, FAIL-OPEN (any error -> exit 0). Kill: CLAUDE_EVENTS_OFF=1.
#   Cross-session tracking via $OMC_STATE_DIR/edit-history.json (path -> last_session); gitignored.
#   TODO(v2): TTL/cap for edit-history.json + GC for orphan edit-track/ shards (currently unbounded). + window/diff.
#   Pure ASCII body (BOM-less PS 5.1 safe).
$ErrorActionPreference = 'SilentlyContinue'
if ($env:CLAUDE_EVENTS_OFF -eq '1') { exit 0 }
try {
    $raw = [Console]::In.ReadToEnd()
    $sess = $null
    if ($raw) { try { $sess = [string]($raw | ConvertFrom-Json).session_id } catch {} }
    if (-not $sess) { $sess = $env:CLAUDE_SESSION_ID }
    if (-not $sess) { $sess = 'nosession' }
    $safe = ($sess -replace '[^A-Za-z0-9._-]', '_'); if (-not $safe) { $safe = 'nosession' }

    # --- events.ps1 location: deployed (~/.claude/lib) > repo-relative ---
    $lib = Join-Path $env:USERPROFILE '.claude\lib\events.ps1'
    if (-not (Test-Path $lib)) { $lib = Join-Path $PSScriptRoot '..\lib\events.ps1' }
    if (-not (Test-Path $lib)) { exit 0 }

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

    $track = Join-Path (Join-Path $omc 'edit-track') ($safe + '.jsonl')
    if (-not (Test-Path $track)) { exit 0 }

    # this session's unique edited paths
    $edited = New-Object System.Collections.Generic.List[string]
    $seen = @{}
    foreach ($ln in [System.IO.File]::ReadAllLines($track)) {
        $t = $ln.Trim(); if (-not $t) { continue }
        try { $o = $t | ConvertFrom-Json } catch { continue }
        $fp = [string]$o.path
        if ($fp -and -not $seen.ContainsKey($fp)) { $seen[$fp] = $true; $edited.Add($fp) }
    }
    if ($edited.Count -eq 0) { exit 0 }

    # history load (path -> last_session)
    $hpath = Join-Path $omc 'edit-history.json'
    $hist = @{}
    if (Test-Path $hpath) {
        try {
            $hraw = [System.IO.File]::ReadAllText($hpath, (New-Object System.Text.UTF8Encoding($false)))
            if ($hraw -and $hraw.Trim()) {
                $ho = $hraw | ConvertFrom-Json
                foreach ($pr in $ho.PSObject.Properties) { $hist[$pr.Name] = [string]$pr.Value }
            }
        } catch { $hist = @{} }
    }

    # rework = edited file previously edited by a DIFFERENT session (file-level)
    $rework = @()
    foreach ($fp in $edited) { if ($hist.ContainsKey($fp) -and $hist[$fp] -ne $sess) { $rework += $fp } }

    # update history: all edited -> current session (prevents re-detection within same session)
    foreach ($fp in $edited) { $hist[$fp] = $sess }
    try {
        $obj = [ordered]@{}
        foreach ($k in $hist.Keys) { $obj[$k] = $hist[$k] }
        $jsonH = ($obj | ConvertTo-Json -Compress)
        if (-not $jsonH) { $jsonH = '{}' }
        $tmpH = "$hpath.tmp"
        [System.IO.File]::WriteAllText($tmpH, $jsonH, (New-Object System.Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $tmpH -Destination $hpath -Force   # atomic replace on same FS (concurrent-Stop safe)
    } catch {}

    # truncate track (processed -> next Stop sees only later edits; prevents bloat/duplication)
    try { [System.IO.File]::WriteAllText($track, '', (New-Object System.Text.UTF8Encoding($false))) } catch {}

    # emit one rework task event per reworked file (gate_suspended stays events default = true)
    foreach ($fp in $rework) {
        & $lib -Type task -Set @('rework=true', "rework_anchor=file:$fp") 2>$null | Out-Null
    }
} catch {}
exit 0
