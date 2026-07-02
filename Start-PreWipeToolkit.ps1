<#
.SYNOPSIS
    Unified interactive orchestrator for the Pre-Wipe Toolkit.

.DESCRIPTION
    Menu-driven workflow that guides a tech through all 27 pre-wipe preparation
    steps. Numbered single-key menus; no external module dependencies.

    Modes:
    - Quick Check  : 12 core steps (fast scan + backup essentials)
    - Full Prep    : all 27 steps in sequence
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

Get-ChildItem -Path $PSScriptRoot -Filter '*.ps1' -Recurse | Unblock-File -ErrorAction SilentlyContinue

$script:ToolkitRoot = $PSScriptRoot
. (Join-Path $PSScriptRoot 'Scripts\Common\Toolkit-UI.ps1')
. (Join-Path $PSScriptRoot 'Scripts\Common\Toolkit-Report.ps1')
. (Join-Path $PSScriptRoot 'Scripts\Common\Toolkit-Execution.ps1')

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

$_principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent() # Check current user permissions
if (-not $_principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { # Verify Administrator role
    Write-Host 'ERROR: This script must run as Administrator.' -ForegroundColor Red
    Write-Host 'Right-click PowerShell → Run as Administrator, then try again.' -ForegroundColor Yellow
    exit 1
}

#endregion

#region --- Hardware Info ---

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

# Quick Check step selection — 12 steps that assess wipe safety without modifying any settings.
# Selection rationale:
#   11, 12 — OneDrive KFM + sync: primary data-loss blockers (run first)
#    1     — Unbacked data scan: identifies at-risk files outside OneDrive
#    2     — Downloads size: flags large folders that won't survive wipe
#    3     — Drive mappings: documents network drives to reconnect post-wipe
#    6     — Installed apps: documents software to reinstall
#   13     — Storage mode: identifies RAID configurations that complicate reinstall
#   18, 19, 20 — Browser bookmarks, desktop background, Outlook signatures: lightweight backups
#    4     — Printers: inventory only, no changes made
#   29     — Autopilot assignment: confirms Autopilot profile is present on device
$script:QuickCheckIndices = @(11, 12, 1, 2, 3, 6, 13, 18, 19, 20, 4, 29)

$script:PhaseLabels = [ordered]@{ # Human-readable phase names
    'ScanCheck'     = 'Scan & Check'
    'Backup'        = 'Backup'
    'Configure'     = 'Configure'
    'InstallUpdate' = 'Install & Update'
    'Autopilot'     = 'Autopilot'
}

$script:Steps = @(
    [PSCustomObject]@{ Index =  1; Phase = 'ScanCheck'; DisplayName = 'Scan for Not-Backed-Up Data';          ScriptPath = 'Scripts\DataCollection\Find-UnbackedData.ps1';                 Status = 'not-run' }
    [PSCustomObject]@{ Index =  2; Phase = 'ScanCheck'; DisplayName = 'Check Downloads Folder Sizes';          ScriptPath = 'Scripts\DataCollection\Get-DownloadsSize.ps1';                 Status = 'not-run' }
    [PSCustomObject]@{ Index =  3; Phase = 'ScanCheck'; DisplayName = 'Get Drive Mappings';                    ScriptPath = 'Scripts\DataCollection\Get-DriveMappings.ps1';                 Status = 'not-run' }
    [PSCustomObject]@{ Index =  4; Phase = 'ScanCheck'; DisplayName = 'List Printers';                         ScriptPath = 'Scripts\DataCollection\Get-Printers.ps1';                      Status = 'not-run' }
    [PSCustomObject]@{ Index =  5; Phase = 'ScanCheck'; DisplayName = 'Get Windows Product Key';               ScriptPath = 'Scripts\DataCollection\Get-WindowsProductKey.ps1';             Status = 'not-run' }
    [PSCustomObject]@{ Index =  6; Phase = 'ScanCheck'; DisplayName = 'Get Installed Applications';            ScriptPath = 'Scripts\DataCollection\Get-InstalledApplications.ps1';         Status = 'not-run' }
    [PSCustomObject]@{ Index =  7; Phase = 'ScanCheck'; DisplayName = 'Get Device Health Report';              ScriptPath = 'Scripts\DataCollection\Get-DeviceHealth.ps1';                  Status = 'not-run' }
    [PSCustomObject]@{ Index =  8; Phase = 'ScanCheck'; DisplayName = 'Get Teams Chat & Meeting Data';         ScriptPath = 'Scripts\DataCollection\Get-TeamsData.ps1';                     Status = 'not-run' }
    [PSCustomObject]@{ Index =  9; Phase = 'ScanCheck'; DisplayName = 'Get Credential Manager Entries';        ScriptPath = 'Scripts\DataCollection\Get-CredentialManagerEntries.ps1';      Status = 'not-run' }
    [PSCustomObject]@{ Index = 10; Phase = 'ScanCheck'; DisplayName = 'Get Local Accounts';                    ScriptPath = 'Scripts\DataCollection\Get-LocalAccounts.ps1';                 Status = 'not-run' }
    [PSCustomObject]@{ Index = 11; Phase = 'ScanCheck'; DisplayName = 'Test OneDrive KFM Status';              ScriptPath = 'Scripts\ConfigurationChecks\Test-OneDriveKFM.ps1';             Status = 'not-run' }
    [PSCustomObject]@{ Index = 12; Phase = 'ScanCheck'; DisplayName = 'Test OneDrive Sync Status';             ScriptPath = 'Scripts\ConfigurationChecks\Test-OneDriveSyncStatus.ps1';      Status = 'not-run' }
    [PSCustomObject]@{ Index = 13; Phase = 'ScanCheck'; DisplayName = 'Get Storage Controller Mode';           ScriptPath = 'Scripts\ConfigurationChecks\Get-StorageMode.ps1';              Status = 'not-run' }
    [PSCustomObject]@{ Index = 14; Phase = 'InstallUpdate'; DisplayName = 'Check and Update BIOS (Dell DCU)';    ScriptPath = 'Scripts\ConfigurationChanges\Invoke-BiosUpdate.ps1';    Status = 'not-run' }
    [PSCustomObject]@{ Index = 15; Phase = 'InstallUpdate'; DisplayName = 'Check and Update Drivers (Dell DCU)'; ScriptPath = 'Scripts\ConfigurationChanges\Invoke-DriverUpdate.ps1';  Status = 'not-run' }
    [PSCustomObject]@{ Index = 16; Phase = 'Configure'; DisplayName = 'Enable Wake-on-LAN (check and set)'; ScriptPath = 'Scripts\ConfigurationChanges\Enable-WakeOnLan.ps1'; Status = 'not-run' }
    [PSCustomObject]@{ Index = 17; Phase = 'ScanCheck'; DisplayName = 'Test Windows Recovery (WinRE)';         ScriptPath = 'Scripts\ConfigurationChecks\Test-WinRE.ps1';                   Status = 'not-run' }
    [PSCustomObject]@{ Index = 18; Phase = 'Backup'; DisplayName = 'Backup Browser Bookmarks';              ScriptPath = 'Scripts\ConfigurationChanges\Backup-BrowserBookmarks.ps1';     Status = 'not-run' }
    [PSCustomObject]@{ Index = 19; Phase = 'Backup'; DisplayName = 'Backup Desktop Background';             ScriptPath = 'Scripts\ConfigurationChanges\Backup-DesktopBackground.ps1';   Status = 'not-run' }
    [PSCustomObject]@{ Index = 20; Phase = 'Backup'; DisplayName = 'Backup Outlook Signatures';             ScriptPath = 'Scripts\ConfigurationChanges\Backup-OutlookSignatures.ps1';   Status = 'not-run' }
    [PSCustomObject]@{ Index = 21; Phase = 'Backup'; DisplayName = 'Backup Taskbar Layout';                 ScriptPath = 'Scripts\ConfigurationChanges\Backup-TaskbarLayout.ps1';       Status = 'not-run' }
    [PSCustomObject]@{ Index = 22; Phase = 'Backup'; DisplayName = 'Backup Wi-Fi Profiles';                 ScriptPath = 'Scripts\ConfigurationChanges\Backup-WiFiProfiles.ps1';        Status = 'not-run' }
    [PSCustomObject]@{ Index = 23; Phase = 'Configure';       DisplayName = 'Escrow BitLocker Key to Entra ID';      ScriptPath = 'Scripts\ConfigurationChanges\Test-BitLockerEscrow.ps1';       Status = 'not-run' }
    [PSCustomObject]@{ Index = 28; Phase = 'Autopilot';       DisplayName = 'Test Autopilot Readiness';              ScriptPath = 'Scripts\AutopilotReadiness\Test-AutopilotReadiness.ps1';      Status = 'not-run' }
    [PSCustomObject]@{ Index = 29; Phase = 'Autopilot';       DisplayName = 'Get Autopilot Assignment';              ScriptPath = 'Scripts\AutopilotReadiness\Get-AutopilotAssignment.ps1';      Status = 'not-run' }
    [PSCustomObject]@{ Index = 31; Phase = 'Autopilot';       DisplayName = 'Pre-Wipe Summary';                      ScriptPath = 'Scripts\AutopilotReadiness\Get-PreWipeSummary.ps1';                        Status = 'not-run' }
    [PSCustomObject]@{ Index = 32; Phase = 'Autopilot';       DisplayName = 'Register Device (OAuth · Community Mod)'; ScriptPath = 'Scripts\AutopilotReadiness\Register-AutopilotDeviceCommunity.ps1'; Status = 'not-run' }
)

#endregion

#region --- Session Management ---

function Initialize-Session { # Creates blank session state
    $steps = @{}
    foreach ($step in $script:Steps) {
        $steps["$($step.Index)"] = @{ Status = 'not-run'; Timestamp = $null; ExitCode = $null; Verdict = $null; VerdictReason = $null } # Initialize each step as not-run
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
                Status        = $prop.Value.Status
                Timestamp     = $prop.Value.Timestamp
                ExitCode      = $prop.Value.ExitCode
                Verdict       = $prop.Value.Verdict
                VerdictReason = $prop.Value.VerdictReason
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
    param([int]$Index, [string]$Status, $ExitCode, [string]$Verdict = $null, [string]$VerdictReason = $null)
    $key = "$Index"
    if (-not $script:Session.Steps.ContainsKey($key)) { $script:Session.Steps[$key] = @{} }
    $script:Session.Steps[$key].Status    = $Status
    $script:Session.Steps[$key].Timestamp = (Get-Date -Format 'o')
    $script:Session.Steps[$key].ExitCode  = $ExitCode
    $script:Session.Steps[$key].Verdict      = $Verdict
    $script:Session.Steps[$key].VerdictReason = $VerdictReason
}

#endregion

#region --- UI — see Scripts/Common/Toolkit-UI.ps1 ---
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

#endregion

#region --- Verdict / Report / Execution — see Scripts/Common/Toolkit-Report.ps1 and Toolkit-Execution.ps1 ---
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

    $null = Invoke-RunSteps -StepsToRun $script:Steps -RunLabel 'Full Prep' -RunSub "All $($script:Steps.Count) steps in sequence"
}

function Invoke-SingleStep { # Menu to run one step interactively
    while ($true) {
        Clear-Host # Clear screen
        Write-Banner # Show banner
        Show-StepListTable -Title 'RUN SINGLE STEP — SELECT BY NUMBER' # Display all steps

        Write-Host '  Enter step number (0 to cancel): ' -ForegroundColor DarkCyan -NoNewline
        $userInput = Read-Host # Get user input ($input is a reserved automatic variable)
        if ($userInput -eq '0' -or $userInput -eq '') { return }

        $num = 0
        if ([int]::TryParse($userInput.Trim(), [ref]$num)) {
            $step = $script:Steps | Where-Object { $_.Index -eq $num } | Select-Object -First 1
            if ($step) {
                Invoke-StepInteractive -Step $step
            }
            else {
                Write-Host '  Invalid step number. Try again.' -ForegroundColor Yellow
                Start-Sleep -Seconds 1
            }
        }
        else {
            Write-Host '  Invalid step number. Try again.' -ForegroundColor Yellow
            Start-Sleep -Seconds 1
        }
    }
}

function Invoke-CustomRun { # Menu to select custom step subset
    Clear-Host # Clear screen
    Write-Banner # Show banner
    Show-StepListTable -Title 'CUSTOM RUN — SELECT STEPS' # Display all steps

    Write-Host '' # Blank line
    Write-Host '  Enter step numbers separated by commas (e.g. 1,3,11,12)' -ForegroundColor Gray
    Write-Host '  Steps always run in ascending index order.' -ForegroundColor DarkGray
    Write-Host '  Enter 0 or leave blank to cancel.' -ForegroundColor DarkGray
    Write-Host '' # Blank line
    Write-Host '  Steps: ' -ForegroundColor DarkCyan -NoNewline
    $userInput = Read-Host # Get user input ($input is a reserved automatic variable)

    if ($userInput -eq '0' -or $userInput -eq '') { return }

    $indices = $userInput -split '[,\s]+' | ForEach-Object {
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
    # Clear per-step report JSONs too — stale reports from a previous device/tech
    # must not feed verdicts or the pre-wipe summary after a reset.
    Remove-Item "$LogDir\*-Report.json" -Force -ErrorAction SilentlyContinue

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
