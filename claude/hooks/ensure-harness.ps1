# SessionStart 훅 (Windows) — 어디서 claude 를 열든 Harness 자동 설치 보장.
$ErrorActionPreference = 'SilentlyContinue'
$marker = Join-Path $env:USERPROFILE '.claude\plugins\installed_plugins.json'
if ((Test-Path $marker) -and (Select-String -Path $marker -Pattern 'harness@harness-marketplace' -Quiet)) {
    exit 0
}
if (-not (Get-Command claude -ErrorAction SilentlyContinue)) { exit 0 }
claude plugin marketplace add revfactory/harness  *> $null
claude plugin install harness@harness-marketplace *> $null
exit 0
