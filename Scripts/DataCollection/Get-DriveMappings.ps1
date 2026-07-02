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
. (Join-Path $PSScriptRoot '..\Common\Initialize-Toolkit.ps1')
. (Join-Path $PSScriptRoot '..\Common\Get-ActiveUserProfile.ps1')
$LogFile = "$LogDir\$ScriptName.log"
if (-not (Test-AdminElevation)) { exit 1 }
#endregion

#region --- Profile Enumeration ---
$Profiles = @(Get-ActiveUserProfile)
Write-Log "Active profiles: $($Profiles.Count)"
#endregion

#region --- Drive Mapping Enumeration ---
$AllResults = @()

foreach ($UserProfile in $Profiles) {
    $ProfilePath = $UserProfile.LocalPath
    $ProfileName = Split-Path $ProfilePath -Leaf
    $SID         = $UserProfile.SID

    Write-Log "Checking drive mappings for: $ProfileName"

    $HiveLoaded = $false
    try {
        $HiveLoaded = Mount-UserHive -UserProfile $UserProfile

        $NetworkKey = "Registry::HKEY_USERS\$SID\Network"

        if (Test-Path $NetworkKey) {
            $driveMappings = Get-ChildItem $NetworkKey -ErrorAction SilentlyContinue
            foreach ($drive in $driveMappings) {
                try {
                    $props      = Get-ItemProperty $drive.PSPath -ErrorAction SilentlyContinue
                    $letter     = $drive.PSChildName
                    $remotePath = $props.RemotePath
                    $persistent = if ($props.ConnectionType -eq 1) { $true } else { $false }

                    # One flat record per mapping — the report/summary consumers count and
                    # tabulate Results as per-mapping rows, not per-profile groups.
                    $AllResults += [PSCustomObject]@{
                        Profile     = $ProfileName
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
    } finally {
        if ($HiveLoaded) { Dismount-UserHive -SID $SID }
    }
}
#endregion

#region --- Output ---
$Summary = [PSCustomObject]@{
    Timestamp    = (Get-Date -Format 'o')
    ProfileCount = $Profiles.Count
    Results      = $AllResults
}

$Summary | ConvertTo-Json -Depth 5 | Out-File "$OutputRoot\Logs\Get-DriveMappings-Report.json" -Force

if ($NonInteractive) {
    $Summary | ConvertTo-Json -Depth 5
} else {
    Write-Host ""
    Write-Host "=== Network Drive Mappings ===" -ForegroundColor Cyan
    Write-Host "  $($AllResults.Count) mapping(s) across $($Profiles.Count) profile(s)"
    foreach ($d in $AllResults) {
        Write-Host "    [$($d.Profile)] $($d.DriveLetter) -> $($d.UNCPath) [Persistent: $($d.Persistent)]"
    }
    Write-Host ""
    Write-Host "Report: $OutputRoot\Logs\Get-DriveMappings-Report.json"
    Write-Host ""
}
#endregion

exit 0
