<#
.SYNOPSIS
    Updates device drivers on Dell devices using Dell Command Update.

.DESCRIPTION
    - Verifies hardware is Dell. Exits gracefully on non-Dell.
    - Runs Dell Command Update (dcu-cli.exe) to apply driver updates only.
    - Reports result and exit code.

.PARAMETER NonInteractive
    Suppress all prompts. Output structured JSON to stdout. Exit cleanly.

.EXAMPLE
    .\Update-Drivers.ps1
    .\Update-Drivers.ps1 -NonInteractive

.NOTES
    Source repos used:
    - garytown-master/hardware/Dell/CommandUpdate/EMPS/Dell-EMPS.ps1
      (Invoke-DCU pattern: /applyUpdates -updateType=driver)
    - garytown-master/Intune/Update-DellApps-Detect.ps1
      (detection/result handling patterns)
    - garytown-master/RunScripts/Update-DellBIOS.ps1
      (DCU execution and exit code patterns, adapted for drivers)

    Requires: Administrator
    Output:   C:\PreWipeOutput\Logs\Update-Drivers.log
    NOTE: A reboot may be required after driver updates.
#>

[CmdletBinding()]
param(
    [switch]$NonInteractive
)

#region --- Init ---
$ScriptName = 'Update-Drivers'
. (Join-Path $PSScriptRoot '..\Common\Initialize-Toolkit.ps1')
. (Join-Path $PSScriptRoot '..\Common\Find-DellCommandTool.ps1')
$LogFile = "$LogDir\$ScriptName.log"
if (-not (Test-AdminElevation)) { exit 1 }
#endregion

#region --- Dell Vendor Check ---
try {
    $CS = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
    $Manufacturer = $CS.Manufacturer
} catch {
    Write-ErrorLog "Failed to query Win32_ComputerSystem: $_"
    exit 1
}

if ($Manufacturer -notlike '*Dell*') {
    $msg = "Vendor is '$Manufacturer' - not Dell. Skipping driver update."
    Write-Log $msg
    if ($NonInteractive) {
        @{ Vendor = $Manufacturer; IsDell = $false; Action = 'Skipped'; Reason = $msg } | ConvertTo-Json
    } else {
        Write-Host $msg
    }
    exit 0
}

Write-Log "Dell device confirmed: $Manufacturer"
#endregion

#region --- DCU Check ---
$DCUExe = Find-DellCommandUpdate

if (-not $DCUExe) {
    $msg = "Dell Command Update not found. Run Install-DellCommandTools.ps1 first."
    Write-ErrorLog $msg
    if ($NonInteractive) {
        @{ Vendor = $Manufacturer; IsDell = $true; DCUFound = $false; Error = $msg } | ConvertTo-Json
    } else {
        Write-Host "ERROR: $msg" -ForegroundColor Red
    }
    exit 1
}

Write-Log "DCU found: $DCUExe"
#endregion

#region --- Run Driver Update ---
$Result = [PSCustomObject]@{
    Timestamp    = (Get-Date -Format 'o')
    Vendor       = $Manufacturer
    IsDell       = $true
    DCUPath      = $DCUExe
    ExitCode     = $null
    ExitMeaning  = $null
    RebootNeeded = $false
    Success      = $false
    Error        = $null
}

$ExitCodeMap = @{
    0    = 'Success - driver updates applied'
    1    = 'Error during update'
    2    = 'Reboot required'
    3    = 'Soft dependency error'
    4    = 'Hard dependency error'
    5    = 'Qualification error'
    500  = 'No driver updates found (system up to date)'
    1000 = 'Error retrieving apply updates result'
    1001 = 'Update cancelled'
    1002 = 'Download error'
}

try {
    $driverLogPath = "$OutputRoot\Logs\DCU-Driver-Update.log"
    $args = "/applyUpdates -updateType=driver -reboot=disable -outputLog=`"$driverLogPath`""
    Write-Log "Running DCU driver update: $DCUExe $args"

    $proc     = Start-Process -FilePath $DCUExe -ArgumentList $args -Wait -PassThru -NoNewWindow
    $exitCode  = $proc.ExitCode
    $meaning   = if ($ExitCodeMap.ContainsKey($exitCode)) { $ExitCodeMap[$exitCode] } else { "ExitCode $exitCode (unknown)" }

    $Result.ExitCode    = $exitCode
    $Result.ExitMeaning = $meaning
    Write-Log "DCU driver update exit code: $exitCode - $meaning"

    if ($exitCode -eq 0) {
        $Result.Success      = $true
        $Result.RebootNeeded = $false
    } elseif ($exitCode -eq 2) {
        $Result.Success      = $true
        $Result.RebootNeeded = $true
        Write-Log "Driver updates applied - REBOOT MAY BE REQUIRED" 'WARN'
    } elseif ($exitCode -eq 500) {
        $Result.Success      = $true
        $Result.RebootNeeded = $false
    } else {
        $Result.Success = $false
        Write-ErrorLog "Driver update returned: $exitCode - $meaning"
    }

} catch {
    Write-ErrorLog "DCU driver update execution failed: $_"
    $Result.Error = $_.ToString()
}
#endregion

#region --- Output ---
$Result | ConvertTo-Json -Depth 5 | Out-File "$OutputRoot\Logs\DriverUpdate-Report.json" -Force

if ($NonInteractive) {
    $Result | ConvertTo-Json -Depth 5
} else {
    Write-Host ""
    Write-Host "=== Driver Update Result ===" -ForegroundColor Cyan
    $color = if ($Result.Success) { 'Green' } else { 'Red' }
    Write-Host "  Result:    $($Result.ExitMeaning)" -ForegroundColor $color
    Write-Host "  Exit Code: $($Result.ExitCode)"
    if ($Result.RebootNeeded) {
        Write-Host "  *** REBOOT MAY BE REQUIRED to complete driver updates ***" -ForegroundColor Yellow
    }
    Write-Host ""
    Write-Host "Full log: $OutputRoot\Logs\DCU-Driver-Update.log"
    Write-Host ""
}
#endregion

exit 0
