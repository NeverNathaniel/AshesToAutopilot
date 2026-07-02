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

foreach ($UserProfile in $Profiles) {
    $ProfilePath = $UserProfile.LocalPath
    $ProfileName = Split-Path $ProfilePath -Leaf
    $SID         = $UserProfile.SID

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
        $HiveLoaded = Mount-UserHive -UserProfile $UserProfile
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

        # Find ALL OneDrive account folders — a user can have several accounts
        # (old tenant + new tenant, personal + business) and KFM may target any of
        # them; comparing against only the first produced false NotKFM verdicts.
        $ODPaths = @()
        if (Test-Path $ODAccountsKey) {
            $accounts = Get-ChildItem $ODAccountsKey -ErrorAction SilentlyContinue
            foreach ($acct in $accounts) {
                $props = Get-ItemProperty $acct.PSPath -ErrorAction SilentlyContinue
                if ($props.UserFolder) { $ODPaths += $props.UserFolder }
            }
        }
        $ProfileResult.OneDrivePath = if ($ODPaths.Count -gt 0) { $ODPaths -join '; ' } else { $null }

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

        if ($ODPaths.Count -eq 0) {
            # OneDrive not configured — KFM status is N/A, not "not set up"
            $ProfileResult.KFM_Desktop   = 'OneDriveNotConfigured'
            $ProfileResult.KFM_Documents = 'OneDriveNotConfigured'
            $ProfileResult.KFM_Pictures  = 'OneDriveNotConfigured'
        } elseif (Test-Path $UserShellFoldersKey) {
            $shellProps = Get-ItemProperty $UserShellFoldersKey -ErrorAction SilentlyContinue
            foreach ($kfmProp in $CheckFolders.Keys) {
                $regName   = $CheckFolders[$kfmProp]
                $folderVal = $shellProps.$regName
                # Separator-anchored StartsWith against every account folder: -like
                # would treat [] in the OneDrive path as wildcard sets, and matching
                # only one account misses KFM targeting a second account.
                $inOneDrive = $false
                if ($null -ne $folderVal) {
                    foreach ($odp in $ODPaths) {
                        if ($folderVal.StartsWith("$odp\", [System.StringComparison]::OrdinalIgnoreCase) -or
                            $folderVal.Equals($odp, [System.StringComparison]::OrdinalIgnoreCase)) { $inOneDrive = $true; break }
                    }
                }
                if ($inOneDrive) {
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

$Summary | ConvertTo-Json -Depth 10 | Out-File "$OutputRoot\Logs\Test-OneDriveKFM-Report.json" -Force

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
    Write-Host "Full report: $OutputRoot\Logs\Test-OneDriveKFM-Report.json"
    Write-Host ""
}
#endregion

# KFM issues are graded by the orchestrator (primary profile -> FAIL, secondary -> WARN);
# exit 1 is reserved for crashes per the toolkit I/O contract.
exit 0
