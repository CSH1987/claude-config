# claude-config test: memory-bootstrap.ps1 - isolated harness for claude/lib/memory-bootstrap.ps1.
# Local temp dirs + local bare "remotes" only. NEVER touches the real ~/claude-memory: every case
# injects CLAUDE_MEMORY_DIR (temp) + CLAUDE_MEMORY_REMOTE (local bare).
# ASCII-only body (PS 5.1 safe). Run: powershell -File test\memory-bootstrap.ps1
$ErrorActionPreference = 'SilentlyContinue'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Definition)
$hook = Join-Path $root 'claude\lib\memory-bootstrap.ps1'
$tmp  = Join-Path $env:TEMP ('mem-boot-test-' + (Get-Random))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$script:pass = 0; $script:fail = 0
function Assert([string]$name, $cond) {
    if ($cond) { $script:pass++; Write-Output ("PASS  " + $name) }
    else       { $script:fail++; Write-Output ("FAIL  " + $name) }
}
function Seed-Remote([string]$name) {
    $bare = Join-Path $tmp ($name + '-remote.git')
    $work = Join-Path $tmp ($name + '-seed')
    git init --bare --quiet $bare *> $null
    git init --quiet $work *> $null
    git -C $work config user.email 't@example.com' *> $null
    git -C $work config user.name 'tester' *> $null
    Set-Content (Join-Path $work 'README.md') 'REMOTE'
    New-Item -ItemType Directory -Force -Path (Join-Path $work 'profile') | Out-Null
    Set-Content (Join-Path $work 'profile\user-profile.json') '{"real":true}'
    git -C $work add -A *> $null
    git -C $work commit -qm seed *> $null
    git -C $work branch -M main *> $null
    git -C $work remote add origin $bare *> $null
    git -C $work push -qu origin main *> $null
    git -C $bare symbolic-ref HEAD refs/heads/main *> $null
    return $bare
}
function Invoke-Boot([string]$target, [string]$remote) {
    $env:CLAUDE_MEMORY_NO_BOOTSTRAP = ''
    $env:CLAUDE_MEMORY_BOOTSTRAP_CREATE = ''
    $env:CLAUDE_MEMORY_DIR = $target
    $env:CLAUDE_MEMORY_REMOTE = $remote
    & powershell -NoProfile -ExecutionPolicy Bypass -File $hook *> $null
    Remove-Item Env:\CLAUDE_MEMORY_DIR, Env:\CLAUDE_MEMORY_REMOTE -ErrorAction SilentlyContinue
}

# case1: target already a git repo -> skip (never re-clone / clobber)
$bare = Seed-Remote 'c1'; $t = Join-Path $tmp 'c1'
git init --quiet $t *> $null; git -C $t config user.email 't@example.com' *> $null; git -C $t config user.name 't' *> $null
Set-Content (Join-Path $t 'LOCAL.txt') 'LOCAL'; git -C $t add -A *> $null; git -C $t commit -qm local *> $null
Invoke-Boot $t $bare
Assert 'case1: existing .git respected (no clobber)' ((Test-Path (Join-Path $t 'LOCAL.txt')) -and -not (Test-Path (Join-Path $t 'README.md')))

# case2: empty dir -> clone + upstream set
$bare = Seed-Remote 'c2'; $t = Join-Path $tmp 'c2'; New-Item -ItemType Directory -Force -Path $t | Out-Null
Invoke-Boot $t $bare
Assert 'case2: empty dir cloned (README present)' ((Test-Path (Join-Path $t '.git')) -and (Test-Path (Join-Path $t 'README.md')))
git -C $t rev-parse '@{u}' *> $null
Assert 'case2: upstream set (@{u} resolves)' ($LASTEXITCODE -eq 0)

# case3: scaffold-only dir -> clone (remote canonical wins over empty seed)
$bare = Seed-Remote 'c3'; $t = Join-Path $tmp 'c3'
foreach ($s in @('profile','decisions','omc-state')) { New-Item -ItemType Directory -Force -Path (Join-Path $t $s) | Out-Null }
Set-Content (Join-Path $t 'profile\user-profile.json') '{}'
Set-Content (Join-Path $t '.gitattributes') 'events/*.jsonl merge=union'
Invoke-Boot $t $bare
Assert 'case3: scaffold-only cloned' ((Test-Path (Join-Path $t '.git')) -and (Test-Path (Join-Path $t 'README.md')))
$prof = ''; if (Test-Path (Join-Path $t 'profile\user-profile.json')) { $prof = Get-Content (Join-Path $t 'profile\user-profile.json') -Raw }
Assert 'case3: remote profile won over empty seed' ($prof -match '"real":true')

# case4: non-scaffold real data present -> refuse (no clone, data preserved)
$bare = Seed-Remote 'c4'; $t = Join-Path $tmp 'c4'; New-Item -ItemType Directory -Force -Path $t | Out-Null
Set-Content (Join-Path $t 'important.txt') 'keep'
Invoke-Boot $t $bare
Assert 'case4: non-scaffold data refused (no clone, kept)' ((-not (Test-Path (Join-Path $t '.git'))) -and (Test-Path (Join-Path $t 'important.txt')))

# case5: unreachable remote -> skip (no clone, no auto-create)
$t = Join-Path $tmp 'c5'; New-Item -ItemType Directory -Force -Path $t | Out-Null
Invoke-Boot $t (Join-Path $tmp 'does-not-exist.git')
Assert 'case5: unreachable remote skipped (no .git)' (-not (Test-Path (Join-Path $t '.git')))

# case6: kill switch -> skip even with a valid remote
$bare = Seed-Remote 'c6'; $t = Join-Path $tmp 'c6'; New-Item -ItemType Directory -Force -Path $t | Out-Null
$env:CLAUDE_MEMORY_NO_BOOTSTRAP = '1'; $env:CLAUDE_MEMORY_DIR = $t; $env:CLAUDE_MEMORY_REMOTE = $bare
& powershell -NoProfile -ExecutionPolicy Bypass -File $hook *> $null
Remove-Item Env:\CLAUDE_MEMORY_NO_BOOTSTRAP, Env:\CLAUDE_MEMORY_DIR, Env:\CLAUDE_MEMORY_REMOTE -ErrorAction SilentlyContinue
Assert 'case6: CLAUDE_MEMORY_NO_BOOTSTRAP=1 disables bootstrap' (-not (Test-Path (Join-Path $t '.git')))

Remove-Item $tmp -Recurse -Force
$verdict = 'FAIL'; if ($script:fail -eq 0) { $verdict = 'ALL-OK' }
Write-Output ('RESULT: pass=' + $script:pass + ' fail=' + $script:fail + ' ' + $verdict)
if ($script:fail -gt 0) { exit 1 }
exit 0
