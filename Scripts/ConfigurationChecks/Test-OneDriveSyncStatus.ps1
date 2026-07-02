<#
.SYNOPSIS
    Confirms OneDrive sync is actually complete before approving wipe.

.DESCRIPTION
    Goes beyond KFM configuration checks to verify OneDrive account sign-in and
    initial-sync completion for each user profile, plus whether the OneDrive process
    is running. Pending uploads are NOT knowable from the registry, so the verdict
    fails closed: a profile is only SafeToWipe when a signed-in account has completed
    its first sync AND OneDrive is running. Returns a go/no-go verdict for wipe safety.

.PARAMETER NonInteractive
    Suppress all prompts. Output structured JSON to stdout. Exit cleanly.

.EXAMPLE
    .\Test-OneDriveSyncStatus.ps1
    .\Test-OneDriveSyncStatus.ps1 -NonInteractive

.NOTES
    Source repos used:
    - No external source repo (uses OneDrive registry paths documented in
      Microsoft OneDrive deployment docs; profile enumeration and hive loading
      patterns consistent with LazyAdmin-master/Office365/OneDriveSizeReport.ps1)

    Requires: Administrator
    Output:   C:\PreWipeOutput\Logs\Test-OneDriveSyncStatus-Report.json
#>

[CmdletBinding()]
param(
    [switch]$NonInteractive
)

#region --- Init ---
$ScriptName = 'Test-OneDriveSyncStatus'
. (Join-Path $PSScriptRoot '..\Common\Initialize-Toolkit.ps1')
. (Join-Path $PSScriptRoot '..\Common\Get-ActiveUserProfile.ps1')
$LogFile = "$LogDir\$ScriptName.log"
if (-not (Test-AdminElevation)) { exit 1 }
#endregion

#region --- Profile Enumeration ---
$Profiles = @(Get-ActiveUserProfile)
Write-Log "Active profiles to check: $($Profiles.Count)"
#endregion

#region --- OneDrive Process Check ---
$OneDriveRunning = $false
try {
    $odProcesses = Get-Process -Name 'OneDrive' -ErrorAction SilentlyContinue
    if ($odProcesses) {
        $OneDriveRunning = $true
        Write-Log "OneDrive process is running ($($odProcesses.Count) instance(s))."
    } else {
        Write-Log "OneDrive process is NOT running - sync status may be stale." 'WARN'
    }
} catch {
    Write-Log "Could not check OneDrive process: $_" 'WARN'
}
#endregion

#region --- Per-Profile Sync Check ---
$Results = @()

foreach ($Profile in $Profiles) {
    $ProfilePath = $Profile.LocalPath
    $ProfileName = Split-Path $ProfilePath -Leaf
    $SID         = $Profile.SID

    Write-Log "Checking OneDrive sync status for: $ProfileName"

    $ProfileResult = [PSCustomObject]@{
        Profile          = $ProfileName
        ProfilePath      = $ProfilePath
        SID              = $SID
        OneDriveConfigured = $false
        Accounts         = @()
        SyncEngines      = @()
        OverallStatus    = 'Unknown'
        SafeToWipe       = $false
        Issues           = @()
    }

    $HiveLoaded = $false
    try {
        $HiveLoaded = Mount-UserHive -UserProfile $Profile
        if (-not $HiveLoaded -and -not (Test-Path "Registry::HKEY_USERS\$SID")) {
            $ProfileResult.Issues += 'No NTUSER.DAT found'
            $Results += $ProfileResult
            continue
        }

        $ODAccountsKey = "Registry::HKEY_USERS\$SID\Software\Microsoft\OneDrive\Accounts"

        # Check OneDrive accounts
        if (Test-Path $ODAccountsKey) {
            $ProfileResult.OneDriveConfigured = $true
            $accounts = Get-ChildItem $ODAccountsKey -ErrorAction SilentlyContinue

            foreach ($acct in $accounts) {
                $props = Get-ItemProperty $acct.PSPath -ErrorAction SilentlyContinue
                if (-not $props) { continue }
                # Skip subkeys that aren't signed-in accounts (no UserEmail = not a real account)
                if (-not $props.UserEmail) { continue }

                # OneDrive does NOT write a 'LastKnownState' DWORD (see Test-OneDriveKFM).
                # The reliable registry signals are UserEmail (signed in) and
                # ClientFirstSyncCompleted (initial sync finished).
                $syncState = if ($props.ClientFirstSyncCompleted -eq 1) { 'Configured' } else { 'FirstSyncNotCompleted' }

                $acctInfo = [PSCustomObject]@{
                    AccountName = $acct.PSChildName
                    UserFolder  = $props.UserFolder
                    UserEmail   = $props.UserEmail
                    SyncState   = $syncState
                }

                $ProfileResult.Accounts += $acctInfo

                if ($syncState -ne 'Configured') {
                    $ProfileResult.Issues += "Account '$($acct.PSChildName)' has not completed its initial sync"
                }
            }
        }

        # Check SyncEngines for mounted libraries and their status
        $SyncEnginesKey = "Registry::HKEY_USERS\$SID\Software\SyncEngines\Providers\OneDrive"
        if (Test-Path $SyncEnginesKey) {
            $engines = Get-ChildItem $SyncEnginesKey -ErrorAction SilentlyContinue
            foreach ($engine in $engines) {
                $eProps = Get-ItemProperty $engine.PSPath -ErrorAction SilentlyContinue
                if ($eProps) {
                    $ProfileResult.SyncEngines += [PSCustomObject]@{
                        LibraryType   = $eProps.LibraryType
                        MountPoint    = $eProps.MountPoint
                        UrlNamespace  = $eProps.UrlNamespace
                    }
                }
            }
        }

        # Determine overall status for this profile. Fail closed: this is a wipe gate,
        # and an unverifiable sync state must never read as safe.
        if (-not $ProfileResult.OneDriveConfigured) {
            $ProfileResult.OverallStatus = 'NotConfigured'
            $ProfileResult.Issues += 'OneDrive not configured'
        } elseif ($ProfileResult.Accounts.Count -eq 0) {
            $ProfileResult.OverallStatus = 'NoAccountSignedIn'
            $ProfileResult.Issues += 'OneDrive present but no account is signed in'
        } elseif ($ProfileResult.Issues.Count -eq 0) {
            if ($OneDriveRunning) {
                $ProfileResult.OverallStatus = 'Configured'
                $ProfileResult.SafeToWipe = $true
            } else {
                $ProfileResult.OverallStatus = 'ProcessNotRunning'
                $ProfileResult.Issues += 'OneDrive process not running — sync currency cannot be verified; start OneDrive and let it finish syncing'
            }
        } else {
            $ProfileResult.OverallStatus = 'NotReady'
        }

    } catch {
        Write-ErrorLog "Error checking profile $($ProfileName): $_"
        $ProfileResult.Issues += "Error: $_"
    } finally {
        if ($HiveLoaded) { Dismount-UserHive -SID $SID }
    }

    $Results += $ProfileResult
    Write-Log "Done: $ProfileName | Status=$($ProfileResult.OverallStatus) | Safe=$($ProfileResult.SafeToWipe)"
}
#endregion

#region --- Overall Verdict ---
$AllSafe = $true
$AllIssues = @()
foreach ($r in $Results) {
    if (-not $r.SafeToWipe) { $AllSafe = $false }
    $AllIssues += $r.Issues
}

if ($Results.Count -eq 0) {
    $OverallVerdict = 'NO_PROFILES'
} elseif ($AllSafe) {
    $OverallVerdict = 'SAFE_TO_WIPE'
} else {
    $OverallVerdict = 'NOT_SAFE'
}

Write-Log "Overall sync verdict: $OverallVerdict"
#endregion

#region --- Output ---
$Result = [PSCustomObject]@{
    Timestamp        = (Get-Date -Format 'o')
    OneDriveRunning  = $OneDriveRunning
    ProfilesChecked  = $Results.Count
    OverallVerdict   = $OverallVerdict
    AllIssues        = $AllIssues
    Profiles         = $Results
}

$Result | ConvertTo-Json -Depth 10 | Out-File "$LogDir\Test-OneDriveSyncStatus-Report.json" -Force

if ($NonInteractive) {
    $Result | ConvertTo-Json -Depth 10
} else {
    Write-Host ""
    Write-Host "=== OneDrive Sync Status ===" -ForegroundColor Cyan
    $verdictColor = switch ($OverallVerdict) { 'SAFE_TO_WIPE' { 'Green' } 'NOT_SAFE' { 'Red' } default { 'Yellow' } }
    Write-Host "Verdict: $OverallVerdict" -ForegroundColor $verdictColor
    if (-not $OneDriveRunning) {
        Write-Host "WARNING: OneDrive process not running - status may be stale" -ForegroundColor Yellow
    }
    Write-Host ""

    foreach ($r in $Results) {
        $color = if ($r.SafeToWipe) { 'Green' } else { 'Red' }
        Write-Host "  $($r.Profile): $($r.OverallStatus)" -ForegroundColor $color
        foreach ($a in $r.Accounts) {
            Write-Host "    Account: $($a.AccountName) - $($a.SyncState)"
        }
        if ($r.Issues.Count -gt 0) {
            foreach ($issue in $r.Issues) {
                Write-Host "    ISSUE: $issue" -ForegroundColor Red
            }
        }
    }

    Write-Host ""
    Write-Host "Report: $LogDir\Test-OneDriveSyncStatus-Report.json"
    Write-Host ""
}
#endregion

# NOT_SAFE severity is graded by the orchestrator (primary profile -> FAIL, secondary -> WARN);
# exit 1 is reserved for crashes per the toolkit I/O contract.
exit 0
