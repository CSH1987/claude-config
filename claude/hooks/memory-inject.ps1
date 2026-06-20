# SessionStart hook (Windows) - deterministically inject the user's canonical profile
# (profile/user-profile.json from the lifelong memory store) into Claude's context each
# session, so stable preferences/identity need not be re-explained (plan v9 0-I / A1).
#
# Determinism: this hook does NOT depend on the model. It resolves CLAUDE_MEMORY_DIR via the
# memdir resolver (~/.claude/lib/memdir.ps1), reads profile/user-profile.json, and emits its
# contents as additionalContext (same stdout JSON shape as effort-reminder.ps1, per the
# official SessionStart hooks docs).
#
# Fail-safe (never blocks a session): on ANY error - resolver missing, env unset, file
# absent/empty/unparseable - it stays silent and exits 0 with no stdout.
#
# Encoding: this script body is pure ASCII (no Korean output) -> intentionally NO UTF-8 BOM,
# exactly like effort-reminder.ps1, so PS 5.1's ANSI-codepage decoding of BOM-less .ps1 cannot
# corrupt it. The user's profile data is read as raw UTF-8 BYTES and parsed - it is never
# embedded into this file as a string literal - so non-ASCII profile values stay intact.
$ErrorActionPreference = 'SilentlyContinue'
try {
    # --- 1. Resolve CLAUDE_MEMORY_DIR (resolver = single source of truth; never hardcode) ---
    #     -NoEnsure: read-only caller, do not create directories. -Export: emit assignable lines.
    #     Resolver writes a Korean fallback notice to stderr when env is unset; we discard stderr
    #     (2>$null) so it never leaks into the hook's stdout JSON.
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
    if (-not $memDir) { exit 0 }   # fail-safe: cannot resolve store -> stay silent

    # --- 2. Read profile/user-profile.json as raw UTF-8 bytes (BOM-tolerant) ---
    $profilePath = Join-Path (Join-Path $memDir 'profile') 'user-profile.json'
    if (-not (Test-Path $profilePath)) { exit 0 }
    $raw = [System.IO.File]::ReadAllText($profilePath, (New-Object System.Text.UTF8Encoding($false)))
    if (-not $raw -or -not $raw.Trim()) { exit 0 }   # empty file -> silent

    $obj = $raw | ConvertFrom-Json   # malformed JSON -> throws -> caught below -> silent
    if (-not $obj) { exit 0 }

    # --- 3. Flatten top-level fields into compact "key: value" lines (schema-agnostic) ---
    #     Works with whatever schema profile/user-profile.json ends up using: scalars are shown
    #     directly; shallow arrays become comma-joined; nested objects become key=val; pairs;
    #     deeper/blank values are skipped. Keeps injection short and deterministic.
    function Format-Val($v) {
        if ($null -eq $v) { return '' }
        if ($v -is [bool]) { return ($v.ToString().ToLower()) }
        if ($v -is [string]) { return $v.Trim() }
        if ($v -is [System.Array]) {
            $parts = @()
            foreach ($e in $v) { $s = Format-Val $e; if ($s) { $parts += $s } }
            return ($parts -join ', ')
        }
        if ($v -is [System.Management.Automation.PSCustomObject]) {
            $parts = @()
            foreach ($p in $v.PSObject.Properties) { $s = Format-Val $p.Value; if ($s) { $parts += ("{0}={1}" -f $p.Name, $s) } }
            return ($parts -join '; ')
        }
        return ([string]$v).Trim()
    }

    # cold-start guard (plan v9 A1 honesty): never inject meta keys, so an empty seed
    # produces zero body lines and the hook stays silent (exit 0) instead of asserting
    # scaffolding defaults as established facts.
    $metaKeys = @('schema_version', 'updated_at', 'updated_by')
    $bodyLines = @()
    foreach ($p in $obj.PSObject.Properties) {
        if ($metaKeys -contains $p.Name) { continue }
        $val = Format-Val $p.Value
        if ($val) { $bodyLines += ("- {0}: {1}" -f $p.Name, $val) }
    }
    if ($bodyLines.Count -eq 0) { exit 0 }   # nothing meaningful -> silent

    $header = 'User profile (canonical lifelong memory; injected deterministically each session). ' +
              'These are stable, already-established facts/preferences - honor them without asking again:'
    $ctx = $header + "`n" + ($bodyLines -join "`n")

    # --- 4. Emit additionalContext (identical shape/method to effort-reminder.ps1) ---
    Add-Type -AssemblyName System.Web.Extensions
    $ser = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $json = $ser.Serialize(@{ hookSpecificOutput = @{ hookEventName = 'SessionStart'; additionalContext = $ctx } })
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $out = [Console]::OpenStandardOutput()
    $out.Write($bytes, 0, $bytes.Length)
    $out.Flush()
} catch {
    # Never block a session on profile-injection failure.
}
exit 0
