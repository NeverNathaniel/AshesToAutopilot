<#
.SYNOPSIS
    Backs up taskbar layout and pinned app data for all active user profiles.

.DESCRIPTION
    For each active user profile (skipping system, inactive 30+ days, ithlocal/itklocal):
    - Detects Windows version (Win10 vs Win11 use different taskbar mechanisms).
    - Win10: exports taskbar registry keys and LayoutModification.xml.
    - Win11: copies TaskbarLayoutModification.xml and relevant AppData files.
    - Saves to C:\PreWipeOutput\Taskbar\{UserProfile}\.

.PARAMETER NonInteractive
    Suppress all prompts. Output structured JSON to stdout. Exit cleanly.

.EXAMPLE
    .\Backup-TaskbarLayout.ps1
    .\Backup-TaskbarLayout.ps1 -NonInteractive

.NOTES
    Source repos used:
    - No dedicated taskbar backup script found in source repos.
      Implemented using known registry and file paths for Win10/Win11 taskbar.
      Win10: HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband
             %APPDATA%\Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar
      Win11: %LOCALAPPDATA%\Microsoft\Windows\Shell\LayoutModification.xml
             HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband

    Requires: Administrator
    Output:   C:\PreWipeOutput\Taskbar\
#>

[CmdletBinding()]
param(
    [switch]$NonInteractive
)

#region --- Init ---
$ScriptName  = 'Backup-TaskbarLayout'
. (Join-Path $PSScriptRoot '..\Common\Initialize-Toolkit.ps1')
. (Join-Path $PSScriptRoot '..\Common\Get-ActiveUserProfile.ps1')
$LogFile     = "$LogDir\$ScriptName.log"
if (-not (Test-AdminElevation)) { exit 1 }
$TaskbarRoot = "$OutputRoot\Taskbar"
if (-not (Test-Path $TaskbarRoot)) { New-Item -Path $TaskbarRoot -ItemType Directory -Force | Out-Null }
# Detect Windows version
$OSBuild = [System.Environment]::OSVersion.Version.Build
$IsWin11 = $OSBuild -ge 22000
Write-Log "Windows build: $OSBuild | Win11: $IsWin11"
#endregion

#region --- Profile Enumeration ---
$Profiles = @(Get-ActiveUserProfile)
Write-Log "Active profiles: $($Profiles.Count)"
#endregion

#region --- Backup Loop ---
$Results = @()

foreach ($Profile in $Profiles) {
    $ProfilePath    = $Profile.LocalPath
    $ProfileName    = Split-Path $ProfilePath -Leaf
    $SID            = $Profile.SID
    $LocalAppData   = Join-Path $ProfilePath 'AppData\Local'
    $RoamingAppData = Join-Path $ProfilePath 'AppData\Roaming'
    $Dest           = Join-Path $TaskbarRoot $ProfileName

    Write-Log "Backing up taskbar layout for: $ProfileName"

    $Result = [PSCustomObject]@{
        Profile       = $ProfileName
        WindowsVersion = if ($IsWin11) { 'Win11' } else { 'Win10' }
        BackupDest    = $Dest
        FilesBackedUp = @()
        RegExported   = $false
        Success       = $false
        Error         = $null
    }

    try {
        if (-not (Test-Path $Dest)) { New-Item -Path $Dest -ItemType Directory -Force | Out-Null }

        # Load user registry hive
        $HiveLoaded = Mount-UserHive -UserProfile $Profile

        # Files to back up (both Win10 and Win11)
        $filesToCopy = @(
            # Win10/11: LayoutModification XML
            "$LocalAppData\Microsoft\Windows\Shell\LayoutModification.xml",
            # Win11 taskbar layout
            "$LocalAppData\Microsoft\Windows\Shell\LayoutModification.json",
            # Pinned items DB (Win11)
            "$LocalAppData\Microsoft\Windows\Shell\DefaultLayouts.xml"
        )

        # Win10: pinned taskbar items are in Quick Launch
        if (-not $IsWin11) {
            $pinnedPath = "$RoamingAppData\Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar"
            if (Test-Path $pinnedPath) {
                $pinnedDest = Join-Path $Dest 'PinnedItems'
                if (-not (Test-Path $pinnedDest)) { New-Item $pinnedDest -ItemType Directory -Force | Out-Null }
                Copy-Item -Path "$pinnedPath\*" -Destination $pinnedDest -Recurse -Force -ErrorAction SilentlyContinue
                $Result.FilesBackedUp += $pinnedDest
                Write-Log "  Copied pinned taskbar items"
            }
        } else {
            # Win11: taskbar pinned items
            $win11PinnedPaths = @(
                "$LocalAppData\Packages\Microsoft.Windows.StartMenuExperienceHost_cw5n1h2txyewy\LocalState",
                "$LocalAppData\Microsoft\Windows\Shell"
            )
            foreach ($wp in $win11PinnedPaths) {
                if (Test-Path $wp) {
                    $wDest = Join-Path $Dest "Win11_$(Split-Path $wp -Leaf)"
                    if (-not (Test-Path $wDest)) { New-Item $wDest -ItemType Directory -Force | Out-Null }
                    Get-ChildItem $wp -File -ErrorAction SilentlyContinue | ForEach-Object {
                        Copy-Item $_.FullName -Destination $wDest -Force -ErrorAction SilentlyContinue
                    }
                    $Result.FilesBackedUp += $wDest
                }
            }
        }

        # Copy common files
        foreach ($f in $filesToCopy) {
            if (Test-Path $f) {
                Copy-Item -Path $f -Destination $Dest -Force -ErrorAction SilentlyContinue
                $Result.FilesBackedUp += $f
                Write-Log "  Copied: $f"
            }
        }

        # Export registry key for taskbar
        if ($HiveLoaded -or (Test-Path "Registry::HKEY_USERS\$SID")) {
            $regExportFile = Join-Path $Dest 'TaskbarRegistry.reg'
            $taskbandKey   = "HKU\$SID\Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband"
            $regOutput = & reg export $taskbandKey $regExportFile /y 2>&1
            if ($LASTEXITCODE -eq 0) {
                $Result.RegExported = $true
                Write-Log "  Registry exported to $regExportFile"
            } else {
                Write-Log "  Registry export warning (key may not exist): $regOutput" 'WARN'
            }
        }

        if ($HiveLoaded) { Dismount-UserHive -SID $SID }

        $Result.Success = $true
    } catch {
        Write-ErrorLog "Backup failed for $ProfileName : $_"
        $Result.Error = $_.ToString()
    }

    $Results += $Result
}
#endregion

#region --- Output ---
$Summary = [PSCustomObject]@{
    Timestamp     = (Get-Date -Format 'o')
    WindowsBuild  = $OSBuild
    IsWin11       = $IsWin11
    Results       = $Results
}

$Summary | ConvertTo-Json -Depth 5 | Out-File "$OutputRoot\Logs\TaskbarLayout-Report.json" -Force

if ($NonInteractive) {
    $Summary | ConvertTo-Json -Depth 5
} else {
    Write-Host ""
    Write-Host "=== Taskbar Layout Backup ===" -ForegroundColor Cyan
    foreach ($r in $Results) {
        $status = if ($r.Success) { 'OK' } else { "FAILED: $($r.Error)" }
        Write-Host "  $($r.Profile) [$($r.WindowsVersion)]: $status | Files: $($r.FilesBackedUp.Count) | RegExported: $($r.RegExported)"
    }
    Write-Host ""
    Write-Host "Backups saved to: $TaskbarRoot"
    Write-Host ""
}
#endregion

exit 0
