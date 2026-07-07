# hermes-sync: claude-config 규칙을 hermes-agent(~/.hermes)에 자동 적용
# - AGENTS.md에 마커 블록으로 portable-rules를 삽입/갱신 (hermes 자체 내용은 보존)
# - 이식 가능한 스킬(workload-optimization)을 hermes skills 디렉터리로 복사
# - hermes 미설치 시 무동작(exit 0) → SessionStart 체인에 안전하게 상주 가능
param(
    [string]$HermesDir = "",
    [string]$SourceDir = "$HOME\.claude"
)

if (-not $HermesDir) {
    foreach ($cand in @("$HOME\.hermes", "$env:LOCALAPPDATA\hermes")) {
        if ($cand -and (Test-Path $cand)) { $HermesDir = $cand; break }
    }
}
if (-not $HermesDir -or -not (Test-Path $HermesDir)) { exit 0 }

$rulesFile = Join-Path $SourceDir "exports\portable-rules.md"
if (-not (Test-Path $rulesFile)) { exit 0 }

# PS 5.1 호환: 인코딩을 .NET IO로 명시(BOM 유무와 무관하게 UTF-8), 개행 정규화로 멱등성 보장
$utf8Read  = [System.Text.UTF8Encoding]::new($false)
$utf8Write = [System.Text.UTF8Encoding]::new($true)

$startMarker = "<!-- claude-config:portable-rules:start -->"
$endMarker   = "<!-- claude-config:portable-rules:end -->"
$rules = [System.IO.File]::ReadAllText($rulesFile, $utf8Read).TrimEnd()
$block = "$startMarker`n$rules`n$endMarker"

$agentsMd = Join-Path $HermesDir "AGENTS.md"
if (Test-Path $agentsMd) {
    $existing = [System.IO.File]::ReadAllText($agentsMd, $utf8Read)
    $i = $existing.IndexOf($startMarker)
    $j = $existing.IndexOf($endMarker)
    if ($i -ge 0 -and $j -gt $i) {
        $updated = $existing.Substring(0, $i) + $block + $existing.Substring($j + $endMarker.Length)
    } else {
        $updated = $existing.TrimEnd() + "`n`n" + $block
    }
} else {
    $updated = $block
}
$updated = $updated.TrimEnd() + "`n"
[System.IO.File]::WriteAllText($agentsMd, $updated, $utf8Write)

$skillSrc = Join-Path $SourceDir "skills\workload-optimization"
if (Test-Path $skillSrc) {
    $skillDst = Join-Path $HermesDir "skills\workload-optimization"
    New-Item -ItemType Directory -Force $skillDst | Out-Null
    Copy-Item "$skillSrc\*" $skillDst -Recurse -Force
}

Write-Output "hermes-sync: rules applied to $HermesDir"
exit 0
