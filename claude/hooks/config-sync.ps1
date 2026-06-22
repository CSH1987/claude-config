# claude-config:config-sync — claude-config 레포를 GitHub(클라우드)와 자동 동기화 (설정-전용).
#   -Mode start (SessionStart) → git pull + (변경 시) deploy-only 자동 반영 : 최신 설정 수신·적용
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
    # leak-guard self-heal (security): route this repo's hooks to the versioned guard before any
    # commit/push, even on a fresh clone where install hasn't run yet (core.hooksPath is .git-local
    # and not carried by clone). Idempotent. 가드 '활성화'일 뿐 가드 로직은 githooks 에 있음(본문 무수정 유지).
    if (Test-Path (Join-Path $Repo 'claude\githooks')) { git config core.hooksPath claude/githooks *> $null }
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
        # Windows 엔 timeout(1) 이 없으므로 git lowSpeed 로 느린/끊긴 네트워크에서 pull 이 무한 대기하지 않게 한다
        # (20초간 1KB/s 미만이면 중단). GIT_TERMINAL_PROMPT=0 와 함께 세션시작 행(hang) 방지.
        function Invoke-Pull {
            git -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=20 pull --rebase --autostash --quiet *> $null
            if ($LASTEXITCODE -ne 0) { git rebase --abort *> $null }
        }
        # pull 로 새 커밋이 들어오면 deploy-only 로 ~/.claude 에 자동 반영(멱등·부작용 없음).
        # deploy-only = 파일 배치만(settings·CLAUDE.md·hooks·ultracode.json), 플러그인/PATH/프로필 스킵.
        # 실패해도 세션 안 막음. 적용은 다음 세션부터(settings·CLAUDE.md 는 세션 시작 시 로드).
        # (자기 덮어쓰기 안전: PS 는 스크립트를 메모리에 로드 후 실행. Unix 는 symlink 라 덮어쓰기 자체가 없음.)
        # 보안: 이는 공개 레포의 코드를 자동 실행한다 → 보안 경계=GitHub 계정(README §5 보안 모델 참조).
        function Invoke-DeployIfChanged([string]$before) {
            $after = (git rev-parse HEAD 2>$null)
            if (-not $after -or $before -eq $after) { return }   # pull 로 변경 없으면 스킵
            $installPs1 = Join-Path $Repo 'install.ps1'
            if (-not (Test-Path $installPs1)) { return }
            try {
                $env:CLAUDE_INSTALL_DEPLOY_ONLY = '1'
                & powershell -NoProfile -ExecutionPolicy Bypass -File $installPs1 *> $null
                Write-Host 'claude-config: 새 설정을 받아 반영했습니다 (다음 세션부터 적용).'
            } catch {
            } finally {
                Remove-Item Env:\CLAUDE_INSTALL_DEPLOY_ONLY -ErrorAction SilentlyContinue
            }
        }
        if ($Mode -eq 'start') {
            $headBefore = (git rev-parse HEAD 2>$null)
            Invoke-Pull
            Invoke-DeployIfChanged $headBefore
        } elseif ($Mode -eq 'end') {
            $dirty = (git status --porcelain) 2>$null
            if ($dirty) {
                git add -A *> $null
                git commit -m ("auto-sync: " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) *> $null
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
