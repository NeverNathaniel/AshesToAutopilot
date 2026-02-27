<#
.SYNOPSIS
    Reports all mapped network drives for each active user profile.

.DESCRIPTION
    For each active user profile (skipping system, inactive 30+ days, ithlocal/itklocal):
    - Reads HKCU registry hive to enumerate mapped network drives.
    - Reports: drive letter, UNC path, persistent (yes/no).

.PARAMETER NonInteractive
    Suppress all prompts. Output structured JSON to stdout. Exit cleanly.

.EXAMPLE
    .\Get-DriveMappings.ps1
    .\Get-DriveMappings.ps1 -NonInteractive

.NOTES
    Source repos used:
    - powershell-scripts-master/SharePointDLMapping.ps1
      (HKCU network drive registry path pattern: HKCU\Network\*)
    No direct multi-profile drive mapping script found; registry path is well-known.

    Requires: Administrator
    Output:   C:\PreWipeOutput\Logs\Get-DriveMappings.log
#>

[CmdletBinding()]
param(
    [switch]$NonInteractive
)

#region --- Init ---
$ScriptName = 'Get-DriveMappings'
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

#region --- Drive Mapping Enumeration ---
$AllResults = @()

foreach ($Profile in $Profiles) {
    $ProfilePath = $Profile.LocalPath
    $ProfileName = Split-Path $ProfilePath -Leaf
    $SID         = $Profile.SID

    Write-Log "Checking drive mappings for: $ProfileName"

    $HiveLoaded = $false
    if (-not (Test-Path "Registry::HKEY_USERS\$SID")) {
        $NtuserDat = Join-Path $ProfilePath 'NTUSER.DAT'
        if (Test-Path $NtuserDat) {
            $null = reg load "HKU\$SID" $NtuserDat 2>&1
            $HiveLoaded = $true
            Start-Sleep -Milliseconds 500
        }
    }

    $Drives = @()
    $NetworkKey = "Registry::HKEY_USERS\$SID\Network"

    if (Test-Path $NetworkKey) {
        $driveMappings = Get-ChildItem $NetworkKey -ErrorAction SilentlyContinue
        foreach ($drive in $driveMappings) {
            try {
                $props      = Get-ItemProperty $drive.PSPath -ErrorAction SilentlyContinue
                $letter     = $drive.PSChildName
                $remotePath = $props.RemotePath
                $persistent = if ($props.ConnectionType -eq 1) { $true } else { $false }

                $Drives += [PSCustomObject]@{
                    DriveLetter = "$letter`:"
                    UNCPath     = $remotePath
                    Persistent  = $persistent
                    UserName    = $props.UserName
                }
                Write-Log "  $letter`: -> $remotePath (Persistent: $persistent)"
            } catch {
                Write-ErrorLog "Error reading drive $($drive.PSChildName) for $ProfileName : $_"
            }
        }
    } else {
        Write-Log "  No Network drives key found for $ProfileName"
    }

    if ($HiveLoaded) {
        [GC]::Collect(); Start-Sleep -Milliseconds 200
        $null = reg unload "HKU\$SID" 2>&1
    }

    $AllResults += [PSCustomObject]@{
        Profile    = $ProfileName
        SID        = $SID
        DriveCount = $Drives.Count
        Drives     = $Drives
    }
}
#endregion

#region --- Output ---
$Summary = [PSCustomObject]@{
    Timestamp = (Get-Date -Format 'o')
    Results   = $AllResults
}

$Summary | ConvertTo-Json -Depth 5 | Out-File "$OutputRoot\Logs\DriveMappings-Report.json" -Force

if ($NonInteractive) {
    $Summary | ConvertTo-Json -Depth 5
} else {
    Write-Host ""
    Write-Host "=== Network Drive Mappings ===" -ForegroundColor Cyan
    foreach ($r in $AllResults) {
        Write-Host "  $($r.Profile): $($r.DriveCount) drive(s)"
        foreach ($d in $r.Drives) {
            Write-Host "    $($d.DriveLetter) -> $($d.UNCPath) [Persistent: $($d.Persistent)]"
        }
    }
    Write-Host ""
    Write-Host "Report: $OutputRoot\Logs\DriveMappings-Report.json"
    Write-Host ""
}
#endregion
