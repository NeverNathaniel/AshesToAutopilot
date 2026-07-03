<#
.SYNOPSIS
    Restores the desktop wallpaper backed up by Backup-DesktopBackground.ps1.

.DESCRIPTION
    Copies the backed-up image from <BackupRoot>\Wallpaper\<SourceProfile>\ into
    %APPDATA%\Microsoft\Windows\Themes\, sets it as the current user's wallpaper
    (HKCU Control Panel\Desktop), and refreshes the desktop.

.NOTES
    Requires: Administrator (toolkit convention; restore itself is per-user)
    Output:   C:\PreWipeOutput\Logs\Restore-DesktopBackground-Report.json
#>
[CmdletBinding()]
param(
    [string]$BackupRoot = 'C:\PreWipeOutput',
    [string]$SourceProfile,
    [switch]$NonInteractive
)

$ScriptName = 'Restore-DesktopBackground'
. (Join-Path $PSScriptRoot '..\Common\Initialize-Toolkit.ps1')
. (Join-Path $PSScriptRoot 'Restore-Common.ps1')
$LogFile = "$LogDir\$ScriptName.log"
if (-not (Test-AdminElevation)) { exit 1 }

$Items = @()
$sourceDir = if ($SourceProfile) { Join-Path (Join-Path $BackupRoot 'Wallpaper') $SourceProfile } else { $null }

if (-not $SourceProfile) {
    $Items += New-RestoreItem -Name 'Wallpaper' -Action 'Skipped' -Detail 'No source profile resolved - pass -SourceProfile'
} elseif (-not (Test-Path -LiteralPath $sourceDir)) {
    Write-Log "No wallpaper backup for profile '$SourceProfile' at $sourceDir" 'WARN'
} else {
    $image = Get-ChildItem -LiteralPath $sourceDir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -match '\.(jpg|jpeg|png|bmp)$' } | Select-Object -First 1
    if (-not $image) {
        $Items += New-RestoreItem -Name 'Wallpaper' -Action 'Skipped' -Detail 'No image file in the wallpaper backup (default wallpaper was in use)'
    } else {
        try {
            $themesDir = Join-Path $env:APPDATA 'Microsoft\Windows\Themes'
            if (-not (Test-Path -LiteralPath $themesDir)) { New-Item -ItemType Directory -Path $themesDir -Force | Out-Null }
            $dest = Join-Path $themesDir "Restored_$($image.Name)"
            Copy-Item -LiteralPath $image.FullName -Destination $dest -Force -ErrorAction Stop
            Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name 'Wallpaper' -Value $dest -ErrorAction Stop
            # Refresh the desktop so the change applies without logoff (best effort).
            $null = & rundll32.exe user32.dll, UpdatePerUserSystemParameters 2>$null
            $Items += New-RestoreItem -Name $image.Name -Action 'Restored' -Detail "Set as wallpaper ($dest); log off/on if it does not appear immediately"
            Write-Log "Wallpaper restored: $dest"
        } catch {
            $Items += New-RestoreItem -Name $image.Name -Action 'Failed' -Detail "Restore failed: $_"
            Write-ErrorLog "Wallpaper restore failed: $_"
        }
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
    Write-Host '=== Wallpaper Restore ===' -ForegroundColor Cyan
    foreach ($i in $Items) { Write-Host "  [$($i.Action)] $($i.Name) $($i.Detail)" }
    Write-Host ''
}
exit 0
