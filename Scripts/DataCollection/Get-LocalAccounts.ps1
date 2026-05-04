<#
.SYNOPSIS
    Inventories local user accounts that survive an Autopilot Reset.

.DESCRIPTION
    Enumerates local Windows user accounts (excluding the well-known system
    accounts: Administrator, Guest, DefaultAccount, WDAGUtilityAccount) and
    reports their state. For each non-system account it captures Name,
    Enabled, LastLogon, Description, PasswordLastSet, SID, and IsAdmin
    (membership in the local Administrators group).

    The script prefers Get-LocalUser (PowerShell 5.1+ on Windows 10/11) and
    falls back to Get-CimInstance Win32_UserAccount when Get-LocalUser is
    unavailable.

.PARAMETER NonInteractive
    Suppress all prompts. Output structured JSON to stdout. Exit cleanly.

.EXAMPLE
    .\Get-LocalAccounts.ps1
    .\Get-LocalAccounts.ps1 -NonInteractive

.NOTES
    Requires: Administrator
    Output:   C:\PreWipeOutput\Logs\Get-LocalAccounts.log
              C:\PreWipeOutput\Logs\Get-LocalAccounts-Report.json
#>

[CmdletBinding()]
param(
    [switch]$NonInteractive
)

#region --- Init ---
$ScriptName = 'Get-LocalAccounts'
. (Join-Path $PSScriptRoot '..\Common\Initialize-Toolkit.ps1')
$LogFile = "$LogDir\$ScriptName.log"

if (-not (Test-AdminElevation)) { exit 1 }
#endregion

#region --- Discover local Administrators members ---
$AdminSidSet = @{}
try {
    $adminMembers = Get-LocalGroupMember -Group 'Administrators' -ErrorAction Stop
    foreach ($m in $adminMembers) {
        $sid = $null
        if ($m.SID -and $m.SID.Value) { $sid = $m.SID.Value }
        elseif ($m.SID)               { $sid = [string]$m.SID }
        if ($sid) { $AdminSidSet[$sid] = $true }
    }
    Write-Log "Local Administrators members: $($AdminSidSet.Count)"
} catch {
    Write-Log "Get-LocalGroupMember failed; admin flag will be best-effort: $_" 'WARN'
}
#endregion

#region --- Enumerate local accounts ---
$SystemAccounts = @('Administrator', 'Guest', 'DefaultAccount', 'WDAGUtilityAccount')
$NonSystem = @()

$useLocalUser = [bool](Get-Command Get-LocalUser -ErrorAction SilentlyContinue)

if ($useLocalUser) {
    Write-Log 'Enumerating via Get-LocalUser.'
    try {
        $localUsers = Get-LocalUser -ErrorAction Stop
    } catch {
        Write-ErrorLog "Get-LocalUser failed: $_"
        $localUsers = @()
    }

    foreach ($u in $localUsers) {
        if ($SystemAccounts -contains $u.Name) { continue }
        $sidValue = if ($u.SID) { $u.SID.Value } else { $null }
        $isAdmin  = $false
        if ($sidValue -and $AdminSidSet.ContainsKey($sidValue)) { $isAdmin = $true }

        $NonSystem += [PSCustomObject]@{
            Name            = $u.Name
            Enabled         = [bool]$u.Enabled
            IsAdmin         = $isAdmin
            LastLogon       = $u.LastLogon
            Description     = $u.Description
            PasswordLastSet = $u.PasswordLastSet
            SID             = $sidValue
        }
        Write-Log "  $($u.Name) Enabled=$($u.Enabled) Admin=$isAdmin LastLogon=$($u.LastLogon)"
    }
} else {
    Write-Log 'Get-LocalUser unavailable; falling back to Win32_UserAccount.' 'WARN'
    try {
        $cimUsers = Get-CimInstance -ClassName Win32_UserAccount -Filter 'LocalAccount=True' -ErrorAction Stop
    } catch {
        Write-ErrorLog "Win32_UserAccount query failed: $_"
        $cimUsers = @()
    }

    foreach ($u in $cimUsers) {
        if ($SystemAccounts -contains $u.Name) { continue }
        $sidValue = $u.SID
        $isAdmin  = $false
        if ($sidValue -and $AdminSidSet.ContainsKey($sidValue)) { $isAdmin = $true }

        # Win32_UserAccount Disabled is the inverse of Enabled.
        $enabled = $true
        if ($u.PSObject.Properties['Disabled']) { $enabled = -not $u.Disabled }

        $NonSystem += [PSCustomObject]@{
            Name            = $u.Name
            Enabled         = [bool]$enabled
            IsAdmin         = $isAdmin
            LastLogon       = $null
            Description     = $u.Description
            PasswordLastSet = $null
            SID             = $sidValue
        }
        Write-Log "  $($u.Name) Enabled=$enabled Admin=$isAdmin (CIM fallback; LastLogon/PwdLastSet unavailable)"
    }
}

$AdminCount = ($NonSystem | Where-Object { $_.IsAdmin }).Count
Write-Log "Non-system accounts: $($NonSystem.Count) | Admins among them: $AdminCount"
#endregion

#region --- Output ---
$Summary = [PSCustomObject]@{
    Timestamp         = (Get-Date -Format 'o')
    AccountCount      = $NonSystem.Count
    NonSystemAccounts = $NonSystem
    AdminCount        = $AdminCount
}

$ReportPath = "$LogDir\$ScriptName-Report.json"
$Summary | ConvertTo-Json -Depth 5 | Out-File -FilePath $ReportPath -Encoding UTF8 -Force

if ($NonInteractive) {
    $Summary | ConvertTo-Json -Depth 5
} else {
    Write-Host ''
    Write-Host '=== Local Accounts (excluding system accounts) ===' -ForegroundColor Cyan
    Write-Host "Total non-system accounts: $($NonSystem.Count) | Admins: $AdminCount"
    Write-Host ''
    if ($NonSystem.Count -eq 0) {
        Write-Host '  No non-system local accounts found.' -ForegroundColor Green
    } else {
        $header = "{0,-25} {1,-8} {2,-8} {3}" -f 'Name', 'Enabled', 'IsAdmin', 'LastLogon'
        Write-Host $header
        Write-Host ('-' * $header.Length)
        foreach ($a in $NonSystem) {
            $line = "{0,-25} {1,-8} {2,-8} {3}" -f $a.Name, $a.Enabled, $a.IsAdmin, $a.LastLogon
            if ($a.Enabled -and $a.IsAdmin) {
                Write-Host $line -ForegroundColor Yellow
            } else {
                Write-Host $line
            }
        }
    }
    Write-Host ''
    Write-Host "Report: $ReportPath"
    Write-Host ''
}
#endregion
