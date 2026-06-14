# claude-config global PreToolUse guardrail (Windows wrapper). FAIL-OPEN.
# Forwards the hook stdin JSON to guardrails.py. If python3 is missing or anything errors,
# prints nothing and exits 0 -> the tool is ALLOWED (the guardrail never breaks a tool itself).
$ErrorActionPreference = 'SilentlyContinue'
try {
    $stdin = [Console]::In.ReadToEnd()
    if (Get-Command python3 -ErrorAction SilentlyContinue) {
        $py = Join-Path $PSScriptRoot 'guardrails.py'
        if (Test-Path $py) { $stdin | & python3 $py 2>$null }
    }
} catch { }
exit 0
