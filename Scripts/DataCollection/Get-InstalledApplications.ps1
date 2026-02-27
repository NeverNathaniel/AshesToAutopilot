<#
.SYNOPSIS
    Exports a comprehensive inventory of all installed applications for reinstallation planning.

.DESCRIPTION
    Enumerates installed software from both 32-bit and 64-bit uninstall registry locations
    (machine-wide and per-user). Filters out noise (Windows updates, runtimes, redistributables).
    Reports DisplayName, Version, Publisher, InstallDate, and installer type (MSI vs EXE).

.PARAMETER NonInteractive
    Suppress all prompts. Output structured JSON to stdout. Exit cleanly.

.EXAMPLE
    .\Get-InstalledApplications.ps1
    .\Get-InstalledApplications.ps1 -NonInteractive

.NOTES
    Source repos used:
    - public-main/Powershell Scripts/list-uninstall-keys.ps1
      (32-bit/64-bit registry uninstall enumeration pattern)

    Requires: Administrator
    Output:   C:\PreWipeOutput\Logs\InstalledApplications-Report.json
#>

[CmdletBinding()]
param(
    [switch]$NonInteractive
)

#region --- Init ---
$ScriptName = 'Get-InstalledApplications'
$OutputRoot = 'C:\PreWipeOutput'
$LogDir     = "$OutputRoot\Logs"
$LogFile    = "$LogDir\$ScriptName.log"
$ErrorLog   = "$OutputRoot\errors.log"

if (-not (Test-Path $OutputRoot)) { New-Item -Path $OutputRoot -ItemType Directory -Force | Out-Null }
if (-not (Test-Path $LogDir))     { New-Item -Path $LogDir     -ItemType Directory -Force | Out-Null }

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

#region --- Noise Filters ---
$NoisePatterns = @(
    'Update for Microsoft*',
    'Security Update for*',
    'Hotfix for Microsoft*',
    'KB[0-9]*',
    'Microsoft Visual C++ 20* Redistributable*',
    'Microsoft .NET*',
    'Microsoft Windows Desktop Runtime*',
    'Microsoft ASP.NET*',
    'Windows SDK*',
    'vs_*',
    'Microsoft Visual Studio Installer*'
)

function Test-IsNoise {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $true }
    foreach ($pattern in $NoisePatterns) {
        if ($Name -like $pattern) { return $true }
    }
    return $false
}
#endregion

#region --- Machine-Wide Applications ---
Write-Log "Enumerating machine-wide installed applications..."
$MachineApps = @()
$RegPaths = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
)

foreach ($regPath in $RegPaths) {
    $is32bit = $regPath -match 'WOW6432Node'
    try {
        $entries = Get-ItemProperty $regPath -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName }
        foreach ($entry in $entries) {
            if (Test-IsNoise $entry.DisplayName) { continue }

            $installerType = 'EXE'
            if ($entry.UninstallString -and $entry.UninstallString -match 'MsiExec') {
                $installerType = 'MSI'
            }

            $MachineApps += [PSCustomObject]@{
                DisplayName     = $entry.DisplayName
                DisplayVersion  = $entry.DisplayVersion
                Publisher       = $entry.Publisher
                InstallDate     = $entry.InstallDate
                InstallLocation = $entry.InstallLocation
                InstallerType   = $installerType
                Architecture    = if ($is32bit) { 'x86' } else { 'x64' }
                Scope           = 'Machine'
            }
        }
    } catch {
        Write-ErrorLog "Error reading $($regPath): $_"
    }
}

# Deduplicate (same app may appear in both 32/64 paths)
$MachineApps = $MachineApps | Sort-Object DisplayName, DisplayVersion -Unique
Write-Log "Found $($MachineApps.Count) machine-wide applications (after filtering)."
#endregion

#region --- Per-User Applications ---
Write-Log "Enumerating per-user installed applications..."
$UserApps = @()

$SkipSIDs   = @('S-1-5-18', 'S-1-5-19', 'S-1-5-20')
$CutoffDate = (Get-Date).AddDays(-30)
$SkipNames  = @('ithlocal', 'itklocal', 'wsi', 'wsiaccount', 'defaultuser0', 'administrator', 'guest')

try {
    $AllProfiles = Get-CimInstance -ClassName Win32_UserProfile -ErrorAction Stop |
        Where-Object { -not $_.Special }

    foreach ($p in $AllProfiles) {
        $sid = $p.SID
        $folderName = Split-Path $p.LocalPath -Leaf
        if ($SkipSIDs -contains $sid) { Write-Log "Skipping system SID: $sid"; continue }
        if ($sid -match '^S-1-5-(18|19|20)$') { Write-Log "Skipping system SID pattern: $sid"; continue }

        if ($SkipNames -contains $folderName.ToLower()) { Write-Log "Skipping service account profile: $folderName"; continue }
        if ($folderName -match 'local$') { Write-Log "Skipping local service account: $folderName"; continue }

        $lastUse = $p.LastUseTime
        if ($null -eq $lastUse -or $lastUse -lt $CutoffDate) { Write-Log "Skipping inactive profile: $folderName (LastUse: $lastUse)"; continue }

        # Load hive if needed
        $HiveLoaded = $false
        if (-not (Test-Path "Registry::HKEY_USERS\$sid")) {
            $NtuserDat = Join-Path $p.LocalPath 'NTUSER.DAT'
            if (Test-Path $NtuserDat) {
                $null = reg load "HKU\$sid" $NtuserDat 2>&1
                $HiveLoaded = $true
                Start-Sleep -Milliseconds 500
            } else {
                continue
            }
        }

        try {
            $userRegPath = "Registry::HKEY_USERS\$sid\Software\Microsoft\Windows\CurrentVersion\Uninstall\*"
            $entries = Get-ItemProperty $userRegPath -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName }
            foreach ($entry in $entries) {
                if (Test-IsNoise $entry.DisplayName) { continue }

                $installerType = 'EXE'
                if ($entry.UninstallString -and $entry.UninstallString -match 'MsiExec') {
                    $installerType = 'MSI'
                }

                $UserApps += [PSCustomObject]@{
                    DisplayName     = $entry.DisplayName
                    DisplayVersion  = $entry.DisplayVersion
                    Publisher       = $entry.Publisher
                    InstallDate     = $entry.InstallDate
                    InstallLocation = $entry.InstallLocation
                    InstallerType   = $installerType
                    Architecture    = 'User'
                    Scope           = "User:$folderName"
                }
            }
        } catch {
            Write-Log "Error reading user apps for $($folderName): $_" 'WARN'
        } finally {
            if ($HiveLoaded) {
                [GC]::Collect()
                Start-Sleep -Milliseconds 200
                $null = reg unload "HKU\$sid" 2>&1
            }
        }
    }
} catch {
    Write-ErrorLog "Profile enumeration failed: $_"
}

Write-Log "Found $($UserApps.Count) per-user applications."
#endregion

#region --- Combine and Sort ---
$AllApps = @($MachineApps) + @($UserApps) | Sort-Object Publisher, DisplayName
$TotalCount = $AllApps.Count
Write-Log "Total applications: $TotalCount"
#endregion

#region --- Output ---
$Result = [PSCustomObject]@{
    Timestamp       = (Get-Date -Format 'o')
    TotalCount      = $TotalCount
    MachineCount    = $MachineApps.Count
    UserCount       = $UserApps.Count
    Applications    = $AllApps
}

$Result | ConvertTo-Json -Depth 5 | Out-File "$LogDir\InstalledApplications-Report.json" -Force

if ($NonInteractive) {
    $Result | ConvertTo-Json -Depth 5
} else {
    Write-Host ""
    Write-Host "=== Installed Applications Inventory ===" -ForegroundColor Cyan
    Write-Host "Machine-wide: $($MachineApps.Count)"
    Write-Host "Per-user:     $($UserApps.Count)"
    Write-Host "Total:        $TotalCount"
    Write-Host ""

    # Group by publisher for readable display
    $ByPublisher = $AllApps | Group-Object Publisher | Sort-Object Name
    foreach ($group in $ByPublisher) {
        $pubName = if ($group.Name) { $group.Name } else { '(Unknown publisher)' }
        Write-Host "  $pubName" -ForegroundColor Yellow
        foreach ($app in ($group.Group | Sort-Object DisplayName)) {
            $ver = if ($app.DisplayVersion) { " v$($app.DisplayVersion)" } else { '' }
            Write-Host "    $($app.DisplayName)$ver [$($app.InstallerType)]"
        }
    }
    Write-Host ""
    Write-Host "Report: $LogDir\InstalledApplications-Report.json"
    Write-Host ""
}
#endregion
