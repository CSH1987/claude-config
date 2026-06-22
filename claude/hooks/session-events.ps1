# claude-config:session-events (Windows) - PowerShell mirror of session-events.sh.
#   SessionEnd hook: records one "growth snapshot" event per session
#   (deep-interview AC#4: memory/skill/wiki entry growth tracking; v10 T1 growth-loop measurement).
#   Deterministic, FAIL-OPEN (never blocks a session). Kill-switch: CLAUDE_EVENTS_OFF=1.
#   Calls events.ps1 (shared instrument) with counts overrides.
#   Pure ASCII body (BOM-less PS 5.1 safe). --debug echoes counts to stderr.
$ErrorActionPreference = 'SilentlyContinue'
if ($env:CLAUDE_EVENTS_OFF -eq '1') { exit 0 }
$dbg = ($args -contains '--debug')

try {
    # --- events.ps1 location: deployed (~/.claude/lib) > repo-relative ---
    $lib = Join-Path $env:USERPROFILE '.claude\lib\events.ps1'
    if (-not (Test-Path $lib)) { $lib = Join-Path $PSScriptRoot '..\lib\events.ps1' }
    if (-not (Test-Path $lib)) { exit 0 }

    # --- resolve memdir (resolver = single source of truth) ---
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

    # --- deterministic counts (failure -> 0) ---
    # profile_keys: non-meta top-level keys in profile/user-profile.json
    $pk = 0
    $prof = Join-Path (Join-Path $memDir 'profile') 'user-profile.json'
    if (Test-Path $prof) {
        try {
            $raw = [System.IO.File]::ReadAllText($prof, (New-Object System.Text.UTF8Encoding($false)))
            if ($raw -and $raw.Trim()) {
                $o = $raw | ConvertFrom-Json
                $meta = @('schema_version', 'updated_at', 'updated_by')
                foreach ($p in $o.PSObject.Properties) { if ($meta -notcontains $p.Name) { $pk++ } }
            }
        } catch { $pk = 0 }
    }

    # digest_files: cloud-digest/*.md count
    $df = 0
    $cd = Join-Path $memDir 'cloud-digest'
    if (Test-Path $cd) { $df = @(Get-ChildItem -Path $cd -Filter '*.md' -File -ErrorAction SilentlyContinue).Count }

    if ($dbg) {
        $dc = 0
        $dd = Join-Path $memDir 'decisions'
        if (Test-Path $dd) { $dc = @(Get-ChildItem -Path $dd -Filter '*.md' -File -Recurse -ErrorAction SilentlyContinue).Count }
        [Console]::Error.WriteLine("session-events.ps1: profile_keys=$pk digest_files=$df decisions=$dc memdir=$memDir")
    }

    # --- append snapshot via events.ps1 (native call passes the array correctly) ---
    $setArr = @("counts.profile_keys=$pk", "counts.digest_files=$df")
    if ($dbg) { & $lib -Type snapshot -Set $setArr -DebugMsg }
    else { & $lib -Type snapshot -Set $setArr }
} catch {}
exit 0
