<#
.SYNOPSIS
    Checks for a locally downloaded Autopilot deployment profile and reports assignment details.

.DESCRIPTION
    Queries local registry and file system for Autopilot deployment profile data
    instead of connecting to Microsoft Graph. Checks three locations:
      1. Registry: HKLM:\SOFTWARE\Microsoft\Provisioning\Diagnostics\Autopilot
      2. JSON file: C:\Windows\Provisioning\Autopilot\AutopilotConfigurationFile.json
      3. dsregcmd /status for Azure AD join and tenant information

    Reports: serial number, tenant domain, tenant ID, profile downloaded (yes/no),
    forced enrollment status, Azure AD join state, and deployment profile details.

.PARAMETER NonInteractive
    Suppress all prompts. Output structured JSON to stdout. Exit cleanly.

.EXAMPLE
    .\Get-AutopilotAssignment.ps1
    .\Get-AutopilotAssignment.ps1 -NonInteractive

.NOTES
    Source repos used:
    - garytown-master/OSD/CloudOSD/OSDCloud-CloudFunctions_BACKUP.ps1
      (Autopilot registry path HKLM:\SOFTWARE\Microsoft\Provisioning\Diagnostics\Autopilot,
       CloudAssignedForcedEnrollment detection, profile property enumeration)
    - garytown-master/OSD/CloudOSD/CopyJson.ps1
      (AutopilotConfigurationFile.json path at C:\Windows\Provisioning\Autopilot\)
    - public-main/Powershell Scripts/Intune/create-windows-iso-with-apjson.ps1
      (Autopilot JSON structure: CloudAssignedTenantDomain, ZtdCorrelationId, etc.)

    Requires: Administrator
    Output:   C:\PreWipeOutput\Logs\AutopilotAssignment-Report.json
#>

[CmdletBinding()]
param(
    [switch]$NonInteractive
)

#region --- Init ---
$ScriptName = 'Get-AutopilotAssignment'
. (Join-Path $PSScriptRoot '..\Common\Initialize-Toolkit.ps1')
$LogFile = "$LogDir\$ScriptName.log"
if (-not (Test-AdminElevation)) { exit 1 }
#endregion

#region --- Get Serial Number ---
$Result = [PSCustomObject]@{
    Timestamp             = (Get-Date -Format 'o')
    SerialNumber          = $null
    ProfileDownloaded     = $false
    ForcedEnrollment      = $false
    TenantDomain          = $null
    TenantId              = $null
    AzureADJoined         = $false
    DeviceName            = $null
    CorrelationId         = $null
    OobeConfig            = $null
    ProfileSource         = $null
    AssignedUser          = $null
    ProfileName           = $null
    EnrollmentState       = $null
    Error                 = $null
}

try {
    $bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction Stop
    $Result.SerialNumber = $bios.SerialNumber
    Write-Log "Device serial number: $($Result.SerialNumber)"
} catch {
    Write-ErrorLog "Failed to get serial number: $_"
    $Result.Error = $_.ToString()
}
#endregion

#region --- Check 1: Autopilot Registry ---
Write-Log "Checking Autopilot registry keys..."
$regPath = 'HKLM:\SOFTWARE\Microsoft\Provisioning\Diagnostics\Autopilot'

try {
    if (Test-Path $regPath) {
        $regData = Get-ItemProperty -Path $regPath -ErrorAction Stop

        if ($regData.CloudAssignedForcedEnrollment -eq 1) {
            $Result.ProfileDownloaded = $true
            $Result.ForcedEnrollment  = $true
            $Result.ProfileSource     = 'Registry'
            Write-Log "Autopilot profile found in registry (forced enrollment enabled)"
        }

        if ($regData.CloudAssignedTenantDomain) {
            $Result.TenantDomain = $regData.CloudAssignedTenantDomain
            Write-Log "Tenant domain: $($Result.TenantDomain)"
        }

        if ($regData.TenantId) {
            $Result.TenantId = $regData.TenantId
            Write-Log "Tenant ID: $($Result.TenantId)"
        }

        if ($regData.CloudAssignedOobeConfig) {
            $Result.OobeConfig = $regData.CloudAssignedOobeConfig.ToString()
        }

        if ($regData.AutopilotServiceCorrelationId) {
            $Result.CorrelationId = $regData.AutopilotServiceCorrelationId
        }

        if ($regData.IsAutoPilotDisabled -eq 0 -or $null -eq $regData.IsAutoPilotDisabled) {
            Write-Log "Autopilot is NOT disabled"
        } elseif ($regData.IsAutoPilotDisabled -eq 1) {
            Write-Log "WARNING: IsAutoPilotDisabled = 1" 'WARN'
        }
    } else {
        Write-Log "Autopilot registry path not found: $regPath" 'WARN'
    }
} catch {
    Write-ErrorLog "Error reading Autopilot registry: $_"
}
#endregion

#region --- Check 2: Autopilot JSON File ---
Write-Log "Checking for Autopilot configuration JSON file..."
$jsonPath = 'C:\Windows\Provisioning\Autopilot\AutopilotConfigurationFile.json'

try {
    if (Test-Path $jsonPath) {
        $jsonContent = Get-Content $jsonPath -Raw -ErrorAction Stop | ConvertFrom-Json

        $Result.ProfileDownloaded = $true
        if (-not $Result.ProfileSource) { $Result.ProfileSource = 'JSON File' }
        else { $Result.ProfileSource += ' + JSON File' }

        Write-Log "AutopilotConfigurationFile.json found"

        if ($jsonContent.CloudAssignedTenantDomain -and -not $Result.TenantDomain) {
            $Result.TenantDomain = $jsonContent.CloudAssignedTenantDomain
        }
        if ($jsonContent.CloudAssignedTenantId -and -not $Result.TenantId) {
            $Result.TenantId = $jsonContent.CloudAssignedTenantId
        }
        if ($jsonContent.CloudAssignedDeviceName) {
            $Result.DeviceName = $jsonContent.CloudAssignedDeviceName
            Write-Log "Assigned device name template: $($Result.DeviceName)"
        }
        if ($jsonContent.ZtdCorrelationId -and -not $Result.CorrelationId) {
            $Result.CorrelationId = $jsonContent.ZtdCorrelationId
        }
        if ($jsonContent.CloudAssignedForcedEnrollment -eq 1) {
            $Result.ForcedEnrollment = $true
        }

        # Try to extract assigned user from AadServerData
        if ($jsonContent.CloudAssignedAadServerData) {
            try {
                $aadData = $jsonContent.CloudAssignedAadServerData | ConvertFrom-Json -ErrorAction SilentlyContinue
                if ($aadData.ZeroTouchConfig) {
                    $ztConfig = $aadData.ZeroTouchConfig | ConvertFrom-Json -ErrorAction SilentlyContinue
                    if ($ztConfig.ForcedEnrollment -and $ztConfig.ForcedEnrollment.UPN) {
                        $Result.AssignedUser = $ztConfig.ForcedEnrollment.UPN
                        Write-Log "Assigned user from JSON: $($Result.AssignedUser)"
                    }
                }
            } catch {
                Write-Log "Could not parse AadServerData for user assignment" 'WARN'
            }
        }
    } else {
        Write-Log "AutopilotConfigurationFile.json not found at $jsonPath"
    }
} catch {
    Write-ErrorLog "Error reading Autopilot JSON file: $_"
}
#endregion

#region --- Check 3: dsregcmd for Azure AD join status ---
Write-Log "Checking Azure AD join status via dsregcmd..."
try {
    $dsregOutput = & dsregcmd /status 2>&1 | Out-String

    if ($dsregOutput -match 'AzureAdJoined\s*:\s*YES') {
        $Result.AzureADJoined = $true
        Write-Log "Device is Azure AD Joined"
    } else {
        Write-Log "Device is NOT Azure AD Joined"
    }

    if ($dsregOutput -match 'TenantId\s*:\s*([a-f0-9-]{36})') {
        if (-not $Result.TenantId) {
            $Result.TenantId = $Matches[1]
            Write-Log "Tenant ID from dsregcmd: $($Result.TenantId)"
        }
    }

    if ($dsregOutput -match 'TenantName\s*:\s*(.+)') {
        $tenantName = $Matches[1].Trim()
        if ($tenantName -and -not $Result.TenantDomain) {
            $Result.TenantDomain = $tenantName
        }
    }
} catch {
    Write-ErrorLog "dsregcmd failed: $_"
}
#endregion

#region --- Derive summary fields ---
if ($Result.ProfileDownloaded) {
    $Result.EnrollmentState = 'ProfileDownloaded'
    if ($Result.ForcedEnrollment) {
        $Result.ProfileName = 'Autopilot (Forced Enrollment)'
    } else {
        $Result.ProfileName = 'Autopilot (Self-Deploying or User-Driven)'
    }
} else {
    $Result.EnrollmentState = 'NoProfileFound'
    $Result.ProfileName = '(none)'
}
#endregion

#region --- Output ---
$Result | ConvertTo-Json -Depth 5 | Out-File "$OutputRoot\Logs\AutopilotAssignment-Report.json" -Force

if ($NonInteractive) {
    $Result | ConvertTo-Json -Depth 5
} else {
    Write-Host ""
    Write-Host "=== Autopilot Assignment (Local Check) ===" -ForegroundColor Cyan
    Write-Host "  Serial Number:      $($Result.SerialNumber)"
    Write-Host "  Profile Downloaded: $(if ($Result.ProfileDownloaded) { 'YES' } else { 'NO' })" -ForegroundColor $(if ($Result.ProfileDownloaded) { 'Green' } else { 'Yellow' })
    Write-Host "  Forced Enrollment:  $($Result.ForcedEnrollment)"
    Write-Host "  Tenant Domain:      $(if ($Result.TenantDomain) { $Result.TenantDomain } else { '(not found)' })"
    Write-Host "  Tenant ID:          $(if ($Result.TenantId) { $Result.TenantId } else { '(not found)' })"
    Write-Host "  Azure AD Joined:    $($Result.AzureADJoined)"
    Write-Host "  Assigned User:      $(if ($Result.AssignedUser) { $Result.AssignedUser } else { '(not embedded in profile)' })"
    Write-Host "  Device Name:        $(if ($Result.DeviceName) { $Result.DeviceName } else { '(not set)' })"
    Write-Host "  Profile Source:     $(if ($Result.ProfileSource) { $Result.ProfileSource } else { 'None' })"
    Write-Host "  Correlation ID:     $(if ($Result.CorrelationId) { $Result.CorrelationId } else { '(none)' })"
    if ($Result.Error) { Write-Host "  Error: $($Result.Error)" -ForegroundColor Yellow }
    Write-Host ""
    Write-Host "Report: $OutputRoot\Logs\AutopilotAssignment-Report.json"
    Write-Host ""
}
#endregion

exit 0
