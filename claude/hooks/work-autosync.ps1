# claude-config:work-autosync — opt-in cloud backup of the CURRENT project (NOT the config repo).
#   Gated on a `.claude-autosync` marker at the git repo root (created by `claude-newproj`).
#   -Mode start (SessionStart) -> git pull --rebase ; -Mode end (SessionEnd) -> commit + push.
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

    $lock = Join-Path $top '.git\.work-autosync.lock'
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
            if ((git status --porcelain) 2>$null) {
                git add -A *> $null
                $secrets = @(@(git diff --cached --name-only 2>$null) | Where-Object { $_ -match $secretRe -and $_ -notmatch '\.(example|sample|template|dist)$' })
                if ($secrets.Count) {
                    git reset -q -- $secrets *> $null
                    [Console]::Error.WriteLine("claude-config work-autosync: NOT pushing secret-looking files: " + ($secrets -join ', ') + " — add them to .gitignore")
                }
                git diff --cached --quiet
                if ($LASTEXITCODE -ne 0) {
                    git commit -m ("autosync: $env:COMPUTERNAME " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) *> $null
                }
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
