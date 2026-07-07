# PreToolUse(Bash) 훅: 테스트 실행 명령의 출력을 실패·요약 라인만 남기도록 재작성해 컨텍스트를 절약
# 근거: code.claude.com/docs/en/costs "Offload processing to hooks" 공식 예제의 PowerShell 포팅
$raw = [Console]::In.ReadToEnd()
try { $data = $raw | ConvertFrom-Json } catch { Write-Output "{}"; exit 0 }
$cmd = [string]$data.tool_input.command
if ([string]::IsNullOrWhiteSpace($cmd)) { Write-Output "{}"; exit 0 }

# 이미 필터가 적용된 명령이면 이중 적용 방지
if ($cmd -match [regex]::Escape("grep -A 3 -E '(FAIL")) { Write-Output "{}"; exit 0 }

# 테스트 러너 명령만 대상 (전체 실행 형태). 특정 테스트 지정 실행은 원문 출력 유지
if ($cmd -match '^\s*(npm test|npx vitest run|pytest|python -m pytest|go test)(\s|$)') {
    $filtered = "$cmd 2>&1 | grep -A 3 -E '(FAIL|FAILED|ERROR|error:|passed|failed)' | head -100"
    $out = @{
        hookSpecificOutput = @{
            hookEventName      = "PreToolUse"
            permissionDecision = "allow"
            updatedInput       = @{ command = $filtered }
        }
    } | ConvertTo-Json -Depth 5 -Compress
    Write-Output $out
} else {
    Write-Output "{}"
}
exit 0
