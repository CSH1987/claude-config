# claude-config:statusline (Windows) - PowerShell mirror of statusline.sh.
#   Always-on context-usage display via the official statusLine feature.
#   used_percentage is precomputed by Claude Code itself (input tokens only, output excluded - confirmed via docs).
#   50/60/90% color bands match workload-optimization skill Sec.2 thresholds.
#   Side effect: caches used_percentage per session_id so the Stop hook (context-notify.ps1) can reuse it
#   (hook input has no context_window field - confirmed - statusline is the only source).
#   Principle: FAIL-OPEN - any parse error still prints a minimal line.
#   Pure ASCII body (BOM-less PS 5.1 safe) - no literal non-ASCII text in this file.
$ErrorActionPreference = 'SilentlyContinue'
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch {}  # PS 5.1 defaults stdout to the system codepage; guards non-ASCII dir/branch names
try {
    $raw = [Console]::In.ReadToEnd()
    if (-not $raw) { Write-Output 'claude'; exit 0 }
    $j = $null
    try { $j = $raw | ConvertFrom-Json } catch {}
    if (-not $j) { Write-Output 'claude'; exit 0 }

    $model = 'claude'
    if ($j.model -and $j.model.display_name) { $model = [string]$j.model.display_name }
    $dir = ''
    if ($j.workspace -and $j.workspace.current_dir) { $dir = [string]$j.workspace.current_dir }
    $dirName = if ($dir) { Split-Path -Leaf $dir } else { '' }
    $sessionId = [string]$j.session_id
    $pct = $null
    if ($j.context_window -and ($null -ne $j.context_window.used_percentage)) { $pct = $j.context_window.used_percentage }
    $cost = $null
    if ($j.cost -and ($null -ne $j.cost.total_cost_usd)) { $cost = $j.cost.total_cost_usd }

    $branch = ''
    if ($dir -and (Get-Command git -ErrorAction SilentlyContinue)) {
        try { $branch = (& git -C $dir branch --show-current 2>$null); $branch = [string]$branch } catch {}
    }

    $ic = [System.Globalization.CultureInfo]::InvariantCulture
    $pctInt = $null
    $pctStr = $null
    if ($null -ne $pct) {
        try { $pctInt = [int][math]::Floor([double]$pct) } catch {}
        try { $pctStr = ([double]$pct).ToString($ic) } catch { $pctStr = [string]$pct }
    }

    # --- cache for the Stop hook (it cannot read context_window itself) ---
    # written only when pct parsed cleanly (validate-before-write, mirrors statusline.sh)
    if ($sessionId -and ($null -ne $pctStr)) {
        $safeId = ($sessionId -replace '[^A-Za-z0-9._-]', '_')  # matches repo convention (edit-track.ps1 etc.)
        $cacheDir = Join-Path $env:USERPROFILE '.claude\state\context-pct'
        if (-not (Test-Path $cacheDir)) { New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null }
        Get-ChildItem $cacheDir -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-3) } | Remove-Item -Force -ErrorAction SilentlyContinue
        $cacheFile = Join-Path $cacheDir "$safeId.json"
        $tmpFile = "$cacheFile.tmp.$PID"
        "{`"used_percentage`":$pctStr}" | Out-File -FilePath $tmpFile -Encoding ascii -Force
        Move-Item -LiteralPath $tmpFile -Destination $cacheFile -Force  # atomic-ish replace, mirrors stop-metrics.ps1
    }

    $esc = [char]27
    $color = "$esc[32m"  # green (<50%)
    if ($null -ne $pctInt) {
        if     ($pctInt -ge 90) { $color = "$esc[1;31m" }  # bold red
        elseif ($pctInt -ge 60) { $color = "$esc[33m" }    # orange
        elseif ($pctInt -ge 50) { $color = "$esc[93m" }    # yellow
    }
    $reset = "$esc[0m"

    $costDisp = $null
    if ($null -ne $cost) {
        try { $costDisp = ([double]$cost).ToString('F2', $ic) } catch { $costDisp = [string]$cost }
    }

    $line = "[$model] $dirName"
    if ($branch) { $line = "$line ($branch)" }
    if ($null -ne $pctStr) { $line = "$line | $color$pctStr% ctx$reset" } else { $line = "$line | ctx?" }
    if ($null -ne $costDisp) { $line = "$line | `$$costDisp" }

    Write-Output $line
} catch {
    Write-Output 'claude'
}
exit 0
