# Claude dotfiles 설치 (Windows) — 이 머신의 모든 폴더·세션에서 Harness 자동.
$ErrorActionPreference = 'Stop'
$dot   = Split-Path -Parent $MyInvocation.MyCommand.Definition
$dst   = Join-Path $env:USERPROFILE '.claude'
$hooks = Join-Path $dst 'hooks'
New-Item -ItemType Directory -Force -Path $hooks | Out-Null

# 훅 복사 (Windows는 심볼릭 링크가 관리자 권한을 요구하므로 복사 방식)
Copy-Item (Join-Path $dot 'claude\hooks\ensure-harness.ps1') (Join-Path $hooks 'ensure-harness.ps1') -Force
Write-Host '  ✓ hook copied'

# PSCustomObject(ConvertFrom-Json 결과)를 깊은 해시테이블로 변환 — 머지/쓰기를 위해.
# (PS 5.1엔 ConvertFrom-Json -AsHashtable 이 없어 직접 변환)
function ConvertTo-HashtableDeep($o) {
    if ($null -eq $o) { return $null }
    if ($o -is [System.Collections.IDictionary]) {
        $h = @{}; foreach ($k in $o.Keys) { $h[$k] = ConvertTo-HashtableDeep $o[$k] }; return $h
    }
    if ($o -is [PSCustomObject]) {
        $h = @{}; foreach ($p in $o.PSObject.Properties) { $h[$p.Name] = ConvertTo-HashtableDeep $p.Value }; return $h
    }
    if (($o -is [System.Collections.IEnumerable]) -and ($o -isnot [string])) {
        return @($o | ForEach-Object { ConvertTo-HashtableDeep $_ })
    }
    return $o
}

# settings.json 머지 (기존 키 보존 — 다른 플러그인/마켓/훅을 덮어쓰지 않음)
$settingsPath = Join-Path $dst 'settings.json'
if (Test-Path $settingsPath) {
    Copy-Item $settingsPath "$settingsPath.bak.$([int](Get-Date -UFormat %s))" -Force
    $s = ConvertTo-HashtableDeep (Get-Content $settingsPath -Raw | ConvertFrom-Json)
    if ($null -eq $s) { $s = @{} }
} else {
    $s = @{}
}

# 마켓플레이스 — 기존 보존, harness 항목만 추가/갱신
if (-not ($s['extraKnownMarketplaces'] -is [hashtable])) { $s['extraKnownMarketplaces'] = @{} }
$s['extraKnownMarketplaces']['harness-marketplace'] = @{ source = @{ source = 'github'; repo = 'revfactory/harness' } }
# 플러그인 — 기존 보존, harness만 추가
if (-not ($s['enabledPlugins'] -is [hashtable])) { $s['enabledPlugins'] = @{} }
$s['enabledPlugins']['harness@harness-marketplace'] = $true
# 훅 (절대 경로로 기록 — Windows 환경변수 확장 이슈 회피) — 기존 훅 보존, 중복일 때만 skip
$hookFile = Join-Path $hooks 'ensure-harness.ps1'
$hookCmd  = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$hookFile`""
if (-not ($s['hooks'] -is [hashtable])) { $s['hooks'] = @{} }
$ss = @($s['hooks']['SessionStart'])
$already = $false
foreach ($grp in $ss) {
    if ($grp -is [hashtable]) {
        foreach ($h in @($grp['hooks'])) {
            if (($h -is [hashtable]) -and ($h['command'] -eq $hookCmd)) { $already = $true }
        }
    }
}
if (-not $already) { $ss += @{ hooks = @(@{ type = 'command'; command = $hookCmd }) } }
$s['hooks']['SessionStart'] = $ss

# UTF-8 (BOM 없이) 로 기록 — Set-Content -Encoding UTF8 이 PS5.1에서 BOM을 붙이는 문제 회피
$jsonOut = ($s | ConvertTo-Json -Depth 20)
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
