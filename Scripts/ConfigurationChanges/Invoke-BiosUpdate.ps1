<#
.SYNOPSIS
    Checks for and applies BIOS updates on Dell devices using Dell Command Update.

.DESCRIPTION
    - Verifies Dell hardware. Exits gracefully on non-Dell.
    - Auto-installs Dell Command Update if not present.
    - Scans for BIOS updates (DCU /scan -updateType=bios).
    - If no updates found (exit 500): reports current as up to date.
    - If updates found (exit 0): applies them with reboot deferred.
    - Reports: CurrentVersion, UpdateFound, ScanExitCode, ApplyExitCode,
      ExitMeaning, RebootNeeded, Success.

.PARAMETER NonInteractive
    Suppress prompts. Output structured JSON to stdout.

.EXAMPLE
    .\Invoke-BiosUpdate.ps1
    .\Invoke-BiosUpdate.ps1 -NonInteractive

.NOTES
    Replaces the separate Test-BiosVersion and Update-Bios steps.
    Requires: Administrator
    Output:   C:\PreWipeOutput\Logs\BiosUpdate-Report.json
#>

[CmdletBinding()]
param([switch]$NonInteractive)

#region --- Init ---
$ScriptName = 'Invoke-BiosUpdate'
. (Join-Path $PSScriptRoot '..\Common\Initialize-Toolkit.ps1')
. (Join-Path $PSScriptRoot '..\Common\Find-DellCommandTool.ps1')
$LogFile = "$LogDir\$ScriptName.log"
if (-not (Test-AdminElevation)) { exit 1 }
#endregion

#region --- Result ---
$Result = [PSCustomObject]@{
    Timestamp      = (Get-Date -Format 'o')
    Vendor         = $null
    IsDell         = $false
    DCUPath        = $null
    CurrentVersion = $null
    UpdateFound    = $null
    ScanExitCode   = $null
    ApplyExitCode  = $null
    ExitMeaning    = $null
    RebootNeeded   = $false
    Success        = $false
    Error          = $null
}
#endregion

#region --- Vendor check ---
try {
    $CS = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
    $Result.Vendor = $CS.Manufacturer
    $bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction SilentlyContinue
    $Result.CurrentVersion = if ($bios) { $bios.SMBIOSBIOSVersion } else { 'Unknown' }
} catch {
    Write-ErrorLog "Vendor check failed: $_"
    $Result.Error = "Vendor check failed: $_"
    if ($NonInteractive) { $Result | ConvertTo-Json -Depth 5 }
    exit 1
}

if ($Result.Vendor -notlike '*Dell*') {
    $msg = "Vendor is '$($Result.Vendor)' — not Dell. Skipping BIOS update."
    Write-Log $msg
    $Result.ExitMeaning = $msg
    $Result.Success     = $true
    if ($NonInteractive) { $Result | ConvertTo-Json -Depth 5 } else { Write-Host $msg }
    exit 0
}
$Result.IsDell = $true
Write-Log "Dell confirmed. BIOS: $($Result.CurrentVersion)"
#endregion

#region --- Ensure DCU ---
$DCUExe = Find-DellCommandUpdate
if (-not $DCUExe) {
    Write-Log 'DCU not found — attempting auto-install via Install-DellCommandTools...'
    try {
        $installScript = Join-Path $PSScriptRoot 'Install-DellCommandTools.ps1'
        & $installScript -NonInteractive 2>&1 | Out-Null
        $DCUExe = Find-DellCommandUpdate
    } catch { Write-Log "Auto-install failed: $_" 'WARN' }
}
if (-not $DCUExe) {
    $msg = 'Dell Command Update not found and could not be auto-installed.'
    Write-ErrorLog $msg
    $Result.Error = $msg
    $Result | ConvertTo-Json -Depth 5 | Out-File "$OutputRoot\Logs\BiosUpdate-Report.json" -Force
    if ($NonInteractive) { $Result | ConvertTo-Json -Depth 5 } else { Write-Host "ERROR: $msg" -ForegroundColor Red }
    exit 0
}
$Result.DCUPath = $DCUExe
Write-Log "DCU: $DCUExe"
#endregion

#region --- Scan ---
Write-Log 'Scanning for BIOS updates...'
try {
    $scanArgs = "/scan -updateType=bios -outputLog=`"$OutputRoot\Logs\DCU-BIOS-Scan.log`""
    $scanProc = Start-Process -FilePath $DCUExe -ArgumentList $scanArgs -Wait -PassThru -NoNewWindow
    $scanCode = $scanProc.ExitCode
    $Result.ScanExitCode = $scanCode
    Write-Log "DCU BIOS scan exit: $scanCode"
} catch {
    Write-ErrorLog "DCU scan failed: $_"
    $Result.Error = "Scan failed: $_"
    $Result | ConvertTo-Json -Depth 5 | Out-File "$OutputRoot\Logs\BiosUpdate-Report.json" -Force
    if ($NonInteractive) { $Result | ConvertTo-Json -Depth 5 }
    exit 0
}
#endregion

#region --- Apply or report ---
if ($scanCode -eq 500) {
    $Result.UpdateFound = $false
    $Result.Success     = $true
    $Result.ExitMeaning = "BIOS v$($Result.CurrentVersion) is current — no update needed"
    Write-Log 'No BIOS update available'
} elseif ($scanCode -eq 0) {
    $Result.UpdateFound = $true
    Write-Log 'BIOS update available — applying...'
    # Dell Command | Update 5.x documented exit codes:
    #   0 = success, 1 = reboot required, 2 = unknown application error,
    #   5 = reboot pending from a previous operation, 500 = no updates, 1002 = download error
    $applyMap = @{
        0    = 'BIOS update applied successfully'
        1    = 'BIOS update applied — reboot required'
        2    = 'Unknown application error during update'
        5    = 'A reboot is pending from a previous operation — reboot and re-run'
        500  = 'No BIOS updates to apply'
        1002 = 'Download error'
    }
    try {
        # autoSuspendBitLocker: a BIOS flash changes TPM PCR measurements; without
        # suspension the next boot lands on the BitLocker recovery prompt.
        $applyArgs = "/applyUpdates -updateType=bios -reboot=disable -autoSuspendBitLocker=enable -outputLog=`"$OutputRoot\Logs\DCU-BIOS-Update.log`""
        $applyProc = Start-Process -FilePath $DCUExe -ArgumentList $applyArgs -Wait -PassThru -NoNewWindow
        $applyCode = $applyProc.ExitCode
        $Result.ApplyExitCode = $applyCode
        $meaning = if ($applyMap.ContainsKey($applyCode)) { $applyMap[$applyCode] } else { "ExitCode $applyCode" }
        $Result.ExitMeaning = $meaning
        Write-Log "DCU BIOS apply exit: $applyCode — $meaning"

        if ($applyCode -eq 0 -or $applyCode -eq 500) {
            $Result.Success = $true
        } elseif ($applyCode -eq 1) {
            $Result.Success      = $true
            $Result.RebootNeeded = $true
            Write-Log 'REBOOT REQUIRED after BIOS update' 'WARN'
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
        Write-ErrorLog "DCU apply execution failed: $_"
        $Result.Error = "Apply failed: $_"
    }
} elseif ($scanCode -eq 1 -or $scanCode -eq 5) {
    $Result.UpdateFound  = $null
    $Result.RebootNeeded = $true
    $Result.ExitMeaning  = "A reboot is pending from a previous operation (scan exit $scanCode) — reboot, then re-run this step"
    $Result.Success      = $false
    Write-ErrorLog $Result.ExitMeaning
} else {
    $Result.UpdateFound  = $null
    $Result.ExitMeaning  = "DCU scan returned unexpected exit code $scanCode"
    $Result.Success      = $false
    Write-ErrorLog $Result.ExitMeaning
}
#endregion

#region --- Output ---
$Result | ConvertTo-Json -Depth 5 | Out-File "$OutputRoot\Logs\BiosUpdate-Report.json" -Force

if ($NonInteractive) {
    $Result | ConvertTo-Json -Depth 5
} else {
    Write-Host ''
    Write-Host '=== BIOS Update Result ===' -ForegroundColor Cyan
    Write-Host "  Vendor  : $($Result.Vendor)"
    Write-Host "  BIOS    : $($Result.CurrentVersion)"
    $updateStr = if ($null -eq $Result.UpdateFound) { 'N/A' } elseif ($Result.UpdateFound) { 'Found and applied' } else { 'Not needed (current)' }
    Write-Host "  Update  : $updateStr"
    Write-Host "  Result  : $($Result.ExitMeaning)"
    $col = if ($Result.Success) { 'Green' } else { 'Red' }
    Write-Host "  Success : $($Result.Success)" -ForegroundColor $col
    if ($Result.RebootNeeded) { Write-Host '  *** REBOOT REQUIRED to complete BIOS update ***' -ForegroundColor Yellow }
    if ($Result.Error) { Write-Host "  Error   : $($Result.Error)" -ForegroundColor Yellow }
    Write-Host ''
    Write-Host "  Log: $OutputRoot\Logs\DCU-BIOS-Update.log"
    Write-Host ''
}
#endregion

exit 0
