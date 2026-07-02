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
    Output:   C:\PreWipeOutput\Logs\Get-InstalledApplications-Report.json
#>

[CmdletBinding()]
param(
    [switch]$NonInteractive
)

#region --- Init ---
$ScriptName = 'Get-InstalledApplications'
. (Join-Path $PSScriptRoot '..\Common\Initialize-Toolkit.ps1')
. (Join-Path $PSScriptRoot '..\Common\Get-ActiveUserProfile.ps1')
$LogFile = "$LogDir\$ScriptName.log"
if (-not (Test-AdminElevation)) { exit 1 }
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

#region --- Standard App Patterns ---
$StandardAppPatterns = @(
    '*Microsoft Office*', '*Microsoft 365*', '*Microsoft OneDrive*',
    '*.NET*', '*Visual C++*', '*Visual Studio*', '*Windows*',
    '*Google Chrome*', '*Microsoft Edge*', '*Brave*', '*Mozilla Firefox*',
    '*Dell*', '*SentinelOne*', '*Adobe Reader*', '*Adobe Acrobat Reader*',
    '*Intel*Driver*', '*Realtek*', '*NVIDIA*', '*AMD*Driver*',
    '*Windows SDK*', '*Teams*', '*Zoom*', '*Slack*', '*Webex*'
)

function Test-IsStandardApp {
    param([string]$Name)
    foreach ($pattern in $StandardAppPatterns) {
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

$Profiles = @(Get-ActiveUserProfile)
Write-Log "Active profiles to check: $($Profiles.Count)"

foreach ($p in $Profiles) {
    $sid        = $p.SID
    $folderName = Split-Path $p.LocalPath -Leaf

    $HiveLoaded = Mount-UserHive -UserProfile $p

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
        if ($HiveLoaded) { Dismount-UserHive -SID $sid }
    }
}

Write-Log "Found $($UserApps.Count) per-user applications."
#endregion

#region --- Combine and Sort ---
$AllApps = @($MachineApps) + @($UserApps) | Sort-Object DisplayName -Unique

$NonStandardApps = @($AllApps | Where-Object { -not (Test-IsStandardApp $_.DisplayName) } | Sort-Object Publisher, DisplayName)
$StandardApps    = @($AllApps | Where-Object {      (Test-IsStandardApp $_.DisplayName) } | Sort-Object Publisher, DisplayName)
$TotalCount      = $AllApps.Count
Write-Log "Total: $TotalCount ($($NonStandardApps.Count) non-standard, $($StandardApps.Count) standard)"
#endregion

#region --- Output ---
$Result = [PSCustomObject]@{
    Timestamp        = (Get-Date -Format 'o')
    TotalCount       = $TotalCount
    MachineCount     = $MachineApps.Count
    UserCount        = $UserApps.Count
    NonStandardCount = $NonStandardApps.Count
    StandardCount    = $StandardApps.Count
    NonStandardApps  = $NonStandardApps
    StandardApps     = $StandardApps
    Applications     = $AllApps
}

$Result | ConvertTo-Json -Depth 5 | Out-File "$LogDir\Get-InstalledApplications-Report.json" -Force

if ($NonInteractive) {
    $Result | ConvertTo-Json -Depth 5
} else {
    Write-Host ""
    Write-Host "=== Installed Applications ===" -ForegroundColor Cyan
    Write-Host "  Total:        $TotalCount ($($NonStandardApps.Count) non-standard, $($StandardApps.Count) standard)"
    Write-Host ""
    if ($NonStandardApps.Count -gt 0) {
        Write-Host "  --- Non-Standard Applications ($($NonStandardApps.Count)) ---" -ForegroundColor Yellow
        $byPub = $NonStandardApps | Group-Object Publisher | Sort-Object Name
        foreach ($group in $byPub) {
            $pubName = if ($group.Name) { $group.Name } else { '(Unknown publisher)' }
            Write-Host "  $pubName" -ForegroundColor Yellow
            foreach ($app in ($group.Group | Sort-Object DisplayName)) {
                $ver = if ($app.DisplayVersion) { " v$($app.DisplayVersion)" } else { '' }
                Write-Host "    $($app.DisplayName)$ver [$($app.InstallerType)]"
            }
        }
        Write-Host ""
    }
    if ($StandardApps.Count -gt 0) {
        Write-Host "  --- Standard Applications ($($StandardApps.Count)) ---" -ForegroundColor DarkGray
        $byPub = $StandardApps | Group-Object Publisher | Sort-Object Name
        foreach ($group in $byPub) {
            $pubName = if ($group.Name) { $group.Name } else { '(Unknown publisher)' }
            Write-Host "  $pubName" -ForegroundColor DarkGray
            foreach ($app in ($group.Group | Sort-Object DisplayName)) {
                $ver = if ($app.DisplayVersion) { " v$($app.DisplayVersion)" } else { '' }
                Write-Host "    $($app.DisplayName)$ver [$($app.InstallerType)]" -ForegroundColor DarkGray
            }
        }
    }
    Write-Host ""
    Write-Host "Report: $LogDir\Get-InstalledApplications-Report.json"
    Write-Host ""
}
#endregion

exit 0
