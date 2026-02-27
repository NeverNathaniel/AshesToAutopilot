<#
.SYNOPSIS
    Exports all saved WiFi profiles with passwords for restoration on the new device.

.DESCRIPTION
    Enumerates all stored WiFi profiles via netsh, exports each as XML with
    cleartext keys (where available), and builds a summary report.
    Enterprise (802.1x) profiles are flagged as requiring re-authentication.

.PARAMETER NonInteractive
    Suppress all prompts. Output structured JSON to stdout. Exit cleanly.

.EXAMPLE
    .\Backup-WiFiProfiles.ps1
    .\Backup-WiFiProfiles.ps1 -NonInteractive

.NOTES
    Source repos used:
    - garytown-master/hardware/HP/SureRecover/CI/WiFiSetup-CI-DetectionScript.ps1
      (netsh wlan show profile name=$SSID key=clear pattern)

    Requires: Administrator (for key=clear export)
    Output:   C:\PreWipeOutput\WiFiProfiles\ (XML files)
              C:\PreWipeOutput\Logs\WiFiProfiles-Report.json
#>

[CmdletBinding()]
param(
    [switch]$NonInteractive
)

#region --- Init ---
$ScriptName = 'Backup-WiFiProfiles'
$OutputRoot = 'C:\PreWipeOutput'
$LogDir     = "$OutputRoot\Logs"
$LogFile    = "$LogDir\$ScriptName.log"
$ErrorLog   = "$OutputRoot\errors.log"
$WiFiDir    = "$OutputRoot\WiFiProfiles"

if (-not (Test-Path $OutputRoot)) { New-Item -Path $OutputRoot -ItemType Directory -Force | Out-Null }
if (-not (Test-Path $LogDir))     { New-Item -Path $LogDir     -ItemType Directory -Force | Out-Null }
if (-not (Test-Path $WiFiDir))    { New-Item -Path $WiFiDir    -ItemType Directory -Force | Out-Null }

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

#region --- Check WLAN service ---
$wlanService = Get-Service -Name 'WlanSvc' -ErrorAction SilentlyContinue
if (-not $wlanService -or $wlanService.Status -ne 'Running') {
    Write-Log "WLAN AutoConfig service not running or not present. No WiFi profiles to export." 'WARN'
    $Result = [PSCustomObject]@{
        Timestamp    = (Get-Date -Format 'o')
        WlanService  = if ($wlanService) { $wlanService.Status.ToString() } else { 'NotInstalled' }
        ProfileCount = 0
        Profiles     = @()
    }
    $Result | ConvertTo-Json -Depth 5 | Out-File "$LogDir\WiFiProfiles-Report.json" -Force
    if ($NonInteractive) { $Result | ConvertTo-Json -Depth 5 }
    else {
        Write-Host "No WLAN service - this may be a desktop without WiFi." -ForegroundColor Yellow
    }
    exit 0
}
#endregion

#region --- Enumerate Profiles ---
Write-Log "Enumerating saved WiFi profiles..."
$profileOutput = netsh wlan show profiles 2>&1
$profileNames = @()
foreach ($line in $profileOutput) {
    if ($line -match ':\s+(.+)$') {
        $name = $Matches[1].Trim()
        if ($name) { $profileNames += $name }
    }
}
Write-Log "Found $($profileNames.Count) WiFi profile(s)."
#endregion

#region --- Export Each Profile ---
$ProfileResults = @()

foreach ($ssid in $profileNames) {
    Write-Log "Exporting profile: $ssid"
    $profileInfo = [PSCustomObject]@{
        SSID           = $ssid
        Authentication = $null
        Encryption     = $null
        KeyType        = $null
        Exported       = $false
        NeedsReauth    = $false
        Error          = $null
    }

    try {
        # Export XML with cleartext key
        $exportResult = netsh wlan export profile name="$ssid" folder="$WiFiDir" key=clear 2>&1
        $exportedFile = Get-ChildItem -Path $WiFiDir -Filter "*$($ssid -replace '[\\/:*?\"<>|]', '_')*" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1

        if ($exportedFile) {
            $profileInfo.Exported = $true
            Write-Log "  Exported: $($exportedFile.Name)"

            # Parse XML for auth details
            try {
                [xml]$xml = Get-Content $exportedFile.FullName -ErrorAction Stop
                $ns = @{ w = 'http://www.microsoft.com/networking/WLAN/profile/v1' }
                $authNode = $xml.WLANProfile.MSM.security.authEncryption
                if ($authNode) {
                    $profileInfo.Authentication = $authNode.authentication
                    $profileInfo.Encryption     = $authNode.encryption

                    # Enterprise profiles need re-auth
                    $enterpriseAuths = @('WPA2-Enterprise', 'WPA-Enterprise', 'WPA3-Enterprise')
                    if ($profileInfo.Authentication -in @('WPA2Enterprise', 'WPAEnterprise', 'WPA3Enterprise') -or
                        $profileInfo.Authentication -match 'Enterprise') {
                        $profileInfo.NeedsReauth = $true
                        $profileInfo.KeyType = 'Enterprise (credential required)'
                        Write-Log "  Enterprise profile - credentials cannot be exported" 'WARN'
                    } else {
                        $profileInfo.KeyType = 'Pre-shared key'
                    }
                }
            } catch {
                Write-Log "  Could not parse XML: $_" 'WARN'
            }
        } else {
            $profileInfo.Error = "Export command ran but no file found"
            Write-Log "  Export failed: no output file" 'WARN'
        }
    } catch {
        $profileInfo.Error = $_.ToString()
        Write-ErrorLog "Failed to export '$($ssid)': $_"
    }

    $ProfileResults += $profileInfo
}
#endregion

#region --- Active Connection ---
$ActiveSSID = $null
try {
    $interfaces = netsh wlan show interfaces 2>&1
    foreach ($line in $interfaces) {
        if ($line -match 'SSID\s+:\s+(.+)$' -and $line -notmatch 'BSSID') {
            $ActiveSSID = $Matches[1].Trim()
            break
        }
    }
    if ($ActiveSSID) { Write-Log "Currently connected to: $ActiveSSID" }
} catch {
    Write-Log "Could not determine active WiFi connection" 'WARN'
}
#endregion

#region --- Output ---
$Result = [PSCustomObject]@{
    Timestamp       = (Get-Date -Format 'o')
    WlanService     = 'Running'
    ActiveSSID      = $ActiveSSID
    ProfileCount    = $ProfileResults.Count
    ExportedCount   = ($ProfileResults | Where-Object { $_.Exported }).Count
    EnterpriseCount = ($ProfileResults | Where-Object { $_.NeedsReauth }).Count
    ExportPath      = $WiFiDir
    Profiles        = $ProfileResults
}

$Result | ConvertTo-Json -Depth 5 | Out-File "$LogDir\WiFiProfiles-Report.json" -Force

if ($NonInteractive) {
    $Result | ConvertTo-Json -Depth 5
} else {
    Write-Host ""
    Write-Host "=== WiFi Profiles Backup ===" -ForegroundColor Cyan
    Write-Host "Total profiles:      $($ProfileResults.Count)"
    Write-Host "Exported:            $(($ProfileResults | Where-Object { $_.Exported }).Count)"
    Write-Host "Enterprise (no key): $(($ProfileResults | Where-Object { $_.NeedsReauth }).Count)"
    if ($ActiveSSID) { Write-Host "Currently connected:  $ActiveSSID" -ForegroundColor Green }
    Write-Host ""
    foreach ($p in $ProfileResults) {
        $color = if ($p.Exported) { 'Green' } else { 'Red' }
        $extra = if ($p.NeedsReauth) { ' [Enterprise]' } else { '' }
        Write-Host "  $($p.SSID)$extra - $($p.Authentication)" -ForegroundColor $color
    }
    Write-Host ""
    Write-Host "Exported to: $WiFiDir"
    Write-Host "Report:      $LogDir\WiFiProfiles-Report.json"
    Write-Host ""
}
#endregion
