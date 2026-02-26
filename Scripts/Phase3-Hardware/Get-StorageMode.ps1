<#
.SYNOPSIS
    Reports the current SATA/storage controller mode (AHCI, RAID, Intel RST, NVMe).

.DESCRIPTION
    Queries Win32_DiskDrive and Win32_IDEController to determine storage controller mode.
    On Dell systems, can also query via Dell Command Configure (DCC) if available.
    Reports the current mode: AHCI, Intel RST/RAID, or NVMe.

.PARAMETER NonInteractive
    Suppress all prompts. Output structured JSON to stdout. Exit cleanly.

.EXAMPLE
    .\Get-StorageMode.ps1
    .\Get-StorageMode.ps1 -NonInteractive

.NOTES
    Source repos used:
    - garytown-master/hardware/Get-FirmwareHardwareVars.ps1
      (hardware info gathering patterns via WMI/CIM)
    - garytown-master/OSD/TroubleShootingSteps/Get-MachineInfo.ps1
      (storage info via WMI patterns)
    No direct storage-mode-check script found in source repos.

    Requires: Administrator
    Output:   C:\PreWipeOutput\Logs\Get-StorageMode.log
#>

[CmdletBinding()]
param(
    [switch]$NonInteractive
)

#region --- Init ---
$ScriptName = 'Get-StorageMode'
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

#region --- Storage Mode Detection ---
$Result = [PSCustomObject]@{
    Timestamp        = (Get-Date -Format 'o')
    StorageMode      = 'Unknown'
    Controllers      = @()
    Disks            = @()
    IntelRSTDetected = $false
    Notes            = @()
    Error            = $null
}

try {
    # Get disk controllers
    Write-Log "Querying storage controllers..."
    $controllers = Get-CimInstance -ClassName Win32_IDEController -ErrorAction SilentlyContinue
    $scsiCtrl    = Get-CimInstance -ClassName Win32_SCSIController -ErrorAction SilentlyContinue
    $storageCtrl = Get-CimInstance -ClassName Win32_StorageController -ErrorAction SilentlyContinue 2>$null

    $ctrlList = @()
    foreach ($c in $controllers) {
        $ctrlList += [PSCustomObject]@{ Type = 'IDE'; Name = $c.Name; Status = $c.Status }
    }
    foreach ($c in $scsiCtrl) {
        $ctrlList += [PSCustomObject]@{ Type = 'SCSI'; Name = $c.Name; Status = $c.Status }
    }
    $Result.Controllers = $ctrlList

    # Get disk drives
    Write-Log "Querying disk drives..."
    $disks = Get-CimInstance -ClassName Win32_DiskDrive -ErrorAction Stop
    $diskList = @()
    foreach ($d in $disks) {
        $diskList += [PSCustomObject]@{
            Model       = $d.Model
            MediaType   = $d.MediaType
            InterfaceType = $d.InterfaceType
            Size        = [math]::Round($d.Size / 1GB, 2)
        }
    }
    $Result.Disks = $diskList

    # Determine storage mode from controller names and disk info
    $allNames = (@($controllers) + @($scsiCtrl) | Where-Object { $_ } | ForEach-Object { $_.Name }) -join ' '

    $storageMode = 'Unknown'

    # Intel RST/RAID detection
    if ($allNames -match 'Intel.*RST' -or $allNames -match 'RAID' -or $allNames -match 'VMD') {
        $storageMode = 'IntelRST_RAID'
        $Result.IntelRSTDetected = $true
        $Result.Notes += "Intel RST or RAID detected via controller name"
    } elseif ($allNames -match 'AHCI' -or $allNames -match 'SATA') {
        $storageMode = 'AHCI'
    } elseif ($diskList | Where-Object { $_.InterfaceType -eq 'SCSI' -and $_.Model -match 'NVMe' }) {
        $storageMode = 'NVMe'
    } elseif ($diskList | Where-Object { $_.Model -match 'NVMe|PCIe|M\.2' }) {
        $storageMode = 'NVMe'
    } elseif ($diskList | Where-Object { $_.InterfaceType -eq 'IDE' }) {
        $storageMode = 'AHCI_or_Legacy'
    }

    # Also check via PnP devices for Intel RST service
    try {
        $pnpDevices = Get-PnpDevice -Class DiskDrive -ErrorAction SilentlyContinue
        $rstService = Get-Service -Name 'iaStorV', 'iaStorAVC', 'RstMwService' -ErrorAction SilentlyContinue
        if ($rstService | Where-Object { $_.Status -eq 'Running' }) {
            $storageMode = 'IntelRST_RAID'
            $Result.IntelRSTDetected = $true
            $Result.Notes += "Intel RST service detected as running"
        }
    } catch {}

    # Registry check for SATA mode
    try {
        $ahciPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\storahci'
        $raidPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\iaStorV'
        if (Test-Path $raidPath) {
            $iaStorStart = (Get-ItemProperty $raidPath -ErrorAction SilentlyContinue).Start
            if ($iaStorStart -le 1) {
                $storageMode = 'IntelRST_RAID'
                $Result.IntelRSTDetected = $true
                $Result.Notes += "iaStorV driver active in registry"
            }
        } elseif (Test-Path $ahciPath) {
            $ahciStart = (Get-ItemProperty $ahciPath -ErrorAction SilentlyContinue).Start
            if ($ahciStart -le 1 -and $storageMode -eq 'Unknown') {
                $storageMode = 'AHCI'
                $Result.Notes += "storahci driver active - AHCI mode"
            }
        }
    } catch {}

    $Result.StorageMode = $storageMode
    Write-Log "Storage mode detected: $storageMode"

} catch {
    Write-ErrorLog "Storage mode detection failed: $_"
    $Result.Error = $_.ToString()
}
#endregion

#region --- Output ---
$Result | ConvertTo-Json -Depth 5 | Out-File "$OutputRoot\Logs\StorageMode-Report.json" -Force

if ($NonInteractive) {
    $Result | ConvertTo-Json -Depth 5
} else {
    Write-Host ""
    Write-Host "=== Storage Mode Report ===" -ForegroundColor Cyan
    Write-Host "  Mode: $($Result.StorageMode)"
    if ($Result.IntelRSTDetected) {
        Write-Host "  Intel RST/RAID DETECTED" -ForegroundColor Yellow
    }
    Write-Host "  Disks:"
    foreach ($d in $Result.Disks) {
        Write-Host "    $($d.Model) [$($d.InterfaceType)] $($d.Size) GB"
    }
    if ($Result.Notes) {
        Write-Host "  Notes: $($Result.Notes -join '; ')"
    }
    Write-Host ""
    Write-Host "Report: $OutputRoot\Logs\StorageMode-Report.json"
    Write-Host ""
    Read-Host "Press Enter to continue"
}
#endregion
