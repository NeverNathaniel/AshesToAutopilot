<#
.SYNOPSIS
    Checks for and applies driver updates on Dell devices using Dell Command Update.

.DESCRIPTION
    - Verifies Dell hardware. For non-Dell, runs PnP-only device health check.
    - Auto-installs Dell Command Update if not present (Dell only).
    - Scans for driver updates (DCU /scan -updateType=driver).
    - If no updates found (exit 500): reports drivers as current.
    - If updates found (exit 0): applies them with reboot deferred.
    - Always enumerates PnP devices to flag problematic drivers.
    - Reports: UpdateFound, ScanExitCode, ApplyExitCode, ExitMeaning,
      RebootNeeded, ProblematicDrivers, TotalDrivers, Success.

.PARAMETER NonInteractive
    Suppress prompts. Output structured JSON to stdout.

.EXAMPLE
    .\Invoke-DriverUpdate.ps1
    .\Invoke-DriverUpdate.ps1 -NonInteractive

.NOTES
    Replaces the separate Test-DriverStatus and Update-Drivers steps.
    Requires: Administrator
    Output:   C:\PreWipeOutput\Logs\DriverUpdate-Report.json
#>

[CmdletBinding()]
param([switch]$NonInteractive)

#region --- Init ---
$ScriptName = 'Invoke-DriverUpdate'
. (Join-Path $PSScriptRoot '..\Common\Initialize-Toolkit.ps1')
. (Join-Path $PSScriptRoot '..\Common\Find-DellCommandTool.ps1')
$LogFile = "$LogDir\$ScriptName.log"
if (-not (Test-AdminElevation)) { exit 1 }
#endregion

#region --- Result ---
$Result = [PSCustomObject]@{
    Timestamp          = (Get-Date -Format 'o')
    Vendor             = $null
    IsDell             = $false
    DCUPath            = $null
    UpdateFound        = $null
    ScanExitCode       = $null
    ApplyExitCode      = $null
    ExitMeaning        = $null
    RebootNeeded       = $false
    ProblematicDrivers = 0
    TotalDrivers       = 0
    DCUScan            = $null
    Drivers            = @()
    Success            = $false
    Error              = $null
}
#endregion

#region --- Vendor ---
try {
    $CS = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
    $Result.Vendor = $CS.Manufacturer
    $Result.IsDell  = $Result.Vendor -like '*Dell*'
    Write-Log "Vendor: $($Result.Vendor) | IsDell: $($Result.IsDell)"
} catch {
    Write-ErrorLog "Vendor check failed: $_"
    $Result.Error = "Vendor check failed: $_"
    if ($NonInteractive) { $Result | ConvertTo-Json -Depth 5 }
    exit 1
}
#endregion

#region --- DCU (Dell only) ---
if ($Result.IsDell) {
    $DCUExe = Find-DellCommandUpdate
    if (-not $DCUExe) {
        Write-Log 'DCU not found — attempting auto-install...'
        try {
            $installScript = Join-Path $PSScriptRoot 'Install-DellCommandTools.ps1'
            & $installScript -NonInteractive 2>&1 | Out-Null
            $DCUExe = Find-DellCommandUpdate
        } catch { Write-Log "Auto-install failed: $_" 'WARN' }
    }

    if ($DCUExe) {
        $Result.DCUPath = $DCUExe
        Write-Log "DCU: $DCUExe"

        # Scan
        Write-Log 'Scanning for driver updates...'
        try {
            $scanArgs = "/scan -updateType=driver -outputLog=`"$OutputRoot\Logs\DCU-Driver-Scan.log`""
            $scanProc = Start-Process -FilePath $DCUExe -ArgumentList $scanArgs -Wait -PassThru -NoNewWindow
            $scanCode = $scanProc.ExitCode
            $Result.ScanExitCode = $scanCode

            $scanMeaning = switch ($scanCode) {
                0   { 'Driver updates available' }
                500 { 'No driver updates found (up to date)' }
                501 { 'Error determining updates' }
                default { "ExitCode $scanCode" }
            }

            $Result.DCUScan = [PSCustomObject]@{
                ExitCode        = $scanCode
                ExitMeaning     = $scanMeaning
                UpdateAvailable = ($scanCode -eq 0)
            }
            Write-Log "DCU driver scan: $scanMeaning (exit $scanCode)"
        } catch {
            Write-ErrorLog "DCU driver scan failed: $_"
            $Result.DCUScan = [PSCustomObject]@{ ExitCode = -1; ExitMeaning = "Scan failed: $_"; UpdateAvailable = $false }
        }

        # Apply if updates found
        if ($Result.ScanExitCode -eq 0) {
            $Result.UpdateFound = $true
            Write-Log 'Driver updates available — applying...'
            # Dell Command | Update 5.x documented exit codes:
            #   0 = success, 1 = reboot required, 2 = unknown application error,
            #   5 = reboot pending from a previous operation, 500 = no updates, 1002 = download error
            $applyMap = @{
                0    = 'Driver updates applied successfully'
                1    = 'Driver updates applied — reboot required'
                2    = 'Unknown application error during update'
                5    = 'A reboot is pending from a previous operation — reboot and re-run'
                500  = 'No driver updates to apply'
                1002 = 'Download error'
            }
            try {
                $applyArgs = "/applyUpdates -updateType=driver -reboot=disable -outputLog=`"$OutputRoot\Logs\DCU-Driver-Update.log`""
                $applyProc = Start-Process -FilePath $DCUExe -ArgumentList $applyArgs -Wait -PassThru -NoNewWindow
                $applyCode = $applyProc.ExitCode
                $Result.ApplyExitCode = $applyCode
                $meaning = if ($applyMap.ContainsKey($applyCode)) { $applyMap[$applyCode] } else { "ExitCode $applyCode" }
                $Result.ExitMeaning = $meaning
                Write-Log "DCU driver apply exit: $applyCode — $meaning"

                if ($applyCode -eq 0 -or $applyCode -eq 500) {
                    $Result.Success = $true
                } elseif ($applyCode -eq 1) {
                    $Result.Success      = $true
                    $Result.RebootNeeded = $true
                    Write-Log 'REBOOT REQUIRED after driver updates' 'WARN'
                } elseif ($applyCode -eq 5) {
                    $Result.Success      = $false
                    $Result.RebootNeeded = $true
                    $Result.Error        = $applyMap[5]
                    Write-ErrorLog $Result.Error
                } else {
                    $Result.Success = $false
                    $Result.Error   = "Apply returned $applyCode : $meaning"
                    Write-ErrorLog $Result.Error
                }
            } catch {
                Write-ErrorLog "DCU driver apply failed: $_"
                $Result.Error = "Apply failed: $_"
            }
        } elseif ($Result.ScanExitCode -eq 500) {
            $Result.UpdateFound = $false
            $Result.Success     = $true
            $Result.ExitMeaning = 'Drivers are current — no update needed'
            Write-Log 'No driver updates needed'
        } elseif ($Result.ScanExitCode -in @(1, 5)) {
            $Result.RebootNeeded = $true
            $Result.ExitMeaning  = "A reboot is pending from a previous operation (scan exit $($Result.ScanExitCode)) — reboot, then re-run this step"
            $Result.Success      = $false
            Write-ErrorLog $Result.ExitMeaning
        } else {
            $Result.ExitMeaning = "DCU scan: $($Result.DCUScan.ExitMeaning)"
            $Result.Success     = $false
        }
    } else {
        Write-Log 'DCU not available after install attempt — proceeding with PnP check only' 'WARN'
        $Result.ExitMeaning = 'DCU not available — PnP check only'
        $Result.Success     = $true
    }
} else {
    $Result.ExitMeaning = "Non-Dell ($($Result.Vendor)) — DCU driver update not applicable"
    $Result.Success     = $true
    Write-Log $Result.ExitMeaning
}
#endregion

#region --- PnP driver inventory (all devices) ---
Write-Log 'Enumerating PnP drivers...'
try {
    $problemDevices = Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { $_.Status -ne 'OK' }
    $pnpDrivers     = Get-CimInstance -ClassName Win32_PnPSignedDriver -ErrorAction Stop |
        Where-Object { $_.DeviceName -and $_.DeviceClass -notmatch 'System|Computer|Processor|Volume' }

    $driverList = @()
    foreach ($drv in $pnpDrivers) {
        $hasIssue = $problemDevices | Where-Object { $_.FriendlyName -eq $drv.DeviceName }
        $driverList += [PSCustomObject]@{
            DeviceName    = $drv.DeviceName
            DeviceClass   = $drv.DeviceClass
            DriverVersion = $drv.DriverVersion
            DriverDate    = $drv.DriverDate
            Manufacturer  = $drv.Manufacturer
            HasIssue      = [bool]$hasIssue
            IssueCode     = if ($hasIssue) { $hasIssue.ConfigManagerErrorCode } else { $null }
        }
    }

    $Result.Drivers            = $driverList
    $Result.TotalDrivers       = $driverList.Count
    $Result.ProblematicDrivers = ($driverList | Where-Object { $_.HasIssue }).Count
    Write-Log "Drivers: $($Result.TotalDrivers) total, $($Result.ProblematicDrivers) problematic"
} catch {
    Write-ErrorLog "PnP enumeration failed: $_"
}
#endregion

#region --- Output ---
$Result | ConvertTo-Json -Depth 5 | Out-File "$OutputRoot\Logs\DriverUpdate-Report.json" -Force

if ($NonInteractive) {
    $Result | ConvertTo-Json -Depth 5
} else {
    Write-Host ''
    Write-Host '=== Driver Update Result ===' -ForegroundColor Cyan
    Write-Host "  Vendor     : $($Result.Vendor)"
    if ($Result.DCUScan) {
        $col = if ($Result.DCUScan.UpdateAvailable) { 'Yellow' } else { 'Green' }
        Write-Host "  DCU Scan   : $($Result.DCUScan.ExitMeaning)" -ForegroundColor $col
    }
    if ($Result.ExitMeaning) { Write-Host "  Result     : $($Result.ExitMeaning)" }
    Write-Host "  PnP Issues : $($Result.ProblematicDrivers) of $($Result.TotalDrivers) drivers"
    $col = if ($Result.Success) { 'Green' } else { 'Red' }
    Write-Host "  Success    : $($Result.Success)" -ForegroundColor $col
    if ($Result.RebootNeeded) { Write-Host '  *** REBOOT REQUIRED to complete driver updates ***' -ForegroundColor Yellow }
    if ($Result.Error) { Write-Host "  Error      : $($Result.Error)" -ForegroundColor Yellow }
    Write-Host ''
}
#endregion

exit 0
