<#
.SYNOPSIS
    Interactive orchestrator for the Pre-Wipe Toolkit.

.DESCRIPTION
    Menu-driven workflow that guides a tech through all 31 pre-wipe preparation
    steps across four categories: Scan/Check/Backup, Configure,
    Install & Update, and Autopilot.

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
# STEP DEFINITIONS  (31 steps — ordered by impact level)
# ScriptPath is relative to $PSScriptRoot
# ─────────────────────────────────────────────────────────────────────────────
$script:Steps = @(
    # ── Scan, Check & Backup (low impact — read-only or backup only) ───────
    [PSCustomObject]@{ Index =  1; Phase = 'ScanCheckBackup'; DisplayName = 'Scan for Unbacked Data & Non-Std Apps'; ScriptPath = 'Scripts\DataCollection\Find-UnbackedData.ps1';                   Status = 'not-run'; IsWorkflow = $false }
    [PSCustomObject]@{ Index =  2; Phase = 'ScanCheckBackup'; DisplayName = 'Check Downloads Folder Sizes';          ScriptPath = 'Scripts\DataCollection\Get-DownloadsSize.ps1';                   Status = 'not-run'; IsWorkflow = $false }
    [PSCustomObject]@{ Index =  3; Phase = 'ScanCheckBackup'; DisplayName = 'Get Drive Mappings';                    ScriptPath = 'Scripts\DataCollection\Get-DriveMappings.ps1';                   Status = 'not-run'; IsWorkflow = $false }
    [PSCustomObject]@{ Index =  4; Phase = 'ScanCheckBackup'; DisplayName = 'List Printers';                         ScriptPath = 'Scripts\DataCollection\Get-Printers.ps1';                        Status = 'not-run'; IsWorkflow = $false }
    [PSCustomObject]@{ Index =  5; Phase = 'ScanCheckBackup'; DisplayName = 'Get Windows Product Key';               ScriptPath = 'Scripts\DataCollection\Get-WindowsProductKey.ps1';               Status = 'not-run'; IsWorkflow = $false }
    [PSCustomObject]@{ Index =  6; Phase = 'ScanCheckBackup'; DisplayName = 'Get Installed Applications';            ScriptPath = 'Scripts\DataCollection\Get-InstalledApplications.ps1';           Status = 'not-run'; IsWorkflow = $false }
    [PSCustomObject]@{ Index =  7; Phase = 'ScanCheckBackup'; DisplayName = 'Get Device Health Report';              ScriptPath = 'Scripts\DataCollection\Get-DeviceHealth.ps1';                    Status = 'not-run'; IsWorkflow = $false }
    [PSCustomObject]@{ Index =  8; Phase = 'ScanCheckBackup'; DisplayName = 'Get Teams Chat & Meeting Data';         ScriptPath = 'Scripts\DataCollection\Get-TeamsData.ps1';                       Status = 'not-run'; IsWorkflow = $false }
    [PSCustomObject]@{ Index =  9; Phase = 'ScanCheckBackup'; DisplayName = 'Get Credential Manager Entries';        ScriptPath = 'Scripts\DataCollection\Get-CredentialManagerEntries.ps1';        Status = 'not-run'; IsWorkflow = $false }
    [PSCustomObject]@{ Index = 10; Phase = 'ScanCheckBackup'; DisplayName = 'Get Local Accounts';                    ScriptPath = 'Scripts\DataCollection\Get-LocalAccounts.ps1';                   Status = 'not-run'; IsWorkflow = $false }
    [PSCustomObject]@{ Index = 11; Phase = 'ScanCheckBackup'; DisplayName = 'Test OneDrive KFM Status';              ScriptPath = 'Scripts\ConfigurationChecks\Test-OneDriveKFM.ps1';               Status = 'not-run'; IsWorkflow = $false }
    [PSCustomObject]@{ Index = 12; Phase = 'ScanCheckBackup'; DisplayName = 'Test OneDrive Sync Status';             ScriptPath = 'Scripts\ConfigurationChecks\Test-OneDriveSyncStatus.ps1';        Status = 'not-run'; IsWorkflow = $false }
    [PSCustomObject]@{ Index = 13; Phase = 'ScanCheckBackup'; DisplayName = 'Get Storage Controller Mode';           ScriptPath = 'Scripts\ConfigurationChecks\Get-StorageMode.ps1';                Status = 'not-run'; IsWorkflow = $false }
    [PSCustomObject]@{ Index = 14; Phase = 'ScanCheckBackup'; DisplayName = 'Test BIOS Version (Dell)';              ScriptPath = 'Scripts\ConfigurationChecks\Test-BiosVersion.ps1';               Status = 'not-run'; IsWorkflow = $false }
    [PSCustomObject]@{ Index = 15; Phase = 'ScanCheckBackup'; DisplayName = 'Test Driver Status (Dell DCU)';         ScriptPath = 'Scripts\ConfigurationChecks\Test-DriverStatus.ps1';              Status = 'not-run'; IsWorkflow = $false }
    [PSCustomObject]@{ Index = 16; Phase = 'ScanCheckBackup'; DisplayName = 'Test Wake-on-LAN Settings';             ScriptPath = 'Scripts\ConfigurationChecks\Test-WakeOnLan.ps1';                Status = 'not-run'; IsWorkflow = $false }
    [PSCustomObject]@{ Index = 17; Phase = 'ScanCheckBackup'; DisplayName = 'Test Windows Recovery (WinRE)';         ScriptPath = 'Scripts\ConfigurationChecks\Test-WinRE.ps1';                     Status = 'not-run'; IsWorkflow = $false }
    [PSCustomObject]@{ Index = 18; Phase = 'ScanCheckBackup'; DisplayName = 'Backup Browser Bookmarks';              ScriptPath = 'Scripts\ConfigurationChanges\Backup-BrowserBookmarks.ps1';       Status = 'not-run'; IsWorkflow = $false }
    [PSCustomObject]@{ Index = 19; Phase = 'ScanCheckBackup'; DisplayName = 'Backup Desktop Background';             ScriptPath = 'Scripts\ConfigurationChanges\Backup-DesktopBackground.ps1';     Status = 'not-run'; IsWorkflow = $false }
    [PSCustomObject]@{ Index = 20; Phase = 'ScanCheckBackup'; DisplayName = 'Backup Outlook Signatures';             ScriptPath = 'Scripts\ConfigurationChanges\Backup-OutlookSignatures.ps1';     Status = 'not-run'; IsWorkflow = $false }
    [PSCustomObject]@{ Index = 21; Phase = 'ScanCheckBackup'; DisplayName = 'Backup Taskbar Layout';                 ScriptPath = 'Scripts\ConfigurationChanges\Backup-TaskbarLayout.ps1';         Status = 'not-run'; IsWorkflow = $false }
    [PSCustomObject]@{ Index = 22; Phase = 'ScanCheckBackup'; DisplayName = 'Backup Wi-Fi Profiles';                 ScriptPath = 'Scripts\ConfigurationChanges\Backup-WiFiProfiles.ps1';          Status = 'not-run'; IsWorkflow = $false }

    # ── Configure (changes settings) ──────────────────────────────────────
    [PSCustomObject]@{ Index = 23; Phase = 'Configure';     DisplayName = 'Escrow BitLocker Key to Entra ID';        ScriptPath = 'Scripts\ConfigurationChanges\Test-BitLockerEscrow.ps1';        Status = 'not-run'; IsWorkflow = $false }
    [PSCustomObject]@{ Index = 24; Phase = 'Configure';     DisplayName = 'Set Wake-on-LAN (BIOS + NIC + Windows)';  ScriptPath = 'Scripts\ConfigurationChanges\Set-WakeOnLan.ps1';              Status = 'not-run'; IsWorkflow = $false }

    # ── Install & Update ──────────────────────────────────────────────────
    [PSCustomObject]@{ Index = 25; Phase = 'InstallUpdate'; DisplayName = 'Install Dell Command Tools (DCU + DCC)';  ScriptPath = 'Scripts\ConfigurationChanges\Install-DellCommandTools.ps1';   Status = 'not-run'; IsWorkflow = $false }
    [PSCustomObject]@{ Index = 26; Phase = 'InstallUpdate'; DisplayName = 'Update Drivers (Dell DCU)';               ScriptPath = 'Scripts\ConfigurationChanges\Update-Drivers.ps1';             Status = 'not-run'; IsWorkflow = $false }
    [PSCustomObject]@{ Index = 27; Phase = 'InstallUpdate'; DisplayName = 'Update BIOS (Dell DCU — may reboot)';     ScriptPath = 'Scripts\ConfigurationChanges\Update-Bios.ps1';                Status = 'not-run'; IsWorkflow = $false }

    # ── Autopilot ─────────────────────────────────────────────────────────
    [PSCustomObject]@{ Index = 28; Phase = 'Autopilot';     DisplayName = 'Test Autopilot Readiness';                ScriptPath = 'Scripts\AutopilotReadiness\Test-AutopilotReadiness.ps1';      Status = 'not-run'; IsWorkflow = $false }
    [PSCustomObject]@{ Index = 29; Phase = 'Autopilot';     DisplayName = 'Get Autopilot Assignment';                ScriptPath = 'Scripts\AutopilotReadiness\Get-AutopilotAssignment.ps1';      Status = 'not-run'; IsWorkflow = $false }
    [PSCustomObject]@{ Index = 30; Phase = 'Autopilot';     DisplayName = 'Register Device with Autopilot';          ScriptPath = 'Scripts\AutopilotReadiness\Register-AutopilotDevice.ps1';    Status = 'not-run'; IsWorkflow = $false }
    [PSCustomObject]@{ Index = 31; Phase = 'Autopilot';     DisplayName = 'Pre-Wipe Summary';                        ScriptPath = 'Scripts\AutopilotReadiness\Get-PreWipeSummary.ps1';          Status = 'not-run'; IsWorkflow = $false }
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
# Uses PSMenu's native Show-Menu — no custom menu renderer.
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

function Show-Header {
    $done  = @($script:Steps | Where-Object { $_.Status -eq 'DONE' }).Count
    $fail  = @($script:Steps | Where-Object { $_.Status -eq 'FAIL' }).Count
    $total = $script:Steps.Count

    Write-Host ''
    Write-Host '  Pre-Wipe Toolkit · AshesToAutopilot' -ForegroundColor White
    Write-Host "  $($script:ComputerName) · SN: $($script:SerialNumber) · $($script:CurrentUser)" -ForegroundColor DarkGray

    # Progress bar
    $barLen  = 24
    $filled  = if ($total -gt 0) { [Math]::Floor(($done / $total) * $barLen) } else { 0 }
    $empty   = $barLen - $filled
    Write-Host -NoNewline '  '
    if ($filled -gt 0) { Write-Host -NoNewline ([string]::new([char]0x2588, $filled)) -ForegroundColor Green }
    if ($empty  -gt 0) { Write-Host -NoNewline ([string]::new([char]0x2591, $empty))  -ForegroundColor DarkGray }
    $progText = "  $done/$total complete"
    if ($fail -gt 0) { $progText += " · $fail failed" }
    Write-Host $progText -ForegroundColor Gray

    Write-Host "  $('─' * 56)" -ForegroundColor DarkGray
    Write-Host ''
}

function Show-StepBanner {
    param([PSCustomObject]$Step)
    $phaseLabel = Get-PhaseLabel $Step.Phase
    Write-CyanBox -Lines @(
        $Step.DisplayName
        ("Category : {0}" -f $phaseLabel)
        ("Script   : {0}" -f $Step.ScriptPath)
    )
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
        Write-Host '  [DONE] Completed.' -ForegroundColor White
    }
    else {
        $Step.Status = 'FAIL'
        Write-Host "  [FAIL] Exited with code $exitCode — review output above." -ForegroundColor Red
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
        'Runs all 31 steps in order.'
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
        # Brief pause so the tech sees the result line before next step clears screen
        Start-Sleep -Milliseconds 800
    }

    Write-CyanBox -Lines @(
        'Run All Complete'
        ("Done    :{0}" -f $counts.DONE)
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
        $lines += ("-- {0}" -f (Get-PhaseLabel $group.Name))
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
    $lines += ("Done    : {0}" -f $done)
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
            $lines.Add("--- $(Get-PhaseLabel $group.Name) ---")
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
        $lines.Add("  Done    :$done")
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

    # Scan, Check & Backup — first group, no leading separator
    foreach ($s in ($script:Steps | Where-Object { $_.Phase -eq 'ScanCheckBackup' })) {
        $null = $items.Add($s)
    }

    # Configure
    $null = $items.Add((Get-MenuSeparator))
    foreach ($s in ($script:Steps | Where-Object { $_.Phase -eq 'Configure' })) {
        $null = $items.Add($s)
    }

    # Install & Update
    $null = $items.Add((Get-MenuSeparator))
    foreach ($s in ($script:Steps | Where-Object { $_.Phase -eq 'InstallUpdate' })) {
        $null = $items.Add($s)
    }

    # Autopilot
    $null = $items.Add((Get-MenuSeparator))
    foreach ($s in ($script:Steps | Where-Object { $_.Phase -eq 'Autopilot' })) {
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
    if (-not ($item -is [PSCustomObject])) { return $item.ToString() }
    if (-not ($item.PSObject.Properties.Name -contains 'IsWorkflow')) { return $item.ToString() }

    if ($item.IsWorkflow) {
        return $item.DisplayName
    }

    $badge = switch ($item.Status) {
        'DONE'  { '[DONE]' }
        'FAIL'  { '[FAIL]' }
        'SKIP'  { '[SKIP]' }
        default { '[    ]' }
    }
    return "$badge  $($item.DisplayName)"
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
        $selected  = Show-Menu -MenuItems $menuItems -MenuItemFormatter $script:Formatter -ItemFocusColor Green

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
