# claude-config:work-autosync — opt-in cloud backup of the CURRENT project (NOT the config repo).
#   Gated on a `.claude-autosync` marker at the git repo root (created by `claude-newproj`).
#   -Mode start (SessionStart) -> git pull --rebase + push any unpushed backlog (self-heal).
#   -Mode end (SessionEnd) -> commit + push FIRST (the hook can be killed mid-run at session end;
#   a network step before push loses the backup) ; on push failure only: pull --rebase, retry once.
#   FAIL-CLOSED secret guard: before committing, unstages secret-looking files (.env, keys, tokens, ...)
#   so they are NEVER pushed to the cloud — a warning lists them; fix by adding to .gitignore.
#   Never blocks the session (GIT_TERMINAL_PROMPT=0, atomic lock, quiet skip on offline/conflict/no-upstream).
#   Kill-switch CLAUDE_AUTOSYNC_OFF=1. Skips config-sync's own repo to avoid a double-push race.
param([string]$Mode = "")

if ($env:CLAUDE_AUTOSYNC_OFF -eq "1") { exit 0 }
if (-not (Get-Command git -ErrorAction SilentlyContinue)) { exit 0 }
$top = (git rev-parse --show-toplevel 2>$null)
if (-not $top) { exit 0 }                                              # cwd not inside a git repo
$top = "$top".Trim()
if (-not (Test-Path (Join-Path $top '.claude-autosync'))) { exit 0 }  # project not opted in

# don't double-act with config-sync on its own repo (different lock files would race)
$cfgFile = Join-Path $env:USERPROFILE '.claude\.config-sync-path'
if (Test-Path $cfgFile) {
    $cfg = (Get-Content $cfgFile -Raw -ErrorAction SilentlyContinue)
    if ($cfg) { try { if ((Resolve-Path ($cfg.Trim())).Path -eq (Resolve-Path $top).Path) { exit 0 } } catch {} }
}

$env:GIT_TERMINAL_PROMPT = "0"
# fail-closed secret denylist (PowerShell -match is case-insensitive)
$secretRe = '(^|/)\.env($|\.)|\.envrc$|\.(pem|key|p12|pfx|jks|keystore|ppk|p8)$|(^|/)id_(rsa|ed25519|dsa|ecdsa)$|\.(npmrc|netrc|pgpass|pypirc)$|(service[-_]account|credentials).*\.json$|token.*\.json$|(^|/)database\.(ya?ml|json)$|(^|/)\.(aws|kube|ssh)/|\.tfstate$|secrets?\.(ya?ml|json|env)$'

Push-Location $top
try {
    git rev-parse --abbrev-ref --symbolic-full-name '@{u}' *> $null
    if ($LASTEXITCODE -ne 0) { return }                               # no upstream -> nothing to sync

    # lock with owner PID recorded inside (same fix as config-sync): a SessionEnd hook killed
    # mid-push skips 'finally' and leaves the lock; age-only reclaim (10 min) would then block the
    # very next session's start-mode self-heal. Dead-PID locks are reclaimed immediately regardless
    # of age; locks without a pid file keep the 10-min rule as the final safety net.
    $lock = Join-Path $top '.git\.work-autosync.lock'
    $pidFile = Join-Path $lock 'pid'
    function Test-LockStale {
        $ownerPid = 0
        try { $ownerPid = [int]((Get-Content $pidFile -ErrorAction Stop | Select-Object -First 1)) } catch {}
        if ($ownerPid -gt 0 -and -not (Get-Process -Id $ownerPid -ErrorAction SilentlyContinue)) { return $true }
        $it = Get-Item $lock -ErrorAction SilentlyContinue
        return [bool]($it -and ((Get-Date) - $it.CreationTime).TotalMinutes -gt 10)
    }
    $haveLock = $false
    try { $null = New-Item -ItemType Directory -Path $lock -ErrorAction Stop; $haveLock = $true }
    catch {
        if (Test-LockStale) {
            Remove-Item $lock -Recurse -Force -ErrorAction SilentlyContinue
            try { $null = New-Item -ItemType Directory -Path $lock -ErrorAction Stop; $haveLock = $true } catch {}
        }
    }
    if (-not $haveLock) { return }
    Set-Content -Path $pidFile -Value $PID -ErrorAction SilentlyContinue

    try {
        function Invoke-Pull {
            git pull --rebase --autostash --quiet *> $null
            if ($LASTEXITCODE -ne 0) { git rebase --abort *> $null }
        }
        # push with lowSpeed guard (no hang on dead network); returns success for retry-after-pull decisions
        function Invoke-Push {
            git -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=20 push --quiet *> $null
            return ($LASTEXITCODE -eq 0)
        }
        if ($Mode -eq 'start') {
            Invoke-Pull
            # self-heal: push any backlog left by a SessionEnd hook killed before its push completed
            $ahead = (git rev-list --count '@{u}..HEAD' 2>$null)
            if ($ahead -and [int]$ahead -gt 0) {
                if (-not (Invoke-Push)) { Invoke-Pull; [void](Invoke-Push) }
                # stalled-backup visibility (same as config-sync): silent push failures once caused
                # a weeks-long backup gap - if still ahead after self-heal, say so.
                $still = (git rev-list --count '@{u}..HEAD' 2>$null)
                if ($still -and [int]$still -gt 0) {
                    [Console]::Error.WriteLine("claude-config work-autosync: $top backup is $still commit(s) ahead of remote (push still failing - check network/auth).")
                }
            }
        } elseif ($Mode -eq 'end') {
            if ((git status --porcelain) 2>$null) {
                git add -A *> $null
                $secrets = @(@(git diff --cached --name-only 2>$null) | Where-Object { $_ -match $secretRe -and $_ -notmatch '\.(example|sample|template|dist)$' })
                if ($secrets.Count) {
                    git reset -q -- $secrets *> $null
                    [Console]::Error.WriteLine("claude-config work-autosync: NOT pushing secret-looking files: " + ($secrets -join ', ') + " — add them to .gitignore")
                }
                git diff --cached --quiet
                if ($LASTEXITCODE -ne 0) {
                    git commit -m ("autosync: " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) *> $null
                }
            }
            if (-not (Invoke-Push)) { Invoke-Pull; [void](Invoke-Push) }
        }
    } finally {
        Remove-Item $lock -Recurse -Force -ErrorAction SilentlyContinue
    }
} finally {
    Pop-Location
}
exit 0
