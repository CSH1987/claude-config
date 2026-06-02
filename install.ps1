# Claude dotfiles 설치 (Windows) — 이 머신의 모든 폴더·세션에서 Harness 자동.
$ErrorActionPreference = 'Stop'
$dot   = Split-Path -Parent $MyInvocation.MyCommand.Definition
$dst   = Join-Path $env:USERPROFILE '.claude'
$hooks = Join-Path $dst 'hooks'
New-Item -ItemType Directory -Force -Path $hooks | Out-Null

# 훅 복사 (Windows는 심볼릭 링크가 관리자 권한을 요구하므로 복사 방식)
Copy-Item (Join-Path $dot 'claude\hooks\ensure-harness.ps1') (Join-Path $hooks 'ensure-harness.ps1') -Force
Write-Host '  ✓ hook copied'

# settings.json 머지 (기존 보존)
$settingsPath = Join-Path $dst 'settings.json'
if (Test-Path $settingsPath) {
    Copy-Item $settingsPath "$settingsPath.bak.$([int](Get-Date -UFormat %s))" -Force
    $json = Get-Content $settingsPath -Raw | ConvertFrom-Json
    $s = @{}
    $json.PSObject.Properties | ForEach-Object { $s[$_.Name] = $_.Value }
} else {
    $s = @{}
}

# 마켓플레이스
if (-not $s.ContainsKey('extraKnownMarketplaces')) { $s['extraKnownMarketplaces'] = @{} }
$s['extraKnownMarketplaces'] = @{ 'harness-marketplace' = @{ source = @{ source = 'github'; repo = 'revfactory/harness' } } }
# 플러그인
$s['enabledPlugins'] = @{ 'harness@harness-marketplace' = $true }
# 훅 (절대 경로로 기록 — Windows 환경변수 확장 이슈 회피)
$hookFile = Join-Path $hooks 'ensure-harness.ps1'
$hookCmd  = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$hookFile`""
$s['hooks'] = @{ SessionStart = @(@{ hooks = @(@{ type = 'command'; command = $hookCmd }) }) }

($s | ConvertTo-Json -Depth 20) | Set-Content -Path $settingsPath -Encoding UTF8
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
