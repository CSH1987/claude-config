# claude-config:pending (Windows) - PowerShell mirror of pending.sh.
#   Stage a PRIVATE promotion proposal into _pending/<runId>/<slug>.md
#   (plan v9 0-D hop1 staging / v10 T1-G1 retro distillation output).
#   PRIVATE ONLY: writes under $env:CLAUDE_MEMORY_DIR only - never under PUBLIC claude-config.
#   Deterministic, FAIL-OPEN. Body via -Body or (redirected) stdin. ASCII no-BOM (PS 5.1 safe).
param(
    [string]$Kind = 'note',
    [string]$Slug = '',
    [string]$RunId = '',
    [string]$Source = 'manual',
    [string]$Body = '',
    [switch]$DebugMsg
)
$ErrorActionPreference = 'SilentlyContinue'
function Dbg($m) { if ($DebugMsg) { [Console]::Error.WriteLine("pending.ps1: $m") } }

try {
    if (-not $RunId) { $RunId = $env:CLAUDE_SESSION_ID }

    # --- resolve memdir ---
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
    if (-not $memDir) { Dbg 'cannot resolve CLAUDE_MEMORY_DIR'; exit 0 }

    $ts = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    if (-not $RunId) { $RunId = 'local-' + (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ') }

    function San($s) { if (-not $s) { return '' } ($s -replace '[^A-Za-z0-9._-]', '_') }
    $RunId = San $RunId
    if (-not $Slug) { $Slug = (Get-Date).ToUniversalTime().ToString('yyyyMMdd') + "-$Kind" }
    $Slug = San $Slug
    $Kind = San $Kind

    if (-not $Body) {
        try { if ([Console]::IsInputRedirected) { $Body = [Console]::In.ReadToEnd() } } catch {}
    }

    $dir = Join-Path (Join-Path $memDir '_pending') $RunId
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force -ErrorAction SilentlyContinue | Out-Null }
    $out = Join-Path $dir ($Slug + '.md')

    $nl = "`n"
    $content = "---$nl" +
        "kind: $Kind$nl" +
        "slug: $Slug$nl" +
        "run_id: $RunId$nl" +
        "created_at: $ts$nl" +
        "status: pending$nl" +
        "source: $Source$nl" +
        "---$nl$nl" + $Body + $nl
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($out, $content, $enc)
    Dbg "staged $out"
} catch {
    Dbg "error: $_"
}
exit 0
