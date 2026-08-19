# claude-config:context-notify (Windows) - PowerShell mirror of context-notify.sh.
#   Stop hook. Reads the used_percentage cached by statusline.ps1 and fires a one-shot systemMessage
#   only on an UPWARD crossing of 50% / 90% (not on every turn while inside a tier).
#   State machine: the stored tier always mirrors the LAST computed tier - rising fires+stores,
#   falling (e.g. /compact landing at 55%) silently demotes so the next rise re-fires. Only resetting
#   on drop-to-zero left a gap where 90%->(compact)->55%->92% never re-notified - fixed here.
#   FAIL-OPEN: no cache (statusline disabled/not yet run) -> silent exit.
#   Contains literal Korean text -> saved with a UTF-8 BOM (required for Windows PowerShell 5.1 to
#   read it as UTF-8 instead of the system ANSI codepage; matches hermes-sync.ps1/config-sync.ps1).
$ErrorActionPreference = 'SilentlyContinue'
try {
    $raw = [Console]::In.ReadToEnd()
    if (-not $raw) { exit 0 }
    $j = $null
    try { $j = $raw | ConvertFrom-Json } catch {}
    if (-not $j -or -not $j.session_id) { exit 0 }
    $sessionId = ([string]$j.session_id) -replace '[^A-Za-z0-9._-]', '_'  # matches repo convention

    $cacheFile = Join-Path $env:USERPROFILE ".claude\state\context-pct\$sessionId.json"
    if (-not (Test-Path $cacheFile)) { exit 0 }
    $cache = $null
    try { $cache = (Get-Content $cacheFile -Raw) | ConvertFrom-Json } catch {}
    if (-not $cache -or ($null -eq $cache.used_percentage)) { exit 0 }
    $pctInt = $null
    try { $pctInt = [int][math]::Floor([double]$cache.used_percentage) } catch {}
    if ($null -eq $pctInt) { exit 0 }

    $stateDir = Join-Path $env:USERPROFILE '.claude\state\context-notified'
    if (-not (Test-Path $stateDir)) { New-Item -ItemType Directory -Force -Path $stateDir | Out-Null }
    Get-ChildItem $stateDir -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-3) } | Remove-Item -Force -ErrorAction SilentlyContinue
    $stateFile = Join-Path $stateDir $sessionId

    $lastTier = 0
    if (Test-Path $stateFile) {
        try { $lastTier = [int](Get-Content $stateFile -Raw).Trim() } catch { $lastTier = 0 }
    }

    $newTier = 0
    if     ($pctInt -ge 90) { $newTier = 90 }
    elseif ($pctInt -ge 50) { $newTier = 50 }

    function Write-TierState([int]$tier) {
        # atomic-ish replace (tmp + Move-Item -Force), mirrors stop-metrics.ps1's tmp+Move-Item pattern
        $tmp = "$stateFile.tmp.$PID"
        "$tier" | Out-File -FilePath $tmp -Encoding ascii -Force
        Move-Item -LiteralPath $tmp -Destination $stateFile -Force
    }

    if ($newTier -lt $lastTier) {
        Write-TierState $newTier
        exit 0
    }

    if ($newTier -gt $lastTier) {
        Write-TierState $newTier
        if ($newTier -eq 90) {
            $msg = "컨텍스트 ${pctInt}% 사용 — 정확도 저하 구간입니다. 지금 /clear 또는 /compact 를 권장합니다."
        } else {
            $msg = "컨텍스트 ${pctInt}% 사용 — 다음 작업으로 넘어갈 때 /clear(또는 /compact)를 고려하세요."
        }
        $out = @{ systemMessage = $msg } | ConvertTo-Json -Compress
        Write-Output $out
    }
} catch {}
exit 0
