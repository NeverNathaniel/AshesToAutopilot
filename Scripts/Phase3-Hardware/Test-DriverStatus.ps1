<#
.SYNOPSIS
    Checks for outdated or problematic device drivers.

.DESCRIPTION
    - Dell devices: uses Dell Command Update (DCU) scan mode to check for driver updates.
    - Non-Dell: uses Get-PnpDevice and Win32_PnPSignedDriver to report driver versions
      and flag devices with errors/warnings.
    - Reports: driver name, current version, update available (if determinable).

.PARAMETER NonInteractive
    Suppress all prompts. Output structured JSON to stdout. Exit cleanly.

.EXAMPLE
    .\Test-DriverStatus.ps1
    .\Test-DriverStatus.ps1 -NonInteractive

.NOTES
    Source repos used:
    - garytown-master/OSD/TroubleShootingSteps/Get-HardwareDevicesAndDrivers.ps1
      (Get-PnpDevice and Win32_PnPSignedDriver query patterns)
    - garytown-master/hardware/Dell/CommandUpdate/EMPS/Dell-EMPS.ps1
      (DCU scan with updateType filter)
    - garytown-master/Intune/Update-DellApps-Detect.ps1
      (DCU detection patterns)

    Requires: Administrator
    Output:   C:\PreWipeOutput\Logs\Test-DriverStatus.log
#>

[CmdletBinding()]
param(
    [switch]$NonInteractive
)

#region --- Init ---
$ScriptName = 'Test-DriverStatus'
$OutputRoot = 'C:\PreWipeOutput'
$LogDir     = "$OutputRoot\Logs"
$LogFile    = "$LogDir\$ScriptName.log"
$ErrorLog   = "$OutputRoot\errors.log"

if (-not (Test-Path $OutputRoot)) { New-Item -Path $OutputRoot -ItemType Directory -Force | Out-Null }
if (-not (Test-Path $LogDir))     { New-Item -Path $LogDir     -ItemType Directory -Force | Out-Null }

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    "$ts [$Level] $Message" | Out-File -FilePath $LogFile -Append
    if (-not $NonInteractive) { Write-Host "$ts [$Level] $Message" }
}

function Write-ErrorLog {
    param([string]$Message)
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    "$ts [ERROR] [$ScriptName] $Message" | Out-File -FilePath $ErrorLog -Append
    Write-Log $Message 'ERROR'
}

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "ERROR: This script must be run as Administrator." -ForegroundColor Red
    exit 1
}
#endregion

#region --- Vendor Check ---
$CS           = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
$Manufacturer = $CS.Manufacturer
$IsDell       = $Manufacturer -like '*Dell*'
Write-Log "Manufacturer: $Manufacturer | IsDell: $IsDell"
#endregion

$DriverResults  = @()
$DCUScanResult  = $null

#region --- Dell: DCU Scan for Drivers ---
if ($IsDell) {
    $DCUPaths = @(
        "$env:ProgramFiles\Dell\CommandUpdate\dcu-cli.exe",
        "${env:ProgramFiles(x86)}\Dell\CommandUpdate\dcu-cli.exe"
    )
    $DCUExe = $null
    foreach ($p in $DCUPaths) { if (Test-Path $p) { $DCUExe = $p; break } }

    if ($DCUExe) {
        Write-Log "Running DCU scan for driver updates..."
        try {
            $logPath = "$env:TEMP\dcu_driver_scan.log"
            $args    = "/scan -updateType=driver -outputLog=`"$logPath`""
            $proc    = Start-Process -FilePath $DCUExe -ArgumentList $args -Wait -PassThru -NoNewWindow
            $exitCode = $proc.ExitCode

            $meaning = switch ($exitCode) {
                0     { 'Driver updates available' }
                500   { 'No driver updates found (up to date)' }
                501   { 'Error determining updates' }
                default { "ExitCode $exitCode" }
            }

            $DCUScanResult = [PSCustomObject]@{
                Method          = 'Dell Command Update'
                ExitCode        = $exitCode
                ExitMeaning     = $meaning
                UpdateAvailable = ($exitCode -eq 0)
                LogPath         = $logPath
            }

            Write-Log "DCU driver scan: $meaning (exit $exitCode)"

            # Parse log for specific updates if available
            if (Test-Path $logPath) {
                $logLines = Get-Content $logPath -ErrorAction SilentlyContinue
                foreach ($line in $logLines) {
                    if ($line -match 'Available|update.*available|Driver') {
                        Write-Log "  DCU log: $line" 'DEBUG'
                    }
                }
            }
        } catch {
            Write-ErrorLog "DCU scan failed: $_"
            $DCUScanResult = [PSCustomObject]@{
                Method  = 'Dell Command Update'
                Error   = $_.ToString()
            }
        }
    } else {
        Write-Log "DCU not found - falling through to PnP driver check" 'WARN'
        $DCUScanResult = [PSCustomObject]@{
            Method  = 'Dell Command Update'
            Error   = 'DCU not installed'
        }
    }
}
#endregion

#region --- PnP Driver Inventory (all devices) ---
Write-Log "Enumerating device drivers via Win32_PnPSignedDriver..."
try {
    # Get devices with issues
    $problemDevices = Get-PnpDevice -ErrorAction SilentlyContinue |
        Where-Object { $_.Status -ne 'OK' }

    # Get all signed drivers
    $pnpDrivers = Get-CimInstance -ClassName Win32_PnPSignedDriver -ErrorAction Stop |
        Where-Object { $_.DeviceName -and $_.DeviceClass -notmatch 'System|Computer|Processor|Volume' }

    foreach ($drv in $pnpDrivers) {
        $hasIssue = $problemDevices | Where-Object { $_.FriendlyName -eq $drv.DeviceName }

        $DriverResults += [PSCustomObject]@{
            DeviceName       = $drv.DeviceName
            DeviceClass      = $drv.DeviceClass
            DriverVersion    = $drv.DriverVersion
            DriverDate       = $drv.DriverDate
            Manufacturer     = $drv.Manufacturer
            Signer           = $drv.Signer
            HasIssue         = [bool]$hasIssue
            IssueCode        = if ($hasIssue) { $hasIssue.ConfigManagerErrorCode } else { $null }
            UpdateAvailable  = if ($IsDell -and $DCUScanResult) { $DCUScanResult.UpdateAvailable } else { $null }
        }
    }

    Write-Log "Total drivers enumerated: $($DriverResults.Count)"
    $problemCount = ($DriverResults | Where-Object { $_.HasIssue }).Count
    Write-Log "Drivers with issues: $problemCount"

} catch {
    Write-ErrorLog "PnP driver enumeration failed: $_"
}
#endregion

#region --- Output ---
$Summary = [PSCustomObject]@{
    Timestamp      = (Get-Date -Format 'o')
    Manufacturer   = $Manufacturer
    IsDell         = $IsDell
    DCUScan        = $DCUScanResult
    TotalDrivers   = $DriverResults.Count
    ProblematicDrivers = ($DriverResults | Where-Object { $_.HasIssue }).Count
    Drivers        = $DriverResults
}

$Summary | ConvertTo-Json -Depth 5 | Out-File "$OutputRoot\Logs\DriverStatus-Report.json" -Force

if ($NonInteractive) {
    $Summary | ConvertTo-Json -Depth 5
} else {
    Write-Host ""
    Write-Host "=== Driver Status ===" -ForegroundColor Cyan
    if ($IsDell -and $DCUScanResult) {
        $color = if ($DCUScanResult.UpdateAvailable) { 'Yellow' } else { 'Green' }
        Write-Host "  Dell Command Update: $($DCUScanResult.ExitMeaning)" -ForegroundColor $color
    }
    Write-Host "  Total Drivers: $($DriverResults.Count)"
    $problems = $DriverResults | Where-Object { $_.HasIssue }
    if ($problems) {
        Write-Host "  Problematic Drivers:" -ForegroundColor Yellow
        foreach ($p in $problems) {
            Write-Host "    $($p.DeviceName) [$($p.DeviceClass)] - Code: $($p.IssueCode)"
        }
    } else {
        Write-Host "  No device issues detected" -ForegroundColor Green
    }
    Write-Host ""
    Write-Host "Report: $OutputRoot\Logs\DriverStatus-Report.json"
    Write-Host ""
    Read-Host "Press Enter to continue"
}
#endregion
