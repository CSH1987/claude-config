# Claude dotfiles 설치 (Windows) — 이 머신의 모든 폴더·세션에서 Harness 자동.
$ErrorActionPreference = 'Stop'
$dot   = Split-Path -Parent $MyInvocation.MyCommand.Definition
$dst   = Join-Path $env:USERPROFILE '.claude'
$hooks = Join-Path $dst 'hooks'
New-Item -ItemType Directory -Force -Path $hooks | Out-Null

# 훅 복사 (Windows는 심볼릭 링크가 관리자 권한을 요구하므로 복사 방식)
Copy-Item (Join-Path $dot 'claude\hooks\ensure-harness.ps1') (Join-Path $hooks 'ensure-harness.ps1') -Force
Write-Host '  ✓ hook copied'

# settings.json 머지 — 기존 키/구조를 충실히 보존.
# PS 5.1의 ConvertFrom/To-Json 은 "단일 요소 배열"을 객체로 붕괴시켜 hooks 배열을 깨뜨림.
# 이를 피하려고 배열을 그대로 보존하는 System.Web.Extensions(JavaScriptSerializer)로 파싱·직렬화.
Add-Type -AssemblyName System.Web.Extensions
$ser = New-Object System.Web.Script.Serialization.JavaScriptSerializer
$ser.MaxJsonLength = [int]::MaxValue

# 컴팩트 JSON 을 문자열 인지 방식으로 들여쓰기(파서 미사용 → 배열 안 깨짐).
function Format-Json([string]$json) {
    $sb = New-Object System.Text.StringBuilder
    $indent = 0; $inStr = $false; $esc = $false
    $pad = { param($n) '  ' * $n }
    for ($i = 0; $i -lt $json.Length; $i++) {
        $c = $json[$i]
        if ($inStr) {
            [void]$sb.Append($c)
            if ($esc) { $esc = $false } elseif ($c -eq '\') { $esc = $true } elseif ($c -eq '"') { $inStr = $false }
            continue
        }
        switch ($c) {
            '"' { $inStr = $true; [void]$sb.Append($c) }
            '{' { if ($i+1 -lt $json.Length -and $json[$i+1] -eq '}') { [void]$sb.Append('{}'); $i++ } else { $indent++; [void]$sb.Append("{`n" + (& $pad $indent)) } }
            '[' { if ($i+1 -lt $json.Length -and $json[$i+1] -eq ']') { [void]$sb.Append('[]'); $i++ } else { $indent++; [void]$sb.Append("[`n" + (& $pad $indent)) } }
            '}' { $indent--; [void]$sb.Append("`n" + (& $pad $indent) + '}') }
            ']' { $indent--; [void]$sb.Append("`n" + (& $pad $indent) + ']') }
            ',' { [void]$sb.Append(",`n" + (& $pad $indent)) }
            ':' { [void]$sb.Append(': ') }
            default { if ($c -notmatch '\s') { [void]$sb.Append($c) } }
        }
    }
    return $sb.ToString()
}

# 현재 dict[key] 가 사전(객체)이 아니면 빈 사전으로 만들고 그 참조를 돌려줌.
function Get-Dict($d, $k) {
    if (-not ($d[$k] -is [System.Collections.IDictionary])) { $d[$k] = @{} }
    return $d[$k]
}

$settingsPath = Join-Path $dst 'settings.json'
if (Test-Path $settingsPath) {
    Copy-Item $settingsPath "$settingsPath.bak.$([int](Get-Date -UFormat %s))" -Force
    $raw = Get-Content $settingsPath -Raw
    if ([string]::IsNullOrWhiteSpace($raw)) { $s = @{} } else { $s = $ser.DeserializeObject($raw) }
} else {
    $s = @{}
}
if ($s -isnot [System.Collections.IDictionary]) { $s = @{} }

# 마켓플레이스 — 기존 보존, harness 항목만 추가/갱신
(Get-Dict $s 'extraKnownMarketplaces')['harness-marketplace'] = @{ source = @{ source = 'github'; repo = 'revfactory/harness' } }
# 플러그인 — 기존 보존, harness만 추가
(Get-Dict $s 'enabledPlugins')['harness@harness-marketplace'] = $true
# 훅 (절대 경로 — Windows 환경변수 확장 이슈 회피) — 기존 훅 보존, 같은 명령 있으면 skip
$hookFile = Join-Path $hooks 'ensure-harness.ps1'
$hookCmd  = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$hookFile`""
$hk = Get-Dict $s 'hooks'
$ss = @($hk['SessionStart'])   # null→빈배열, 단일→배열로 정규화
$already = $false
foreach ($grp in $ss) {
    if ($grp -is [System.Collections.IDictionary]) {
        foreach ($h in @($grp['hooks'])) {
            if (($h -is [System.Collections.IDictionary]) -and ($h['command'] -eq $hookCmd)) { $already = $true }
        }
    }
}
if (-not $already) { $ss += @{ hooks = @(@{ type = 'command'; command = $hookCmd }) } }
$hk['SessionStart'] = $ss

# UTF-8(BOM 없이) 기록 — Set-Content -Encoding UTF8 이 PS5.1에서 BOM 붙이는 문제 회피
$jsonOut = Format-Json ($ser.Serialize($s))
[System.IO.File]::WriteAllText($settingsPath, $jsonOut + "`n", (New-Object System.Text.UTF8Encoding($false)))
Write-Host '  ✓ settings merged (기존 보존, 백업됨)'

# 즉시 설치
if (Get-Command claude -ErrorAction SilentlyContinue) {
    claude plugin marketplace add revfactory/harness  *> $null
    claude plugin install harness@harness-marketplace *> $null
    Write-Host '  ✓ harness installed'
    claude plugin list 2>$null | Select-String -Pattern 'harness|Status'
} else {
    Write-Host '  ℹ claude 미설치 — 다음 세션 훅이 설치'
}
Write-Host '✓ 완료. 이 머신 전체에서 Harness 자동.'
