<#
.SYNOPSIS
    Reports the size of each active user's Downloads folder and optionally copies it.

.DESCRIPTION
    For each active user profile (skipping system, inactive 30+ days, ithlocal/itklocal):
    - Calculates the size of the Downloads folder.
    - Interactive mode: reports size and prompts once whether to copy to Documents\Downloads_Backup.
    - NonInteractive mode: reports size only as JSON.

.PARAMETER NonInteractive
    Suppress all prompts. Output structured JSON to stdout. Exit cleanly.

.EXAMPLE
    .\Get-DownloadsSize.ps1
    .\Get-DownloadsSize.ps1 -NonInteractive

.NOTES
    Source repos used:
    - LazyAdmin-master/Office365/OneDriveSizeReport.ps1 (folder size calculation patterns)
    - public-main/IntuneConfig/Powershell/backupprofile.ps1 (profile path enumeration)
    No direct Downloads-size script found; folder sizing via Get-ChildItem -Recurse is standard.

    Requires: Administrator
    Output:   C:\PreWipeOutput\Logs\Get-DownloadsSize.log
#>

[CmdletBinding()]
param(
    [switch]$NonInteractive
)

#region --- Init ---
$ScriptName = 'Get-DownloadsSize'
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

function Format-Bytes {
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { return "{0:N2} GB" -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return "{0:N2} MB" -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return "{0:N2} KB" -f ($Bytes / 1KB) }
    return "$Bytes B"
}

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "ERROR: This script must be run as Administrator." -ForegroundColor Red
    exit 1
}
#endregion

#region --- Profile Enumeration ---
$SkipSIDs   = @('S-1-5-18', 'S-1-5-19', 'S-1-5-20')
$CutoffDate = (Get-Date).AddDays(-30)
$SkipNames  = @('ithlocal', 'itklocal')

$Profiles = @()
try {
    $AllProfiles = Get-CimInstance -ClassName Win32_UserProfile -ErrorAction Stop |
        Where-Object { -not $_.Special }
    foreach ($p in $AllProfiles) {
        $sid = $p.SID
        if ($SkipSIDs -contains $sid -or $sid -match '^S-1-5-(18|19|20)$') { continue }
        $folderName = Split-Path $p.LocalPath -Leaf
        if ($SkipNames -contains $folderName.ToLower()) {
            Write-Log "Skipping service account: $folderName"
            continue
        }
        $lastUse = $p.LastUseTime
        if ($null -eq $lastUse -or $lastUse -lt $CutoffDate) {
            Write-Log "Skipping inactive profile: $folderName (LastUse: $lastUse)"
            continue
        }
        $Profiles += $p
    }
} catch {
    Write-ErrorLog "Profile enumeration failed: $_"
    exit 1
}

Write-Log "Active profiles to check: $($Profiles.Count)"
#endregion

#region --- Size Calculation ---
$Results = @()

foreach ($Profile in $Profiles) {
    $ProfilePath  = $Profile.LocalPath
    $ProfileName  = Split-Path $ProfilePath -Leaf
    $DownloadsDir = Join-Path $ProfilePath 'Downloads'

    $ProfileResult = [PSCustomObject]@{
        Profile       = $ProfileName
        ProfilePath   = $ProfilePath
        DownloadsPath = $DownloadsDir
        SizeBytes     = 0
        SizeHuman     = '0 B'
        FileCount     = 0
        FolderExists  = $false
        CopyRequested = $false
        CopyDest      = $null
        CopySuccess   = $null
        Error         = $null
    }

    try {
        if (Test-Path $DownloadsDir) {
            $ProfileResult.FolderExists = $true
            Write-Log "Calculating size of $DownloadsDir ..."
            $items = Get-ChildItem -Path $DownloadsDir -Recurse -Force -ErrorAction SilentlyContinue
            $size  = ($items | Where-Object { -not $_.PSIsContainer } | Measure-Object -Property Length -Sum).Sum
            $ProfileResult.SizeBytes = [long]($size ?? 0)
            $ProfileResult.SizeHuman = Format-Bytes $ProfileResult.SizeBytes
            $ProfileResult.FileCount = ($items | Where-Object { -not $_.PSIsContainer }).Count
            Write-Log "$ProfileName Downloads: $($ProfileResult.SizeHuman) ($($ProfileResult.FileCount) files)"
        } else {
            Write-Log "No Downloads folder found for $ProfileName"
        }
    } catch {
        Write-ErrorLog "Error sizing Downloads for $ProfileName : $_"
        $ProfileResult.Error = $_.ToString()
    }

    $Results += $ProfileResult
}
#endregion

#region --- Interactive Copy Prompt ---
if (-not $NonInteractive) {
    Write-Host ""
    Write-Host "=== Downloads Folder Summary ===" -ForegroundColor Cyan
    foreach ($r in $Results) {
        if ($r.FolderExists) {
            Write-Host "  $($r.Profile): $($r.SizeHuman) ($($r.FileCount) files) at $($r.DownloadsPath)"
        } else {
            Write-Host "  $($r.Profile): No Downloads folder found"
        }
    }
    Write-Host ""

    $copyChoice = Read-Host "Copy any Downloads folder to Documents\Downloads_Backup? [Y/N]"
    if ($copyChoice -match '^[Yy]') {
        foreach ($r in ($Results | Where-Object { $_.FolderExists })) {
            $destPath = Join-Path $r.ProfilePath 'Documents\Downloads_Backup'
            Write-Log "Copying $($r.DownloadsPath) -> $destPath ..."
            try {
                if (-not (Test-Path $destPath)) {
                    New-Item -Path $destPath -ItemType Directory -Force | Out-Null
                }
                Copy-Item -Path "$($r.DownloadsPath)\*" -Destination $destPath -Recurse -Force -ErrorAction Stop
                $r.CopyRequested = $true
                $r.CopyDest      = $destPath
                $r.CopySuccess   = $true
                Write-Log "Copy complete for $($r.Profile)"
            } catch {
                Write-ErrorLog "Copy failed for $($r.Profile): $_"
                $r.CopyRequested = $true
                $r.CopyDest      = $destPath
                $r.CopySuccess   = $false
            }
        }
    }
}
#endregion

#region --- Output ---
$Summary = [PSCustomObject]@{
    Timestamp = (Get-Date -Format 'o')
    Results   = $Results
}

$Summary | ConvertTo-Json -Depth 5 | Out-File "$OutputRoot\Logs\DownloadsSize.json" -Force

if ($NonInteractive) {
    $Summary | ConvertTo-Json -Depth 5
} else {
    Write-Host ""
    Write-Host "Report saved: $OutputRoot\Logs\DownloadsSize.json"
    Write-Host ""
    Read-Host "Press Enter to continue"
}
#endregion
