# SessionStart hook (Windows) - inject effort/ultracode reminder into Claude context each session.
# Hooks cannot run /effort, so this only "informs". The additionalContext on stdout is injected
# as a system-reminder every session (per official hooks docs).
# The reminder body is read from effort-reminder.txt (UTF-8) in the same folder, so this script
# contains NO non-ASCII and is immune to PS 5.1's ANSI-codepage decoding of BOM-less .ps1 files.
$ErrorActionPreference = 'SilentlyContinue'
$txt = Join-Path $PSScriptRoot 'effort-reminder.txt'
$ctx = [System.IO.File]::ReadAllText($txt, (New-Object System.Text.UTF8Encoding($false)))
$ctx = $ctx.TrimEnd([char]13, [char]10)
Add-Type -AssemblyName System.Web.Extensions
$ser = New-Object System.Web.Script.Serialization.JavaScriptSerializer
$json = $ser.Serialize(@{ hookSpecificOutput = @{ hookEventName = 'SessionStart'; additionalContext = $ctx } })
$bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
$out = [Console]::OpenStandardOutput()
$out.Write($bytes, 0, $bytes.Length)
$out.Flush()
exit 0
