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
