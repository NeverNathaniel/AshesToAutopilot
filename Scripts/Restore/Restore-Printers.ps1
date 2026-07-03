<#
.SYNOPSIS
    Reconnects printers recorded by Get-Printers.ps1.

.DESCRIPTION
    Network printers with a \\server\printer identity are reconnected via
    Add-Printer -ConnectionName, and the recorded default printer is re-set.
    Local printers and IP/WSD-port printers cannot be recreated without their
    drivers - they are reported as Staged with a manual instruction.

.NOTES
    Requires: Administrator (toolkit convention; connections are per-user)
    Output:   C:\PreWipeOutput\Logs\Restore-Printers-Report.json
#>
[CmdletBinding()]
param(
    [string]$BackupRoot = 'C:\PreWipeOutput',
    [string]$SourceProfile,
    [switch]$NonInteractive
)

$ScriptName = 'Restore-Printers'
. (Join-Path $PSScriptRoot '..\Common\Initialize-Toolkit.ps1')
. (Join-Path $PSScriptRoot 'Restore-Common.ps1')
$LogFile = "$LogDir\$ScriptName.log"
if (-not (Test-AdminElevation)) { exit 1 }

$Items = @()
$report = Get-BackupReport -BackupRoot $BackupRoot -BaseName 'Get-Printers'

if ($null -eq $report -or -not $report.Printers) {
    Write-Log 'No printer report in backup (or no printers were recorded)' 'WARN'
} else {
    $plan = New-PrinterPlan -Printers $report.Printers
    $defaultToSet = $null

    foreach ($p in $plan) {
        if ($p.Action -eq 'Manual') {
            $Items += New-RestoreItem -Name $p.Name -Action 'Staged' -Detail $p.Reason
            continue
        }
        try {
            Add-Printer -ConnectionName $p.Connection -ErrorAction Stop
            $Items += New-RestoreItem -Name $p.Name -Action 'Restored' -Detail "Connected to $($p.Connection)"
            Write-Log "Reconnected printer: $($p.Connection)"
            if ($p.IsDefault) { $defaultToSet = $p.Connection }
        } catch {
            $Items += New-RestoreItem -Name $p.Name -Action 'Failed' -Detail "Add-Printer failed: $_"
            Write-ErrorLog "Printer reconnect failed for $($p.Connection): $_"
        }
    }

    if ($defaultToSet) {
        try {
            (New-Object -ComObject WScript.Network).SetDefaultPrinter($defaultToSet)
            $Items += New-RestoreItem -Name 'Default printer' -Action 'Restored' -Detail $defaultToSet
            Write-Log "Default printer set: $defaultToSet"
        } catch {
            $Items += New-RestoreItem -Name 'Default printer' -Action 'Failed' -Detail "Could not set default: $_"
            Write-ErrorLog "Setting default printer failed: $_"
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
    Write-Host "=== Printer Restore ($($Items.Count) item(s)) ===" -ForegroundColor Cyan
    foreach ($i in $Items) { Write-Host "  [$($i.Action)] $($i.Name) $($i.Detail)" }
    Write-Host ''
}
exit 0
