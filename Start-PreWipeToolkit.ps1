<#
.SYNOPSIS
    Pre-Wipe Toolkit orchestrator — interactive multi-select menu for all pre-wipe scripts.

.DESCRIPTION
    Displays all scripts grouped by category with PSMenu (Show-Menu -MultiSelect).
    Pre-selects read-only / data-backup scripts. Config-change and BIOS scripts require
    explicit selection. BIOS scripts require an additional yes/no confirmation before running.
    Pauses for technician review once per script, in the loop — not inside each script.

.NOTES
    Requires: PSMenu module (Sebazzz/PSMenu) — installed automatically if missing.
    Requires: Administrator
    Session state: C:\PreWipeOutput\session.json
#>

[CmdletBinding()]
param()

#region --- Init ---
$ErrorActionPreference = 'Stop'

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'ERROR: This script must be run as Administrator.' -ForegroundColor Red
    exit 1
}

$OutputRoot   = 'C:\PreWipeOutput'
$SessionFile  = "$OutputRoot\session.json"
$ScriptRoot   = $PSScriptRoot

if (-not (Test-Path $OutputRoot)) { New-Item -Path $OutputRoot -ItemType Directory -Force | Out-Null }

# Ensure PSMenu is available
try {
    Import-Module PSMenu -ErrorAction Stop
} catch {
    Write-Host 'PSMenu not found. Installing from PSGallery...' -ForegroundColor Yellow
    try {
        Install-Module -Name PSMenu -Scope CurrentUser -Force -ErrorAction Stop
        Import-Module PSMenu -ErrorAction Stop
    } catch {
        Write-Host "ERROR: Could not install PSMenu: $_" -ForegroundColor Red
        exit 1
    }
}
#endregion

#region --- Script Registry ---
# Each entry: Label, Path, Category, IsChange, IsBios, PreSelected
$AllScripts = @(

    # --- Data Collection ---
    [PSCustomObject]@{
        Label       = 'Find Unbacked Data (PST, SSH keys, certs, OneNote)'
        Path        = "$ScriptRoot\Scripts\DataCollection\Find-UnbackedData.ps1"
        Category    = 'Data Collection'
        IsChange    = $false
        IsBios      = $false
        PreSelected = $true
        Status      = 'not-run'
    }
    [PSCustomObject]@{
        Label       = 'Get Downloads Folder Size'
        Path        = "$ScriptRoot\Scripts\DataCollection\Get-DownloadsSize.ps1"
        Category    = 'Data Collection'
        IsChange    = $false
        IsBios      = $false
        PreSelected = $true
        Status      = 'not-run'
    }
    [PSCustomObject]@{
        Label       = 'Get Network Drive Mappings'
        Path        = "$ScriptRoot\Scripts\DataCollection\Get-DriveMappings.ps1"
        Category    = 'Data Collection'
        IsChange    = $false
        IsBios      = $false
        PreSelected = $true
        Status      = 'not-run'
    }
    [PSCustomObject]@{
        Label       = 'Get Physical Printers'
        Path        = "$ScriptRoot\Scripts\DataCollection\Get-Printers.ps1"
        Category    = 'Data Collection'
        IsChange    = $false
        IsBios      = $false
        PreSelected = $true
        Status      = 'not-run'
    }

    # --- Configuration Checks ---
    [PSCustomObject]@{
        Label       = 'Test OneDrive KFM Status'
        Path        = "$ScriptRoot\Scripts\ConfigurationChecks\Test-OneDriveKFM.ps1"
        Category    = 'Configuration Checks'
        IsChange    = $false
        IsBios      = $false
        PreSelected = $true
        Status      = 'not-run'
    }
    [PSCustomObject]@{
        Label       = 'Get Storage Controller Mode (AHCI/RAID/NVMe)'
        Path        = "$ScriptRoot\Scripts\ConfigurationChecks\Get-StorageMode.ps1"
        Category    = 'Configuration Checks'
        IsChange    = $false
        IsBios      = $false
        PreSelected = $true
        Status      = 'not-run'
    }
    [PSCustomObject]@{
        Label       = 'Test BIOS Version (Dell)'
        Path        = "$ScriptRoot\Scripts\ConfigurationChecks\Test-BiosVersion.ps1"
        Category    = 'Configuration Checks'
        IsChange    = $false
        IsBios      = $false
        PreSelected = $true
        Status      = 'not-run'
    }
    [PSCustomObject]@{
        Label       = 'Test Driver Status (Dell DCU scan)'
        Path        = "$ScriptRoot\Scripts\ConfigurationChecks\Test-DriverStatus.ps1"
        Category    = 'Configuration Checks'
        IsChange    = $false
        IsBios      = $false
        PreSelected = $true
        Status      = 'not-run'
    }
    [PSCustomObject]@{
        Label       = 'Test Wake-on-LAN Settings'
        Path        = "$ScriptRoot\Scripts\ConfigurationChecks\Test-WakeOnLan.ps1"
        Category    = 'Configuration Checks'
        IsChange    = $false
        IsBios      = $false
        PreSelected = $true
        Status      = 'not-run'
    }
    [PSCustomObject]@{
        Label       = 'Test Windows Recovery Environment (WinRE)'
        Path        = "$ScriptRoot\Scripts\ConfigurationChecks\Test-WinRE.ps1"
        Category    = 'Configuration Checks'
        IsChange    = $false
        IsBios      = $false
        PreSelected = $true
        Status      = 'not-run'
    }

    # --- Configuration Changes ---
    [PSCustomObject]@{
        Label       = '[CHANGE] Backup Browser Bookmarks'
        Path        = "$ScriptRoot\Scripts\ConfigurationChanges\Backup-BrowserBookmarks.ps1"
        Category    = 'Configuration Changes'
        IsChange    = $true
        IsBios      = $false
        PreSelected = $true
        Status      = 'not-run'
    }
    [PSCustomObject]@{
        Label       = '[CHANGE] Backup Desktop Wallpaper'
        Path        = "$ScriptRoot\Scripts\ConfigurationChanges\Backup-DesktopBackground.ps1"
        Category    = 'Configuration Changes'
        IsChange    = $true
        IsBios      = $false
        PreSelected = $true
        Status      = 'not-run'
    }
    [PSCustomObject]@{
        Label       = '[CHANGE] Backup Outlook Signatures'
        Path        = "$ScriptRoot\Scripts\ConfigurationChanges\Backup-OutlookSignatures.ps1"
        Category    = 'Configuration Changes'
        IsChange    = $true
        IsBios      = $false
        PreSelected = $true
        Status      = 'not-run'
    }
    [PSCustomObject]@{
        Label       = '[CHANGE] Backup Taskbar Layout'
        Path        = "$ScriptRoot\Scripts\ConfigurationChanges\Backup-TaskbarLayout.ps1"
        Category    = 'Configuration Changes'
        IsChange    = $true
        IsBios      = $false
        PreSelected = $true
        Status      = 'not-run'
    }
    [PSCustomObject]@{
        Label       = '[CHANGE] Escrow BitLocker Key to Entra ID'
        Path        = "$ScriptRoot\Scripts\ConfigurationChanges\Test-BitLockerEscrow.ps1"
        Category    = 'Configuration Changes'
        IsChange    = $true
        IsBios      = $false
        PreSelected = $false
        Status      = 'not-run'
    }
    [PSCustomObject]@{
        Label       = '[CHANGE] Install Dell Command Tools (DCU + DCC)'
        Path        = "$ScriptRoot\Scripts\ConfigurationChanges\Install-DellCommandTools.ps1"
        Category    = 'Configuration Changes'
        IsChange    = $true
        IsBios      = $false
        PreSelected = $false
        Status      = 'not-run'
    }
    [PSCustomObject]@{
        Label       = '[CHANGE] Set Wake-on-LAN (BIOS + NIC + Windows)'
        Path        = "$ScriptRoot\Scripts\ConfigurationChanges\Set-WakeOnLan.ps1"
        Category    = 'Configuration Changes'
        IsChange    = $true
        IsBios      = $false
        PreSelected = $false
        Status      = 'not-run'
    }
    [PSCustomObject]@{
        Label       = '[CHANGE] Update Drivers (Dell DCU)'
        Path        = "$ScriptRoot\Scripts\ConfigurationChanges\Update-Drivers.ps1"
        Category    = 'Configuration Changes'
        IsChange    = $true
        IsBios      = $false
        PreSelected = $false
        Status      = 'not-run'
    }
    [PSCustomObject]@{
        Label       = '[BIOS] Update BIOS (Dell DCU — may reboot)'
        Path        = "$ScriptRoot\Scripts\ConfigurationChanges\Update-Bios.ps1"
        Category    = 'Configuration Changes'
        IsChange    = $true
        IsBios      = $true
        PreSelected = $false
        Status      = 'not-run'
    }

    # --- Autopilot Readiness ---
    [PSCustomObject]@{
        Label       = 'Test Autopilot Profile (local registry/file check)'
        Path        = "$ScriptRoot\Scripts\AutopilotReadiness\Test-AutopilotProfile.ps1"
        Category    = 'Autopilot Readiness'
        IsChange    = $false
        IsBios      = $false
        PreSelected = $false
        Status      = 'not-run'
    }
    [PSCustomObject]@{
        Label       = 'Get Autopilot Assignment (Graph API)'
        Path        = "$ScriptRoot\Scripts\AutopilotReadiness\Get-AutopilotAssignment.ps1"
        Category    = 'Autopilot Readiness'
        IsChange    = $false
        IsBios      = $false
        PreSelected = $false
        Status      = 'not-run'
    }
    [PSCustomObject]@{
        Label       = '[CHANGE] Register Device with Autopilot (uploads hardware hash)'
        Path        = "$ScriptRoot\Scripts\AutopilotReadiness\Register-AutopilotDevice.ps1"
        Category    = 'Autopilot Readiness'
        IsChange    = $true
        IsBios      = $false
        PreSelected = $false
        Status      = 'not-run'
    }
)
#endregion

#region --- Session State ---
function Save-Session {
    $state = $AllScripts | Select-Object Label, Category, Status
    $state | ConvertTo-Json -Depth 3 | Out-File $SessionFile -Force -Encoding UTF8
}

function Load-Session {
    if (Test-Path $SessionFile) {
        try {
            $saved = Get-Content $SessionFile -Raw | ConvertFrom-Json
            foreach ($entry in $saved) {
                $match = $AllScripts | Where-Object { $_.Label -eq $entry.Label } | Select-Object -First 1
                if ($match) { $match.Status = $entry.Status }
            }
        } catch {}
    }
}

Load-Session
#endregion

#region --- Menu Formatter ---
function Get-MenuLabel {
    param($Item)
    $status = switch ($Item.Status) {
        'DONE' { '[DONE]  ' }
        'FAIL' { '[FAIL]  ' }
        'SKIP' { '[SKIP]  ' }
        default { '        ' }
    }
    return "$status$($Item.Label)"
}

$MenuFormatter = {
    param($Item)
    if ($Item -is [string]) { return $Item }  # separator
    if ($Item.IsBios) {
        return "$([char]27)[33m$(Get-MenuLabel $Item)$([char]27)[0m"  # Yellow for BIOS
    } elseif ($Item.IsChange) {
        return "$([char]27)[33m$(Get-MenuLabel $Item)$([char]27)[0m"  # Yellow for change
    } else {
        return "$(Get-MenuLabel $Item)"  # default color
    }
}
#endregion

#region --- Build Menu Items and Initial Selection ---
$MenuItems = @()
$MenuItems += Get-MenuSeparator '--- Data Collection ---'
$MenuItems += $AllScripts | Where-Object { $_.Category -eq 'Data Collection' }
$MenuItems += Get-MenuSeparator '--- Configuration Checks ---'
$MenuItems += $AllScripts | Where-Object { $_.Category -eq 'Configuration Checks' }
$MenuItems += Get-MenuSeparator '--- Configuration Changes ---'
$MenuItems += $AllScripts | Where-Object { $_.Category -eq 'Configuration Changes' }
$MenuItems += Get-MenuSeparator '--- Autopilot Readiness ---'
$MenuItems += $AllScripts | Where-Object { $_.Category -eq 'Autopilot Readiness' }

# Build InitialSelection: indices of pre-selected items (only non-separator items)
$InitialSelection = @()
$idx = 0
foreach ($item in $MenuItems) {
    if ($item -isnot [string] -and $item.PreSelected) {
        $InitialSelection += $idx
    }
    $idx++
}
#endregion

#region --- Main Loop ---
while ($true) {
    Clear-Host
    Write-Host ''
    Write-Host '  Pre-Wipe Toolkit' -ForegroundColor Cyan
    Write-Host '  ─────────────────────────────────────────' -ForegroundColor Cyan
    Write-Host '  SPACE = select/deselect   ENTER = run selected   Q = quit' -ForegroundColor DarkGray
    Write-Host ''

    $showParams = @{
        MenuItems          = $MenuItems
        MultiSelect        = $true
        InitialSelection   = $InitialSelection
        MenuItemFormatter  = $MenuFormatter
    }

    try {
        $Selected = Show-Menu @showParams
    } catch {
        Write-Host "Menu error: $_" -ForegroundColor Red
        break
    }

    # Q / escape / empty = quit
    if ($null -eq $Selected -or $Selected.Count -eq 0) {
        Write-Host ''
        Write-Host '  No scripts selected. Exiting.' -ForegroundColor DarkGray
        break
    }

    # Filter out any separators that may have slipped through
    $ToRun = $Selected | Where-Object { $_ -isnot [string] -and $_.Path }

    if ($ToRun.Count -eq 0) {
        Write-Host '  Nothing to run. Re-opening menu...' -ForegroundColor Yellow
        Start-Sleep -Milliseconds 800
        continue
    }

    # Update InitialSelection to reflect current choices for next iteration
    $InitialSelection = @()
    $idx = 0
    foreach ($item in $MenuItems) {
        if ($item -isnot [string] -and ($ToRun | Where-Object { $_.Label -eq $item.Label })) {
            $InitialSelection += $idx
        }
        $idx++
    }

    Clear-Host
    Write-Host ''
    Write-Host "  Running $($ToRun.Count) selected script(s)..." -ForegroundColor Cyan
    Write-Host '  ─────────────────────────────────────────' -ForegroundColor Cyan

    $runIndex = 0
    foreach ($script in $ToRun) {
        $runIndex++

        Write-Host ''
        Write-Host "  ══════════════════════════════════════════" -ForegroundColor Cyan
        Write-Host "  [$runIndex/$($ToRun.Count)]  $($script.Label)" -ForegroundColor Cyan
        Write-Host "  ══════════════════════════════════════════" -ForegroundColor Cyan
        Write-Host ''

        # BIOS scripts require explicit yes/no confirmation
        if ($script.IsBios) {
            Write-Host '  WARNING: This script will attempt a BIOS update and may trigger a reboot.' -ForegroundColor Yellow
            Write-Host ''
            $confirm = ''
            while ($confirm -notmatch '^(yes|no)$') {
                $confirm = (Read-Host '  Type YES to proceed or NO to skip').ToLower().Trim()
            }
            if ($confirm -ne 'yes') {
                Write-Host '  Skipped by technician.' -ForegroundColor Yellow
                $script.Status = 'SKIP'
                Save-Session
                continue
            }
        }

        if (-not (Test-Path $script.Path)) {
            Write-Host "  ERROR: Script not found: $($script.Path)" -ForegroundColor Red
            $script.Status = 'FAIL'
            Save-Session
            Write-Host ''
            Read-Host '  Press Enter to continue'
            continue
        }

        try {
            & $script.Path
            $script.Status = 'DONE'
        } catch {
            Write-Host ''
            Write-Host "  ERROR running $($script.Label):" -ForegroundColor Red
            Write-Host "  $_" -ForegroundColor Red
            $script.Status = 'FAIL'
        }

        Save-Session
        Start-Sleep -Milliseconds 300

        # Single pause after each script — only where technician verification needed
        $needsPause = $script.IsChange -or $script.Status -eq 'FAIL' -or $script.Category -eq 'Autopilot Readiness'
        if ($needsPause) {
            Write-Host ''
            Read-Host '  Press Enter to continue'
        } else {
            Start-Sleep -Milliseconds 600
        }
    }

    Write-Host ''
    Write-Host '  ─────────────────────────────────────────' -ForegroundColor Cyan
    Write-Host "  Run complete. $($ToRun.Where({ $_.Status -eq 'DONE' }).Count) succeeded, $($ToRun.Where({ $_.Status -eq 'FAIL' }).Count) failed." -ForegroundColor Cyan
    Write-Host ''
    Read-Host '  Press Enter to return to menu (or Ctrl+C to exit)'
}

Write-Host ''
Write-Host '  Session saved to: ' -ForegroundColor DarkGray -NoNewline
Write-Host $SessionFile -ForegroundColor Cyan
Write-Host ''
#endregion
