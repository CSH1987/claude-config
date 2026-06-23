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
Check 'hooks copied (all managed files present)' { $need = @('ensure-harness.ps1','effort-reminder.ps1','memory-inject.ps1','effort-reminder.txt','config-sync.ps1','work-autosync.ps1','session-events.ps1','reconcile-check.ps1','morning-brief.ps1','memory-sync.ps1','guardrails.ps1','guardrails.py','edit-track.ps1','stop-metrics.ps1'); @($need | Where-Object { -not (Test-Path (Join-Path $HooksDir $_)) }).Count -eq 0 }
Check 'ultracode.json deployed = {"ultracode":true}' { ((Get-Content (Join-Path $ClaudeDir 'ultracode.json') -Raw | ConvertFrom-Json).ultracode) -eq $true }
Check '.config-sync-path points at repo'   { ((Get-Content (Join-Path $ClaudeDir '.config-sync-path') -Raw).Trim()) -eq $Repo }
Check 'CLAUDE.md has claude-config block'    { (Get-Content (Join-Path $ClaudeDir 'CLAUDE.md') -Raw) -match 'claude-config:claude-md:start' }
Check 'settings.json is valid JSON'         { (Read-Settings) -ne $null }
$s = Read-Settings
Check 'effortLevel = xhigh'                  { $s.effortLevel -eq 'xhigh' }
Check 'enabledPlugins: all template plugins merged' { $tmpl = (Get-Content (Join-Path $Repo 'claude/settings.json') -Raw | ConvertFrom-Json).enabledPlugins.PSObject.Properties.Name; $dep = $s.enabledPlugins.PSObject.Properties.Name; $tmpl.Count -ge 1 -and (@($tmpl | Where-Object { $_ -notin $dep }).Count -eq 0) }
Check 'enabledPlugins: vercel NOT in default set' { $s.enabledPlugins.PSObject.Properties.Name -notcontains 'vercel@claude-plugins-official' }
Check 'marketplaces: harness + omc'         { $s.extraKnownMarketplaces.'harness-marketplace' -and $s.extraKnownMarketplaces.omc }
$ss = Get-Cmds $s 'SessionStart'
$se = Get-Cmds $s 'SessionEnd'
Check 'SessionStart has exactly 8 hooks'    { $ss.Count -eq 8 }
Check 'SessionEnd has exactly 4 hooks'      { $se.Count -eq 4 }
Check 'SessionStart = ensure+effort+memory-inject+config+autosync+reconcile+morning+memory-sync' { ($ss -match 'ensure-harness\.ps1').Count -eq 1 -and ($ss -match 'effort-reminder\.ps1').Count -eq 1 -and ($ss -match 'memory-inject\.ps1').Count -eq 1 -and ($ss -match 'config-sync\.ps1').Count -eq 1 -and ($ss -match 'work-autosync\.ps1').Count -eq 1 -and ($ss -match 'reconcile-check\.ps1').Count -eq 1 -and ($ss -match 'morning-brief\.ps1').Count -eq 1 -and ($ss -match 'memory-sync\.ps1').Count -eq 1 }
Check 'SessionEnd = config+autosync+session-events+memory-sync' { ($se -match 'config-sync\.ps1').Count -eq 1 -and ($se -match 'work-autosync\.ps1').Count -eq 1 -and ($se -match 'session-events\.ps1').Count -eq 1 -and ($se -match 'memory-sync\.ps1').Count -eq 1 }
$pt = Get-Cmds $s 'PreToolUse'
Check 'PreToolUse has exactly 1 hook (guardrails)' { $pt.Count -eq 1 -and (@($pt -match 'guardrails\.ps1').Count -eq 1) }
Check 'PreToolUse hook is powershell -File'        { @($pt | Where-Object { $_ -notmatch '^powershell ' }).Count -eq 0 }
Check 'guardrails.ps1 + guardrails.py deployed'    { (Test-Path (Join-Path $HooksDir 'guardrails.ps1')) -and (Test-Path (Join-Path $HooksDir 'guardrails.py')) }
$po = Get-Cmds $s 'PostToolUse'
$st = Get-Cmds $s 'Stop'
Check 'PostToolUse has exactly 1 hook (edit-track)' { $po.Count -eq 1 -and (@($po -match 'edit-track\.ps1').Count -eq 1) }
Check 'Stop has exactly 1 hook (stop-metrics)'      { $st.Count -eq 1 -and (@($st -match 'stop-metrics\.ps1').Count -eq 1) }
Check 'PostToolUse + Stop are powershell -File'     { @(($po + $st) | Where-Object { $_ -notmatch '^powershell ' }).Count -eq 0 }
Check 'edit-track.ps1 + stop-metrics.ps1 deployed'  { (Test-Path (Join-Path $HooksDir 'edit-track.ps1')) -and (Test-Path (Join-Path $HooksDir 'stop-metrics.ps1')) }
Check 'all hooks use powershell -File'       { ($ss + $se | Where-Object { $_ -notmatch '^powershell ' }).Count -eq 0 }
Check 'NO bash-form hook on Windows'        { ($ss + $se | Where-Object { $_ -match '(^|\s)bash\b' }).Count -eq 0 }
Check 'hook paths point into fake HOME'     { ($ss + $se | Where-Object { $_ -notmatch [regex]::Escape($HooksDir) }).Count -eq 0 }
Check 'settings.json written without BOM'   { $b = [System.IO.File]::ReadAllBytes((Join-Path $ClaudeDir 'settings.json')); -not ($b[0] -eq 0xEF -and $b[1] -eq 0xBB) }

# ----------------------------------------------------------------------------
Phase 'B. Idempotency (run install again)'
$r2 = Run-Install
$s2 = Read-Settings
Check 'second install exits 0'              { $r2.Code -eq 0 }
Check 'still exactly 8 SessionStart hooks'  { (Get-Cmds $s2 'SessionStart').Count -eq 8 }
Check 'still exactly 4 SessionEnd hooks'    { (Get-Cmds $s2 'SessionEnd').Count -eq 4 }
Check 'still exactly 1 PostToolUse hook'    { (Get-Cmds $s2 'PostToolUse').Count -eq 1 }
Check 'still exactly 1 Stop hook'           { (Get-Cmds $s2 'Stop').Count -eq 1 }
Check 'still valid JSON after re-run'       { $s2 -ne $null }
Check 'CLAUDE.md block not duplicated'      { ([regex]::Matches((Get-Content (Join-Path $ClaudeDir 'CLAUDE.md') -Raw),'claude-config:claude-md:start \(')).Count -eq 1 }

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
Check 'managed hooks appended (8 + 1 user)' { (Get-Cmds $s3 'SessionStart').Count -eq 9 }
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

# D5b auto-deploy: config-sync start 가 새 커밋 pull 시 deploy-only install 을 자동 실행 (변경 시에만)
$depRemote = Join-Path $SbRoot 'dep-remote.git'
$depA = Join-Path $SbRoot 'dep-a'; $depB = Join-Path $SbRoot 'dep-b'
foreach ($p in @($depRemote,$depA,$depB)) { if (Test-Path $p) { Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue } }
git init --bare --quiet $depRemote
git clone --quiet $depRemote $depA 2>&1 | Out-Null
# 가짜 install.ps1: deploy-only 로 호출되면 fake HOME 에 마커+env 기록(진짜 install 은 무겁고 부작용 → 계약만 검증)
$fakeInstall = @'
param()
$m = Join-Path $env:USERPROFILE '.claude\DEPLOY_RAN'
New-Item -ItemType Directory -Force (Split-Path $m) | Out-Null
Set-Content $m "deploy=$env:CLAUDE_INSTALL_DEPLOY_ONLY"
'@
Set-Content (Join-Path $depA 'install.ps1') $fakeInstall
Set-Content (Join-Path $depA 'a.txt') 'one' -NoNewline
git -C $depA add -A 2>&1 | Out-Null
git -C $depA -c user.email='t@t' -c user.name='t' commit -qm init 2>&1 | Out-Null
git -C $depA push -q -u origin HEAD 2>&1 | Out-Null
git clone --quiet $depRemote $depB 2>&1 | Out-Null   # depB = '다른 머신' (init 시점, 가짜 install 포함)
# depA 에서 새 커밋 push → depB 는 한 커밋 뒤처짐
Set-Content (Join-Path $depA 'changed.txt') 'newcommit' -NoNewline
git -C $depA add -A 2>&1 | Out-Null
git -C $depA -c user.email='t@t' -c user.name='t' commit -qm change 2>&1 | Out-Null
git -C $depA push -q 2>&1 | Out-Null
# NOTE: Reset-Home 을 부르면 $HooksDir 의 config-sync.ps1/work-autosync.ps1 까지 지워져 이후 Phase 가 깨진다.
# 여기선 배포된 훅을 보존하고 마커만 정리한다(가짜 install 은 USERPROFILE=$Home2 의 .claude 에 마커 생성).
$depMarker = Join-Path $ClaudeDir 'DEPLOY_RAN'
Remove-Item $depMarker -Force -ErrorAction SilentlyContinue
$savedDepUP = $env:USERPROFILE
$env:USERPROFILE = $Home2
try { $csDep = Invoke-Child $cs @('-Mode','start','-Repo',$depB) } finally { $env:USERPROFILE = $savedDepUP }
Check 'auto-deploy: start exits 0'                  { $csDep.Code -eq 0 }
Check 'auto-deploy: 변경 pull 시 install 자동 실행'  { Test-Path $depMarker }
Check 'auto-deploy: deploy-only env(=1) 전달'        { (Test-Path $depMarker) -and ((Get-Content $depMarker -Raw).Trim() -eq 'deploy=1') }
# 변경 없을 때 재실행 → deploy 스킵(멱등; before==after HEAD)
Remove-Item $depMarker -Force -ErrorAction SilentlyContinue
$env:USERPROFILE = $Home2
try { $csDep2 = Invoke-Child $cs @('-Mode','start','-Repo',$depB) } finally { $env:USERPROFILE = $savedDepUP }
Check 'auto-deploy: 변경 없으면 install 스킵(멱등)'   { -not (Test-Path $depMarker) }

# D6 work-autosync: opt-in gate — skips without the .claude-autosync marker, pushes with it
$waPs = Join-Path $HooksDir 'work-autosync.ps1'
$waRemote = Join-Path $SbRoot 'wa-remote.git'
$waWork   = Join-Path $SbRoot 'wa-work'
foreach ($p in @($waRemote,$waWork)) { if (Test-Path $p) { Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue } }
git init --bare --quiet $waRemote
git clone --quiet $waRemote $waWork 2>&1 | Out-Null
Set-Content (Join-Path $waWork 'a.txt') 'one' -NoNewline
git -C $waWork add -A 2>&1 | Out-Null
git -C $waWork -c user.email='t@t' -c user.name='t' commit -qm init 2>&1 | Out-Null
git -C $waWork push -q -u origin HEAD 2>&1 | Out-Null
# no marker -> must skip even when dirty (opt-in)
Set-Content (Join-Path $waWork 'a.txt') 'two' -NoNewline
$beforeNo = [int]((git -C $waRemote rev-list --count HEAD) 2>$null)
Push-Location $waWork; $waNo = Invoke-Child $waPs @('-Mode','end'); Pop-Location
$afterNo = [int]((git -C $waRemote rev-list --count HEAD) 2>$null)
Check 'work-autosync: no marker exits 0'         { $waNo.Code -eq 0 }
Check 'work-autosync: no marker pushes nothing'  { $afterNo -eq $beforeNo }
# add marker -> must commit + push
Set-Content (Join-Path $waWork '.claude-autosync') 'on' -NoNewline
$beforeYes = [int]((git -C $waRemote rev-list --count HEAD) 2>$null)
Push-Location $waWork; $waYes = Invoke-Child $waPs @('-Mode','end'); Pop-Location
$afterYes = [int]((git -C $waRemote rev-list --count HEAD) 2>$null)
Check 'work-autosync: with marker exits 0'       { $waYes.Code -eq 0 }
Check 'work-autosync: with marker pushed a commit' { $afterYes -eq ($beforeYes + 1) }

# D6b fail-closed secret guard: a staged .env must be EXCLUDED from the push; safe files still pushed
Set-Content (Join-Path $waWork '.env') 'SECRET=topsecret' -NoNewline
Set-Content (Join-Path $waWork 'id_rsa') 'PRIVATEKEY' -NoNewline
Set-Content (Join-Path $waWork '.env.example') 'SECRET=' -NoNewline
Set-Content (Join-Path $waWork 'safe.txt') 'ok' -NoNewline
Push-Location $waWork; $waSec = Invoke-Child $waPs @('-Mode','end'); Pop-Location
$remoteFiles = @(git -C $waRemote ls-tree -r --name-only HEAD 2>$null)
Check 'work-autosync: secret guard exits 0'          { $waSec.Code -eq 0 }
Check 'work-autosync: .env NOT pushed (fail-closed)'  { $remoteFiles -notcontains '.env' }
Check 'work-autosync: id_rsa NOT pushed (widened denylist)' { $remoteFiles -notcontains 'id_rsa' }
Check 'work-autosync: .env.example WAS pushed (template ok)' { $remoteFiles -contains '.env.example' }
Check 'work-autosync: safe file WAS pushed'          { $remoteFiles -contains 'safe.txt' }

# ----------------------------------------------------------------------------
Phase 'E. Cross-shell invariants (committed blob = what new machines clone)'
# Check the git INDEX eol (the blob that gets cloned/deployed), not the local working tree —
# a dev machine may have a stale CRLF working copy, but Mac/Linux installs get the blob (must be LF).
$shFiles = @('claude/hooks/config-sync.sh','claude/hooks/work-autosync.sh','claude/hooks/guardrails.sh','claude/hooks/guardrails.py','claude/hooks/effort-reminder.sh','claude/hooks/ensure-harness.sh','claude/hooks/effort-reminder.txt','install.sh','bootstrap.sh','claude/shell/claude-ultra.sh')
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
  Check 'install.sh installs bash claude wrapper' { (Test-Path (Join-Path $bhWin '.bashrc')) -and (Select-String -Path (Join-Path $bhWin '.bashrc') -Pattern 'claude-config:claude-ultra' -Quiet) }
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
$invSh  = '(?:-File\s*"?|bash\s+"?)[^"]*\.claude[\\/]hooks[\\/](ensure-harness|effort-reminder|memory-inject|config-sync|work-autosync|session-events|reconcile-check|morning-brief|memory-sync|guardrails)\.sh\b'
$invPs1 = '(?:-File\s*"?|bash\s+"?)[^"]*\.claude[\\/]hooks[\\/](ensure-harness|effort-reminder|memory-inject|config-sync|work-autosync|session-events|reconcile-check|morning-brief|memory-sync|guardrails)\.ps1\b'
Check 'heal: settings still valid JSON'                  { $sg -ne $null }
Check 'heal: ZERO invoked bash-form managed hooks remain' { @(($gss+$gse) | Where-Object { $_ -match $invSh }).Count -eq 0 }
Check 'heal: exactly 8 invoked-ps1 managed in SessionStart' { @($gss | Where-Object { $_ -match $invPs1 }).Count -eq 8 }
Check 'heal: exactly 4 invoked-ps1 managed in SessionEnd' { @($gse | Where-Object { $_ -match $invPs1 }).Count -eq 4 }
Check 'heal: stale ps managed at C:\old evicted'         { @(($gss+$gse) | Where-Object { $_ -match 'C:\\old' }).Count -eq 0 }
Check 'heal: user OWN bash hook PRESERVED'               { $gss -contains 'bash "$HOME/my-own-hook.sh"' }
Check 'heal: path-mention hook PRESERVED (no over-evict)' { $gss -contains 'echo "docs: .claude/hooks/config-sync.ps1"' }
Check 'heal: custom top-level key preserved'             { $sg.myCustomKey -eq 7 }
Check 'heal: no managed duplication (10 start / 4 end)'   { $gss.Count -eq 10 -and $gse.Count -eq 4 }

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
Phase 'K. Guardrail (PreToolUse): block catastrophic / warn dangerous / allow / fail-open'
$gPy = Join-Path $HooksDir 'guardrails.py'
function _verdict($json) {
  $tmp = [System.IO.Path]::GetTempFileName()
  [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))
  $out = (& cmd /c "python3 `"$gPy`" < `"$tmp`"" 2>$null)
  Remove-Item $tmp -Force -ErrorAction SilentlyContinue
  $out = "$out".Trim()
  if (-not $out) { return 'ALLOW' }
  try { $o = $out | ConvertFrom-Json } catch { return 'BADJSON' }
  if ($o.hookSpecificOutput.permissionDecision -eq 'deny') { return 'BLOCK' }
  if ($o.systemMessage) { return 'WARN' }
  return 'ALLOW'
}
if (-not (Get-Command python3 -ErrorAction SilentlyContinue)) {
  Write-Host '  SKIP  python3 not available' -ForegroundColor DarkYellow
} else {
  $RM = 'rm -' + 'rf '; $SL = [char]47   # assemble to keep literal danger strings out of this file
  Check 'guardrail: catastrophic root -> BLOCK'      { (_verdict ('{"tool_name":"Bash","tool_input":{"command":"' + $RM + $SL + '"}}')) -eq 'BLOCK' }
  Check 'guardrail: fork bomb -> BLOCK'              { (_verdict '{"tool_name":"Bash","tool_input":{"command":":()@{ :|:& @};:"}}'.Replace('@','')) -eq 'BLOCK' }
  Check 'guardrail: safe ls -> ALLOW'                { (_verdict '{"tool_name":"Bash","tool_input":{"command":"ls -la"}}') -eq 'ALLOW' }
  Check 'guardrail: rm -rf ./dir -> WARN'            { (_verdict ('{"tool_name":"Bash","tool_input":{"command":"' + $RM + './build"}}')) -eq 'WARN' }
  Check 'guardrail: force-push -> WARN'              { (_verdict '{"tool_name":"Bash","tool_input":{"command":"git push --force origin main"}}') -eq 'WARN' }
  Check 'guardrail: secret edit -> WARN'             { (_verdict '{"tool_name":"Edit","tool_input":{"file_path":"cfg/.env"}}') -eq 'WARN' }
  Check 'guardrail: .env.example edit -> ALLOW'      { (_verdict '{"tool_name":"Edit","tool_input":{"file_path":".env.example"}}') -eq 'ALLOW' }
  Check 'guardrail: malformed -> ALLOW (fail-open)'  { (_verdict 'not valid json') -eq 'ALLOW' }
}

# ----------------------------------------------------------------------------
Phase 'L. Growth metrics: edit-track (PostToolUse) + stop-metrics (Stop) file-level rework'
if (-not (Get-Command python3 -ErrorAction SilentlyContinue)) {
  Write-Host '  SKIP  python3 not available' -ForegroundColor DarkYellow
} else {
  Reset-Home; $null = Run-Install   # deploys edit-track.ps1 / stop-metrics.ps1 / events.ps1 / memdir.ps1
  $lmem = Join-Path $SbRoot 'lmem'
  if (Test-Path $lmem) { Remove-Item $lmem -Recurse -Force -ErrorAction SilentlyContinue }
  New-Item -ItemType Directory -Force -Path $lmem | Out-Null
  $lomc  = Join-Path $lmem 'omc-state'
  $etrk  = Join-Path $HooksDir 'edit-track.ps1'
  $smet  = Join-Path $HooksDir 'stop-metrics.ps1'
  $evDir = Join-Path $lmem 'events'
  $trkS1 = Join-Path (Join-Path $lomc 'edit-track') 's1.jsonl'
  $hist  = Join-Path $lomc 'edit-history.json'
  $fileX = 'C:/proj/fileX.ps1'; $fileY = 'C:/proj/fileY.ps1'   # forward-slash -> no JSON escaping
  # Feed a JSON payload to a hook via stdin in a child ps process (memdir/omc isolated to $lmem).
  function Feed-Hook($file, $json) {
    $sM = $env:CLAUDE_MEMORY_DIR; $sO = $env:OMC_STATE_DIR
    $env:CLAUDE_MEMORY_DIR = $lmem; $env:OMC_STATE_DIR = $lomc
    $tmp = [System.IO.Path]::GetTempFileName()
    [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))
    & cmd /c "powershell -NoProfile -ExecutionPolicy Bypass -File `"$file`" < `"$tmp`"" 2>$null | Out-Null
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    $env:CLAUDE_MEMORY_DIR = $sM; $env:OMC_STATE_DIR = $sO
  }
  function Ev-Lines { $a = @(); Get-ChildItem $evDir -Filter *.jsonl -ErrorAction SilentlyContinue | ForEach-Object { $a += Get-Content $_.FullName }; ,$a }
  function Rework-Count { @((Ev-Lines) | Where-Object { $_ -match '"rework":true' }).Count }
  $ed = '{"session_id":"%S","tool_name":"%T","tool_input":{"file_path":"%F"}}'
  # s1 edits fileX (Edit) + fileY (Write)
  Feed-Hook $etrk ($ed.Replace('%S','s1').Replace('%T','Edit').Replace('%F',$fileX))
  Feed-Hook $etrk ($ed.Replace('%S','s1').Replace('%T','Write').Replace('%F',$fileY))
  Check 'edit-track: s1 track has 2 edits'           { (Test-Path $trkS1) -and (@(Get-Content $trkS1 | Where-Object { $_.Trim() }).Count -eq 2) }
  Check 'edit-track: ignores non-edit tool (Bash)'   { Feed-Hook $etrk ($ed.Replace('%S','s1').Replace('%T','Bash').Replace('%F',$fileX)); (@(Get-Content $trkS1 | Where-Object { $_.Trim() }).Count -eq 2) }
  # s1 Stop: first time these files are seen -> NO rework; history seeded; track truncated
  Feed-Hook $smet '{"session_id":"s1"}'
  Check 'stop-metrics: first session -> no rework'   { (Rework-Count) -eq 0 }
  Check 'stop-metrics: s1 track truncated after stop' { (Test-Path $trkS1) -and ((Get-Item $trkS1).Length -eq 0) }
  Check 'edit-history seeded with both files (s1)'    { (Test-Path $hist) -and ((Get-Content $hist -Raw) -match 'fileX') -and ((Get-Content $hist -Raw) -match 'fileY') }
  # s2 edits fileX -> a DIFFERENT prior session touched it -> file-level rework
  Feed-Hook $etrk ($ed.Replace('%S','s2').Replace('%T','Edit').Replace('%F',$fileX))
  Feed-Hook $smet '{"session_id":"s2"}'
  Check 'stop-metrics: cross-session rework detected' { (Rework-Count) -eq 1 }
  Check 'stop-metrics: rework_anchor = file:<fileX>'  { @((Ev-Lines) | Where-Object { ($_ -match '"rework":true') -and ($_ -match 'fileX') }).Count -eq 1 }
  # s2 re-edits fileX in the SAME session -> history already s2 -> NOT rework (count stays 1)
  Feed-Hook $etrk ($ed.Replace('%S','s2').Replace('%T','Edit').Replace('%F',$fileX))
  Feed-Hook $smet '{"session_id":"s2"}'
  Check 'stop-metrics: same-session re-edit NOT rework' { (Rework-Count) -eq 1 }
  # kill-switch: CLAUDE_EVENTS_OFF=1 must no-op
  $sOff = $env:CLAUDE_EVENTS_OFF; $env:CLAUDE_EVENTS_OFF = '1'
  Feed-Hook $etrk ($ed.Replace('%S','s3').Replace('%T','Edit').Replace('%F',$fileY))
  $env:CLAUDE_EVENTS_OFF = $sOff
  Check 'edit-track: CLAUDE_EVENTS_OFF=1 no-op'       { -not (Test-Path (Join-Path (Join-Path $lomc 'edit-track') 's3.jsonl')) }
}

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
