# claude-config:memory-bootstrap (Windows) - auto-link the PRIVATE lifelong-memory repo onto a
#   machine that doesn't have it yet, so memory backup + native-memory mirror + self-heal turn on
#   with zero manual steps. Called from install.ps1 and from memory-sync.ps1 SessionStart self-heal.
# Safety (PRIVATE repo - never leak / never clobber):
#   * Exit immediately if $MEM\.git already exists (never touch an existing store; idempotent).
#   * Clone ONLY an already-existing remote. Auto-create only when CLAUDE_MEMORY_BOOTSTRAP_CREATE=1
#     (default is clone-only so a machine cannot accidentally create the wrong/public repo).
#   * Refuse to clobber a $MEM that holds non-scaffold real data (manual reconcile required).
#   * Never block install/session (fail-open, always exit 0). Off: CLAUDE_MEMORY_NO_BOOTSTRAP=1.
# Remote resolution: CLAUDE_MEMORY_REMOTE (env override, used by tests) > gh-derived
#   https://github.com/<login>/claude-memory.git (login from `gh api user`). No hardcoded URL (no PII).
# ASCII no-BOM (PS 5.1 safe): this body is pure ASCII on purpose.
$ErrorActionPreference = 'SilentlyContinue'
if ($env:CLAUDE_MEMORY_NO_BOOTSTRAP -eq '1') { exit 0 }
if (-not (Get-Command git -ErrorAction SilentlyContinue)) { exit 0 }

# --- resolve memdir (resolver single source of truth) ---
$mem = $env:CLAUDE_MEMORY_DIR
if (-not $mem) {
    $r = Join-Path $env:USERPROFILE '.claude\lib\memdir.ps1'
    if (-not (Test-Path $r)) {
        $here = $PSScriptRoot
        if (-not $here) { $here = Split-Path -Parent $MyInvocation.MyCommand.Path }
        if ($here) { $r = Join-Path $here 'memdir.ps1' }
    }
    if (Test-Path $r) {
        $lines = & powershell -NoProfile -ExecutionPolicy Bypass -File $r -NoEnsure -Export 2>$null
        foreach ($ln in @($lines)) {
            if ($ln -match "^\s*\`$env:CLAUDE_MEMORY_DIR\s*=\s*'(.*)'\s*$") { $mem = $Matches[1] }
        }
    }
    if (-not $mem) { $mem = Join-Path $env:USERPROFILE 'claude-memory' }
}

# already a git repo -> nothing to do (protect the existing store)
if (Test-Path (Join-Path $mem '.git')) { exit 0 }

# --- resolve remote url ---
$remote = $env:CLAUDE_MEMORY_REMOTE
if (-not $remote -and (Get-Command gh -ErrorAction SilentlyContinue)) {
    $login = (& gh api user --jq .login 2>$null)
    if ($login) { $remote = "https://github.com/$login/claude-memory.git" }
}
if (-not $remote) { exit 0 }   # no way to know the private remote -> skip

$env:GIT_TERMINAL_PROMPT = '0'
& git ls-remote $remote *> $null
if ($LASTEXITCODE -ne 0) {
    if ($env:CLAUDE_MEMORY_BOOTSTRAP_CREATE -eq '1' -and (Get-Command gh -ErrorAction SilentlyContinue)) {
        & gh repo create claude-memory --private *> $null
        if ($LASTEXITCODE -ne 0) { exit 0 }
    } else { exit 0 }
}

# --- clobber guard: refuse if $mem holds a non-scaffold top-level entry ---
if (Test-Path $mem) {
    $allow = @('profile', 'decisions', 'omc-state', '.gitattributes', '.last-brief', '.leakwords')
    $extra = Get-ChildItem -Force -Path $mem -ErrorAction SilentlyContinue | Where-Object { $allow -notcontains $_.Name }
    if ($extra) {
        Write-Host "claude-config memory-bootstrap: $mem has existing data; skipping auto-clone (reconcile manually)."
        exit 0
    }
}

# --- clone: remove only the known empty scaffold so clone gets a clean target, then git clone.
# clone auto-sets origin + upstream (avoids the untracked-overwrite ambiguity of init+fetch+checkout).
# The clobber guard already passed, so only empty dirs / seed files are removed -- never real data.
if (Test-Path $mem) {
    foreach ($s in @('profile', 'decisions', 'omc-state')) {
        $p = Join-Path $mem $s; if (Test-Path $p) { Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue }
    }
    foreach ($s in @('.gitattributes', '.last-brief', '.leakwords')) {
        $p = Join-Path $mem $s; if (Test-Path $p) { Remove-Item $p -Force -ErrorAction SilentlyContinue }
    }
    if (-not (Get-ChildItem -Force -Path $mem -ErrorAction SilentlyContinue)) { Remove-Item $mem -Force -ErrorAction SilentlyContinue }
}
$parent = Split-Path -Parent $mem
if ($parent -and -not (Test-Path $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
& git -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=20 clone --quiet $remote $mem *> $null
if ($LASTEXITCODE -eq 0) {
    Write-Host "claude-config: linked PRIVATE memory store on this machine ($mem <- origin)."
}
exit 0
