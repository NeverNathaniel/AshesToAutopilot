<#
.SYNOPSIS
    Post-wipe restore orchestrator - replays the pre-wipe backups onto the
    freshly re-enrolled device. The counterpart to Start-PreWipeToolkit.ps1.

.DESCRIPTION
    Before wiping, copy C:\PreWipeOutput to a USB drive or network share (the
    wipe destroys it). After the device re-enrolls and the user is signed in,
    run from an elevated PowerShell IN THE USER'S SESSION:

        .\Start-PostWipeRestore.ps1 -BackupRoot E:\PreWipeOutput

    Restores, per category, with an honest per-item outcome:
      Wi-Fi profiles      restored device-wide (enterprise = re-auth needed)
      Drive mappings      re-mapped for the current user (free letters only)
      Printers            network printers reconnected, default re-set
      Browser bookmarks   copied when provably safe, otherwise staged
      Outlook signatures  copied, never overwriting existing files
      Wallpaper           set for the current user
      Taskbar layout      Win10 pins restored; Win11 staged as reference

    Anything not directly restorable lands in Desktop\RestoredData with
    instructions. A diff report (JSON + HTML) is written to C:\PreWipeOutput.

.PARAMETER BackupRoot
    Path to the copied pre-wipe output folder. Default: C:\PreWipeOutput.

.PARAMETER SourceProfile
    Which backed-up user profile's data to restore. Auto-detected when the
    current username matches a backed-up profile or only one profile exists;
    required (fail-closed) when ambiguous.

.PARAMETER Skip
    Category names to skip, e.g. -Skip WiFiProfiles,TaskbarLayout.

.PARAMETER NonInteractive
    Suppress prompts. Output structured JSON to stdout. Ambiguous source
    profiles fail with the candidate list instead of prompting.

.NOTES
    Requires: Administrator, run in the target user's session
    Output:   C:\PreWipeOutput\RestoreReport_<PC>_<ts>.json / .html
#>
[CmdletBinding()]
param(
    [string]$BackupRoot = 'C:\PreWipeOutput',
    [string]$SourceProfile,
    [string[]]$Skip = @(),
    [switch]$NonInteractive
)

$ScriptName = 'Start-PostWipeRestore'
. (Join-Path $PSScriptRoot 'Scripts\Common\Initialize-Toolkit.ps1')
. (Join-Path $PSScriptRoot 'Scripts\Restore\Restore-Common.ps1')
$LogFile = "$LogDir\$ScriptName.log"
if (-not (Test-AdminElevation)) { exit 1 }

function Write-FailureJson {
    param([string]$Message)
    if ($NonInteractive) {
        [PSCustomObject]@{ Timestamp = (Get-Date -Format 'o'); Success = $false; Error = $Message } | ConvertTo-Json -Depth 3
    } else {
        Write-Host "ERROR: $Message" -ForegroundColor Red
    }
}

#region --- Validate backup root ---
$knownArtifacts = @('WiFiProfiles', 'Bookmarks', 'Signatures', 'Wallpaper', 'Taskbar', 'Logs')
$found = @($knownArtifacts | Where-Object { Test-Path -LiteralPath (Join-Path $BackupRoot $_) })
if ($found.Count -eq 0) {
    Write-FailureJson "No pre-wipe backup artifacts found under '$BackupRoot'. Point -BackupRoot at the copied C:\PreWipeOutput folder."
    exit 1
}
Write-Log "Backup root validated: $BackupRoot (found: $($found -join ', '))"
#endregion

#region --- Resolve source profile ---
$candidates = Get-BackupProfileNames -BackupRoot $BackupRoot
$resolved   = Select-SourceProfile -Candidates $candidates -Requested $SourceProfile -CurrentUserName $env:USERNAME

if ($SourceProfile -and -not $resolved) {
    Write-FailureJson "Requested profile '$SourceProfile' is not in this backup. Available: $($candidates -join ', ')"
    exit 1
}
if (-not $resolved -and $candidates.Count -gt 1) {
    if ($NonInteractive) {
        Write-FailureJson "Multiple backed-up profiles - pass -SourceProfile. Available: $($candidates -join ', ')"
        exit 1
    }
    Write-Host ''
    Write-Host '  Multiple user profiles were backed up. Restore which one?' -ForegroundColor Cyan
    for ($i = 0; $i -lt $candidates.Count; $i++) { Write-Host "    [$($i + 1)] $($candidates[$i])" }
    $choice = Read-Host '  Enter number (blank to cancel)'
    $n = 0
    if (-not [int]::TryParse("$choice".Trim(), [ref]$n) -or $n -lt 1 -or $n -gt $candidates.Count) {
        Write-Host '  Cancelled.' -ForegroundColor Yellow
        exit 0
    }
    $resolved = $candidates[$n - 1]
}
if ($resolved) { Write-Log "Source profile: $resolved (restoring for current user $env:USERDOMAIN\$env:USERNAME)" }
else { Write-Log 'No per-user profile resolved - device-wide categories only (Wi-Fi, printers)' 'WARN' }
#endregion

#region --- Run restore scripts ---
$categories = @(
    @{ Name = 'WiFiProfiles';      Script = 'Scripts\Restore\Restore-WiFiProfiles.ps1' }
    @{ Name = 'DriveMappings';     Script = 'Scripts\Restore\Restore-DriveMappings.ps1' }
    @{ Name = 'Printers';          Script = 'Scripts\Restore\Restore-Printers.ps1' }
    @{ Name = 'BrowserBookmarks';  Script = 'Scripts\Restore\Restore-BrowserBookmarks.ps1' }
    @{ Name = 'OutlookSignatures'; Script = 'Scripts\Restore\Restore-OutlookSignatures.ps1' }
    @{ Name = 'DesktopBackground'; Script = 'Scripts\Restore\Restore-DesktopBackground.ps1' }
    @{ Name = 'TaskbarLayout';     Script = 'Scripts\Restore\Restore-TaskbarLayout.ps1' }
)

if (-not $NonInteractive) {
    Write-Host ''
    Write-Host '  =============================================' -ForegroundColor Cyan
    Write-Host '     POST-WIPE RESTORE' -ForegroundColor White
    Write-Host "     Backup : $BackupRoot" -ForegroundColor Gray
    Write-Host "     Source : $(if ($resolved) { $resolved } else { '(device-wide only)' })" -ForegroundColor Gray
    Write-Host "     Target : $env:USERDOMAIN\$env:USERNAME on $env:COMPUTERNAME" -ForegroundColor Gray
    Write-Host '  =============================================' -ForegroundColor Cyan
    Write-Host ''
}

$CategoryResults = @()
foreach ($cat in $categories) {
    if (@($Skip) -icontains $cat.Name) {
        Write-Log "Skipping category (requested): $($cat.Name)"
        continue
    }
    $scriptPath = Join-Path $PSScriptRoot $cat.Script
    if (-not (Test-Path -LiteralPath $scriptPath)) {
        $CategoryResults += [PSCustomObject]@{ Category = $cat.Name; Items = @(); Error = 'Restore script missing' }
        continue
    }
    if (-not $NonInteractive) { Write-Host "  Restoring $($cat.Name)..." -ForegroundColor DarkCyan }

    $global:LASTEXITCODE = 0 # plain assignment would create a script-scope shadow
    $parsed = $null
    try {
        $raw = & $scriptPath -BackupRoot $BackupRoot -SourceProfile $resolved -NonInteractive 2>&1
        $jsonText = ($raw | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }) | Out-String
        if ($jsonText.Trim()) { $parsed = $jsonText | ConvertFrom-Json }
    } catch {
        Write-ErrorLog "$($cat.Name) restore threw: $_"
    }

    $CategoryResults += [PSCustomObject]@{
        Category = $cat.Name
        Items    = if ($parsed -and $parsed.Items) { @($parsed.Items) } else { @() }
        Error    = if ($null -eq $parsed) { 'Restore script produced no result' } else { $null }
    }
}
#endregion

#region --- Aggregate + report ---
$allItems = @($CategoryResults | ForEach-Object { $_.Items })
$totals = [PSCustomObject]@{
    Restored = @($allItems | Where-Object { $_.Action -eq 'Restored' }).Count
    Staged   = @($allItems | Where-Object { $_.Action -eq 'Staged' }).Count
    Skipped  = @($allItems | Where-Object { $_.Action -eq 'Skipped' }).Count
    Failed   = @($allItems | Where-Object { $_.Action -eq 'Failed' }).Count
}

$Report = [PSCustomObject]@{
    Timestamp     = (Get-Date -Format 'o')
    ComputerName  = $env:COMPUTERNAME
    RestoredFor   = "$env:USERDOMAIN\$env:USERNAME"
    BackupRoot    = $BackupRoot
    SourceProfile = $resolved
    Totals        = $totals
    Categories    = $CategoryResults
}

$stamp    = Get-Date -Format 'yyyyMMdd-HHmmss'
$jsonPath = Join-Path $OutputRoot "RestoreReport_$($env:COMPUTERNAME)_$stamp.json"
$Report | ConvertTo-Json -Depth 6 | Out-File $jsonPath -Force

# Compact self-contained HTML diff report.
$enc = { param($s) [System.Net.WebUtility]::HtmlEncode("$s") }
$sb = [System.Text.StringBuilder]::new()
$null = $sb.AppendLine('<!DOCTYPE html><html><head><meta charset="utf-8"><title>Restore Report</title><style>')
$null = $sb.AppendLine('body{font-family:-apple-system,Segoe UI,Roboto,sans-serif;background:#f8fafc;color:#1e293b;margin:0}')
$null = $sb.AppendLine('.hd{background:#0f172a;color:#fff;padding:20px 28px}.hd .sub{color:#94a3b8;font-size:.85rem}')
$null = $sb.AppendLine('.wrap{max-width:860px;margin:0 auto;padding:20px 14px}table{width:100%;border-collapse:collapse;background:#fff;font-size:.85rem}')
$null = $sb.AppendLine('th{text-align:left;padding:6px 10px;border-bottom:2px solid #e2e8f0;color:#64748b}td{padding:6px 10px;border-bottom:1px solid #e2e8f0}')
$null = $sb.AppendLine('.b{padding:2px 8px;border-radius:4px;font-weight:700;font-size:.72rem;color:#fff}.Restored{background:#22c55e}.Staged{background:#eab308;color:#422006}.Skipped{background:#94a3b8}.Failed{background:#ef4444}')
$null = $sb.AppendLine('.cat{font-size:.72rem;font-weight:700;text-transform:uppercase;letter-spacing:.08em;color:#64748b;padding:18px 0 6px}')
$null = $sb.AppendLine('.badges span{display:inline-block;margin-right:10px;padding:6px 14px;border-radius:8px;color:#fff;font-weight:600;font-size:.82rem}')
$null = $sb.AppendLine('</style></head><body>')
$null = $sb.AppendLine("<div class='hd'><h2>Post-Wipe Restore Report</h2><div class='sub'>$(& $enc $env:COMPUTERNAME) &middot; restored for $(& $enc "$env:USERDOMAIN\$env:USERNAME") &middot; source profile: $(& $enc $(if ($resolved) { $resolved } else { '(device-wide)' })) &middot; $(Get-Date -Format 'yyyy-MM-dd HH:mm')</div></div>")
$null = $sb.AppendLine("<div class='wrap'><div class='badges'><span style='background:#22c55e'>Restored: $($totals.Restored)</span><span style='background:#eab308;color:#422006'>Staged: $($totals.Staged)</span><span style='background:#94a3b8'>Skipped: $($totals.Skipped)</span><span style='background:#ef4444'>Failed: $($totals.Failed)</span></div>")
foreach ($cr in $CategoryResults) {
    $null = $sb.AppendLine("<div class='cat'>$(& $enc $cr.Category)</div>")
    if ($cr.Error) {
        $null = $sb.AppendLine("<table><tr><td><span class='b Failed'>ERROR</span></td><td>$(& $enc $cr.Error)</td></tr></table>")
        continue
    }
    if (@($cr.Items).Count -eq 0) {
        $null = $sb.AppendLine('<table><tr><td>Nothing in the backup for this category.</td></tr></table>')
        continue
    }
    $null = $sb.AppendLine('<table><tr><th style="width:6.5rem">Outcome</th><th>Item</th><th>Detail</th></tr>')
    foreach ($i in $cr.Items) {
        $null = $sb.AppendLine("<tr><td><span class='b $(& $enc $i.Action)'>$(& $enc $i.Action)</span></td><td>$(& $enc $i.Name)</td><td>$(& $enc $i.Detail)</td></tr>")
    }
    $null = $sb.AppendLine('</table>')
}
$null = $sb.AppendLine("<p style='color:#64748b;font-size:.8rem'>Staged items are on the Desktop in RestoredData with instructions. JSON: $(& $enc $jsonPath)</p></div></body></html>")
$htmlPath = Join-Path $OutputRoot "RestoreReport_$($env:COMPUTERNAME)_$stamp.html"
$sb.ToString() | Set-Content $htmlPath -Encoding UTF8 -Force
Write-Log "Restore report: $jsonPath / $htmlPath"
#endregion

#region --- Output ---
if ($NonInteractive) {
    $Report | ConvertTo-Json -Depth 6
} else {
    Write-Host ''
    Write-Host '  ============ RESTORE SUMMARY ============' -ForegroundColor Cyan
    Write-Host "   Restored: $($totals.Restored)   Staged: $($totals.Staged)   Skipped: $($totals.Skipped)   Failed: $($totals.Failed)" -ForegroundColor White
    foreach ($cr in $CategoryResults) {
        Write-Host ''
        Write-Host "   $($cr.Category)" -ForegroundColor Yellow
        if ($cr.Error) { Write-Host "     ERROR: $($cr.Error)" -ForegroundColor Red; continue }
        if (@($cr.Items).Count -eq 0) { Write-Host '     (nothing in backup)' -ForegroundColor DarkGray; continue }
        foreach ($i in $cr.Items) {
            $color = switch ($i.Action) { 'Restored' { 'Green' } 'Staged' { 'Yellow' } 'Failed' { 'Red' } default { 'Gray' } }
            Write-Host "     [$($i.Action)] $($i.Name)" -ForegroundColor $color
            if ($i.Detail) { Write-Host "        $($i.Detail)" -ForegroundColor DarkGray }
        }
    }
    Write-Host ''
    Write-Host "   Report: $htmlPath" -ForegroundColor Cyan
    if ($totals.Staged -gt 0) { Write-Host '   Staged items are on the Desktop in RestoredData with instructions.' -ForegroundColor Yellow }
    Write-Host ''
}
exit 0
#endregion
