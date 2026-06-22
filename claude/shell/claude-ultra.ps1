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

# claude-config:review — enable Claude auto code-review + opt-in auto-fix (GitHub Action) on the CURRENT repo.
#   Reviews EVERY pull request using YOUR Claude subscription via an OAuth token (no API billing).
#   Also installs an opt-in auto-fix workflow: add the 'claude-autofix' label to a PR to have Claude fix it.
#   Usage:  claude-review            enable/refresh on this repo
#           claude-review -Status    show current setup state (read-only)
function claude-review {
    param([switch]$Status)
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { Write-Error 'git not found'; return }
    if (-not (Get-Command gh  -ErrorAction SilentlyContinue)) { Write-Error 'gh not found - winget install GitHub.cli ; gh auth login'; return }
    & gh auth status *> $null
    if ($LASTEXITCODE -ne 0) { Write-Error 'gh not logged in - run: gh auth login'; return }
    & git rev-parse --is-inside-work-tree *> $null
    if ($LASTEXITCODE -ne 0) { Write-Error 'not inside a git repo - cd into your project first'; return }
    $slug = (& gh repo view --json nameWithOwner -q .nameWithOwner 2>$null)
    if (-not $slug) { Write-Error 'no GitHub remote for this repo - create one first (e.g. claude-newproj), then re-run'; return }
    $out = '.github/workflows/claude-auto-review.yml'
    $hasSecret = ((& gh secret list 2>$null) | Select-String -Pattern '^CLAUDE_CODE_OAUTH_TOKEN' -Quiet)

    if ($Status) {
        Write-Host "claude-review status - $slug"
        if (Test-Path $out)  { Write-Host '  [OK]   review workflow present' } else { Write-Host "  [MISS] review workflow $out" }
        if (Test-Path '.github/workflows/claude-autofix.yml') { Write-Host '  [OK]   auto-fix workflow present (opt-in)' } else { Write-Host '  [--]   auto-fix workflow not installed' }
        if ($hasSecret)      { Write-Host '  [OK]   secret CLAUDE_CODE_OAUTH_TOKEN set' } else { Write-Host '  [MISS] secret CLAUDE_CODE_OAUTH_TOKEN' }
        if ((& gh label list -R $slug 2>$null) -match 'claude-autofix') { Write-Host '  [OK]   label claude-autofix exists' } else { Write-Host '  [--]   label claude-autofix missing' }
        return
    }

    # 1) write the workflow (prefer the config-repo template; fall back to an embedded copy)
    New-Item -ItemType Directory -Force -Path '.github/workflows' | Out-Null
    $u8 = New-Object System.Text.UTF8Encoding($false)
    $tmpl = $null
    $cfp = Join-Path $env:USERPROFILE '.claude\.config-sync-path'
    if (Test-Path $cfp) { $tmpl = Join-Path ((Get-Content $cfp -Raw).Trim()) 'claude\github\claude-auto-review.yml' }
    if ($tmpl -and (Test-Path $tmpl)) {
        Copy-Item $tmpl $out -Force
    } else {
        $yml = @'
# Claude 자동 코드 리뷰 — 모든 Pull Request 에서 실행. (claude-config / claude-review)
# 인증: Claude 구독 OAuth 토큰을 레포 시크릿 CLAUDE_CODE_OAUTH_TOKEN 으로 저장.
#   발급:  claude setup-token   저장:  gh secret set CLAUDE_CODE_OAUTH_TOKEN  (또는 claude-review)
# 주의: 구독 OAuth 는 anthropic_api_key 가 아니라 claude_code_oauth_token 입력을 써야 함.
name: Claude Auto Review
on:
  pull_request:
    types: [opened, synchronize, reopened]
permissions:
  contents: read
  pull-requests: write
  issues: write
  id-token: write
jobs:
  claude-review:
    runs-on: ubuntu-latest
    if: github.event.pull_request.draft == false && github.actor != 'dependabot[bot]'
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - uses: anthropics/claude-code-action@v1
        with:
          claude_code_oauth_token: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
          track_progress: true
          prompt: |
            REPO: ${{ github.repository }}
            PR NUMBER: ${{ github.event.pull_request.number }}
            이 PR을 코드 리뷰해줘. 정확성 버그·로직 오류·엣지케이스·보안·단순화 위주로.
            구체적 라인은 mcp__github_inline_comment__create_inline_comment (confirmed: true),
            총평은 `gh pr comment` 로 반드시 GitHub 코멘트로 게시. 한국어로, 사소한 건 최소화.
          claude_args: '--allowedTools "mcp__github_inline_comment__create_inline_comment,Bash(gh pr comment:*),Bash(gh pr diff:*),Bash(gh pr view:*)" --max-turns 15 --model claude-sonnet-4-6'
'@
        [System.IO.File]::WriteAllText((Join-Path (Get-Location).Path ($out -replace '/', '\')), $yml + "`n", $u8)
    }
    Write-Host "  + wrote $out"

    # 1b) also install the opt-in auto-fix workflow (label-triggered) + ensure the label exists
    $afout = '.github/workflows/claude-autofix.yml'
    $afTmpl = $null
    if (Test-Path $cfp) { $afTmpl = Join-Path ((Get-Content $cfp -Raw).Trim()) 'claude\github\claude-autofix.yml' }
    if ($afTmpl -and (Test-Path $afTmpl)) {
        Copy-Item $afTmpl $afout -Force
        & gh label create claude-autofix -R $slug --color 1f6feb --description "Claude가 이 PR을 자동 수정" 2>$null | Out-Null
        Write-Host "  + wrote $afout  (opt-in: PR에 'claude-autofix' 라벨을 달면 자동 수정)"
    } else {
        $afout = $null
        Write-Host '  i auto-fix 템플릿 못 찾음 (claude-update 후 재시도) - 리뷰만 설치'
    }

    # 2) ensure the subscription OAuth token secret exists on the repo (never stored in the repo)
    if ($hasSecret) {
        Write-Host "  + secret CLAUDE_CODE_OAUTH_TOKEN already set on $slug"
    } else {
        Write-Host '  This review runs on YOUR Claude subscription via an OAuth token.'
        Write-Host '  In ANOTHER terminal run:  claude setup-token   (1-year token; copy the output)'
        $sec = Read-Host -Prompt '  Paste token here (hidden), or press Enter to skip' -AsSecureString
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
        $tok = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        if ($tok) {
            # Feed EXACT bytes via a temp file + cmd redirection: a PowerShell pipe would append a
            # newline that corrupts the token, and --body would leak it into PSReadLine history.
            $tmp = [System.IO.Path]::GetTempFileName()
            try {
                [System.IO.File]::WriteAllText($tmp, $tok, $u8)
                & cmd /c "gh secret set CLAUDE_CODE_OAUTH_TOKEN < `"$tmp`"" 2>$null
                if ($LASTEXITCODE -eq 0) { Write-Host "  + secret CLAUDE_CODE_OAUTH_TOKEN set on $slug" }
                else { Write-Host '  ! failed - set manually: claude setup-token then  gh secret set CLAUDE_CODE_OAUTH_TOKEN' }
            } finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
        } else {
            Write-Host '  i skipped - later:  claude setup-token  then  gh secret set CLAUDE_CODE_OAUTH_TOKEN'
        }
    }

    # 3) commit + push the workflow(s) (contains no secret)
    git add $out *> $null
    if ($afout) { git add $afout *> $null }
    git diff --cached --quiet
    if ($LASTEXITCODE -ne 0) {
        git commit -q -m 'ci: Claude auto-review + opt-in auto-fix (claude-review)' *> $null
        git push -q *> $null
        if ($LASTEXITCODE -eq 0) { Write-Host '  + workflow committed & pushed' } else { Write-Host "  i committed locally - run 'git push' when ready" }
    } else {
        Write-Host '  i workflow already current'
    }

    # 4) one-time browser step: install the Claude GitHub App so PRs trigger the action
    Write-Host ''
    Write-Host '  Last step (one-time, browser): install the Claude GitHub App on this repo:'
    Write-Host '     https://github.com/apps/claude      (or run once:  claude /install-github-app)'
    Write-Host "  Done - every PR on $slug then gets an automatic Claude review (uses your subscription)."
    if ($afout) { Write-Host "  Auto-fix (opt-in): PR에 'claude-autofix' 라벨을 달면 Claude가 직접 고쳐 커밋합니다." }
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

# claude-config:status — read-only growth dashboard (lifelong-memory snapshot).
function claude-status {
    $py = Join-Path $env:USERPROFILE '.claude\lib\dashboard.py'
    if (-not (Test-Path $py)) { Write-Error 'dashboard not installed - run claude-update'; return }
    $py3 = (Get-Command python3 -ErrorAction SilentlyContinue)
    if (-not $py3) { Write-Error 'python3 not found'; return }
    $mem = $env:CLAUDE_MEMORY_DIR
    if (-not $mem) {
        $resolver = Join-Path $env:USERPROFILE '.claude\lib\memdir.ps1'
        if (Test-Path $resolver) {
            $lines = & powershell -NoProfile -ExecutionPolicy Bypass -File $resolver -NoEnsure -Export 2>$null
            foreach ($ln in @($lines)) { if ($ln -match "^\s*\`$env:CLAUDE_MEMORY_DIR\s*=\s*'(.*)'\s*$") { $mem = $Matches[1] } }
        }
    }
    if (-not $mem) { Write-Error 'memory dir not resolved'; return }
    & $py3.Source $py $mem
}

# claude-config:rate — record a 1-5 quality rating of the current output (feeds the objective fn).
#   events.ps1 is run as a SEPARATE process (its 'exit 0' must not close the user's shell);
#   the override is passed via $env:EV_OVERRIDES (events.ps1 reads it).
function claude-rate {
    param([int]$Score)
    if ($Score -lt 1 -or $Score -gt 5) { Write-Host 'usage: claude-rate <1-5>  (현재 산출물 품질 평가 -> metrics)'; return }
    $lib = Join-Path $env:USERPROFILE '.claude\lib\events.ps1'
    if (-not (Test-Path $lib)) { Write-Error 'events lib not installed - run claude-update'; return }
    $env:EV_OVERRIDES = "user_rating=$Score"
    try { & powershell -NoProfile -ExecutionPolicy Bypass -File $lib -Type task | Out-Null }
    finally { Remove-Item Env:\EV_OVERRIDES -ErrorAction SilentlyContinue }
    Write-Host "  + rated $Score/5 (metrics 의 user_rating_avg 에 반영)"
}

# claude-config:help — cheatsheet of commands, modes, and kill-switches.
function claude-help {
    Write-Host @'

claude-config — commands & modes
  claude            launch Claude Code in ultracode (auto via this wrapper)
  claude-newproj    current folder -> private GitHub repo + opt-in auto-backup
  claude-review     enable Claude auto code-review (GitHub Action) on the current repo
  claude-update     pull latest config + re-run installer
  claude-doctor     health-check this machine's setup
  claude-status     growth dashboard (memory/decisions/pending/metrics snapshot)
  claude-rate <1-5> rate current output quality (feeds growth metrics)
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
