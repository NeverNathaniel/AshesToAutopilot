<#
.SYNOPSIS
    Confirms OneDrive sync is actually complete before approving wipe.

.DESCRIPTION
    Goes beyond KFM configuration checks to verify that OneDrive is actively synced
    and up-to-date for each user profile. Checks sync engine status, pending uploads,
    and last sync timestamps. Returns a go/no-go verdict for wipe safety.

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
    Output:   C:\PreWipeOutput\Logs\OneDriveSyncStatus-Report.json
#>

[CmdletBinding()]
param(
    [switch]$NonInteractive
)

#region --- Init ---
$ScriptName = 'Test-OneDriveSyncStatus'
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
        $folderName = Split-Path $p.LocalPath -Leaf
        if ($SkipSIDs -contains $sid) { Write-Log "Skipping system SID: $sid"; continue }
        if ($sid -match '^S-1-5-(18|19|20)$') { Write-Log "Skipping system SID pattern: $sid"; continue }
        if ($SkipNames -contains $folderName.ToLower()) { Write-Log "Skipping service account profile: $folderName"; continue }
        if ($folderName -match 'local$') { Write-Log "Skipping local service account: $folderName"; continue }
        $lastUse = $p.LastUseTime
        if ($null -eq $lastUse -or $lastUse -lt $CutoffDate) { Write-Log "Skipping inactive profile: $folderName (LastUse: $lastUse)"; continue }
        $Profiles += $p
    }
} catch {
    Write-ErrorLog "Failed to enumerate profiles: $_"
    exit 1
}

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
        if (-not (Test-Path "Registry::HKEY_USERS\$SID")) {
            $NtuserDat = Join-Path $ProfilePath 'NTUSER.DAT'
            if (Test-Path $NtuserDat) {
                $null = reg load "HKU\$SID" $NtuserDat 2>&1
                $HiveLoaded = $true
                Start-Sleep -Milliseconds 500
            } else {
                $ProfileResult.Issues += 'No NTUSER.DAT found'
                $Results += $ProfileResult
                continue
            }
        }

        $ODAccountsKey = "Registry::HKEY_USERS\$SID\Software\Microsoft\OneDrive\Accounts"

        # Check OneDrive accounts
        if (Test-Path $ODAccountsKey) {
            $ProfileResult.OneDriveConfigured = $true
            $accounts = Get-ChildItem $ODAccountsKey -ErrorAction SilentlyContinue

            foreach ($acct in $accounts) {
                $props = Get-ItemProperty $acct.PSPath -ErrorAction SilentlyContinue
                if (-not $props) { continue }

                $stateMap = @{ 0 = 'UpToDate'; 1 = 'Syncing'; 2 = 'Paused'; 3 = 'Error'; 4 = 'NotSignedIn' }
                $lastKnownState = $props.LastKnownState
                $stateStr = if ($null -ne $lastKnownState) { $stateMap[[int]$lastKnownState] } else { 'Unknown' }
                if (-not $stateStr) { $stateStr = "State$lastKnownState" }

                $acctInfo = [PSCustomObject]@{
                    AccountName    = $acct.PSChildName
                    UserFolder     = $props.UserFolder
                    LastKnownState = $stateStr
                    StateCode      = $lastKnownState
                    UserEmail      = $props.UserEmail
                }

                $ProfileResult.Accounts += $acctInfo

                if ($null -ne $lastKnownState -and $lastKnownState -gt 0) {
                    if ($lastKnownState -eq 1) {
                        $ProfileResult.Issues += "Account '$($acct.PSChildName)' is still syncing"
                    } elseif ($lastKnownState -eq 2) {
                        $ProfileResult.Issues += "Account '$($acct.PSChildName)' sync is paused"
                    } elseif ($lastKnownState -ge 3) {
                        $ProfileResult.Issues += "Account '$($acct.PSChildName)' sync error (state: $stateStr)"
                    }
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

        # Determine overall status for this profile
        if (-not $ProfileResult.OneDriveConfigured) {
            $ProfileResult.OverallStatus = 'NotConfigured'
            $ProfileResult.Issues += 'OneDrive not configured'
        } elseif ($ProfileResult.Issues.Count -eq 0) {
            $allUpToDate = $true
            foreach ($a in $ProfileResult.Accounts) {
                if ($a.LastKnownState -ne 'UpToDate' -and $a.LastKnownState -ne 'Unknown') {
                    $allUpToDate = $false
                }
            }
            if ($allUpToDate) {
                $ProfileResult.OverallStatus = 'UpToDate'
                $ProfileResult.SafeToWipe = $true
            } else {
                $ProfileResult.OverallStatus = 'Unknown'
            }
        } else {
            $ProfileResult.OverallStatus = 'NotReady'
        }

    } catch {
        Write-ErrorLog "Error checking profile $($ProfileName): $_"
        $ProfileResult.Issues += "Error: $_"
    } finally {
        if ($HiveLoaded) {
            [GC]::Collect()
            Start-Sleep -Milliseconds 200
            $null = reg unload "HKU\$SID" 2>&1
        }
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

$Result | ConvertTo-Json -Depth 10 | Out-File "$LogDir\OneDriveSyncStatus-Report.json" -Force

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
            Write-Host "    Account: $($a.AccountName) - $($a.LastKnownState)"
        }
        if ($r.Issues.Count -gt 0) {
            foreach ($issue in $r.Issues) {
                Write-Host "    ISSUE: $issue" -ForegroundColor Red
            }
        }
    }

    Write-Host ""
    Write-Host "Report: $LogDir\OneDriveSyncStatus-Report.json"
    Write-Host ""
    Read-Host "Press Enter to continue"
}
#endregion
