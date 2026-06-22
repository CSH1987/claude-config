# claude-config:memory-sync (Windows) — PRIVATE claude-memory 저장소 클라우드 이중백업 (컴포넌트②·기둥7).
#   -Mode start=pull / -Mode end=push. resolver 로 $CLAUDE_MEMORY_DIR 해석 후 config-sync.ps1 에 위임
#   (검증된 fail-open pull/push/lock 재사용). 세션 절대 안 막음. 끄기: CLAUDE_MEMORY_NO_SYNC=1.
#   claude-memory 는 PRIVATE 전용(leak-guard 없음 — config-sync 가 githooks 부재로 self-heal 자동 스킵).
#   ASCII no-BOM (PS 5.1 safe).
param([string]$Mode = "")
$ErrorActionPreference = 'SilentlyContinue'
if ($env:CLAUDE_MEMORY_NO_SYNC -eq '1') { exit 0 }

# resolve memdir
$memDir = $env:CLAUDE_MEMORY_DIR
if (-not $memDir) {
    $resolver = Join-Path $env:USERPROFILE '.claude\lib\memdir.ps1'
    if (Test-Path $resolver) {
        $lines = & powershell -NoProfile -ExecutionPolicy Bypass -File $resolver -NoEnsure -Export 2>$null
        foreach ($ln in @($lines)) {
            if ($ln -match "^\s*\`$env:CLAUDE_MEMORY_DIR\s*=\s*'(.*)'\s*$") { $memDir = $Matches[1] }
        }
    }
}
if (-not $memDir) { exit 0 }
if (-not (Test-Path (Join-Path $memDir '.git'))) { exit 0 }   # not a git repo yet -> nothing to sync

# delegate to config-sync.ps1 with claude-memory as -Repo (deployed > repo-relative)
$cs = Join-Path $env:USERPROFILE '.claude\hooks\config-sync.ps1'
if (-not (Test-Path $cs)) {
    $here = $PSScriptRoot
    if (-not $here) { $here = Split-Path -Parent $MyInvocation.MyCommand.Path }
    $cs = Join-Path $here 'config-sync.ps1'
}
if (-not (Test-Path $cs)) { exit 0 }
& powershell -NoProfile -ExecutionPolicy Bypass -File $cs -Mode $Mode -Repo $memDir
exit 0
