<#
.SYNOPSIS
    Unified interactive orchestrator for the Pre-Wipe Toolkit.

.DESCRIPTION
    Menu-driven workflow that guides a tech through all 31 pre-wipe preparation
    steps. Numbered single-key menus; no external module dependencies.

    Modes:
    - Quick Check  : 12 core steps (fast scan + backup essentials)
    - Full Prep    : all 31 steps in sequence
    - Single Step  : pick any step by number
    - Custom Run   : enter a comma-separated list of step numbers

    Features:
    - Retro terminal aesthetic: box-drawing chars, block progress bars
    - Session state persistence to C:\PreWipeOutput\session.json
    - Resume on reopen
    - Per-step status: DONE / FAIL / SKIP / not-run
    - Inline result accumulation (no screen-clears between steps)
    - HTML report on completion of any run mode

.PARAMETER NonInteractive
    Emits current session state as JSON to stdout, then exits.

.EXAMPLE
    .\Start-PreWipeToolkit.ps1
    .\Start-PreWipeToolkit.ps1 -NonInteractive
#>

[CmdletBinding()]
param([switch]$NonInteractive) # Non-interactive mode emits JSON to stdout only

#region --- Init / Admin Check ---

$ScriptName  = 'Start-PreWipeToolkit' # Script identifier for log headers
$OutputRoot  = 'C:\PreWipeOutput' # Base output directory
$LogDir      = Join-Path $OutputRoot 'Logs' # Log file directory
$LogFile     = Join-Path $LogDir "$ScriptName`_$(Get-Date -Format 'yyyyMMdd').log" # Daily activity log
$ErrorLog    = Join-Path $LogDir "$ScriptName`_Errors_$(Get-Date -Format 'yyyyMMdd').log" # Error log
$SessionFile = Join-Path $OutputRoot 'session.json' # Session state persistence file

foreach ($dir in @($OutputRoot, $LogDir)) {
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null } # Create output folders if missing
}

function Write-Log { # Writes timestamped message to log file and console
    param([string]$Message, [string]$Level = 'INFO')
    "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message" | Add-Content -Path $LogFile -Encoding UTF8
    if (-not $NonInteractive) {
        $color = switch ($Level) { 'WARN' { 'Yellow' } 'ERROR' { 'Red' } default { 'Gray' } }
        Write-Host "  $Message" -ForegroundColor $color
    }
}

function Write-ErrorLog { # Logs errors to dedicated error log file
    param([string]$Message)
    "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$ScriptName] ERROR: $Message" | Add-Content -Path $ErrorLog -Encoding UTF8
    Write-Log -Message $Message -Level 'ERROR'
}

$_principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent() # Check current user permissions
if (-not $_principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { # Verify Administrator role
    Write-Host 'ERROR: This script must run as Administrator.' -ForegroundColor Red
    Write-Host 'Right-click PowerShell → Run as Administrator, then try again.' -ForegroundColor Yellow
    exit 1
}

#endregion

#region --- Hardware Info ---

$script:TermWidth    = try { [Math]::Min($Host.UI.RawUI.WindowSize.Width, 100) } catch { 80 } # Terminal width for formatting
$script:ComputerName = $env:COMPUTERNAME # Device hostname
$script:CurrentUser  = $env:USERNAME # Current user running script

try {
    $script:_bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction SilentlyContinue # Query system BIOS
    $script:SerialNumber = if ($script:_bios -and $script:_bios.SerialNumber) {
        $script:_bios.SerialNumber.Trim() # Extract and clean serial number
    } else { 'Unknown' }
} catch {
    $script:SerialNumber = 'Unknown' # Fallback if BIOS query fails
}

Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue # Load for HTML encoding in reports

#endregion

#region --- Step Definitions ---

$script:QuickCheckIndices = @(11, 12, 1, 2, 3, 6, 13, 18, 19, 20, 4, 29) # 12 core steps for quick scan

$script:PhaseLabels = [ordered]@{ # Human-readable phase names
    'ScanCheckBackup' = 'Scan, Check & Backup'
    'Configure'       = 'Configure'
    'InstallUpdate'   = 'Install & Update'
    'Autopilot'       = 'Autopilot'
}

function Get-PhaseLabel([string]$Phase) {
    if ($script:PhaseLabels.Contains($Phase)) { return $script:PhaseLabels[$Phase] }
    return $Phase
}

$script:Steps = @(
    [PSCustomObject]@{ Index =  1; Phase = 'ScanCheckBackup'; DisplayName = 'Scan for Unbacked Data & Non-Std Apps'; ScriptPath = 'Scripts\DataCollection\Find-UnbackedData.ps1';                 Status = 'not-run' }
    [PSCustomObject]@{ Index =  2; Phase = 'ScanCheckBackup'; DisplayName = 'Check Downloads Folder Sizes';          ScriptPath = 'Scripts\DataCollection\Get-DownloadsSize.ps1';                 Status = 'not-run' }
    [PSCustomObject]@{ Index =  3; Phase = 'ScanCheckBackup'; DisplayName = 'Get Drive Mappings';                    ScriptPath = 'Scripts\DataCollection\Get-DriveMappings.ps1';                 Status = 'not-run' }
    [PSCustomObject]@{ Index =  4; Phase = 'ScanCheckBackup'; DisplayName = 'List Printers';                         ScriptPath = 'Scripts\DataCollection\Get-Printers.ps1';                      Status = 'not-run' }
    [PSCustomObject]@{ Index =  5; Phase = 'ScanCheckBackup'; DisplayName = 'Get Windows Product Key';               ScriptPath = 'Scripts\DataCollection\Get-WindowsProductKey.ps1';             Status = 'not-run' }
    [PSCustomObject]@{ Index =  6; Phase = 'ScanCheckBackup'; DisplayName = 'Get Installed Applications';            ScriptPath = 'Scripts\DataCollection\Get-InstalledApplications.ps1';         Status = 'not-run' }
    [PSCustomObject]@{ Index =  7; Phase = 'ScanCheckBackup'; DisplayName = 'Get Device Health Report';              ScriptPath = 'Scripts\DataCollection\Get-DeviceHealth.ps1';                  Status = 'not-run' }
    [PSCustomObject]@{ Index =  8; Phase = 'ScanCheckBackup'; DisplayName = 'Get Teams Chat & Meeting Data';         ScriptPath = 'Scripts\DataCollection\Get-TeamsData.ps1';                     Status = 'not-run' }
    [PSCustomObject]@{ Index =  9; Phase = 'ScanCheckBackup'; DisplayName = 'Get Credential Manager Entries';        ScriptPath = 'Scripts\DataCollection\Get-CredentialManagerEntries.ps1';      Status = 'not-run' }
    [PSCustomObject]@{ Index = 10; Phase = 'ScanCheckBackup'; DisplayName = 'Get Local Accounts';                    ScriptPath = 'Scripts\DataCollection\Get-LocalAccounts.ps1';                 Status = 'not-run' }
    [PSCustomObject]@{ Index = 11; Phase = 'ScanCheckBackup'; DisplayName = 'Test OneDrive KFM Status';              ScriptPath = 'Scripts\ConfigurationChecks\Test-OneDriveKFM.ps1';             Status = 'not-run' }
    [PSCustomObject]@{ Index = 12; Phase = 'ScanCheckBackup'; DisplayName = 'Test OneDrive Sync Status';             ScriptPath = 'Scripts\ConfigurationChecks\Test-OneDriveSyncStatus.ps1';      Status = 'not-run' }
    [PSCustomObject]@{ Index = 13; Phase = 'ScanCheckBackup'; DisplayName = 'Get Storage Controller Mode';           ScriptPath = 'Scripts\ConfigurationChecks\Get-StorageMode.ps1';              Status = 'not-run' }
    [PSCustomObject]@{ Index = 14; Phase = 'ScanCheckBackup'; DisplayName = 'Test BIOS Version (Dell)';              ScriptPath = 'Scripts\ConfigurationChecks\Test-BiosVersion.ps1';             Status = 'not-run' }
    [PSCustomObject]@{ Index = 15; Phase = 'ScanCheckBackup'; DisplayName = 'Test Driver Status (Dell DCU)';         ScriptPath = 'Scripts\ConfigurationChecks\Test-DriverStatus.ps1';            Status = 'not-run' }
    [PSCustomObject]@{ Index = 16; Phase = 'ScanCheckBackup'; DisplayName = 'Test Wake-on-LAN Settings';             ScriptPath = 'Scripts\ConfigurationChecks\Test-WakeOnLan.ps1';               Status = 'not-run' }
    [PSCustomObject]@{ Index = 17; Phase = 'ScanCheckBackup'; DisplayName = 'Test Windows Recovery (WinRE)';         ScriptPath = 'Scripts\ConfigurationChecks\Test-WinRE.ps1';                   Status = 'not-run' }
    [PSCustomObject]@{ Index = 18; Phase = 'ScanCheckBackup'; DisplayName = 'Backup Browser Bookmarks';              ScriptPath = 'Scripts\ConfigurationChanges\Backup-BrowserBookmarks.ps1';     Status = 'not-run' }
    [PSCustomObject]@{ Index = 19; Phase = 'ScanCheckBackup'; DisplayName = 'Backup Desktop Background';             ScriptPath = 'Scripts\ConfigurationChanges\Backup-DesktopBackground.ps1';   Status = 'not-run' }
    [PSCustomObject]@{ Index = 20; Phase = 'ScanCheckBackup'; DisplayName = 'Backup Outlook Signatures';             ScriptPath = 'Scripts\ConfigurationChanges\Backup-OutlookSignatures.ps1';   Status = 'not-run' }
    [PSCustomObject]@{ Index = 21; Phase = 'ScanCheckBackup'; DisplayName = 'Backup Taskbar Layout';                 ScriptPath = 'Scripts\ConfigurationChanges\Backup-TaskbarLayout.ps1';       Status = 'not-run' }
    [PSCustomObject]@{ Index = 22; Phase = 'ScanCheckBackup'; DisplayName = 'Backup Wi-Fi Profiles';                 ScriptPath = 'Scripts\ConfigurationChanges\Backup-WiFiProfiles.ps1';        Status = 'not-run' }
    [PSCustomObject]@{ Index = 23; Phase = 'Configure';       DisplayName = 'Escrow BitLocker Key to Entra ID';      ScriptPath = 'Scripts\ConfigurationChanges\Test-BitLockerEscrow.ps1';       Status = 'not-run' }
    [PSCustomObject]@{ Index = 24; Phase = 'Configure';       DisplayName = 'Set Wake-on-LAN (BIOS + NIC + Windows)';ScriptPath = 'Scripts\ConfigurationChanges\Set-WakeOnLan.ps1';              Status = 'not-run' }
    [PSCustomObject]@{ Index = 25; Phase = 'InstallUpdate';   DisplayName = 'Install Dell Command Tools';            ScriptPath = 'Scripts\ConfigurationChanges\Install-DellCommandTools.ps1';   Status = 'not-run' }
    [PSCustomObject]@{ Index = 26; Phase = 'InstallUpdate';   DisplayName = 'Update Drivers (Dell DCU)';             ScriptPath = 'Scripts\ConfigurationChanges\Update-Drivers.ps1';             Status = 'not-run' }
    [PSCustomObject]@{ Index = 27; Phase = 'InstallUpdate';   DisplayName = 'Update BIOS (Dell DCU — may reboot)';   ScriptPath = 'Scripts\ConfigurationChanges\Update-Bios.ps1';                Status = 'not-run' }
    [PSCustomObject]@{ Index = 28; Phase = 'Autopilot';       DisplayName = 'Test Autopilot Readiness';              ScriptPath = 'Scripts\AutopilotReadiness\Test-AutopilotReadiness.ps1';      Status = 'not-run' }
    [PSCustomObject]@{ Index = 29; Phase = 'Autopilot';       DisplayName = 'Get Autopilot Assignment';              ScriptPath = 'Scripts\AutopilotReadiness\Get-AutopilotAssignment.ps1';      Status = 'not-run' }
    [PSCustomObject]@{ Index = 30; Phase = 'Autopilot';       DisplayName = 'Register Device with Autopilot';        ScriptPath = 'Scripts\AutopilotReadiness\Register-AutopilotDevice.ps1';    Status = 'not-run' }
    [PSCustomObject]@{ Index = 31; Phase = 'Autopilot';       DisplayName = 'Pre-Wipe Summary';                      ScriptPath = 'Scripts\AutopilotReadiness\Get-PreWipeSummary.ps1';          Status = 'not-run' }
)

#endregion

#region --- Session Management ---

function Initialize-Session { # Creates blank session state
    $steps = @{}
    foreach ($step in $script:Steps) {
        $steps["$($step.Index)"] = @{ Status = 'not-run'; Timestamp = $null; ExitCode = $null } # Initialize each step as not-run
    }
    return [PSCustomObject]@{
        StartTime    = (Get-Date -Format 'o') # Session start timestamp
        ComputerName = $script:ComputerName
        SerialNumber = $script:SerialNumber
        CurrentUser  = $script:CurrentUser
        Steps        = $steps
    }
}

function Import-Session { # Loads session from JSON or creates new
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
        foreach ($step in $script:Steps) {
            $key = "$($step.Index)"
            if ($steps.ContainsKey($key) -and $steps[$key].Status) {
                $step.Status = $steps[$key].Status
            }
        }
        if (-not $NonInteractive) {
            Write-Host "  Session resumed from: $SessionFile" -ForegroundColor DarkGray
            Start-Sleep -Milliseconds 800
        }
        return [PSCustomObject]@{
            StartTime    = $raw.StartTime
            ComputerName = $raw.ComputerName
            SerialNumber = $raw.SerialNumber
            CurrentUser  = $raw.CurrentUser
            Steps        = $steps
        }
    } catch {
        if (-not $NonInteractive) {
            Write-Host "  Warning: Could not load session.json — starting fresh." -ForegroundColor Yellow
        }
        return Initialize-Session
    }
}

function Save-Session { # Persists session to disk
    try {
        $script:Session | ConvertTo-Json -Depth 5 | Set-Content $SessionFile -Encoding UTF8 # Write session JSON
    } catch {
        Write-Host "  Warning: Could not save session.json: $_" -ForegroundColor Yellow
    }
}

function Update-SessionStep { # Updates step status after execution
    param([int]$Index, [string]$Status, $ExitCode)
    $key = "$Index"
    if (-not $script:Session.Steps.ContainsKey($key)) { $script:Session.Steps[$key] = @{} }
    $script:Session.Steps[$key].Status    = $Status
    $script:Session.Steps[$key].Timestamp = (Get-Date -Format 'o')
    $script:Session.Steps[$key].ExitCode  = $ExitCode
}

#endregion

#region --- Display Helpers ---

function Read-MenuKey { # Waits for single keypress
    $key = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') # Capture without echo
    return $key.Character.ToString().ToUpper() # Return uppercase char
}

$script:FullBanner = @( # ASCII art full banner (13 lines)
   ' █████╗ ███████╗██╗  ██╗███████╗███████╗    ████████╗ ██████╗            '
   ' ██╔══██╗██╔════╝██║  ██║██╔════╝██╔════╝    ╚══██╔══╝██╔═══██╗          '
   ' ███████║███████╗███████║█████╗  ███████╗       ██║   ██║   ██║          ' 
   ' ██╔══██║╚════██║██╔══██║██╔══╝  ╚════██║       ██║   ██║   ██║          ' 
   ' ██║  ██║███████║██║  ██║███████╗███████║       ██║   ╚██████╔╝          ' 
   ' ╚═╝  ╚═╝╚══════╝╚═╝  ╚═╝╚══════╝╚══════╝       ╚═╝    ╚═════╝           ' 
   '                                                                         ' 
   ' █████╗ ██╗   ██╗████████╗ ██████╗ ██████╗ ██╗██╗      ██████╗ ████████╗ '
   ' ██╔══██╗██║   ██║╚══██╔══╝██╔═══██╗██╔══██╗██║██║     ██╔═══██╗╚══██╔══╝'
   ' ███████║██║   ██║   ██║   ██║   ██║██████╔╝██║██║     ██║   ██║   ██║   '
   ' ██╔══██║██║   ██║   ██║   ██║   ██║██╔═══╝ ██║██║     ██║   ██║   ██║   '
   ' ██║  ██║╚██████╔╝   ██║   ╚██████╔╝██║     ██║███████╗╚██████╔╝   ██║   '
   ' ╚═╝  ╚═╝ ╚═════╝    ╚═╝    ╚═════╝ ╚═╝     ╚═╝╚══════╝ ╚═════╝    ╚═╝   '
   '                                                                         '
   '     Pre-Wipe Preparation Toolkit for Windows Device Wipe & Autopilot    '
   '          Created by Nathan Sol | NeverNathaniel/AshesToAutopilot                                                          '
)

$script:CompactBanner = @( # Compact 4-line banner
   '  ╔═══════════════════════════════════════════════════════════╗'
   '  ║   /_\ / __| || | __/ __| |_   _/ _ \                      ║'
   '  ║  / _ \\__ \ __ | _|\__ \   | || (_) |                     ║'
   '  ║ /_/_\_\___/_||_|___|___/__ |_| \___/___ _____             ║'
   '  ║   /_\| | | |_   _/ _ \| _ \_ _| |  / _ \_   _|            ║'
   '  ║  / _ \ |_| | | || (_) |  _/| || |_| (_) || |              ║'
   '  ║ /_/ \_\___/  |_| \___/|_| |___|____\___/ |_|              ║'
   '  ╚═══════════════════════════════════════════════════════════╝'
)

$script:IsInitialBanner = $true # Track if this is the first display

function Write-BannerFull { # Displays full ASCII banner (13 lines)
    Write-Host '' # Blank line
    foreach ($line in $script:FullBanner) {
        Write-Host $line -ForegroundColor Cyan # Display each line
    }
    Write-Host '' # Blank line
}

function Write-Banner { # Displays compact 4-line banner
    Write-Host '' # Blank line
    foreach ($line in $script:CompactBanner) {
        Write-Host $line -ForegroundColor Cyan # Display compact banner
    }
    Write-Host '' # Blank line
}

function Show-InitialBanner { # Shows full banner for 3 seconds, then compact on subsequent loops
    if ($script:IsInitialBanner) {
        Write-BannerFull # Display full banner
        Start-Sleep -Seconds 3 # Wait 3 seconds
        Clear-Host # Clear screen
        Write-Banner # Show compact banner
        $script:IsInitialBanner = $false # Set flag for next iterations
    } else {
        Write-Banner # Show compact banner on subsequent calls
    }
}

function Get-ProgressBarString { # Renders filled progress bar
    param([int]$Done, [int]$Total, [int]$Width = 24)
    $filled = if ($Total -gt 0) { [Math]::Floor(($Done / $Total) * $Width) } else { 0 }
    $empty  = $Width - $filled
    return ([string]::new([char]0x2588, $filled)) + ([string]::new([char]0x2591, $empty))
}

function Show-MainMenu { # Displays main menu with progress
    $done  = @($script:Steps | Where-Object { $_.Status -eq 'DONE' }).Count # Count completed steps
    $fail  = @($script:Steps | Where-Object { $_.Status -eq 'FAIL' }).Count # Count failed steps
    $total = $script:Steps.Count # Total step count

    Clear-Host # Clear screen
    Show-InitialBanner # Show banner (full on first run, compact after)

    $inner   = 56
    $bar     = '═' * ($inner + 2)
    $progBar = Get-ProgressBarString -Done $done -Total $total -Width 24
    $progTxt = "$progBar  $done/$total complete$(if ($fail -gt 0) { "  ($fail failed)" })"

    Write-Host "  ╔$bar╗" -ForegroundColor Cyan
    Write-Host ("  ║ {0} ║" -f ("  $($script:ComputerName)  ·  SN: $($script:SerialNumber)  ·  $($script:CurrentUser)").PadRight($inner)) -ForegroundColor DarkGray
    Write-Host ("  ║ {0} ║" -f ("  $progTxt").PadRight($inner)) -ForegroundColor Cyan
    Write-Host ("  ║ {0} ║" -f ''.PadRight($inner)) -ForegroundColor Cyan
    Write-Host "  ╠$bar╣" -ForegroundColor Cyan
    Write-Host ("  ║ {0} ║" -f ''.PadRight($inner)) -ForegroundColor Cyan
    Write-Host ("  ║ {0} ║" -f '  [1]  Quick Check       12 core steps'.PadRight($inner)) -ForegroundColor White
    Write-Host ("  ║ {0} ║" -f '  [2]  Full Prep         all 31 steps'.PadRight($inner)) -ForegroundColor White
    Write-Host ("  ║ {0} ║" -f '  [3]  Run Single Step'.PadRight($inner)) -ForegroundColor White
    Write-Host ("  ║ {0} ║" -f '  [4]  Custom Run        choose steps'.PadRight($inner)) -ForegroundColor White
    Write-Host ("  ║ {0} ║" -f ''.PadRight($inner)) -ForegroundColor Cyan
    Write-Host ("  ║ {0} ║" -f ("  " + ('─' * ($inner - 4))).PadRight($inner)) -ForegroundColor DarkGray
    Write-Host ("  ║ {0} ║" -f ''.PadRight($inner)) -ForegroundColor Cyan
    Write-Host ("  ║ {0} ║" -f '  [5]  View Session Summary'.PadRight($inner)) -ForegroundColor Gray
    Write-Host ("  ║ {0} ║" -f '  [6]  Export Report'.PadRight($inner)) -ForegroundColor Gray
    Write-Host ("  ║ {0} ║" -f '  [7]  Reset Session'.PadRight($inner)) -ForegroundColor Gray
    Write-Host ("  ║ {0} ║" -f ''.PadRight($inner)) -ForegroundColor Cyan
    Write-Host ("  ║ {0} ║" -f ("  " + ('─' * ($inner - 4))).PadRight($inner)) -ForegroundColor DarkGray
    Write-Host ("  ║ {0} ║" -f ''.PadRight($inner)) -ForegroundColor Cyan
    Write-Host ("  ║ {0} ║" -f '  [Q]  Quit'.PadRight($inner)) -ForegroundColor DarkGray
    Write-Host ("  ║ {0} ║" -f ''.PadRight($inner)) -ForegroundColor Cyan
    Write-Host "  ╚$bar╝" -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  Press a key › ' -ForegroundColor DarkCyan -NoNewline
}

function Write-RunHeader { # Displays run mode header
    param([string]$Title, [string]$Sub, [int]$StepCount) # Title, subtitle, step count
    Clear-Host # Clear screen
    Write-BannerFull # Show full banner for run headers
    $inner = 62 # Box inner width
    $bar   = '═' * ($inner + 2) # Box border line
    Write-Host "  ╔$bar╗" -ForegroundColor Cyan # Top border
    Write-Host ("  ║ {0} ║" -f "  $Title".PadRight($inner)) -ForegroundColor White # Title line
    Write-Host ("  ║ {0} ║" -f "  $Sub  ·  $StepCount steps".PadRight($inner)) -ForegroundColor DarkGray # Subtitle line
    Write-Host "  ╚$bar╝" -ForegroundColor Cyan # Bottom border
    Write-Host '' # Blank line
}

function Write-StepLine { # Writes step header during run
    param([int]$Num, [int]$Total, [PSCustomObject]$Step)
    $label = " ── [$Num/$Total]  $($Step.DisplayName) "
    $dash  = '─' * [Math]::Max(2, 68 - $label.Length)
    Write-Host ''
    Write-Host "  $label$dash" -ForegroundColor DarkCyan
}

function Write-StepResultLine { # Displays step execution result
    param([hashtable]$Result) # Result hashtable from step execution
    $elapsed = if ($Result.Elapsed) { '{0:mm\:ss}' -f $Result.Elapsed } else { '--:--' } # Format elapsed time
    $vTag    = switch ($Result.Verdict) { 'PASS' { '[OK]' } 'WARN' { '[!!]' } 'FAIL' { '[XX]' } default { '[--]' } } # Verdict icon
    $vColor  = switch ($Result.Verdict) { 'PASS' { 'Green' } 'WARN' { 'Yellow' } 'FAIL' { 'Red' } default { 'Gray' } } # Verdict color
    $sColor  = switch ($Result.Status)  { 'DONE' { 'White' } 'FAIL' { 'Red' } 'SKIP' { 'Yellow' } default { 'Gray' } } # Status color

    Write-Host -NoNewline "  "
    Write-Host -NoNewline $vTag                -ForegroundColor $vColor
    Write-Host -NoNewline "  [$($Result.Status)]" -ForegroundColor $sColor
    Write-Host -NoNewline "  $($Result.Summary)" -ForegroundColor Gray
    Write-Host            "  ($elapsed)"          -ForegroundColor DarkGray

    if ($Result.VerdictReason -and $Result.Verdict -ne 'PASS') {
        Write-Host "       └─ $($Result.VerdictReason)" -ForegroundColor $vColor
    }
}

function Show-RunSummaryInline {
    param([PSCustomObject[]]$Results)

    $done  = @($Results | Where-Object { $_.Status -eq 'DONE' }).Count
    $fail  = @($Results | Where-Object { $_.Status -eq 'FAIL' }).Count
    $skip  = @($Results | Where-Object { $_.Status -eq 'SKIP' }).Count

    Write-Host ''
    Write-Host "  $('═' * 66)" -ForegroundColor Cyan
    Write-Host '  RESULTS SUMMARY' -ForegroundColor White
    Write-Host "  $('═' * 66)" -ForegroundColor Cyan
    Write-Host ''

    $lastPhase = ''
    foreach ($r in $Results) {
        $step = $script:Steps | Where-Object { $_.Index -eq $r.Index } | Select-Object -First 1
        if ($step -and $step.Phase -ne $lastPhase) {
            $lastPhase = $step.Phase
            Write-Host "   ── $(Get-PhaseLabel $lastPhase) ──" -ForegroundColor DarkGray
        }

        $num     = $r.Index.ToString().PadLeft(2)
        $name    = $r.DisplayName.PadRight(42)
        $elapsed = if ($r.Elapsed) { '{0:mm\:ss}' -f $r.Elapsed } else { '--:--' }
        $sColor  = switch ($r.Status)  { 'DONE' { 'White' } 'FAIL' { 'Red' } 'SKIP' { 'Yellow' } default { 'DarkGray' } }
        $vTag    = switch ($r.Verdict) { 'PASS' { '[OK]' } 'WARN' { '[!!]' } 'FAIL' { '[XX]' } default { '[--]' } }
        $vColor  = switch ($r.Verdict) { 'PASS' { 'Green' } 'WARN' { 'Yellow' } 'FAIL' { 'Red' } default { 'Gray' } }

        Write-Host -NoNewline "   $num  " -ForegroundColor DarkGray
        Write-Host -NoNewline $name       -ForegroundColor Gray
        Write-Host -NoNewline " [$($r.Status)]".PadRight(8) -ForegroundColor $sColor
        Write-Host -NoNewline " $vTag"    -ForegroundColor $vColor
        Write-Host            "  $elapsed" -ForegroundColor DarkGray
    }

    Write-Host ''
    Write-Host "  $('═' * 66)" -ForegroundColor Cyan
    Write-Host -NoNewline '  '
    Write-Host -NoNewline " DONE: $done" -ForegroundColor Green
    Write-Host -NoNewline "   FAIL: " -ForegroundColor Gray
    Write-Host -NoNewline "$fail" -ForegroundColor $(if ($fail -gt 0) { 'Red' } else { 'Gray' })
    Write-Host -NoNewline "   SKIP: " -ForegroundColor Gray
    Write-Host -NoNewline "$skip" -ForegroundColor $(if ($skip -gt 0) { 'Yellow' } else { 'Gray' })
    Write-Host "   Total: $($Results.Count)" -ForegroundColor Gray
    Write-Host "  $('═' * 66)" -ForegroundColor Cyan
    Write-Host ''

    $failV = @($Results | Where-Object { $_.Verdict -eq 'FAIL' })
    $warnV = @($Results | Where-Object { $_.Verdict -eq 'WARN' })

    if ($failV.Count -eq 0 -and $warnV.Count -eq 0) {
        Write-Host '  ╔══════════════════════════════════════╗' -ForegroundColor Green
        Write-Host '  ║   [OK]  READY TO WIPE               ║' -ForegroundColor Green
        Write-Host '  ╚══════════════════════════════════════╝' -ForegroundColor Green
    } elseif ($failV.Count -eq 0) {
        Write-Host '  ╔══════════════════════════════════════╗' -ForegroundColor Yellow
        Write-Host ("  ║   [!!]  READY — $($warnV.Count) warning(s)".PadRight(40) + '║') -ForegroundColor Yellow
        Write-Host '  ╚══════════════════════════════════════╝' -ForegroundColor Yellow
    } else {
        Write-Host '  ╔══════════════════════════════════════╗' -ForegroundColor Red
        Write-Host ("  ║   [XX]  NOT READY — $($failV.Count) issue(s)".PadRight(40) + '║') -ForegroundColor Red
        Write-Host '  ╚══════════════════════════════════════╝' -ForegroundColor Red
        Write-Host ''
        foreach ($fv in $failV) {
            Write-Host "    [XX] $($fv.DisplayName)" -ForegroundColor Red
            Write-Host "         $($fv.VerdictReason)" -ForegroundColor DarkRed
        }
    }
    Write-Host ''
}

function Show-StepListTable {
    param([string]$Title = 'ALL STEPS')
    Write-Host ''
    Write-Host "  $('═' * 66)" -ForegroundColor Cyan
    Write-Host "  $Title" -ForegroundColor White
    Write-Host "  $('═' * 66)" -ForegroundColor Cyan

    $lastPhase = ''
    foreach ($s in $script:Steps) {
        if ($s.Phase -ne $lastPhase) {
            $lastPhase = $s.Phase
            Write-Host ''
            Write-Host "   ── $(Get-PhaseLabel $lastPhase) ──" -ForegroundColor DarkGray
        }
        $badge = switch ($s.Status) {
            'DONE'    { '[DONE]' }
            'FAIL'    { '[FAIL]' }
            'SKIP'    { '[SKIP]' }
            'not-run' { '[    ]' }
            default   { '[    ]' }
        }
        $bColor = switch ($s.Status) {
            'DONE'    { 'Green'  }
            'FAIL'    { 'Red'    }
            'SKIP'    { 'Yellow' }
            default   { 'DarkGray' }
        }
        $num = $s.Index.ToString().PadLeft(2)
        Write-Host -NoNewline "   $num  " -ForegroundColor DarkGray
        Write-Host -NoNewline $badge      -ForegroundColor $bColor
        Write-Host "  $($s.DisplayName)" -ForegroundColor Gray
    }
    Write-Host ''
    Write-Host "  $('─' * 66)" -ForegroundColor DarkGray
}

#endregion

#region --- Verdict Evaluation ---

$script:PrimaryProfile = $null # Primary user profile (identified for KFM checks)
try {
    $vpSkipSIDs  = @('S-1-5-18', 'S-1-5-19', 'S-1-5-20') # System account SIDs to skip
    $vpSkipNames = @('ithlocal', 'itklocal', 'wsi', 'wsiaccount', 'defaultuser0', 'administrator', 'guest') # System/service account names
    $vpCutoff    = (Get-Date).AddDays(-30) # Profile age threshold
    $primaryProfileObj = Get-CimInstance -ClassName Win32_UserProfile -ErrorAction Stop | # Query user profiles
        Where-Object { -not $_.Special -and $vpSkipSIDs -notcontains $_.SID } |
        Where-Object { $vpSkipNames -notcontains (Split-Path $_.LocalPath -Leaf).ToLower() } |
        Where-Object { $_.LastUseTime -and $_.LastUseTime -ge $vpCutoff } |
        Sort-Object LastUseTime -Descending | Select-Object -First 1
    if ($primaryProfileObj) {
        $script:PrimaryProfile = Split-Path $primaryProfileObj.LocalPath -Leaf
        Write-Log "Primary profile: $($script:PrimaryProfile)"
    }
} catch {
    Write-Log "Could not determine primary profile: $_" -Level 'WARN'
}

function Get-StepSummary { # Generates human-readable summary from step output
    param([PSCustomObject]$Parsed, [string]$ScriptFile) # Parsed JSON output and script path
    if ($null -eq $Parsed) { return 'No output' } # Handle null output
    try {
        switch -Wildcard ($ScriptFile) { # Match script and extract key metrics
            '*Test-OneDriveKFM*' {
                if (-not $Parsed.Results) { return 'No profiles' }
                $enabled = @($Parsed.Results | Where-Object { $_.KFM_Desktop -eq 'Enabled' -and $_.KFM_Documents -eq 'Enabled' -and $_.KFM_Pictures -eq 'Enabled' }).Count
                return "$enabled/$($Parsed.Results.Count) profiles fully KFM-enabled"
            }
            '*Test-OneDriveSyncStatus*' { return "$($Parsed.OverallVerdict) ($($Parsed.ProfilesChecked) profiles)" }
            '*Find-UnbackedData*' {
                $totalFindings = 0
                if ($Parsed.ProfileFindings) { $Parsed.ProfileFindings | ForEach-Object { $totalFindings += $_.FindingCount } }
                $appCount = if ($Parsed.NonStandardApps) { $Parsed.NonStandardApps.Count } else { 0 }
                if ($totalFindings -eq 0 -and $appCount -eq 0) { return 'Clean — nothing found' }
                return "$totalFindings item(s) at risk, $appCount non-std app(s)"
            }
            '*Get-DownloadsSize*' {
                if (-not $Parsed.Results) { return 'No profiles' }
                $totalBytes = ($Parsed.Results | Measure-Object -Property SizeBytes -Sum).Sum
                $totalFiles = ($Parsed.Results | Measure-Object -Property FileCount -Sum).Sum
                $sizeStr = if ($totalBytes -gt 1GB) { '{0:N1} GB' -f ($totalBytes / 1GB) } `
                           elseif ($totalBytes -gt 1MB) { '{0:N0} MB' -f ($totalBytes / 1MB) } `
                           else { '{0:N0} KB' -f ($totalBytes / 1KB) }
                $copied = @($Parsed.Results | Where-Object { $_.CopySuccess -eq $true }).Count
                return "$sizeStr across $($Parsed.Results.Count) user(s)  $copied/$($Parsed.Results.Count) copied"
            }
            '*Get-InstalledApplications*' { return "$($Parsed.TotalCount) apps ($($Parsed.MachineCount) machine, $($Parsed.UserCount) user)" }
            '*Get-StorageMode*' {
                $diskInfo = ''
                if ($Parsed.Disks -and $Parsed.Disks.Count -gt 0) {
                    $d = $Parsed.Disks[0]
                    $diskInfo = " ($($d.MediaType) {0:N0} GB)" -f $d.Size
                }
                return "$($Parsed.StorageMode)$diskInfo"
            }
            '*Backup-BrowserBookmarks*' {
                $backed = 0; $total = 0
                if ($Parsed.Results) {
                    $Parsed.Results | ForEach-Object {
                        if ($_.Browsers) { $_.Browsers | ForEach-Object { $total++; if ($_.BackedUp) { $backed++ } } }
                    }
                }
                return "$backed/$total browser profile(s) backed up"
            }
            '*Backup-DesktopBackground*' {
                if (-not $Parsed.Results) { return 'No profiles' }
                $ok = @($Parsed.Results | Where-Object { $_.Success -eq $true }).Count
                return "$ok/$($Parsed.Results.Count) wallpaper(s) backed up"
            }
            '*Backup-OutlookSignatures*' {
                if (-not $Parsed.Results) { return 'No profiles' }
                $found = @($Parsed.Results | Where-Object { $_.Found -eq $true }).Count
                $files = ($Parsed.Results | Measure-Object -Property FileCount -Sum).Sum
                return "$found user(s) with signatures, $files file(s) backed up"
            }
            '*Get-Printers*' {
                if (-not $Parsed.Printers -or $Parsed.Printers.Count -eq 0) { return 'No printers found' }
                $net   = @($Parsed.Printers | Where-Object { $_.Type -eq 'Network' }).Count
                $local = @($Parsed.Printers | Where-Object { $_.Type -eq 'Local'   }).Count
                return "$($Parsed.TotalPrinters) printer(s) ($net network, $local local)"
            }
            '*Get-AutopilotAssignment*' {
                if ($Parsed.Error) { return "Error: $($Parsed.Error)" }
                if ($Parsed.ProfileDownloaded) {
                    $s = 'Profile downloaded'
                    if ($Parsed.TenantDomain) { $s += " ($($Parsed.TenantDomain))" }
                    if ($Parsed.AssignedUser)  { $s += " — $($Parsed.AssignedUser)" }
                    return $s
                }
                return 'No Autopilot profile found locally'
            }
            '*Get-DriveMappings*' {
                if (-not $Parsed.Results) { return 'No drive mappings found' }
                $persistent = @($Parsed.Results | Where-Object { $_.Persistent }).Count
                return "$($Parsed.Results.Count) mapping(s) ($persistent persistent)"
            }
            '*Test-BitLockerEscrow*' {
                if ($null -eq $Parsed.AllEscrowed) { return 'Completed' }
                return if ($Parsed.AllEscrowed) { 'All drives escrowed to Entra ID' } else { 'Escrow failed on one or more drives' }
            }
            '*Test-WinRE*' {
                return if ($Parsed.WinREEnabled) { "WinRE enabled — $($Parsed.WinRELocation)" } else { 'WinRE NOT enabled' }
            }
            '*Test-AutopilotReadiness*' {
                if ($Parsed.OverallStatus) { return $Parsed.OverallStatus }
                return 'Completed'
            }
            default { return 'Completed' }
        }
    } catch { return 'Parse error' }
}

function Get-StepVerdict { # Evaluates step result (PASS/WARN/FAIL)
    param([PSCustomObject]$Parsed, [string]$ScriptFile, [string]$Status) # Parsed output, script path, execution status

    if ($Status -eq 'FAIL') { return @{ Verdict = 'FAIL'; Reason = 'Script execution failed' } } # Execution error = fail
    if ($Status -eq 'SKIP') { return @{ Verdict = 'WARN'; Reason = 'Step was skipped' } } # Skipped step = warn
    if ($null  -eq $Parsed) { return @{ Verdict = 'WARN'; Reason = 'No output to evaluate' } } # No output = warn

    try {
        switch -Wildcard ($ScriptFile) {
            '*Test-OneDriveKFM*' {
                if (-not $Parsed.Results -or $Parsed.Results.Count -eq 0) {
                    return @{ Verdict = 'WARN'; Reason = 'No profiles found to check' }
                }
                $allGood = $true; $primaryGood = $true
                foreach ($r in $Parsed.Results) {
                    if ($r.KFM_Desktop -ne 'Enabled' -or $r.KFM_Documents -ne 'Enabled' -or $r.KFM_Pictures -ne 'Enabled') {
                        $allGood = $false
                        if ($r.Profile -eq $script:PrimaryProfile) { $primaryGood = $false }
                    }
                }
                if ($allGood)          { return @{ Verdict = 'PASS'; Reason = 'All profiles KFM-enabled' } }
                if (-not $primaryGood) { return @{ Verdict = 'FAIL'; Reason = "Primary profile ($($script:PrimaryProfile)) missing KFM" } }
                return @{ Verdict = 'WARN'; Reason = 'Secondary profile(s) missing KFM' }
            }
            '*Test-OneDriveSyncStatus*' {
                if (-not $Parsed.Profiles -or $Parsed.Profiles.Count -eq 0) {
                    return @{ Verdict = 'WARN'; Reason = 'No profiles found to check' }
                }
                $allSafe = $true; $primarySafe = $true
                foreach ($p in $Parsed.Profiles) {
                    if (-not $p.SafeToWipe) {
                        $allSafe = $false
                        if ($p.Profile -eq $script:PrimaryProfile) { $primarySafe = $false }
                    }
                }
                if ($allSafe)          { return @{ Verdict = 'PASS'; Reason = 'All profiles synced and safe' } }
                if (-not $primarySafe) { return @{ Verdict = 'FAIL'; Reason = "Primary profile ($($script:PrimaryProfile)) not synced" } }
                return @{ Verdict = 'WARN'; Reason = 'Secondary profile(s) not synced' }
            }
            '*Find-UnbackedData*' {
                $criticalFail   = @('QuickBooks', 'QuickBooks_Bkp', 'Access_DB', 'Access_DB_Accdb', 'SQLite_DB', 'Generic_DB')
                $warnCategories = @('PST_Files', 'SSH_Keys', 'Cert_PFX', 'Cert_CER')
                $hasFail = $false; $hasWarn = $false
                if ($Parsed.ProfileFindings) {
                    foreach ($pf in $Parsed.ProfileFindings) {
                        if ($pf.Findings) {
                            foreach ($f in $pf.Findings) {
                                if ($criticalFail   -contains $f.Category) { $hasFail = $true }
                                if ($warnCategories -contains $f.Category) { $hasWarn = $true }
                            }
                        }
                    }
                }
                if ($hasFail) { return @{ Verdict = 'FAIL'; Reason = 'Database or QuickBooks files found outside OneDrive' } }
                if ($hasWarn) { return @{ Verdict = 'WARN'; Reason = 'PSTs, SSH keys, or certificates found outside OneDrive' } }
                return @{ Verdict = 'PASS'; Reason = 'No critical unbacked data found' }
            }
            '*Get-DownloadsSize*' {
                if (-not $Parsed.Results) { return @{ Verdict = 'PASS'; Reason = 'No profiles with Downloads' } }
                $anyFail = $false
                foreach ($r in $Parsed.Results) { if ($r.CopySuccess -eq $false) { $anyFail = $true } }
                if ($anyFail) { return @{ Verdict = 'FAIL'; Reason = 'Auto-copy failed for one or more profiles' } }
                return @{ Verdict = 'PASS'; Reason = 'Downloads backed up to Documents' }
            }
            '*Get-InstalledApplications*' { return @{ Verdict = 'PASS'; Reason = 'Informational' } }
            '*Get-StorageMode*' {
                if ($Parsed.StorageMode -match 'RAID|Intel RST|IntelRST') {
                    return @{ Verdict = 'WARN'; Reason = "Storage mode is $($Parsed.StorageMode) — may need AHCI conversion" }
                }
                return @{ Verdict = 'PASS'; Reason = "Storage mode: $($Parsed.StorageMode)" }
            }
            '*Backup-BrowserBookmarks*' {
                if (-not $Parsed.Results -or $Parsed.Results.Count -eq 0) {
                    return @{ Verdict = 'PASS'; Reason = 'No browser profiles found' }
                }
                $edgeSynced = $false; $allBackedUp = $true; $edgeBackedUp = $true; $anyBrowserFound = $false
                foreach ($userResult in $Parsed.Results) {
                    if (-not $userResult.Browsers) { continue }
                    foreach ($b in $userResult.Browsers) {
                        $anyBrowserFound = $true
                        $isEdge = ($b.Browser -match 'Edge')
                        if ($isEdge -and $b.SyncStatus -match 'Sync') { $edgeSynced = $true }
                        if (-not $b.BackedUp) {
                            $allBackedUp = $false
                            if ($isEdge) { $edgeBackedUp = $false }
                        }
                    }
                }
                if (-not $anyBrowserFound) { return @{ Verdict = 'PASS'; Reason = 'No browsers detected' } }
                $noProtection = $false
                foreach ($userResult in $Parsed.Results) {
                    if (-not $userResult.Browsers) { continue }
                    $userHasBackup = $false; $userHasSync = $false
                    foreach ($b in $userResult.Browsers) {
                        if ($b.BackedUp)                  { $userHasBackup = $true }
                        if ($b.SyncStatus -match 'Sync')  { $userHasSync   = $true }
                    }
                    if (-not $userHasBackup -and -not $userHasSync) { $noProtection = $true }
                }
                if ($noProtection)                       { return @{ Verdict = 'FAIL'; Reason = 'Profile(s) have no bookmark sync or backup' } }
                if ($edgeSynced -and $allBackedUp)       { return @{ Verdict = 'PASS'; Reason = 'Edge synced, all bookmarks backed up' } }
                if (-not $edgeSynced -and $allBackedUp)  { return @{ Verdict = 'WARN'; Reason = 'Edge not synced, but all bookmarks backed up' } }
                if ($edgeSynced -and -not $edgeBackedUp) { return @{ Verdict = 'WARN'; Reason = 'Edge synced but backup failed' } }
                return @{ Verdict = 'WARN'; Reason = 'Partial bookmark coverage' }
            }
            '*Backup-DesktopBackground*' {
                if (-not $Parsed.Results) { return @{ Verdict = 'PASS'; Reason = 'No profiles checked' } }
                $anyCustomFailed = $false
                foreach ($r in $Parsed.Results) {
                    if ($r.IsCustom -eq $true -and $r.Success -ne $true) { $anyCustomFailed = $true }
                }
                if ($anyCustomFailed) { return @{ Verdict = 'FAIL'; Reason = 'Custom wallpaper backup failed' } }
                return @{ Verdict = 'PASS'; Reason = 'Wallpapers backed up (or default)' }
            }
            '*Backup-OutlookSignatures*' {
                if (-not $Parsed.Results) { return @{ Verdict = 'PASS'; Reason = 'No profiles checked' } }
                $anyFoundNotBacked = $false
                foreach ($r in $Parsed.Results) {
                    if ($r.Found -eq $true -and $r.Success -ne $true) { $anyFoundNotBacked = $true }
                }
                if ($anyFoundNotBacked) { return @{ Verdict = 'FAIL'; Reason = 'Signature backup failed' } }
                return @{ Verdict = 'PASS'; Reason = 'Signatures backed up (or none found)' }
            }
            '*Get-Printers*'              { return @{ Verdict = 'PASS'; Reason = 'Informational' } }
            '*Get-DriveMappings*'         { return @{ Verdict = 'PASS'; Reason = 'Informational' } }
            '*Test-BitLockerEscrow*' {
                if ($Parsed.AllEscrowed -eq $true)  { return @{ Verdict = 'PASS'; Reason = 'All drives escrowed to Entra ID' } }
                if ($Parsed.AllEscrowed -eq $false) { return @{ Verdict = 'FAIL'; Reason = 'Escrow failed — BitLocker key not backed up' } }
                return @{ Verdict = 'WARN'; Reason = 'Escrow status unknown' }
            }
            '*Test-WinRE*' {
                if ($Parsed.WinREEnabled) { return @{ Verdict = 'PASS'; Reason = 'WinRE enabled' } }
                return @{ Verdict = 'WARN'; Reason = 'WinRE not enabled — run reagentc /enable' }
            }
            '*Test-AutopilotReadiness*' {
                if ($Parsed.OverallStatus -eq 'READY')     { return @{ Verdict = 'PASS'; Reason = 'Device meets Autopilot hardware requirements' } }
                if ($Parsed.OverallStatus -eq 'NOT READY') { return @{ Verdict = 'FAIL'; Reason = 'Device does not meet Autopilot hardware requirements' } }
                return @{ Verdict = 'WARN'; Reason = 'Autopilot readiness status unknown' }
            }
            '*Get-AutopilotAssignment*' {
                if ($Parsed.ProfileDownloaded) { return @{ Verdict = 'PASS'; Reason = 'Autopilot profile downloaded locally' } }
                return @{ Verdict = 'FAIL'; Reason = 'No Autopilot profile found on device' }
            }
            '*Get-TeamsData*'               { return @{ Verdict = 'PASS'; Reason = 'Informational' } }
            '*Get-CredentialManagerEntries*'{ return @{ Verdict = 'PASS'; Reason = 'Informational' } }
            '*Get-LocalAccounts*'           { return @{ Verdict = 'PASS'; Reason = 'Informational' } }
            '*Register-AutopilotDevice*' {
                if ($Parsed.Success -eq $true) { return @{ Verdict = 'PASS'; Reason = "Device registered (upload: $($Parsed.UploadStatus))" } }
                if ($Parsed.UploadStatus -eq 'UploadFailed') { return @{ Verdict = 'FAIL'; Reason = "Autopilot upload failed: $($Parsed.Error)" } }
                if ($Parsed.UploadStatus -eq 'HashCollected') { return @{ Verdict = 'WARN'; Reason = 'Hash collected but not uploaded' } }
                return @{ Verdict = 'FAIL'; Reason = 'Registration did not complete successfully' }
            }
            default                         { return @{ Verdict = 'PASS'; Reason = 'Completed' } }
        }
    } catch { return @{ Verdict = 'WARN'; Reason = "Evaluation error: $_" } }
}

#endregion

#region --- HTML Report ---

function Get-HtmlTable { # Extracts data table from step output
    param($Parsed, [string]$ScriptFile) # Parsed JSON and script path
    if ($null -eq $Parsed) { return '' } # Return empty if no parsed data
    $rows = @(); $cols = @() # Initialize rows and column headers
    try {
        switch -Wildcard ($ScriptFile) { # Match script type and extract table
            '*Test-OneDriveKFM*' {
                if ($Parsed.Results) { $cols = @('Profile','KFM_Desktop','KFM_Documents','KFM_Pictures','SyncStatus'); $rows = @($Parsed.Results) }
            }
            '*Test-OneDriveSyncStatus*' {
                if ($Parsed.Profiles) {
                    $cols = @('Profile','OverallStatus','SafeToWipe')
                    $rows = @($Parsed.Profiles | ForEach-Object { [PSCustomObject]@{ Profile = $_.Profile; OverallStatus = $_.OverallStatus; SafeToWipe = $_.SafeToWipe } })
                }
            }
            '*Find-UnbackedData*' {
                if ($Parsed.ProfileFindings) {
                    $cols = @('Profile','Category','Path')
                    $rows = @($Parsed.ProfileFindings | ForEach-Object {
                        $p = $_.Profile
                        if ($_.Findings) { $_.Findings | ForEach-Object { [PSCustomObject]@{ Profile = $p; Category = $_.Category; Path = $_.Path } } }
                    })
                }
            }
            '*Get-DownloadsSize*' {
                if ($Parsed.Results) {
                    $cols = @('Profile','SizeHuman','FileCount','CopyStatus')
                    $rows = @($Parsed.Results | ForEach-Object {
                        [PSCustomObject]@{
                            Profile    = $_.Profile
                            SizeHuman  = $_.SizeHuman
                            FileCount  = $_.FileCount
                            CopyStatus = if ($_.CopySuccess -eq $true) { "Copied ($($_.CopiedFiles) new)" } elseif ($_.CopySuccess -eq $false) { 'FAILED' } else { 'N/A' }
                        }
                    })
                }
            }
            '*Get-InstalledApplications*' {
                if ($Parsed.Applications) { $cols = @('DisplayName','DisplayVersion','Publisher','Scope'); $rows = @($Parsed.Applications | Select-Object -First 10) }
            }
            '*Get-StorageMode*' {
                if ($Parsed.Disks) { $cols = @('Model','MediaType','InterfaceType'); $rows = @($Parsed.Disks) }
            }
            '*Backup-BrowserBookmarks*' {
                if ($Parsed.Results) {
                    $cols = @('Profile','Browser','Sync','BackedUp')
                    $rows = @($Parsed.Results | ForEach-Object {
                        $u = $_.UserProfile
                        if ($_.Browsers) { $_.Browsers | ForEach-Object { [PSCustomObject]@{ Profile = $u; Browser = $_.Browser; Sync = $_.SyncStatus; BackedUp = $_.BackedUp } } }
                    })
                }
            }
            '*Backup-DesktopBackground*'  { if ($Parsed.Results) { $cols = @('Profile','IsCustom','Success','SkipReason'); $rows = @($Parsed.Results) } }
            '*Backup-OutlookSignatures*'   { if ($Parsed.Results) { $cols = @('Profile','Found','FileCount','Success'); $rows = @($Parsed.Results) } }
            '*Get-Printers*'               { if ($Parsed.Printers) { $cols = @('Name','Type','PortName','DriverName','IsDefault'); $rows = @($Parsed.Printers) } }
            '*Get-DriveMappings*'          { if ($Parsed.Results)  { $cols = @('DriveLetter','UNCPath','Persistent','Profile'); $rows = @($Parsed.Results) } }
            '*Get-AutopilotAssignment*' {
                $cols = @('Serial','Downloaded','Tenant','AzureAD','Profile','User')
                $rows = @([PSCustomObject]@{
                    Serial     = $Parsed.SerialNumber
                    Downloaded = if ($Parsed.ProfileDownloaded) { 'YES' } else { 'NO' }
                    Tenant     = if ($Parsed.TenantDomain) { $Parsed.TenantDomain } else { '(unknown)' }
                    AzureAD    = if ($Parsed.AzureADJoined) { 'Joined' } else { 'No' }
                    Profile    = if ($Parsed.ProfileName) { $Parsed.ProfileName } else { '(none)' }
                    User       = if ($Parsed.AssignedUser) { $Parsed.AssignedUser } else { '(none)' }
                })
            }
        }
    } catch { return '' }
    if ($rows.Count -eq 0 -or $cols.Count -eq 0) { return '' }

    $html = [System.Text.StringBuilder]::new()
    $null = $html.AppendLine('<table>')
    $null = $html.Append('<tr>')
    foreach ($c in $cols) { $null = $html.Append("<th>$([System.Web.HttpUtility]::HtmlEncode($c))</th>") }
    $null = $html.AppendLine('</tr>')
    $limit = [Math]::Min($rows.Count, 15)
    for ($i = 0; $i -lt $limit; $i++) {
        $null = $html.Append('<tr>')
        foreach ($c in $cols) {
            $val = $rows[$i].$c
            if ($null -eq $val) { $val = '' }
            $null = $html.Append("<td>$([System.Web.HttpUtility]::HtmlEncode([string]$val))</td>")
        }
        $null = $html.AppendLine('</tr>')
    }
    if ($rows.Count -gt 15) {
        $null = $html.AppendLine("<tr><td colspan='$($cols.Count)' style='color:var(--muted);font-style:italic'>… and $($rows.Count - 15) more rows</td></tr>")
    }
    $null = $html.AppendLine('</table>')
    return $html.ToString()
}

function Export-HtmlReport { # Generates styled HTML report from results
    param([PSCustomObject[]]$ResultSet, [string]$RunLabel = 'Run') # Result set and run label

    $stamp    = Get-Date -Format 'yyyyMMdd-HHmmss' # Timestamp for filename
    $htmlPath = Join-Path $OutputRoot "PreWipeReport_$($script:ComputerName)_$stamp.html" # Output file path
    $now      = Get-Date -Format 'yyyy-MM-dd HH:mm:ss' # Current timestamp

    $done  = @($ResultSet | Where-Object { $_.Status -eq 'DONE' }).Count
    $fail  = @($ResultSet | Where-Object { $_.Status -eq 'FAIL' }).Count
    $skip  = @($ResultSet | Where-Object { $_.Status -eq 'SKIP' }).Count

    $failV = @($ResultSet | Where-Object { $_.Verdict -eq 'FAIL' })
    $warnV = @($ResultSet | Where-Object { $_.Verdict -eq 'WARN' })

    $readinessClass = if ($failV.Count -eq 0 -and $warnV.Count -eq 0) { 'ready' } elseif ($failV.Count -eq 0) { 'warnings' } else { 'not-ready' }
    $readinessText  = if ($failV.Count -eq 0 -and $warnV.Count -eq 0) { '&#10003; Ready to Wipe' } `
                      elseif ($failV.Count -eq 0) { "&#9888; Ready to Wipe &mdash; $($warnV.Count) warning(s)" } `
                      else { "&#10007; Not Ready &mdash; $($failV.Count) issue(s) to resolve" }

    $sb = [System.Text.StringBuilder]::new()
    $null = $sb.AppendLine(@'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Pre-Wipe Report</title>
<style>
  :root{--pass:#22c55e;--fail:#ef4444;--skip:#eab308;--bg:#f8fafc;--card:#fff;--border:#e2e8f0;--text:#1e293b;--muted:#64748b}
  *{margin:0;padding:0;box-sizing:border-box}
  body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;background:var(--bg);color:var(--text);line-height:1.5}
  .header{background:#0f172a;color:#fff;padding:24px 32px}
  .header h1{font-size:1.5rem;font-weight:600}
  .header .sub{color:#94a3b8;font-size:.875rem;margin-top:4px}
  .device-info{display:flex;gap:32px;margin-top:12px;font-size:.8125rem;color:#cbd5e1}
  .container{max-width:900px;margin:0 auto;padding:24px 16px}
  .badges{display:flex;gap:12px;margin-bottom:24px}
  .badge{padding:8px 20px;border-radius:8px;font-weight:600;font-size:.875rem;color:#fff}
  .badge.pass{background:var(--pass)}.badge.fail{background:var(--fail)}.badge.skip{background:var(--skip);color:#422006}.badge.total{background:#334155}
  .card{background:var(--card);border:1px solid var(--border);border-radius:8px;margin-bottom:12px;overflow:hidden}
  .card-head{display:flex;justify-content:space-between;align-items:center;padding:12px 16px;border-bottom:1px solid var(--border)}
  .card-head .step-name{font-weight:600;font-size:.9375rem}
  .status{padding:2px 10px;border-radius:4px;font-size:.75rem;font-weight:700;color:#fff;text-transform:uppercase}
  .status.done{background:var(--pass)}.status.fail{background:var(--fail)}.status.skip{background:var(--skip);color:#422006}
  .verdict{padding:2px 10px;border-radius:4px;font-size:.75rem;font-weight:700;color:#fff;text-transform:uppercase;margin-left:6px}
  .verdict.pass{background:var(--pass)}.verdict.warn{background:var(--skip);color:#422006}.verdict.fail{background:var(--fail)}
  .card-body{padding:12px 16px}.card-body .summary{color:var(--muted);font-size:.875rem}
  .card-body table{width:100%;border-collapse:collapse;margin-top:8px;font-size:.8125rem}
  .card-body th{text-align:left;padding:4px 8px;border-bottom:2px solid var(--border);color:var(--muted);font-weight:600}
  .card-body td{padding:4px 8px;border-bottom:1px solid var(--border)}
  .readiness{padding:12px 20px;border-radius:8px;font-weight:600;font-size:.9375rem;margin-bottom:24px;text-align:center}
  .readiness.ready{background:#dcfce7;color:#166534;border:1px solid #86efac}
  .readiness.warnings{background:#fef9c3;color:#854d0e;border:1px solid #fde047}
  .readiness.not-ready{background:#fee2e2;color:#991b1b;border:1px solid #fca5a5}
  .footer{text-align:center;color:var(--muted);font-size:.75rem;padding:16px;margin-top:24px}
</style>
</head>
<body>
'@)
    $null = $sb.AppendLine("<div class='header'><h1>Pre-Wipe Report</h1><div class='sub'>AshesToAutopilot &middot; $([System.Web.HttpUtility]::HtmlEncode($RunLabel))</div>")
    $null = $sb.AppendLine("<div class='device-info'><span><strong>PC:</strong> $([System.Web.HttpUtility]::HtmlEncode($script:ComputerName))</span><span><strong>SN:</strong> $([System.Web.HttpUtility]::HtmlEncode($script:SerialNumber))</span><span><strong>User:</strong> $([System.Web.HttpUtility]::HtmlEncode($script:CurrentUser))</span><span><strong>Date:</strong> $now</span></div></div>")
    $null = $sb.AppendLine("<div class='container'>")
    $null = $sb.AppendLine("<div class='badges'><div class='badge pass'>DONE: $done</div><div class='badge fail'>FAIL: $fail</div><div class='badge skip'>SKIP: $skip</div><div class='badge total'>Total: $($ResultSet.Count)</div></div>")
    $null = $sb.AppendLine("<div class='readiness $readinessClass'>$readinessText")
    if ($failV.Count -gt 0) {
        $null = $sb.AppendLine("<div style='margin-top:6px;font-size:.8125rem;font-weight:400'>")
        foreach ($fv in $failV) {
            $null = $sb.AppendLine("$([System.Web.HttpUtility]::HtmlEncode($fv.DisplayName)): $([System.Web.HttpUtility]::HtmlEncode($fv.VerdictReason))<br/>")
        }
        $null = $sb.AppendLine('</div>')
    }
    $null = $sb.AppendLine('</div>')

    foreach ($r in $ResultSet) {
        $sc   = switch ($r.Status)  { 'DONE' { 'done' } 'FAIL' { 'fail' } 'SKIP' { 'skip' } default { 'skip' } }
        $vc   = switch ($r.Verdict) { 'PASS' { 'pass' } 'WARN' { 'warn' } 'FAIL' { 'fail' } default { 'pass' } }
        $vl   = switch ($r.Verdict) { 'PASS' { '&#10003; Pass' } 'WARN' { '&#9888; Warn' } 'FAIL' { '&#10007; Fail' } default { '' } }
        $vrCol= switch ($r.Verdict) { 'PASS' { 'var(--pass)' } 'WARN' { '#b45309' } 'FAIL' { 'var(--fail)' } default { 'var(--text)' } }

        $null = $sb.AppendLine("<div class='card'><div class='card-head'><span class='step-name'>$($r.Index). $([System.Web.HttpUtility]::HtmlEncode($r.DisplayName))</span>")
        $null = $sb.AppendLine("<span><span class='status $sc'>$($r.Status)</span><span class='verdict $vc' title='$([System.Web.HttpUtility]::HtmlEncode($r.VerdictReason))'>$vl</span></span></div>")
        $null = $sb.AppendLine("<div class='card-body'><div class='summary'>$([System.Web.HttpUtility]::HtmlEncode($r.Summary))</div>")
        if ($r.VerdictReason) {
            $null = $sb.AppendLine("<div class='summary' style='margin-top:4px;font-weight:600;color:$vrCol'>$([System.Web.HttpUtility]::HtmlEncode($r.VerdictReason))</div>")
        }
        $tableHtml = Get-HtmlTable -Parsed $r.ParsedData -ScriptFile $r.ScriptPath
        if ($tableHtml) { $null = $sb.AppendLine($tableHtml) }
        $null = $sb.AppendLine('</div></div>')
    }

    $null = $sb.AppendLine("<div class='footer'>Generated $now by Start-PreWipeToolkit.ps1</div>")
    $null = $sb.AppendLine('</div></body></html>')

    try {
        $sb.ToString() | Set-Content $htmlPath -Encoding UTF8 -Force
        Write-Log "HTML report: $htmlPath"
        Write-Host "  HTML report: $htmlPath" -ForegroundColor Cyan
    } catch {
        Write-ErrorLog "Failed to save HTML report: $_"
    }
    return $htmlPath
}

#endregion

#region --- Step Execution ---

function Invoke-StepCapture { # Executes step and captures output
    param([PSCustomObject]$Step) # Step object to execute

    $fullPath = Join-Path $PSScriptRoot $Step.ScriptPath # Resolve full script path

    if (-not (Test-Path $fullPath)) {
        Write-Log "Script not found, skipping: $($Step.ScriptPath)" -Level 'WARN' # Log missing script
        return @{ Status = 'SKIP'; Parsed = $null; Summary = 'Script not found'; Elapsed = $null; Verdict = 'WARN'; VerdictReason = 'Step was skipped — script missing' } # Return skip
    }

    $LASTEXITCODE = 0 # Reset exit code
    $exitCode = 0 # Initialize exit code
    $parsed   = $null # Initialize parsed output

    $sw = [System.Diagnostics.Stopwatch]::StartNew() # Start timer
    try {
        $jsonRaw  = & $fullPath -NonInteractive 2>&1 | Out-String # Execute script and capture output
        $exitCode = if ($null -ne $LASTEXITCODE) { $LASTEXITCODE } else { 0 } # Capture exit code
    } catch {
        $sw.Stop() # Stop timer
        Write-ErrorLog "Step $($Step.Index) ($($Step.DisplayName)) threw: $_" # Log exception
        return @{ Status = 'FAIL'; Parsed = $null; Summary = "Error: $_"; Elapsed = $sw.Elapsed; Verdict = 'FAIL'; VerdictReason = 'Script execution failed' } # Return failure
    }
    $sw.Stop() # Stop timer

    try {
        if ($jsonRaw.Trim()) { $parsed = $jsonRaw | ConvertFrom-Json } # Parse JSON output
    } catch {
        Write-Log "Could not parse JSON from $($Step.DisplayName)" -Level 'WARN' # Log parse error
    }

    $status  = if ($exitCode -eq 0) { 'DONE' } else { 'FAIL' }
    $summary = Get-StepSummary -Parsed $parsed -ScriptFile $Step.ScriptPath
    $verdict = Get-StepVerdict -Parsed $parsed -ScriptFile $Step.ScriptPath -Status $status

    Write-Log "Step $($Step.Index) ($($Step.DisplayName)): $status — $summary"

    return @{
        Status        = $status
        Parsed        = $parsed
        Summary       = $summary
        Elapsed       = $sw.Elapsed
        Verdict       = $verdict.Verdict
        VerdictReason = $verdict.Reason
    }
}

function Invoke-StepInteractive { # Runs step interactively with output
    param([PSCustomObject]$Step) # Step to execute

    $fullPath = Join-Path $PSScriptRoot $Step.ScriptPath # Resolve full path
    Clear-Host # Clear screen
    Write-Banner # Display banner

    $inner = 62; $bar = '═' * ($inner + 2)
    Write-Host "  ╔$bar╗" -ForegroundColor Cyan
    Write-Host ("  ║ {0} ║" -f "  Step $($Step.Index) — $($Step.DisplayName)".PadRight($inner)) -ForegroundColor White
    Write-Host ("  ║ {0} ║" -f "  $(Get-PhaseLabel $Step.Phase)  ·  $($Step.ScriptPath)".PadRight($inner)) -ForegroundColor DarkGray
    Write-Host "  ╚$bar╝" -ForegroundColor Cyan
    Write-Host ''

    if (-not (Test-Path $fullPath)) {
        Write-Host "  [SKIP] Script not found: $($Step.ScriptPath)" -ForegroundColor Yellow
        $Step.Status = 'SKIP'
        Update-SessionStep -Index $Step.Index -Status 'SKIP' -ExitCode $null
        Save-Session
        Write-Host ''
        Write-Host '  Press any key to return to menu...' -ForegroundColor DarkGray
        $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
        return
    }

    Write-Host "  $('─' * 62)" -ForegroundColor DarkGray
    Write-Host ''

    $LASTEXITCODE = 0
    $exitCode = 0
    try {
        & $fullPath
        $exitCode = if ($null -ne $LASTEXITCODE) { $LASTEXITCODE } else { 0 }
    } catch {
        Write-Host ''
        Write-Host "  [FAIL] Unhandled error: $_" -ForegroundColor Red
        Write-ErrorLog "Step $($Step.Index) ($($Step.DisplayName)) threw: $_"
        $exitCode = -1
    }

    Write-Host ''
    Write-Host "  $('─' * 62)" -ForegroundColor DarkGray
    Write-Host ''

    if ($exitCode -eq 0) {
        $Step.Status = 'DONE'
        Write-Host '  [DONE] Completed.' -ForegroundColor White
    } else {
        $Step.Status = 'FAIL'
        Write-Host "  [FAIL] Exited with code $exitCode — review output above." -ForegroundColor Red
    }

    Update-SessionStep -Index $Step.Index -Status $Step.Status -ExitCode $exitCode
    Save-Session

    Write-Host ''
    Write-Host '  Press any key to return to menu...' -ForegroundColor DarkGray
    $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
}

#endregion

#region --- Run Engine ---

function Invoke-RunSteps { # Executes batch of steps and collects results
    param(
        [PSCustomObject[]]$StepsToRun, # Steps to execute
        [string]$RunLabel, # Run mode label (e.g., 'Quick Check')
        [string]$RunSub # Subtitle description
    )

    $total      = $StepsToRun.Count # Total steps in run
    $counts     = @{ DONE = 0; FAIL = 0; SKIP = 0 } # Result counters
    $runResults = [System.Collections.Generic.List[PSCustomObject]]::new() # Collect all results

    Write-RunHeader -Title $RunLabel -Sub $RunSub -StepCount $total

    $i = 0 # Step counter
    foreach ($step in $StepsToRun) {
        $i++ # Increment counter
        Write-StepLine -Num $i -Total $total -Step $step # Display step header

        $result = Invoke-StepCapture -Step $step # Execute step and capture output

        $step.Status = $result.Status # Update step status
        Update-SessionStep -Index $step.Index -Status $step.Status -ExitCode ($result.Status -eq 'DONE' ? 0 : 1) # Update session
        Save-Session # Persist session state

        switch ($step.Status) {
            'DONE' { $counts.DONE++ }
            'FAIL' { $counts.FAIL++ }
            'SKIP' { $counts.SKIP++ }
        }

        Write-StepResultLine -Result $result

        $runResults.Add([PSCustomObject]@{
            Index         = $step.Index
            Phase         = $step.Phase
            DisplayName   = $step.DisplayName
            ScriptPath    = $step.ScriptPath
            Status        = $result.Status
            Summary       = $result.Summary
            ParsedData    = $result.Parsed
            Elapsed       = $result.Elapsed
            Verdict       = $result.Verdict
            VerdictReason = $result.VerdictReason
        })

        if ($i -lt $total) { Start-Sleep -Seconds 2 }
    }

    $resultArray = $runResults.ToArray() # Convert to array
    Show-RunSummaryInline -Results $resultArray # Display inline summary
    $null = Export-HtmlReport -ResultSet $resultArray -RunLabel $RunLabel # Generate HTML report

    Write-Host '' # Blank line
    Write-Host '  Press any key to return to menu...' -ForegroundColor DarkGray
    $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') # Wait for keypress

    return $resultArray # Return results
}

#endregion

#region --- Workflow Actions ---

function Invoke-QuickCheck { # Runs 12 core steps
    $stepsToRun = @($script:QuickCheckIndices | ForEach-Object { # Resolve step objects
        $idx = $_ # Get index
        $script:Steps | Where-Object { $_.Index -eq $idx } | Select-Object -First 1 # Find step
    } | Where-Object { $_ }) # Filter valid

    Write-Host ''
    Write-Host '  Quick Check will run the following 12 steps:' -ForegroundColor Cyan
    foreach ($s in $stepsToRun) {
        Write-Host "    [$($s.Index.ToString().PadLeft(2))]  $($s.DisplayName)" -ForegroundColor Gray
    }
    Write-Host ''
    Write-Host '  [Y] Start    [N] Cancel  ' -ForegroundColor DarkCyan -NoNewline
    $key = Read-MenuKey
    Write-Host ''
    if ($key -ne 'Y') { return }

    $null = Invoke-RunSteps -StepsToRun $stepsToRun -RunLabel 'Quick Check' -RunSub 'Core scan, check & backup'
}

function Invoke-FullPrep {
    Write-Host ''
    Write-Host "  Full Prep runs all $($script:Steps.Count) steps in sequence." -ForegroundColor Cyan
    Write-Host '  This may take 30+ minutes and some steps will modify settings.' -ForegroundColor Yellow
    Write-Host ''
    Write-Host '  [Y] Start    [N] Cancel  ' -ForegroundColor DarkCyan -NoNewline
    $key = Read-MenuKey
    Write-Host ''
    if ($key -ne 'Y') { return }

    $null = Invoke-RunSteps -StepsToRun $script:Steps -RunLabel 'Full Prep' -RunSub 'All 31 steps in sequence'
}

function Invoke-SingleStep { # Menu to run one step interactively
    while ($true) {
        Clear-Host # Clear screen
        Write-Banner # Show banner
        Show-StepListTable -Title 'RUN SINGLE STEP — SELECT BY NUMBER' # Display all steps

        Write-Host '  Enter step number (0 to cancel): ' -ForegroundColor DarkCyan -NoNewline
        $input = Read-Host # Get user input
        if ($input -eq '0' -or $input -eq '') { return }

        $num = 0
        if ([int]::TryParse($input.Trim(), [ref]$num)) {
            $step = $script:Steps | Where-Object { $_.Index -eq $num } | Select-Object -First 1
            if ($step) {
                Invoke-StepInteractive -Step $step
                return
            }
        }
        Write-Host '  Invalid step number. Try again.' -ForegroundColor Yellow
        Start-Sleep -Seconds 1
    }
}

function Invoke-CustomRun { # Menu to select custom step subset
    Clear-Host # Clear screen
    Write-Banner # Show banner
    Show-StepListTable -Title 'CUSTOM RUN — SELECT STEPS' # Display all steps

    Write-Host '' # Blank line
    Write-Host '  Enter step numbers separated by commas (e.g. 1,3,11,12)' -ForegroundColor Gray
    Write-Host '  Enter 0 or leave blank to cancel.' -ForegroundColor DarkGray
    Write-Host '' # Blank line
    Write-Host '  Steps: ' -ForegroundColor DarkCyan -NoNewline
    $input = Read-Host # Get user input

    if ($input -eq '0' -or $input -eq '') { return }

    $indices = $input -split '[,\s]+' | ForEach-Object {
        $n = 0
        if ([int]::TryParse($_.Trim(), [ref]$n)) { $n }
    } | Where-Object { $_ -gt 0 } | Select-Object -Unique | Sort-Object

    if (-not $indices) {
        Write-Host '  No valid step numbers entered.' -ForegroundColor Yellow
        Start-Sleep -Seconds 2
        return
    }

    $stepsToRun = @($indices | ForEach-Object {
        $idx = $_
        $script:Steps | Where-Object { $_.Index -eq $idx } | Select-Object -First 1
    } | Where-Object { $_ })

    if (-not $stepsToRun) {
        Write-Host '  No matching steps found.' -ForegroundColor Yellow
        Start-Sleep -Seconds 2
        return
    }

    Write-Host ''
    Write-Host "  Running $($stepsToRun.Count) selected step(s): $($stepsToRun.DisplayName -join ', ')" -ForegroundColor Cyan
    Write-Host '  [Y] Confirm    [N] Cancel  ' -ForegroundColor DarkCyan -NoNewline
    $key = Read-MenuKey
    Write-Host ''
    if ($key -ne 'Y') { return }

    $null = Invoke-RunSteps -StepsToRun $stepsToRun -RunLabel 'Custom Run' -RunSub "Steps: $($indices -join ', ')"
}

function Show-SessionSummary { # Displays session progress overview
    Clear-Host # Clear screen
    Write-Banner # Show banner

    $done  = @($script:Steps | Where-Object { $_.Status -eq 'DONE' }).Count # Count completed
    $fail  = @($script:Steps | Where-Object { $_.Status -eq 'FAIL' }).Count # Count failed
    $skip  = @($script:Steps | Where-Object { $_.Status -eq 'SKIP' }).Count # Count skipped
    $norun = @($script:Steps | Where-Object { $_.Status -eq 'not-run' }).Count # Count not-run

    $progBar = Get-ProgressBarString -Done $done -Total $script:Steps.Count -Width 32

    Write-Host "  $('═' * 66)" -ForegroundColor Cyan
    Write-Host '  SESSION SUMMARY' -ForegroundColor White
    Write-Host "  $('═' * 66)" -ForegroundColor Cyan
    Write-Host ''
    Write-Host "  $progBar  $done/$($script:Steps.Count) complete" -ForegroundColor Cyan
    Write-Host ''
    Write-Host "  Started : $($script:Session.StartTime)" -ForegroundColor DarkGray
    Write-Host "  PC      : $($script:ComputerName)  ·  SN: $($script:SerialNumber)" -ForegroundColor DarkGray
    Write-Host ''

    $lastPhase = ''
    foreach ($step in $script:Steps) {
        if ($step.Phase -ne $lastPhase) {
            $lastPhase = $step.Phase
            Write-Host "   ── $(Get-PhaseLabel $lastPhase) ──" -ForegroundColor DarkGray
        }
        $badge  = switch ($step.Status) { 'DONE' { '[DONE]' } 'FAIL' { '[FAIL]' } 'SKIP' { '[SKIP]' } default { '[    ]' } }
        $bColor = switch ($step.Status) { 'DONE' { 'Green' } 'FAIL' { 'Red' } 'SKIP' { 'Yellow' } default { 'DarkGray' } }
        $num    = $step.Index.ToString().PadLeft(2)
        Write-Host -NoNewline "   $num  " -ForegroundColor DarkGray
        Write-Host -NoNewline $badge      -ForegroundColor $bColor
        Write-Host "  $($step.DisplayName)" -ForegroundColor Gray
    }

    Write-Host ''
    Write-Host "  $('─' * 66)" -ForegroundColor DarkGray
    Write-Host -NoNewline "  "
    Write-Host -NoNewline " DONE: $done"   -ForegroundColor Green
    Write-Host -NoNewline "   FAIL: "      -ForegroundColor Gray
    Write-Host -NoNewline "$fail"          -ForegroundColor $(if ($fail -gt 0) { 'Red' } else { 'Gray' })
    Write-Host -NoNewline "   SKIP: "      -ForegroundColor Gray
    Write-Host -NoNewline "$skip"          -ForegroundColor $(if ($skip -gt 0) { 'Yellow' } else { 'Gray' })
    Write-Host "   Not Run: $norun"        -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  Press any key to return...' -ForegroundColor DarkGray
    $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
}

function Export-SessionReport { # Exports session as JSON and text
    Clear-Host # Clear screen
    Write-Host '' # Blank line
    Write-Host '  Exporting Session Report...' -ForegroundColor Cyan
    Write-Host '' # Blank line

    $stamp    = Get-Date -Format 'yyyyMMdd-HHmmss' # Timestamp for filename
    $baseName = "PreWipeReport_$($script:ComputerName)_$stamp" # Base filename
    $jsonPath = Join-Path $OutputRoot "$baseName.json" # JSON file path
    $txtPath  = Join-Path $OutputRoot "$baseName.txt" # Text file path

    try {
        $script:Session | ConvertTo-Json -Depth 5 | Set-Content $jsonPath -Encoding UTF8 -Force
        Write-Host "  JSON : $jsonPath" -ForegroundColor Green
    } catch {
        Write-ErrorLog "JSON export failed: $_"
        Write-Host "  JSON export failed: $_" -ForegroundColor Red
    }

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
        $done  = @($script:Steps | Where-Object { $_.Status -eq 'DONE' }).Count
        $fail  = @($script:Steps | Where-Object { $_.Status -eq 'FAIL' }).Count
        $skip  = @($script:Steps | Where-Object { $_.Status -eq 'SKIP' }).Count
        $norun = @($script:Steps | Where-Object { $_.Status -eq 'not-run' }).Count
        $lines.Add('--- Summary ---')
        $lines.Add("  Done    : $done")
        $lines.Add("  Failed  : $fail")
        $lines.Add("  Skipped : $skip")
        $lines.Add("  Not Run : $norun")
        $lines | Set-Content $txtPath -Encoding UTF8 -Force
        Write-Host "  TXT  : $txtPath" -ForegroundColor Green
    } catch {
        Write-ErrorLog "TXT export failed: $_"
        Write-Host "  TXT export failed: $_" -ForegroundColor Red
    }

    Write-Host ''
    Write-Host '  Press any key to return...' -ForegroundColor DarkGray
    $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
}

function Invoke-ResetSession { # Clears all progress and deletes session file
    Clear-Host # Clear screen
    Write-Host '' # Blank line
    Write-Host '  Reset Session' -ForegroundColor White
    Write-Host '  This clears all step statuses and deletes session.json.' -ForegroundColor Gray
    Write-Host '' # Blank line
    Write-Host '  [Y] Reset    [N] Cancel  ' -ForegroundColor DarkCyan -NoNewline
    $key = Read-MenuKey # Get confirmation
    Write-Host '' # Blank line
    if ($key -ne 'Y') { return } # Cancel if not confirmed

    foreach ($step in $script:Steps) { $step.Status = 'not-run' } # Reset all steps
    $script:Session = Initialize-Session # Create new session
    if (Test-Path $SessionFile) { Remove-Item $SessionFile -Force } # Delete session file

    Write-Host ''
    Write-Host '  Session reset. All steps marked as not-run.' -ForegroundColor Green
    Start-Sleep -Seconds 2
}

#endregion

#region --- Main Loop ---

$script:Session = Import-Session # Load or create session

if ($NonInteractive) { # Non-interactive JSON output mode
    [PSCustomObject]@{ # Build output object
        Timestamp     = (Get-Date -Format 'o') # Current time
        ScriptName    = $ScriptName
        ComputerName  = $script:ComputerName
        SerialNumber  = $script:SerialNumber
        CurrentUser   = $script:CurrentUser
        SessionFile   = $SessionFile
        SessionExists = (Test-Path $SessionFile) # Check if session file exists
        Steps         = $script:Steps | Select-Object Index, Phase, DisplayName, Status, ScriptPath
        Summary       = [PSCustomObject]@{ # Result counters
            Total   = $script:Steps.Count
            Done    = @($script:Steps | Where-Object { $_.Status -eq 'DONE' }).Count
            Failed  = @($script:Steps | Where-Object { $_.Status -eq 'FAIL' }).Count
            Skipped = @($script:Steps | Where-Object { $_.Status -eq 'SKIP' }).Count
            NotRun  = @($script:Steps | Where-Object { $_.Status -eq 'not-run' }).Count
        }
    } | ConvertTo-Json -Depth 5 # Output JSON and exit
    exit 0
}

try {
    $running = $true # Main loop flag
    while ($running) { # Main interactive loop
        Show-MainMenu # Display menu
        $key = Read-MenuKey # Get user key
        Write-Host $key -ForegroundColor White # Echo key
        Start-Sleep -Milliseconds 120 # Brief delay

        switch ($key) { # Route key press to action
            '1' { Invoke-QuickCheck } # Run quick check
            '2' { Invoke-FullPrep } # Run full prep
            '3' { Invoke-SingleStep } # Run single step
            '4' { Invoke-CustomRun } # Run custom selection
            '5' { Show-SessionSummary } # Show progress
            '6' { Export-SessionReport } # Export session
            '7' { Invoke-ResetSession } # Reset progress
            'Q' { $running = $false } # Quit
        }
    }
} catch {
    Write-ErrorLog "Unhandled exception in main loop: $_" # Log fatal error
    Write-Host "  FATAL: Unexpected error — check $ErrorLog" -ForegroundColor Red
    exit 1
}

Clear-Host # Clear screen
Write-Banner # Display banner
Write-Host '  Session ended. Output saved to C:\PreWipeOutput' -ForegroundColor DarkCyan # Farewell message
Write-Host '' # Blank line

#endregion
