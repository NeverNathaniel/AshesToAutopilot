<#
.SYNOPSIS
    Restores Wi-Fi profiles exported by Backup-WiFiProfiles.ps1.

.DESCRIPTION
    Imports every XML in <BackupRoot>\WiFiProfiles via
    'netsh wlan add profile filename=... user=all', verified by exit code.
    Enterprise (802.1x) profiles import but carry no credentials - they are
    marked NeedsReauth. Requires Administrator (user=all).

.PARAMETER BackupRoot
    The copied pre-wipe output folder (e.g. E:\PreWipeOutput).

.PARAMETER NonInteractive
    Suppress prompts. Output structured JSON to stdout.

.NOTES
    Requires: Administrator
    Output:   C:\PreWipeOutput\Logs\Restore-WiFiProfiles-Report.json
#>
[CmdletBinding()]
param(
    [string]$BackupRoot = 'C:\PreWipeOutput',
    [string]$SourceProfile,
    [switch]$NonInteractive
)

$ScriptName = 'Restore-WiFiProfiles'
. (Join-Path $PSScriptRoot '..\Common\Initialize-Toolkit.ps1')
. (Join-Path $PSScriptRoot 'Restore-Common.ps1')
$LogFile = "$LogDir\$ScriptName.log"
if (-not (Test-AdminElevation)) { exit 1 }

$Items = @()
$wifiDir = Join-Path $BackupRoot 'WiFiProfiles'

$wlanRunning = $false
try { $wlanRunning = (Get-Service -Name 'WlanSvc' -ErrorAction Stop).Status -eq 'Running' } catch { }

if (-not (Test-Path -LiteralPath $wifiDir)) {
    Write-Log "No WiFiProfiles folder in backup at $wifiDir" 'WARN'
} elseif (-not $wlanRunning) {
    foreach ($xml in (Get-ChildItem -LiteralPath $wifiDir -Filter '*.xml' -ErrorAction SilentlyContinue)) {
        $Items += New-RestoreItem -Name $xml.BaseName -Action 'Skipped' -Detail 'WLAN service not running on this device (no Wi-Fi adapter?)'
    }
    Write-Log 'WLAN service not running - Wi-Fi profiles skipped' 'WARN'
} else {
    foreach ($xml in (Get-ChildItem -LiteralPath $wifiDir -Filter '*.xml' -ErrorAction SilentlyContinue)) {
        $isEnterprise = $false
        try {
            $content = Get-Content -LiteralPath $xml.FullName -Raw -ErrorAction Stop
            $isEnterprise = $content -match 'Enterprise'
        } catch { }

        $null = netsh wlan add profile filename="$($xml.FullName)" user=all 2>&1
        if ($LASTEXITCODE -eq 0) {
            $detail = if ($isEnterprise) { 'Imported - enterprise (802.1x) profile: user must re-enter credentials on first connect' } else { 'Imported with pre-shared key' }
            $Items += New-RestoreItem -Name $xml.BaseName -Action 'Restored' -Detail $detail
            Write-Log "Restored Wi-Fi profile: $($xml.BaseName)"
        } else {
            $Items += New-RestoreItem -Name $xml.BaseName -Action 'Failed' -Detail "netsh exited $LASTEXITCODE"
            Write-ErrorLog "Wi-Fi profile import failed: $($xml.Name) (netsh exit $LASTEXITCODE)"
        }
    }
}

$Result = [PSCustomObject]@{
    Timestamp     = (Get-Date -Format 'o')
    BackupRoot    = $BackupRoot
    SourceProfile = $SourceProfile
    Items         = $Items
    Counts        = [PSCustomObject]@{
        Restored = @($Items | Where-Object { $_.Action -eq 'Restored' }).Count
        Staged   = @($Items | Where-Object { $_.Action -eq 'Staged' }).Count
        Skipped  = @($Items | Where-Object { $_.Action -eq 'Skipped' }).Count
        Failed   = @($Items | Where-Object { $_.Action -eq 'Failed' }).Count
    }
}

$Result | ConvertTo-Json -Depth 5 | Out-File "$LogDir\$ScriptName-Report.json" -Force
if ($NonInteractive) { $Result | ConvertTo-Json -Depth 5 }
else {
    Write-Host ''
    Write-Host "=== Wi-Fi Profile Restore ($($Items.Count) profile(s)) ===" -ForegroundColor Cyan
    foreach ($i in $Items) { Write-Host "  [$($i.Action)] $($i.Name) $($i.Detail)" }
    Write-Host ''
}
exit 0
