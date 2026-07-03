<#
.SYNOPSIS
    Restores Outlook signature files backed up by Backup-OutlookSignatures.ps1.

.DESCRIPTION
    Copies <BackupRoot>\Signatures\<SourceProfile>\* into
    %APPDATA%\Microsoft\Signatures for the current user. Existing files are
    never overwritten (a signature the user already recreated wins) - those
    are reported as Skipped.

.NOTES
    Requires: Administrator (toolkit convention; restore itself is per-user)
    Output:   C:\PreWipeOutput\Logs\Restore-OutlookSignatures-Report.json
#>
[CmdletBinding()]
param(
    [string]$BackupRoot = 'C:\PreWipeOutput',
    [string]$SourceProfile,
    [switch]$NonInteractive
)

$ScriptName = 'Restore-OutlookSignatures'
. (Join-Path $PSScriptRoot '..\Common\Initialize-Toolkit.ps1')
. (Join-Path $PSScriptRoot 'Restore-Common.ps1')
$LogFile = "$LogDir\$ScriptName.log"
if (-not (Test-AdminElevation)) { exit 1 }

$Items = @()
$sourceDir = if ($SourceProfile) { Join-Path (Join-Path $BackupRoot 'Signatures') $SourceProfile } else { $null }
$destDir = Join-Path $env:APPDATA 'Microsoft\Signatures'

if (-not $SourceProfile) {
    $Items += New-RestoreItem -Name 'Signatures' -Action 'Skipped' -Detail 'No source profile resolved - pass -SourceProfile'
} elseif (-not (Test-Path -LiteralPath $sourceDir)) {
    Write-Log "No signature backup for profile '$SourceProfile' at $sourceDir" 'WARN'
} else {
    if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
    $files = @(Get-ChildItem -LiteralPath $sourceDir -Recurse -Force -ErrorAction SilentlyContinue | Where-Object { -not $_.PSIsContainer })
    foreach ($f in $files) {
        $rel  = $f.FullName.Substring($sourceDir.Length).TrimStart('\', '/')
        $dest = Join-Path $destDir $rel
        if (Test-Path -LiteralPath $dest) {
            $Items += New-RestoreItem -Name $rel -Action 'Skipped' -Detail 'Already exists on this device - not overwriting'
            continue
        }
        try {
            $destParent = Split-Path $dest -Parent
            if (-not (Test-Path -LiteralPath $destParent)) { New-Item -ItemType Directory -Path $destParent -Force | Out-Null }
            Copy-Item -LiteralPath $f.FullName -Destination $dest -ErrorAction Stop
            $Items += New-RestoreItem -Name $rel -Action 'Restored' -Detail ''
        } catch {
            $Items += New-RestoreItem -Name $rel -Action 'Failed' -Detail "Copy failed: $_"
            Write-ErrorLog "Signature restore failed for $rel : $_"
        }
    }
    Write-Log "Signatures restore: $(@($Items | Where-Object { $_.Action -eq 'Restored' }).Count)/$($files.Count) file(s) copied to $destDir"
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
    Write-Host "=== Outlook Signature Restore ($($Items.Count) file(s)) ===" -ForegroundColor Cyan
    foreach ($i in $Items) { Write-Host "  [$($i.Action)] $($i.Name) $($i.Detail)" }
    Write-Host ''
}
exit 0
