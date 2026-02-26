<#
.SYNOPSIS
    Interactive orchestrator for the Pre-Wipe Toolkit.

.DESCRIPTION
    Menu-driven workflow that guides a tech through all 22 pre-wipe preparation
    steps across four phases: Prerequisites, Data Backup, Hardware, and Autopilot.

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
# STEP DEFINITIONS  (22 steps — ordered by phase)
# ScriptPath is relative to $PSScriptRoot
# ─────────────────────────────────────────────────────────────────────────────
$script:Steps = @(
    # ── Phase 1: Prerequisites ──────────────────────────────────────────────
    [PSCustomObject]@{
        Index      = 1
        Phase      = 'Phase1-Prerequisites'
        DisplayName = 'Install/Update Dell Command Tools'
        ScriptPath  = 'Scripts\Phase1-Prerequisites\Install-DellCommandTools.ps1'
        Status      = 'not-run'
        IsWorkflow  = $false
    }

    # ── Phase 2: Data Validation ─────────────────────────────────────────────
    [PSCustomObject]@{
        Index      = 2
        Phase      = 'Phase2-DataBackup'
        DisplayName = 'Validate OneDrive KFM & Sync'
        ScriptPath  = 'Scripts\Phase2-DataBackup\Test-OneDriveKFM.ps1'
        Status      = 'not-run'
        IsWorkflow  = $false
    }
    [PSCustomObject]@{
        Index      = 3
        Phase      = 'Phase2-DataBackup'
        DisplayName = 'Check Downloads Folder Sizes'
        ScriptPath  = 'Scripts\Phase2-DataBackup\Get-DownloadsSize.ps1'
        Status      = 'not-run'
        IsWorkflow  = $false
    }
    [PSCustomObject]@{
        Index      = 4
        Phase      = 'Phase2-DataBackup'
        DisplayName = 'Backup Browser Bookmarks'
        ScriptPath  = 'Scripts\Phase2-DataBackup\Backup-BrowserBookmarks.ps1'
        Status      = 'not-run'
        IsWorkflow  = $false
    }
    [PSCustomObject]@{
        Index      = 5
        Phase      = 'Phase2-DataBackup'
        DisplayName = 'Scan for Unbacked Data & Non-Std Apps'
        ScriptPath  = 'Scripts\Phase2-DataBackup\Find-UnbackedData.ps1'
        Status      = 'not-run'
        IsWorkflow  = $false
    }
    [PSCustomObject]@{
        Index      = 6
        Phase      = 'Phase2-DataBackup'
        DisplayName = 'Backup Outlook Signatures'
        ScriptPath  = 'Scripts\Phase2-DataBackup\Backup-OutlookSignatures.ps1'
        Status      = 'not-run'
        IsWorkflow  = $false
    }
    [PSCustomObject]@{
        Index      = 7
        Phase      = 'Phase2-DataBackup'
        DisplayName = 'Get Drive Mappings'
        ScriptPath  = 'Scripts\Phase2-DataBackup\Get-DriveMappings.ps1'
        Status      = 'not-run'
        IsWorkflow  = $false
    }
    [PSCustomObject]@{
        Index      = 8
        Phase      = 'Phase2-DataBackup'
        DisplayName = 'Check BitLocker Escrow'
        ScriptPath  = 'Scripts\Phase2-DataBackup\Test-BitLockerEscrow.ps1'
        Status      = 'not-run'
        IsWorkflow  = $false
    }

    # ── Phase 2: Backups ──────────────────────────────────────────────────────
    [PSCustomObject]@{
        Index      = 9
        Phase      = 'Phase2-DataBackup'
        DisplayName = 'Backup Taskbar Layout'
        ScriptPath  = 'Scripts\Phase2-DataBackup\Backup-TaskbarLayout.ps1'
        Status      = 'not-run'
        IsWorkflow  = $false
    }
    [PSCustomObject]@{
        Index      = 10
        Phase      = 'Phase2-DataBackup'
        DisplayName = 'Backup Desktop Background'
        ScriptPath  = 'Scripts\Phase2-DataBackup\Backup-DesktopBackground.ps1'
        Status      = 'not-run'
        IsWorkflow  = $false
    }

    # ── Phase 3: Hardware & Firmware ──────────────────────────────────────────
    [PSCustomObject]@{
        Index      = 11
        Phase      = 'Phase3-Hardware'
        DisplayName = 'Check Storage Mode'
        ScriptPath  = 'Scripts\Phase3-Hardware\Get-StorageMode.ps1'
        Status      = 'not-run'
        IsWorkflow  = $false
    }
    [PSCustomObject]@{
        Index      = 12
        Phase      = 'Phase3-Hardware'
        DisplayName = 'Check BIOS Version'
        ScriptPath  = 'Scripts\Phase3-Hardware\Test-BiosVersion.ps1'
        Status      = 'not-run'
        IsWorkflow  = $false
    }
    [PSCustomObject]@{
        Index      = 13
        Phase      = 'Phase3-Hardware'
        DisplayName = 'Update BIOS'
        ScriptPath  = 'Scripts\Phase3-Hardware\Update-Bios.ps1'
        Status      = 'not-run'
        IsWorkflow  = $false
    }
    [PSCustomObject]@{
        Index      = 14
        Phase      = 'Phase3-Hardware'
        DisplayName = 'Check Wake-on-LAN Settings'
        ScriptPath  = 'Scripts\Phase3-Hardware\Test-WakeOnLan.ps1'
        Status      = 'not-run'
        IsWorkflow  = $false
    }
    [PSCustomObject]@{
        Index      = 15
        Phase      = 'Phase3-Hardware'
        DisplayName = 'Configure Wake-on-LAN'
        ScriptPath  = 'Scripts\Phase3-Hardware\Set-WakeOnLan.ps1'
        Status      = 'not-run'
        IsWorkflow  = $false
    }
    [PSCustomObject]@{
        Index      = 16
        Phase      = 'Phase3-Hardware'
        DisplayName = 'Check WinRE Status'
        ScriptPath  = 'Scripts\Phase3-Hardware\Test-WinRE.ps1'
        Status      = 'not-run'
        IsWorkflow  = $false
    }
    [PSCustomObject]@{
        Index      = 17
        Phase      = 'Phase3-Hardware'
        DisplayName = 'List Printers'
        ScriptPath  = 'Scripts\Phase3-Hardware\Get-Printers.ps1'
        Status      = 'not-run'
        IsWorkflow  = $false
    }
    [PSCustomObject]@{
        Index      = 18
        Phase      = 'Phase3-Hardware'
        DisplayName = 'Check Driver Status'
        ScriptPath  = 'Scripts\Phase3-Hardware\Test-DriverStatus.ps1'
        Status      = 'not-run'
        IsWorkflow  = $false
    }
    [PSCustomObject]@{
        Index      = 19
        Phase      = 'Phase3-Hardware'
        DisplayName = 'Update Drivers'
        ScriptPath  = 'Scripts\Phase3-Hardware\Update-Drivers.ps1'
        Status      = 'not-run'
        IsWorkflow  = $false
    }

    # ── Phase 4: Autopilot & Intune ───────────────────────────────────────────
    [PSCustomObject]@{
        Index      = 20
        Phase      = 'Phase4-Autopilot'
        DisplayName = 'Register Autopilot Device'
        ScriptPath  = 'Scripts\Phase4-Autopilot\Register-AutopilotDevice.ps1'
        Status      = 'not-run'
        IsWorkflow  = $false
    }
    [PSCustomObject]@{
        Index      = 21
        Phase      = 'Phase4-Autopilot'
        DisplayName = 'Check Autopilot Profile'
        ScriptPath  = 'Scripts\Phase4-Autopilot\Test-AutopilotProfile.ps1'
        Status      = 'not-run'
        IsWorkflow  = $false
    }
    [PSCustomObject]@{
        Index      = 22
        Phase      = 'Phase4-Autopilot'
        DisplayName = 'Get Autopilot Assignment'
        ScriptPath  = 'Scripts\Phase4-Autopilot\Get-AutopilotAssignment.ps1'
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

function Show-Header {
    $done  = ($script:Steps | Where-Object { $_.Status -eq 'DONE' }).Count
    $total = $script:Steps.Count
    $start = try { ([datetime]$script:Session.StartTime).ToString('yyyy-MM-dd HH:mm') } catch { 'New session' }

    Write-Host ''
    Write-Host '  ═══════════════════════════════════════════════════════════' -ForegroundColor Cyan
    Write-Host '   Pre-Wipe Toolkit  ·  AshesToAutopilot' -ForegroundColor White
    Write-Host '  ═══════════════════════════════════════════════════════════' -ForegroundColor Cyan
    Write-Host "  Computer  : $($script:ComputerName)   Serial: $($script:SerialNumber)" -ForegroundColor Gray
    Write-Host "  User      : $($script:CurrentUser)   Session: $start" -ForegroundColor Gray
    $progColor = if ($done -eq $total) { 'Green' } else { 'White' }
    Write-Host "  Progress  : $done of $total steps complete" -ForegroundColor $progColor
    Write-Host '  ═══════════════════════════════════════════════════════════' -ForegroundColor Cyan
    Write-Host ''
}

function Show-StepBanner {
    param([PSCustomObject]$Step)
    Write-Host ''
    Write-Host '  ┌──────────────────────────────────────────────────────────' -ForegroundColor Cyan
    Write-Host "  │  Step $($Step.Index): $($Step.DisplayName)" -ForegroundColor White
    Write-Host "  │  Phase : $($Step.Phase)" -ForegroundColor Gray
    Write-Host "  │  Script: $($Step.ScriptPath)" -ForegroundColor Gray
    Write-Host '  └──────────────────────────────────────────────────────────' -ForegroundColor Cyan
    Write-Host ''
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
    Write-Host ''
    Write-Host '  Run All Steps' -ForegroundColor White
    Write-Host '  Runs all 22 steps in order. Scripts run interactively — respond to' -ForegroundColor Gray
    Write-Host '  any prompts as each script runs. Progress is saved after each step.' -ForegroundColor Gray
    Write-Host ''

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
        # Brief pause so the tech sees the result line before next step clears screen
        Start-Sleep -Milliseconds 800
    }

    Write-Host ''
    Write-Host '  ══════════════════════════════════════════' -ForegroundColor Cyan
    Write-Host '  Run All — Complete' -ForegroundColor White
    Write-Host '  ──────────────────────────────────────────' -ForegroundColor DarkGray
    Write-Host "  Passed  : $($counts.DONE)" -ForegroundColor Green
    $failColor = if ($counts.FAIL -gt 0) { 'Red' } else { 'Gray' }
    Write-Host "  Failed  : $($counts.FAIL)" -ForegroundColor $failColor
    Write-Host "  Skipped : $($counts.SKIP)" -ForegroundColor Yellow
    Write-Host '  ══════════════════════════════════════════' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  Press any key to return to menu...' -ForegroundColor DarkGray
    $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
}

# ─────────────────────────────────────────────────────────────────────────────
# WORKFLOW: SESSION SUMMARY
# ─────────────────────────────────────────────────────────────────────────────

function Show-SessionSummary {
    Clear-Host
    Write-Host ''
    Write-Host '  ═══════════════════════════════════════════════════════════' -ForegroundColor Cyan
    Write-Host '   Session Summary' -ForegroundColor White
    Write-Host '  ═══════════════════════════════════════════════════════════' -ForegroundColor Cyan

    foreach ($group in ($script:Steps | Group-Object Phase)) {
        Write-Host ''
        Write-Host "  ── $($group.Name)" -ForegroundColor White
        foreach ($step in $group.Group) {
            $badge = switch ($step.Status) {
                'DONE'    { '[DONE]' }
                'FAIL'    { '[FAIL]' }
                'SKIP'    { '[SKIP]' }
                default   { '[    ]' }
            }
            $color = switch ($step.Status) {
                'DONE'    { 'Green' }
                'FAIL'    { 'Red' }
                'SKIP'    { 'Yellow' }
                default   { 'Gray' }
            }
            Write-Host "    $badge  $($step.DisplayName)" -ForegroundColor $color
        }
    }

    Write-Host ''
    Write-Host '  ─────────────────────────────────────────────────────────' -ForegroundColor DarkGray
    $done  = ($script:Steps | Where-Object { $_.Status -eq 'DONE' }).Count
    $fail  = ($script:Steps | Where-Object { $_.Status -eq 'FAIL' }).Count
    $skip  = ($script:Steps | Where-Object { $_.Status -eq 'SKIP' }).Count
    $norun = ($script:Steps | Where-Object { $_.Status -eq 'not-run' }).Count
    Write-Host "  Passed  : $done" -ForegroundColor Green
    $failColor = if ($fail -gt 0) { 'Red' } else { 'Gray' }
    Write-Host "  Failed  : $fail" -ForegroundColor $failColor
    Write-Host "  Skipped : $skip" -ForegroundColor Yellow
    Write-Host "  Not Run : $norun" -ForegroundColor Gray
    Write-Host '  ═══════════════════════════════════════════════════════════' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  Press any key to return to menu...' -ForegroundColor DarkGray
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

    # Phase 1 — no leading separator; it's the first visible group
    foreach ($s in ($script:Steps | Where-Object { $_.Phase -eq 'Phase1-Prerequisites' })) {
        $null = $items.Add($s)
    }

    # Phase 2
    $null = $items.Add((Get-MenuSeparator))
    foreach ($s in ($script:Steps | Where-Object { $_.Phase -eq 'Phase2-DataBackup' })) {
        $null = $items.Add($s)
    }

    # Phase 3
    $null = $items.Add((Get-MenuSeparator))
    foreach ($s in ($script:Steps | Where-Object { $_.Phase -eq 'Phase3-Hardware' })) {
        $null = $items.Add($s)
    }

    # Phase 4
    $null = $items.Add((Get-MenuSeparator))
    foreach ($s in ($script:Steps | Where-Object { $_.Phase -eq 'Phase4-Autopilot' })) {
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

    # Defensive: only format our PSCustomObjects; let PSMenu render separators natively
    if (-not ($item -is [PSCustomObject])) { return '' }
    if (-not ($item.PSObject.Properties.Name -contains 'IsWorkflow')) { return '' }

    # Workflow items have no status badge
    if ($item.IsWorkflow) {
        return "  $($item.DisplayName)"
    }

    # Step items: show status badge and 1-based index
    $badge = switch ($item.Status) {
        'DONE'  { '[DONE]' }
        'FAIL'  { '[FAIL]' }
        'SKIP'  { '[SKIP]' }
        default { '[    ]' }
    }
    $idx = "[$($item.Index.ToString().PadLeft(2))]"
    return "  $badge $idx $($item.DisplayName)"
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
