<#
.SYNOPSIS
    Registers device with Windows Autopilot using OAuth and the community module.

.DESCRIPTION
    Uses the WindowsAutopilotIntuneCommunity module and Microsoft.Graph.Authentication
    to register a device with full OAuth support.

    Flow:
      1. Installs WindowsAutopilotIntuneCommunity + Microsoft.Graph.Authentication
      2. Collects hardware hash via MDM WMI class (falls back to Get-WindowsAutopilotInfo)
      3. Authenticates via Connect-MgGraph: device code flow (interactive) or
         client credentials (NonInteractive with -TenantId/-AppId/-AppSecret)
      4. Registers device using Add-AutopilotImportedDevice from the community module
         (falls back to direct Invoke-MgGraphRequest if module function unavailable)
      5. Polls Get-AutopilotImportedDevice until complete, error, or 5-minute timeout

.PARAMETER NonInteractive
    Suppress prompts and emit structured JSON to stdout. Requires -TenantId, -AppId,
    and -AppSecret for service principal authentication. Without those, exits with
    ImportStatus = 'NeedsInteractiveAuth' so the orchestrator can surface the correct
    remediation message.

.PARAMETER GroupTag
    Optional Autopilot Group Tag to assign to the device.

.PARAMETER AssignedUser
    Optional UPN of the user to pre-assign in Autopilot.

.PARAMETER TenantId
    Azure AD Tenant ID. Optional for interactive (scopes auth to tenant);
    required for NonInteractive service principal auth.

.PARAMETER AppId
    App registration Client ID. Required for NonInteractive service principal auth.

.PARAMETER AppSecret
    App registration Client Secret. Required for NonInteractive service principal auth.

.EXAMPLE
    .\Register-AutopilotDeviceCommunity.ps1
    .\Register-AutopilotDeviceCommunity.ps1 -GroupTag "CORP-WIPE" -AssignedUser "jdoe@contoso.com"
    .\Register-AutopilotDeviceCommunity.ps1 -NonInteractive -TenantId "xxx" -AppId "yyy" -AppSecret "zzz"

.NOTES
    Modules:  WindowsAutopilotIntuneCommunity (Michael Niehaus, PSGallery)
              Microsoft.Graph.Authentication (Microsoft, PSGallery)
    Auth:     Connect-MgGraph device code (interactive) or ClientSecretCredential (SP)
    Scope:    DeviceManagementServiceConfig.ReadWrite.All
    Requires: Administrator, internet access, Intune admin or delegated Autopilot permissions
    Output:   C:\PreWipeOutput\Logs\Register-AutopilotDeviceCommunity-Report.json
#>

[CmdletBinding()]
param(
    [switch]$NonInteractive,
    [string]$GroupTag     = '',
    [string]$AssignedUser = '',
    [string]$TenantId     = '',
    [string]$AppId        = '',
    [string]$AppSecret    = ''
)

#region --- Init ---
$ScriptName = 'Register-AutopilotDeviceCommunity'
. (Join-Path $PSScriptRoot '..\Common\Initialize-Toolkit.ps1')
$LogFile = "$LogDir\$ScriptName.log"
if (-not (Test-AdminElevation)) { exit 1 }
#endregion

#region --- Result ---
$Result = [PSCustomObject]@{
    Timestamp            = (Get-Date -Format 'o')
    SerialNumber         = $null
    HardwareHashLength   = 0
    HashSource           = $null
    CommunityModVersion  = $null
    GraphModVersion      = $null
    AuthMethod           = $null
    AuthAccount          = $null
    ImportId             = $null
    ImportStatus         = $null
    ImportErrorCode      = $null
    ImportErrorName      = $null
    DeviceRegistrationId = $null
    GroupTag             = $GroupTag
    AssignedUser         = $AssignedUser
    Success              = $false
    Error                = $null
}
#endregion

#region --- UI Helpers ---
function Write-Section {
    param([string]$Title, [int]$Num, [int]$Total)
    if ($NonInteractive) { return }
    Write-Host ''
    Write-Host "  $('─' * 64)" -ForegroundColor DarkCyan
    Write-Host "  [ $Num / $Total ]  $Title" -ForegroundColor Cyan
    Write-Host "  $('─' * 64)" -ForegroundColor DarkCyan
}
function Write-OK   { param([string]$m) if (-not $NonInteractive) { Write-Host "  [OK] $m" -ForegroundColor Green  } }
function Write-Info { param([string]$m) if (-not $NonInteractive) { Write-Host "  $m"      -ForegroundColor Gray   } }
function Write-Wrn  { param([string]$m) if (-not $NonInteractive) { Write-Host "  [!!] $m" -ForegroundColor Yellow } }
function Write-Err  { param([string]$m) if (-not $NonInteractive) { Write-Host "  [XX] $m" -ForegroundColor Red   } }
#endregion

#region --- Step 1: Module Setup ---
Write-Section 'MODULE SETUP' 1 5
Write-Log 'Verifying and installing required modules...'

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $null = Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope AllUsers -ErrorAction SilentlyContinue

    # Microsoft.Graph.Authentication — provides Connect-MgGraph and Invoke-MgGraphRequest
    $mgAuth = Get-Module 'Microsoft.Graph.Authentication' -ListAvailable -ErrorAction SilentlyContinue |
        Sort-Object Version -Descending | Select-Object -First 1
    if (-not $mgAuth) {
        Write-Log  'Installing Microsoft.Graph.Authentication...'
        Write-Info 'Installing Microsoft.Graph.Authentication...'
        Install-Module 'Microsoft.Graph.Authentication' -Force -Scope AllUsers -AllowClobber -ErrorAction Stop
    } else {
        Write-Log "Microsoft.Graph.Authentication found: v$($mgAuth.Version) — checking for updates..."
        Update-Module 'Microsoft.Graph.Authentication' -Force -ErrorAction SilentlyContinue
    }
    $mgAuth = Get-Module 'Microsoft.Graph.Authentication' -ListAvailable |
        Sort-Object Version -Descending | Select-Object -First 1
    $Result.GraphModVersion = $mgAuth.Version.ToString()
    Import-Module 'Microsoft.Graph.Authentication' -Force -ErrorAction Stop
    Write-OK  "Microsoft.Graph.Authentication v$($Result.GraphModVersion)"
    Write-Log "Microsoft.Graph.Authentication v$($Result.GraphModVersion) ready"

    # WindowsAutopilotIntuneCommunity — provides Add/Get-AutopilotImportedDevice
    $wpic = Get-Module 'WindowsAutopilotIntuneCommunity' -ListAvailable -ErrorAction SilentlyContinue |
        Sort-Object Version -Descending | Select-Object -First 1
    if (-not $wpic) {
        Write-Log  'Installing WindowsAutopilotIntuneCommunity...'
        Write-Info 'Installing WindowsAutopilotIntuneCommunity...'
        Install-Module 'WindowsAutopilotIntuneCommunity' -Force -Scope AllUsers -AllowClobber -ErrorAction Stop
        $wpic = Get-Module 'WindowsAutopilotIntuneCommunity' -ListAvailable |
            Sort-Object Version -Descending | Select-Object -First 1
    } else {
        Write-Log "WindowsAutopilotIntuneCommunity found: v$($wpic.Version) — checking for updates..."
        Update-Module 'WindowsAutopilotIntuneCommunity' -Force -ErrorAction SilentlyContinue
        $wpic = Get-Module 'WindowsAutopilotIntuneCommunity' -ListAvailable |
            Sort-Object Version -Descending | Select-Object -First 1
    }
    if ($wpic) {
        $Result.CommunityModVersion = $wpic.Version.ToString()
        Import-Module 'WindowsAutopilotIntuneCommunity' -Force -ErrorAction SilentlyContinue
        Write-OK  "WindowsAutopilotIntuneCommunity v$($Result.CommunityModVersion)"
        Write-Log "WindowsAutopilotIntuneCommunity v$($Result.CommunityModVersion) ready"
    } else {
        Write-Wrn 'WindowsAutopilotIntuneCommunity not available — will use Invoke-MgGraphRequest directly'
        Write-Log 'WindowsAutopilotIntuneCommunity unavailable — falling back to direct Graph calls' -Level 'WARN'
    }

} catch {
    Write-ErrorLog "Module setup failed: $_"
    $Result.Error = "Module setup failed: $_"
    Write-Err "Module setup failed: $_"
    if ($NonInteractive) { $Result | ConvertTo-Json -Depth 5 }
    exit 1
}
#endregion

#region --- Step 2: Hardware Hash Collection ---
Write-Section 'HARDWARE HASH COLLECTION' 2 5
Write-Log 'Collecting hardware hash...'

$hardwareHash = $null

try {
    $bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction Stop
    $Result.SerialNumber = $bios.SerialNumber.Trim()
    Write-Log "Serial Number: $($Result.SerialNumber)"
    Write-Info "Serial Number : $($Result.SerialNumber)"

    # Primary: MDM WMI DMMap class — works on any Autopilot-capable device, no module needed
    try {
        $devDetail = Get-CimInstance -Namespace 'root/cimv2/mdm/dmmap' `
            -ClassName 'MDM_DevDetail_Ext01' `
            -Filter "InstanceID='Ext' AND ParentID='./DevDetail'" `
            -ErrorAction Stop
        $hardwareHash = $devDetail.DeviceHardwareData
        if (-not $hardwareHash) { throw 'MDM_DevDetail_Ext01.DeviceHardwareData is empty' }
        $Result.HardwareHashLength = $hardwareHash.Length
        $Result.HashSource         = 'MDM_WMI'
        Write-OK  "Hardware hash collected via WMI ($($hardwareHash.Length) chars)"
        Write-Log "Hardware hash: MDM WMI — $($hardwareHash.Length) chars"
    } catch {
        # Fallback: Get-WindowsAutopilotInfo community module (hash-only, no upload)
        Write-Log "MDM WMI unavailable ($($_.Exception.Message)) — falling back to Get-WindowsAutopilotInfo" -Level 'WARN'
        Write-Wrn 'WMI hash class unavailable — collecting via Get-WindowsAutopilotInfo...'

        $gwai = Get-Module 'Get-WindowsAutopilotInfo' -ListAvailable -ErrorAction SilentlyContinue |
            Sort-Object Version -Descending | Select-Object -First 1
        if (-not $gwai) {
            Write-Info 'Installing Get-WindowsAutopilotInfo...'
            Install-Module 'Get-WindowsAutopilotInfo' -Force -Scope AllUsers -AllowClobber -ErrorAction Stop
        } else {
            Update-Module 'Get-WindowsAutopilotInfo' -Force -ErrorAction SilentlyContinue
        }
        Import-Module 'Get-WindowsAutopilotInfo' -Force -ErrorAction Stop

        $csvPath = "$OutputRoot\AutopilotHash_Community.csv"
        Get-WindowsAutopilotInfo -OutputFile $csvPath -ErrorAction Stop
        $csvData = Import-Csv $csvPath -ErrorAction Stop
        $hashEntry = $csvData | Select-Object -First 1
        $hardwareHash = $hashEntry.'Hardware Hash'
        if (-not $hardwareHash) { throw 'Get-WindowsAutopilotInfo returned empty hardware hash' }
        $Result.HardwareHashLength = $hardwareHash.Length
        $Result.HashSource         = 'Get-WindowsAutopilotInfo'
        Write-OK  "Hardware hash via community module ($($hardwareHash.Length) chars)"
        Write-Log "Hardware hash: Get-WindowsAutopilotInfo — $($hardwareHash.Length) chars"
    }

} catch {
    Write-ErrorLog "Hardware hash collection failed: $_"
    $Result.Error = "Hardware hash collection failed: $_"
    Write-Err "Failed to collect hardware hash: $_"
    if ($NonInteractive) { $Result | ConvertTo-Json -Depth 5 }
    exit 1
}
#endregion

#region --- Step 3: OAuth Authentication ---
Write-Section 'OAUTH AUTHENTICATION — MICROSOFT GRAPH' 3 5
Write-Log 'Starting Microsoft Graph authentication...'

# In NonInteractive mode without service principal credentials, we cannot do device code auth
if ($NonInteractive -and (-not ($AppId -and $AppSecret -and $TenantId))) {
    $msg = 'OAuth device code login requires interactive mode. Run this step via [3] Run Single Step. For automated auth, supply -TenantId, -AppId, and -AppSecret.'
    Write-ErrorLog $msg
    $Result.Error        = $msg
    $Result.ImportStatus = 'NeedsInteractiveAuth'
    $Result | ConvertTo-Json -Depth 5
    exit 1
}

try {
    if ($AppId -and $AppSecret -and $TenantId) {
        # Service principal (client credentials) — usable in NonInteractive mode
        Write-Log "Authenticating via service principal (TenantId: $TenantId, AppId: $AppId)..."
        Write-Info 'Authenticating via service principal...'
        $secSecret  = ConvertTo-SecureString $AppSecret -AsPlainText -Force
        $credential = [PSCredential]::new($AppId, $secSecret)
        Connect-MgGraph -TenantId $TenantId -ClientSecretCredential $credential -ErrorAction Stop
        $Result.AuthMethod = 'ServicePrincipal'
        Write-Log 'Service principal auth succeeded'
        Write-OK  'Authenticated via service principal'
    } else {
        # Interactive device code flow
        Write-Log 'Starting device code authentication flow...'
        if (-not $NonInteractive) {
            Write-Host ''
            Write-Host '  ╔══════════════════════════════════════════════════════════════╗' -ForegroundColor Cyan
            Write-Host '  ║   SIGN IN REQUIRED — MICROSOFT GRAPH                         ║' -ForegroundColor Cyan
            Write-Host '  ║                                                               ║' -ForegroundColor Cyan
            Write-Host '  ║   Required permission:                                        ║' -ForegroundColor Cyan
            Write-Host '  ║     DeviceManagementServiceConfig.ReadWrite.All               ║' -ForegroundColor Cyan
            Write-Host '  ║                                                               ║' -ForegroundColor Cyan
            Write-Host '  ║   A code will appear on the next line. Open any browser:     ║' -ForegroundColor Cyan
            Write-Host '  ║     https://microsoft.com/devicelogin                        ║' -ForegroundColor Cyan
            Write-Host '  ║   Enter the code and sign in with an Intune admin account.   ║' -ForegroundColor Cyan
            Write-Host '  ╚══════════════════════════════════════════════════════════════╝' -ForegroundColor Cyan
            Write-Host ''
        }

        $mgParams = @{
            Scopes                  = @('DeviceManagementServiceConfig.ReadWrite.All')
            UseDeviceAuthentication = $true
            ErrorAction             = 'Stop'
        }
        if ($TenantId) { $mgParams.TenantId = $TenantId }
        if ($AppId)    { $mgParams.ClientId  = $AppId    }

        Connect-MgGraph @mgParams
        Write-Host '' # Blank line after Connect-MgGraph output
        $Result.AuthMethod = 'DeviceCode'
        Write-Log 'Device code authentication succeeded'
    }

    $ctx = Get-MgContext -ErrorAction SilentlyContinue
    if ($ctx) {
        $Result.AuthAccount = if ($ctx.Account) { $ctx.Account } elseif ($ctx.AppName) { $ctx.AppName } else { $ctx.ClientId }
        Write-Log "Authenticated as: $($Result.AuthAccount)"
        Write-OK  "Authenticated: $($Result.AuthAccount)"
    }

} catch {
    Write-ErrorLog "Authentication failed: $_"
    $Result.Error = "Authentication failed: $_"
    Write-Err "Authentication failed: $_"
    if ($NonInteractive) { $Result | ConvertTo-Json -Depth 5 }
    exit 1
}
#endregion

#region --- Step 4: Device Registration ---
Write-Section 'DEVICE REGISTRATION' 4 5
Write-Log 'Submitting device to Autopilot...'
Write-Info "GroupTag     : $(if ($GroupTag)     { $GroupTag }     else { '(none)' })"
Write-Info "AssignedUser : $(if ($AssignedUser) { $AssignedUser } else { '(none)' })"
Write-Info 'Submitting hardware hash to Microsoft Intune...'

$importRecord = $null

try {
    # Use community module function if available; otherwise call Graph API directly
    $hasCommunityAdd = $null -ne (Get-Command 'Add-AutopilotImportedDevice' -ErrorAction SilentlyContinue)

    if ($hasCommunityAdd) {
        Write-Log 'Using WindowsAutopilotIntuneCommunity Add-AutopilotImportedDevice'
        $importArgs = @{
            serialNumber       = $Result.SerialNumber
            hardwareIdentifier = $hardwareHash
        }
        if ($GroupTag)    { $importArgs.groupTag    = $GroupTag }
        if ($AssignedUser){ $importArgs.assignedUser = $AssignedUser }
        $importRecord = Add-AutopilotImportedDevice @importArgs -ErrorAction Stop
    } else {
        Write-Log 'Community function not found — using Invoke-MgGraphRequest'
        Write-Wrn 'Using Invoke-MgGraphRequest (community module function unavailable)'
        $body = @{
            serialNumber       = $Result.SerialNumber
            hardwareIdentifier = $hardwareHash
        }
        if ($GroupTag)    { $body.groupTag                  = $GroupTag }
        if ($AssignedUser){ $body.assignedUserPrincipalName = $AssignedUser }
        $importRecord = Invoke-MgGraphRequest -Method POST `
            -Uri 'https://graph.microsoft.com/v1.0/deviceManagement/importedWindowsAutopilotDeviceIdentities' `
            -Body ($body | ConvertTo-Json -Depth 5) `
            -ContentType 'application/json' `
            -ErrorAction Stop
    }

    if (-not $importRecord -or -not $importRecord.id) {
        throw 'Registration returned no import record ID'
    }

    $Result.ImportId = $importRecord.id
    Write-OK  "Submitted — Import ID: $($Result.ImportId)"
    Write-Log "Import record created: $($Result.ImportId)"

} catch {
    Write-ErrorLog "Device registration failed: $_"
    $Result.Error        = "Device registration failed: $_"
    $Result.ImportStatus = 'SubmissionFailed'
    Write-Err "Submission failed: $_"
    if ($NonInteractive) { $Result | ConvertTo-Json -Depth 5 }
    exit 1
}
#endregion

#region --- Step 5: Poll Import Status ---
Write-Section 'POLLING IMPORT STATUS' 5 5
Write-Log "Polling status for import ID: $($Result.ImportId)..."
Write-Info "Import ID : $($Result.ImportId)"
Write-Info 'Waiting for Intune to process the import...'

$maxAttempts = 20   # 20 × 15 s = 5 minutes
$intervalSec = 15
$attempt     = 0
$finalStatus = 'unknown'
$statusRecord = $null
$importState  = $null

$hasCommunityPoll = $null -ne (Get-Command 'Get-AutopilotImportedDevice' -ErrorAction SilentlyContinue)

while ($attempt -lt $maxAttempts) {
    $attempt++
    try {
        if ($hasCommunityPoll) {
            $statusRecord = Get-AutopilotImportedDevice -id $Result.ImportId -ErrorAction Stop
        } else {
            $statusRecord = Invoke-MgGraphRequest -Method GET `
                -Uri "https://graph.microsoft.com/v1.0/deviceManagement/importedWindowsAutopilotDeviceIdentities/$($Result.ImportId)" `
                -ErrorAction Stop
        }

        try {
            $importState  = $statusRecord.state
            $finalStatus  = if ($importState -and $importState.deviceImportStatus) { $importState.deviceImportStatus } else { 'unknown' }
        } catch { $finalStatus = 'unknown' }

        Write-Log "Poll $attempt/$maxAttempts — status: $finalStatus"
        Write-Info "  Attempt $attempt/$maxAttempts  [ $finalStatus ]"

        if ($finalStatus -in @('complete', 'error', 'partialMatch')) { break }

    } catch {
        Write-Log "Poll attempt $attempt failed: $_" -Level 'WARN'
        Write-Wrn "Poll $attempt failed: $_"
    }

    if ($attempt -lt $maxAttempts) {
        if (-not $NonInteractive) {
            Write-Host "  Retrying in $intervalSec s..." -ForegroundColor DarkGray
        }
        Start-Sleep -Seconds $intervalSec
    }
}

$Result.ImportStatus = $finalStatus

switch ($finalStatus) {
    'complete' {
        $Result.Success = $true
        try { $Result.DeviceRegistrationId = $importState.deviceRegistrationId } catch { }
        Write-OK  "Registration complete!  Device Reg ID: $($Result.DeviceRegistrationId)"
        Write-Log "Registration complete. Device Reg ID: $($Result.DeviceRegistrationId)"
    }
    'partialMatch' {
        # Device already exists in Autopilot — not a failure
        $Result.Success = $true
        try { $Result.DeviceRegistrationId = $importState.deviceRegistrationId } catch { }
        Write-Wrn 'Partial match — device already registered in Autopilot (existing record).'
        Write-Log 'Partial match — device may already be registered.'
    }
    'error' {
        try {
            $Result.ImportErrorCode = $importState.deviceErrorCode
            $Result.ImportErrorName = $importState.deviceErrorName
        } catch { }
        $Result.Error   = "Import error — Code: $($Result.ImportErrorCode), Name: $($Result.ImportErrorName)"
        $Result.Success = $false
        Write-Err  "Import error — Code: $($Result.ImportErrorCode)  Name: $($Result.ImportErrorName)"
        Write-Log  "Import error. Code: $($Result.ImportErrorCode), Name: $($Result.ImportErrorName)" -Level 'ERROR'
    }
    default {
        $Result.Error   = "Import timed out after $($maxAttempts * $intervalSec)s. Last status: $finalStatus — may still complete in Intune."
        $Result.Success = $false
        Write-Wrn "Timed out after $($maxAttempts * $intervalSec)s. Last status: $finalStatus"
        Write-Wrn 'The import may still complete. Check Intune > Devices > Enrollment > Windows Autopilot.'
        Write-Log "Import timed out. Last status: $finalStatus" -Level 'WARN'
    }
}
#endregion

#region --- Disconnect + Output ---
try { Disconnect-MgGraph -ErrorAction SilentlyContinue } catch { }

$jsonOut = $Result | ConvertTo-Json -Depth 5
$jsonOut | Out-File "$LogDir\$ScriptName-Report.json" -Force -Encoding UTF8
Write-Log "Result JSON saved: $LogDir\$ScriptName-Report.json"

if ($NonInteractive) {
    $jsonOut
} else {
    Write-Host ''
    Write-Host "  $('═' * 64)" -ForegroundColor Cyan
    Write-Host '  AUTOPILOT REGISTRATION (OAUTH / COMMUNITY MODULE) — RESULT' -ForegroundColor White
    Write-Host "  $('═' * 64)" -ForegroundColor Cyan
    $fields = [ordered]@{
        'Serial Number'  = $Result.SerialNumber
        'Hash Source'    = $Result.HashSource
        'Hash Length'    = "$($Result.HardwareHashLength) chars"
        'Auth Method'    = $Result.AuthMethod
        'Auth Account'   = $Result.AuthAccount
        'Community Mod'  = if ($Result.CommunityModVersion) { "v$($Result.CommunityModVersion)" } else { 'Not used (Graph direct)' }
        'Graph Auth Mod' = "v$($Result.GraphModVersion)"
        'Import ID'      = if ($Result.ImportId) { $Result.ImportId } else { '(none)' }
        'Import Status'  = if ($Result.ImportStatus) { $Result.ImportStatus } else { '(none)' }
        'Device Reg ID'  = if ($Result.DeviceRegistrationId) { $Result.DeviceRegistrationId } else { '(pending)' }
    }
    if ($GroupTag)    { $fields['Group Tag']     = $GroupTag }
    if ($AssignedUser){ $fields['Assigned User'] = $AssignedUser }
    foreach ($k in $fields.Keys) {
        Write-Host ("  {0,-18}: {1}" -f $k, $fields[$k]) -ForegroundColor Gray
    }
    Write-Host ''
    $successColor = if ($Result.Success) { 'Green' } else { 'Red' }
    Write-Host "  Success : $($Result.Success)" -ForegroundColor $successColor
    if ($Result.Error) { Write-Host "  Error   : $($Result.Error)" -ForegroundColor Yellow }
    Write-Host "  $('═' * 64)" -ForegroundColor Cyan
    Write-Host ''
    Write-Host "  Report saved: $LogDir\$ScriptName-Report.json" -ForegroundColor DarkCyan
    Write-Host ''
}
#endregion

exit $(if ($Result.Success) { 0 } else { 1 })
