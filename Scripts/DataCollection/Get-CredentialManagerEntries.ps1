<#
.SYNOPSIS
    Inventories Windows Credential Manager entries for the invoking user.

.DESCRIPTION
    Runs `cmdkey /list` and parses the output into structured records of the
    Target, Type, and User for each stored credential. Credential secret
    values are never read or stored -- cmdkey does not expose them.

    Note: cmdkey only enumerates the credentials of the user actually
    invoking the command. Other users' Credential Manager vaults are not
    accessible from an admin context. The output explicitly notes this so
    the technician knows whether a re-run under each end user is required.

.PARAMETER NonInteractive
    Suppress all prompts. Output structured JSON to stdout. Exit cleanly.

.EXAMPLE
    .\Get-CredentialManagerEntries.ps1
    .\Get-CredentialManagerEntries.ps1 -NonInteractive

.NOTES
    Requires: Administrator (for log path access; cmdkey itself does not
              require elevation, but the toolkit is consistent on this).
    Output:   C:\PreWipeOutput\Logs\Get-CredentialManagerEntries.log
              C:\PreWipeOutput\Logs\Get-CredentialManagerEntries-Report.json
#>

[CmdletBinding()]
param(
    [switch]$NonInteractive
)

#region --- Init ---
$ScriptName = 'Get-CredentialManagerEntries'
. (Join-Path $PSScriptRoot '..\Common\Initialize-Toolkit.ps1')
$LogFile = "$LogDir\$ScriptName.log"

if (-not (Test-AdminElevation)) { exit 1 }
#endregion

#region --- Enumerate via cmdkey /list ---
$InvokingUser = "$env:USERDOMAIN\$env:USERNAME"
Write-Log "Enumerating Credential Manager entries for: $InvokingUser"

$Entries = @()
$cmdkeyOutput = $null

try {
    $cmdkeyOutput = & cmdkey.exe /list 2>&1 | Out-String
} catch {
    Write-ErrorLog "cmdkey invocation failed: $_"
    $cmdkeyOutput = ''
}

# Parse cmdkey output. Each entry block contains lines such as:
#     Target: LegacyGeneric:target=https://contoso.sharepoint.com
#     Type: Generic
#     User: user@contoso.com
# A blank line (or new "Target:" line) terminates an entry.
$lines = $cmdkeyOutput -split "`r?`n"
$current = $null

foreach ($raw in $lines) {
    $line = $raw.Trim()
    if (-not $line) {
        if ($current -and $current.Target) {
            $Entries += [PSCustomObject]$current
        }
        $current = $null
        continue
    }

    if ($line -match '^Target:\s*(.+)$') {
        if ($current -and $current.Target) {
            $Entries += [PSCustomObject]$current
        }
        $current = @{ Target = $matches[1].Trim(); Type = ''; User = '' }
        continue
    }
    if (-not $current) { continue }

    if ($line -match '^Type:\s*(.+)$') {
        $current.Type = $matches[1].Trim()
        continue
    }
    if ($line -match '^User:\s*(.+)$') {
        $current.User = $matches[1].Trim()
        continue
    }
}
if ($current -and $current.Target) {
    $Entries += [PSCustomObject]$current
}

Write-Log "Parsed $($Entries.Count) credential entries."

# Group counts by type for the summary view.
$ByType = @{}
foreach ($e in $Entries) {
    $key = if ($e.Type) { $e.Type } else { 'Unknown' }
    if (-not $ByType.ContainsKey($key)) { $ByType[$key] = 0 }
    $ByType[$key]++
    Write-Log "  [$key] Target='$($e.Target)' User='$($e.User)'"
}
#endregion

#region --- Output ---
$ContextNote = 'cmdkey only lists the invoking user''s vault. Other users'' credentials are not enumerable from this context -- run as each user to enumerate fully.'

$Summary = [PSCustomObject]@{
    Timestamp    = (Get-Date -Format 'o')
    InvokingUser = $InvokingUser
    EntryCount   = $Entries.Count
    CountsByType = $ByType
    Entries      = $Entries
    Note         = $ContextNote
}

$ReportPath = "$LogDir\$ScriptName-Report.json"
$Summary | ConvertTo-Json -Depth 5 | Out-File -FilePath $ReportPath -Encoding UTF8 -Force

if ($NonInteractive) {
    $Summary | ConvertTo-Json -Depth 5
} else {
    Write-Host ''
    Write-Host '=== Windows Credential Manager Entries ===' -ForegroundColor Cyan
    Write-Host "Invoking user: $InvokingUser"
    Write-Host "Total entries: $($Entries.Count)"
    Write-Host ''
    if ($ByType.Count -gt 0) {
        Write-Host 'Counts by type:'
        foreach ($k in ($ByType.Keys | Sort-Object)) {
            Write-Host ("  {0,-30} {1}" -f $k, $ByType[$k])
        }
        Write-Host ''
    }
    if ($Entries.Count -gt 0) {
        $Entries | Format-Table -AutoSize -Property Type, Target, User | Out-String | Write-Host
    } else {
        Write-Host '  No credentials found in this user vault.' -ForegroundColor Yellow
    }
    Write-Host "Note: $ContextNote" -ForegroundColor Yellow
    Write-Host ''
    Write-Host "Report: $ReportPath"
    Write-Host ''
}
#endregion

exit 0
