<#
.SYNOPSIS
    Assesses hardware health (battery, disk, uptime) to determine if device is worth redeploying.

.DESCRIPTION
    Checks battery degradation percentage and cycle count (laptops only), disk SMART/health
    status via Storage cmdlets, and system uptime. Flags hardware that may be failing.

.PARAMETER NonInteractive
    Suppress all prompts. Output structured JSON to stdout. Exit cleanly.

.EXAMPLE
    .\Get-DeviceHealth.ps1
    .\Get-DeviceHealth.ps1 -NonInteractive

.NOTES
    Source repos used:
    - garytown-master/hardware/HP/BatteryInfo.ps1
      (Win32_Battery, ROOT\WMI BatteryCycleCount, FullChargedCapacity, DesignedCapacity)

    Requires: Administrator
    Output:   C:\PreWipeOutput\Logs\DeviceHealth-Report.json
#>

[CmdletBinding()]
param(
    [switch]$NonInteractive
)

#region --- Init ---
$ScriptName = 'Get-DeviceHealth'
$OutputRoot = 'C:\PreWipeOutput'
$LogDir     = "$OutputRoot\Logs"
$LogFile    = "$LogDir\$ScriptName.log"
$ErrorLog   = "$OutputRoot\errors.log"

if (-not (Test-Path $OutputRoot)) { New-Item -Path $OutputRoot -ItemType Directory -Force | Out-Null }
if (-not (Test-Path $LogDir))     { New-Item -Path $LogDir     -ItemType Directory -Force | Out-Null }

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    "$ts [$Level] $Message" | Tee-Object -FilePath $LogFile -Append | Out-Null
    if (-not $NonInteractive) { Write-Host "$ts [$Level] $Message" }
}

function Write-ErrorLog {
    param([string]$Message)
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    "$ts [ERROR] [$ScriptName] $Message" | Out-File -FilePath $ErrorLog -Append
    Write-Log $Message 'ERROR'
}

# Admin check
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "ERROR: This script must be run as Administrator." -ForegroundColor Red
    exit 1
}
#endregion

$Warnings = @()

#region --- Chassis Type Detection ---
$IsLaptop = $false
try {
    $enclosure = Get-CimInstance -ClassName Win32_SystemEnclosure -ErrorAction Stop
    # Laptop chassis types: 8=Portable, 9=Laptop, 10=Notebook, 14=Sub Notebook, 31=Convertible, 32=Detachable
    $laptopTypes = @(8, 9, 10, 14, 31, 32)
    foreach ($ct in $enclosure.ChassisTypes) {
        if ($ct -in $laptopTypes) { $IsLaptop = $true; break }
    }
    Write-Log "Chassis type: $(if ($IsLaptop) { 'Laptop/Portable' } else { 'Desktop/Other' }) (types: $($enclosure.ChassisTypes -join ', '))"
} catch {
    Write-ErrorLog "Failed to detect chassis type: $_"
}
#endregion

#region --- Battery Health (Laptops) ---
$BatteryInfo = $null
if ($IsLaptop) {
    try {
        Write-Log "Checking battery health..."
        $battery = Get-CimInstance -Namespace 'root\cimv2' -ClassName Win32_Battery -ErrorAction Stop

        if ($battery) {
            $chargeRemaining = $battery.EstimatedChargeRemaining

            # Detailed battery data from WMI namespace
            $cycleCount      = $null
            $fullCharged     = $null
            $designedCap     = $null
            $degradation     = $null
            $serialNumber    = $null
            $manufacturer    = $null

            try {
                $cycleCount   = (Get-CimInstance -Namespace 'root\WMI' -ClassName BatteryCycleCount -ErrorAction Stop).CycleCount
            } catch { Write-Log "BatteryCycleCount not available" 'WARN' }

            try {
                $fullCharged  = (Get-CimInstance -Namespace 'root\WMI' -ClassName BatteryFullChargedCapacity -ErrorAction Stop).FullChargedCapacity
            } catch { Write-Log "BatteryFullChargedCapacity not available" 'WARN' }

            try {
                $staticData   = Get-CimInstance -Namespace 'root\WMI' -ClassName BatteryStaticData -ErrorAction Stop
                $designedCap  = $staticData.DesignedCapacity
                $serialNumber = $staticData.SerialNumber
                $manufacturer = $staticData.ManufactureName
            } catch { Write-Log "BatteryStaticData not available" 'WARN' }

            if ($fullCharged -and $designedCap -and $designedCap -gt 0) {
                $degradation = [math]::Round(100 - (($fullCharged / $designedCap) * 100), 1)
            }

            $BatteryInfo = [PSCustomObject]@{
                Status                   = if ($degradation -and $degradation -gt 40) { 'WARNING' } else { 'OK' }
                EstimatedChargePercent   = $chargeRemaining
                DesignedCapacityWHr      = if ($designedCap) { [math]::Round($designedCap / 1000, 1) } else { $null }
                FullChargedCapacityWHr   = if ($fullCharged) { [math]::Round($fullCharged / 1000, 1) } else { $null }
                DegradationPercent       = $degradation
                CycleCount               = $cycleCount
                SerialNumber             = $serialNumber
                Manufacturer             = $manufacturer
            }

            if ($degradation -and $degradation -gt 40) {
                $Warnings += "Battery degraded $($degradation)% (>40% threshold)"
                Write-Log "Battery WARNING: $($degradation)% degraded" 'WARN'
            } else {
                Write-Log "Battery OK: $(if ($degradation) { "$($degradation)% degraded" } else { 'degradation unknown' }), charge $($chargeRemaining)%"
            }
        } else {
            $BatteryInfo = [PSCustomObject]@{ Status = 'NotDetected' }
            Write-Log "No battery detected (docked or removed?)" 'WARN'
        }
    } catch {
        $BatteryInfo = [PSCustomObject]@{ Status = 'Error'; Error = $_.ToString() }
        Write-ErrorLog "Battery check failed: $_"
    }
} else {
    Write-Log "Desktop device - skipping battery check."
}
#endregion

#region --- Disk Health ---
$DiskResults = @()
try {
    Write-Log "Checking disk health..."
    $physicalDisks = Get-PhysicalDisk -ErrorAction Stop

    foreach ($disk in $physicalDisks) {
        $diskInfo = [PSCustomObject]@{
            DeviceId          = $disk.DeviceId
            FriendlyName      = $disk.FriendlyName
            MediaType         = $disk.MediaType
            BusType           = $disk.BusType
            SizeGB            = [math]::Round($disk.Size / 1GB, 1)
            HealthStatus      = $disk.HealthStatus
            OperationalStatus = $disk.OperationalStatus
            WearLevel         = $null
            ReadErrors        = $null
            WriteErrors       = $null
            Status            = 'OK'
        }

        # Storage reliability counters (SSD wear, error counts)
        try {
            $reliability = Get-StorageReliabilityCounter -PhysicalDisk $disk -ErrorAction Stop
            if ($reliability) {
                $diskInfo.WearLevel   = $reliability.Wear
                $diskInfo.ReadErrors  = $reliability.ReadErrorsTotal
                $diskInfo.WriteErrors = $reliability.WriteErrorsTotal
            }
        } catch {
            Write-Log "  StorageReliabilityCounter not available for $($disk.FriendlyName)" 'WARN'
        }

        # Flag unhealthy disks
        if ($disk.HealthStatus -ne 'Healthy') {
            $diskInfo.Status = 'WARNING'
            $Warnings += "Disk '$($disk.FriendlyName)' health: $($disk.HealthStatus)"
            Write-Log "Disk WARNING: $($disk.FriendlyName) - $($disk.HealthStatus)" 'WARN'
        } elseif ($diskInfo.WearLevel -and $diskInfo.WearLevel -gt 80) {
            $diskInfo.Status = 'WARNING'
            $Warnings += "SSD '$($disk.FriendlyName)' wear level $($diskInfo.WearLevel)% (>80%)"
            Write-Log "Disk WARNING: $($disk.FriendlyName) - wear $($diskInfo.WearLevel)%" 'WARN'
        } else {
            Write-Log "Disk OK: $($disk.FriendlyName) ($($diskInfo.SizeGB)GB $($disk.MediaType)) - $($disk.HealthStatus)"
        }

        $DiskResults += $diskInfo
    }
} catch {
    Write-ErrorLog "Disk health check failed: $_"
    $DiskResults += [PSCustomObject]@{ Status = 'Error'; Error = $_.ToString() }
}
#endregion

#region --- System Uptime ---
$UptimeInfo = $null
try {
    Write-Log "Checking system uptime..."
    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    $lastBoot = $os.LastBootUpTime
    $uptime = (Get-Date) - $lastBoot

    $UptimeInfo = [PSCustomObject]@{
        LastBootTime = $lastBoot.ToString('o')
        UptimeDays   = [math]::Round($uptime.TotalDays, 1)
        Status       = if ($uptime.TotalDays -gt 30) { 'WARNING' } else { 'OK' }
    }

    if ($uptime.TotalDays -gt 30) {
        $Warnings += "System uptime $([math]::Round($uptime.TotalDays)) days (>30 day threshold)"
        Write-Log "Uptime WARNING: $([math]::Round($uptime.TotalDays)) days since last reboot" 'WARN'
    } else {
        Write-Log "Uptime OK: $([math]::Round($uptime.TotalDays, 1)) days"
    }
} catch {
    Write-ErrorLog "Uptime check failed: $_"
}
#endregion

#region --- Overall Status ---
$OverallStatus = if ($Warnings.Count -gt 0) { 'WARNINGS' } else { 'HEALTHY' }
Write-Log "Overall device health: $OverallStatus"
#endregion

#region --- Output ---
$Result = [PSCustomObject]@{
    Timestamp     = (Get-Date -Format 'o')
    OverallStatus = $OverallStatus
    IsLaptop      = $IsLaptop
    Warnings      = $Warnings
    Battery       = $BatteryInfo
    Disks         = $DiskResults
    Uptime        = $UptimeInfo
}

$Result | ConvertTo-Json -Depth 5 | Out-File "$LogDir\DeviceHealth-Report.json" -Force

if ($NonInteractive) {
    $Result | ConvertTo-Json -Depth 5
} else {
    Write-Host ""
    Write-Host "=== Device Health Report ===" -ForegroundColor Cyan
    $statusColor = if ($OverallStatus -eq 'HEALTHY') { 'Green' } else { 'Yellow' }
    Write-Host "Overall: $OverallStatus" -ForegroundColor $statusColor
    Write-Host ""

    if ($BatteryInfo -and $BatteryInfo.Status -ne 'NotDetected') {
        $batColor = if ($BatteryInfo.Status -eq 'OK') { 'Green' } else { 'Yellow' }
        Write-Host "Battery:" -ForegroundColor Cyan
        Write-Host "  Charge:      $($BatteryInfo.EstimatedChargePercent)%"
        if ($BatteryInfo.DegradationPercent) {
            Write-Host "  Degradation: $($BatteryInfo.DegradationPercent)%" -ForegroundColor $batColor
        }
        if ($BatteryInfo.DesignedCapacityWHr) {
            Write-Host "  Design/Full: $($BatteryInfo.DesignedCapacityWHr) / $($BatteryInfo.FullChargedCapacityWHr) WHr"
        }
        if ($BatteryInfo.CycleCount) { Write-Host "  Cycles:      $($BatteryInfo.CycleCount)" }
    }

    Write-Host ""
    Write-Host "Disks:" -ForegroundColor Cyan
    foreach ($d in $DiskResults) {
        if ($d.FriendlyName) {
            $dColor = if ($d.Status -eq 'OK') { 'Green' } else { 'Yellow' }
            $wear = if ($d.WearLevel) { " | Wear: $($d.WearLevel)%" } else { '' }
            Write-Host "  $($d.FriendlyName): $($d.SizeGB)GB $($d.MediaType) - $($d.HealthStatus)$wear" -ForegroundColor $dColor
        }
    }

    if ($UptimeInfo) {
        Write-Host ""
        Write-Host "Uptime:" -ForegroundColor Cyan
        $uColor = if ($UptimeInfo.Status -eq 'OK') { 'Green' } else { 'Yellow' }
        Write-Host "  $($UptimeInfo.UptimeDays) days since last boot" -ForegroundColor $uColor
    }

    if ($Warnings.Count -gt 0) {
        Write-Host ""
        Write-Host "Warnings:" -ForegroundColor Yellow
        foreach ($w in $Warnings) { Write-Host "  - $w" -ForegroundColor Yellow }
    }

    Write-Host ""
    Write-Host "Report: $LogDir\DeviceHealth-Report.json"
    Write-Host ""
}
#endregion
