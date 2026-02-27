<#
.SYNOPSIS
    Interactive orchestrator for the Pre-Wipe Toolkit.

.DESCRIPTION
    Menu-driven workflow that guides a tech through all 29 pre-wipe preparation
    steps across four categories: Data Collection, Configuration Checks,
    Configuration Changes, and Autopilot Readiness.

    Features:
    - Arrow-key menu navigation via PSMenu module
    - Session state persistence to C:\PreWipeOutput\session.json
    - Resume on reopen if session.json exists
    - Per-step status tracking (DONE / FAIL / SKIP / not-run)
    - Run All, Summary, Export, and Reset workflow actions

.PARAMETER NonInteractive
    Suppresses all interactive prompts and menu display. Emits current session
    state as a JSON object to stdout, then exits with code 0.

.NOTES
    Requirements  : PSMenu module (Install-Module PSMenu), Administrator privileges
    Output dir    : C:\PreWipeOutput\
    Log dir       : C:\PreWipeOutput\Logs\
    Does NOT modify any script in .\Scripts\ — calls them by path only.
    Source repos used: (none — orchestrator only; delegates to phase scripts)

.EXAMPLE
    .\Start-PreWipeToolkit.ps1

    Launches the interactive Pre-Wipe Toolkit menu.

.EXAMPLE
    .\Start-PreWipeToolkit.ps1 -NonInteractive

    Emits current session state as JSON to stdout and exits. Skips all prompts
    and menu interaction. Useful for automated status polling.
#>

[CmdletBinding()]
param(
    [switch]$NonInteractive
)

# ─────────────────────────────────────────────────────────────────────────────
# ADMIN ELEVATION CHECK
# ─────────────────────────────────────────────────────────────────────────────
$_principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $_principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "ERROR: This script must run as Administrator." -ForegroundColor Red
    Write-Host "Right-click PowerShell > Run as Administrator, then try again." -ForegroundColor Yellow
    exit 1
}

# ─────────────────────────────────────────────────────────────────────────────
# CONSTANTS, OUTPUT DIRECTORY & LOGGING
# (defined before PSMenu check so Write-ErrorLog is available everywhere)
# ─────────────────────────────────────────────────────────────────────────────
$ScriptName  = 'Start-PreWipeToolkit'
$OutputRoot  = 'C:\PreWipeOutput'
$LogDir      = Join-Path $OutputRoot 'Logs'
$LogFile     = Join-Path $LogDir "$ScriptName`_$(Get-Date -Format 'yyyyMMdd').log"
$ErrorLog    = Join-Path $LogDir "$ScriptName`_Errors_$(Get-Date -Format 'yyyyMMdd').log"
$SessionFile = Join-Path $OutputRoot 'session.json'

foreach ($dir in @($OutputRoot, $LogDir)) {
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
}

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $entry = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message"
    $entry | Add-Content -Path $LogFile -Encoding UTF8
    if (-not $NonInteractive) {
        $color = switch ($Level) {
            'WARN'  { 'Yellow' }
            'ERROR' { 'Red' }
            default { 'Gray' }
        }
        Write-Host "  $Message" -ForegroundColor $color
    }
}

function Write-ErrorLog {
    param([string]$Message)
    $entry = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$ScriptName] ERROR: $Message"
    $entry | Add-Content -Path $ErrorLog -Encoding UTF8
    Write-Log -Message "ERROR: $Message" -Level 'ERROR'
}

# ─────────────────────────────────────────────────────────────────────────────
# PSMODULE: PSMenu  (skipped in -NonInteractive mode)
# ─────────────────────────────────────────────────────────────────────────────
if (-not $NonInteractive) {
    if (-not (Get-Module -ListAvailable -Name PSMenu)) {
        Write-Host ''
        Write-Host '  PSMenu module is not installed.' -ForegroundColor Yellow
        Write-Host '  This toolkit requires PSMenu for interactive arrow-key menus.' -ForegroundColor Yellow
        Write-Host ''
        $answer = Read-Host '  Install PSMenu now from PSGallery? (Y/N)'
        if ($answer -notmatch '^[Yy]') {
            Write-Host '  PSMenu is required. Exiting.' -ForegroundColor Red
            exit 1
        }
        try {
            Write-Host '  Installing PSMenu...' -ForegroundColor Cyan
            Install-Module -Name PSMenu -Scope AllUsers -Force -ErrorAction Stop
            Write-Host '  PSMenu installed successfully.' -ForegroundColor Green
            Write-Host ''
        }
        catch {
            Write-ErrorLog "PSMenu install failed: $_"
            Write-Host '  Run manually: Install-Module PSMenu -Scope AllUsers' -ForegroundColor Yellow
            exit 1
        }
    }

    try {
        Import-Module PSMenu -ErrorAction Stop
    }
    catch {
        Write-ErrorLog "PSMenu import failed: $_"
        exit 1
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# HARDWARE INFO
# ─────────────────────────────────────────────────────────────────────────────
$script:ComputerName = $env:COMPUTERNAME
$script:CurrentUser  = $env:USERNAME

try {
    $script:_bios    = Get-CimInstance -ClassName Win32_BIOS -ErrorAction SilentlyContinue
    $script:SerialNumber = if ($script:_bios -and $script:_bios.SerialNumber) {
        $script:_bios.SerialNumber.Trim()
    }
    else { 'Unknown' }
}
catch {
    $script:SerialNumber = 'Unknown'
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP DEFINITIONS  (29 steps — ordered by category)
# ScriptPath is relative to $PSScriptRoot
# ─────────────────────────────────────────────────────────────────────────────
$script:Steps = @(
    # ── Data Collection ───────────────────────────────────────────────────────
    [PSCustomObject]@{
        Index       = 1
        Phase       = 'DataCollection'
        DisplayName = 'Scan for Unbacked Data & Non-Std Apps'
        ScriptPath  = 'Scripts\DataCollection\Find-UnbackedData.ps1'
        Status      = 'not-run'
        IsWorkflow  = $false
    }
    [PSCustomObject]@{
        Index       = 2
        Phase       = 'DataCollection'
        DisplayName = 'Check Downloads Folder Sizes'
        ScriptPath  = 'Scripts\DataCollection\Get-DownloadsSize.ps1'
        Status      = 'not-run'
        IsWorkflow  = $false
    }
    [PSCustomObject]@{
        Index       = 3
        Phase       = 'DataCollection'
        DisplayName = 'Get Drive Mappings'
        ScriptPath  = 'Scripts\DataCollection\Get-DriveMappings.ps1'
        Status      = 'not-run'
        IsWorkflow  = $false
    }
    [PSCustomObject]@{
        Index       = 4
        Phase       = 'DataCollection'
        DisplayName = 'List Physical Printers'
        ScriptPath  = 'Scripts\DataCollection\Get-Printers.ps1'
        Status      = 'not-run'
        IsWorkflow  = $false
    }
    [PSCustomObject]@{
        Index       = 5
        Phase       = 'DataCollection'
        DisplayName = 'Get Windows Product Key'
        ScriptPath  = 'Scripts\DataCollection\Get-WindowsProductKey.ps1'
        Status      = 'not-run'
        IsWorkflow  = $false
    }
    [PSCustomObject]@{
        Index       = 6
        Phase       = 'DataCollection'
        DisplayName = 'Get Installed Applications'
        ScriptPath  = 'Scripts\DataCollection\Get-InstalledApplications.ps1'
        Status      = 'not-run'
        IsWorkflow  = $false
    }
    [PSCustomObject]@{
        Index       = 7
        Phase       = 'DataCollection'
        DisplayName = 'Get Device Health Report'
        ScriptPath  = 'Scripts\DataCollection\Get-DeviceHealth.ps1'
        Status      = 'not-run'
        IsWorkflow  = $false
    }

    # ── Configuration Checks ──────────────────────────────────────────────────
    [PSCustomObject]@{
        Index       = 8
        Phase       = 'ConfigurationChecks'
        DisplayName = 'Test OneDrive KFM Status'
        ScriptPath  = 'Scripts\ConfigurationChecks\Test-OneDriveKFM.ps1'
        Status      = 'not-run'
        IsWorkflow  = $false
    }
    [PSCustomObject]@{
        Index       = 9
        Phase       = 'ConfigurationChecks'
        DisplayName = 'Test OneDrive Sync Status'
        ScriptPath  = 'Scripts\ConfigurationChecks\Test-OneDriveSyncStatus.ps1'
        Status      = 'not-run'
        IsWorkflow  = $false
    }
    [PSCustomObject]@{
        Index       = 10
        Phase       = 'ConfigurationChecks'
        DisplayName = 'Get Storage Controller Mode'
        ScriptPath  = 'Scripts\ConfigurationChecks\Get-StorageMode.ps1'
        Status      = 'not-run'
        IsWorkflow  = $false
    }
    [PSCustomObject]@{
        Index       = 11
        Phase       = 'ConfigurationChecks'
        DisplayName = 'Test BIOS Version (Dell)'
        ScriptPath  = 'Scripts\ConfigurationChecks\Test-BiosVersion.ps1'
        Status      = 'not-run'
        IsWorkflow  = $false
    }
    [PSCustomObject]@{
        Index       = 12
        Phase       = 'ConfigurationChecks'
        DisplayName = 'Test Driver Status (Dell DCU scan)'
        ScriptPath  = 'Scripts\ConfigurationChecks\Test-DriverStatus.ps1'
        Status      = 'not-run'
        IsWorkflow  = $false
    }
    [PSCustomObject]@{
        Index       = 13
        Phase       = 'ConfigurationChecks'
        DisplayName = 'Test Wake-on-LAN Settings'
        ScriptPath  = 'Scripts\ConfigurationChecks\Test-WakeOnLan.ps1'
        Status      = 'not-run'
        IsWorkflow  = $false
    }
    [PSCustomObject]@{
        Index       = 14
        Phase       = 'ConfigurationChecks'
        DisplayName = 'Test Windows Recovery Environment (WinRE)'
        ScriptPath  = 'Scripts\ConfigurationChecks\Test-WinRE.ps1'
        Status      = 'not-run'
        IsWorkflow  = $false
    }

    # ── Configuration Changes ─────────────────────────────────────────────────
    [PSCustomObject]@{
        Index       = 15
        Phase       = 'ConfigurationChanges'
        DisplayName = '[CHANGE] Backup Browser Bookmarks'
        ScriptPath  = 'Scripts\ConfigurationChanges\Backup-BrowserBookmarks.ps1'
        Status      = 'not-run'
        IsWorkflow  = $false
    }
    [PSCustomObject]@{
        Index       = 16
        Phase       = 'ConfigurationChanges'
        DisplayName = '[CHANGE] Backup Desktop Background'
        ScriptPath  = 'Scripts\ConfigurationChanges\Backup-DesktopBackground.ps1'
        Status      = 'not-run'
        IsWorkflow  = $false
    }
    [PSCustomObject]@{
        Index       = 17
        Phase       = 'ConfigurationChanges'
        DisplayName = '[CHANGE] Backup Outlook Signatures'
        ScriptPath  = 'Scripts\ConfigurationChanges\Backup-OutlookSignatures.ps1'
        Status      = 'not-run'
        IsWorkflow  = $false
    }
    [PSCustomObject]@{
        Index       = 18
        Phase       = 'ConfigurationChanges'
        DisplayName = '[CHANGE] Backup Taskbar Layout'
        ScriptPath  = 'Scripts\ConfigurationChanges\Backup-TaskbarLayout.ps1'
        Status      = 'not-run'
        IsWorkflow  = $false
    }
    [PSCustomObject]@{
        Index       = 19
        Phase       = 'ConfigurationChanges'
        DisplayName = '[CHANGE] Backup Wi-Fi Profiles'
        ScriptPath  = 'Scripts\ConfigurationChanges\Backup-WiFiProfiles.ps1'
        Status      = 'not-run'
        IsWorkflow  = $false
    }
    [PSCustomObject]@{
        Index       = 20
        Phase       = 'ConfigurationChanges'
        DisplayName = '[CHANGE] Escrow BitLocker Key to Entra ID'
        ScriptPath  = 'Scripts\ConfigurationChanges\Test-BitLockerEscrow.ps1'
        Status      = 'not-run'
        IsWorkflow  = $false
    }
    [PSCustomObject]@{
        Index       = 21
        Phase       = 'ConfigurationChanges'
        DisplayName = '[CHANGE] Install Dell Command Tools (DCU + DCC)'
        ScriptPath  = 'Scripts\ConfigurationChanges\Install-DellCommandTools.ps1'
        Status      = 'not-run'
        IsWorkflow  = $false
    }
    [PSCustomObject]@{
        Index       = 22
        Phase       = 'ConfigurationChanges'
        DisplayName = '[CHANGE] Set Wake-on-LAN (BIOS + NIC + Windows)'
        ScriptPath  = 'Scripts\ConfigurationChanges\Set-WakeOnLan.ps1'
        Status      = 'not-run'
        IsWorkflow  = $false
    }
    [PSCustomObject]@{
        Index       = 23
        Phase       = 'ConfigurationChanges'
        DisplayName = '[CHANGE] Update Drivers (Dell DCU)'
        ScriptPath  = 'Scripts\ConfigurationChanges\Update-Drivers.ps1'
        Status      = 'not-run'
        IsWorkflow  = $false
    }
    [PSCustomObject]@{
        Index       = 24
        Phase       = 'ConfigurationChanges'
        DisplayName = '[BIOS] Update BIOS (Dell DCU — may reboot)'
        ScriptPath  = 'Scripts\ConfigurationChanges\Update-Bios.ps1'
        Status      = 'not-run'
        IsWorkflow  = $false
    }

    # ── Autopilot Readiness ───────────────────────────────────────────────────
    [PSCustomObject]@{
        Index       = 25
        Phase       = 'AutopilotReadiness'
        DisplayName = 'Test Autopilot Profile (local registry/file check)'
        ScriptPath  = 'Scripts\AutopilotReadiness\Test-AutopilotProfile.ps1'
        Status      = 'not-run'
        IsWorkflow  = $false
    }
    [PSCustomObject]@{
        Index       = 26
        Phase       = 'AutopilotReadiness'
        DisplayName = 'Test Autopilot Readiness'
        ScriptPath  = 'Scripts\AutopilotReadiness\Test-AutopilotReadiness.ps1'
        Status      = 'not-run'
        IsWorkflow  = $false
    }
    [PSCustomObject]@{
        Index       = 27
        Phase       = 'AutopilotReadiness'
        DisplayName = 'Get Autopilot Assignment (Graph API)'
        ScriptPath  = 'Scripts\AutopilotReadiness\Get-AutopilotAssignment.ps1'
        Status      = 'not-run'
        IsWorkflow  = $false
    }
    [PSCustomObject]@{
        Index       = 28
        Phase       = 'AutopilotReadiness'
        DisplayName = '[CHANGE] Register Device with Autopilot'
        ScriptPath  = 'Scripts\AutopilotReadiness\Register-AutopilotDevice.ps1'
        Status      = 'not-run'
        IsWorkflow  = $false
    }
    [PSCustomObject]@{
        Index       = 29
        Phase       = 'AutopilotReadiness'
        DisplayName = 'Get Pre-Wipe Summary'
        ScriptPath  = 'Scripts\AutopilotReadiness\Get-PreWipeSummary.ps1'
        Status      = 'not-run'
        IsWorkflow  = $false
    }
)

# Workflow items — appear at the bottom of the menu, no status badge
$script:WorkflowItems = @(
    [PSCustomObject]@{ Index = 0; DisplayName = 'Run All (Sequential)';  Action = 'RunAll';   IsWorkflow = $true }
    [PSCustomObject]@{ Index = 0; DisplayName = 'View Session Summary';  Action = 'Summary';  IsWorkflow = $true }
    [PSCustomObject]@{ Index = 0; DisplayName = 'Export Session Report'; Action = 'Export';   IsWorkflow = $true }
    [PSCustomObject]@{ Index = 0; DisplayName = 'Reset Session';         Action = 'Reset';    IsWorkflow = $true }
    [PSCustomObject]@{ Index = 0; DisplayName = 'Exit';                  Action = 'Exit';     IsWorkflow = $true }
)

# ─────────────────────────────────────────────────────────────────────────────
# SESSION MANAGEMENT
# ─────────────────────────────────────────────────────────────────────────────

function Initialize-Session {
    $steps = @{}
    foreach ($step in $script:Steps) {
        $steps["$($step.Index)"] = @{ Status = 'not-run'; Timestamp = $null; ExitCode = $null }
    }
    return [PSCustomObject]@{
        StartTime    = (Get-Date -Format 'o')
        ComputerName = $script:ComputerName
        SerialNumber = $script:SerialNumber
        CurrentUser  = $script:CurrentUser
        Steps        = $steps
    }
}

function Import-Session {
    if (-not (Test-Path $SessionFile)) { return Initialize-Session }
    try {
        $raw   = Get-Content $SessionFile -Raw | ConvertFrom-Json
        $steps = @{}
        foreach ($prop in $raw.Steps.PSObject.Properties) {
            $steps[$prop.Name] = @{
                Status    = $prop.Value.Status
                Timestamp = $prop.Value.Timestamp
                ExitCode  = $prop.Value.ExitCode
            }
        }
        # Apply persisted statuses back onto the live step objects
        foreach ($step in $script:Steps) {
            $key = "$($step.Index)"
            if ($steps.ContainsKey($key) -and $steps[$key].Status) {
                $step.Status = $steps[$key].Status
            }
        }
        if (-not $NonInteractive) { Write-Host "  Session resumed from $SessionFile" -ForegroundColor Cyan }
        return [PSCustomObject]@{
            StartTime    = $raw.StartTime
            ComputerName = $raw.ComputerName
            SerialNumber = $raw.SerialNumber
            CurrentUser  = $raw.CurrentUser
            Steps        = $steps
        }
    }
    catch {
        if (-not $NonInteractive) { Write-Host "  Could not load session.json ($_). Starting fresh." -ForegroundColor Yellow }
        return Initialize-Session
    }
}

function Save-Session {
    try {
        $script:Session | ConvertTo-Json -Depth 5 | Set-Content $SessionFile -Encoding UTF8
    }
    catch {
        Write-Host "  Warning: Could not save session.json: $_" -ForegroundColor Yellow
    }
}

function Update-SessionStep {
    param([int]$Index, [string]$Status, $ExitCode)
    $key = "$Index"
    if (-not $script:Session.Steps.ContainsKey($key)) {
        $script:Session.Steps[$key] = @{}
    }
    $script:Session.Steps[$key].Status    = $Status
    $script:Session.Steps[$key].Timestamp = (Get-Date -Format 'o')
    $script:Session.Steps[$key].ExitCode  = $ExitCode
}

# ─────────────────────────────────────────────────────────────────────────────
# DISPLAY HELPERS
# ─────────────────────────────────────────────────────────────────────────────

function Write-CyanBox {
    param(
        [string[]]$Lines,
        [int]$MinWidth = 58
    )

    if (-not $Lines -or $Lines.Count -eq 0) {
        $Lines = @('')
    }

    $normalized = @($Lines | ForEach-Object {
        if ($null -eq $_) { '' } else { [string]$_ }
    })

    $maxLength = ($normalized | Measure-Object -Property Length -Maximum).Maximum
    if ($null -eq $maxLength) { $maxLength = 0 }

    $innerWidth = [Math]::Max($maxLength, $MinWidth)
    $bar = '═' * ($innerWidth + 2)

    Write-Host ''
    Write-Host "╔$bar╗" -ForegroundColor Cyan
    foreach ($line in $normalized) {
        Write-Host ("║ {0} ║" -f $line.PadRight($innerWidth)) -ForegroundColor Cyan
    }
    Write-Host "╚$bar╝" -ForegroundColor Cyan
    Write-Host ''
}

function Show-Menu {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory, Position = 0)][array]$MenuItems,
        [switch]$ReturnIndex,
        [switch]$MultiSelect,
        [ConsoleColor]$ItemFocusColor = [ConsoleColor]::Cyan,
        [ScriptBlock]$MenuItemFormatter = {
            param($M)
            if ($null -eq $M) { '' } else { $M.ToString() }
        },
        [array]$InitialSelection = @(),
        [ScriptBlock]$Callback = $null
    )

    if ($MultiSelect) {
        throw 'MultiSelect is not supported by this menu renderer.'
    }

    if (-not $MenuItems -or $MenuItems.Count -eq 0) {
        return $null
    }

    $separatorToken = Get-MenuSeparator
    $entries = @()

    for ($i = 0; $i -lt $MenuItems.Count; $i++) {
        $item = $MenuItems[$i]
        if ($null -eq $item) { continue }

        $isSeparator = [object]::ReferenceEquals($item, $separatorToken)
        $text = ''

        if (-not $isSeparator) {
            $text = & $MenuItemFormatter $item
            if ([string]::IsNullOrWhiteSpace([string]$text)) {
                $text = $item.ToString()
            }
        }

        $entries += [PSCustomObject]@{
            ArrayIndex  = $i
            Item        = $item
            IsSeparator = $isSeparator
            IsSelectable = (-not $isSeparator)
            Text        = ([string]$text).TrimEnd()
        }
    }

    $selectable = @($entries | Where-Object { $_.IsSelectable })
    if ($selectable.Count -eq 0) {
        return $null
    }

    $currentArrayIndex = if ($InitialSelection -and $InitialSelection.Count -gt 0) {
        [int]$InitialSelection[0]
    }
    else {
        [int]$selectable[0].ArrayIndex
    }
    if (-not ($entries | Where-Object { $_.ArrayIndex -eq $currentArrayIndex -and $_.IsSelectable })) {
        $currentArrayIndex = [int]$selectable[0].ArrayIndex
    }

    $windowWidth = [Math]::Max(40, (Get-Host).UI.RawUI.WindowSize.Width)
    $windowHeight = [Math]::Max(18, (Get-Host).UI.RawUI.WindowSize.Height)
    $maxVisibleItems = [Math]::Max(6, [Math]::Min($entries.Count, $windowHeight - 12))

    $maxTextLength = ($entries | Where-Object { -not $_.IsSeparator } | Measure-Object -Property Text.Length -Maximum).Maximum
    if ($null -eq $maxTextLength) { $maxTextLength = 0 }

    $title = 'Menu'
    $hint = 'Use Up/Down arrows to move, Enter to select, Esc to cancel'
    $targetWidth = [Math]::Max(($maxTextLength + 4), [Math]::Max($title.Length, $hint.Length))
    $innerWidth = [Math]::Max(58, [Math]::Min($targetWidth, $windowWidth - 6))
    $topIndex = 0
    $startTop = [Console]::CursorTop

    $render = {
        if ([Console]::CursorTop -ne $startTop) {
            [Console]::SetCursorPosition(0, $startTop)
        }

        $currentVisiblePos = 0
        for ($j = 0; $j -lt $entries.Count; $j++) {
            if ($entries[$j].ArrayIndex -eq $currentArrayIndex) {
                $currentVisiblePos = $j
                break
            }
        }

        if ($currentVisiblePos -lt $topIndex) {
            $topIndex = $currentVisiblePos
        }
        if ($currentVisiblePos -ge ($topIndex + $maxVisibleItems)) {
            $topIndex = $currentVisiblePos - $maxVisibleItems + 1
        }

        $bottomIndex = [Math]::Min($entries.Count - 1, $topIndex + $maxVisibleItems - 1)
        $visibleEntries = @()
        for ($j = $topIndex; $j -le $bottomIndex; $j++) {
            $visibleEntries += $entries[$j]
        }

        $bar = '═' * ($innerWidth + 2)
        Write-Host "╔$bar╗" -ForegroundColor Cyan
        Write-Host ("║ {0} ║" -f $title.PadRight($innerWidth)) -ForegroundColor Cyan
        Write-Host ("║ {0} ║" -f ('─' * $innerWidth)) -ForegroundColor Cyan

        foreach ($entry in $visibleEntries) {
            if ($entry.IsSeparator) {
                $content = ('─' * $innerWidth)
            }
            else {
                $prefix = if ($entry.ArrayIndex -eq $currentArrayIndex) { '> ' } else { '  ' }
                $content = $prefix + $entry.Text
                if ($content.Length -gt $innerWidth) {
                    $content = $content.Substring(0, $innerWidth)
                }
                $content = $content.PadRight($innerWidth)
            }
            Write-Host ("║ {0} ║" -f $content) -ForegroundColor Cyan
        }

        for ($j = $visibleEntries.Count; $j -lt $maxVisibleItems; $j++) {
            Write-Host ("║ {0} ║" -f ''.PadRight($innerWidth)) -ForegroundColor Cyan
        }

        Write-Host ("║ {0} ║" -f ('─' * $innerWidth)) -ForegroundColor Cyan
        $pageInfo = if ($entries.Count -gt $maxVisibleItems) {
            "Showing {0}-{1} of {2}" -f ($topIndex + 1), ($bottomIndex + 1), $entries.Count
        }
        else {
            $hint
        }
        if ($pageInfo.Length -gt $innerWidth) {
            $pageInfo = $pageInfo.Substring(0, $innerWidth)
        }
        Write-Host ("║ {0} ║" -f $pageInfo.PadRight($innerWidth)) -ForegroundColor Cyan
        Write-Host "╚$bar╝" -ForegroundColor Cyan
    }

    & $render
    while ($true) {
        if ($Callback) { & $Callback }
        $key = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
        switch ($key.VirtualKeyCode) {
            27 { return $null } # Esc
            13 { # Enter
                if ($ReturnIndex) {
                    return $currentArrayIndex
                }
                $selectedEntry = $entries | Where-Object { $_.ArrayIndex -eq $currentArrayIndex } | Select-Object -First 1
                return $selectedEntry.Item
            }
            38 { # Up
                $pos = ($entries | ForEach-Object { $_.ArrayIndex }).IndexOf($currentArrayIndex)
                do {
                    $pos--
                    if ($pos -lt 0) { $pos = $entries.Count - 1 }
                } until ($entries[$pos].IsSelectable)
                $currentArrayIndex = $entries[$pos].ArrayIndex
                & $render
            }
            40 { # Down
                $pos = ($entries | ForEach-Object { $_.ArrayIndex }).IndexOf($currentArrayIndex)
                do {
                    $pos++
                    if ($pos -ge $entries.Count) { $pos = 0 }
                } until ($entries[$pos].IsSelectable)
                $currentArrayIndex = $entries[$pos].ArrayIndex
                & $render
            }
        }
    }
}

function Show-Header {
    $steps = @($script:Steps)
    $done  = @($steps | Where-Object { $_.Status -eq 'DONE' }).Count
    $total = $steps.Count
    $start = try { ([datetime]$script:Session.StartTime).ToString('yyyy-MM-dd HH:mm') } catch { 'New session' }

    $lines = @(
        '___________________________________________  __________________    ______________         '
        '___________________________    |_  ___/__  / / /__  ____/_  ___/    ___  __/_  __ \       '
        '__________________________  /| |____ \__  /_/ /__  __/  _____ \     __  /  _  / / /       '
        '_________________________  ___ |___/ /_  __  / _  /___  ____/ /     _  /   / /_/ /        '
        '________________________/_/  |_/____/ /_/ /_/  /_____/  /____/      /_/    \____/         '
        '                                                                                          '
        '________________________________  ____________________________________ _______________    '
        '_______________________    |_  / / /__  __/_  __ \__  __ \___  _/__  / __  __ \__  __/    '
        '______________________  /| |  / / /__  /  _  / / /_  /_/ /__  / __  /  _  / / /_  /       '
        '_____________________  ___ / /_/ / _  /   / /_/ /_  ____/__/ /  _  /___/ /_/ /_  /        '
        '____________________/_/  |_\____/  /_/    \____/ /_/     /___/  /_____/\____/ /_/         '
        '                                                                                          '
        'An end to end pre-wipe preparation toolkit for Dell devices being enrolled into Autopilot.'
        'Created by Nathan Sol based various community scripts.                                    '
        'Version 1.0 — 2024-06-01                                                                  '
        ''
        ("Computer  : {0}             Serial: {1}" -f $script:ComputerName, $script:SerialNumber)
        ("User      : {0}             Session: {1}" -f $script:CurrentUser, $start)
        ("Progress  : {0} of {1} steps complete" -f $done, $total)
    )

    Write-CyanBox -Lines $lines
}

function Show-StepBanner {
    param([PSCustomObject]$Step)

    $lines = @(
        ("Step     : {0} - {1}" -f $Step.Index, $Step.DisplayName)
        ("Phase    : {0}" -f $Step.Phase)
        ("Script   : {0}" -f $Step.ScriptPath)
    )

    Write-CyanBox -Lines $lines
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP EXECUTION
# ─────────────────────────────────────────────────────────────────────────────

function Invoke-Step {
    param(
        [PSCustomObject]$Step,
        [switch]$InRunAll   # suppresses "press any key" pause when called from Run All
    )

    Clear-Host
    Show-StepBanner -Step $Step

    $fullPath = Join-Path $PSScriptRoot $Step.ScriptPath

    if (-not (Test-Path $fullPath)) {
        Write-Host "  [SKIP] Script not found: $($Step.ScriptPath)" -ForegroundColor Yellow
        $Step.Status = 'SKIP'
        Update-SessionStep -Index $Step.Index -Status 'SKIP' -ExitCode $null
        Save-Session
        if (-not $InRunAll) {
            Write-Host ''
            Write-Host '  Press any key to return to menu...' -ForegroundColor DarkGray
            $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
        }
        return
    }

    Write-Host "  $('─' * 58)" -ForegroundColor DarkGray
    Write-Host ''

    # Reset before call so we capture this script's exit code, not a stale one
    $LASTEXITCODE = 0
    $exitCode = 0

    try {
        & $fullPath
        $exitCode = if ($null -ne $LASTEXITCODE) { $LASTEXITCODE } else { 0 }
    }
    catch {
        Write-Host ''
        Write-Host "  [FAIL] Unhandled error: $_" -ForegroundColor Red
        Write-ErrorLog "Step $($Step.Index) ($($Step.DisplayName)) threw: $_"
        $exitCode = -1
    }

    Write-Host ''
    Write-Host "  $('─' * 58)" -ForegroundColor DarkGray

    if ($exitCode -eq 0) {
        $Step.Status = 'DONE'
        Write-Host '  [PASS] Completed successfully.' -ForegroundColor Green
    }
    else {
        $Step.Status = 'FAIL'
        Write-Host "  [FAIL] Exited with code: $exitCode" -ForegroundColor Red
    }

    Update-SessionStep -Index $Step.Index -Status $Step.Status -ExitCode $exitCode
    Save-Session

    if (-not $InRunAll) {
        Write-Host ''
        Write-Host '  Press any key to return to menu...' -ForegroundColor DarkGray
        $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# WORKFLOW: RUN ALL
# ─────────────────────────────────────────────────────────────────────────────

function Invoke-RunAll {
    Clear-Host

    Write-CyanBox -Lines @(
        'Run All Steps'
        'Runs all 29 steps in order.'
        'Scripts run interactively. Respond to prompts as each script runs.'
        'Progress is saved after each step.'
    )

    $confirm = Show-Menu -MenuItems @('Yes, run all steps', 'Cancel')
    if ($confirm -ne 'Yes, run all steps') { return }

    $counts = @{ DONE = 0; FAIL = 0; SKIP = 0 }

    foreach ($step in $script:Steps) {
        Invoke-Step -Step $step -InRunAll
        switch ($step.Status) {
            'DONE' { $counts.DONE++ }
            'FAIL' { $counts.FAIL++ }
            'SKIP' { $counts.SKIP++ }
        }
        Start-Sleep -Milliseconds 800
    }

    Write-CyanBox -Lines @(
        'Run All Complete'
        ("Passed  : {0}" -f $counts.DONE)
        ("Failed  : {0}" -f $counts.FAIL)
        ("Skipped : {0}" -f $counts.SKIP)
    )

    Write-Host 'Press any key to return to menu...' -ForegroundColor Cyan
    $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
}

# ─────────────────────────────────────────────────────────────────────────────
# WORKFLOW: SESSION SUMMARY
# ─────────────────────────────────────────────────────────────────────────────

function Show-SessionSummary {
    Clear-Host
    $lines = @('Session Summary')

    foreach ($group in ($script:Steps | Group-Object Phase)) {
        $lines += ''
        $lines += ("-- {0}" -f $group.Name)
        foreach ($step in $group.Group) {
            $badge = switch ($step.Status) {
                'DONE'    { '[DONE]' }
                'FAIL'    { '[FAIL]' }
                'SKIP'    { '[SKIP]' }
                default   { '[    ]' }
            }
            $lines += ("  {0}  {1}" -f $badge, $step.DisplayName)
        }
    }

    $done  = ($script:Steps | Where-Object { $_.Status -eq 'DONE' }).Count
    $fail  = ($script:Steps | Where-Object { $_.Status -eq 'FAIL' }).Count
    $skip  = ($script:Steps | Where-Object { $_.Status -eq 'SKIP' }).Count
    $norun = ($script:Steps | Where-Object { $_.Status -eq 'not-run' }).Count
    $lines += ''
    $lines += ("Passed  : {0}" -f $done)
    $lines += ("Failed  : {0}" -f $fail)
    $lines += ("Skipped : {0}" -f $skip)
    $lines += ("Not Run : {0}" -f $norun)

    Write-CyanBox -Lines $lines
    Write-Host 'Press any key to return to menu...' -ForegroundColor Cyan
    $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
}

# ─────────────────────────────────────────────────────────────────────────────
# WORKFLOW: EXPORT REPORT
# ─────────────────────────────────────────────────────────────────────────────

function Export-SessionReport {
    Clear-Host
    Write-Host ''
    Write-Host '  Exporting Session Report...' -ForegroundColor Cyan
    Write-Host ''

    $stamp    = Get-Date -Format 'yyyyMMdd-HHmmss'
    $baseName = "PreWipeReport_$($script:ComputerName)_$stamp"
    $jsonPath = Join-Path $OutputRoot "$baseName.json"
    $txtPath  = Join-Path $OutputRoot "$baseName.txt"

    # JSON
    try {
        $script:Session | ConvertTo-Json -Depth 5 | Set-Content $jsonPath -Encoding UTF8 -Force
        Write-Host "  JSON : $jsonPath" -ForegroundColor Green
    }
    catch {
        Write-ErrorLog "JSON export failed: $_"
        Write-Host "  JSON export failed: $_" -ForegroundColor Red
    }

    # Readable TXT
    try {
        $lines = [System.Collections.Generic.List[string]]::new()
        $lines.Add('Pre-Wipe Toolkit — Session Report')
        $lines.Add('==================================')
        $lines.Add("Computer     : $($script:ComputerName)")
        $lines.Add("Serial       : $($script:SerialNumber)")
        $lines.Add("User         : $($script:CurrentUser)")
        $lines.Add("Session Start: $($script:Session.StartTime)")
        $lines.Add("Generated    : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
        $lines.Add('')

        foreach ($group in ($script:Steps | Group-Object Phase)) {
            $lines.Add("--- $($group.Name) ---")
            foreach ($step in $group.Group) {
                $stepData = $script:Session.Steps["$($step.Index)"]
                $ts       = if ($stepData -and $stepData.Timestamp) { "  ($($stepData.Timestamp))" } else { '' }
                $lines.Add("  [$($step.Status.PadRight(7))] $($step.DisplayName)$ts")
            }
            $lines.Add('')
        }

        $done  = ($script:Steps | Where-Object { $_.Status -eq 'DONE' }).Count
        $fail  = ($script:Steps | Where-Object { $_.Status -eq 'FAIL' }).Count
        $skip  = ($script:Steps | Where-Object { $_.Status -eq 'SKIP' }).Count
        $norun = ($script:Steps | Where-Object { $_.Status -eq 'not-run' }).Count
        $lines.Add('--- Summary ---')
        $lines.Add("  Passed  : $done")
        $lines.Add("  Failed  : $fail")
        $lines.Add("  Skipped : $skip")
        $lines.Add("  Not Run : $norun")

        $lines | Set-Content $txtPath -Encoding UTF8 -Force
        Write-Host "  TXT  : $txtPath" -ForegroundColor Green
    }
    catch {
        Write-ErrorLog "TXT export failed: $_"
        Write-Host "  TXT export failed: $_" -ForegroundColor Red
    }

    Write-Host ''
    Write-Host '  Press any key to return to menu...' -ForegroundColor DarkGray
    $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
}

# ─────────────────────────────────────────────────────────────────────────────
# WORKFLOW: RESET SESSION
# ─────────────────────────────────────────────────────────────────────────────

function Invoke-ResetSession {
    Clear-Host
    Write-Host ''
    Write-Host '  Reset Session' -ForegroundColor White
    Write-Host '  This clears all step statuses and deletes session.json.' -ForegroundColor Gray
    Write-Host ''

    $confirm = Show-Menu -MenuItems @('Yes, reset session', 'Cancel')
    if ($confirm -ne 'Yes, reset session') { return }

    foreach ($step in $script:Steps) { $step.Status = 'not-run' }
    $script:Session = Initialize-Session
    if (Test-Path $SessionFile) { Remove-Item $SessionFile -Force }

    Write-Host ''
    Write-Host '  Session reset. All steps marked as not-run.' -ForegroundColor Green
    Start-Sleep -Seconds 1
}

# ─────────────────────────────────────────────────────────────────────────────
# MENU CONSTRUCTION
# ─────────────────────────────────────────────────────────────────────────────

function Get-MenuItems {
    $items = [System.Collections.ArrayList]::new()

    # Data Collection — no leading separator; it's the first visible group
    foreach ($s in ($script:Steps | Where-Object { $_.Phase -eq 'DataCollection' })) {
        $null = $items.Add($s)
    }

    # Configuration Checks
    $null = $items.Add((Get-MenuSeparator))
    foreach ($s in ($script:Steps | Where-Object { $_.Phase -eq 'ConfigurationChecks' })) {
        $null = $items.Add($s)
    }

    # Configuration Changes
    $null = $items.Add((Get-MenuSeparator))
    foreach ($s in ($script:Steps | Where-Object { $_.Phase -eq 'ConfigurationChanges' })) {
        $null = $items.Add($s)
    }

    # Autopilot Readiness
    $null = $items.Add((Get-MenuSeparator))
    foreach ($s in ($script:Steps | Where-Object { $_.Phase -eq 'AutopilotReadiness' })) {
        $null = $items.Add($s)
    }

    # Workflow actions
    $null = $items.Add((Get-MenuSeparator))
    foreach ($w in $script:WorkflowItems) {
        $null = $items.Add($w)
    }

    return $items.ToArray()
}

# Menu item formatter — returns a string for PSMenu to display
$script:Formatter = {
    param($item)

    if ($null -eq $item) { return '' }

    # Defensive: only format our expected step/workflow objects
    if (-not ($item -is [PSCustomObject])) { return '' }
    if (-not ($item.PSObject.Properties.Name -contains 'IsWorkflow')) { return '' }

    if ($item.IsWorkflow) {
        return ("Action  {0}" -f $item.DisplayName)
    }

    $badge = switch ($item.Status) {
        'DONE'  { '[DONE]' }
        'FAIL'  { '[FAIL]' }
        'SKIP'  { '[SKIP]' }
        default { '[    ]' }
    }
    $idx = $item.Index.ToString().PadLeft(2, '0')
    return ("{0}  Step {1}  {2}" -f $badge, $idx, $item.DisplayName)
}

# ─────────────────────────────────────────────────────────────────────────────
# MAIN LOOP
# ─────────────────────────────────────────────────────────────────────────────

$script:Session = Import-Session

# ─────────────────────────────────────────────────────────────────────────────
# NON-INTERACTIVE MODE — emit session JSON to stdout and exit
# ─────────────────────────────────────────────────────────────────────────────
if ($NonInteractive) {
    $result = [PSCustomObject]@{
        Timestamp    = (Get-Date -Format 'o')
        ScriptName   = $ScriptName
        ComputerName = $script:ComputerName
        SerialNumber = $script:SerialNumber
        CurrentUser  = $script:CurrentUser
        SessionFile  = $SessionFile
        SessionExists = (Test-Path $SessionFile)
        Steps        = $script:Steps | Select-Object Index, Phase, DisplayName, Status, ScriptPath
        Summary      = [PSCustomObject]@{
            Total   = $script:Steps.Count
            Done    = ($script:Steps | Where-Object { $_.Status -eq 'DONE' }).Count
            Failed  = ($script:Steps | Where-Object { $_.Status -eq 'FAIL' }).Count
            Skipped = ($script:Steps | Where-Object { $_.Status -eq 'SKIP' }).Count
            NotRun  = ($script:Steps | Where-Object { $_.Status -eq 'not-run' }).Count
        }
    }
    $result | ConvertTo-Json -Depth 5
    exit 0
}

Start-Sleep -Milliseconds 800   # let any resume message stay visible briefly

try {
    $running = $true
    while ($running) {
        Clear-Host
        Show-Header

        $menuItems = Get-MenuItems
        $selected  = Show-Menu -MenuItems $menuItems -MenuItemFormatter $script:Formatter

        # Escape / closed menu
        if ($null -eq $selected) { $running = $false; continue }

        # Skip separators or unexpected types
        if (-not ($selected -is [PSCustomObject])) { continue }
        if (-not ($selected.PSObject.Properties.Name -contains 'IsWorkflow')) { continue }

        if ($selected.IsWorkflow) {
            switch ($selected.Action) {
                'RunAll'  { Invoke-RunAll }
                'Summary' { Show-SessionSummary }
                'Export'  { Export-SessionReport }
                'Reset'   { Invoke-ResetSession }
                'Exit'    { $running = $false }
            }
        }
        else {
            Invoke-Step -Step $selected
        }
    }
}
catch {
    Write-ErrorLog "Unhandled exception in main loop: $_"
    Write-Host "  FATAL: Unexpected error — check $ErrorLog" -ForegroundColor Red
    exit 1
}

Write-Host ''
Write-Host '  Goodbye! Pre-Wipe session ended.' -ForegroundColor Cyan
Write-Host ''
