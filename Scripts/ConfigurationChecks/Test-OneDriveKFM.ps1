<#
.SYNOPSIS
    Reports OneDrive Known Folder Move (KFM) status and sync health for all active user profiles.

.DESCRIPTION
    For each active user profile (skipping system, inactive 30+ days, ithlocal/itklocal):
    - Checks if KFM is configured for Desktop, Documents, Pictures.
    - Checks OneDrive sync status via registry keys.
    - Reports per-profile: KFM status per folder, sync status, any issues.

.PARAMETER NonInteractive
    Suppress all prompts. Output structured JSON to stdout. Exit cleanly.

.EXAMPLE
    .\Test-OneDriveKFM.ps1
    .\Test-OneDriveKFM.ps1 -NonInteractive

.NOTES
    Source repos used:
    - public-main/Powershell Scripts/EnableAutoConfig_Onedrive.ps1
      (OneDrive registry key paths and KFM configuration reference)
    - LazyAdmin-master/Office365/OneDriveSizeReport.ps1
      (user profile enumeration patterns)
    - Office365itpros-master/ (OneDrive provisioning patterns)
    No direct KFM-check script found in source repos; implemented using known
    registry paths documented in Microsoft OneDrive deployment docs.

    Requires: Administrator
    Output:   C:\PreWipeOutput\Logs\Test-OneDriveKFM.log
#>

[CmdletBinding()]
param(
    [switch]$NonInteractive
)

#region --- Init ---
$ScriptName = 'Test-OneDriveKFM'
. (Join-Path $PSScriptRoot '..\Common\Initialize-Toolkit.ps1')
. (Join-Path $PSScriptRoot '..\Common\Get-ActiveUserProfile.ps1')
$LogFile = "$LogDir\$ScriptName.log"
if (-not (Test-AdminElevation)) { exit 1 }
#endregion

#region --- Profile Enumeration ---
$Profiles = @(Get-ActiveUserProfile)
Write-Log "Active profiles to check: $($Profiles.Count)"
#endregion

#region --- KFM / Sync Check ---
$Results = @()

foreach ($Profile in $Profiles) {
    $ProfilePath = $Profile.LocalPath
    $ProfileName = Split-Path $ProfilePath -Leaf
    $SID         = $Profile.SID

    Write-Log "Checking OneDrive KFM for profile: $ProfileName ($ProfilePath)"

    $ProfileResult = [PSCustomObject]@{
        Profile        = $ProfileName
        ProfilePath    = $ProfilePath
        SID            = $SID
        KFM_Desktop    = 'Unknown'
        KFM_Documents  = 'Unknown'
        KFM_Pictures   = 'Unknown'
        SyncStatus     = 'Unknown'
        OneDrivePath   = $null
        Issues         = @()
    }

    try {
        # Load the user's registry hive if not already loaded
        $HiveLoaded = Mount-UserHive -UserProfile $Profile
        if (-not $HiveLoaded -and -not (Test-Path "Registry::HKEY_USERS\$SID")) {
            Write-Log "No NTUSER.DAT found for $ProfileName, skipping registry checks." 'WARN'
            $ProfileResult.Issues += 'No NTUSER.DAT found'
            $Results += $ProfileResult
            continue
        }

        # OneDrive KFM registry keys
        # HKCU\Software\Microsoft\OneDrive\Accounts\{AccountName}\ScopeIdToMountPointPathCache
        # KFM tracked by: HKCU\Software\Microsoft\OneDrive\Accounts\*\KFMState
        # Backup/Sync status: HKCU\Software\Microsoft\OneDrive\Accounts\*\LastKnownState

        $ODAccountsKey = "Registry::HKEY_USERS\$SID\Software\Microsoft\OneDrive\Accounts"

        # Known folder GUIDs for KFM
        $KnownFolderGUIDs = @{
            Desktop   = '{B4BFCC3A-DB2C-424C-B029-7FE99A87C641}'
            Documents = '{FDD39AD0-238F-46AF-ADB4-6C85480369C7}'
            Pictures  = '{33E28130-4E1E-4676-835A-98395C3BC3BB}'
        }

        # Find OneDrive path from registry
        $ODPath = $null
        if (Test-Path $ODAccountsKey) {
            $accounts = Get-ChildItem $ODAccountsKey -ErrorAction SilentlyContinue
            foreach ($acct in $accounts) {
                $props = Get-ItemProperty $acct.PSPath -ErrorAction SilentlyContinue
                if ($props.UserFolder) {
                    $ODPath = $props.UserFolder
                    break
                }
            }
        }
        $ProfileResult.OneDrivePath = $ODPath

        # Check KFM by examining if known folder shell locations point into OneDrive
        $UserShellFoldersKey = "Registry::HKEY_USERS\$SID\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders"

        $CheckFolders = @{
            KFM_Desktop   = 'Desktop'
            KFM_Documents = 'Personal'
            KFM_Pictures  = 'My Pictures'
        }

        $RegFolderNames = @{
            'Desktop'     = 'Desktop'
            'Personal'    = 'Documents'
            'My Pictures' = 'Pictures'
        }

        if (-not $ODPath) {
            # OneDrive not configured — KFM status is N/A, not "not set up"
            $ProfileResult.KFM_Desktop   = 'OneDriveNotConfigured'
            $ProfileResult.KFM_Documents = 'OneDriveNotConfigured'
            $ProfileResult.KFM_Pictures  = 'OneDriveNotConfigured'
        } elseif (Test-Path $UserShellFoldersKey) {
            $shellProps = Get-ItemProperty $UserShellFoldersKey -ErrorAction SilentlyContinue
            foreach ($kfmProp in $CheckFolders.Keys) {
                $regName   = $CheckFolders[$kfmProp]
                $folderVal = $shellProps.$regName
                if ($null -ne $folderVal -and $folderVal -like "$ODPath*") {
                    $ProfileResult.$kfmProp = 'Enabled'
                } elseif ($null -ne $folderVal) {
                    $ProfileResult.$kfmProp = "NotKFM ($folderVal)"
                    $ProfileResult.Issues  += "$($RegFolderNames[$regName]) not backed up to OneDrive"
                } else {
                    $ProfileResult.$kfmProp = 'NotFound'
                }
            }
        } else {
            $ProfileResult.Issues += 'User Shell Folders registry key not accessible'
        }

        # Sync status: check OneDrive account sign-in and initial sync completion.
        # OneDrive does NOT write a "LastKnownState" DWORD — use ClientFirstSyncCompleted
        # and UserEmail presence instead, which are the actual values written to:
        #   HKCU\Software\Microsoft\OneDrive\Accounts\{AccountName}\
        if (Test-Path $ODAccountsKey) {
            $accounts   = Get-ChildItem $ODAccountsKey -ErrorAction SilentlyContinue
            $syncStates = @()
            foreach ($acct in $accounts) {
                $props = Get-ItemProperty $acct.PSPath -ErrorAction SilentlyContinue
                # Skip subkeys that aren't real accounts (no UserEmail = not a signed-in account)
                if (-not $props.UserEmail) { continue }

                if ($props.ClientFirstSyncCompleted -eq 1) {
                    $stateStr = 'Synced'
                } elseif ($null -ne $props.ClientFirstSyncCompleted) {
                    $stateStr = 'SyncPending'
                    $ProfileResult.Issues += "OneDrive initial sync not completed for account $($acct.PSChildName)"
                } else {
                    $stateStr = 'SyncStatusUnknown'
                }
                $syncStates += "$($acct.PSChildName):$stateStr"
            }
            $ProfileResult.SyncStatus = if ($syncStates) { $syncStates -join '; ' } else { 'NoAccountSignedIn' }
        } else {
            $ProfileResult.SyncStatus = 'OneDriveNotConfigured'
            $ProfileResult.Issues    += 'OneDrive not configured for this profile'
        }

    } catch {
        Write-ErrorLog "Error checking profile $ProfileName : $_"
        $ProfileResult.Issues += "Error: $_"
    } finally {
        if ($HiveLoaded) { Dismount-UserHive -SID $SID }
    }

    $Results += $ProfileResult
    Write-Log "Done: $ProfileName | Desktop=$($ProfileResult.KFM_Desktop) | Docs=$($ProfileResult.KFM_Documents) | Pics=$($ProfileResult.KFM_Pictures) | Sync=$($ProfileResult.SyncStatus)"
}
#endregion

#region --- Output ---
$Summary = [PSCustomObject]@{
    Timestamp      = (Get-Date -Format 'o')
    ProfilesChecked = $Results.Count
    Results        = $Results
}

$Summary | ConvertTo-Json -Depth 10 | Out-File "$OutputRoot\Logs\OneDriveKFM-Report.json" -Force

$anyKfmIssue = $Results | Where-Object { $_.Issues.Count -gt 0 }

if ($NonInteractive) {
    $Summary | ConvertTo-Json -Depth 10
} else {
    Write-Host ""
    Write-Host "=== OneDrive KFM Status ===" -ForegroundColor Cyan
    foreach ($r in $Results) {
        $hasIssues = $r.Issues.Count -gt 0
        $lineColor = if ($hasIssues) { 'Yellow' } else { 'Green' }
        $issueStr  = if ($hasIssues) { " ISSUES: $($r.Issues -join '; ')" } else { '' }
        Write-Host "  $($r.Profile): Desktop=$($r.KFM_Desktop) | Docs=$($r.KFM_Documents) | Pics=$($r.KFM_Pictures) | Sync=$($r.SyncStatus)$issueStr" -ForegroundColor $lineColor
    }
    Write-Host ""
    Write-Host "Full report: $OutputRoot\Logs\OneDriveKFM-Report.json"
    Write-Host ""
}
#endregion

if ($anyKfmIssue) { exit 1 }

exit 0
