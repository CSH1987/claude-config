# Claude dotfiles 설치 (Windows) — 이 머신의 모든 폴더·세션에서:
#   · Harness 플러그인 자동 설치/복구
#   · effortLevel=xhigh 영구 적용 + ultracode/ultraplan 리마인더
#   · `claude` 명령을 ultracode 로 자동 실행($PROFILE 함수 오버라이드)
$ErrorActionPreference = 'Stop'
$dot   = Split-Path -Parent $MyInvocation.MyCommand.Definition
$dst   = Join-Path $env:USERPROFILE '.claude'
$hooks = Join-Path $dst 'hooks'
New-Item -ItemType Directory -Force -Path $hooks | Out-Null

# 훅 복사 (Windows는 심볼릭 링크가 관리자 권한을 요구하므로 복사 방식)
Copy-Item (Join-Path $dot 'claude\hooks\ensure-harness.ps1')  (Join-Path $hooks 'ensure-harness.ps1')  -Force
Copy-Item (Join-Path $dot 'claude\hooks\effort-reminder.ps1') (Join-Path $hooks 'effort-reminder.ps1') -Force
Copy-Item (Join-Path $dot 'claude\hooks\effort-reminder.txt') (Join-Path $hooks 'effort-reminder.txt') -Force
Copy-Item (Join-Path $dot 'claude\hooks\config-sync.ps1')     (Join-Path $hooks 'config-sync.ps1')     -Force
# config-sync 가 레포 위치를 찾도록 기록 (BOM 없이)
[System.IO.File]::WriteAllText((Join-Path $dst '.config-sync-path'), $dot, (New-Object System.Text.UTF8Encoding($false)))
Write-Host '  ✓ hooks copied (ensure-harness, effort-reminder, config-sync)'

# ultracode 설정 파일(--settings 로 넘길 용도) 복사
Copy-Item (Join-Path $dot 'claude\ultracode.json') (Join-Path $dst 'ultracode.json') -Force
Write-Host '  ✓ ultracode.json copied'

# CLAUDE.md (전역 세션 기본값): dotfiles 관리 블록을 마커 사이에 삽입/갱신.
# 마커 밖의 사용자 내용은 보존하고, 재실행 시 블록만 최신본으로 교체(업데이트 자동 반영).
$claudeMd = Join-Path $dst 'CLAUDE.md'
$srcMd    = Join-Path $dot 'claude\CLAUDE.md'
$u8       = New-Object System.Text.UTF8Encoding($false)
$mdStart    = '<!-- dotfiles:claude-md:start (auto-generated; updated on reinstall) -->'
$mdStartTok = '<!-- dotfiles:claude-md:start'   # ASCII 토큰 — 기존(모지바케 포함) 블록까지 매칭
$mdEnd    = '<!-- dotfiles:claude-md:end -->'
$mdBody   = [System.IO.File]::ReadAllText($srcMd, $u8).TrimEnd([char]13, [char]10)
$block    = "$mdStart`n$mdBody`n$mdEnd"
if (Test-Path $claudeMd) {
    $cur = [System.IO.File]::ReadAllText($claudeMd, $u8)
    $i = $cur.IndexOf($mdStartTok)
    $j = $cur.IndexOf($mdEnd)
    if ($i -ge 0 -and $j -ge $i) {
        $new = $cur.Substring(0, $i) + $block + $cur.Substring($j + $mdEnd.Length)
    } else {
        $new = $cur.TrimEnd([char]13, [char]10) + "`n`n" + $block + "`n"
    }
} else {
    $new = $block + "`n"
}
[System.IO.File]::WriteAllText($claudeMd, $new, $u8)
Write-Host '  ✓ CLAUDE.md dotfiles 블록 삽입/갱신 (마커 밖 사용자 내용 보존)'

# settings.json 머지 — 기존 키/구조를 충실히 보존.
# PS 5.1의 ConvertFrom/To-Json 은 "단일 요소 배열"을 객체로 붕괴시켜 hooks 배열을 깨뜨림.
# 이를 피하려고 배열을 그대로 보존하는 System.Web.Extensions(JavaScriptSerializer)로 파싱·직렬화.
Add-Type -AssemblyName System.Web.Extensions
$ser = New-Object System.Web.Script.Serialization.JavaScriptSerializer
$ser.MaxJsonLength = [int]::MaxValue

# 컴팩트 JSON 을 문자열 인지 방식으로 들여쓰기(파서 미사용 → 배열 안 깨짐).
function Format-Json([string]$json) {
    $sb = New-Object System.Text.StringBuilder
    $indent = 0; $inStr = $false; $esc = $false
    $pad = { param($n) '  ' * $n }
    for ($i = 0; $i -lt $json.Length; $i++) {
        $c = $json[$i]
        if ($inStr) {
            [void]$sb.Append($c)
            if ($esc) { $esc = $false } elseif ($c -eq '\') { $esc = $true } elseif ($c -eq '"') { $inStr = $false }
            continue
        }
        switch ($c) {
            '"' { $inStr = $true; [void]$sb.Append($c) }
            '{' { if ($i+1 -lt $json.Length -and $json[$i+1] -eq '}') { [void]$sb.Append('{}'); $i++ } else { $indent++; [void]$sb.Append("{`n" + (& $pad $indent)) } }
            '[' { if ($i+1 -lt $json.Length -and $json[$i+1] -eq ']') { [void]$sb.Append('[]'); $i++ } else { $indent++; [void]$sb.Append("[`n" + (& $pad $indent)) } }
            '}' { $indent--; [void]$sb.Append("`n" + (& $pad $indent) + '}') }
            ']' { $indent--; [void]$sb.Append("`n" + (& $pad $indent) + ']') }
            ',' { [void]$sb.Append(",`n" + (& $pad $indent)) }
            ':' { [void]$sb.Append(': ') }
            default { if ($c -notmatch '\s') { [void]$sb.Append($c) } }
        }
    }
    return $sb.ToString()
}

# 현재 dict[key] 가 사전(객체)이 아니면 빈 사전으로 만들고 그 참조를 돌려줌.
function Get-Dict($d, $k) {
    if (-not ($d[$k] -is [System.Collections.IDictionary])) { $d[$k] = @{} }
    return $d[$k]
}

$settingsPath = Join-Path $dst 'settings.json'
if (Test-Path $settingsPath) {
    Copy-Item $settingsPath "$settingsPath.bak.$([int](Get-Date -UFormat %s))" -Force
    $raw = Get-Content $settingsPath -Raw
    if ([string]::IsNullOrWhiteSpace($raw)) { $s = @{} } else { $s = $ser.DeserializeObject($raw) }
} else {
    $s = @{}
}
if ($s -isnot [System.Collections.IDictionary]) { $s = @{} }

# 마켓플레이스 — 기존 보존, 항목만 추가/갱신 (harness, omc=oh-my-claudecode)
(Get-Dict $s 'extraKnownMarketplaces')['harness-marketplace'] = @{ source = @{ source = 'github'; repo = 'revfactory/harness' } }
(Get-Dict $s 'extraKnownMarketplaces')['omc'] = @{ source = @{ source = 'github'; repo = 'Yeachan-Heo/oh-my-claudecode' } }
# 플러그인 — 기존 보존, base(harness, omc, vercel) + 작업 기반 보강 플러그인 추가
(Get-Dict $s 'enabledPlugins')['harness@harness-marketplace'] = $true
(Get-Dict $s 'enabledPlugins')['oh-my-claudecode@omc'] = $true
# claude-plugins-official 은 기본 내장 마켓 — 별도 등록 불필요
$officialPlugins = @(
    'vercel', 'hookify', 'security-guidance', 'skill-creator', 'plugin-dev',
    'mcp-server-dev', 'frontend-design', 'playwright', 'context7', 'github'
)
foreach ($p in $officialPlugins) { (Get-Dict $s 'enabledPlugins')["$p@claude-plugins-official"] = $true }
# effort 기본값 — 영구화되는 유일한 부분(xhigh). 없을 때만 설정해 사용자 선택 보존.
# (.ContainsKey 는 Hashtable·Generic Dictionary 모두 지원; .Contains 는 제네릭 Dictionary 에 없음)
if (-not $s.ContainsKey('effortLevel')) { $s['effortLevel'] = 'xhigh' }

# 훅 (절대 경로 — Windows 환경변수 확장 이슈 회피).
# 결정적 재구성: 우리 관리 명령(ensure-harness, effort-reminder)을 포함한 기존 그룹은 모두 제거하고
# (기존 중복도 함께 정리), 관계없는 사용자 훅 그룹은 보존한 뒤, 우리 두 훅을 정확히 1개씩 추가.
# → 반복 실행해도 항상 정확히 1쌍 (자가 치유, 멱등).
function New-PsHook([string]$file, [string]$rest) {
    "powershell -NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $hooks $file)`"$rest"
}
# 관리 훅: 이벤트 → 명령 목록. config-sync 는 레포 경로를 -Repo 로 박아 넘김(Windows settings.json 은 머신별).
$managedHooks = [ordered]@{
    SessionStart = @(
        (New-PsHook 'ensure-harness.ps1'  ''),
        (New-PsHook 'effort-reminder.ps1' ''),
        (New-PsHook 'config-sync.ps1'     " -Mode start -Repo `"$dot`"")
    )
    SessionEnd = @(
        (New-PsHook 'config-sync.ps1'     " -Mode end -Repo `"$dot`"")
    )
}
# 우리가 관리하는 모든 명령(이벤트 불문) — 기존 그룹에서 우리 것만 제거(자가 치유)
$allManaged = @{}
foreach ($evt in $managedHooks.Keys) { foreach ($c in $managedHooks[$evt]) { $allManaged[$c] = $true } }
$hk = Get-Dict $s 'hooks'
foreach ($evt in $managedHooks.Keys) {
    $existing = @(); if ($hk[$evt]) { $existing = @($hk[$evt]) }
    # ArrayList: PS5.1에서 빈 배열 += 해시테이블이 스칼라로 붕괴하는 문제 회피
    $kept = New-Object System.Collections.ArrayList
    foreach ($grp in $existing) {
        if ($null -eq $grp) { continue }
        if ($grp -isnot [System.Collections.IDictionary]) { [void]$kept.Add($grp); continue }
        $isManaged = $false
        foreach ($h in @($grp['hooks'])) {
            if (($h -is [System.Collections.IDictionary]) -and ($h['command']) -and $allManaged.ContainsKey([string]$h['command'])) { $isManaged = $true }
        }
        if (-not $isManaged) { [void]$kept.Add($grp) }   # 우리 훅이 아닌 그룹만 보존
    }
    foreach ($cmd in $managedHooks[$evt]) { [void]$kept.Add(@{ hooks = @(@{ type = 'command'; command = $cmd }) }) }
    $hk[$evt] = @($kept.ToArray())
}

# UTF-8(BOM 없이) 기록 — Set-Content -Encoding UTF8 이 PS5.1에서 BOM 붙이는 문제 회피
$jsonOut = Format-Json ($ser.Serialize($s))
[System.IO.File]::WriteAllText($settingsPath, $jsonOut + "`n", (New-Object System.Text.UTF8Encoding($false)))
Write-Host '  ✓ settings merged (기존 보존, 백업됨)'

# python3 심 — hookify 훅이 python3 를 직접 호출. Windows 의 python3 는 MS-Store 스텁(깨짐)이라
# 실제 python(py)을 가리키는 venv 리다이렉터 python3.exe 를 만들고 USER PATH 앞에 둔다 (멱등, admin 불필요).
# 맥/리눅스는 python3 가 네이티브라 install.sh 에는 이 단계가 없다.
$pyShim        = Join-Path $env:USERPROFILE '.pyshim'
$pyShimScripts = Join-Path $pyShim 'Scripts'
$py3           = Join-Path $pyShimScripts 'python3.exe'
if (-not (Test-Path $py3)) {
    if (Get-Command py -ErrorAction SilentlyContinue)         { & py     -m venv --system-site-packages $pyShim 2>$null }
    elseif (Get-Command python -ErrorAction SilentlyContinue) { & python -m venv --system-site-packages $pyShim 2>$null }
    $venvPy = Join-Path $pyShimScripts 'python.exe'
    if (Test-Path $venvPy) { Copy-Item $venvPy $py3 -Force; Write-Host '  ✓ python3 shim created (.pyshim)' }
    else { Write-Host '  ! python3 shim skipped — python/py not found (hookify needs python3)' }
}
if (Test-Path $py3) {
    $up = [Environment]::GetEnvironmentVariable('Path','User'); if ($null -eq $up) { $up = '' }
    if ($up -notlike "*$pyShimScripts*") {
        [Environment]::SetEnvironmentVariable('Path', "$pyShimScripts;$up", 'User')
        Write-Host '  ✓ python3 shim added to USER PATH (new sessions)'
    }
}

# ExecutionPolicy: 새 머신 기본(Restricted)이면 프로필 자체가 로드 거부됨 → CurrentUser 를 RemoteSigned 로.
try {
    $cp = Get-ExecutionPolicy -Scope CurrentUser
    if ($cp -in @('Restricted', 'Undefined', 'AllSigned')) {
        Set-ExecutionPolicy -Scope CurrentUser RemoteSigned -Force
        Write-Host '  ✓ ExecutionPolicy(CurrentUser) → RemoteSigned'
    }
} catch { Write-Host '  ! ExecutionPolicy 설정 실패(무시) — 수동: Set-ExecutionPolicy -Scope CurrentUser RemoteSigned' }

# `claude` → ultracode 자동: Windows PowerShell 5.1 + (있으면) PowerShell 7 프로필 양쪽에 dot-source (idempotent).
# 레포 삭제/이동 대비 Test-Path 가드. OneDrive 리디렉션은 MyDocuments 로 해결.
$srcFunc = Join-Path $dot 'claude\shell\claude-ultra.ps1'
$marker  = 'dotfiles:claude-ultra'
$docs    = [Environment]::GetFolderPath('MyDocuments')
$profiles = @( (Join-Path $docs 'WindowsPowerShell\Microsoft.PowerShell_profile.ps1') )
if ((Get-Command pwsh -ErrorAction SilentlyContinue) -or (Test-Path (Join-Path $docs 'PowerShell'))) {
    $profiles += (Join-Path $docs 'PowerShell\Microsoft.PowerShell_profile.ps1')   # pwsh 7
}
foreach ($prof in $profiles) {
    $profDir = Split-Path -Parent $prof
    $edition = Split-Path -Leaf $profDir
    if (-not (Test-Path $profDir)) { New-Item -ItemType Directory -Force -Path $profDir | Out-Null }
    if ((Test-Path $prof) -and (Select-String -Path $prof -SimpleMatch $marker -Quiet)) {
        Write-Host "  ✓ claude override already in $edition"
    } else {
        Add-Content -Path $prof -Value "`n# $marker`nif (Test-Path `"$srcFunc`") { . `"$srcFunc`" }"
        Write-Host "  ✓ claude override → $edition"
    }
}

# 즉시 설치 (실제 실행파일 사용)
if (Get-Command claude -CommandType Application -ErrorAction SilentlyContinue) {
    claude plugin marketplace add revfactory/harness  *> $null
    claude plugin install harness@harness-marketplace *> $null
    Write-Host '  ✓ harness installed'
    claude plugin marketplace add Yeachan-Heo/oh-my-claudecode *> $null
    claude plugin install oh-my-claudecode@omc                 *> $null
    Write-Host '  ✓ oh-my-claudecode installed (/deep-interview, /ralph)'
    foreach ($p in $officialPlugins) { claude plugin install "$p@claude-plugins-official" *> $null }
    Write-Host '  ✓ official plugins installed (vercel, hookify, security-guidance, skill-creator, plugin-dev, mcp-server-dev, frontend-design, playwright, context7, github)'
    Write-Host '  i  github MCP needs env GITHUB_PERSONAL_ACCESS_TOKEN (set per machine; never commit)'
    claude plugin list 2>$null | Select-String -Pattern 'harness|oh-my-claudecode|hookify|security-guidance|skill-creator|plugin-dev|mcp-server-dev|frontend-design|playwright|context7|github|vercel|Status'
} else {
    Write-Host '  ℹ claude 미설치 — 다음 세션 훅이 설치'
}
Write-Host '✓ 완료. effortLevel=xhigh 영구 + ultracode 자동(claude 오버라이드) + harness 자동.'
Write-Host '  (새 PowerShell 창을 열어야 claude 오버라이드가 적용됩니다.)'
