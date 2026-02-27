<#
.SYNOPSIS
    Checks the current BIOS version and, for Dell systems, determines if an update is available.

.DESCRIPTION
    - Queries current BIOS version via Win32_BIOS.
    - For Dell devices: uses Dell Command Update (DCU) scan to check for available BIOS updates.
    - For non-Dell: reports current version only.
    - Reports: current version, latest available (if determinable), update needed (yes/no).

.PARAMETER NonInteractive
    Suppress all prompts. Output structured JSON to stdout. Exit cleanly.

.EXAMPLE
    .\Test-BiosVersion.ps1
    .\Test-BiosVersion.ps1 -NonInteractive

.NOTES
    Source repos used:
    - garytown-master/OSD/BIOS/BIOSGatherPackage/BIOS_Gather.ps1
      (Win32_BIOS query patterns, BIOS version reporting)
    - garytown-master/Intune/Update-DellBIOS-Detect.ps1
      (Dell DCU BIOS detection logic - check if update available)
    - garytown-master/hardware/Dell/CommandUpdate/EMPS/Dell-EMPS.ps1
      (Get-DCUUpdateList with BIOS category filter pattern)

    Requires: Administrator
    Output:   C:\PreWipeOutput\Logs\Test-BiosVersion.log
#>

[CmdletBinding()]
param(
    [switch]$NonInteractive
)

#region --- Init ---
$ScriptName = 'Test-BiosVersion'
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

#region --- BIOS Info ---
$Result = [PSCustomObject]@{
    Timestamp        = (Get-Date -Format 'o')
    Manufacturer     = $null
    IsDell           = $false
    CurrentVersion   = $null
    ReleaseDate      = $null
    LatestAvailable  = $null
    UpdateAvailable  = $null
    DCUPath          = $null
    DCUScanOutput    = $null
    Error            = $null
}

try {
    $BIOS = Get-CimInstance -ClassName Win32_BIOS -ErrorAction Stop
    $CS   = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop

    $Result.CurrentVersion = $BIOS.SMBIOSBIOSVersion
    $Result.ReleaseDate    = $BIOS.ReleaseDate
    $Result.Manufacturer   = $CS.Manufacturer

    Write-Log "BIOS version: $($Result.CurrentVersion)"
    Write-Log "Manufacturer: $($Result.Manufacturer)"

    if ($CS.Manufacturer -like '*Dell*') {
        $Result.IsDell = $true
        Write-Log "Dell device - checking DCU for BIOS update availability..."

        # Find DCU CLI
        $DCUPaths = @(
            "$env:ProgramFiles\Dell\CommandUpdate\dcu-cli.exe",
            "${env:ProgramFiles(x86)}\Dell\CommandUpdate\dcu-cli.exe"
        )
        $DCUExe = $null
        foreach ($p in $DCUPaths) { if (Test-Path $p) { $DCUExe = $p; break } }

        if ($DCUExe) {
            $Result.DCUPath = $DCUExe
            Write-Log "DCU found at: $DCUExe"

            # Run DCU scan for BIOS updates only
            $scanOutput = "$env:TEMP\dcu_bios_scan.xml"
            $args = "/scan -outputLog=`"$env:TEMP\dcu_scan.log`" -updateType=bios"

            Write-Log "Running DCU scan (BIOS only)..."
            try {
                $proc = Start-Process -FilePath $DCUExe -ArgumentList $args -Wait -PassThru -NoNewWindow
                $exitCode = $proc.ExitCode
                Write-Log "DCU scan exit code: $exitCode"

                # Exit code 0 = updates available, 500 = no updates found
                if ($exitCode -eq 0) {
                    $Result.UpdateAvailable = $true
                    $Result.LatestAvailable = 'Update available (check DCU GUI for version)'
                    $Result.DCUScanOutput   = "ExitCode:0 - BIOS update available"
                } elseif ($exitCode -eq 500) {
                    $Result.UpdateAvailable = $false
                    $Result.LatestAvailable = 'Current version is latest'
                    $Result.DCUScanOutput   = "ExitCode:500 - No BIOS updates found (up to date)"
                } else {
                    $Result.UpdateAvailable = $null
                    $Result.DCUScanOutput   = "ExitCode:$exitCode - Unable to determine"
                }

                # Try to parse scan log if it exists
                $logPath = "$env:TEMP\dcu_scan.log"
                if (Test-Path $logPath) {
                    $logContent = Get-Content $logPath -Tail 20 -ErrorAction SilentlyContinue
                    Write-Log "DCU scan log (last 20 lines): $($logContent -join ' | ')"
                }

            } catch {
                Write-ErrorLog "DCU scan execution failed: $_"
                $Result.DCUScanOutput = "Scan failed: $_"
            }
        } else {
            Write-Log "DCU not found - cannot check for BIOS updates. Run Install-DellCommandTools.ps1 first." 'WARN'
            $Result.LatestAvailable = 'Unknown (DCU not installed)'
            $Result.UpdateAvailable = $null
        }
    } else {
        Write-Log "Non-Dell device - reporting current BIOS version only"
        $Result.LatestAvailable = 'N/A (non-Dell device)'
        $Result.UpdateAvailable = $null
    }

} catch {
    Write-ErrorLog "BIOS check failed: $_"
    $Result.Error = $_.ToString()
}
#endregion

#region --- Output ---
$Result | ConvertTo-Json -Depth 5 | Out-File "$OutputRoot\Logs\BiosVersion-Report.json" -Force

if ($NonInteractive) {
    $Result | ConvertTo-Json -Depth 5
} else {
    Write-Host ""
    Write-Host "=== BIOS Version Report ===" -ForegroundColor Cyan
    Write-Host "  Manufacturer:    $($Result.Manufacturer)"
    Write-Host "  Current Version: $($Result.CurrentVersion)"
    Write-Host "  Release Date:    $($Result.ReleaseDate)"
    Write-Host "  Latest Available: $($Result.LatestAvailable)"
    if ($null -ne $Result.UpdateAvailable) {
        $color = if ($Result.UpdateAvailable) { 'Yellow' } else { 'Green' }
        Write-Host "  Update Needed:   $($Result.UpdateAvailable)" -ForegroundColor $color
    }
    Write-Host ""
    Write-Host "Report: $OutputRoot\Logs\BiosVersion-Report.json"
    Write-Host ""
}
#endregion
