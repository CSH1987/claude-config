# claude-config:claude-ultra — `claude` 를 항상 ultracode 로 실행 (PowerShell).
# 실제 실행파일(claude.cmd/.exe)을 -CommandType Application 으로 해석해 함수 재귀를 방지하고,
# ultracode.json 이 없으면 평범한 claude 로 폴백한다.
function claude {
    $real = (Get-Command claude.cmd -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    if (-not $real) { $real = (Get-Command claude.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source }
    if (-not $real) { $real = (Get-Command claude -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source }
    if (-not $real) { Write-Error 'claude 실행파일을 찾을 수 없습니다.'; return }
    $s = Join-Path $env:USERPROFILE '.claude\ultracode.json'
    # github MCP 토큰: 명시적으로 설정돼 있지 않으면 로그인된 gh 에서 런타임으로 가져옴 (레포엔 비밀 미포함)
    if ((-not $env:GITHUB_PERSONAL_ACCESS_TOKEN) -and (Get-Command gh -ErrorAction SilentlyContinue)) {
        $ghTok = (& gh auth token 2>$null)
        if ($ghTok) { $env:GITHUB_PERSONAL_ACCESS_TOKEN = "$ghTok".Trim() }
    }
    if (Test-Path $s) { & $real --settings $s @args } else { & $real @args }
}

# claude-config:newproj — turn the CURRENT folder into a private GitHub repo (cloud backup from day one).
#   Usage:  claude-newproj [repo-name]   (defaults to the folder name)
#   Seeds a secret-safe .gitignore + a .claude-autosync marker so the work-autosync hook auto-pushes thereafter.
function claude-newproj {
    param([string]$Name = (Split-Path -Leaf (Get-Location)))
    $Name = ($Name -replace '[^A-Za-z0-9._-]', '-')   # GitHub-safe repo name
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { Write-Error 'git not found'; return }
    if (-not (Get-Command gh  -ErrorAction SilentlyContinue)) { Write-Error 'gh not found - run: winget install GitHub.cli ; gh auth login'; return }
    & gh auth status *> $null
    if ($LASTEXITCODE -ne 0) { Write-Error 'gh not logged in - run: gh auth login'; return }
    if (-not (Test-Path .git)) { git init -q }
    # ALWAYS ensure secret-safe ignore patterns (append missing even if a .gitignore already exists)
    $ig = @('.env','.env.*','.envrc','*.key','*.pem','*.p12','*.pfx','*.jks','*.keystore','*.ppk','*.p8','id_rsa','id_ed25519','id_dsa','id_ecdsa','.npmrc','.netrc','.pgpass','.pypirc','*service-account*.json','*credentials*.json','*token*.json','database.yml','.aws/','.kube/','.ssh/','*.tfstate','*.tfstate.*','secrets.yml','secrets.yaml','secrets.json','node_modules/','.venv/','__pycache__/','.DS_Store','.omc/','*.log','!.env.example','!.env.sample','!.env.template')
    if (-not (Test-Path .gitignore)) { Set-Content .gitignore '' -Encoding ascii }
    $cur = @(Get-Content .gitignore -ErrorAction SilentlyContinue)
    $add = @($ig | Where-Object { $_ -notin $cur })
    if ($add.Count) { Add-Content .gitignore (@('', '# claude-config: secret-safe defaults') + $add) -Encoding ascii; Write-Host "  + .gitignore: $($add.Count) secret-safe patterns added" }
    if (-not (Test-Path .claude-autosync)) {
        'claude-config work-autosync marker - this repo auto commits+pushes on session end. Delete this file to opt out.' | Out-File -FilePath .claude-autosync -Encoding ascii
    }
    git add -A
    # fail-closed: never let secret-looking files into the first commit
    $secretRe = '(^|/)\.env($|\.)|\.envrc$|\.(pem|key|p12|pfx|jks|keystore|ppk|p8)$|(^|/)id_(rsa|ed25519|dsa|ecdsa)$|\.(npmrc|netrc|pgpass|pypirc)$|(service[-_]account|credentials).*\.json$|token.*\.json$|(^|/)database\.(ya?ml|json)$|(^|/)\.(aws|kube|ssh)/|\.tfstate$|secrets?\.(ya?ml|json|env)$'
    $secrets = @(@(git diff --cached --name-only 2>$null) | Where-Object { $_ -match $secretRe -and $_ -notmatch '\.(example|sample|template|dist)$' })
    if ($secrets.Count) { git reset -q -- $secrets *> $null; Write-Warning ("Excluded secret-looking files (not committed/pushed): " + ($secrets -join ', ')) }
    git diff --cached --quiet
    if ($LASTEXITCODE -ne 0) { git commit -q -m 'initial commit (claude-newproj)' }
    git rev-parse --abbrev-ref --symbolic-full-name '@{u}' *> $null
    if ($LASTEXITCODE -eq 0) { git push -q } else { gh repo create $Name --private --source=. --remote=origin --push }
    if ($LASTEXITCODE -ne 0) { Write-Error "push/create failed - NOT backed up (repo name conflict? gh auth?). Nothing was pushed."; return }
    Write-Host "  + '$Name' pushed to a private GitHub repo. Auto-backup on every session end is now ON."
}

# claude-config:update — pull the latest config repo + re-run the installer (one command).
function claude-update {
    $cf = Join-Path $env:USERPROFILE '.claude\.config-sync-path'
    if (-not (Test-Path $cf)) { Write-Error 'config repo path unknown (~/.claude/.config-sync-path missing) - run install.ps1 once'; return }
    $repo = ((Get-Content $cf -Raw)).Trim()
    if (-not (Test-Path (Join-Path $repo '.git'))) { Write-Error "config repo not found: $repo"; return }
    Write-Host "  updating $repo ..."
    git -C $repo pull --ff-only
    if ($LASTEXITCODE -ne 0) { git -C $repo pull --rebase --autostash }
    powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'install.ps1')
    Write-Host '  + updated. Open a NEW terminal for shell changes to take effect.'
}

# claude-config:doctor — read-only health-check of THIS machine's setup.
function claude-doctor {
    $dst = Join-Path $env:USERPROFILE '.claude'
    $rows = New-Object System.Collections.ArrayList
    function _add($s, $m, $h = '') { [void]$rows.Add([pscustomobject]@{ s = $s; m = $m; h = $h }) }
    if ((Get-Command claude.cmd -CommandType Application -ErrorAction SilentlyContinue) -or (Get-Command claude -CommandType Application -ErrorAction SilentlyContinue)) { _add 'OK' 'claude CLI found' } else { _add 'FAIL' 'claude CLI not found' 'npm i -g @anthropic-ai/claude-code' }
    $sp = Join-Path $dst 'settings.json'
    if (Test-Path $sp) {
        try {
            $s = Get-Content $sp -Raw | ConvertFrom-Json
            $pc = @($s.enabledPlugins.PSObject.Properties).Count
            if ($pc -ge 11) { _add 'OK' "enabledPlugins: $pc" } else { _add 'WARN' "enabledPlugins: $pc (expected >= 11)" 'claude-update' }
            if ($s.effortLevel -eq 'xhigh') { _add 'OK' 'effortLevel = xhigh' } else { _add 'WARN' "effortLevel = $($s.effortLevel)" }
            _add 'OK' ("hooks: SessionStart={0} SessionEnd={1}" -f @($s.hooks.SessionStart).Count, @($s.hooks.SessionEnd).Count)
        } catch { _add 'FAIL' 'settings.json invalid JSON' 'claude-update' }
    } else { _add 'FAIL' 'settings.json missing' 'run install.ps1' }
    foreach ($h in 'ensure-harness.ps1', 'effort-reminder.ps1', 'config-sync.ps1', 'work-autosync.ps1') {
        if (Test-Path (Join-Path $dst "hooks\$h")) { _add 'OK' "hook: $h" } else { _add 'WARN' "hook missing: $h" 'claude-update' }
    }
    if (Get-Command gh -ErrorAction SilentlyContinue) { & gh auth status *> $null; if ($LASTEXITCODE -eq 0) { _add 'OK' 'gh authenticated' } else { _add 'WARN' 'gh not authenticated' 'gh auth login (github MCP token)' } } else { _add 'WARN' 'gh not installed' 'winget install GitHub.cli' }
    if (Get-Command python3 -ErrorAction SilentlyContinue) { _add 'OK' 'python3 available (hookify)' } else { _add 'WARN' 'python3 not on PATH' 'claude-update (.pyshim)' }
    if (Test-Path (Join-Path $dst 'ultracode.json')) { _add 'OK' 'ultracode.json present' } else { _add 'WARN' 'ultracode.json missing' 'claude-update' }
    if ((Test-Path $PROFILE) -and (Select-String -Path $PROFILE -SimpleMatch 'claude-ultra' -Quiet)) { _add 'OK' 'claude wrapper in $PROFILE' } else { _add 'WARN' 'claude wrapper not in $PROFILE' 'open a new terminal / claude-update' }
    if ((& git config --global --get core.excludesfile)) { _add 'OK' 'git core.excludesfile set (global gitignore)' } else { _add 'WARN' 'global gitignore not set' 'claude-update' }
    $cf = Join-Path $dst '.config-sync-path'
    if (Test-Path $cf) { $r = ((Get-Content $cf -Raw)).Trim(); if (Test-Path (Join-Path $r '.git')) { _add 'OK' "config repo: $r" } else { _add 'WARN' "config repo missing: $r" } } else { _add 'WARN' '.config-sync-path missing' }
    Write-Host "`nclaude-doctor:" -ForegroundColor Cyan
    foreach ($r in $rows) {
        $c = switch ($r.s) { 'OK' { 'Green' } 'WARN' { 'Yellow' } default { 'Red' } }
        Write-Host ("  [{0,-4}] {1}" -f $r.s, $r.m) -ForegroundColor $c
        if ($r.h -and $r.s -ne 'OK') { Write-Host "         -> $($r.h)" -ForegroundColor DarkGray }
    }
    Write-Host ("`n  {0} OK / {1} WARN / {2} FAIL`n" -f @($rows | Where-Object { $_.s -eq 'OK' }).Count, @($rows | Where-Object { $_.s -eq 'WARN' }).Count, @($rows | Where-Object { $_.s -eq 'FAIL' }).Count) -ForegroundColor Cyan
}

# claude-config:help — cheatsheet of commands, modes, and kill-switches.
function claude-help {
    Write-Host @'

claude-config — commands & modes
  claude            launch Claude Code in ultracode (auto via this wrapper)
  claude-newproj    current folder -> private GitHub repo + opt-in auto-backup
  claude-update     pull latest config + re-run installer
  claude-doctor     health-check this machine's setup
  claude-help       this cheatsheet

  work-autosync (opt-in project backup): add a .claude-autosync marker at the repo root.
    off (project): delete .claude-autosync   |   off (global): CLAUDE_AUTOSYNC_OFF=1
  config auto-sync: SessionStart=pull / SessionEnd=push.  off: CLAUDE_CONFIG_NO_SYNC=1

OMC modes (you run the slash command; Claude suggests them proactively):
  /deep-interview  crystallize vague requirements
  /ralph           persist until done + reviewer-verified
  /autopilot       idea -> code pipeline     /ultrawork  parallel throughput

'@
}
