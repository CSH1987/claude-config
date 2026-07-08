# hermes-sync: claude-config 규칙을 hermes-agent에 자동 적용
# - AGENTS.md에 마커 블록으로 portable-rules를 삽입/갱신 (hermes 자체 내용은 보존, 재실행 멱등)
# - hermes는 AGENTS.md를 "세션 작업 디렉터리(cwd)"에서만 로드한다
#   (hermes-agent agent/prompt_builder.py `_load_agents_md` — cwd only, v0.18.2 확인).
#   게이트웨이 기본 cwd = config.yaml terminal.cwd 이고, 플레이스홀더("."|"auto"|"cwd")면
#   홈 디렉터리로 폴백한다 (gateway/run.py + gateway/cwd_placeholder.py).
#   따라서 두 곳에 주입한다:
#     1) HERMES_HOME\AGENTS.md — hermes 공식 프로필 아티팩트(profile export 포함),
#        cwd=HERMES_HOME 배포(Docker 등) 및 HERMES_HOME 에서 CLI 실행 시 적용
#     2) 실효 게이트웨이 cwd\AGENTS.md — terminal.cwd 가 절대경로면 그곳, 아니면 $HOME
# - 이식 가능한 스킬(workload-optimization)을 hermes skills 디렉터리로 복사
#   (hermes 사용자 스킬 규약: skills/<maybe-category>/<name>/SKILL.md — 카테고리 생략 가능)
# - hermes 미설치 시 무동작(exit 0) → SessionStart 체인에 안전하게 상주 가능
param(
    [string]$HermesDir = "",
    [string]$SourceDir = "$HOME\.claude"
)

if (-not $HermesDir) {
    foreach ($cand in @("$HOME\.hermes", "$env:LOCALAPPDATA\hermes")) {
        if ($cand -and (Test-Path $cand)) { $HermesDir = $cand; break }
    }
}
if (-not $HermesDir -or -not (Test-Path $HermesDir)) { exit 0 }

$rulesFile = Join-Path $SourceDir "exports\portable-rules.md"
if (-not (Test-Path $rulesFile)) { exit 0 }

# PS 5.1 호환: 인코딩을 .NET IO로 명시(BOM 유무와 무관하게 UTF-8), 개행 정규화로 멱등성 보장
# 출력(AGENTS.md)은 반드시 BOM 없이 쓴다 — hermes 의 컨텍스트 파일 스캐너가
# U+FEFF(BOM) 포함 파일을 "invisible_unicode" 로 차단함 (agent/prompt_builder.py 확인)
$utf8Read  = [System.Text.UTF8Encoding]::new($false)
$utf8Write = [System.Text.UTF8Encoding]::new($false)

$startMarker = "<!-- claude-config:portable-rules:start -->"
$endMarker   = "<!-- claude-config:portable-rules:end -->"
$rules = [System.IO.File]::ReadAllText($rulesFile, $utf8Read).TrimEnd()
$block = "$startMarker`n$rules`n$endMarker"

# 마커 블록 upsert: 블록 밖 내용 보존, 재실행 멱등
function Update-AgentsMd([string]$agentsMd) {
    if (Test-Path $agentsMd) {
        $existing = [System.IO.File]::ReadAllText($agentsMd, $script:utf8Read)
        $i = $existing.IndexOf($script:startMarker)
        $j = $existing.IndexOf($script:endMarker)
        if ($i -ge 0 -and $j -gt $i) {
            $updated = $existing.Substring(0, $i) + $script:block + $existing.Substring($j + $script:endMarker.Length)
        } else {
            $updated = $existing.TrimEnd() + "`n`n" + $script:block
        }
    } else {
        $updated = $script:block
    }
    $updated = $updated.TrimEnd() + "`n"
    [System.IO.File]::WriteAllText($agentsMd, $updated, $script:utf8Write)
}

# 실효 게이트웨이 cwd 결정: config.yaml terminal.cwd(절대경로·비플레이스홀더·존재) → 그 외 $HOME 폴백
# (hermes gateway/cwd_placeholder.py 의 local 백엔드 규칙과 동일. MESSAGING_CWD 는 deprecated 라 미고려)
$gatewayCwd = "$HOME"
$configYaml = Join-Path $HermesDir "config.yaml"
if (Test-Path $configYaml) {
    $inTerminal = $false
    foreach ($line in [System.IO.File]::ReadAllLines($configYaml, $utf8Read)) {
        if ($line -match '^terminal:\s*(#.*)?$') { $inTerminal = $true; continue }
        if ($inTerminal -and $line -match '^\S') { break }
        if ($inTerminal -and $line -match '^\s+cwd:\s*(.+)$') {
            $val = ($Matches[1] -replace '#.*$', '').Trim().Trim('"').Trim("'")
            if ($val -and ($val -notin @('.', 'auto', 'cwd')) -and
                [System.IO.Path]::IsPathRooted($val) -and (Test-Path $val)) {
                $gatewayCwd = $val
            }
            break
        }
    }
}

$targets = @(Join-Path $HermesDir "AGENTS.md")
if ((Resolve-Path $gatewayCwd).Path -ne (Resolve-Path $HermesDir).Path) {
    $targets += (Join-Path $gatewayCwd "AGENTS.md")
}
foreach ($t in $targets) { Update-AgentsMd $t }

$skillSrc = Join-Path $SourceDir "skills\workload-optimization"
if (Test-Path $skillSrc) {
    $skillDst = Join-Path $HermesDir "skills\workload-optimization"
    New-Item -ItemType Directory -Force $skillDst | Out-Null
    Copy-Item "$skillSrc\*" $skillDst -Recurse -Force
}

Write-Output "hermes-sync: rules applied to $($targets -join ', ')"
exit 0
