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
    Output:   C:\PreWipeOutput\Logs\Test-AutopilotReadiness-Report.json
#>

[CmdletBinding()]
param(
    [switch]$NonInteractive
)

#region --- Init ---
$ScriptName = 'Test-AutopilotReadiness'
. (Join-Path $PSScriptRoot '..\Common\Initialize-Toolkit.ps1')
$LogFile = "$LogDir\$ScriptName.log"
if (-not (Test-AdminElevation)) { exit 1 }
#endregion

$Checks = @{}
$Failures = @()
$Warnings = @()

#region --- TPM Check ---
try {
    Write-Log "Checking TPM..."
    $tpm = Get-Tpm -ErrorAction Stop
    if ($tpm.TpmPresent) {
        $tpmWmi = Get-CimInstance -Namespace 'root\cimv2\Security\MicrosoftTpm' -ClassName Win32_Tpm -ErrorAction Stop
        $tpmVersion = $tpmWmi.SpecVersion
        $majorVersion = ($tpmVersion -split ',')[0].Trim() -as [int]

        # Manufacturer flagging - record details and flag known-issue vendors
        $manufacturerId        = $tpmWmi.ManufacturerId
        $manufacturerVersion   = $tpmWmi.ManufacturerVersion
        $manufacturerIdString  = $null
        if ($tpmWmi.PSObject.Properties.Name -contains 'ManufacturerIdTxt') {
            $manufacturerIdString = $tpmWmi.ManufacturerIdTxt
        }
        $manufacturerIdHex = $null
        if ($null -ne $manufacturerId) {
            $manufacturerIdHex = ('0x{0:X8}' -f [uint32]$manufacturerId)
        }

        # Derive a 4-char ASCII tag from the numeric ManufacturerId if string form unavailable
        $idTag = $manufacturerIdString
        if (-not $idTag -and $null -ne $manufacturerId) {
            try {
                $bytes = [BitConverter]::GetBytes([uint32]$manufacturerId)
                [array]::Reverse($bytes)
                $idTag = ([System.Text.Encoding]::ASCII.GetString($bytes)).Trim([char]0)
            } catch {
                $idTag = $null
            }
        }

        $knownIssue = $null
        $idTagNorm = if ($idTag) { $idTag.Trim() } else { '' }
        if ($manufacturerId -eq 0x49465800 -or $idTagNorm -eq 'IFX') {
            $knownIssue = "Infineon TPMs may require a CA certificate update for Autopilot AIK; verify firmware is current"
        } elseif ($manufacturerId -eq 0x53544D20 -or $idTagNorm -eq 'STM') {
            $knownIssue = "STMicro TPMs have had RSA 3072 + SHA-384 attestation rejection issues with Autopilot AIK; verify firmware is current"
        } elseif ($manufacturerId -eq 0x4E544300 -or $idTagNorm -eq 'NTC') {
            $knownIssue = "Nuvoton TPMs have had AIK enrollment issues with Autopilot; verify firmware is current"
        }

        # A present-but-not-ready TPM 2.0 passes version checks yet fails Autopilot
        # attestation at OOBE — exactly what this pre-wipe check exists to catch.
        # Known-problem vendors likewise surface as WARN, not a silent JSON field.
        $tpmStatus = if ($majorVersion -ge 2) {
            if ($tpm.TpmReady -ne $true) { 'WARN' }
            elseif ($knownIssue)          { 'WARN' }
            else                          { 'PASS' }
        } else { 'FAIL' }
        $tpmDetail = "SpecVersion $tpmVersion; manufacturer $idTagNorm ($manufacturerIdHex)"
        if ($tpm.TpmReady -ne $true) { $tpmDetail += '; TPM NOT READY - initialize before Autopilot pre-provisioning' }
        if ($knownIssue)             { $tpmDetail += "; $knownIssue" }

        $Checks['TPM'] = [PSCustomObject]@{
            Status               = $tpmStatus
            Detail               = $tpmDetail
            Present              = $true
            Version              = $tpmVersion
            Ready                = $tpm.TpmReady
            ManufacturerId       = $manufacturerId
            ManufacturerIdHex    = $manufacturerIdHex
            ManufacturerIdString = $manufacturerIdString
            ManufacturerVersion  = $manufacturerVersion
            KnownIssue           = $knownIssue
        }
        if ($majorVersion -lt 2) {
            $Failures += "TPM version $tpmVersion is below 2.0"
            Write-Log "TPM FAIL: version $tpmVersion (need 2.0+)" 'WARN'
        } elseif ($tpmStatus -eq 'WARN') {
            $Warnings += $tpmDetail
            Write-Log "TPM WARN: $tpmDetail" 'WARN'
        } else {
            Write-Log "TPM PASS: version $tpmVersion"
        }
    } else {
        $Checks['TPM'] = [PSCustomObject]@{
            Status               = 'FAIL'
            Detail               = 'No TPM present'
            Present              = $false
            Version              = $null
            Ready                = $false
            ManufacturerId       = $null
            ManufacturerIdHex    = $null
            ManufacturerIdString = $null
            ManufacturerVersion  = $null
            KnownIssue           = $null
        }
        $Failures += "TPM not present"
        Write-Log "TPM FAIL: not present" 'WARN'
    }
} catch {
    $Checks['TPM'] = [PSCustomObject]@{
        Status               = 'UNDETERMINED'
        Detail               = "TPM query failed: $_"
        Present              = $null
        Version              = $null
        Ready                = $null
        ManufacturerId       = $null
        ManufacturerIdHex    = $null
        ManufacturerIdString = $null
        ManufacturerVersion  = $null
        KnownIssue           = $null
        Error                = $_.ToString()
    }
    Write-ErrorLog "TPM check failed: $_"
}
#endregion

#region --- Secure Boot Check ---
try {
    Write-Log "Checking Secure Boot..."
    $secureBoot = Confirm-SecureBootUEFI
    $Checks['SecureBoot'] = [PSCustomObject]@{
        Status  = if ($secureBoot) { 'PASS' } else { 'FAIL' }
        Detail  = if ($secureBoot) { 'Secure Boot enabled' } else { 'Secure Boot disabled' }
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
    if ($cpu.MaxClockSpeed -lt 1000) { # 1 GHz or faster passes; exactly 1000 MHz is compliant
        $cpuPass = $false
        $cpuReasons += "Clock speed $($cpu.MaxClockSpeed)MHz < 1000MHz"
    }
    if ($cpu.NumberOfLogicalProcessors -lt 2) {
        $cpuPass = $false
        $cpuReasons += "Only $($cpu.NumberOfLogicalProcessors) logical core(s)"
    }

    $Checks['CPU'] = [PSCustomObject]@{
        Status           = if ($cpuPass) { 'PASS' } else { 'FAIL' }
        Detail           = if ($cpuPass) { "$($cpu.Name) - $($cpu.MaxClockSpeed)MHz, $($cpu.NumberOfLogicalProcessors) logical cores" } else { $cpuReasons -join '; ' }
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
        Detail     = "$($memoryGB)GB installed (minimum $($MinMemoryGB)GB)"
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
        Detail     = "$($diskGB)GB on $osDrive (minimum $($MinDiskGB)GB)"
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
        Detail       = if ($isUEFI) { 'UEFI firmware' } else { 'Legacy BIOS - UEFI required for Autopilot' }
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
} elseif ($allStatuses -contains 'WARN') {
    $OverallStatus = 'READY WITH WARNINGS'
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
    Warnings      = $Warnings
    Checks        = $Checks
}

$Result | ConvertTo-Json -Depth 5 | Out-File "$LogDir\Test-AutopilotReadiness-Report.json" -Force

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
    $knownIssues = @()
    foreach ($checkName in $Checks.Keys) {
        $check = $Checks[$checkName]
        if (($check.PSObject.Properties.Name -contains 'KnownIssue') -and $check.KnownIssue) {
            $knownIssues += "[$checkName] $($check.KnownIssue)"
        }
    }
    if ($knownIssues.Count -gt 0) {
        Write-Host ""
        Write-Host "Known issues (informational):" -ForegroundColor Yellow
        foreach ($ki in $knownIssues) { Write-Host "  - $ki" -ForegroundColor Yellow }
    }
    Write-Host ""
    Write-Host "Report: $LogDir\Test-AutopilotReadiness-Report.json"
    Write-Host ""
}
#endregion

if ($OverallStatus -eq 'NOT READY') { exit 1 }
exit 0
