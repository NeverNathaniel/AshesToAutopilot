<#
.SYNOPSIS
    PowerShell 5.1 compatibility gate for every script in the repo.

.DESCRIPTION
    Three checks per .ps1 file:
    1. Any file containing non-ASCII bytes must carry a UTF-8 BOM. Windows
       PowerShell 5.1 reads BOM-less files as ANSI, and mangled multi-byte
       sequences include smart quotes the parser treats as string terminators.
    2. The file must parse cleanly as PS 5.1 would read it (BOM -> UTF-8,
       no BOM -> code page 1252 simulation).
    3. No PS7-only operators (?? ??= ?. and ternary ?). Detected via token
       scan on PS 7 hosts; on a real 5.1 host these token kinds do not exist,
       but there the parse check in step 2 catches them as syntax errors.

    Runs on pwsh (macOS/Linux/Windows) and on Windows PowerShell 5.1.
    Exits 0 when clean, 1 with a FAIL line per finding otherwise.

.EXAMPLE
    pwsh -NoProfile -File .\Tests\Test-Ps51Compat.ps1
#>
[CmdletBinding()]
param(
    [string]$Repo = (Split-Path -Parent $PSScriptRoot)
)

$fail = 0
$enc1252 = [System.Text.Encoding]::GetEncoding(1252)
# Exclusions match repo-RELATIVE paths so the gate also works when the repo
# root itself lives under a .worktrees/ checkout.
$Repo = (Resolve-Path $Repo).Path
$files = Get-ChildItem -Path $Repo -Recurse -Filter *.ps1 | Where-Object {
    $rel = $_.FullName.Substring($Repo.Length)
    $rel -notmatch '\.superpowers|Source Repos|[\\/]\.worktrees[\\/]|[\\/]\.git[\\/]'
}

foreach ($f in $files) {
    $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
    $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $hasNonAscii = $false
    foreach ($b in $bytes) { if ($b -gt 127) { $hasNonAscii = $true; break } }
    if ($hasNonAscii -and -not $hasBom) {
        Write-Host "FAIL [no BOM + non-ASCII] $($f.Name)"
        $fail++
    }

    # Simulate how PS 5.1 decodes the file
    $text51 = if ($hasBom) { [System.Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3) }
              else { $enc1252.GetString($bytes) }
    $errs = $null; $tokens = $null
    [System.Management.Automation.Language.Parser]::ParseInput($text51, [ref]$tokens, [ref]$errs) | Out-Null
    if ($errs.Count -gt 0) {
        $msg = ($errs[0].Message -replace '\s+', ' ')
        if ($msg.Length -gt 70) { $msg = $msg.Substring(0, 70) }
        Write-Host "FAIL [PS5.1 parse: $msg] $($f.Name):$($errs[0].Extent.StartLineNumber)"
        $fail++
    }

    # PS7-only operator scan, including tokens nested inside expandable strings.
    # On Windows PowerShell 5.1 these TokenKind names do not exist so the
    # comparison never matches; the parse check above covers 5.1 hosts.
    $stack = New-Object System.Collections.Stack
    foreach ($t in $tokens) { $stack.Push($t) }
    while ($stack.Count -gt 0) {
        $t = $stack.Pop()
        if ("$($t.Kind)" -in @('QuestionQuestion', 'QuestionQuestionEquals', 'QuestionDot', 'QuestionMark')) {
            Write-Host "FAIL [PS7 operator $($t.Kind)] $($f.Name):$($t.Extent.StartLineNumber)"
            $fail++
        }
        if ($t.PSObject.Properties['NestedTokens'] -and $t.NestedTokens) {
            foreach ($nt in $t.NestedTokens) { $stack.Push($nt) }
        }
    }
}

if ($fail -eq 0) {
    Write-Host "OK: $($files.Count) files pass the PS 5.1 compatibility gate"
    exit 0
}
Write-Host "$fail failure(s)"
exit 1
