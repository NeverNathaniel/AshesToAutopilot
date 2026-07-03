<#
.SYNOPSIS
    Restores what can be restored of the taskbar layout backed up by
    Backup-TaskbarLayout.ps1, and stages the rest honestly.

.DESCRIPTION
    Windows 10: pinned-taskbar shortcuts are copied back into the user's
    Quick Launch\User Pinned\TaskBar folder (Explorer restart required for
    them to appear; some pins may still need manual re-pinning).

    Windows 11: pin state lives in an app-bound database tied to the old
    install, and TaskbarRegistry.reg was exported under the OLD device's user
    SID - importing it here would write to the wrong hive path. Everything is
    staged to Desktop\RestoredData\Taskbar as reference for manual re-pinning.

.NOTES
    Requires: Administrator (toolkit convention; restore itself is per-user)
    Output:   C:\PreWipeOutput\Logs\Restore-TaskbarLayout-Report.json
#>
[CmdletBinding()]
param(
    [string]$BackupRoot = 'C:\PreWipeOutput',
    [string]$SourceProfile,
    [switch]$NonInteractive
)

$ScriptName = 'Restore-TaskbarLayout'
. (Join-Path $PSScriptRoot '..\Common\Initialize-Toolkit.ps1')
. (Join-Path $PSScriptRoot 'Restore-Common.ps1')
$LogFile = "$LogDir\$ScriptName.log"
if (-not (Test-AdminElevation)) { exit 1 }

$Items = @()
$sourceDir = if ($SourceProfile) { Join-Path (Join-Path $BackupRoot 'Taskbar') $SourceProfile } else { $null }
$isWin11 = $false
try { $isWin11 = [int](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop).CurrentBuildNumber -ge 22000 } catch { }

if (-not $SourceProfile) {
    $Items += New-RestoreItem -Name 'Taskbar layout' -Action 'Skipped' -Detail 'No source profile resolved - pass -SourceProfile'
} elseif (-not (Test-Path -LiteralPath $sourceDir)) {
    Write-Log "No taskbar backup for profile '$SourceProfile' at $sourceDir" 'WARN'
} else {
    # Win10: pinned shortcuts can go straight back.
    $pinnedSrc = Join-Path $sourceDir 'PinnedItems'
    if ((-not $isWin11) -and (Test-Path -LiteralPath $pinnedSrc)) {
        try {
            $pinnedDest = Join-Path $env:APPDATA 'Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar'
            if (-not (Test-Path -LiteralPath $pinnedDest)) { New-Item -ItemType Directory -Path $pinnedDest -Force | Out-Null }
            Copy-Item -Path (Join-Path $pinnedSrc '*') -Destination $pinnedDest -Recurse -Force -ErrorAction Stop
            $Items += New-RestoreItem -Name 'Pinned taskbar shortcuts' -Action 'Restored' -Detail 'Copied to User Pinned\TaskBar - restart Explorer (or log off/on); some pins may need re-pinning'
            Write-Log 'Win10 pinned shortcuts restored'
        } catch {
            $Items += New-RestoreItem -Name 'Pinned taskbar shortcuts' -Action 'Failed' -Detail "Copy failed: $_"
            Write-ErrorLog "Pinned shortcut restore failed: $_"
        }
    }

    # Everything else (Win11 pin state, layout XML/JSON, the SID-bound .reg) is
    # reference material, not directly importable - stage it.
    $stage = Get-RestoreStagingDir -SubFolder 'Taskbar'
    $staged = 0
    foreach ($entry in (Get-ChildItem -LiteralPath $sourceDir -ErrorAction SilentlyContinue)) {
        if ((-not $isWin11) -and $entry.Name -eq 'PinnedItems') { continue }
        Copy-Item -LiteralPath $entry.FullName -Destination $stage -Recurse -Force -ErrorAction SilentlyContinue
        $staged++
    }
    if ($staged -gt 0) {
        Set-Content -Path (Join-Path $stage 'HOW-TO-RESTORE.txt') -Value @(
            'These files document the old taskbar layout for manual re-pinning.'
            'Do NOT import TaskbarRegistry.reg - it was exported under the old'
            "device's user SID and would write to the wrong registry path here."
        )
        $detail = if ($isWin11) { 'Windows 11 pin state is app-bound and not directly importable - staged as reference' } else { 'Layout files staged as reference' }
        $Items += New-RestoreItem -Name 'Taskbar layout files' -Action 'Staged' -Detail "$detail -> $stage"
        Write-Log "Taskbar layout files staged to $stage"
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
    Write-Host '=== Taskbar Layout Restore ===' -ForegroundColor Cyan
    foreach ($i in $Items) { Write-Host "  [$($i.Action)] $($i.Name) $($i.Detail)" }
    Write-Host ''
}
exit 0
