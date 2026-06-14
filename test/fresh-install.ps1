# Fresh-install verification harness for claude-config (Windows runtime).
# Exercises install.ps1 (deploy-only) + every SessionStart/End hook in an isolated fake HOME,
# pushes config-sync against a throwaway bare remote (never touches the real repo / GitHub),
# and asserts the cross-shell invariants the "hook error" pointed at (incl. Windows-via-Git-Bash).
# Read-only against $Repo; all writes go under $SbRoot (a temp scratch dir). Needs Git for Windows
# (bundled bash) for Phase F; that phase SKIPs gracefully if absent.
#   Run:  powershell -NoProfile -ExecutionPolicy Bypass -File test\fresh-install.ps1
#   Exit 0 = all green; Exit 1 = at least one failure (CI / ralph gate).
param(
  [string]$Repo   = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,   # repo root (test/ is one level down)
  [string]$SbRoot = (Join-Path $env:TEMP 'claude-config-fresh-test')      # scratch sandbox (fake HOMEs, throwaway repos)
)
$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
New-Item -ItemType Directory -Force -Path $SbRoot | Out-Null

$script:fails  = New-Object System.Collections.ArrayList
$script:passes = 0
function Ok($n)      { $script:passes++; Write-Host "  PASS  $n" -ForegroundColor Green }
function Bad($n,$d)  { $m = if ($d) { "$n :: $d" } else { $n }; [void]$script:fails.Add($m); Write-Host "  FAIL  $m" -ForegroundColor Red }
function Check($n,[scriptblock]$cond) {
  try { if (& $cond) { Ok $n } else { Bad $n '' } } catch { Bad $n $_.Exception.Message }
}
function Phase($t) { Write-Host "`n=== $t ===" -ForegroundColor Cyan }
function To-Msys($p) { '/' + $p.Substring(0,1).ToLower() + ($p.Substring(2) -replace '\\','/') }  # C:\a\b -> /c/a/b

$Home2     = Join-Path $SbRoot 'home'
$ClaudeDir = Join-Path $Home2 '.claude'
$HooksDir  = Join-Path $ClaudeDir 'hooks'

function Reset-Home {
  if (Test-Path $ClaudeDir) { Remove-Item $ClaudeDir -Recurse -Force -ErrorAction SilentlyContinue }
  New-Item -ItemType Directory -Force -Path $Home2 | Out-Null
}

# Run a powershell script in a CHILD process (isolates `exit`, inherits env we set).
function Invoke-Child($file, [string[]]$cargs) {
  $tmp = [System.IO.Path]::GetTempFileName()
  $all = @('-NoProfile','-ExecutionPolicy','Bypass','-File', $file) + $cargs
  & powershell @all > $tmp 2>&1
  $code = $LASTEXITCODE
  $out  = ''
  if (Test-Path $tmp) { $out = Get-Content $tmp -Raw -ErrorAction SilentlyContinue; Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
  [pscustomobject]@{ Code = $code; Out = $out }
}

# Run install.ps1 deploy-only into the fake HOME (env inherited by child).
function Run-Install {
  $saved = $env:USERPROFILE
  $env:USERPROFILE = $Home2
  $env:CLAUDE_INSTALL_DEPLOY_ONLY = '1'
  try { return Invoke-Child (Join-Path $Repo 'install.ps1') @() }
  finally { $env:USERPROFILE = $saved; Remove-Item Env:\CLAUDE_INSTALL_DEPLOY_ONLY -ErrorAction SilentlyContinue }
}

function Read-Settings {
  $p = Join-Path $ClaudeDir 'settings.json'
  if (-not (Test-Path $p)) { return $null }
  Get-Content $p -Raw | ConvertFrom-Json
}
function Get-Cmds($s, $evt) {
  $out = @()
  foreach ($grp in @($s.hooks.$evt)) { foreach ($h in @($grp.hooks)) { if ($h.command) { $out += [string]$h.command } } }
  ,$out
}

# ----------------------------------------------------------------------------
Phase 'A. Fresh install (clean HOME, deploy-only)'
Reset-Home
$r = Run-Install
Check 'install.ps1 exits 0'                 { $r.Code -eq 0 }
Check 'hooks copied (4 files)'              { (Test-Path (Join-Path $HooksDir 'ensure-harness.ps1')) -and (Test-Path (Join-Path $HooksDir 'effort-reminder.ps1')) -and (Test-Path (Join-Path $HooksDir 'effort-reminder.txt')) -and (Test-Path (Join-Path $HooksDir 'config-sync.ps1')) }
Check 'ultracode.json deployed = {"ultracode":true}' { ((Get-Content (Join-Path $ClaudeDir 'ultracode.json') -Raw | ConvertFrom-Json).ultracode) -eq $true }
Check '.config-sync-path points at repo'   { ((Get-Content (Join-Path $ClaudeDir '.config-sync-path') -Raw).Trim()) -eq $Repo }
Check 'CLAUDE.md has dotfiles block'        { (Get-Content (Join-Path $ClaudeDir 'CLAUDE.md') -Raw) -match 'dotfiles:claude-md:start' }
Check 'settings.json is valid JSON'         { (Read-Settings) -ne $null }
$s = Read-Settings
Check 'effortLevel = xhigh'                  { $s.effortLevel -eq 'xhigh' }
Check 'enabledPlugins has 12'               { (@($s.enabledPlugins.PSObject.Properties)).Count -eq 12 }
Check 'marketplaces: harness + omc'         { $s.extraKnownMarketplaces.'harness-marketplace' -and $s.extraKnownMarketplaces.omc }
$ss = Get-Cmds $s 'SessionStart'
$se = Get-Cmds $s 'SessionEnd'
Check 'SessionStart has exactly 3 hooks'    { $ss.Count -eq 3 }
Check 'SessionEnd has exactly 1 hook'       { $se.Count -eq 1 }
Check 'SessionStart = ensure+effort+config' { ($ss -match 'ensure-harness\.ps1').Count -eq 1 -and ($ss -match 'effort-reminder\.ps1').Count -eq 1 -and ($ss -match 'config-sync\.ps1').Count -eq 1 }
Check 'all hooks use powershell -File'       { ($ss + $se | Where-Object { $_ -notmatch '^powershell ' }).Count -eq 0 }
Check 'NO bash-form hook on Windows'        { ($ss + $se | Where-Object { $_ -match '(^|\s)bash\b' }).Count -eq 0 }
Check 'hook paths point into fake HOME'     { ($ss + $se | Where-Object { $_ -notmatch [regex]::Escape($HooksDir) }).Count -eq 0 }
Check 'settings.json written without BOM'   { $b = [System.IO.File]::ReadAllBytes((Join-Path $ClaudeDir 'settings.json')); -not ($b[0] -eq 0xEF -and $b[1] -eq 0xBB) }

# ----------------------------------------------------------------------------
Phase 'B. Idempotency (run install again)'
$r2 = Run-Install
$s2 = Read-Settings
Check 'second install exits 0'              { $r2.Code -eq 0 }
Check 'still exactly 3 SessionStart hooks'  { (Get-Cmds $s2 'SessionStart').Count -eq 3 }
Check 'still exactly 1 SessionEnd hook'     { (Get-Cmds $s2 'SessionEnd').Count -eq 1 }
Check 'still valid JSON after re-run'       { $s2 -ne $null }
Check 'CLAUDE.md block not duplicated'      { ([regex]::Matches((Get-Content (Join-Path $ClaudeDir 'CLAUDE.md') -Raw),'dotfiles:claude-md:start \(')).Count -eq 1 }

# ----------------------------------------------------------------------------
Phase 'C. Preserve unrelated user settings + hooks'
Reset-Home
New-Item -ItemType Directory -Force -Path $ClaudeDir | Out-Null
$seed = @'
{
  "myCustomKey": 123,
  "hooks": {
    "SessionStart": [ { "hooks": [ { "type": "command", "command": "echo custom-user-hook" } ] } ],
    "UserPromptSubmit": [ { "hooks": [ { "type": "command", "command": "echo ups-hook" } ] } ]
  }
}
'@
[System.IO.File]::WriteAllText((Join-Path $ClaudeDir 'settings.json'), $seed, (New-Object System.Text.UTF8Encoding($false)))
$r3 = Run-Install
$s3 = Read-Settings
Check 'custom top-level key preserved'      { $s3.myCustomKey -eq 123 }
Check 'unrelated UserPromptSubmit preserved' { (Get-Cmds $s3 'UserPromptSubmit') -contains 'echo ups-hook' }
Check 'custom SessionStart hook preserved'  { (Get-Cmds $s3 'SessionStart') -contains 'echo custom-user-hook' }
Check 'managed hooks appended (3 + 1 user)' { (Get-Cmds $s3 'SessionStart').Count -eq 4 }
Check 'effortLevel preserved-or-set'        { $s3.effortLevel -eq 'xhigh' }

# ----------------------------------------------------------------------------
Phase 'D. Hook runtime behaviour'
Reset-Home; $null = Run-Install

# D1 effort-reminder -> valid JSON additionalContext
$er = Invoke-Child (Join-Path $HooksDir 'effort-reminder.ps1') @()
Check 'effort-reminder exits 0'             { $er.Code -eq 0 }
Check 'effort-reminder emits valid JSON'    { try { $j = $er.Out | ConvertFrom-Json; $j.hookSpecificOutput.hookEventName -eq 'SessionStart' -and $j.hookSpecificOutput.additionalContext } catch { $false } }

# D2 ensure-harness -> early-exit path (seed marker so it does not hit network)
$pluginsDir = Join-Path $ClaudeDir 'plugins'
New-Item -ItemType Directory -Force -Path $pluginsDir | Out-Null
'{ "harness@harness-marketplace": true }' | Out-File (Join-Path $pluginsDir 'installed_plugins.json') -Encoding utf8
$saved = $env:USERPROFILE; $env:USERPROFILE = $Home2
$eh = Invoke-Child (Join-Path $HooksDir 'ensure-harness.ps1') @()
$env:USERPROFILE = $saved
Check 'ensure-harness exits 0 (early-exit)' { $eh.Code -eq 0 }

# D3 config-sync against a THROWAWAY bare remote (safe push test)
$remote = Join-Path $SbRoot 'remote.git'
$work   = Join-Path $SbRoot 'synctest'
foreach ($p in @($remote,$work)) { if (Test-Path $p) { Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue } }
git init --bare --quiet $remote
git clone --quiet $remote $work 2>&1 | Out-Null
Set-Content (Join-Path $work 'a.txt') 'one' -NoNewline
git -C $work add -A 2>&1 | Out-Null
git -C $work -c user.email='t@t' -c user.name='t' commit -qm init 2>&1 | Out-Null
git -C $work push -q -u origin HEAD 2>&1 | Out-Null
$beforeStart = (git -C $remote rev-list --count HEAD) 2>$null

$cs = Join-Path $HooksDir 'config-sync.ps1'
$csStart = Invoke-Child $cs @('-Mode','start','-Repo',$work)
Check 'config-sync start exits 0'           { $csStart.Code -eq 0 }

# make the working tree dirty, then end-mode should commit + push to the throwaway remote
Set-Content (Join-Path $work 'a.txt') 'two' -NoNewline
$beforeEnd = [int]((git -C $remote rev-list --count HEAD) 2>$null)
$csEnd = Invoke-Child $cs @('-Mode','end','-Repo',$work)
$afterEnd = [int]((git -C $remote rev-list --count HEAD) 2>$null)
Check 'config-sync end exits 0'             { $csEnd.Code -eq 0 }
Check 'config-sync end pushed a commit'     { $afterEnd -eq ($beforeEnd + 1) }

# D4 kill-switch: CLAUDE_CONFIG_NO_SYNC=1 must no-op
Set-Content (Join-Path $work 'a.txt') 'three' -NoNewline
$beforeKs = [int]((git -C $remote rev-list --count HEAD) 2>$null)
$env:CLAUDE_CONFIG_NO_SYNC = '1'
$csKs = Invoke-Child $cs @('-Mode','end','-Repo',$work)
Remove-Item Env:\CLAUDE_CONFIG_NO_SYNC -ErrorAction SilentlyContinue
$afterKs = [int]((git -C $remote rev-list --count HEAD) 2>$null)
Check 'NO_SYNC=1 exits 0'                   { $csKs.Code -eq 0 }
Check 'NO_SYNC=1 pushes nothing'            { $afterKs -eq $beforeKs }

# D5 config-sync on a repo with NO upstream must skip gracefully (exit 0)
$noup = Join-Path $SbRoot 'noupstream'
if (Test-Path $noup) { Remove-Item $noup -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force -Path $noup | Out-Null
git -C $noup init --quiet 2>&1 | Out-Null
Set-Content (Join-Path $noup 'x.txt') 'x' -NoNewline
git -C $noup add -A 2>&1 | Out-Null
git -C $noup -c user.email='t@t' -c user.name='t' commit -qm init 2>&1 | Out-Null
$csNoup = Invoke-Child $cs @('-Mode','start','-Repo',$noup)
Check 'config-sync no-upstream exits 0'     { $csNoup.Code -eq 0 }

# ----------------------------------------------------------------------------
Phase 'E. Cross-shell invariants (committed blob = what new machines clone)'
# Check the git INDEX eol (the blob that gets cloned/deployed), not the local working tree —
# a dev machine may have a stale CRLF working copy, but Mac/Linux installs get the blob (must be LF).
$shFiles = @('claude/hooks/config-sync.sh','claude/hooks/effort-reminder.sh','claude/hooks/ensure-harness.sh','claude/hooks/effort-reminder.txt','install.sh','bootstrap.sh','claude/shell/claude-ultra.sh')
foreach ($f in $shFiles) {
  $info = (& git -C $Repo ls-files --eol -- $f 2>$null) -join "`n"
  Check "committed LF (index) for $f" { $info -match '(^|\n)\s*i/lf\b' }
}
Check 'committed claude/settings.json is bash-form template' { (Get-Content (Join-Path $Repo 'claude/settings.json') -Raw) -match 'bash ' }

# ----------------------------------------------------------------------------
Phase 'F. Bash installer on Windows -> powershell-form hooks (the user-reported bug)'
$gitBash = @('C:\Program Files\Git\bin\bash.exe','C:\Program Files (x86)\Git\bin\bash.exe') | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $gitBash) {
  Write-Host '  SKIP  no Git bash on this machine (cannot exercise install.sh)' -ForegroundColor DarkYellow
} else {
  $bhWin = Join-Path $SbRoot 'bashhome'
  if (Test-Path $bhWin) { Remove-Item $bhWin -Recurse -Force -ErrorAction SilentlyContinue }
  New-Item -ItemType Directory -Force $bhWin | Out-Null
  $savedUP = $env:USERPROFILE
  $env:HOME = (To-Msys $bhWin); $env:USERPROFILE = $bhWin; $env:CLAUDE_INSTALL_DEPLOY_ONLY = '1'
  & $gitBash -c "bash '$(To-Msys $Repo)/install.sh'" > $null 2>&1
  $bcode = $LASTEXITCODE
  $env:USERPROFILE = $savedUP
  Remove-Item Env:\HOME, Env:\CLAUDE_INSTALL_DEPLOY_ONLY -ErrorAction SilentlyContinue
  $bs = $null; try { $bs = Get-Content (Join-Path $bhWin '.claude\settings.json') -Raw | ConvertFrom-Json } catch {}
  $bcmds = @()
  if ($bs) { foreach ($e in 'SessionStart','SessionEnd') { foreach ($g in @($bs.hooks.$e)) { foreach ($h in @($g.hooks)) { if ($h.command) { $bcmds += [string]$h.command } } } } }
  Check 'install.sh (Windows) exits 0'          { $bcode -eq 0 }
  Check 'install.sh produced valid settings.json' { $bs -ne $null }
  Check 'install.sh hooks are powershell-form'  { $bcmds.Count -ge 4 -and (@($bcmds | Where-Object { $_ -notmatch '^powershell ' }).Count -eq 0) }
  Check 'install.sh writes NO bash-form hook'   { @($bcmds | Where-Object { $_ -match '(^|\s)bash\b' }).Count -eq 0 }
  Check 'install.sh installs bash claude wrapper' { (Test-Path (Join-Path $bhWin '.bashrc')) -and (Select-String -Path (Join-Path $bhWin '.bashrc') -Pattern 'dotfiles:claude-ultra' -Quiet) }
}

# ----------------------------------------------------------------------------
Phase 'G. Self-heal: migrate a poisoned machine (mixed bash+ps managed, scoped preservation)'
Reset-Home
New-Item -ItemType Directory -Force -Path $ClaudeDir | Out-Null
# Poisoned + mixed state, plus two hooks that MUST survive:
#  - user's own bash hook (different file)
#  - a hook that only MENTIONS a managed path as text (over-eviction boundary)
$poisoned = @'
{
  "myCustomKey": 7,
  "hooks": {
    "SessionStart": [
      { "hooks": [ { "type": "command", "command": "bash \"$HOME/.claude/hooks/ensure-harness.sh\"" } ] },
      { "hooks": [ { "type": "command", "command": "bash \"$HOME/.claude/hooks/effort-reminder.sh\"" } ] },
      { "hooks": [ { "type": "command", "command": "bash \"$HOME/.claude/hooks/config-sync.sh\" start" } ] },
      { "hooks": [ { "type": "command", "command": "powershell -NoProfile -ExecutionPolicy Bypass -File \"C:\\old\\.claude\\hooks\\ensure-harness.ps1\"" } ] },
      { "hooks": [ { "type": "command", "command": "bash \"$HOME/my-own-hook.sh\"" } ] },
      { "hooks": [ { "type": "command", "command": "echo \"docs: .claude/hooks/config-sync.ps1\"" } ] }
    ],
    "SessionEnd": [
      { "hooks": [ { "type": "command", "command": "bash \"$HOME/.claude/hooks/config-sync.sh\" end" } ] }
    ]
  }
}
'@
[System.IO.File]::WriteAllText((Join-Path $ClaudeDir 'settings.json'), $poisoned, (New-Object System.Text.UTF8Encoding($false)))
$null = Run-Install
$sg = Read-Settings
$gss = Get-Cmds $sg 'SessionStart'; $gse = Get-Cmds $sg 'SessionEnd'
# anchored detectors: only a command that actually INVOKES a managed hook file counts
$invSh  = '(?:-File\s*"?|bash\s+"?)[^"]*\.claude[\\/]hooks[\\/](ensure-harness|effort-reminder|config-sync)\.sh\b'
$invPs1 = '(?:-File\s*"?|bash\s+"?)[^"]*\.claude[\\/]hooks[\\/](ensure-harness|effort-reminder|config-sync)\.ps1\b'
Check 'heal: settings still valid JSON'                  { $sg -ne $null }
Check 'heal: ZERO invoked bash-form managed hooks remain' { @(($gss+$gse) | Where-Object { $_ -match $invSh }).Count -eq 0 }
Check 'heal: exactly 3 invoked-ps1 managed in SessionStart' { @($gss | Where-Object { $_ -match $invPs1 }).Count -eq 3 }
Check 'heal: exactly 1 invoked-ps1 managed in SessionEnd' { @($gse | Where-Object { $_ -match $invPs1 }).Count -eq 1 }
Check 'heal: stale ps managed at C:\old evicted'         { @(($gss+$gse) | Where-Object { $_ -match 'C:\\old' }).Count -eq 0 }
Check 'heal: user OWN bash hook PRESERVED'               { $gss -contains 'bash "$HOME/my-own-hook.sh"' }
Check 'heal: path-mention hook PRESERVED (no over-evict)' { $gss -contains 'echo "docs: .claude/hooks/config-sync.ps1"' }
Check 'heal: custom top-level key preserved'             { $sg.myCustomKey -eq 7 }
Check 'heal: no managed duplication (5 start / 1 end)'   { $gss.Count -eq 5 -and $gse.Count -eq 1 }

# ----------------------------------------------------------------------------
Phase 'H. Spaces in HOME path'
$spaceHome = Join-Path $SbRoot 'dir with space'
if (Test-Path $spaceHome) { Remove-Item $spaceHome -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force -Path $spaceHome | Out-Null
$savedUP2 = $env:USERPROFILE
$env:USERPROFILE = $spaceHome; $env:CLAUDE_INSTALL_DEPLOY_ONLY = '1'
$rh = Invoke-Child (Join-Path $Repo 'install.ps1') @()
$env:USERPROFILE = $savedUP2; Remove-Item Env:\CLAUDE_INSTALL_DEPLOY_ONLY -ErrorAction SilentlyContinue
$sh = $null; try { $sh = Get-Content (Join-Path $spaceHome '.claude\settings.json') -Raw | ConvertFrom-Json } catch {}
$shcmds = @(); if ($sh) { foreach ($e in 'SessionStart','SessionEnd') { foreach ($g in @($sh.hooks.$e)) { foreach ($h in @($g.hooks)) { if ($h.command) { $shcmds += [string]$h.command } } } } }
Check 'spaces: install exits 0'                 { $rh.Code -eq 0 }
Check 'spaces: valid settings.json'             { $sh -ne $null }
Check 'spaces: hooks powershell-form'           { $shcmds.Count -ge 4 -and (@($shcmds | Where-Object { $_ -notmatch '^powershell ' }).Count -eq 0) }
Check 'spaces: -File path is double-quoted'     { @($shcmds | Where-Object { $_ -match '-File "[^"]*dir with space' }).Count -ge 4 }

# ----------------------------------------------------------------------------
Write-Host "`n========================================" -ForegroundColor Yellow
Write-Host ("RESULT: {0} passed, {1} failed" -f $script:passes, $script:fails.Count) -ForegroundColor Yellow
if ($script:fails.Count -gt 0) {
  Write-Host "FAILURES:" -ForegroundColor Red
  $script:fails | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
  exit 1
}
Write-Host "ALL GREEN" -ForegroundColor Green
exit 0
