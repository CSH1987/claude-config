# claude-config 부트스트랩 (Windows) — "짧은 한 줄"의 진입점.
#   irm https://raw.githubusercontent.com/CSH1987/claude-config/main/bootstrap.ps1 | iex
# 하는 일: winget 으로 git·gh·node 없으면 설치 → PATH 갱신 → (public 레포라 인증 없이) clone/update → install.ps1 실행.
# Claude Code CLI 자체와 `gh auth login` 은 사용자가 먼저(설치+로그인). gh 인증은 github MCP 토큰용이라
# 없어도 설정은 진행됨(안내만).
$ErrorActionPreference = 'Continue'
$RepoUrl = 'https://github.com/CSH1987/claude-config.git'
$Dest    = Join-Path $env:USERPROFILE 'claude-config'
function Say($m) { Write-Host "`n== $m ==" -ForegroundColor Cyan }

Say 'claude-config bootstrap (Windows)'

function Ensure($cmd, $wingetId) {
    if (Get-Command $cmd -ErrorAction SilentlyContinue) { Write-Host "  ✓ $cmd"; return }
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Write-Host "  · installing $cmd ($wingetId) ..."
        winget install --id $wingetId -e --silent --accept-source-agreements --accept-package-agreements *> $null
    } else { Write-Host "  ! winget 없음 → $cmd 수동 설치 필요" }
}
Ensure git  Git.Git
Ensure gh   GitHub.cli
Ensure node OpenJS.NodeJS.LTS

# winget 이 바꾼 PATH 를 현재 세션에 반영(같은 창에서 바로 쓰도록)
$env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')

if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
    Write-Host '  ! Claude Code CLI 미설치 — 먼저 설치하세요 (예: npm i -g @anthropic-ai/claude-code)'
}
if (Get-Command gh -ErrorAction SilentlyContinue) {
    gh auth status *> $null
    if ($LASTEXITCODE -ne 0) { Write-Host '  i github MCP 토큰을 쓰려면 한 번: gh auth login  (지금 안 해도 설정은 진행됨)' }
}

# public 레포 → 인증 없이 clone/update
if (Test-Path (Join-Path $Dest '.git')) {
    Say "update $Dest"
    git -C $Dest pull --ff-only
    if ($LASTEXITCODE -ne 0) { git -C $Dest pull --rebase --autostash }
} else {
    Say "clone -> $Dest"
    git clone $RepoUrl $Dest
    if (-not (Test-Path (Join-Path $Dest '.git'))) { Write-Host '  ! clone 실패 (git 설치 확인)'; return }
}

Say 'run install.ps1'
powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Dest 'install.ps1')
Say '완료 — 새 PowerShell 창을 열고  claude  입력'
