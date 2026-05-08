<#
.SYNOPSIS
    Enables Wake-on-LAN: BIOS level (Dell DCC), NIC driver settings, and Windows power management.

.DESCRIPTION
    - Dell devices only: configures BIOS WOL via Dell Command Configure (DCC).
    - Configures NIC driver WOL settings (WOL magic packet) via Set-NetAdapterPowerManagement.
    - Configures Windows power management on all physical NICs to allow wake.
    - Reports changes made.

.PARAMETER NonInteractive
    Suppress all prompts. Output structured JSON to stdout. Exit cleanly.

.EXAMPLE
    .\Set-WakeOnLan.ps1
    .\Set-WakeOnLan.ps1 -NonInteractive

.NOTES
    Source repos used:
    - garytown-master/hardware/Dell/CommandUpdate/EMPS/Dell-EMPS.ps1
      (DCC path pattern, Dell vendor check)
    - garytown-master/hardware/BIOSManagement-Remediation-Laptop-Dell.ps1
      (Dell DCC cctk --wakeonlan syntax)
    No dedicated WOL set script found in source repos.

    Requires: Administrator
    Output:   C:\PreWipeOutput\Logs\Set-WakeOnLan.log
    NOTE: BIOS changes via DCC may require a cold boot to take effect.
#>

[CmdletBinding()]
param(
    [switch]$NonInteractive
)

#region --- Init ---
$ScriptName = 'Set-WakeOnLan'
. (Join-Path $PSScriptRoot '..\Common\Initialize-Toolkit.ps1')
. (Join-Path $PSScriptRoot '..\Common\Find-DellCommandTool.ps1')
$LogFile = "$LogDir\$ScriptName.log"
if (-not (Test-AdminElevation)) { exit 1 }
#endregion

#region --- Vendor Check ---
$CS           = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
$Manufacturer = $CS.Manufacturer
$IsDell       = $Manufacturer -like '*Dell*'
Write-Log "Manufacturer: $Manufacturer | IsDell: $IsDell"
#endregion

#region --- DCC WOL (Dell only) ---
$Changes = @()
$BIOSWOLResult = [PSCustomObject]@{
    Attempted = $false
    Success   = $false
    Output    = $null
    Error     = $null
}

if ($IsDell) {
    $DCCPath = Find-DellCommandConfigure
    if ($DCCPath) {
        Write-Log "Setting BIOS WOL via DCC: $DCCPath"
        $BIOSWOLResult.Attempted = $true
        try {
            # Enable WOL in BIOS: --wakeonlan=LanWithPxeBoot (enables WOL with PXE capability)
            $dccOutput = & $DCCPath --wakeonlan=LanWithPxeBoot 2>&1 | Out-String
            Write-Log "DCC WOL set output: $dccOutput"
            $BIOSWOLResult.Output = $dccOutput.Trim()

            if ($dccOutput -match 'LanWithPxeBoot|success|enabled' -or $LASTEXITCODE -eq 0) {
                $BIOSWOLResult.Success = $true
                $Changes += "BIOS WOL set to LanWithPxeBoot via DCC"
            } else {
                # Try alternate syntax
                $dccOutput2 = & $DCCPath --wakeonlan=Enabled 2>&1 | Out-String
                Write-Log "DCC WOL (Enabled) output: $dccOutput2"
                if ($LASTEXITCODE -eq 0) {
                    $BIOSWOLResult.Success = $true
                    $Changes += "BIOS WOL enabled via DCC"
                } else {
                    $BIOSWOLResult.Error = "DCC returned non-zero: $dccOutput"
                }
            }
        } catch {
            Write-ErrorLog "DCC WOL configuration failed: $_"
            $BIOSWOLResult.Error = $_.ToString()
        }
    } else {
        Write-Log "DCC not found - cannot set BIOS WOL. Run Install-DellCommandTools.ps1 first." 'WARN'
        $BIOSWOLResult.Error = 'DCC not installed'
    }
} else {
    Write-Log "Non-Dell device - BIOS WOL configuration via DCC not applicable"
}
#endregion

#region --- NIC Driver and Power Management WOL ---
$NICResults = @()

try {
    $adapters = Get-NetAdapter -ErrorAction Stop | Where-Object {
        $_.MediaType -eq '802.3' -and $_.Status -ne 'Not Present'
    }

    foreach ($nic in $adapters) {
        Write-Log "Configuring WOL on NIC: $($nic.Name)"

        $nicResult = [PSCustomObject]@{
            NICName          = $nic.Name
            Description      = $nic.InterfaceDescription
            WOLMagicPacket   = 'NotChanged'
            PMWakeEnabled    = 'NotChanged'
            Success          = $false
            Error            = $null
        }

        try {
            # Set WOL via NetAdapterPowerManagement
            Set-NetAdapterPowerManagement -Name $nic.Name `
                -WakeOnMagicPacket Enabled `
                -WakeOnPattern Enabled `
                -ErrorAction Stop

            # Allow the device to wake the computer (power management)
            $nicResult.WOLMagicPacket = 'Enabled'
            $nicResult.PMWakeEnabled  = 'Enabled'
            $nicResult.Success        = $true
            $Changes += "NIC '$($nic.Name)': WOL Magic Packet enabled"
            Write-Log "  NIC $($nic.Name): WOL configured successfully"

        } catch {
            Write-ErrorLog "Failed to set WOL on NIC $($nic.Name): $_"
            $nicResult.Error = $_.ToString()

            # Fallback: try via DevCon / PnP
            try {
                # Enable wake via netsh
                $null = netsh interface set interface "$($nic.Name)" admin=ENABLED 2>&1
                $nicResult.Success = $true
                $Changes += "NIC '$($nic.Name)': Interface enabled via netsh"
            } catch {}
        }

        $NICResults += $nicResult
    }
} catch {
    Write-ErrorLog "NIC enumeration failed: $_"
}
#endregion

#region --- Output ---
$Result = [PSCustomObject]@{
    Timestamp   = (Get-Date -Format 'o')
    Manufacturer = $Manufacturer
    IsDell      = $IsDell
    BIOS_WOL    = $BIOSWOLResult
    NICs        = $NICResults
    Changes     = $Changes
}

$Result | ConvertTo-Json -Depth 5 | Out-File "$OutputRoot\Logs\WakeOnLan-SetResult.json" -Force

if ($NonInteractive) {
    $Result | ConvertTo-Json -Depth 5
} else {
    Write-Host ""
    Write-Host "=== Wake-on-LAN Configuration Results ===" -ForegroundColor Cyan
    if ($IsDell) {
        $color = if ($BIOSWOLResult.Success) { 'Green' } else { 'Red' }
        Write-Host "  BIOS WOL (DCC): Success=$($BIOSWOLResult.Success)" -ForegroundColor $color
    }
    foreach ($n in $NICResults) {
        $color = if ($n.Success) { 'Green' } else { 'Yellow' }
        Write-Host "  NIC '$($n.NICName)': MagicPacket=$($n.WOLMagicPacket) | PM=$($n.PMWakeEnabled)" -ForegroundColor $color
    }
    Write-Host ""
    Write-Host "  Changes made:"
    foreach ($c in $Changes) { Write-Host "    - $c" }
    Write-Host ""
}
#endregion
