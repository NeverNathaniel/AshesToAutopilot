<#
.SYNOPSIS
    Collects hardware hash and registers device with Windows Autopilot/Intune.

.DESCRIPTION
    - Installs or updates the Get-WindowsAutopilotInfo (community) module from PSGallery.
    - Collects hardware hash using the module.
    - Uploads device to Intune/Autopilot via Microsoft Graph.
    - Reports success or failure with details.

.PARAMETER NonInteractive
    Suppress all prompts. Output structured JSON to stdout. Exit cleanly.

.PARAMETER GroupTag
    Optional Autopilot Group Tag to assign to the device.

.PARAMETER AssignedUser
    Optional UPN of the user to pre-assign to the device.

.EXAMPLE
    .\Register-AutopilotDevice.ps1
    .\Register-AutopilotDevice.ps1 -NonInteractive
    .\Register-AutopilotDevice.ps1 -GroupTag "PreWipe" -AssignedUser "user@domain.com"

.NOTES
    Source repos used:
    - public-main/Powershell Scripts/Intune/Harvest-hash-remediation/runbook.ps1
      (Graph API POST pattern for importing Autopilot device identities)
    - public-main/Powershell Scripts/Intune/migrate-autopilot-device.ps1
      (Autopilot device migration patterns)
    - garytown-master/ (various Autopilot/OSD references for hash collection approach)

    Module used: Get-WindowsAutopilotInfo (Michael Niehaus, PSGallery)
    Requires: Administrator, internet access, Intune/Azure AD permissions
    Output:   C:\PreWipeOutput\Logs\Register-AutopilotDevice.log
#>

[CmdletBinding()]
param(
    [switch]$NonInteractive,
    [string]$GroupTag = '',
    [string]$AssignedUser = ''
)

#region --- Init ---
$ScriptName = 'Register-AutopilotDevice'
. (Join-Path $PSScriptRoot '..\Common\Initialize-Toolkit.ps1')
$LogFile = "$LogDir\$ScriptName.log"
if (-not (Test-AdminElevation)) { exit 1 }
#endregion

#region --- Module Install ---
$Result = [PSCustomObject]@{
    Timestamp      = (Get-Date -Format 'o')
    SerialNumber   = $null
    HardwareHash   = $null
    ModuleVersion  = $null
    UploadStatus   = $null
    UploadResponse = $null
    GroupTag       = $GroupTag
    AssignedUser   = $AssignedUser
    Success        = $false
    Error          = $null
}

Write-Log "Installing/updating Get-WindowsAutopilotInfo module..."

try {
    # Set TLS 1.2 for PSGallery
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    # Install NuGet provider if needed
    $null = Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope AllUsers -ErrorAction SilentlyContinue

    # Check if module exists
    $existingModule = Get-Module -Name 'Get-WindowsAutopilotInfo' -ListAvailable -ErrorAction SilentlyContinue
    if (-not $existingModule) {
        Write-Log "Installing Get-WindowsAutopilotInfo from PSGallery..."
        Install-Module -Name 'Get-WindowsAutopilotInfo' -Force -Scope AllUsers -ErrorAction Stop
    } else {
        Write-Log "Module found: v$($existingModule.Version) - checking for updates..."
        Update-Module -Name 'Get-WindowsAutopilotInfo' -Force -ErrorAction SilentlyContinue
    }

    $moduleInfo = Get-Module -Name 'Get-WindowsAutopilotInfo' -ListAvailable |
        Sort-Object Version -Descending | Select-Object -First 1
    $Result.ModuleVersion = $moduleInfo.Version.ToString()
    Write-Log "Module ready: v$($Result.ModuleVersion)"

} catch {
    Write-ErrorLog "Module install failed: $_"
    $Result.Error = "Module install failed: $_"
    if ($NonInteractive) { $Result | ConvertTo-Json -Depth 5; exit 1 }
    Write-Host "ERROR: $_" -ForegroundColor Red
    exit 1
}
#endregion

#region --- Hardware Hash Collection ---
Write-Log "Collecting hardware hash..."

try {
    # Get serial number
    $bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction Stop
    $Result.SerialNumber = $bios.SerialNumber
    Write-Log "Serial Number: $($Result.SerialNumber)"

    # Collect hardware hash using OA3Tool via the community module approach
    # The Get-WindowsAutopilotInfo module uses OA3 Tool or WMI to get hardware hash
    $csvPath = "$OutputRoot\AutopilotHash.csv"

    # Run the community module to collect and optionally upload
    if ($AssignedUser -or $GroupTag) {
        $extraArgs = @{}
        if ($GroupTag)    { $extraArgs.GroupTag     = $GroupTag }
        if ($AssignedUser){ $extraArgs.AssignedUser = $AssignedUser }
        Get-WindowsAutopilotInfo -OutputFile $csvPath @extraArgs -ErrorAction Stop
    } else {
        Get-WindowsAutopilotInfo -OutputFile $csvPath -ErrorAction Stop
    }

    if (Test-Path $csvPath) {
        $csvData = Import-Csv $csvPath -ErrorAction Stop
        $hashEntry = $csvData | Select-Object -First 1
        $Result.HardwareHash = if ($hashEntry.'Hardware Hash') { "PRESENT (length: $($hashEntry.'Hardware Hash'.Length))" } else { 'Not collected' }
        Write-Log "Hardware hash collected. CSV saved to $csvPath"
        $Result.UploadStatus = 'HashCollected'
    } else {
        throw "Output CSV not created at $csvPath"
    }

} catch {
    Write-ErrorLog "Hardware hash collection failed: $_"
    $Result.Error = $_.ToString()
    if ($NonInteractive) { $Result | ConvertTo-Json -Depth 5 }
    exit 1
}
#endregion

#region --- Upload to Autopilot ---
Write-Log "Uploading device to Autopilot..."

try {
    # Use the -Online flag to upload directly
    $uploadParams = @{
        OutputFile = $csvPath
        Online     = $true
    }
    if ($GroupTag)    { $uploadParams.GroupTag     = $GroupTag }
    if ($AssignedUser){ $uploadParams.AssignedUser = $AssignedUser }

    Get-WindowsAutopilotInfo @uploadParams -ErrorAction Stop

    $Result.UploadStatus   = 'Uploaded'
    $Result.UploadResponse = 'Device submitted to Autopilot successfully'
    $Result.Success        = $true
    Write-Log "Device successfully registered with Autopilot"

} catch {
    $errMsg = $_.ToString()
    Write-ErrorLog "Autopilot upload failed: $errMsg"
    $Result.UploadStatus   = 'UploadFailed'
    $Result.UploadResponse = $errMsg
    $Result.Success        = $false
    $Result.Error = "Upload failed (hash saved to $csvPath): $errMsg"
}
#endregion

#region --- Output ---
$Result | ConvertTo-Json -Depth 5 | Out-File "$OutputRoot\Logs\AutopilotRegister-Result.json" -Force

if ($NonInteractive) {
    $Result | ConvertTo-Json -Depth 5
} else {
    Write-Host ""
    Write-Host "=== Autopilot Registration Result ===" -ForegroundColor Cyan
    Write-Host "  Serial:        $($Result.SerialNumber)"
    Write-Host "  Module:        v$($Result.ModuleVersion)"
    Write-Host "  Hash:          $($Result.HardwareHash)"
    Write-Host "  Upload Status: $($Result.UploadStatus)"
    $color = if ($Result.Success) { 'Green' } else { 'Red' }
    Write-Host "  Success:       $($Result.Success)" -ForegroundColor $color
    if ($Result.Error) { Write-Host "  Error: $($Result.Error)" -ForegroundColor Yellow }
    Write-Host ""
    Write-Host "CSV saved: $OutputRoot\AutopilotHash.csv"
    Write-Host ""
}
#endregion
