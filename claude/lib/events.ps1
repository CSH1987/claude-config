# claude-config:events (Windows) - PowerShell mirror of events.sh.
#   Appends one SCHEMA.md section-3 event line to events/<machineId>.jsonl
#   (plan v9 shared instrument / v10 T1-G4 growth-loop measurement backbone).
#
# Principles (mirror of the .sh + existing hooks):
#   - Deterministic, model-independent. Path via resolver (memdir.ps1) only; never hardcode.
#   - FAIL-OPEN: on ANY error it stays silent and exits 0 (never blocks a hook/session).
#   - machineId = _resolver-manifest.json machine_id > $env:COMPUTERNAME > 'unknown'.
#   - Overrides: -Set 'key=value' (dotted keys, e.g. backup.result, counts.skills) AND/OR
#     newline-separated $env:EV_OVERRIDES. Value parsed as true/false/int/null else string.
#   - Output JSONL written UTF-8 (no BOM), LF line ending (consistent with events.sh).
#
# Encoding: this body is pure ASCII (no non-ASCII) -> safe with BOM-less PS 5.1 ANSI decode,
# exactly like memory-inject.ps1 / effort-reminder.ps1.
param(
    [string]$Type = 'task',
    [string[]]$Set = @(),
    [switch]$DebugMsg
)
$ErrorActionPreference = 'SilentlyContinue'
function Dbg($m) { if ($DebugMsg) { [Console]::Error.WriteLine("events.ps1: $m") } }

try {
    # --- 1) resolve memdir (resolver = single source of truth) ---
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
    if (-not $memDir) { Dbg 'cannot resolve CLAUDE_MEMORY_DIR'; exit 0 }

    # --- 2) machineId: manifest > COMPUTERNAME > unknown ---
    $machineId = $env:COMPUTERNAME
    if (-not $machineId) { $machineId = 'unknown' }
    $manifest = Join-Path $memDir '_resolver-manifest.json'
    if (Test-Path $manifest) {
        try {
            $mraw = [System.IO.File]::ReadAllText($manifest, (New-Object System.Text.UTF8Encoding($false)))
            $m = $mraw | ConvertFrom-Json
            if ($m.machine_id) { $machineId = [string]$m.machine_id }
        } catch {}
    }
    $safe = ($machineId -replace '[^A-Za-z0-9._-]', '_')
    if (-not $safe) { $safe = 'unknown' }

    # --- 3) deterministic context ---
    $ts = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $sess = $env:CLAUDE_SESSION_ID
    $omc = $env:OMC_STATE_DIR
    $cwdRepo = $null
    try { $top = (& git rev-parse --show-toplevel 2>$null); if ($top) { $cwdRepo = @($top)[0] } } catch {}
    if (-not $cwdRepo) { $cwdRepo = (Get-Location).Path }

    # --- 4) SCHEMA.md section-3 full default skeleton (ordered for stable key order) ---
    $ev = [ordered]@{
        ts = $ts
        session_id = $(if ($sess) { $sess } else { $null })
        cwd_repo = $cwdRepo
        omc_state_dir = $(if ($omc) { $omc } else { $null })
        machine_id = $safe
        resolver_mode = 'local-env'
        runner_verified = $false
        type = $(if ($Type) { $Type } else { 'task' })
        skill_id = $null
        skill_reused = $false
        rework = $false
        rework_anchor = $null
        recall_query = $null
        recall_hit = $false
        recall_anchor = $null
        recall_source = 'decisions'
        reask_count = 0
        anchor_reinject_count = 0
        label_n = 0
        gate_suspended = $true
        degraded_to_proxy = $false
        decision_writer = $null
        pending_age_days = $null
        outcome = $null        # success|fail|partial|null - 산출물 결과(선택)
        duration_ms = $null    # 작업/세션 소요(ms)
        token_cost = $null     # 토큰 비용(알 때)
        user_rating = $null    # 1-5 사용자 품질 평가(선택; claude-rate)
        counts = [ordered]@{ skills = 0; wiki = 0; profile_keys = 0; digest_files = 0 }
        backup = [ordered]@{
            result = 'skip'; sha = $null; ahead_count = 0; last_snapshot_ts = $null
            actions_minutes_left = $null; actions_budget_used = $null; ratelimit_headroom = $null
            token_days_left = $null; reason = $null
        }
    }

    # --- 5) overrides: -Set array + $env:EV_OVERRIDES (newline-separated) ---
    $allSets = @()
    if ($Set) { $allSets += $Set }
    if ($env:EV_OVERRIDES) { $allSets += ($env:EV_OVERRIDES -split "`n") }

    foreach ($pair in $allSets) {
        if (-not $pair) { continue }
        if ($pair -notmatch '=') { continue }
        $idx = $pair.IndexOf('=')
        $k = $pair.Substring(0, $idx).Trim()
        $raw = $pair.Substring($idx + 1).Trim()
        if (-not $k) { continue }
        $val = $raw
        if ($raw -eq 'true') { $val = $true }
        elseif ($raw -eq 'false') { $val = $false }
        elseif ($raw -eq 'null') { $val = $null }
        elseif ($raw -match '^-?\d+$') { $val = [int]$raw }
        $parts = $k -split '\.'
        if ($parts.Count -eq 1) {
            $ev[$parts[0]] = $val
        } else {
            if (-not ($ev[$parts[0]] -is [System.Collections.IDictionary])) { $ev[$parts[0]] = [ordered]@{} }
            $ev[$parts[0]][$parts[1]] = $val
        }
    }

    # --- 6) append one compact JSON line (UTF-8 no BOM, LF) ---
    $edir = Join-Path $memDir 'events'
    if (-not (Test-Path $edir)) { New-Item -ItemType Directory -Path $edir -Force -ErrorAction SilentlyContinue | Out-Null }
    $path = Join-Path $edir ($safe + '.jsonl')
    $json = $ev | ConvertTo-Json -Depth 6 -Compress
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::AppendAllText($path, $json + "`n", $enc)
    Dbg "appended type=$($ev.type) -> $path"
} catch {
    Dbg "error: $_"
}
exit 0
