<#
.SYNOPSIS
    Inventories Microsoft Teams local data that may be lost at wipe.

.DESCRIPTION
    For each active user profile, examines classic and new (Store) Teams data
    locations on disk that aren't necessarily synchronized to SharePoint or
    OneDrive. Reports per-profile findings including:
      - Classic Teams Downloads folder count and size.
      - Classic Teams Local cache folder size.
      - New Teams (MSTeams_*) LocalCache size.
      - Any meeting media files (*.mp4, *.m4a, *.wav) discovered under either
        Teams location, including their per-file size.

    The script is read-only. It never opens, copies, or modifies any Teams
    file -- it only enumerates paths and computes sizes.

.PARAMETER NonInteractive
    Suppress all prompts. Output structured JSON to stdout. Exit cleanly.

.EXAMPLE
    .\Get-TeamsData.ps1
    .\Get-TeamsData.ps1 -NonInteractive

.NOTES
    Requires: Administrator
    Output:   C:\PreWipeOutput\Logs\Get-TeamsData.log
              C:\PreWipeOutput\Logs\Get-TeamsData-Report.json
#>

[CmdletBinding()]
param(
    [switch]$NonInteractive
)

#region --- Init ---
$ScriptName = 'Get-TeamsData'
. (Join-Path $PSScriptRoot '..\Common\Initialize-Toolkit.ps1')
$LogFile = "$LogDir\$ScriptName.log"
. (Join-Path $PSScriptRoot '..\Common\Get-ActiveUserProfile.ps1')

if (-not (Test-AdminElevation)) { exit 1 }
#endregion

#region --- Helpers ---
function Get-FolderSizeMB {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return 0 }
    try {
        $bytes = (Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue |
                  Measure-Object -Property Length -Sum).Sum
        if (-not $bytes) { return 0 }
        return [math]::Round($bytes / 1MB, 2)
    } catch {
        Write-Log "Size enumeration failed for ${Path}: $_" 'WARN'
        return 0
    }
}

function Get-MediaFiles {
    param([string]$Path)
    $files = @()
    if (-not (Test-Path -LiteralPath $Path)) { return $files }
    try {
        $items = Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue |
                 Where-Object { $_.Extension -match '^\.(mp4|m4a|wav)$' }
        foreach ($f in $items) {
            $files += [PSCustomObject]@{
                Path   = $f.FullName
                SizeMB = [math]::Round($f.Length / 1MB, 2)
            }
        }
    } catch {
        Write-Log "Media file scan failed for ${Path}: $_" 'WARN'
    }
    return $files
}
#endregion

#region --- Inventory ---
$Results = @()
$Profiles = @()

try {
    $Profiles = Get-ActiveUserProfile
} catch {
    Write-ErrorLog "Profile enumeration failed: $_"
    exit 1
}

Write-Log "Active profiles to inspect: $($Profiles.Count)"

foreach ($UserProfile in $Profiles) {
    $ProfilePath = $UserProfile.LocalPath
    $ProfileName = Split-Path -Path $ProfilePath -Leaf
    Write-Log "Inspecting Teams data for: $ProfileName"

    $classicRoaming = Join-Path $ProfilePath 'AppData\Roaming\Microsoft\Teams'
    $classicLocal   = Join-Path $ProfilePath 'AppData\Local\Microsoft\Teams'
    $classicDownloads = Join-Path $classicRoaming 'Downloads'

    $classicPresent = (Test-Path -LiteralPath $classicRoaming) -or (Test-Path -LiteralPath $classicLocal)
    $classicDownloadsCount  = 0
    $classicDownloadsSizeMB = 0

    if (Test-Path -LiteralPath $classicDownloads) {
        try {
            $items = Get-ChildItem -LiteralPath $classicDownloads -Recurse -Force -File -ErrorAction SilentlyContinue
            $classicDownloadsCount  = ($items | Measure-Object).Count
            $bytes = ($items | Measure-Object -Property Length -Sum).Sum
            if ($bytes) { $classicDownloadsSizeMB = [math]::Round($bytes / 1MB, 2) }
        } catch {
            Write-Log "Could not enumerate classic Downloads for ${ProfileName}: $_" 'WARN'
        }
    }

    $classicLocalSizeMB = Get-FolderSizeMB -Path $classicLocal

    # New Teams (Store) lives under AppData\Local\Packages\MSTeams_*
    $newTeamsBase = Join-Path $ProfilePath 'AppData\Local\Packages'
    $newTeamsPresent     = $false
    $newTeamsCacheSizeMB = 0
    $newTeamsCachePaths  = @()

    if (Test-Path -LiteralPath $newTeamsBase) {
        try {
            $pkgs = Get-ChildItem -LiteralPath $newTeamsBase -Directory -Force -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -like 'MSTeams_*' }
            foreach ($pkg in $pkgs) {
                $cachePath = Join-Path $pkg.FullName 'LocalCache\Microsoft\MSTeams'
                if (Test-Path -LiteralPath $cachePath) {
                    $newTeamsPresent = $true
                    $newTeamsCachePaths += $cachePath
                    $newTeamsCacheSizeMB += Get-FolderSizeMB -Path $cachePath
                }
            }
        } catch {
            Write-Log "Could not enumerate new Teams packages for ${ProfileName}: $_" 'WARN'
        }
    }

    # Meeting-media file scan across both locations.
    $mediaFiles = @()
    foreach ($scanRoot in @($classicRoaming, $classicLocal) + $newTeamsCachePaths) {
        if ($scanRoot) { $mediaFiles += Get-MediaFiles -Path $scanRoot }
    }

    Write-Log "  Classic present: $classicPresent | Downloads files: $classicDownloadsCount ($classicDownloadsSizeMB MB) | Local cache: $classicLocalSizeMB MB"
    Write-Log "  New Teams present: $newTeamsPresent | Cache size: $newTeamsCacheSizeMB MB | Media files: $($mediaFiles.Count)"

    $Results += [PSCustomObject]@{
        Profile                = $ProfileName
        ClassicTeamsPresent    = [bool]$classicPresent
        ClassicDownloadsCount  = [int]$classicDownloadsCount
        ClassicDownloadsSizeMB = [double]$classicDownloadsSizeMB
        ClassicLocalCacheSizeMB = [double]$classicLocalSizeMB
        NewTeamsPresent        = [bool]$newTeamsPresent
        NewTeamsCacheSizeMB    = [double]([math]::Round($newTeamsCacheSizeMB, 2))
        MeetingMediaFiles      = @($mediaFiles)
    }
}

$AnyMedia = ($Results | Where-Object { $_.MeetingMediaFiles.Count -gt 0 }).Count -gt 0
#endregion

#region --- Output ---
$Summary = [PSCustomObject]@{
    Timestamp       = (Get-Date -Format 'o')
    ProfilesChecked = $Results.Count
    Results         = $Results
    AnyMediaFiles   = [bool]$AnyMedia
}

$ReportPath = "$LogDir\$ScriptName-Report.json"
$Summary | ConvertTo-Json -Depth 5 | Out-File -FilePath $ReportPath -Encoding UTF8 -Force

if ($NonInteractive) {
    $Summary | ConvertTo-Json -Depth 5
} else {
    Write-Host ''
    Write-Host '=== Microsoft Teams Local Data ===' -ForegroundColor Cyan
    Write-Host "Profiles checked: $($Results.Count)"
    $notable = $Results | Where-Object {
        $_.ClassicDownloadsCount -gt 0 -or $_.MeetingMediaFiles.Count -gt 0
    }
    if (-not $notable) {
        Write-Host '  No notable Teams findings (no Downloads contents, no meeting media).' -ForegroundColor Green
    } else {
        foreach ($r in $notable) {
            Write-Host ''
            Write-Host "  Profile: $($r.Profile)" -ForegroundColor Yellow
            if ($r.ClassicDownloadsCount -gt 0) {
                Write-Host "    Classic Downloads: $($r.ClassicDownloadsCount) file(s), $($r.ClassicDownloadsSizeMB) MB"
            }
            if ($r.MeetingMediaFiles.Count -gt 0) {
                Write-Host "    Meeting media files: $($r.MeetingMediaFiles.Count)"
                foreach ($m in $r.MeetingMediaFiles) {
                    Write-Host "      $($m.SizeMB) MB  $($m.Path)"
                }
            }
        }
    }
    Write-Host ''
    Write-Host "Report: $ReportPath"
    Write-Host ''
}
#endregion

exit 0
