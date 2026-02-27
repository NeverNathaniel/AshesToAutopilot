<#
.SYNOPSIS
    Verifies device meets Windows 11 and Autopilot hardware requirements.

.DESCRIPTION
    Checks TPM 2.0, Secure Boot, UEFI, CPU compatibility, RAM (>=4GB), and
    disk space (>=64GB). Returns pass/fail per check with clear failure reasons.
    Should be run before wipe to confirm Autopilot enrollment will succeed.

.PARAMETER NonInteractive
    Suppress all prompts. Output structured JSON to stdout. Exit cleanly.

.EXAMPLE
    .\Test-AutopilotReadiness.ps1
    .\Test-AutopilotReadiness.ps1 -NonInteractive

.NOTES
    Source repos used:
    - garytown-master/OSD/GetWin11Readiness.ps1
      (TPM, SecureBoot, CPU family, memory, storage checks adapted)

    Requires: Administrator
    Output:   C:\PreWipeOutput\Logs\AutopilotReadiness-Report.json
#>

[CmdletBinding()]
param(
    [switch]$NonInteractive
)

#region --- Init ---
$ScriptName = 'Test-AutopilotReadiness'
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

$Checks = @{}
$Failures = @()

#region --- TPM Check ---
try {
    Write-Log "Checking TPM..."
    $tpm = Get-Tpm -ErrorAction Stop
    if ($tpm.TpmPresent) {
        $tpmWmi = Get-CimInstance -Namespace 'root\cimv2\Security\MicrosoftTpm' -ClassName Win32_Tpm -ErrorAction Stop
        $tpmVersion = $tpmWmi.SpecVersion
        $majorVersion = ($tpmVersion -split ',')[0].Trim() -as [int]
        $Checks['TPM'] = [PSCustomObject]@{
            Status  = if ($majorVersion -ge 2) { 'PASS' } else { 'FAIL' }
            Present = $true
            Version = $tpmVersion
            Ready   = $tpm.TpmReady
        }
        if ($majorVersion -lt 2) {
            $Failures += "TPM version $tpmVersion is below 2.0"
            Write-Log "TPM FAIL: version $tpmVersion (need 2.0+)" 'WARN'
        } else {
            Write-Log "TPM PASS: version $tpmVersion"
        }
    } else {
        $Checks['TPM'] = [PSCustomObject]@{ Status = 'FAIL'; Present = $false; Version = $null; Ready = $false }
        $Failures += "TPM not present"
        Write-Log "TPM FAIL: not present" 'WARN'
    }
} catch {
    $Checks['TPM'] = [PSCustomObject]@{ Status = 'UNDETERMINED'; Present = $null; Version = $null; Ready = $null; Error = $_.ToString() }
    Write-ErrorLog "TPM check failed: $_"
}
#endregion

#region --- Secure Boot Check ---
try {
    Write-Log "Checking Secure Boot..."
    $secureBoot = Confirm-SecureBootUEFI
    $Checks['SecureBoot'] = [PSCustomObject]@{
        Status  = if ($secureBoot) { 'PASS' } else { 'FAIL' }
        Enabled = $secureBoot
    }
    if ($secureBoot) {
        Write-Log "Secure Boot PASS: enabled"
    } else {
        $Failures += "Secure Boot is disabled"
        Write-Log "Secure Boot FAIL: disabled" 'WARN'
    }
} catch [System.PlatformNotSupportedException] {
    $Checks['SecureBoot'] = [PSCustomObject]@{ Status = 'FAIL'; Enabled = $false; Error = 'Not UEFI or not supported' }
    $Failures += "Secure Boot not supported (legacy BIOS?)"
    Write-Log "Secure Boot FAIL: platform not supported (non-UEFI)" 'WARN'
} catch {
    $Checks['SecureBoot'] = [PSCustomObject]@{ Status = 'UNDETERMINED'; Enabled = $null; Error = $_.ToString() }
    Write-ErrorLog "Secure Boot check failed: $_"
}
#endregion

#region --- CPU Check ---
try {
    Write-Log "Checking CPU..."
    $cpu = @(Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop)[0]
    $cpuPass = $true
    $cpuReasons = @()

    if ($cpu.AddressWidth -ne 64) {
        $cpuPass = $false
        $cpuReasons += "Not 64-bit ($($cpu.AddressWidth)-bit)"
    }
    if ($cpu.MaxClockSpeed -le 1000) {
        $cpuPass = $false
        $cpuReasons += "Clock speed $($cpu.MaxClockSpeed)MHz <= 1000MHz"
    }
    if ($cpu.NumberOfLogicalProcessors -lt 2) {
        $cpuPass = $false
        $cpuReasons += "Only $($cpu.NumberOfLogicalProcessors) logical core(s)"
    }

    $Checks['CPU'] = [PSCustomObject]@{
        Status           = if ($cpuPass) { 'PASS' } else { 'FAIL' }
        Name             = $cpu.Name
        Manufacturer     = $cpu.Manufacturer
        AddressWidth     = $cpu.AddressWidth
        MaxClockSpeedMHz = $cpu.MaxClockSpeed
        LogicalCores     = $cpu.NumberOfLogicalProcessors
        Cores            = $cpu.NumberOfCores
    }
    if ($cpuPass) {
        Write-Log "CPU PASS: $($cpu.Name)"
    } else {
        $Failures += $cpuReasons
        Write-Log "CPU FAIL: $($cpuReasons -join '; ')" 'WARN'
    }
} catch {
    $Checks['CPU'] = [PSCustomObject]@{ Status = 'UNDETERMINED'; Error = $_.ToString() }
    Write-ErrorLog "CPU check failed: $_"
}
#endregion

#region --- Memory Check ---
$MinMemoryGB = 4
try {
    Write-Log "Checking RAM..."
    $memoryBytes = (Get-CimInstance -ClassName Win32_PhysicalMemory -ErrorAction Stop | Measure-Object -Property Capacity -Sum).Sum
    $memoryGB = [math]::Round($memoryBytes / 1GB, 1)
    $memPass = $memoryGB -ge $MinMemoryGB

    $Checks['Memory'] = [PSCustomObject]@{
        Status     = if ($memPass) { 'PASS' } else { 'FAIL' }
        InstalledGB = $memoryGB
        RequiredGB  = $MinMemoryGB
    }
    if ($memPass) {
        Write-Log "Memory PASS: $($memoryGB)GB"
    } else {
        $Failures += "RAM $($memoryGB)GB < $($MinMemoryGB)GB required"
        Write-Log "Memory FAIL: $($memoryGB)GB < $($MinMemoryGB)GB" 'WARN'
    }
} catch {
    $Checks['Memory'] = [PSCustomObject]@{ Status = 'UNDETERMINED'; Error = $_.ToString() }
    Write-ErrorLog "Memory check failed: $_"
}
#endregion

#region --- Storage Check ---
$MinDiskGB = 64
try {
    Write-Log "Checking system disk..."
    $osDrive = (Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).SystemDrive
    $disk = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='$osDrive'" -ErrorAction Stop
    $diskGB = [math]::Round($disk.Size / 1GB, 1)
    $diskPass = $diskGB -ge $MinDiskGB

    $Checks['Storage'] = [PSCustomObject]@{
        Status     = if ($diskPass) { 'PASS' } else { 'FAIL' }
        Drive      = $osDrive
        SizeGB     = $diskGB
        FreeGB     = [math]::Round($disk.FreeSpace / 1GB, 1)
        RequiredGB = $MinDiskGB
    }
    if ($diskPass) {
        Write-Log "Storage PASS: $($diskGB)GB on $osDrive"
    } else {
        $Failures += "Disk $($diskGB)GB < $($MinDiskGB)GB required"
        Write-Log "Storage FAIL: $($diskGB)GB < $($MinDiskGB)GB" 'WARN'
    }
} catch {
    $Checks['Storage'] = [PSCustomObject]@{ Status = 'UNDETERMINED'; Error = $_.ToString() }
    Write-ErrorLog "Storage check failed: $_"
}
#endregion

#region --- UEFI Check ---
try {
    Write-Log "Checking UEFI mode..."
    $fwType = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control' -Name 'PEFirmwareType' -ErrorAction Stop).PEFirmwareType
    # 1 = BIOS, 2 = UEFI
    $isUEFI = $fwType -eq 2
    $Checks['UEFI'] = [PSCustomObject]@{
        Status       = if ($isUEFI) { 'PASS' } else { 'FAIL' }
        FirmwareType = if ($isUEFI) { 'UEFI' } else { 'Legacy BIOS' }
    }
    if ($isUEFI) {
        Write-Log "UEFI PASS: UEFI firmware"
    } else {
        $Failures += "Legacy BIOS detected (UEFI required)"
        Write-Log "UEFI FAIL: Legacy BIOS" 'WARN'
    }
} catch {
    $Checks['UEFI'] = [PSCustomObject]@{ Status = 'UNDETERMINED'; Error = $_.ToString() }
    Write-ErrorLog "UEFI check failed: $_"
}
#endregion

#region --- Overall Verdict ---
$allStatuses = $Checks.Values | ForEach-Object { $_.Status }
if ($allStatuses -contains 'FAIL') {
    $OverallStatus = 'NOT READY'
} elseif ($allStatuses -contains 'UNDETERMINED') {
    $OverallStatus = 'UNDETERMINED'
} else {
    $OverallStatus = 'READY'
}
Write-Log "Overall readiness: $OverallStatus"
#endregion

#region --- Output ---
$Result = [PSCustomObject]@{
    Timestamp     = (Get-Date -Format 'o')
    OverallStatus = $OverallStatus
    Failures      = $Failures
    Checks        = $Checks
}

$Result | ConvertTo-Json -Depth 5 | Out-File "$LogDir\AutopilotReadiness-Report.json" -Force

if ($NonInteractive) {
    $Result | ConvertTo-Json -Depth 5
} else {
    Write-Host ""
    Write-Host "=== Autopilot Readiness Report ===" -ForegroundColor Cyan
    $statusColor = switch ($OverallStatus) { 'READY' { 'Green' } 'NOT READY' { 'Red' } default { 'Yellow' } }
    Write-Host "Overall: $OverallStatus" -ForegroundColor $statusColor
    Write-Host ""
    foreach ($checkName in $Checks.Keys) {
        $check = $Checks[$checkName]
        $color = switch ($check.Status) { 'PASS' { 'Green' } 'FAIL' { 'Red' } default { 'Yellow' } }
        $detail = switch ($checkName) {
            'TPM'        { "v$($check.Version)" }
            'SecureBoot' { if ($check.Enabled) { 'Enabled' } else { 'Disabled' } }
            'CPU'        { $check.Name }
            'Memory'     { "$($check.InstalledGB)GB" }
            'Storage'    { "$($check.SizeGB)GB on $($check.Drive)" }
            'UEFI'       { $check.FirmwareType }
            default      { '' }
        }
        Write-Host "  [$($check.Status)] $($checkName): $detail" -ForegroundColor $color
    }
    if ($Failures.Count -gt 0) {
        Write-Host ""
        Write-Host "Failures:" -ForegroundColor Red
        foreach ($f in $Failures) { Write-Host "  - $f" -ForegroundColor Red }
    }
    Write-Host ""
    Write-Host "Report: $LogDir\AutopilotReadiness-Report.json"
    Write-Host ""
}
#endregion
