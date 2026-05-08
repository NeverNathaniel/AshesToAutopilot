<#
.SYNOPSIS
    Backs up browser bookmarks for Chrome, Edge, Brave, and Firefox across all active user profiles.

.DESCRIPTION
    For each active user profile (skipping system, inactive 30+ days, ithlocal/itklocal):
    - Detects installed browsers: Chrome, Edge, Brave, Firefox.
    - Enumerates all browser profiles (not just Default).
    - Backs up bookmarks/places files to C:\PreWipeOutput\Bookmarks\{UserProfile}\{Browser}\{BrowserProfile}\.
    - Detects sync status per browser where possible.
    - Reports: browser, profile, sync enabled/disabled, bookmarks backed up (yes/no).

.PARAMETER NonInteractive
    Suppress all prompts. Output structured JSON to stdout. Exit cleanly.

.EXAMPLE
    .\Backup-BrowserBookmarks.ps1
    .\Backup-BrowserBookmarks.ps1 -NonInteractive

.NOTES
    Source repos used:
    - public-main/Powershell Scripts/export-bookmarks.ps1 (Chrome bookmark file paths
      and Get-BookmarkFolder recursive enumeration pattern; adapted for multi-browser/profile)
    - powershell-scripts-master/export-bookmarks.ps1 (same source, duplicate)

    Requires: Administrator
    Output:   C:\PreWipeOutput\Bookmarks\
#>

[CmdletBinding()]
param(
    [switch]$NonInteractive
)

#region --- Init ---
$ScriptName  = 'Backup-BrowserBookmarks'
. (Join-Path $PSScriptRoot '..\Common\Initialize-Toolkit.ps1')
. (Join-Path $PSScriptRoot '..\Common\Get-ActiveUserProfile.ps1')
$LogFile     = "$LogDir\$ScriptName.log"
if (-not (Test-AdminElevation)) { exit 1 }
$BookmarkRoot= "$OutputRoot\Bookmarks"
if (-not (Test-Path $BookmarkRoot)) { New-Item -Path $BookmarkRoot -ItemType Directory -Force | Out-Null }
#endregion

#region --- Profile Enumeration ---
$Profiles = @(Get-ActiveUserProfile)
Write-Log "Active profiles: $($Profiles.Count)"
#endregion

#region --- Browser Backup Functions ---

function Get-ChromiumSyncStatus {
    param([string]$PrefsFile)
    # Chrome/Edge/Brave: check Preferences JSON for sync account
    if (-not (Test-Path $PrefsFile)) { return 'Unknown' }
    try {
        $prefs = Get-Content $PrefsFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        # Check for SyncDisabled policy first
        $syncDisabled = $false
        $accountEmail = $null
        if ($prefs.sync) {
            if ($prefs.sync.suppressed_stop_sync_warning) { $syncDisabled = $true }
        }
        if ($prefs.account_info -and $prefs.account_info.Count -gt 0) {
            $accountEmail = $prefs.account_info[0].email
        }
        if ($prefs.signin -and $prefs.signin.allowed -eq $false) { $syncDisabled = $true }
        if ($syncDisabled) { return 'Disabled' }
        if ($accountEmail) { return "Enabled ($accountEmail)" }
        return 'NotSignedIn'
    } catch {
        return "Unknown (parse error)"
    }
}

function Get-FirefoxSyncStatus {
    param([string]$ProfileDir)
    $prefsFile = Join-Path $ProfileDir 'prefs.js'
    if (-not (Test-Path $prefsFile)) { return 'Unknown' }
    try {
        $content = Get-Content $prefsFile -ErrorAction Stop
        $syncEmail = $content | Where-Object { $_ -match 'services.sync.username' } |
            Select-Object -First 1
        if ($syncEmail) {
            if ($syncEmail -match '"([^"]+@[^"]+)"') { return "Enabled ($($Matches[1]))" }
            return 'Enabled'
        }
        return 'NotConfigured'
    } catch {
        return 'Unknown'
    }
}

function Backup-ChromiumBrowser {
    param(
        [string]$BrowserName,
        [string]$UserDataPath,
        [string]$DestBase
    )
    $BrowserResults = @()
    if (-not (Test-Path $UserDataPath)) { return $BrowserResults }

    # Enumerate all profiles (Profile 1, Profile 2, Default, etc.)
    $profileDirs = Get-ChildItem -Path $UserDataPath -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^(Default|Profile \d+)$' }

    foreach ($pDir in $profileDirs) {
        $bookmarkFile = Join-Path $pDir.FullName 'Bookmarks'
        $prefsFile    = Join-Path $pDir.FullName 'Preferences'
        $syncStatus   = Get-ChromiumSyncStatus -PrefsFile $prefsFile

        $bResult = [PSCustomObject]@{
            Browser        = $BrowserName
            BrowserProfile = $pDir.Name
            SyncStatus     = $syncStatus
            BackedUp       = $false
            BackupPath     = $null
            Error          = $null
        }

        if (Test-Path $bookmarkFile) {
            $dest = Join-Path $DestBase "$BrowserName\$($pDir.Name)"
            try {
                if (-not (Test-Path $dest)) { New-Item -Path $dest -ItemType Directory -Force | Out-Null }
                Copy-Item -Path $bookmarkFile -Destination "$dest\Bookmarks" -Force -ErrorAction Stop
                $bResult.BackedUp   = $true
                $bResult.BackupPath = "$dest\Bookmarks"
                Write-Log "  Backed up: $BrowserName/$($pDir.Name)"
            } catch {
                Write-ErrorLog "Backup failed $BrowserName/$($pDir.Name): $_"
                $bResult.Error = $_.ToString()
            }
        } else {
            Write-Log "  No Bookmarks file in $BrowserName/$($pDir.Name)" 'DEBUG'
        }

        $BrowserResults += $bResult
    }
    return $BrowserResults
}

function Backup-FirefoxBrowser {
    param(
        [string]$FFProfilesPath,
        [string]$DestBase
    )
    $BrowserResults = @()
    if (-not (Test-Path $FFProfilesPath)) { return $BrowserResults }

    $profileDirs = Get-ChildItem -Path $FFProfilesPath -Directory -ErrorAction SilentlyContinue

    foreach ($pDir in $profileDirs) {
        $placesFile = Join-Path $pDir.FullName 'places.sqlite'
        $syncStatus = Get-FirefoxSyncStatus -ProfileDir $pDir.FullName

        $bResult = [PSCustomObject]@{
            Browser        = 'Firefox'
            BrowserProfile = $pDir.Name
            SyncStatus     = $syncStatus
            BackedUp       = $false
            BackupPath     = $null
            Error          = $null
        }

        if (Test-Path $placesFile) {
            $dest = Join-Path $DestBase "Firefox\$($pDir.Name)"
            try {
                if (-not (Test-Path $dest)) { New-Item -Path $dest -ItemType Directory -Force | Out-Null }
                Copy-Item -Path $placesFile -Destination "$dest\places.sqlite" -Force -ErrorAction Stop
                $bResult.BackedUp   = $true
                $bResult.BackupPath = "$dest\places.sqlite"
                Write-Log "  Backed up: Firefox/$($pDir.Name)"
            } catch {
                Write-ErrorLog "Backup failed Firefox/$($pDir.Name): $_"
                $bResult.Error = $_.ToString()
            }
        }
        $BrowserResults += $bResult
    }
    return $BrowserResults
}
#endregion

#region --- Main Loop ---
$AllResults = @()

foreach ($Profile in $Profiles) {
    $ProfilePath = $Profile.LocalPath
    $ProfileName = Split-Path $ProfilePath -Leaf
    $LocalAppData = Join-Path $ProfilePath 'AppData\Local'
    $RoamingAppData = Join-Path $ProfilePath 'AppData\Roaming'
    $DestBase = Join-Path $BookmarkRoot $ProfileName

    Write-Log "Processing browsers for: $ProfileName"

    $ProfileResults = @()

    # Chrome
    $ChromePath = "$LocalAppData\Google\Chrome\User Data"
    $ProfileResults += Backup-ChromiumBrowser -BrowserName 'Chrome' -UserDataPath $ChromePath -DestBase $DestBase

    # Edge
    $EdgePath = "$LocalAppData\Microsoft\Edge\User Data"
    $ProfileResults += Backup-ChromiumBrowser -BrowserName 'Edge' -UserDataPath $EdgePath -DestBase $DestBase

    # Brave
    $BravePath = "$LocalAppData\BraveSoftware\Brave-Browser\User Data"
    $ProfileResults += Backup-ChromiumBrowser -BrowserName 'Brave' -UserDataPath $BravePath -DestBase $DestBase

    # Firefox
    $FFProfilesPath = "$RoamingAppData\Mozilla\Firefox\Profiles"
    $ProfileResults += Backup-FirefoxBrowser -FFProfilesPath $FFProfilesPath -DestBase $DestBase

    $AllResults += [PSCustomObject]@{
        UserProfile = $ProfileName
        Browsers    = $ProfileResults
    }
}
#endregion

#region --- Output ---
$Summary = [PSCustomObject]@{
    Timestamp = (Get-Date -Format 'o')
    Results   = $AllResults
}

$Summary | ConvertTo-Json -Depth 10 | Out-File "$OutputRoot\Logs\BrowserBookmarks-Report.json" -Force

if ($NonInteractive) {
    $Summary | ConvertTo-Json -Depth 10
} else {
    Write-Host ""
    Write-Host "=== Browser Bookmark Backup Summary ===" -ForegroundColor Cyan
    foreach ($ur in $AllResults) {
        Write-Host "  User: $($ur.UserProfile)"
        foreach ($br in $ur.Browsers) {
            $status = if ($br.BackedUp) { 'OK' } else { 'NoBookmarks' }
            Write-Host "    $($br.Browser)/$($br.BrowserProfile): Sync=$($br.SyncStatus) | Backup=$status"
        }
    }
    Write-Host ""
    Write-Host "Backups saved to: $BookmarkRoot"
    Write-Host "Report: $OutputRoot\Logs\BrowserBookmarks-Report.json"
    Write-Host ""
}
#endregion

exit 0
