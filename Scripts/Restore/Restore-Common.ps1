<#
.SYNOPSIS
    Shared helpers for the post-wipe restore scripts (Scripts\Restore\).

.DESCRIPTION
    Dot-source this after Initialize-Toolkit.ps1. Provides:
    - backup discovery (Get-BackupReport, Get-BackupProfileNames)
    - source-profile selection (Select-SourceProfile)
    - PURE plan builders (New-DriveMappingPlan, New-PrinterPlan, New-BookmarkPlan)
      that turn backup data into restore plans without touching the system,
      so the decision logic is unit-testable on any OS (Tests\Test-RestoreLogic.ps1)
    - result helpers (New-RestoreItem, Get-RestoreStagingDir)

    Restore item actions:
      Restored - the thing was applied to this device and verified by exit code
      Staged   - copied to Desktop\RestoredData for a manual step (with a reason)
      Skipped  - intentionally not attempted (with a reason)
      Failed   - attempted and did not work
#>

function Get-BackupReport {
    param(
        [Parameter(Mandatory)][string]$BackupRoot,
        [Parameter(Mandatory)][string]$BaseName
    )
    $p = Join-Path $BackupRoot "Logs\$BaseName-Report.json"
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    try { return Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
}

# Profiles that have any per-user backup folder in the backup root.
function Get-BackupProfileNames {
    param([Parameter(Mandatory)][string]$BackupRoot)
    $names = @()
    foreach ($folder in @('Bookmarks', 'Signatures', 'Wallpaper', 'Taskbar')) {
        $p = Join-Path $BackupRoot $folder
        if (Test-Path -LiteralPath $p) {
            foreach ($d in (Get-ChildItem -LiteralPath $p -Directory -ErrorAction SilentlyContinue)) {
                if ($names -notcontains $d.Name) { $names += $d.Name }
            }
        }
    }
    # Drive mappings carry profile names in the report JSON too.
    $dm = Get-BackupReport -BackupRoot $BackupRoot -BaseName 'Get-DriveMappings'
    if ($dm -and $dm.Results) {
        foreach ($r in @($dm.Results)) {
            if ($r.Profile -and $names -notcontains $r.Profile) { $names += $r.Profile }
        }
    }
    return @($names | Sort-Object)
}

# Pure. Picks which backed-up profile's data to restore for the current user.
# Fail closed: ambiguity returns $null so the caller can list candidates instead
# of silently restoring the wrong user's data.
function Select-SourceProfile {
    param(
        [string[]]$Candidates = @(),
        [string]$Requested,
        [string]$CurrentUserName
    )
    $Candidates = @($Candidates)
    if ($Requested) {
        $match = $Candidates | Where-Object { $_ -ieq $Requested } | Select-Object -First 1
        return $match # $null when the requested profile is not in the backup
    }
    if ($CurrentUserName) {
        $match = $Candidates | Where-Object { $_ -ieq $CurrentUserName } | Select-Object -First 1
        if ($match) { return $match }
    }
    if ($Candidates.Count -eq 1) { return $Candidates[0] }
    return $null
}

function New-RestoreItem {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('Restored', 'Staged', 'Skipped', 'Failed')][string]$Action,
        [string]$Detail = ''
    )
    return [PSCustomObject]@{ Name = $Name; Action = $Action; Detail = $Detail }
}

function Get-RestoreStagingDir {
    param([string]$SubFolder)
    $base = Join-Path ([Environment]::GetFolderPath('Desktop')) 'RestoredData'
    $dir = if ($SubFolder) { Join-Path $base $SubFolder } else { $base }
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    return $dir
}

# Pure. Drive-mapping restore plan from the backup report's flat Results records.
# $LettersInUse: drive letters (like 'H:') already taken on this device.
function New-DriveMappingPlan {
    param(
        $Mappings,          # Results[] from Get-DriveMappings-Report.json
        [Parameter(Mandatory)][string]$SourceProfile,
        [string[]]$LettersInUse = @()
    )
    $plan = @()
    foreach ($m in @($Mappings)) {
        if ($null -eq $m -or -not $m.DriveLetter) { continue }
        if ($m.Profile -and $m.Profile -ine $SourceProfile) { continue }
        if (-not $m.UNCPath) {
            $plan += [PSCustomObject]@{ Action = 'Skipped'; DriveLetter = $m.DriveLetter; UNCPath = $null; Persistent = $false; Reason = 'No UNC path recorded' }
            continue
        }
        if (@($LettersInUse) -icontains $m.DriveLetter) {
            $plan += [PSCustomObject]@{ Action = 'Skipped'; DriveLetter = $m.DriveLetter; UNCPath = $m.UNCPath; Persistent = [bool]$m.Persistent; Reason = 'Drive letter already in use on this device' }
            continue
        }
        $plan += [PSCustomObject]@{ Action = 'Map'; DriveLetter = $m.DriveLetter; UNCPath = $m.UNCPath; Persistent = [bool]$m.Persistent; Reason = '' }
    }
    return @($plan)
}

# Pure. Printer restore plan: network printers with a \\server\printer identity
# can be reconnected; local printers need drivers we cannot know about.
function New-PrinterPlan {
    param($Printers) # Printers[] from Get-Printers-Report.json
    $plan = @()
    foreach ($p in @($Printers)) {
        if ($null -eq $p -or -not $p.Name) { continue }
        $connection = $null
        if ("$($p.Name)".StartsWith('\\')) { $connection = $p.Name }
        elseif ("$($p.PortName)".StartsWith('\\')) { $connection = $p.PortName }
        if ($p.Type -eq 'Network' -and $connection) {
            $plan += [PSCustomObject]@{ Action = 'Connect'; Name = $p.Name; Connection = $connection; IsDefault = [bool]$p.IsDefault; Reason = '' }
        } elseif ($p.Type -eq 'Network') {
            $plan += [PSCustomObject]@{ Action = 'Manual'; Name = $p.Name; Connection = $null; IsDefault = [bool]$p.IsDefault; Reason = "Network printer without a \\server\printer identity (port: $($p.PortName)) - re-add via its IP/WSD port" }
        } else {
            $plan += [PSCustomObject]@{ Action = 'Manual'; Name = $p.Name; Connection = $null; IsDefault = [bool]$p.IsDefault; Reason = 'Local printer - reinstall its driver, then re-add' }
        }
    }
    return @($plan)
}

# Pure. Bookmark restore decisions for one backed-up browser profile dir.
# Direct copy is only safe when the target browser profile already exists
# (browser installed/launched) AND it has no Bookmarks file yet (nothing to
# clobber, sync has not populated it). Everything else is staged.
function New-BookmarkDecision {
    param(
        [Parameter(Mandatory)][string]$Browser,        # Chrome / Edge / Brave / Firefox
        [Parameter(Mandatory)][bool]$TargetProfileExists,
        [Parameter(Mandatory)][bool]$TargetBookmarksExist
    )
    if ($Browser -eq 'Firefox') {
        # Swapping places.sqlite under a profile that may be live/synced is unsafe.
        return [PSCustomObject]@{ Action = 'Stage'; Reason = 'Firefox bookmarks are restored by copying places.sqlite into the profile while Firefox is closed - staged with instructions' }
    }
    if (-not $TargetProfileExists) {
        return [PSCustomObject]@{ Action = 'Stage'; Reason = 'Browser profile does not exist yet on this device - launch the browser once, then import' }
    }
    if ($TargetBookmarksExist) {
        return [PSCustomObject]@{ Action = 'Stage'; Reason = 'Browser already has bookmarks here (possibly synced) - not overwriting; merge manually if needed' }
    }
    return [PSCustomObject]@{ Action = 'Copy'; Reason = '' }
}
