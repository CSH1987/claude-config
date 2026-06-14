# dotfiles:claude-ultra — `claude` 를 항상 ultracode 로 실행 (PowerShell).
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
