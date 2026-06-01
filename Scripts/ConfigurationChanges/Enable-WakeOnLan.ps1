<#
.SYNOPSIS
    Checks Wake-on-LAN settings and enables WoL on all NICs that need it.

.DESCRIPTION
    - Checks current WoL status on all physical NICs via Get-NetAdapterPowerManagement.
    - For Dell devices: checks and sets BIOS WoL via Dell Command Configure (DCC).
    - Enables WoL (magic packet) on any NICs that don't have it configured.
    - Reports what was already enabled vs. what was changed.
    - AlreadyEnabled: true if all NICs were already enabled on entry.

.PARAMETER NonInteractive
    Suppress prompts. Output structured JSON to stdout.

.EXAMPLE
    .\Enable-WakeOnLan.ps1
    .\Enable-WakeOnLan.ps1 -NonInteractive

.NOTES
    Replaces the separate Test-WakeOnLan and Set-WakeOnLan steps.
    Requires: Administrator
    Output:   C:\PreWipeOutput\Logs\EnableWakeOnLan-Report.json
    NOTE: BIOS changes via DCC may require a cold boot to take effect.
#>

[CmdletBinding()]
param([switch]$NonInteractive)

#region --- Init ---
$ScriptName = 'Enable-WakeOnLan'
. (Join-Path $PSScriptRoot '..\Common\Initialize-Toolkit.ps1')
. (Join-Path $PSScriptRoot '..\Common\Find-DellCommandTool.ps1')
$LogFile = "$LogDir\$ScriptName.log"
if (-not (Test-AdminElevation)) { exit 1 }
#endregion

#region --- Vendor ---
$CS           = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
$Manufacturer = $CS.Manufacturer
$IsDell       = $Manufacturer -like '*Dell*'
Write-Log "Manufacturer: $Manufacturer | IsDell: $IsDell"
#endregion

#region --- BIOS WoL (Dell via DCC) ---
$BIOSWOLResult = [PSCustomObject]@{
    Attempted = $false
    WasEnabled = $null
    Success   = $false
    Output    = $null
    Error     = $null
}
$Changes = @()

if ($IsDell) {
    $DCCPath = Find-DellCommandConfigure
    if ($DCCPath) {
        $BIOSWOLResult.Attempted = $true
        Write-Log "Checking BIOS WoL via DCC: $DCCPath"
        try {
            $checkOutput = & $DCCPath --wakeonlan 2>&1 | Out-String
            Write-Log "DCC WoL status: $checkOutput"
            $alreadyEnabled = $checkOutput -match 'LanWithPxeBoot|Enabled' -and $checkOutput -notmatch 'Disabled'
            $BIOSWOLResult.WasEnabled = $alreadyEnabled

            if (-not $alreadyEnabled) {
                $setOutput = & $DCCPath --wakeonlan=LanWithPxeBoot 2>&1 | Out-String
                Write-Log "DCC WoL set: $setOutput"
                $BIOSWOLResult.Output = $setOutput.Trim()
                if ($LASTEXITCODE -eq 0 -or $setOutput -match 'LanWithPxeBoot|success|enabled') {
                    $BIOSWOLResult.Success = $true
                    $Changes += 'BIOS WoL set to LanWithPxeBoot via DCC'
                } else {
                    $setOutput2 = & $DCCPath --wakeonlan=Enabled 2>&1 | Out-String
                    if ($LASTEXITCODE -eq 0) {
                        $BIOSWOLResult.Success = $true
                        $Changes += 'BIOS WoL enabled via DCC'
                    } else {
                        $BIOSWOLResult.Error = "DCC returned non-zero: $setOutput"
                    }
                }
            } else {
                $BIOSWOLResult.Success = $true
                Write-Log 'BIOS WoL already enabled'
            }
        } catch {
            Write-ErrorLog "DCC WoL failed: $_"
            $BIOSWOLResult.Error = $_.ToString()
        }
    } else {
        Write-Log 'DCC not found — cannot check/set BIOS WoL' 'WARN'
        $BIOSWOLResult.Error = 'DCC not installed'
    }
}
#endregion

#region --- NIC WoL ---
$NICResults = @()
try {
    $adapters = Get-NetAdapter -ErrorAction Stop | Where-Object { $_.MediaType -eq '802.3' -and $_.Status -ne 'Not Present' }
    foreach ($nic in $adapters) {
        Write-Log "Checking NIC: $($nic.Name)"
        $nicResult = [PSCustomObject]@{
            NICName        = $nic.Name
            Description    = $nic.InterfaceDescription
            WasEnabled     = $false
            WOLMagicPacket = 'Unknown'
            PMWakeEnabled  = 'Unknown'
            Success        = $false
            Error          = $null
        }

        # Check current state
        try {
            $pm = Get-NetAdapterPowerManagement -Name $nic.Name -ErrorAction Stop
            $nicResult.WOLMagicPacket = $pm.WakeOnMagicPacket
            $nicResult.PMWakeEnabled  = $pm.AllowComputerToTurnOffDevice
            $nicResult.WasEnabled     = ($pm.WakeOnMagicPacket -eq 'Enabled')
        } catch {
            Write-Log "  Could not read power management for $($nic.Name): $_" 'DEBUG'
        }

        # Enable if needed
        if ($nicResult.WasEnabled) {
            $nicResult.Success = $true
            Write-Log "  $($nic.Name): WoL already enabled"
        } else {
            try {
                Set-NetAdapterPowerManagement -Name $nic.Name -WakeOnMagicPacket Enabled -WakeOnPattern Enabled -ErrorAction Stop
                $nicResult.WOLMagicPacket = 'Enabled'
                $nicResult.PMWakeEnabled  = 'Enabled'
                $nicResult.Success        = $true
                $Changes += "NIC '$($nic.Name)': WoL magic packet enabled"
                Write-Log "  $($nic.Name): WoL enabled"
            } catch {
                Write-ErrorLog "  Failed to enable WoL on $($nic.Name): $_"
                $nicResult.Error = $_.ToString()
                try {
                    $null = netsh interface set interface "$($nic.Name)" admin=ENABLED 2>&1
                    $nicResult.Success = $true
                    $Changes += "NIC '$($nic.Name)': interface enabled via netsh"
                } catch {}
            }
        }
        $NICResults += $nicResult
    }
} catch {
    Write-ErrorLog "NIC enumeration failed: $_"
}
#endregion

#region --- Result ---
$allWereEnabled = ($NICResults.Count -gt 0) -and -not ($NICResults | Where-Object { -not $_.WasEnabled })
$allNowEnabled  = -not ($NICResults | Where-Object { $_.Success -ne $true })

$Result = [PSCustomObject]@{
    Timestamp      = (Get-Date -Format 'o')
    Manufacturer   = $Manufacturer
    IsDell         = $IsDell
    BIOS_WOL       = $BIOSWOLResult
    NICs           = $NICResults
    Changes        = $Changes
    AlreadyEnabled = $allWereEnabled
    Success        = $allNowEnabled
}
#endregion

#region --- Output ---
$Result | ConvertTo-Json -Depth 5 | Out-File "$OutputRoot\Logs\EnableWakeOnLan-Report.json" -Force

if ($NonInteractive) {
    $Result | ConvertTo-Json -Depth 5
} else {
    Write-Host ''
    Write-Host '=== Wake-on-LAN Result ===' -ForegroundColor Cyan
    if ($IsDell) {
        $col = if ($BIOSWOLResult.Success) { 'Green' } else { 'Yellow' }
        $was = if ($BIOSWOLResult.WasEnabled -eq $true) { ' (was already enabled)' } else { '' }
        Write-Host "  BIOS WoL (DCC): $(if ($BIOSWOLResult.Success) {'Enabled'} else {'Failed'})$was" -ForegroundColor $col
    }
    foreach ($n in $NICResults) {
        $col = if ($n.Success) { 'Green' } else { 'Yellow' }
        $was = if ($n.WasEnabled) { ' (was already enabled)' } else { ' (newly enabled)' }
        Write-Host "  NIC '$($n.NICName)': $($n.WOLMagicPacket)$was" -ForegroundColor $col
    }
    if ($Changes.Count -gt 0) {
        Write-Host ''
        Write-Host '  Changes made:'
        foreach ($c in $Changes) { Write-Host "    - $c" }
    } else {
        Write-Host '  No changes needed — WoL was already fully configured' -ForegroundColor Green
    }
    Write-Host ''
}
#endregion

exit 0
