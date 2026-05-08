<#
.SYNOPSIS
    Extracts the Windows OEM product key and activation status before wipe.

.DESCRIPTION
    Retrieves the OEM product key embedded in BIOS firmware via SoftwareLicensingService.
    Also reports current Windows activation status, edition, and partial product key.
    Critical for license recovery if needed after device redeployment.

.PARAMETER NonInteractive
    Suppress all prompts. Output structured JSON to stdout. Exit cleanly.

.EXAMPLE
    .\Get-WindowsProductKey.ps1
    .\Get-WindowsProductKey.ps1 -NonInteractive

.NOTES
    Source repos used:
    - garytown-master/Dev/CloudScripts/Functions.ps1
      (Get-WindowsOEMProductKey function - SoftwareLicensingService.OA3xOriginalProductKey)

    Requires: Administrator
    Output:   C:\PreWipeOutput\Logs\WindowsProductKey-Report.json
#>

[CmdletBinding()]
param(
    [switch]$NonInteractive
)

#region --- Init ---
$ScriptName = 'Get-WindowsProductKey'
. (Join-Path $PSScriptRoot '..\Common\Initialize-Toolkit.ps1')
$LogFile = "$LogDir\$ScriptName.log"
if (-not (Test-AdminElevation)) { exit 1 }
#endregion

#region --- OEM Product Key ---
$OEMKey = $null
try {
    Write-Log "Querying OEM product key from BIOS firmware..."
    $sls = Get-CimInstance -ClassName SoftwareLicensingService -ErrorAction Stop
    $OEMKey = $sls.OA3xOriginalProductKey
    if ($OEMKey) {
        Write-Log "OEM product key found: $($OEMKey.Substring(0,5))...[redacted in log]"
    } else {
        Write-Log "No OEM product key embedded in firmware (common on volume-licensed devices)." 'WARN'
    }
} catch {
    Write-ErrorLog "Failed to query SoftwareLicensingService: $_"
}
#endregion

#region --- Activation Status ---
$ActivationInfo = $null
try {
    Write-Log "Querying Windows activation status..."
    $license = Get-CimInstance -ClassName SoftwareLicensingProduct -ErrorAction Stop |
        Where-Object { $_.ApplicationId -eq '55c92734-d682-4d71-983e-d6ec3f16059f' -and $_.PartialProductKey } |
        Select-Object -First 1

    if ($license) {
        $statusMap = @{
            0 = 'Unlicensed'
            1 = 'Licensed'
            2 = 'OOBGrace'
            3 = 'OOTGrace'
            4 = 'NonGenuineGrace'
            5 = 'Notification'
            6 = 'ExtendedGrace'
        }
        $ActivationInfo = [PSCustomObject]@{
            Name              = $license.Name
            Description       = $license.Description
            LicenseStatus     = $statusMap[[int]$license.LicenseStatus]
            LicenseStatusCode = $license.LicenseStatus
            PartialProductKey = $license.PartialProductKey
            ProductKeyChannel = $license.ProductKeyChannel
        }
        Write-Log "Activation: $($ActivationInfo.LicenseStatus) | Edition: $($license.Name) | Partial key: ...$($license.PartialProductKey)"
    } else {
        Write-Log "No activated Windows license found." 'WARN'
    }
} catch {
    Write-ErrorLog "Failed to query activation status: $_"
}
#endregion

#region --- OS Edition ---
$OSEdition = $null
try {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    $OSEdition = [PSCustomObject]@{
        Caption       = $os.Caption
        Version       = $os.Version
        BuildNumber   = $os.BuildNumber
        OSArchitecture = $os.OSArchitecture
    }
    Write-Log "OS: $($os.Caption) ($($os.Version))"
} catch {
    Write-ErrorLog "Failed to query OS edition: $_"
}
#endregion

#region --- Output ---
$Result = [PSCustomObject]@{
    Timestamp      = (Get-Date -Format 'o')
    OEMProductKey  = $OEMKey
    HasOEMKey      = [bool]$OEMKey
    Activation     = $ActivationInfo
    OS             = $OSEdition
}

$Result | ConvertTo-Json -Depth 5 | Out-File "$LogDir\WindowsProductKey-Report.json" -Force

if ($NonInteractive) {
    $Result | ConvertTo-Json -Depth 5
} else {
    Write-Host ""
    Write-Host "=== Windows Product Key Report ===" -ForegroundColor Cyan
    if ($OEMKey) {
        Write-Host "OEM Key:    $OEMKey" -ForegroundColor Green
    } else {
        Write-Host "OEM Key:    Not found (volume license or no embedded key)" -ForegroundColor Yellow
    }
    if ($ActivationInfo) {
        Write-Host "Status:     $($ActivationInfo.LicenseStatus)"
        Write-Host "Edition:    $($ActivationInfo.Name)"
        Write-Host "Partial:    ...$($ActivationInfo.PartialProductKey)"
        Write-Host "Channel:    $($ActivationInfo.ProductKeyChannel)"
    }
    if ($OSEdition) {
        Write-Host "OS:         $($OSEdition.Caption) ($($OSEdition.Version))"
    }
    Write-Host "Report:     $LogDir\WindowsProductKey-Report.json"
    Write-Host ""
}
#endregion

exit 0
