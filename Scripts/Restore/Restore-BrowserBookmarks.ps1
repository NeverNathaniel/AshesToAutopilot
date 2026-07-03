<#
.SYNOPSIS
    Restores browser bookmarks backed up by Backup-BrowserBookmarks.ps1.

.DESCRIPTION
    For Chrome/Edge/Brave: the backed-up Bookmarks file is copied directly ONLY
    when the target browser profile already exists on this device and has no
    Bookmarks file yet (nothing to clobber, sync has not populated it). In every
    other case the file is staged to Desktop\RestoredData\Bookmarks with the
    reason - existing (possibly synced) bookmarks are never overwritten.

    Firefox places.sqlite is ALWAYS staged: swapping the database under a
    profile that may be live or synced is unsafe. Instructions are included.

.NOTES
    Requires: Administrator (toolkit convention; restore itself is per-user)
    Output:   C:\PreWipeOutput\Logs\Restore-BrowserBookmarks-Report.json
#>
[CmdletBinding()]
param(
    [string]$BackupRoot = 'C:\PreWipeOutput',
    [string]$SourceProfile,
    [switch]$NonInteractive
)

$ScriptName = 'Restore-BrowserBookmarks'
. (Join-Path $PSScriptRoot '..\Common\Initialize-Toolkit.ps1')
. (Join-Path $PSScriptRoot 'Restore-Common.ps1')
$LogFile = "$LogDir\$ScriptName.log"
if (-not (Test-AdminElevation)) { exit 1 }

$Items = @()
$sourceRoot = if ($SourceProfile) { Join-Path (Join-Path $BackupRoot 'Bookmarks') $SourceProfile } else { $null }

$targetUserData = @{
    'Chrome' = "$env:LOCALAPPDATA\Google\Chrome\User Data"
    'Edge'   = "$env:LOCALAPPDATA\Microsoft\Edge\User Data"
    'Brave'  = "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data"
}

if (-not $SourceProfile) {
    $Items += New-RestoreItem -Name 'Bookmarks' -Action 'Skipped' -Detail 'No source profile resolved - pass -SourceProfile'
} elseif (-not (Test-Path -LiteralPath $sourceRoot)) {
    Write-Log "No bookmark backup for profile '$SourceProfile' at $sourceRoot" 'WARN'
} else {
    foreach ($browserDir in (Get-ChildItem -LiteralPath $sourceRoot -Directory -ErrorAction SilentlyContinue)) {
        $browser = $browserDir.Name
        foreach ($profDir in (Get-ChildItem -LiteralPath $browserDir.FullName -Directory -ErrorAction SilentlyContinue)) {
            $itemName = "$browser/$($profDir.Name)"

            if ($browser -eq 'Firefox') {
                $decision = New-BookmarkDecision -Browser 'Firefox' -TargetProfileExists $false -TargetBookmarksExist $false
                $stage = Get-RestoreStagingDir -SubFolder "Bookmarks\Firefox\$($profDir.Name)"
                Copy-Item -Path (Join-Path $profDir.FullName '*') -Destination $stage -Force -ErrorAction SilentlyContinue
                Set-Content -Path (Join-Path $stage 'HOW-TO-RESTORE.txt') -Value @(
                    'Close Firefox completely, then copy places.sqlite (and the -wal/-shm'
                    'files if present) into your Firefox profile folder:'
                    '  %APPDATA%\Mozilla\Firefox\Profiles\<profile>\'
                    'Reopen Firefox - bookmarks and history are restored together.'
                )
                $Items += New-RestoreItem -Name $itemName -Action 'Staged' -Detail "$($decision.Reason) -> $stage"
                continue
            }

            $srcBookmarks = Join-Path $profDir.FullName 'Bookmarks'
            if (-not (Test-Path -LiteralPath $srcBookmarks)) { continue }

            $targetProfileDir = if ($targetUserData.ContainsKey($browser)) { Join-Path $targetUserData[$browser] $profDir.Name } else { $null }
            $targetExists     = [bool]($targetProfileDir -and (Test-Path -LiteralPath $targetProfileDir))
            $targetHasFile    = [bool]($targetExists -and (Test-Path -LiteralPath (Join-Path $targetProfileDir 'Bookmarks')))

            $decision = New-BookmarkDecision -Browser $browser -TargetProfileExists $targetExists -TargetBookmarksExist $targetHasFile
            if ($decision.Action -eq 'Copy') {
                try {
                    Copy-Item -LiteralPath $srcBookmarks -Destination (Join-Path $targetProfileDir 'Bookmarks') -ErrorAction Stop
                    $Items += New-RestoreItem -Name $itemName -Action 'Restored' -Detail "Copied into $targetProfileDir (browser must be closed for it to load)"
                    Write-Log "Restored bookmarks: $itemName"
                } catch {
                    $Items += New-RestoreItem -Name $itemName -Action 'Failed' -Detail "Copy failed: $_"
                    Write-ErrorLog "Bookmark restore failed for $itemName : $_"
                }
            } else {
                $stage = Get-RestoreStagingDir -SubFolder "Bookmarks\$browser\$($profDir.Name)"
                Copy-Item -LiteralPath $srcBookmarks -Destination (Join-Path $stage 'Bookmarks') -Force -ErrorAction SilentlyContinue
                $Items += New-RestoreItem -Name $itemName -Action 'Staged' -Detail "$($decision.Reason) -> $stage"
                Write-Log "Staged bookmarks: $itemName ($($decision.Reason))"
            }
        }
    }
    if ($Items.Count -eq 0) {
        Write-Log "Bookmark backup for '$SourceProfile' contained no browser data" 'WARN'
    }
}

$Result = [PSCustomObject]@{
    Timestamp     = (Get-Date -Format 'o')
    BackupRoot    = $BackupRoot
    SourceProfile = $SourceProfile
    Items         = $Items
    Counts        = [PSCustomObject]@{
        Restored = @($Items | Where-Object { $_.Action -eq 'Restored' }).Count
        Staged   = @($Items | Where-Object { $_.Action -eq 'Staged' }).Count
        Skipped  = @($Items | Where-Object { $_.Action -eq 'Skipped' }).Count
        Failed   = @($Items | Where-Object { $_.Action -eq 'Failed' }).Count
    }
}

$Result | ConvertTo-Json -Depth 5 | Out-File "$LogDir\$ScriptName-Report.json" -Force
if ($NonInteractive) { $Result | ConvertTo-Json -Depth 5 }
else {
    Write-Host ''
    Write-Host "=== Bookmark Restore ($($Items.Count) item(s)) ===" -ForegroundColor Cyan
    foreach ($i in $Items) { Write-Host "  [$($i.Action)] $($i.Name) $($i.Detail)" }
    Write-Host ''
}
exit 0
