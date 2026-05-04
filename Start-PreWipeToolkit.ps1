<#
.SYNOPSIS
    Interactive orchestrator for the Pre-Wipe Toolkit.

.DESCRIPTION
    Retro-styled dashboard TUI that guides a tech through all 29 pre-wipe
    preparation steps across four categories: Scan/Check/Backup, Configure,
    Install & Update, and Autopilot.

    Features:
    - Custom ANSI dashboard with rainbow gradient banner (no external modules)
    - Arrow-key menu navigation with scrolling and status badges
    - Split-pane layout: step list (left) + session status / last result (right)
    - Session state persistence to C:\PreWipeOutput\session.json
    - Resume on reopen if session.json exists
    - Per-step status tracking (DONE / FAIL / SKIP / not-run)
    - Run All, Export, and Reset workflow actions

.PARAMETER NonInteractive
    Suppresses all interactive prompts and menu display. Emits current session
    state as a JSON object to stdout, then exits with code 0.

.NOTES
    Requirements  : Windows PowerShell 5.1+ or PowerShell 7+, Administrator privileges
    Output dir    : C:\PreWipeOutput\
    Log dir       : C:\PreWipeOutput\Logs\
    Does NOT modify any script in .\Scripts\ — calls them by path only.
    Source repos used: (none — orchestrator only; delegates to phase scripts)

.EXAMPLE
    .\Start-PreWipeToolkit.ps1

    Launches the interactive Pre-Wipe Toolkit dashboard.

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
# CUSTOM TUI: ANSI HELPERS & FLAME ENGINE
# ─────────────────────────────────────────────────────────────────────────────
$esc = [char]27
$script:AnsiRegex = [regex]("$([regex]::Escape($esc))\[[0-9;]*m")

# Returns visible character count (strips ANSI escape sequences)
function Get-VisibleLength { param([string]$T); return ($script:AnsiRegex.Replace($T, '')).Length }

# Pads an ANSI-colored string to a target visible width
function Set-AnsiPad { param([string]$T, [int]$W); return $T + (' ' * [Math]::Max(0, $W - (Get-VisibleLength $T))) }

# Flame gradient: dark red → bright red → orange → golden yellow
function Get-FlameColor {
    param([int]$Index, [int]$Total)
    $pos = if ($Total -le 1) { 0 } else { $Index / ($Total - 1) }
    $h = $pos * 50            # Hue: 0 (red) → 50 (golden yellow)
    $s = 1.0 - ($pos * 0.1)   # Slight desaturation toward yellow
    $v = 0.55 + ($pos * 0.45) # Darker left (embers), brighter right (flame tip)
    $c = $v * $s
    $x = $c * (1 - [Math]::Abs(($h / 60) % 2 - 1))
    $m = $v - $c
    $R = [int](($c + $m) * 255); $G = [int](($x + $m) * 255); $B = [int]($m * 255)
    return "$esc[38;2;$R;$G;$B`m"
}

# Returns the ASCII banner as an array of flame-colored ANSI strings
function Get-BannerLines {
    $art = @(
        "    ___       __             ______         ___        __             _ __     __ "
        "   / _ |_____/ /  ___ ___   /_  __/__      / _ |__ __ / /____  ___   (_) /__  / / "
        "  / __ /___/ _ \ / -_|_-<    / / / _ \    / __ / // // __/ _ \/ _ \ / / / _ \/ /  "
        " /_/ |_\   /_//_/\__/___/   /_/  \___/   /_/ |_\_,_(_)__/\___/ .__//_/_/\___/_/   "
        "                                                            /_/                   "
    )
    $w = $art[0].Length
    $lines = @()
    foreach ($row in $art) {
        $s = ""
        for ($i = 0; $i -lt $row.Length; $i++) {
            $s += "$(Get-FlameColor -Index $i -Total $w)$($row[$i])"
        }
        $lines += "$s$esc[0m"
    }
    return $lines
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
# PHASE LABELS (friendly display names for menu categories)
# ─────────────────────────────────────────────────────────────────────────────
$script:PhaseLabels = [ordered]@{
    'ScanCheckBackup' = 'Scan, Check & Backup'
    'Configure'       = 'Configure'
    'InstallUpdate'   = 'Install & Update'
    'Autopilot'       = 'Autopilot'
}

function Get-PhaseLabel([string]$Phase) {
    if ($script:PhaseLabels.Contains($Phase)) { return $script:PhaseLabels[$Phase] }
    return $Phase
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP DEFINITIONS  (29 steps — ordered by impact level)
# ScriptPath is relative to $PSScriptRoot
# ─────────────────────────────────────────────────────────────────────────────
$script:Steps = @(
    # ── Scan, Check & Backup (low impact — read-only or backup only) ───────
    [PSCustomObject]@{
        Index       = 1
        Phase       = 'ScanCheckBackup'
        DisplayName = 'Scan for Unbacked Data & Non-Std Apps'
        ScriptPath  = 'Scripts\DataCollection\Find-UnbackedData.ps1'
        Status      = 'not-run'
        IsWorkflow  = $false
    }
    [PSCustomObject]@{
        Index       = 2
        Phase       = 'ScanCheckBackup'
        DisplayName = 'Check Downloads Folder Sizes'
        ScriptPath  = 'Scripts\DataCollection\Get-DownloadsSize.ps1'
        Status      = 'not-run'
        IsWorkflow  = $false
    }
    [PSCustomObject]@{
        Index       = 3
        Phase       = 'ScanCheckBackup'
        DisplayName = 'Get Drive Mappings'
        ScriptPath  = 'Scripts\DataCollection\Get-DriveMappings.ps1'
        Status      = 'not-run'
        IsWorkflow  = $false
    }
    [PSCustomObject]@{
        Index       = 4
        Phase       = 'ScanCheckBackup'
        DisplayName = 'List Physical Printers'
        ScriptPath  = 'Scripts\DataCollection\Get-Printers.ps1'
        Status      = 'not-run'
        IsWorkflow  = $false
    }
    [PSCustomObject]@{
        Index       = 5
        Phase       = 'ScanCheckBackup'
        DisplayName = 'Get Windows Product Key'
        ScriptPath  = 'Scripts\DataCollection\Get-WindowsProductKey.ps1'
        Status      = 'not-run'
        IsWorkflow  = $false
    }
    [PSCustomObject]@{
        Index       = 6
        Phase       = 'ScanCheckBackup'
        DisplayName = 'Get Installed Applications'
        ScriptPath  = 'Scripts\DataCollection\Get-InstalledApplications.ps1'
        Status      = 'not-run'
        IsWorkflow  = $false
    }
    [PSCustomObject]@{
        Index       = 7
        Phase       = 'ScanCheckBackup'
        DisplayName = 'Get Device Health Report'
        ScriptPath  = 'Scripts\DataCollection\Get-DeviceHealth.ps1'
        Status      = 'not-run'
        IsWorkflow  = $false
    }
    [PSCustomObject]@{
        Index       = 8
        Phase       = 'ScanCheckBackup'
        DisplayName = 'Test OneDrive KFM Status'
        ScriptPath  = 'Scripts\ConfigurationChecks\Test-OneDriveKFM.ps1'
        Status      = 'not-run'
        IsWorkflow  = $false
    }
    [PSCustomObject]@{
        Index       = 9
        Phase       = 'ScanCheckBackup'
        DisplayName = 'Test OneDrive Sync Status'
        ScriptPath  = 'Scripts\ConfigurationChecks\Test-OneDriveSyncStatus.ps1'
        Status      = 'not-run'
        IsWorkflow  = $false
    }
    [PSCustomObject]@{
        Index       = 10
        Phase       = 'ScanCheckBackup'
        DisplayName = 'Get Storage Controller Mode'
        ScriptPath  = 'Scripts\ConfigurationChecks\Get-StorageMode.ps1'
        Status      = 'not-run'
        IsWorkflow  = $false
    }
    [PSCustomObject]@{
        Index       = 11
        Phase       = 'ScanCheckBackup'
        DisplayName = 'Test BIOS Version (Dell)'
        ScriptPath  = 'Scripts\ConfigurationChecks\Test-BiosVersion.ps1'
        Status      = 'not-run'
        IsWorkflow  = $false
    }
    [PSCustomObject]@{
        Index       = 12
        Phase       = 'ScanCheckBackup'
        DisplayName = 'Test Driver Status (Dell DCU)'
        ScriptPath  = 'Scripts\ConfigurationChecks\Test-DriverStatus.ps1'
        Status      = 'not-run'
        IsWorkflow  = $false
    }
    [PSCustomObject]@{
        Index       = 13
        Phase       = 'ScanCheckBackup'
        DisplayName = 'Test Wake-on-LAN Settings'
        ScriptPath  = 'Scripts\ConfigurationChecks\Test-WakeOnLan.ps1'
        Status      = 'not-run'
        IsWorkflow  = $false
    }
    [PSCustomObject]@{
        Index       = 14
        Phase       = 'ScanCheckBackup'
        DisplayName = 'Test Windows Recovery (WinRE)'
        ScriptPath  = 'Scripts\ConfigurationChecks\Test-WinRE.ps1'
        Status      = 'not-run'
        IsWorkflow  = $false
    }
    [PSCustomObject]@{
        Index       = 15
        Phase       = 'ScanCheckBackup'
        DisplayName = 'Backup Browser Bookmarks'
        ScriptPath  = 'Scripts\ConfigurationChanges\Backup-BrowserBookmarks.ps1'
        Status      = 'not-run'
        IsWorkflow  = $false
    }
    [PSCustomObject]@{
        Index       = 16
        Phase       = 'ScanCheckBackup'
        DisplayName = 'Backup Desktop Background'
        ScriptPath  = 'Scripts\ConfigurationChanges\Backup-DesktopBackground.ps1'
        Status      = 'not-run'
        IsWorkflow  = $false
    }
    [PSCustomObject]@{
        Index       = 17
        Phase       = 'ScanCheckBackup'
        DisplayName = 'Backup Outlook Signatures'
        ScriptPath  = 'Scripts\ConfigurationChanges\Backup-OutlookSignatures.ps1'
        Status      = 'not-run'
        IsWorkflow  = $false
    }
    [PSCustomObject]@{
        Index       = 18
        Phase       = 'ScanCheckBackup'
        DisplayName = 'Backup Taskbar Layout'
        ScriptPath  = 'Scripts\ConfigurationChanges\Backup-TaskbarLayout.ps1'
        Status      = 'not-run'
        IsWorkflow  = $false
    }
    [PSCustomObject]@{
        Index       = 19
        Phase       = 'ScanCheckBackup'
        DisplayName = 'Backup Wi-Fi Profiles'
        ScriptPath  = 'Scripts\ConfigurationChanges\Backup-WiFiProfiles.ps1'
        Status      = 'not-run'
        IsWorkflow  = $false
    }

    # ── Configure (changes settings) ──────────────────────────────────────
    [PSCustomObject]@{
        Index       = 20
        Phase       = 'Configure'
        DisplayName = 'Escrow BitLocker Key to Entra ID'
        ScriptPath  = 'Scripts\ConfigurationChanges\Test-BitLockerEscrow.ps1'
        Status      = 'not-run'
        IsWorkflow  = $false
    }
    [PSCustomObject]@{
        Index       = 21
        Phase       = 'Configure'
        DisplayName = 'Set Wake-on-LAN (BIOS + NIC + Windows)'
        ScriptPath  = 'Scripts\ConfigurationChanges\Set-WakeOnLan.ps1'
        Status      = 'not-run'
        IsWorkflow  = $false
    }

    # ── Install & Update ──────────────────────────────────────────────────
    [PSCustomObject]@{
        Index       = 22
        Phase       = 'InstallUpdate'
        DisplayName = 'Install Dell Command Tools (DCU + DCC)'
        ScriptPath  = 'Scripts\ConfigurationChanges\Install-DellCommandTools.ps1'
        Status      = 'not-run'
        IsWorkflow  = $false
    }
    [PSCustomObject]@{
        Index       = 23
        Phase       = 'InstallUpdate'
        DisplayName = 'Update Drivers (Dell DCU)'
        ScriptPath  = 'Scripts\ConfigurationChanges\Update-Drivers.ps1'
        Status      = 'not-run'
        IsWorkflow  = $false
    }
    [PSCustomObject]@{
        Index       = 24
        Phase       = 'InstallUpdate'
        DisplayName = 'Update BIOS (Dell DCU — may reboot)'
        ScriptPath  = 'Scripts\ConfigurationChanges\Update-Bios.ps1'
        Status      = 'not-run'
        IsWorkflow  = $false
    }

    # ── Autopilot ─────────────────────────────────────────────────────────
    [PSCustomObject]@{
        Index       = 25
        Phase       = 'Autopilot'
        DisplayName = 'Test Autopilot Profile'
        ScriptPath  = 'Scripts\AutopilotReadiness\Test-AutopilotProfile.ps1'
        Status      = 'not-run'
        IsWorkflow  = $false
    }
    [PSCustomObject]@{
        Index       = 26
        Phase       = 'Autopilot'
        DisplayName = 'Test Autopilot Readiness'
        ScriptPath  = 'Scripts\AutopilotReadiness\Test-AutopilotReadiness.ps1'
        Status      = 'not-run'
        IsWorkflow  = $false
    }
    [PSCustomObject]@{
        Index       = 27
        Phase       = 'Autopilot'
        DisplayName = 'Get Autopilot Assignment (Graph API)'
        ScriptPath  = 'Scripts\AutopilotReadiness\Get-AutopilotAssignment.ps1'
        Status      = 'not-run'
        IsWorkflow  = $false
    }
    [PSCustomObject]@{
        Index       = 28
        Phase       = 'Autopilot'
        DisplayName = 'Register Device with Autopilot'
        ScriptPath  = 'Scripts\AutopilotReadiness\Register-AutopilotDevice.ps1'
        Status      = 'not-run'
        IsWorkflow  = $false
    }
    [PSCustomObject]@{
        Index       = 29
        Phase       = 'Autopilot'
        DisplayName = 'Pre-Wipe Summary'
        ScriptPath  = 'Scripts\AutopilotReadiness\Get-PreWipeSummary.ps1'
        Status      = 'not-run'
        IsWorkflow  = $false
    }
)

# Workflow items — appear at the bottom of the menu, no status badge
$script:WorkflowItems = @(
    [PSCustomObject]@{ Index = 0; DisplayName = 'Run All (Sequential)';  Action = 'RunAll';   IsWorkflow = $true }
    [PSCustomObject]@{ Index = 0; DisplayName = 'View Session Summary';  Action = 'Summary';  IsWorkflow = $true }
    [PSCustomObject]@{ Index = 0; DisplayName = 'Export Session Report (TXT/JSON/HTML)'; Action = 'Export';   IsWorkflow = $true }
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
# CUSTOM DASHBOARD ENGINE
# ─────────────────────────────────────────────────────────────────────────────

$script:LastActionResult = 'Welcome to the Pre-Wipe Toolkit. Select an action to begin.'
$script:MenuItems = @()

function Build-MenuItems {
    $items = @()
    $items += [PSCustomObject]@{ IsHeader=$true; DisplayName=" SCAN, CHECK & BACKUP" }
    foreach ($s in ($script:Steps | Where-Object Phase -eq 'ScanCheckBackup')) { $items += $s }
    
    $items += [PSCustomObject]@{ IsHeader=$true; DisplayName=" CONFIGURE" }
    foreach ($s in ($script:Steps | Where-Object Phase -eq 'Configure')) { $items += $s }
    
    $items += [PSCustomObject]@{ IsHeader=$true; DisplayName=" INSTALL & UPDATE" }
    foreach ($s in ($script:Steps | Where-Object Phase -eq 'InstallUpdate')) { $items += $s }
    
    $items += [PSCustomObject]@{ IsHeader=$true; DisplayName=" AUTOPILOT" }
    foreach ($s in ($script:Steps | Where-Object Phase -eq 'Autopilot')) { $items += $s }
    
    $items += [PSCustomObject]@{ IsHeader=$true; DisplayName=" WORKFLOW ACTIONS" }
    foreach ($w in $script:WorkflowItems) { $items += $w }
    
    return $items
}

function Draw-Dashboard {
    param([int]$SelectedIndex, [int]$ScrollTop)
    
    # Hide cursor and move home (NO screen clear here to prevent flicker)
    Write-Host -NoNewline "$esc[?25l$esc[H"
    
    $width = $Host.UI.RawUI.WindowSize.Width
    if ($width -lt 90) { $width = 90 }
    
    # Dynamic sizing based on terminal window
    $leftInnerWidth = [Math]::Floor(($width - 3) * 0.55)
    $rightInnerWidth = $width - 3 - $leftInnerWidth
    $viewHeight = [Math]::Max(10, $Host.UI.RawUI.WindowSize.Height - 12)
    
    $bannerLines = Get-BannerLines
    foreach ($line in $bannerLines) {
        Write-Host $line
    }
    
    $totalSteps = $script:Steps.Count
    $done  = @($script:Steps | Where-Object { $_.Status -eq 'DONE' }).Count
    $fail  = @($script:Steps | Where-Object { $_.Status -eq 'FAIL' }).Count
    $skip  = @($script:Steps | Where-Object { $_.Status -eq 'SKIP' }).Count
    $norun = @($script:Steps | Where-Object { $_.Status -eq 'not-run' }).Count

    # Build menu lines
    $menuLines = @()
    for ($i = $ScrollTop; $i -lt [Math]::Min($script:MenuItems.Count, $ScrollTop + $viewHeight); $i++) {
        $item = $script:MenuItems[$i]
        $prefix = if ($i -eq $SelectedIndex) { " $esc[32m>>$esc[0m " } else { "    " }
        
        if ($item.IsHeader) {
            $menuLines += Set-AnsiPad "$prefix$esc[36m$($item.DisplayName)$esc[0m" $leftInnerWidth
        }
        elseif ($item.IsWorkflow) {
            $menuLines += Set-AnsiPad "$prefix$esc[37m$($item.DisplayName)$esc[0m" $leftInnerWidth
        }
        else {
            $badgeColor = switch ($item.Status) {
                'DONE' { "$esc[32m[DONE]$esc[0m" }
                'FAIL' { "$esc[31m[FAIL]$esc[0m" }
                'SKIP' { "$esc[33m[SKIP]$esc[0m" }
                default { "$esc[90m[    ]$esc[0m" }
            }
            $menuLines += Set-AnsiPad "$prefix$badgeColor $($item.DisplayName)" $leftInnerWidth
        }
    }
    while ($menuLines.Count -lt $viewHeight) { $menuLines += (" " * $leftInnerWidth) }

    # Build right pane lines
    $rightLines = @()
    $rightLines += Set-AnsiPad " $esc[36m=== SESSION STATUS ===$esc[0m" $rightInnerWidth
    $rightLines += Set-AnsiPad " Computer : $($script:ComputerName)" $rightInnerWidth
    $rightLines += Set-AnsiPad " User     : $($script:CurrentUser)" $rightInnerWidth
    $rightLines += (" " * $rightInnerWidth)
    
    $barLen = [Math]::Min(24, $rightInnerWidth - 14)
    $filled = if ($totalSteps -gt 0) { [Math]::Floor(($done / $totalSteps) * $barLen) } else { 0 }
    $empty  = $barLen - $filled
    $barStr = "$esc[32m$([string]::new([char]0x2588, $filled))$esc[90m$([string]::new([char]0x2591, $empty))$esc[0m"
    $rightLines += Set-AnsiPad " Progress : $barStr" $rightInnerWidth
    $rightLines += Set-AnsiPad " Passed   : $esc[32m$done$esc[0m  Failed : $esc[31m$fail$esc[0m" $rightInnerWidth
    $rightLines += Set-AnsiPad " Skipped  : $esc[33m$skip$esc[0m  Not Run: $norun" $rightInnerWidth
    $rightLines += (" " * $rightInnerWidth)
    
    $rightLines += Set-AnsiPad " $esc[36m=== SELECTION ===$esc[0m" $rightInnerWidth
    $selItem = $script:MenuItems[$SelectedIndex]
    if ($selItem.IsHeader) {
        $rightLines += Set-AnsiPad " Category header." $rightInnerWidth
    } elseif ($selItem.IsWorkflow) {
        $rightLines += Set-AnsiPad " Action: $($selItem.DisplayName)" $rightInnerWidth
    } else {
        $rightLines += Set-AnsiPad " Step   : $($selItem.Index)" $rightInnerWidth
        $rightLines += Set-AnsiPad " Name   : $($selItem.DisplayName)" $rightInnerWidth
        $rightLines += Set-AnsiPad " Status : $($selItem.Status)" $rightInnerWidth
        $rightLines += Set-AnsiPad " Script : $(Split-Path $selItem.ScriptPath -Leaf)" $rightInnerWidth
    }
    
    $rightLines += (" " * $rightInnerWidth)
    $rightLines += Set-AnsiPad " $esc[36m=== LAST RESULT ===$esc[0m" $rightInnerWidth
    
    $words = $script:LastActionResult -split ' '
    $curLine = " "
    foreach ($w in $words) {
        if (($curLine.Length + $w.Length) -gt ($rightInnerWidth - 2)) {
            $rightLines += Set-AnsiPad $curLine $rightInnerWidth
            $curLine = "  $w "
        } else {
            $curLine += "$w "
        }
    }
    if ($curLine.Trim() -ne "") { $rightLines += Set-AnsiPad $curLine $rightInnerWidth }

    while ($rightLines.Count -lt $viewHeight) { $rightLines += (" " * $rightInnerWidth) }

    # Draw framed box with flame border colors (deep red)
    Write-Host "$esc[38;2;180;30;20m╔$([string]::new('═', $leftInnerWidth))╦$([string]::new('═', $rightInnerWidth))╗$esc[0m"
    for ($i = 0; $i -lt $viewHeight; $i++) {
        Write-Host "$esc[38;2;180;30;20m║$esc[0m$($menuLines[$i])$esc[38;2;180;30;20m║$esc[0m$($rightLines[$i])$esc[38;2;180;30;20m║$esc[0m"
    }
    Write-Host "$esc[38;2;180;30;20m╚$([string]::new('═', $leftInnerWidth))╩$([string]::new('═', $rightInnerWidth))╝$esc[0m"
    Write-Host "  [↑/↓] Navigate    [ENTER] Execute    [ESC] Exit" -ForegroundColor DarkGray
    Write-Host "$esc[K" # Clear remainder of line to prevent artifacting
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP EXECUTION
# ─────────────────────────────────────────────────────────────────────────────

function Invoke-Step {
    param(
        [PSCustomObject]$Step,
        [switch]$InRunAll
    )

    # Move cursor down to not overwrite the banner completely, but show we are running
    Write-Host -NoNewline "$esc[?25h$esc[2J$esc[H"
    Write-RainbowBanner
    Write-Host "  >>> Running: $($Step.DisplayName) <<<" -ForegroundColor Cyan
    Write-Host ""

    $fullPath = Join-Path $PSScriptRoot $Step.ScriptPath

    if (-not (Test-Path $fullPath)) {
        $Step.Status = 'SKIP'
        Update-SessionStep -Index $Step.Index -Status 'SKIP' -ExitCode $null
        Save-Session
        $script:LastActionResult = "[SKIP] Script not found: $($Step.ScriptPath)"
        return
    }

    $LASTEXITCODE = 0
    $exitCode = 0

    try {
        & $fullPath
        $exitCode = if ($null -ne $LASTEXITCODE) { $LASTEXITCODE } else { 0 }
    }
    catch {
        Write-ErrorLog "Step $($Step.Index) ($($Step.DisplayName)) threw: $_"
        $exitCode = -1
    }

    if ($exitCode -eq 0) {
        $Step.Status = 'DONE'
        $script:LastActionResult = "[PASS] $($Step.DisplayName) completed successfully."
    }
    else {
        $Step.Status = 'FAIL'
        $script:LastActionResult = "[FAIL] $($Step.DisplayName) exited with code: $exitCode"
    }

    Update-SessionStep -Index $Step.Index -Status $Step.Status -ExitCode $exitCode
    Save-Session

    if (-not $InRunAll) {
        Write-Host ""
        Write-Host "  Finished. Returning to dashboard in 2 seconds..." -ForegroundColor DarkGray
        Start-Sleep -Seconds 2
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# WORKFLOW: RUN ALL
# ─────────────────────────────────────────────────────────────────────────────

function Invoke-RunAll {
    Write-Host -NoNewline "$esc[?25h$esc[2J$esc[H"
    Write-Host "  Run All Steps" -ForegroundColor Cyan
    Write-Host "  Runs all 29 steps in order. Respond to prompts as scripts run." -ForegroundColor Gray
    Write-Host ""
    
    $confirm = Read-Host "  Type 'Y' to run all steps, or press Enter to cancel"
    if ($confirm -notmatch '^[Yy]') { return }

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

    $script:LastActionResult = "Run All Complete. Passed: $($counts.DONE), Failed: $($counts.FAIL), Skipped: $($counts.SKIP)."
    Write-Host "  Run All Complete! Returning to dashboard..." -ForegroundColor Green
    Start-Sleep -Seconds 2
}

# ─────────────────────────────────────────────────────────────────────────────
# WORKFLOW: SESSION SUMMARY
# ─────────────────────────────────────────────────────────────────────────────

function Show-SessionSummary {
    # Dashboard displays this natively now, but we'll leave a status update
    $script:LastActionResult = 'Session summary is displayed on the dashboard. Review the STATUS and Progress panes.'
}

# ─────────────────────────────────────────────────────────────────────────────
# WORKFLOW: EXPORT REPORT
# ─────────────────────────────────────────────────────────────────────────────

function Export-SessionReport {
    Write-Host -NoNewline "$esc[?25h$esc[2J$esc[H"
    Write-Host '  Exporting Session Report...' -ForegroundColor Cyan
    
    $stamp    = Get-Date -Format 'yyyyMMdd-HHmmss'
    $baseName = "PreWipeReport_$($script:ComputerName)_$stamp"
    $jsonPath = Join-Path $OutputRoot "$baseName.json"
    $txtPath  = Join-Path $OutputRoot "$baseName.txt"
    $htmlPath = Join-Path $OutputRoot "$baseName.html"

    # JSON export
    try {
        $script:Session | ConvertTo-Json -Depth 5 | Set-Content $jsonPath -Encoding UTF8 -Force
    } catch { Write-ErrorLog "JSON export failed: $_" }

    $done  = ($script:Steps | Where-Object { $_.Status -eq 'DONE' }).Count
    $fail  = ($script:Steps | Where-Object { $_.Status -eq 'FAIL' }).Count
    $skip  = ($script:Steps | Where-Object { $_.Status -eq 'SKIP' }).Count
    $norun = ($script:Steps | Where-Object { $_.Status -eq 'not-run' }).Count

    # Readable TXT export with full step detail
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
            $lines.Add("--- $(Get-PhaseLabel $group.Name) ---")
            foreach ($step in $group.Group) {
                $stepData = $script:Session.Steps["$($step.Index)"]
                $ts = if ($stepData -and $stepData.Timestamp) { "  ($($stepData.Timestamp))" } else { '' }
                $lines.Add("  [$($step.Status.PadRight(7))] $($step.DisplayName)$ts")
            }
            $lines.Add('')
        }

        $lines.Add('--- Summary ---')
        $lines.Add("  Passed  : $done")
        $lines.Add("  Failed  : $fail")
        $lines.Add("  Skipped : $skip")
        $lines.Add("  Not Run : $norun")

        $lines | Set-Content $txtPath -Encoding UTF8 -Force
    } catch { Write-ErrorLog "TXT export failed: $_" }

    # HTML export
    try {
        $html = @"
<!DOCTYPE html>
<html>
<head>
    <title>Pre-Wipe Report - $($script:ComputerName)</title>
    <style>
        body { font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; margin: 40px; background-color: #1e1e1e; color: #d4d4d4; }
        h1 { color: #ff6b35; border-bottom: 2px solid #333; padding-bottom: 10px; }
        h2 { color: #569cd6; margin-top: 30px; }
        .status-DONE { color: #4CAF50; font-weight: bold; }
        .status-FAIL { color: #F44336; font-weight: bold; }
        .status-SKIP { color: #FF9800; font-weight: bold; }
        .status-not-run { color: #9E9E9E; }
        table { border-collapse: collapse; width: 100%; margin-bottom: 20px; box-shadow: 0 4px 6px rgba(0,0,0,0.3); }
        th, td { text-align: left; padding: 12px 15px; border-bottom: 1px solid #333; }
        th { background-color: #2d2d2d; color: #4FC1FF; text-transform: uppercase; font-size: 0.9em; }
        tr:nth-child(even) { background-color: #252526; }
        tr:hover { background-color: #333; }
        .summary-box { background: #252526; padding: 20px; border-radius: 8px; border-left: 4px solid #ff6b35; margin-bottom: 30px; }
    </style>
</head>
<body>
    <h1>Pre-Wipe Session Report</h1>
    <div class="summary-box">
        <p><strong>Computer:</strong> $($script:ComputerName) &nbsp;|&nbsp;
        <strong>User:</strong> $($script:CurrentUser) &nbsp;|&nbsp;
        <strong>Serial:</strong> $($script:SerialNumber)<br>
        <strong>Generated:</strong> $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')</p>
        <p style="font-size: 1.1em;">Passed: <span class="status-DONE">$done</span> &nbsp;|&nbsp; 
           Failed: <span class="status-FAIL">$fail</span> &nbsp;|&nbsp; 
           Skipped: <span class="status-SKIP">$skip</span> &nbsp;|&nbsp; 
           Not Run: <span class="status-not-run">$norun</span></p>
    </div>
"@
        foreach ($group in ($script:Steps | Group-Object Phase)) {
            $html += "<h2>$(Get-PhaseLabel $group.Name)</h2><table><tr><th>Status</th><th>Step</th><th>Timestamp</th></tr>"
            foreach ($step in $group.Group) {
                $stepData = $script:Session.Steps["$($step.Index)"]
                $ts = if ($stepData -and $stepData.Timestamp) { $stepData.Timestamp } else { '-' }
                $html += "<tr><td class='status-$($step.Status)'>$($step.Status)</td><td>$($step.DisplayName)</td><td>$ts</td></tr>"
            }
            $html += "</table>"
        }
        $html += "</body></html>"
        $html | Set-Content $htmlPath -Encoding UTF8 -Force
    } catch { Write-ErrorLog "HTML export failed: $_" }

    $script:LastActionResult = "Session exported to JSON, TXT, and HTML in $OutputRoot."
    Write-Host "  Finished. Returning to dashboard in 2 seconds..." -ForegroundColor DarkGray
    Start-Sleep -Seconds 2
}

# ─────────────────────────────────────────────────────────────────────────────
# WORKFLOW: RESET SESSION
# ─────────────────────────────────────────────────────────────────────────────

function Invoke-ResetSession {
    Write-Host -NoNewline "$esc[?25h$esc[2J$esc[H"
    Write-Host '  Reset Session' -ForegroundColor White
    Write-Host '  This clears all step statuses and deletes session.json.' -ForegroundColor Gray
    
    $confirm = Read-Host "  Type 'Y' to reset session, or press Enter to cancel"
    if ($confirm -notmatch '^[Yy]') { return }

    foreach ($step in $script:Steps) { $step.Status = 'not-run' }
    $script:Session = Initialize-Session
    if (Test-Path $SessionFile) { Remove-Item $SessionFile -Force }

    $script:LastActionResult = 'Session reset successfully. All steps marked as not-run.'
}

# ─────────────────────────────────────────────────────────────────────────────
# MAIN LOOP
# ─────────────────────────────────────────────────────────────────────────────

$script:Session = Import-Session

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

Start-Sleep -Milliseconds 800

try {
    $running = $true
    $script:MenuItems = Build-MenuItems

    # Start selection on first selectable item (skip header at index 0)
    $selectedIndex = 1
    $scrollTop = 0

    while ($running) {
        Draw-Dashboard -SelectedIndex $selectedIndex -ScrollTop $scrollTop

        $key = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        if ($key.KeyDown) {
            switch ($key.VirtualKeyCode) {
                38 { # Up Arrow
                    $prev = $selectedIndex
                    $selectedIndex--
                    if ($selectedIndex -lt 0) { $selectedIndex = 0 }
                    # Skip headers; if stuck on one at top, revert
                    while ($script:MenuItems[$selectedIndex].IsHeader -and $selectedIndex -gt 0) {
                        $selectedIndex--
                    }
                    if ($script:MenuItems[$selectedIndex].IsHeader) { $selectedIndex = $prev }
                    if ($selectedIndex -lt $scrollTop) { $scrollTop = $selectedIndex }
                }
                40 { # Down Arrow
                    $prev = $selectedIndex
                    $selectedIndex++
                    if ($selectedIndex -ge $script:MenuItems.Count) { $selectedIndex = $script:MenuItems.Count - 1 }
                    # Skip headers; if stuck on one at bottom, revert
                    while ($script:MenuItems[$selectedIndex].IsHeader -and $selectedIndex -lt ($script:MenuItems.Count - 1)) {
                        $selectedIndex++
                    }
                    if ($script:MenuItems[$selectedIndex].IsHeader) { $selectedIndex = $prev }
                    if ($selectedIndex -ge ($scrollTop + 18)) { $scrollTop = $selectedIndex - 17 }
                }
                13 { # Enter
                    $sel = $script:MenuItems[$selectedIndex]
                    if ($sel.IsWorkflow) {
                        switch ($sel.Action) {
                            'RunAll'  { Invoke-RunAll }
                            'Summary' { Show-SessionSummary }
                            'Export'  { Export-SessionReport }
                            'Reset'   { Invoke-ResetSession }
                            'Exit'    { $running = $false }
                        }
                    } else {
                        Invoke-Step -Step $sel
                    }
                    # Clear screen fully after an action returns so the dashboard repaints clean
                    if ($running) { Write-Host -NoNewline "$esc[2J$esc[H" }
                }
                27 { # Escape
                    $running = $false
                }
            }
        }
    }
    # Restore cursor on exit
    Write-Host -NoNewline "$esc[?25h"
    Clear-Host
}
catch {
    Write-Host -NoNewline "$esc[?25h"
    Write-ErrorLog "Unhandled exception in main loop: $_"
    Write-Host "  FATAL: Unexpected error — check $ErrorLog" -ForegroundColor Red
    exit 1
}

Write-Host ''
Write-Host '  Goodbye! Pre-Wipe session ended.' -ForegroundColor Cyan
Write-Host ''
