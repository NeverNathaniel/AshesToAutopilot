<#
.SYNOPSIS
    Registers this device with Windows Autopilot using the Andrew Taylor community
    edition of get-windowsautopilotinfocommunity.ps1 with OAuth authentication.

.DESCRIPTION
    Downloads the community script from GitHub (cached locally after first run),
    installs the required microsoft.graph.authentication module, then:

    Interactive mode:
      - Pre-authenticates via Connect-MgGraph device code flow so the sign-in
        code is visible in the toolkit's retro terminal UI before the community
        script runs. The community script then reuses the cached token silently.

    NonInteractive mode (service principal):
      - Requires -TenantId, -AppId, and -AppSecret. Passes them directly to the
        community script which performs its own client-credentials OAuth flow.
      - Without those parameters, exits with ImportStatus = 'NeedsInteractiveAuth'
        so the orchestrator shows the correct remediation message.

    The community script (get-windowsautopilotinfocommunity.ps1) handles:
      - Hardware hash collection (MDM_DevDetail_Ext01 WMI)
      - Device registration via Microsoft Graph Autopilot API
      - Status polling until complete (30-second intervals)
      - GroupTag and AssignedUser assignment

.PARAMETER NonInteractive
    Suppress prompts and emit structured JSON to stdout.
    Requires -TenantId, -AppId, and -AppSecret.

.PARAMETER GroupTag
    Optional Autopilot Group Tag to apply to the device.

.PARAMETER AssignedUser
    Optional UPN to pre-assign in Autopilot.

.PARAMETER TenantId
    Azure AD Tenant ID. Required for NonInteractive service principal auth.

.PARAMETER AppId
    App registration Client ID. Required for NonInteractive service principal auth.

.PARAMETER AppSecret
    App registration Client Secret. Required for NonInteractive service principal auth.

.PARAMETER CertificateThumbprint
    Certificate thumbprint for app-based cert authentication (interactive or NonInteractive).
    Requires -AppId and -TenantId.

.PARAMETER CertificateSubjectName
    Certificate subject name for app-based cert authentication (interactive or NonInteractive).
    Requires -AppId and -TenantId.

.EXAMPLE
    .\Register-AutopilotDeviceCommunity.ps1
    .\Register-AutopilotDeviceCommunity.ps1 -GroupTag "CORP-FLEET" -AssignedUser "jdoe@contoso.com"
    .\Register-AutopilotDeviceCommunity.ps1 -NonInteractive -TenantId "xxx" -AppId "yyy" -AppSecret "zzz"

.NOTES
    Community script: get-windowsautopilotinfocommunity.ps1 by Andrew Taylor
    Source:  https://github.com/andrew-s-taylor/WindowsAutopilotInfo
    Module:  microsoft.graph.authentication (max v2.9.1 per community script)
    Scopes:  Device.ReadWrite.All, DeviceManagementManagedDevices.ReadWrite.All,
             DeviceManagementServiceConfig.ReadWrite.All, DeviceManagementScripts.ReadWrite.All
    Requires: Administrator, internet access, Intune admin permissions
    Output:  C:\PreWipeOutput\Logs\Register-AutopilotDeviceCommunity-Report.json
#>

[CmdletBinding()]
param(
    [switch]$NonInteractive,
    [string]$GroupTag              = '',
    [string]$AssignedUser          = '',
    [string]$TenantId              = '',
    [string]$AppId                 = '',
    [string]$AppSecret             = '',
    [string]$CertificateThumbprint = '',
    [string]$CertificateSubjectName = ''
)

#region --- Init ---
$ScriptName = 'Register-AutopilotDeviceCommunity'
. (Join-Path $PSScriptRoot '..\Common\Initialize-Toolkit.ps1')
$LogFile = "$LogDir\$ScriptName.log"
if (-not (Test-AdminElevation)) { exit 1 }
#endregion

#region --- Result ---
$Result = [PSCustomObject]@{
    Timestamp           = (Get-Date -Format 'o')
    SerialNumber        = $null
    CommunityScriptPath = $null
    GraphModVersion     = $null
    AuthMethod          = $null
    AuthAccount         = $null
    UploadStatus        = $null
    GroupTag            = $GroupTag
    AssignedUser        = $AssignedUser
    CommunityOutput     = $null
    Success             = $false
    Error               = $null
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

#region --- Step 1: Download community script + install module ---
Write-Section 'COMMUNITY SCRIPT + MODULE SETUP' 1 4
Write-Log 'Setting up community script and module...'

$communityScriptUrl  = 'https://raw.githubusercontent.com/andrew-s-taylor/WindowsAutopilotInfo/main/Community%20Version/get-windowsautopilotinfocommunity.ps1'
$communityScriptsDir = "$OutputRoot\Scripts"
$communityScriptPath = "$communityScriptsDir\get-windowsautopilotinfocommunity.ps1"
$Result.CommunityScriptPath = $communityScriptPath

if (-not (Test-Path $communityScriptsDir)) {
    New-Item -ItemType Directory -Path $communityScriptsDir -Force | Out-Null
}

try {
    Write-Log "Downloading community script from GitHub..."
    Write-Info "Downloading get-windowsautopilotinfocommunity.ps1 from GitHub..."
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $communityScriptUrl -OutFile $communityScriptPath -UseBasicParsing -ErrorAction Stop
    Unblock-File -Path $communityScriptPath -ErrorAction SilentlyContinue
    $scriptSize = [Math]::Round((Get-Item $communityScriptPath).Length / 1KB, 1)
    Write-OK  "Community script downloaded ($scriptSize KB) → $communityScriptPath"
    Write-Log "Community script downloaded ($scriptSize KB)"
} catch {
    Write-ErrorLog "Community script download failed: $_"
    $Result.Error = "Community script download failed: $_"
    Write-Err "Download failed: $_"
    if ($NonInteractive) { $Result | ConvertTo-Json -Depth 5 }
    exit 1
}

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $null = Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope AllUsers -ErrorAction SilentlyContinue

    $mgAuth = Get-Module 'Microsoft.Graph.Authentication' -ListAvailable -ErrorAction SilentlyContinue |
        Sort-Object Version -Descending | Select-Object -First 1
    if (-not $mgAuth) {
        Write-Log  'Installing Microsoft.Graph.Authentication...'
        Write-Info 'Installing Microsoft.Graph.Authentication...'
        Install-Module 'Microsoft.Graph.Authentication' -Force -Scope AllUsers -AllowClobber -MaximumVersion '2.9.1' -ErrorAction Stop
        $mgAuth = Get-Module 'Microsoft.Graph.Authentication' -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1
    }
    $Result.GraphModVersion = $mgAuth.Version.ToString()
    Import-Module 'Microsoft.Graph.Authentication' -Force -ErrorAction Stop
    Write-OK  "Microsoft.Graph.Authentication v$($Result.GraphModVersion)"
    Write-Log "Microsoft.Graph.Authentication v$($Result.GraphModVersion) ready"
} catch {
    Write-ErrorLog "Module setup failed: $_"
    $Result.Error = "Module setup failed: $_"
    Write-Err "Module setup failed: $_"
    if ($NonInteractive) { $Result | ConvertTo-Json -Depth 5 }
    exit 1
}
#endregion

#region --- Step 2: Serial number ---
Write-Section 'DEVICE IDENTIFICATION' 2 4
Write-Log 'Querying device serial number...'
try {
    $bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction Stop
    $Result.SerialNumber = $bios.SerialNumber.Trim()
    Write-Log "Serial Number: $($Result.SerialNumber)"
    Write-Info "Serial Number : $($Result.SerialNumber)"
    Write-Info "Computer Name : $env:COMPUTERNAME"
} catch {
    Write-Log "Could not query serial number: $_" -Level 'WARN'
    Write-Wrn "Could not read serial number: $_"
}
#endregion

#region --- Step 3: OAuth pre-authentication (interactive mode only) ---

# In NonInteractive mode without credentials, we cannot authenticate interactively.
if ($NonInteractive -and (-not $AppId) -and (-not $CertificateThumbprint) -and (-not $CertificateSubjectName)) {
    $msg = 'OAuth device code login requires interactive mode. Run this step via [3] Run Single Step to sign in. For automated auth supply -TenantId, -AppId, and -AppSecret (or a certificate).'
    Write-ErrorLog $msg
    $Result.Error        = $msg
    $Result.UploadStatus = 'NeedsInteractiveAuth'
    $Result | ConvertTo-Json -Depth 5
    exit 1
}

# Only pre-authenticate in interactive mode (no credentials supplied).
# In SP/cert mode the community script handles auth itself.
$usePreAuth = (-not $NonInteractive) -and (-not $AppId) -and (-not $CertificateThumbprint) -and (-not $CertificateSubjectName)

if ($usePreAuth) {
    Write-Section 'OAUTH AUTHENTICATION — DEVICE CODE LOGIN' 3 4
    Write-Log 'Starting interactive device code authentication...'

    Write-Host ''
    Write-Host '  ╔══════════════════════════════════════════════════════════════╗' -ForegroundColor Cyan
    Write-Host '  ║   SIGN IN REQUIRED — MICROSOFT GRAPH                         ║' -ForegroundColor Cyan
    Write-Host '  ║                                                               ║' -ForegroundColor Cyan
    Write-Host '  ║   A code will appear on the next line.                        ║' -ForegroundColor Cyan
    Write-Host '  ║   Open a browser on any device and visit:                    ║' -ForegroundColor Cyan
    Write-Host '  ║     https://microsoft.com/devicelogin                        ║' -ForegroundColor Cyan
    Write-Host '  ║   Sign in with an account that has Intune admin access.      ║' -ForegroundColor Cyan
    Write-Host '  ║                                                               ║' -ForegroundColor Cyan
    Write-Host '  ║   Required scopes:                                            ║' -ForegroundColor Cyan
    Write-Host '  ║     Device.ReadWrite.All                                      ║' -ForegroundColor Cyan
    Write-Host '  ║     DeviceManagementManagedDevices.ReadWrite.All              ║' -ForegroundColor Cyan
    Write-Host '  ║     DeviceManagementServiceConfig.ReadWrite.All               ║' -ForegroundColor Cyan
    Write-Host '  ╚══════════════════════════════════════════════════════════════╝' -ForegroundColor Cyan
    Write-Host ''

    # Disable WAM to match the community script's own behaviour (device code works in console)
    try { Set-MgGraphOption -DisableLoginByWAM $true -ErrorAction SilentlyContinue } catch { }

    try {
        $mgParams = @{
            Scopes                  = @(
                'Device.ReadWrite.All',
                'DeviceManagementManagedDevices.ReadWrite.All',
                'DeviceManagementServiceConfig.ReadWrite.All',
                'DeviceManagementScripts.ReadWrite.All'
            )
            UseDeviceAuthentication = $true
            ErrorAction             = 'Stop'
        }
        if ($TenantId) { $mgParams.TenantId = $TenantId }

        Connect-MgGraph @mgParams

        Write-Host '' # blank line after device-code output
        $ctx = Get-MgContext -ErrorAction SilentlyContinue
        if ($ctx) {
            $Result.AuthMethod  = 'DeviceCode'
            $Result.AuthAccount = if ($ctx.Account) { $ctx.Account } else { $ctx.ClientId }
            Write-Log "Device code auth succeeded: $($Result.AuthAccount)"
            Write-OK  "Authenticated: $($Result.AuthAccount)"
        }
    } catch {
        Write-ErrorLog "Device code authentication failed: $_"
        $Result.Error = "Authentication failed: $_"
        Write-Err "Authentication failed: $_"
        $Result | ConvertTo-Json -Depth 5
        exit 1
    }
} elseif ($AppId) {
    $Result.AuthMethod = 'ServicePrincipal'
    Write-Log "Using service principal auth (AppId: $AppId, TenantId: $TenantId) — community script will authenticate"
} elseif ($CertificateThumbprint -or $CertificateSubjectName) {
    $Result.AuthMethod = 'Certificate'
    Write-Log "Using certificate auth — community script will authenticate"
}
#endregion

#region --- Step 4: Run community script ---
Write-Section 'AUTOPILOT REGISTRATION — COMMUNITY SCRIPT' 4 4
Write-Log "Running get-windowsautopilotinfocommunity.ps1 with -Online..."

$csvPath = "$OutputRoot\AutopilotHash_Community.csv"

# Build the argument list for the community script
$communityArgs = @('-Online', '-OutputFile', $csvPath)
if ($GroupTag)               { $communityArgs += '-GroupTag';               $communityArgs += $GroupTag }
if ($AssignedUser)           { $communityArgs += '-AssignedUser';           $communityArgs += $AssignedUser }
if ($TenantId)               { $communityArgs += '-TenantId';               $communityArgs += $TenantId }
if ($AppId)                  { $communityArgs += '-AppId';                  $communityArgs += $AppId }
if ($AppSecret)              { $communityArgs += '-AppSecret';              $communityArgs += $AppSecret }
if ($CertificateThumbprint)  { $communityArgs += '-CertificateThumbprint';  $communityArgs += $CertificateThumbprint }
if ($CertificateSubjectName) { $communityArgs += '-CertificateSubjectName'; $communityArgs += $CertificateSubjectName }

if (-not $NonInteractive) {
    Write-Info "Output CSV   : $csvPath"
    if ($GroupTag)    { Write-Info "GroupTag     : $GroupTag" }
    if ($AssignedUser){ Write-Info "AssignedUser : $AssignedUser" }
    Write-Host ''
    Write-Host "  $('─' * 64)" -ForegroundColor DarkGray
    Write-Host '  Community script output:' -ForegroundColor DarkGray
    Write-Host "  $('─' * 64)" -ForegroundColor DarkGray
    Write-Host ''
}

$communityExitCode = 0
$communityOutput   = $null

try {
    if ($NonInteractive) {
        # Capture all output so we can build our JSON result
        $communityOutput   = & $communityScriptPath @communityArgs 2>&1 | Out-String
        $communityExitCode = if ($null -ne $LASTEXITCODE) { $LASTEXITCODE } else { 0 }
        Write-Log "Community script exit code: $communityExitCode"
        Write-Log "Community script output:`n$communityOutput"

        # Trim output for JSON (avoid huge strings)
        $Result.CommunityOutput = $communityOutput.Trim() -replace '(?m)^\s+', '  ' | Out-String
        if ($Result.CommunityOutput.Length -gt 2000) {
            $Result.CommunityOutput = $Result.CommunityOutput.Substring(0, 2000) + '...[truncated]'
        }
    } else {
        # Let the community script write to the console directly — the user sees live output
        & $communityScriptPath @communityArgs
        $communityExitCode = if ($null -ne $LASTEXITCODE) { $LASTEXITCODE } else { 0 }
        Write-Log "Community script exit code: $communityExitCode"
    }
} catch {
    Write-ErrorLog "Community script execution failed: $_"
    $Result.Error        = "Community script failed: $_"
    $Result.UploadStatus = 'ExecutionFailed'
    if ($NonInteractive) { $Result | ConvertTo-Json -Depth 5 }
    exit 1
}

if (-not $NonInteractive) {
    Write-Host ''
    Write-Host "  $('─' * 64)" -ForegroundColor DarkGray
    Write-Host ''
}
#endregion

#region --- Parse results ---
Write-Log 'Parsing community script results...'

# Check CSV output to confirm hash was collected
$hashCollected = $false
if (Test-Path $csvPath) {
    try {
        $csvData = Import-Csv $csvPath -ErrorAction Stop
        $hashEntry = $csvData | Select-Object -First 1
        $hashValue = $hashEntry.'Hardware Hash'
        if ($hashValue -and $hashValue.Length -gt 0) {
            $hashCollected = $true
            Write-Log "Hardware hash confirmed in CSV ($($hashValue.Length) chars)"
        }
        # Use serial from CSV if we didn't get it earlier
        if (-not $Result.SerialNumber -and $hashEntry.'Device Serial Number') {
            $Result.SerialNumber = $hashEntry.'Device Serial Number'
        }
    } catch {
        Write-Log "Could not parse CSV at $csvPath : $_" -Level 'WARN'
    }
}

# Determine success and upload status from exit code and output
if ($communityExitCode -eq 0) {
    $Result.Success = $true

    # Try to extract auth account from community script output (NonInteractive)
    if ($NonInteractive -and $communityOutput -and -not $Result.AuthAccount) {
        if ($communityOutput -match 'Connected to Intune tenant (\S+)') {
            $Result.AuthAccount = $Matches[1]
        }
    }

    if ($hashCollected) {
        $Result.UploadStatus = 'Registered'
        Write-OK  'Device successfully registered with Autopilot'
        Write-Log 'Registration: success (exit code 0, hash confirmed in CSV)'
    } else {
        $Result.UploadStatus = 'Registered'
        Write-OK  'Community script completed successfully (exit code 0)'
        Write-Log 'Registration: success (exit code 0, CSV not found — may have been cleaned up)'
    }
} else {
    $Result.Success      = $false
    $Result.UploadStatus = 'Failed'

    # Try to extract error from community script output
    if ($communityOutput) {
        $errorLines = ($communityOutput -split "`n" | Where-Object { $_ -match 'error|fail|exception' -and $_ -notmatch '^#' }) -join ' '
        if ($errorLines) {
            $Result.Error = "Community script error (exit $communityExitCode): " + $errorLines.Trim().Substring(0, [Math]::Min(200, $errorLines.Trim().Length))
        }
    }
    if (-not $Result.Error) {
        $Result.Error = "Community script exited with code $communityExitCode"
    }

    Write-Err  "Registration failed (exit code $communityExitCode)"
    Write-Log  "Registration: failed — exit code $communityExitCode" -Level 'ERROR'
}
#endregion

#region --- Disconnect + Output ---
try { Disconnect-MgGraph -ErrorAction SilentlyContinue } catch { }

$jsonOut = $Result | ConvertTo-Json -Depth 5
$jsonOut | Out-File "$LogDir\$ScriptName-Report.json" -Force -Encoding UTF8
Write-Log "Result JSON: $LogDir\$ScriptName-Report.json"

if ($NonInteractive) {
    $jsonOut
} else {
    Write-Host ''
    Write-Host "  $('═' * 64)" -ForegroundColor Cyan
    Write-Host '  AUTOPILOT REGISTRATION (OAUTH · COMMUNITY SCRIPT) — RESULT' -ForegroundColor White
    Write-Host "  $('═' * 64)" -ForegroundColor Cyan
    $fields = [ordered]@{
        'Serial Number'  = if ($Result.SerialNumber)   { $Result.SerialNumber }   else { '(unknown)' }
        'Auth Method'    = if ($Result.AuthMethod)     { $Result.AuthMethod }     else { '(community script)' }
        'Auth Account'   = if ($Result.AuthAccount)    { $Result.AuthAccount }    else { '(see output above)' }
        'Upload Status'  = if ($Result.UploadStatus)   { $Result.UploadStatus }   else { '(unknown)' }
        'Graph Mod Ver'  = if ($Result.GraphModVersion){ "v$($Result.GraphModVersion)" } else { '(unknown)' }
        'Community Script' = $communityScriptPath
    }
    if ($GroupTag)    { $fields['Group Tag']     = $GroupTag }
    if ($AssignedUser){ $fields['Assigned User'] = $AssignedUser }
    foreach ($k in $fields.Keys) {
        Write-Host ("  {0,-20}: {1}" -f $k, $fields[$k]) -ForegroundColor Gray
    }
    Write-Host ''
    $col = if ($Result.Success) { 'Green' } else { 'Red' }
    Write-Host "  Success : $($Result.Success)" -ForegroundColor $col
    if ($Result.Error) { Write-Host "  Error   : $($Result.Error)" -ForegroundColor Yellow }
    Write-Host "  $('═' * 64)" -ForegroundColor Cyan
    Write-Host ''
    Write-Host "  Report : $LogDir\$ScriptName-Report.json" -ForegroundColor DarkCyan
    if (Test-Path $csvPath) {
        Write-Host "  CSV    : $csvPath" -ForegroundColor DarkCyan
    }
    Write-Host ''
}
#endregion

exit $(if ($Result.Success) { 0 } else { 1 })
