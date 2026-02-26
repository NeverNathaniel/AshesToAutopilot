<#
.SYNOPSIS
    Updates BIOS on Dell devices using Dell Command Update.

.DESCRIPTION
    - Verifies hardware is Dell. Exits gracefully on non-Dell.
    - Runs Dell Command Update (dcu-cli.exe) to apply BIOS updates only.
    - Reports result and exit code.

.PARAMETER NonInteractive
    Suppress all prompts. Output structured JSON to stdout. Exit cleanly.

.EXAMPLE
    .\Update-Bios.ps1
    .\Update-Bios.ps1 -NonInteractive

.NOTES
    Source repos used:
    - garytown-master/RunScripts/Update-DellBIOS.ps1
      (Dell Command Update BIOS apply pattern)
    - garytown-master/hardware/Dell/CommandUpdate/EMPS/Dell-EMPS.ps1
      (Invoke-DCU function pattern: /applyUpdates -updateType=bios)
    - garytown-master/Intune/Update-DellBIOS-Detect.ps1
      (exit code handling patterns)

    Requires: Administrator
    Output:   C:\PreWipeOutput\Logs\Update-Bios.log
    NOTE: A reboot may be required after BIOS update. Script reports this but does NOT reboot.
#>

[CmdletBinding()]
param(
    [switch]$NonInteractive
)

#region --- Init ---
$ScriptName = 'Update-Bios'
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

#region --- Dell Vendor Check ---
try {
    $CS = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
    $Manufacturer = $CS.Manufacturer
} catch {
    Write-ErrorLog "Failed to query Win32_ComputerSystem: $_"
    exit 1
}

if ($Manufacturer -notlike '*Dell*') {
    $msg = "Vendor is '$Manufacturer' - not Dell. Skipping BIOS update."
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
$DCUPaths = @(
    "$env:ProgramFiles\Dell\CommandUpdate\dcu-cli.exe",
    "${env:ProgramFiles(x86)}\Dell\CommandUpdate\dcu-cli.exe"
)
$DCUExe = $null
foreach ($p in $DCUPaths) { if (Test-Path $p) { $DCUExe = $p; break } }

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

#region --- Run BIOS Update ---
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

# DCU exit code map (from Dell-EMPS.ps1 reference)
$ExitCodeMap = @{
    0    = 'Success'
    1    = 'Error during update'
    2    = 'Reboot required'
    3    = 'Soft dependency error (same or downgrade attempted)'
    4    = 'Hard dependency error'
    5    = 'Qualification error'
    500  = 'No BIOS updates found (system up to date)'
    1000 = 'Error retrieving apply updates result'
    1001 = 'Update cancelled'
    1002 = 'Download error'
}

try {
    # Apply BIOS updates only, no reboot (reboot after all updates done)
    $args = '/applyUpdates -updateType=bios -reboot=disable -outputLog="C:\PreWipeOutput\Logs\DCU-BIOS-Update.log"'
    Write-Log "Running DCU BIOS update: $DCUExe $args"

    $proc    = Start-Process -FilePath $DCUExe -ArgumentList $args -Wait -PassThru -NoNewWindow
    $exitCode = $proc.ExitCode
    $meaning  = $ExitCodeMap[$exitCode] ?? "ExitCode $exitCode (unknown)"

    $Result.ExitCode    = $exitCode
    $Result.ExitMeaning = $meaning
    Write-Log "DCU BIOS update exit code: $exitCode - $meaning"

    if ($exitCode -eq 0) {
        $Result.Success      = $true
        $Result.RebootNeeded = $false
        Write-Log "BIOS update applied successfully"
    } elseif ($exitCode -eq 2) {
        $Result.Success      = $true
        $Result.RebootNeeded = $true
        Write-Log "BIOS update applied - REBOOT REQUIRED" 'WARN'
    } elseif ($exitCode -eq 500) {
        $Result.Success      = $true
        $Result.RebootNeeded = $false
        Write-Log "No BIOS updates needed - system is current"
    } else {
        $Result.Success = $false
        Write-ErrorLog "BIOS update returned: $exitCode - $meaning"
    }

} catch {
    Write-ErrorLog "DCU BIOS update execution failed: $_"
    $Result.Error = $_.ToString()
}
#endregion

#region --- Output ---
$Result | ConvertTo-Json -Depth 5 | Out-File "$OutputRoot\Logs\BiosUpdate-Result.json" -Force

if ($NonInteractive) {
    $Result | ConvertTo-Json -Depth 5
} else {
    Write-Host ""
    Write-Host "=== BIOS Update Result ===" -ForegroundColor Cyan
    $color = if ($Result.Success) { 'Green' } else { 'Red' }
    Write-Host "  Result:       $($Result.ExitMeaning)" -ForegroundColor $color
    Write-Host "  Exit Code:    $($Result.ExitCode)"
    if ($Result.RebootNeeded) {
        Write-Host "  *** REBOOT REQUIRED to complete BIOS update ***" -ForegroundColor Yellow
    }
    Write-Host ""
    Write-Host "Full log: C:\PreWipeOutput\Logs\DCU-BIOS-Update.log"
    Write-Host ""
    Read-Host "Press Enter to continue"
}
#endregion
