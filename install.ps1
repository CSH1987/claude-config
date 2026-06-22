# claude-config 설치 (Windows) — 이 머신의 모든 폴더·세션에서:
#   · Harness 플러그인 자동 설치/복구
#   · effortLevel=xhigh 영구 적용 + ultracode/ultraplan 리마인더
#   · `claude` 명령을 ultracode 로 자동 실행($PROFILE 함수 오버라이드)
$ErrorActionPreference = 'Stop'
$repoDir   = Split-Path -Parent $MyInvocation.MyCommand.Definition
$dst   = Join-Path $env:USERPROFILE '.claude'
$hooks = Join-Path $dst 'hooks'
New-Item -ItemType Directory -Force -Path $hooks | Out-Null

# 훅 복사 (Windows는 심볼릭 링크가 관리자 권한을 요구하므로 복사 방식)
Copy-Item (Join-Path $repoDir 'claude\hooks\ensure-harness.ps1')  (Join-Path $hooks 'ensure-harness.ps1')  -Force
Copy-Item (Join-Path $repoDir 'claude\hooks\effort-reminder.ps1') (Join-Path $hooks 'effort-reminder.ps1') -Force
Copy-Item (Join-Path $repoDir 'claude\hooks\memory-inject.ps1')   (Join-Path $hooks 'memory-inject.ps1')   -Force
Copy-Item (Join-Path $repoDir 'claude\hooks\effort-reminder.txt') (Join-Path $hooks 'effort-reminder.txt') -Force
Copy-Item (Join-Path $repoDir 'claude\hooks\config-sync.ps1')     (Join-Path $hooks 'config-sync.ps1')     -Force
Copy-Item (Join-Path $repoDir 'claude\hooks\work-autosync.ps1')   (Join-Path $hooks 'work-autosync.ps1')   -Force
Copy-Item (Join-Path $repoDir 'claude\hooks\session-events.ps1')  (Join-Path $hooks 'session-events.ps1')  -Force
Copy-Item (Join-Path $repoDir 'claude\hooks\reconcile-check.ps1') (Join-Path $hooks 'reconcile-check.ps1') -Force
Copy-Item (Join-Path $repoDir 'claude\hooks\morning-brief.ps1')   (Join-Path $hooks 'morning-brief.ps1')   -Force
Copy-Item (Join-Path $repoDir 'claude\hooks\guardrails.ps1')      (Join-Path $hooks 'guardrails.ps1')      -Force
Copy-Item (Join-Path $repoDir 'claude\hooks\guardrails.py')       (Join-Path $hooks 'guardrails.py')       -Force
# config-sync 가 레포 위치를 찾도록 기록 (BOM 없이)
[System.IO.File]::WriteAllText((Join-Path $dst '.config-sync-path'), $repoDir, (New-Object System.Text.UTF8Encoding($false)))
Write-Host '  ✓ hooks copied (ensure-harness, effort-reminder, config-sync, work-autosync, session-events, reconcile-check, guardrails)'

# 평생 기억저장소 경로 resolver(memdir) 복사 — 모든 hook·skill 이 호출하는 단일 진실원(경로만, 데이터 없음).
$lib = Join-Path $dst 'lib'
New-Item -ItemType Directory -Force -Path $lib | Out-Null
Copy-Item (Join-Path $repoDir 'claude\lib\memdir.ps1') (Join-Path $lib 'memdir.ps1') -Force
Copy-Item (Join-Path $repoDir 'claude\lib\memdir.sh')  (Join-Path $lib 'memdir.sh')  -Force
Copy-Item (Join-Path $repoDir 'claude\lib\events.ps1')  (Join-Path $lib 'events.ps1')  -Force
Copy-Item (Join-Path $repoDir 'claude\lib\events.sh')   (Join-Path $lib 'events.sh')   -Force
Copy-Item (Join-Path $repoDir 'claude\lib\pending.ps1') (Join-Path $lib 'pending.ps1') -Force
Copy-Item (Join-Path $repoDir 'claude\lib\pending.sh')  (Join-Path $lib 'pending.sh')  -Force
Copy-Item (Join-Path $repoDir 'claude\lib\metrics.ps1') (Join-Path $lib 'metrics.ps1') -Force
Copy-Item (Join-Path $repoDir 'claude\lib\metrics.sh')  (Join-Path $lib 'metrics.sh')  -Force
Copy-Item (Join-Path $repoDir 'claude\lib\metrics.py')  (Join-Path $lib 'metrics.py')  -Force
Copy-Item (Join-Path $repoDir 'claude\lib\brief.py')     (Join-Path $lib 'brief.py')     -Force
Copy-Item (Join-Path $repoDir 'claude\lib\dashboard.py') (Join-Path $lib 'dashboard.py') -Force
Write-Host '  ✓ lib copied (memdir resolver, events instrument, pending stager, metrics derive, brief + dashboard)'

# leak-guard (M1): route this repo's git hooks to versioned claude/githooks (pre-commit/pre-push).
# Repo-local; blocks PII/secrets in config-sync's auto-commit/push to the PUBLIC repo. config-sync 본문 무수정.
if (Test-Path (Join-Path $repoDir 'claude\githooks')) {
    & git -C $repoDir config core.hooksPath claude/githooks 2>$null
    Write-Host '  ✓ leak-guard active (core.hooksPath=claude/githooks; off: CLAUDE_LEAKGUARD_OFF=1)'
}

# ultracode 설정 파일(--settings 로 넘길 용도) 복사
Copy-Item (Join-Path $repoDir 'claude\ultracode.json') (Join-Path $dst 'ultracode.json') -Force
Write-Host '  ✓ ultracode.json copied'

# CLAUDE.md (전역 세션 기본값): claude-config 관리 블록을 마커 사이에 삽입/갱신.
# 마커 밖의 사용자 내용은 보존하고, 재실행 시 블록만 최신본으로 교체(업데이트 자동 반영).
$claudeMd = Join-Path $dst 'CLAUDE.md'
$srcMd    = Join-Path $repoDir 'claude\CLAUDE.md'
$u8       = New-Object System.Text.UTF8Encoding($false)
$mdStart  = '<!-- claude-config:claude-md:start (auto-generated; updated on reinstall) -->'
$mdEnd    = '<!-- claude-config:claude-md:end -->'
# 블록 검색 토큰
$mdStartToks = @('<!-- claude-config:claude-md:start', '<!-- dotfiles:claude-md:start')
$mdEndToks   = @('<!-- claude-config:claude-md:end -->', '<!-- dotfiles:claude-md:end -->')
$mdBody   = [System.IO.File]::ReadAllText($srcMd, $u8).TrimEnd([char]13, [char]10)
$block    = "$mdStart`n$mdBody`n$mdEnd"
if (Test-Path $claudeMd) {
    $cur = [System.IO.File]::ReadAllText($claudeMd, $u8)
    $i = -1; foreach ($t in $mdStartToks) { $i = $cur.IndexOf($t); if ($i -ge 0) { break } }
    $j = -1; $endLen = 0; foreach ($t in $mdEndToks) { $j = $cur.IndexOf($t); if ($j -ge 0) { $endLen = $t.Length; break } }
    if ($i -ge 0 -and $j -ge $i) {
        $new = $cur.Substring(0, $i) + $block + $cur.Substring($j + $endLen)
    } else {
        $new = $cur.TrimEnd([char]13, [char]10) + "`n`n" + $block + "`n"
    }
} else {
    $new = $block + "`n"
}
[System.IO.File]::WriteAllText($claudeMd, $new, $u8)
Write-Host '  ✓ CLAUDE.md claude-config 블록 삽입/갱신 (마커 밖 사용자 내용 보존)'

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
    # 백업 누적 방지(config-sync 가 매 변경마다 deploy 하므로): 최근 5개만 유지
    Get-ChildItem "$settingsPath.bak.*" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -Skip 5 | Remove-Item -Force -ErrorAction SilentlyContinue
    $raw = Get-Content $settingsPath -Raw
    if ([string]::IsNullOrWhiteSpace($raw)) { $s = @{} } else { $s = $ser.DeserializeObject($raw) }
} else {
    $s = @{}
}
if ($s -isnot [System.Collections.IDictionary]) { $s = @{} }

# 마켓플레이스 — 기존 보존, 항목만 추가/갱신 (harness, omc=oh-my-claudecode)
(Get-Dict $s 'extraKnownMarketplaces')['harness-marketplace'] = @{ source = @{ source = 'github'; repo = 'revfactory/harness' } }
(Get-Dict $s 'extraKnownMarketplaces')['omc'] = @{ source = @{ source = 'github'; repo = 'Yeachan-Heo/oh-my-claudecode' } }
# 플러그인 — 기존 보존, base(harness, omc) + 작업 기반 보강 플러그인 추가
(Get-Dict $s 'enabledPlugins')['harness@harness-marketplace'] = $true
(Get-Dict $s 'enabledPlugins')['oh-my-claudecode@omc'] = $true
# claude-plugins-official 은 기본 내장 마켓 — 별도 등록 불필요
$officialPlugins = @(
    'hookify', 'security-guidance', 'skill-creator', 'plugin-dev',
    'mcp-server-dev', 'frontend-design', 'playwright', 'context7', 'github'
)
foreach ($p in $officialPlugins) { (Get-Dict $s 'enabledPlugins')["$p@claude-plugins-official"] = $true }
# effort 기본값 — 영구화되는 유일한 부분(xhigh). 없을 때만 설정해 사용자 선택 보존.
# (.ContainsKey 는 Hashtable·Generic Dictionary 모두 지원; .Contains 는 제네릭 Dictionary 에 없음)
if (-not $s.ContainsKey('effortLevel')) { $s['effortLevel'] = 'xhigh' }

# auto 모드 기본값(연구 프리뷰) — 없을 때만 설정해 사용자 선택 보존.
# 새 세션이 'auto mode' 로 시작: AI 안전 classifier 가 각 작업을 검사 후 거의 자동 승인.
# 보호 경로(.claude/.git)·위험 명령은 여전히 확인, PreToolUse 가드레일 훅도 그대로 동작.
# 주의: defaultMode=auto 는 사용자수준(~/.claude/settings.json)에서만 유효(프로젝트 .claude/* 는 무시).
#       우리 배포 대상이 ~/.claude/settings.json 이라 적용됨. 모델은 Opus/Sonnet 4.6+ 필요.
$perm = Get-Dict $s 'permissions'
if (-not $perm.ContainsKey('defaultMode')) { $perm['defaultMode'] = 'auto' }

# 자동업데이트 항상 ON 보장(1/2): settings 의 비활성 레버 제거.
# 전역 config 의 autoUpdates 가 settings 의 env.DISABLE_AUTOUPDATER 로 마이그레이션될 수 있는데,
# 그 값은 "0" 이어도 JS 에서 truthy 라 끄므로 키 자체를 제거해야 함.
if (($s['env'] -is [System.Collections.IDictionary]) -and $s['env'].ContainsKey('DISABLE_AUTOUPDATER')) {
    [void]$s['env'].Remove('DISABLE_AUTOUPDATER')
    Write-Host '  ✓ settings env.DISABLE_AUTOUPDATER 제거 (auto-update 항상 ON)'
}

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
        (New-PsHook 'memory-inject.ps1'   ''),
        (New-PsHook 'config-sync.ps1'     " -Mode start -Repo `"$repoDir`""),
        (New-PsHook 'work-autosync.ps1'   ' -Mode start'),
        (New-PsHook 'reconcile-check.ps1' ''),
        (New-PsHook 'morning-brief.ps1'   '')
    )
    SessionEnd = @(
        (New-PsHook 'config-sync.ps1'     " -Mode end -Repo `"$repoDir`""),
        (New-PsHook 'work-autosync.ps1'   ' -Mode end'),
        (New-PsHook 'session-events.ps1'  '')
    )
    PreToolUse = @(
        (New-PsHook 'guardrails.ps1'      '')
    )
}
# 우리가 관리하는 모든 명령(이벤트 불문) — 기존 그룹에서 우리 것만 제거(자가 치유)
$allManaged = @{}
foreach ($evt in $managedHooks.Keys) { foreach ($c in $managedHooks[$evt]) { $allManaged[$c] = $true } }
# 런처(bash/powershell)·경로·인자가 달라도 "우리 훅 파일을 실제 실행"하면 관리 훅으로 인식해 교체한다.
# → 과거 bash-form 훅(`bash "$HOME/.claude/hooks/config-sync.sh"`)이 박힌 머신도 재실행으로 자가 치유.
#   딱 3개 관리 파일명으로만 한정 + 호출 위치(-File "..." / bash "...")에 앵커 →
#   사용자 자신의 bash 훅이나, 관리 경로를 인자/문구로 "언급만" 하는 훅은 보존(과잉 제거 방지).
$managedRe = '(?:-File\s*"?|bash\s+"?)[^"]*\.claude[\\/]hooks[\\/](ensure-harness|effort-reminder|memory-inject|config-sync|work-autosync|session-events|reconcile-check|morning-brief|guardrails)\.(ps1|sh)\b'
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
            if (($h -is [System.Collections.IDictionary]) -and ($h['command'])) {
                $cmdStr = [string]$h['command']
                if ($allManaged.ContainsKey($cmdStr) -or ($cmdStr -match $managedRe)) { $isManaged = $true }
            }
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

# 테스트/CI 용 deploy-only: 파일 배치(훅·settings·CLAUDE.md·ultracode.json)만 하고
# 머신 상태 변경(python shim PATH·ExecutionPolicy·셸 프로필·플러그인 설치)은 건너뜀. (멱등·부작용 없음)
if ($env:CLAUDE_INSTALL_DEPLOY_ONLY -eq '1') {
    Write-Host '  i deploy-only — machine-state steps skipped (PATH/ExecutionPolicy/profile/plugins)'
    return
}

# 평생 기억저장소 env 영구설정 (결정 D1) — 미설정 시에만(사용자 선택 보존). User 스코프 = admin 불필요(D4).
# resolver(memdir.ps1)와 동일 규칙: CLAUDE_MEMORY_DIR > 기본 $USERPROFILE\claude-memory; OMC_STATE_DIR=<memdir>\omc-state.
# OMC 는 process.env.OMC_STATE_DIR 를 읽어 성장데이터를 단일 트리로 모은다(discovery GO 로 검증됨). 적용은 새 세션부터.
$memDir = [Environment]::GetEnvironmentVariable('CLAUDE_MEMORY_DIR', 'User')
if (-not $memDir) {
    $memDir = Join-Path $env:USERPROFILE 'claude-memory'
    [Environment]::SetEnvironmentVariable('CLAUDE_MEMORY_DIR', $memDir, 'User')
    Write-Host "  ✓ CLAUDE_MEMORY_DIR(User) → $memDir (new sessions)"
}
$omcStateDir = Join-Path $memDir 'omc-state'
if (-not [Environment]::GetEnvironmentVariable('OMC_STATE_DIR', 'User')) {
    [Environment]::SetEnvironmentVariable('OMC_STATE_DIR', $omcStateDir, 'User')
    Write-Host "  ✓ OMC_STATE_DIR(User) → $omcStateDir (new sessions)"
}
foreach ($d in @($memDir, (Join-Path $memDir 'profile'), (Join-Path $memDir 'decisions'), $omcStateDir)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
}
# profile 시드 — 부재 시에만(빈 스캐폴드, bool 기본값 없음 → A1 hook 의 cold-start 무주입 계약 유지).
$profileJson = Join-Path $memDir 'profile\user-profile.json'
if (-not (Test-Path $profileJson)) {
    $seed = '{"schema_version":1,"updated_at":"","updated_by":"","identity":{"display_name":"","handles":{},"contact_domain":"","locale":"","timezone":""},"preferences":{"response_language":"","tone":"","effort_default":"","code_comment_language":"","units":""},"roles":[],"working_style":{"preferred_stacks":[],"preferred_tools":[]},"constraints":{"do_not":[],"sensitive_topics":[],"no_proactive_mentions":[]},"projects":[],"anchors":[]}'
    [System.IO.File]::WriteAllText($profileJson, $seed, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "  ✓ profile seed created ($profileJson)"
}

# 자동업데이트 항상 ON 보장(2/2): 전역 config(~/.claude.json)의 레거시 비활성(autoUpdates:false)을 치유.
# 이 버전은 자동업데이트 on/off 를 전역 config 의 autoUpdates 에서 읽음(settings.json 아님).
# native 설치는 보호 차원에서 건드리지 않음. 해당 불리언만 표면 치환(앱 토큰 등 나머지는 그대로 보존).
# 실패해도 설치를 막지 않음(try/catch) — 앱-상태 파일이라 백업 후 진행.
try {
    $cj = Join-Path $env:USERPROFILE '.claude.json'
    if (Test-Path $cj) {
        $raw = [System.IO.File]::ReadAllText($cj)
        if (($raw -notmatch '"installMethod"\s*:\s*"native"') -and ($raw -match '"autoUpdates"\s*:\s*false')) {
            Copy-Item $cj "$cj.bak.$([int](Get-Date -UFormat %s))" -Force
            $new = [regex]::Replace($raw, '("autoUpdates"\s*:\s*)false', '${1}true')
            [System.IO.File]::WriteAllText($cj, $new, (New-Object System.Text.UTF8Encoding($false)))
            Write-Host '  ✓ ~/.claude.json autoUpdates:false → true (auto-update 항상 ON)'
        }
    }
} catch { Write-Host '  ! auto-update 보장 스킵(무시) — ~/.claude.json 처리 실패' }

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
$srcFunc = Join-Path $repoDir 'claude\shell\claude-ultra.ps1'
$marker    = 'claude-config:claude-ultra'
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

# 전역 git 안전 기본값: ~/.gitignore_global(모든 레포가 시크릿 무시) + sane 기본값(미설정 시에만).
if (Get-Command git -ErrorAction SilentlyContinue) {
    $giSrc = Join-Path $repoDir 'claude\git\gitignore_global'
    if (Test-Path $giSrc) {
        # 사용자가 이미 전역 gitignore 를 쓰면 그 파일에 시크릿 패턴만 보강(설정을 덮어쓰지 않음).
        $existing = (& git config --global --get core.excludesfile)
        $existing = if ($existing) { "$existing".Trim() } else { '' }
        $target = $null
        if ($existing) {
            $res = [Environment]::ExpandEnvironmentVariables(($existing -replace '^~', $env:USERPROFILE))
            if (Test-Path $res) { $target = $res }
        }
        if (-not $target) {
            $target = Join-Path $env:USERPROFILE '.gitignore_global'
            if (-not (Test-Path $target)) { Copy-Item $giSrc $target -Force }
            git config --global core.excludesfile $target
        }
        $cur = @(Get-Content $target -ErrorAction SilentlyContinue)
        $add = @(Get-Content $giSrc | Where-Object { $_ -ne '' -and (-not $_.StartsWith('#')) -and ($_ -notin $cur) })
        if ($add.Count) { Add-Content $target $add }
        Write-Host "  ✓ global gitignore secrets ensured ($target)"
    }
    # sane git 기본값 — 미설정일 때만 (사용자 선택 보존)
    foreach ($kv in @(@('init.defaultBranch', 'main'), @('push.autoSetupRemote', 'true'), @('fetch.prune', 'true'), @('rebase.autoStash', 'true'))) {
        if (-not (& git config --global --get $kv[0])) { git config --global $kv[0] $kv[1] }
    }
    Write-Host '  ✓ git defaults (init.defaultBranch, push.autoSetupRemote, fetch.prune, rebase.autoStash) — 미설정 시에만'
}

# 즉시 설치 (실제 실행파일 사용)
# claude 세션 내부에서 install.ps1 을 돌리면, 플러그인 설치가 띄우는 중첩 claude 프로세스의
# SessionEnd 훅(config-sync push)이 "Hook cancelled" 로 죽어 install 이 exit 1 + stale lock 을 남긴다.
# 세션 안에서는 '플러그인 설치 단계만' 건너뛴다(플러그인 enable 은 위 settings.json 머지로 이미 반영됨;
# 파일 배포·머신상태 단계는 그대로 수행). 실제 설치는 새 터미널(비-claude)에서 재실행 시 수행.
# 강제 실행: CLAUDE_INSTALL_FORCE_PLUGINS=1.
$inClaudeSession = (($env:CLAUDECODE) -or ($env:CLAUDE_CODE_ENTRYPOINT)) -and ($env:CLAUDE_INSTALL_FORCE_PLUGINS -ne '1')
if ($inClaudeSession) {
    Write-Host '  i claude 세션 내부 감지 — 플러그인 설치 단계 건너뜀 (새 터미널에서 install.ps1 재실행 시 설치; 강제: CLAUDE_INSTALL_FORCE_PLUGINS=1)'
} elseif (Get-Command claude -CommandType Application -ErrorAction SilentlyContinue) {
    claude plugin marketplace add revfactory/harness  *> $null
    claude plugin install harness@harness-marketplace *> $null
    Write-Host '  ✓ harness installed'
    claude plugin marketplace add Yeachan-Heo/oh-my-claudecode *> $null
    claude plugin install oh-my-claudecode@omc                 *> $null
    Write-Host '  ✓ oh-my-claudecode installed (/deep-interview, /ralph)'
    foreach ($p in $officialPlugins) { claude plugin install "$p@claude-plugins-official" *> $null }
    Write-Host '  ✓ official plugins installed (hookify, security-guidance, skill-creator, plugin-dev, mcp-server-dev, frontend-design, playwright, context7, github)'
    Write-Host '  i  github MCP needs env GITHUB_PERSONAL_ACCESS_TOKEN (set per machine; never commit)'
    claude plugin list 2>$null | Select-String -Pattern 'harness|oh-my-claudecode|hookify|security-guidance|skill-creator|plugin-dev|mcp-server-dev|frontend-design|playwright|context7|github|Status'
} else {
    Write-Host '  ℹ claude 미설치 — 다음 세션 훅이 설치'
}
Write-Host '✓ 완료. effortLevel=xhigh 영구 + ultracode 자동(claude 오버라이드) + harness 자동.'
Write-Host '  (새 PowerShell 창을 열어야 claude 오버라이드가 적용됩니다.)'
