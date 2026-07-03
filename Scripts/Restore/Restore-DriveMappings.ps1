<#
.SYNOPSIS
    Re-creates mapped network drives recorded by Get-DriveMappings.ps1.

.DESCRIPTION
    Reads Logs\Get-DriveMappings-Report.json from the backup, filters to the
    source profile's mappings, and maps each free drive letter via 'net use'
    (persistence preserved), verified by exit code. Letters already in use on
    this device are skipped, never clobbered.

    Mappings are per-user: run this in the session of the user being restored.
    If elevated under a different account, the mappings land in THAT account's
    profile.

.NOTES
    Requires: Administrator (toolkit convention; mapping itself is per-user)
    Output:   C:\PreWipeOutput\Logs\Restore-DriveMappings-Report.json
#>
[CmdletBinding()]
param(
    [string]$BackupRoot = 'C:\PreWipeOutput',
    [string]$SourceProfile,
    [switch]$NonInteractive
)

$ScriptName = 'Restore-DriveMappings'
. (Join-Path $PSScriptRoot '..\Common\Initialize-Toolkit.ps1')
. (Join-Path $PSScriptRoot 'Restore-Common.ps1')
$LogFile = "$LogDir\$ScriptName.log"
if (-not (Test-AdminElevation)) { exit 1 }

$Items = @()
$report = Get-BackupReport -BackupRoot $BackupRoot -BaseName 'Get-DriveMappings'

if ($null -eq $report -or -not $report.Results) {
    Write-Log 'No drive-mapping report in backup' 'WARN'
} elseif (-not $SourceProfile) {
    $Items += New-RestoreItem -Name 'Drive mappings' -Action 'Skipped' -Detail 'No source profile resolved - pass -SourceProfile'
} else {
    $inUse = @(Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue | ForEach-Object { "$($_.Name):" })
    $plan = New-DriveMappingPlan -Mappings $report.Results -SourceProfile $SourceProfile -LettersInUse $inUse

    foreach ($p in $plan) {
        if ($p.Action -eq 'Skipped') {
            $Items += New-RestoreItem -Name "$($p.DriveLetter) $($p.UNCPath)" -Action 'Skipped' -Detail $p.Reason
            continue
        }
        $persistFlag = if ($p.Persistent) { '/persistent:yes' } else { '/persistent:no' }
        $null = net use $p.DriveLetter $p.UNCPath $persistFlag 2>&1
        if ($LASTEXITCODE -eq 0) {
            $Items += New-RestoreItem -Name "$($p.DriveLetter) $($p.UNCPath)" -Action 'Restored' -Detail "Mapped ($persistFlag)"
            Write-Log "Mapped $($p.DriveLetter) -> $($p.UNCPath)"
        } else {
            $Items += New-RestoreItem -Name "$($p.DriveLetter) $($p.UNCPath)" -Action 'Failed' -Detail "net use exited $LASTEXITCODE (share unreachable or credentials required)"
            Write-ErrorLog "Mapping failed: $($p.DriveLetter) -> $($p.UNCPath) (exit $LASTEXITCODE)"
        }
    }
}

$Result = [PSCustomObject]@{
    Timestamp     = (Get-Date -Format 'o')
    BackupRoot    = $BackupRoot
    SourceProfile = $SourceProfile
    RestoredForUser = "$env:USERDOMAIN\$env:USERNAME"
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
    Write-Host "=== Drive Mapping Restore ($($Items.Count) mapping(s)) ===" -ForegroundColor Cyan
    foreach ($i in $Items) { Write-Host "  [$($i.Action)] $($i.Name) $($i.Detail)" }
    Write-Host ''
}
exit 0
