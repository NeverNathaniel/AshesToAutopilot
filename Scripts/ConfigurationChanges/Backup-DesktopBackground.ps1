<#
.SYNOPSIS
    Backs up custom desktop wallpaper images for all active user profiles.

.DESCRIPTION
    For each active user profile (skipping system, inactive 30+ days, ithlocal/itklocal):
    - Checks if a custom desktop wallpaper is set (not a default Windows wallpaper).
    - If custom, copies the image file to C:\PreWipeOutput\Wallpaper\{UserProfile}\.
    - Reports the source path and whether backup succeeded.

.PARAMETER NonInteractive
    Suppress all prompts. Output structured JSON to stdout. Exit cleanly.

.EXAMPLE
    .\Backup-DesktopBackground.ps1
    .\Backup-DesktopBackground.ps1 -NonInteractive

.NOTES
    Source repos used:
    - No dedicated desktop background backup script found in source repos.
      Implemented using known registry path:
      HKCU\Control Panel\Desktop\Wallpaper
      Default Windows wallpapers are in %SystemRoot%\Web\Wallpaper\ so
      any path not under that location is considered custom.

    Requires: Administrator
    Output:   C:\PreWipeOutput\Wallpaper\
#>

[CmdletBinding()]
param(
    [switch]$NonInteractive
)

#region --- Init ---
$ScriptName   = 'Backup-DesktopBackground'
$OutputRoot   = 'C:\PreWipeOutput'
$WallpaperRoot= "$OutputRoot\Wallpaper"
$LogDir       = "$OutputRoot\Logs"
$LogFile      = "$LogDir\$ScriptName.log"
$ErrorLog     = "$OutputRoot\errors.log"

foreach ($d in @($OutputRoot, $WallpaperRoot, $LogDir)) {
    if (-not (Test-Path $d)) { New-Item -Path $d -ItemType Directory -Force | Out-Null }
}

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

# Paths considered default Windows wallpapers
$DefaultWallpaperPaths = @(
    "$env:SystemRoot\Web\",
    "$env:SystemRoot\System32\",
    '%SystemRoot%\Web\',
    'C:\Windows\Web\',
    'C:\Windows\System32\',
    ''  # empty = no wallpaper set
)
#endregion

#region --- Profile Enumeration ---
$SkipSIDs   = @('S-1-5-18', 'S-1-5-19', 'S-1-5-20')
$CutoffDate = (Get-Date).AddDays(-30)
$SkipNames  = @('ithlocal', 'itklocal', 'wsi', 'wsiaccount', 'defaultuser0', 'administrator', 'guest')

$Profiles = @()
try {
    $AllProfiles = Get-CimInstance -ClassName Win32_UserProfile -ErrorAction Stop |
        Where-Object { -not $_.Special }
    foreach ($p in $AllProfiles) {
        $sid = $p.SID
        if ($SkipSIDs -contains $sid -or $sid -match '^S-1-5-(18|19|20)$') { continue }
        $folderName = Split-Path $p.LocalPath -Leaf
        if ($SkipNames -contains $folderName.ToLower()) { Write-Log "Skipping service account: $folderName"; continue }
        $lastUse = $p.LastUseTime
        if ($null -eq $lastUse -or $lastUse -lt $CutoffDate) { Write-Log "Skipping inactive: $folderName"; continue }
        $Profiles += $p
    }
} catch {
    Write-ErrorLog "Profile enumeration failed: $_"; exit 1
}

Write-Log "Active profiles: $($Profiles.Count)"
#endregion

#region --- Backup Loop ---
$Results = @()

foreach ($Profile in $Profiles) {
    $ProfilePath = $Profile.LocalPath
    $ProfileName = Split-Path $ProfilePath -Leaf
    $SID         = $Profile.SID

    Write-Log "Checking desktop background for: $ProfileName"

    $Result = [PSCustomObject]@{
        Profile      = $ProfileName
        WallpaperPath = $null
        IsCustom     = $false
        BackupDest   = $null
        Success      = $false
        Skipped      = $false
        SkipReason   = $null
        Error        = $null
    }

    try {
        # Load user hive
        $HiveLoaded = $false
        if (-not (Test-Path "Registry::HKEY_USERS\$SID")) {
            $NtuserDat = Join-Path $ProfilePath 'NTUSER.DAT'
            if (Test-Path $NtuserDat) {
                $null = reg load "HKU\$SID" $NtuserDat 2>&1
                $HiveLoaded = $true
                Start-Sleep -Milliseconds 500
            } else {
                $Result.Skipped    = $true
                $Result.SkipReason = 'No NTUSER.DAT'
                $Results += $Result
                continue
            }
        }

        # Read wallpaper path from registry
        $desktopKey = "Registry::HKEY_USERS\$SID\Control Panel\Desktop"
        $wallpaperPath = $null

        if (Test-Path $desktopKey) {
            $desktopProps = Get-ItemProperty $desktopKey -ErrorAction SilentlyContinue
            $wallpaperPath = $desktopProps.Wallpaper
        }

        $Result.WallpaperPath = $wallpaperPath

        if ([string]::IsNullOrWhiteSpace($wallpaperPath)) {
            $Result.Skipped    = $true
            $Result.SkipReason = 'No wallpaper configured'
            Write-Log "  $($ProfileName): No wallpaper configured"
        } else {
            # Check if it's a default Windows wallpaper
            $isDefault = $false
            foreach ($defaultPath in $DefaultWallpaperPaths) {
                if ([string]::IsNullOrEmpty($defaultPath)) { continue }
                if ($wallpaperPath -like "$defaultPath*") { $isDefault = $true; break }
            }

            # Also resolve environment variables
            $expandedPath = [System.Environment]::ExpandEnvironmentVariables($wallpaperPath)

            # Re-check with expanded path
            if (-not $isDefault) {
                foreach ($defaultPath in @('C:\Windows\Web\', 'C:\Windows\System32\')) {
                    if ($expandedPath -like "$defaultPath*") { $isDefault = $true; break }
                }
            }

            if ($isDefault) {
                $Result.IsCustom   = $false
                $Result.Skipped    = $true
                $Result.SkipReason = "Default Windows wallpaper: $wallpaperPath"
                Write-Log "  $($ProfileName): Default wallpaper, skipping"
            } else {
                $Result.IsCustom = $true
                Write-Log "  $($ProfileName): Custom wallpaper at $expandedPath"

                if (Test-Path $expandedPath) {
                    $dest = Join-Path $WallpaperRoot $ProfileName
                    if (-not (Test-Path $dest)) { New-Item $dest -ItemType Directory -Force | Out-Null }
                    $fileName = Split-Path $expandedPath -Leaf
                    Copy-Item -Path $expandedPath -Destination "$dest\$fileName" -Force -ErrorAction Stop
                    $Result.BackupDest = "$dest\$fileName"
                    $Result.Success    = $true
                    Write-Log "  Backed up wallpaper to $dest\$fileName"
                } else {
                    $Result.Skipped    = $true
                    $Result.SkipReason = "Wallpaper file not found: $expandedPath"
                    Write-Log "  Wallpaper file not found: $expandedPath" 'WARN'
                }
            }
        }
    } catch {
        Write-ErrorLog "Error processing $ProfileName : $_"
        $Result.Error = $_.ToString()
    } finally {
        if ($HiveLoaded) {
            [GC]::Collect(); Start-Sleep -Milliseconds 200
            $null = reg unload "HKU\$SID" 2>&1
        }
    }

    $Results += $Result
}
#endregion

#region --- Output ---
$Summary = [PSCustomObject]@{
    Timestamp = (Get-Date -Format 'o')
    Results   = $Results
}

$Summary | ConvertTo-Json -Depth 5 | Out-File "$OutputRoot\Logs\DesktopBackground-Report.json" -Force

if ($NonInteractive) {
    $Summary | ConvertTo-Json -Depth 5
} else {
    Write-Host ""
    Write-Host "=== Desktop Background Backup ===" -ForegroundColor Cyan
    foreach ($r in $Results) {
        if ($r.Success) {
            Write-Host "  $($r.Profile): Custom wallpaper backed up -> $($r.BackupDest)" -ForegroundColor Green
        } elseif ($r.Skipped) {
            Write-Host "  $($r.Profile): Skipped - $($r.SkipReason)"
        } elseif ($r.Error) {
            Write-Host "  $($r.Profile): ERROR - $($r.Error)" -ForegroundColor Red
        }
    }
    Write-Host ""
    Write-Host "Backups saved to: $WallpaperRoot"
    Write-Host ""
}
#endregion
