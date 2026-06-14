# claude-config:config-sync — claude-config 레포를 GitHub(클라우드)와 자동 동기화 (설정-전용).
#   -Mode start (SessionStart) → git pull --rebase : 매 세션 최신 설정 수신
#   -Mode end   (SessionEnd)   → commit + push     : 변경분을 클라우드에 백업
# 원칙: 세션을 절대 막지 않는다.
#   · GIT_TERMINAL_PROMPT=0 → 자격증명 프롬프트로 멈추지 않고 즉시 실패(행 방지).
#   · lock → 한 번에 하나만(설치 중 hook 다발 발화 시 git 경쟁 방지).
#   · 오프라인·충돌·미설치는 조용히 스킵. 끄려면 CLAUDE_CONFIG_NO_SYNC=1.
# 비밀은 레포에 없고 .omc 는 gitignore 이므로 add -A 안전.
param([string]$Mode = "", [string]$Repo = "")

if ($env:CLAUDE_CONFIG_NO_SYNC -eq "1") { exit 0 }

# 레포 위치: 인자 > path 파일(설치 시 기록) > 기본값
if (-not $Repo) {
    $pf = Join-Path $env:USERPROFILE '.claude\.config-sync-path'
    if (Test-Path $pf) { $Repo = (Get-Content $pf -Raw -ErrorAction SilentlyContinue).Trim() }
}
if (-not $Repo) { $Repo = Join-Path $env:USERPROFILE 'claude-config' }

if (-not (Get-Command git -ErrorAction SilentlyContinue)) { exit 0 }
if (-not (Test-Path (Join-Path $Repo '.git'))) { exit 0 }

$env:GIT_TERMINAL_PROMPT = "0"   # 자격증명 없으면 행 대신 즉시 실패
Push-Location $Repo
try {
    git rev-parse --abbrev-ref --symbolic-full-name '@{u}' *> $null
    if ($LASTEXITCODE -ne 0) { return }

    # lock (atomic). 이미 돌고 있으면 스킵. 10분 이상 묵은 락은 회수.
    $lock = Join-Path $Repo '.git\.config-sync.lock'
    $haveLock = $false
    try { $null = New-Item -ItemType Directory -Path $lock -ErrorAction Stop; $haveLock = $true }
    catch {
        $it = Get-Item $lock -ErrorAction SilentlyContinue
        if ($it -and ((Get-Date) - $it.CreationTime).TotalMinutes -gt 10) {
            Remove-Item $lock -Recurse -Force -ErrorAction SilentlyContinue
            try { $null = New-Item -ItemType Directory -Path $lock -ErrorAction Stop; $haveLock = $true } catch {}
        }
    }
    if (-not $haveLock) { return }

    try {
        function Invoke-Pull {
            git pull --rebase --autostash --quiet *> $null
            if ($LASTEXITCODE -ne 0) { git rebase --abort *> $null }
        }
        if ($Mode -eq 'start') {
            Invoke-Pull
        } elseif ($Mode -eq 'end') {
            $dirty = (git status --porcelain) 2>$null
            if ($dirty) {
                git add -A *> $null
                git commit -m ("auto-sync: $env:COMPUTERNAME " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) *> $null
            }
            Invoke-Pull
            git push --quiet *> $null
        }
    } finally {
        Remove-Item $lock -Recurse -Force -ErrorAction SilentlyContinue
    }
} finally {
    Pop-Location
}
exit 0
