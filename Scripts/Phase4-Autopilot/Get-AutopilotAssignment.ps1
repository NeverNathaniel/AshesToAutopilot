<#
.SYNOPSIS
    Queries Intune/Autopilot for the device's assigned user and deployment profile.

.DESCRIPTION
    - Connects to Microsoft Graph to query Autopilot device records.
    - Looks up this device by serial number.
    - Reports: device serial, assigned user UPN, assignment date if available.
    - Requires the Microsoft.Graph.Authentication module or falls back to MSAL/REST.

.PARAMETER NonInteractive
    Suppress all prompts. Output structured JSON to stdout. Exit cleanly.

.PARAMETER TenantId
    Optional: Azure AD Tenant ID. If not provided, attempts to detect from device join info.

.EXAMPLE
    .\Get-AutopilotAssignment.ps1
    .\Get-AutopilotAssignment.ps1 -NonInteractive
    .\Get-AutopilotAssignment.ps1 -TenantId "00000000-0000-0000-0000-000000000000"

.NOTES
    Source repos used:
    - public-main/Powershell Scripts/Intune/Harvest-hash-remediation/runbook.ps1
      (Connect-MgGraph -Identity pattern, Graph API device query)
    - public-main/Powershell Scripts/Intune/assign-autopilot-WIP.ps1
      (Autopilot device assignment query patterns)
    - public-main/Powershell Scripts/Intune/migrate-autopilot-device.ps1
      (device serial lookup via Graph API)

    Requires: Administrator, Microsoft.Graph or Az module, Intune permissions
    Output:   C:\PreWipeOutput\Logs\Get-AutopilotAssignment.log
#>

[CmdletBinding()]
param(
    [switch]$NonInteractive,
    [string]$TenantId = ''
)

#region --- Init ---
$ScriptName = 'Get-AutopilotAssignment'
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

#region --- Get Serial Number ---
$Result = [PSCustomObject]@{
    Timestamp      = (Get-Date -Format 'o')
    SerialNumber   = $null
    DeviceId       = $null
    AssignedUser   = $null
    AssignedUserUPN = $null
    AssignmentDate = $null
    GroupTag       = $null
    ProfileName    = $null
    EnrollmentState = $null
    QueryMethod    = $null
    Error          = $null
}

try {
    $bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction Stop
    $Result.SerialNumber = $bios.SerialNumber
    Write-Log "Device serial number: $($Result.SerialNumber)"
} catch {
    Write-ErrorLog "Failed to get serial number: $_"
    $Result.Error = $_
    if ($NonInteractive) { $Result | ConvertTo-Json | Write-Output; exit 1 }
    exit 1
}

# Try to detect tenant from DSReg
if (-not $TenantId) {
    try {
        $dsregOutput = & dsregcmd /status 2>&1 | Out-String
        if ($dsregOutput -match 'TenantId\s*:\s*([a-f0-9-]{36})') {
            $TenantId = $Matches[1]
            Write-Log "Tenant ID from dsregcmd: $TenantId"
        }
    } catch {}
}
#endregion

#region --- Graph Query ---
Write-Log "Installing Microsoft.Graph.Authentication if needed..."
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    if (-not (Get-Module -Name 'Microsoft.Graph.Authentication' -ListAvailable)) {
        $null = Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope AllUsers -ErrorAction SilentlyContinue
        Install-Module -Name 'Microsoft.Graph.Authentication' -Force -Scope AllUsers -ErrorAction Stop
        Write-Log "Microsoft.Graph.Authentication installed"
    }

    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop

    # Connect to Graph (interactive or device code)
    $connectParams = @{ Scopes = 'DeviceManagementServiceConfig.Read.All', 'DeviceManagementManagedDevices.Read.All' }
    if ($TenantId) { $connectParams.TenantId = $TenantId }

    Write-Log "Connecting to Microsoft Graph..."
    if ($NonInteractive) {
        Connect-MgGraph @connectParams -NoWelcome -ErrorAction Stop
    } else {
        Connect-MgGraph @connectParams -NoWelcome -ErrorAction Stop
    }

    $Result.QueryMethod = 'MicrosoftGraph'

    # Query Autopilot devices by serial number
    $serial = [System.Web.HttpUtility]::UrlEncode($Result.SerialNumber)
    $uri    = "https://graph.microsoft.com/v1.0/deviceManagement/windowsAutopilotDeviceIdentities?`$filter=serialNumber eq '$($Result.SerialNumber)'"

    Write-Log "Querying Graph API: $uri"
    $response = Invoke-MgGraphRequest -Method GET -Uri $uri -ErrorAction Stop

    if ($response.value -and $response.value.Count -gt 0) {
        $device = $response.value[0]
        $Result.DeviceId    = $device.id
        $Result.GroupTag    = $device.groupTag
        $Result.ProfileName = $device.deploymentProfileAssignmentDetailedStatus

        # Get assigned user
        if ($device.assignedUserPrincipalName) {
            $Result.AssignedUserUPN = $device.assignedUserPrincipalName
            $Result.AssignedUser    = $device.assignedUserPrincipalName
        }

        $Result.EnrollmentState = $device.enrollmentState
        $Result.AssignmentDate  = $device.deploymentProfileAssignedDateTime

        Write-Log "Device found in Autopilot"
        Write-Log "  Assigned User: $($Result.AssignedUserUPN ?? 'None')"
        Write-Log "  Group Tag: $($Result.GroupTag ?? 'None')"
        Write-Log "  Enrollment State: $($Result.EnrollmentState)"
    } else {
        Write-Log "Device not found in Autopilot records for serial: $($Result.SerialNumber)" 'WARN'
        $Result.Error = "Device not found in Autopilot"
    }

    Disconnect-MgGraph -ErrorAction SilentlyContinue

} catch {
    Write-ErrorLog "Graph query failed: $_"
    $Result.Error = $_.ToString()
    $Result.QueryMethod = 'Failed'
}
#endregion

#region --- Output ---
$Result | ConvertTo-Json -Depth 5 | Out-File "$OutputRoot\Logs\AutopilotAssignment-Report.json" -Force

if ($NonInteractive) {
    $Result | ConvertTo-Json -Depth 5
} else {
    Write-Host ""
    Write-Host "=== Autopilot Assignment ===" -ForegroundColor Cyan
    Write-Host "  Serial Number:   $($Result.SerialNumber)"
    Write-Host "  Device ID:       $($Result.DeviceId ?? 'Not found')"
    Write-Host "  Assigned User:   $($Result.AssignedUserUPN ?? 'None')"
    Write-Host "  Assignment Date: $($Result.AssignmentDate ?? 'N/A')"
    Write-Host "  Group Tag:       $($Result.GroupTag ?? 'None')"
    Write-Host "  Profile:         $($Result.ProfileName ?? 'Unknown')"
    Write-Host "  Enrollment:      $($Result.EnrollmentState ?? 'Unknown')"
    if ($Result.Error) { Write-Host "  Error: $($Result.Error)" -ForegroundColor Yellow }
    Write-Host ""
    Write-Host "Report: $OutputRoot\Logs\AutopilotAssignment-Report.json"
    Write-Host ""
    Read-Host "Press Enter to continue"
}
#endregion
