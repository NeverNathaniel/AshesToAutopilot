<#
.SYNOPSIS
    Checks if an Autopilot profile has been downloaded and applied to this device.

.DESCRIPTION
    - Checks expected registry keys for Autopilot profile presence.
    - Checks for profile JSON files in expected locations.
    - Reports: profile present (yes/no), profile name if available, assigned tenant.

.PARAMETER NonInteractive
    Suppress all prompts. Output structured JSON to stdout. Exit cleanly.

.EXAMPLE
    .\Test-AutopilotProfile.ps1
    .\Test-AutopilotProfile.ps1 -NonInteractive

.NOTES
    Source repos used:
    - public-main/Powershell Scripts/Intune/migrate-autopilot-device.ps1
      (Autopilot profile registry key patterns)
    - garytown-master/OSD/ (various Autopilot detection references)
    Registry paths for Autopilot profile:
      HKLM:\SOFTWARE\Microsoft\Provisioning\Diagnostics\Autopilot\EstablishedCorrelation
      HKLM:\SOFTWARE\Microsoft\Provisioning\AutopilotPolicyCache
      %SystemDrive%\Recovery\OEM\AutopilotConfigurationFile.json

    Requires: Administrator
    Output:   C:\PreWipeOutput\Logs\Test-AutopilotProfile.log
#>

[CmdletBinding()]
param(
    [switch]$NonInteractive
)

#region --- Init ---
$ScriptName = 'Test-AutopilotProfile'
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

#region --- Autopilot Profile Check ---
$Result = [PSCustomObject]@{
    Timestamp       = (Get-Date -Format 'o')
    ProfilePresent  = $false
    ProfileName     = $null
    TenantDomain    = $null
    TenantID        = $null
    DeploymentMode  = $null
    PolicyCachePath = $null
    ConfigFilePath  = $null
    Sources         = @()
    Error           = $null
}

# Known registry and file paths for Autopilot profile
$autopilotRegPaths = @(
    'HKLM:\SOFTWARE\Microsoft\Provisioning\Diagnostics\Autopilot',
    'HKLM:\SOFTWARE\Microsoft\Provisioning\AutopilotPolicyCache',
    'HKLM:\SOFTWARE\Microsoft\Provisioning\AutopilotManagedDeviceInfo'
)

$autopilotFilePaths = @(
    "$env:SystemDrive\Recovery\OEM\AutopilotConfigurationFile.json",
    "$env:ProgramData\Microsoft\Provisioning\AutopilotConfigurationFile.json",
    "$env:SystemRoot\Provisioning\Autopilot\AutopilotConfigurationFile.json"
)

try {
    # Check registry
    foreach ($regPath in $autopilotRegPaths) {
        if (Test-Path $regPath) {
            Write-Log "Found Autopilot registry key: $regPath"
            $props = Get-ItemProperty $regPath -ErrorAction SilentlyContinue
            $Result.Sources += "Registry: $regPath"
            $Result.ProfilePresent = $true
            $Result.PolicyCachePath = $regPath

            # Extract tenant info if available
            if ($props.TenantDomain) { $Result.TenantDomain = $props.TenantDomain }
            if ($props.TenantId)     { $Result.TenantID     = $props.TenantId }
            if ($props.CloudAssignedTenantId) { $Result.TenantID = $props.CloudAssignedTenantId }
            if ($props.CloudAssignedTenantDomain) { $Result.TenantDomain = $props.CloudAssignedTenantDomain }

            # Check sub-keys for profile details
            $subKeys = Get-ChildItem $regPath -ErrorAction SilentlyContinue
            foreach ($sub in $subKeys) {
                $subProps = Get-ItemProperty $sub.PSPath -ErrorAction SilentlyContinue
                if ($subProps.CloudAssignedTenantDomain) {
                    $Result.TenantDomain = $subProps.CloudAssignedTenantDomain
                }
                if ($subProps.DeploymentMode) {
                    $Result.DeploymentMode = $subProps.DeploymentMode
                }
                Write-Log "  Sub-key $($sub.PSChildName): $($subProps | ConvertTo-Json -Compress -ErrorAction SilentlyContinue)" 'DEBUG'
            }
        }
    }

    # Check file-based profile
    foreach ($filePath in $autopilotFilePaths) {
        if (Test-Path $filePath) {
            Write-Log "Found Autopilot config file: $filePath"
            $Result.Sources       += "File: $filePath"
            $Result.ProfilePresent = $true
            $Result.ConfigFilePath = $filePath

            try {
                $profileJson = Get-Content $filePath -Raw -ErrorAction Stop | ConvertFrom-Json
                if ($profileJson.CloudAssignedTenantDomain) {
                    $Result.TenantDomain = $profileJson.CloudAssignedTenantDomain
                }
                if ($profileJson.CloudAssignedTenantId) {
                    $Result.TenantID = $profileJson.CloudAssignedTenantId
                }
                if ($profileJson.DeploymentMode) {
                    $Result.DeploymentMode = $profileJson.DeploymentMode
                }
                if ($profileJson.ZtdRegistrationId) {
                    $Result.ProfileName = $profileJson.ZtdRegistrationId
                }
                Write-Log "  Tenant: $($Result.TenantDomain) | Mode: $($Result.DeploymentMode)"
            } catch {
                Write-Log "  JSON parse error: $_" 'WARN'
            }
        }
    }

    # Additional check: OOBE/Autopilot related WMI
    try {
        $mdmInfo = Get-CimInstance -Namespace 'root\cimv2\mdm\dmmap' -ClassName 'MDM_EnrollmentStatusTracking_EnrollmentStatusTrackingPolicy01' -ErrorAction SilentlyContinue
        if ($mdmInfo) {
            $Result.Sources       += "MDM WMI namespace"
            $Result.ProfilePresent = $true
            Write-Log "MDM enrollment tracking found"
        }
    } catch {}

    if (-not $Result.ProfilePresent) {
        Write-Log "No Autopilot profile found on this device"
    } else {
        Write-Log "Autopilot profile detected | Tenant: $($Result.TenantDomain) | TenantID: $($Result.TenantID)"
    }

} catch {
    Write-ErrorLog "Autopilot profile check failed: $_"
    $Result.Error = $_.ToString()
}
#endregion

#region --- Output ---
$Result | ConvertTo-Json -Depth 5 | Out-File "$OutputRoot\Logs\AutopilotProfile-Status.json" -Force

if ($NonInteractive) {
    $Result | ConvertTo-Json -Depth 5
} else {
    Write-Host ""
    Write-Host "=== Autopilot Profile Status ===" -ForegroundColor Cyan
    Write-Host ""

    if (-not $Result.ProfilePresent) {
        Write-Host "  NO AUTOPILOT PROFILE FOUND ON THIS DEVICE." -ForegroundColor Red
        Write-Host "  The device has not received an Autopilot deployment profile." -ForegroundColor Red
    } else {
        # Map deployment mode integer to label
        $modeLabel = switch ($Result.DeploymentMode) {
            0       { 'User-Driven AAD Join' }
            1       { 'Self-Deploying' }
            2       { 'User-Driven Hybrid AAD Join' }
            default { if ($Result.DeploymentMode) { $Result.DeploymentMode.ToString() } else { 'Unknown' } }
        }

        [PSCustomObject]@{
            'Profile Present'   = 'Yes'
            'Tenant Domain'     = $Result.TenantDomain ?? 'Unknown'
            'Tenant ID'         = $Result.TenantID ?? 'Unknown'
            'Deployment Mode'   = $modeLabel
            'Profile Name/ID'   = $Result.ProfileName ?? 'Unknown'
            'Sources'           = ($Result.Sources -join '; ')
        } | Format-List | Out-String | ForEach-Object { Write-Host $_ -ForegroundColor Green }

        if ($Result.Error) {
            Write-Host "  Warning: $($Result.Error)" -ForegroundColor Yellow
        }
    }

    Write-Host ""
    Write-Host "Report: $OutputRoot\Logs\AutopilotProfile-Status.json" -ForegroundColor Cyan
    Write-Host ""
}
#endregion
