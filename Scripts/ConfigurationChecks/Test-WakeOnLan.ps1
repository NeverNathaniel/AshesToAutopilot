<#
.SYNOPSIS
    Reports all Wake-on-LAN related settings: BIOS (Dell DCC), NIC driver, and Windows power management.

.DESCRIPTION
    - For Dell devices: checks BIOS WOL setting via Dell Command Configure (DCC).
    - Checks NIC driver WOL settings (WOL magic packet, wake on pattern match) via registry/WMI.
    - Checks Windows power management settings on network adapters.
    - Reports what is configured and what is missing.

.PARAMETER NonInteractive
    Suppress all prompts. Output structured JSON to stdout. Exit cleanly.

.EXAMPLE
    .\Test-WakeOnLan.ps1
    .\Test-WakeOnLan.ps1 -NonInteractive

.NOTES
    Source repos used:
    - garytown-master/hardware/Dell/CommandUpdate/EMPS/Dell-EMPS.ps1
      (DCC path pattern, Dell vendor check)
    - garytown-master/hardware/BIOSManagement-Remediation-Laptop-Dell.ps1
      (Dell BIOS setting read patterns)
    No dedicated WOL test script found in source repos.

    Requires: Administrator
    Output:   C:\PreWipeOutput\Logs\Test-WakeOnLan.log
#>

[CmdletBinding()]
param(
    [switch]$NonInteractive
)

#region --- Init ---
$ScriptName = 'Test-WakeOnLan'
. (Join-Path $PSScriptRoot '..\Common\Initialize-Toolkit.ps1')
$LogFile = "$LogDir\$ScriptName.log"
if (-not (Test-AdminElevation)) { exit 1 }
#endregion

#region --- Vendor Check ---
$CS           = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
$Manufacturer = $CS.Manufacturer
$IsDell       = $Manufacturer -like '*Dell*'
Write-Log "Manufacturer: $Manufacturer | IsDell: $IsDell"
#endregion

#region --- DCC Check (Dell only) ---
function Get-DCCExePath {
    $candidates = @(
        "$env:ProgramFiles\Dell\Command Configure\X86_64\cctk.exe",
        "$env:ProgramFiles\Dell\Command Configure\cctk.exe",
        "${env:ProgramFiles(x86)}\Dell\Command Configure\X86_64\cctk.exe",
        "${env:ProgramFiles(x86)}\Dell\Command Configure\cctk.exe"
    )
    foreach ($p in $candidates) { if (Test-Path $p) { return $p } }
    return $null
}

$BIOSWOLStatus = 'NotChecked'
$DCCPath       = $null

if ($IsDell) {
    $DCCPath = Get-DCCExePath
    if ($DCCPath) {
        Write-Log "DCC found: $DCCPath"
        try {
            # Query WOL BIOS setting via DCC
            $dccOutput = & $DCCPath --wakeonlan 2>&1 | Out-String
            Write-Log "DCC WOL output: $dccOutput"

            if ($dccOutput -match 'WakeOnLAN=(\w+)' -or $dccOutput -match 'wol.*=.*(\w+)') {
                $BIOSWOLStatus = $Matches[1]
            } elseif ($dccOutput -match 'LanWithPxeBoot|LANwithPXEBoot') {
                $BIOSWOLStatus = 'Enabled (LanWithPxeBoot)'
            } elseif ($dccOutput -match 'Disabled|disabled') {
                $BIOSWOLStatus = 'Disabled'
            } elseif ($dccOutput -match 'Enabled|enabled') {
                $BIOSWOLStatus = 'Enabled'
            } else {
                $BIOSWOLStatus = "Unknown: $dccOutput"
            }
        } catch {
            Write-ErrorLog "DCC WOL query failed: $_"
            $BIOSWOLStatus = "Error: $_"
        }
    } else {
        Write-Log "DCC not found - cannot check BIOS WOL setting" 'WARN'
        $BIOSWOLStatus = 'DCCNotInstalled'
    }
}
#endregion

#region --- NIC Driver WOL Settings ---
$NICResults = @()

try {
    # Get physical network adapters (Ethernet only)
    $adapters = Get-NetAdapter -ErrorAction Stop | Where-Object {
        $_.MediaType -eq '802.3' -and $_.Status -ne 'Not Present'
    }

    foreach ($nic in $adapters) {
        Write-Log "Checking NIC: $($nic.Name) [$($nic.InterfaceDescription)]"

        $nicResult = [PSCustomObject]@{
            NICName          = $nic.Name
            Description      = $nic.InterfaceDescription
            Status           = $nic.Status
            WOLMagicPacket   = 'Unknown'
            WakeOnPattern    = 'Unknown'
            PMWakeEnabled    = 'Unknown'
            DeviceInstanceID = $nic.DeviceID
        }

        # Check NIC power management via registry
        # HKLM:\SYSTEM\CurrentControlSet\Enum\{DeviceID}\Device Parameters\WakeOnLan
        # Or via advanced properties
        try {
            $devPath = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($nic.PnPDeviceID)"
            $ndisPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4D36E972-E325-11CE-BFC1-08002BE10318}"

            # Find the adapter's registry key by matching MAC address
            $regAdapterKeys = Get-ChildItem $ndisPath -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -notmatch 'Properties' }

            foreach ($key in $regAdapterKeys) {
                $props = Get-ItemProperty $key.PSPath -ErrorAction SilentlyContinue
                if ($props.NetCfgInstanceId -eq $nic.InterfaceGuid -or
                    $props.NetCfgInstanceId -eq "{$($nic.InterfaceGuid)}") {

                    # WOL driver settings
                    $wolKey = "$($key.PSPath)\Ndi\Params\WakeOnMagicPacket"
                    if (Test-Path $wolKey) {
                        $wolVal = (Get-ItemProperty $key.PSPath -Name '*WakeOnMagicPacket*' -ErrorAction SilentlyContinue)
                        $nicResult.WOLMagicPacket = if ($wolVal) { $wolVal.WakeOnMagicPacket ?? 'Found' } else { 'SettingExists' }
                    }
                    break
                }
            }

            # Power management: check via Get-NetAdapterPowerManagement
            try {
                $pm = Get-NetAdapterPowerManagement -Name $nic.Name -ErrorAction Stop
                $nicResult.WOLMagicPacket = $pm.WakeOnMagicPacket
                $nicResult.WakeOnPattern  = $pm.WakeOnPattern
                $nicResult.PMWakeEnabled  = $pm.AllowComputerToTurnOffDevice
            } catch {
                Write-Log "  Get-NetAdapterPowerManagement failed for $($nic.Name): $_" 'DEBUG'
            }

        } catch {
            Write-Log "  NIC registry check failed for $($nic.Name): $_" 'WARN'
        }

        $NICResults += $nicResult
        Write-Log "  $($nic.Name): MagicPacket=$($nicResult.WOLMagicPacket) | WakeOnPattern=$($nicResult.WakeOnPattern) | PMWake=$($nicResult.PMWakeEnabled)"
    }
} catch {
    Write-ErrorLog "NIC enumeration failed: $_"
}
#endregion

#region --- Output ---
$Result = [PSCustomObject]@{
    Timestamp        = (Get-Date -Format 'o')
    Manufacturer     = $Manufacturer
    IsDell           = $IsDell
    DCCPath          = $DCCPath
    BIOS_WOL_Status  = $BIOSWOLStatus
    NICs             = $NICResults
    Summary          = @()
}

# Build summary
$issues = @()
if ($IsDell -and $BIOSWOLStatus -match 'Disabled|Not') { $issues += "BIOS WOL is disabled" }
if ($IsDell -and $BIOSWOLStatus -match 'DCCNotInstalled') { $issues += "DCC not installed - BIOS WOL cannot be checked" }
foreach ($n in $NICResults) {
    if ($n.WOLMagicPacket -eq 'Disabled') { $issues += "NIC '$($n.NICName)': WOL Magic Packet disabled" }
    if ($n.PMWakeEnabled -eq 'Disabled')  { $issues += "NIC '$($n.NICName)': Windows Power Management wake disabled" }
}
$Result.Summary = if ($issues) { $issues } else { @('All checked WOL settings appear configured') }

$Result | ConvertTo-Json -Depth 5 | Out-File "$OutputRoot\Logs\WakeOnLan-Status.json" -Force

if ($NonInteractive) {
    $Result | ConvertTo-Json -Depth 5
} else {
    Write-Host ""
    Write-Host "=== Wake-on-LAN Status ===" -ForegroundColor Cyan
    if ($IsDell) { Write-Host "  BIOS WOL (DCC): $BIOSWOLStatus" }
    foreach ($n in $NICResults) {
        Write-Host "  NIC: $($n.NICName) | MagicPacket=$($n.WOLMagicPacket) | Pattern=$($n.WakeOnPattern) | PMWake=$($n.PMWakeEnabled)"
    }
    Write-Host ""
    Write-Host "  Issues:"
    foreach ($s in $Result.Summary) { Write-Host "    - $s" }
    Write-Host ""
    Write-Host "Report: $OutputRoot\Logs\WakeOnLan-Status.json"
    Write-Host ""
}
#endregion
