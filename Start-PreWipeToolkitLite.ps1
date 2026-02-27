<#
.SYNOPSIS
    Lightweight pre-wipe orchestrator — runs 11 key checks sequentially with a summary.

.DESCRIPTION
    Streamlined version of Start-PreWipeToolkit.ps1. No PSMenu dependency, no session
    persistence, no interactive menu loop. Shows an ASCII header, lists all steps,
    asks for confirmation, runs each script in order, and prints a colour-coded
    results summary at the end.

    Steps (11):
      1. Check OneDrive KFM
      2. Check OneDrive Sync Status
      3. Scan for Unbacked Data
      4. Get Downloads Size
      5. Get Installed Applications
      6. Get Storage Controller Mode
      7. Backup Browser Bookmarks
      8. Backup Desktop Background
      9. Backup Outlook Signatures
     10. Get Printers
     11. Get Autopilot Assignment

.PARAMETER NonInteractive
    Suppresses all interactive prompts and ASCII art. Runs every step, emits a
    JSON results object to stdout, then exits with code 0 (all passed) or 1 (any failed).

.NOTES
    Source repos used: None (orchestrator only; delegates to child scripts)
    Requirements  : Administrator privileges
    Output dir    : C:\PreWipeOutput\
    Log dir       : C:\PreWipeOutput\Logs\
    Does NOT modify any script in .\Scripts\ — calls them by path only.

.EXAMPLE
    .\Start-PreWipeToolkitLite.ps1

    Launches the lite pre-wipe run with confirmation prompt.

.EXAMPLE
    .\Start-PreWipeToolkitLite.ps1 -NonInteractive

    Runs all steps silently and outputs JSON results.
#>

[CmdletBinding()]
param(
    [switch]$NonInteractive
)

#region --- Init ---
$ScriptName = 'Start-PreWipeToolkitLite'
$OutputRoot  = 'C:\PreWipeOutput'
$LogDir      = Join-Path $OutputRoot 'Logs'
$LogFile     = Join-Path $LogDir "$ScriptName.log"
$ErrorLog    = Join-Path $OutputRoot 'errors.log'

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
#endregion

#region --- Admin Check ---
$_principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $_principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    if ($NonInteractive) {
        [PSCustomObject]@{ Error = 'Must run as Administrator' } | ConvertTo-Json | Write-Output
        exit 1
    }
    Write-Host ''
    Write-Host '  ERROR: This script must run as Administrator.' -ForegroundColor Red
    Write-Host '  Right-click PowerShell > Run as Administrator, then try again.' -ForegroundColor Yellow
    Write-Host ''
    Read-Host '  Press Enter to close...'
    exit 1
}
#endregion

#region --- Device Info ---
$ComputerName = $env:COMPUTERNAME
$CurrentUser  = $env:USERNAME
try {
    $_bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction SilentlyContinue
    $SerialNumber = if ($_bios -and $_bios.SerialNumber) { $_bios.SerialNumber.Trim() } else { 'Unknown' }
}
catch {
    $SerialNumber = 'Unknown'
}
#endregion

#region --- Step Definitions ---
$Steps = @(
    [PSCustomObject]@{ Index = 1;  DisplayName = 'Check OneDrive KFM';           ScriptPath = 'Scripts\ConfigurationChecks\Test-OneDriveKFM.ps1' }
    [PSCustomObject]@{ Index = 2;  DisplayName = 'Check OneDrive Sync Status';   ScriptPath = 'Scripts\ConfigurationChecks\Test-OneDriveSyncStatus.ps1' }
    [PSCustomObject]@{ Index = 3;  DisplayName = 'Scan for Unbacked Data';       ScriptPath = 'Scripts\DataCollection\Find-UnbackedData.ps1' }
    [PSCustomObject]@{ Index = 4;  DisplayName = 'Get Downloads Size';           ScriptPath = 'Scripts\DataCollection\Get-DownloadsSize.ps1' }
    [PSCustomObject]@{ Index = 5;  DisplayName = 'Get Installed Applications';   ScriptPath = 'Scripts\DataCollection\Get-InstalledApplications.ps1' }
    [PSCustomObject]@{ Index = 6;  DisplayName = 'Get Storage Controller Mode';  ScriptPath = 'Scripts\ConfigurationChecks\Get-StorageMode.ps1' }
    [PSCustomObject]@{ Index = 7;  DisplayName = 'Backup Browser Bookmarks';     ScriptPath = 'Scripts\ConfigurationChanges\Backup-BrowserBookmarks.ps1' }
    [PSCustomObject]@{ Index = 8;  DisplayName = 'Backup Desktop Background';    ScriptPath = 'Scripts\ConfigurationChanges\Backup-DesktopBackground.ps1' }
    [PSCustomObject]@{ Index = 9;  DisplayName = 'Backup Outlook Signatures';    ScriptPath = 'Scripts\ConfigurationChanges\Backup-OutlookSignatures.ps1' }
    [PSCustomObject]@{ Index = 10; DisplayName = 'Get Printers';                 ScriptPath = 'Scripts\DataCollection\Get-Printers.ps1' }
    [PSCustomObject]@{ Index = 11; DisplayName = 'Get Autopilot Assignment';     ScriptPath = 'Scripts\AutopilotReadiness\Get-AutopilotAssignment.ps1' }
)

# Results array — populated during execution
$Results = @()
#endregion

#region --- Display Helpers ---
function Show-Phoenix {
    Write-Host ''
    Write-Host '           )\._.,--.....,--.   '  -ForegroundColor DarkYellow
    Write-Host '          /;   _..--' -NoNewline -ForegroundColor DarkYellow
    Write-Host "'" -NoNewline -ForegroundColor Yellow
    Write-Host "    ,--';  " -ForegroundColor DarkYellow
    Write-Host '         /  ' -NoNewline -ForegroundColor DarkYellow
    Write-Host "'" -NoNewline -ForegroundColor Yellow
    Write-Host "-'" -NoNewline -ForegroundColor DarkYellow
    Write-Host '          ' -NoNewline
    Write-Host "'.  '" -ForegroundColor DarkYellow
    Write-Host '        ;                          ;' -ForegroundColor DarkYellow
    Write-Host '        ;    ' -NoNewline -ForegroundColor DarkYellow
    Write-Host 'ASHES TO AUTOPILOT' -NoNewline -ForegroundColor White
    Write-Host '    ;' -ForegroundColor DarkYellow
    Write-Host '        ;    ' -NoNewline -ForegroundColor DarkYellow
    Write-Host 'Pre-Wipe Lite' -NoNewline -ForegroundColor Cyan
    Write-Host '           ;' -ForegroundColor DarkYellow
    Write-Host "         '-._                  _,-'" -ForegroundColor DarkYellow
    Write-Host "             '---..______..---'"      -ForegroundColor DarkYellow
    Write-Host ''
}

function Show-DeviceInfo {
    $line = "  $ComputerName  |  SN: $SerialNumber  |  $CurrentUser"
    $bar  = [string]::new([char]0x2550, 52)
    Write-Host "  $bar" -ForegroundColor DarkGray
    Write-Host $line -ForegroundColor Gray
    Write-Host "  $bar" -ForegroundColor DarkGray
    Write-Host ''
}

function Show-StepList {
    Write-Host '  Steps to run:' -ForegroundColor Cyan
    Write-Host ''
    foreach ($step in $Steps) {
        $num = $step.Index.ToString().PadLeft(2)
        Write-Host "    $($num). $($step.DisplayName)" -ForegroundColor Gray
    }
    Write-Host ''
}

function Show-StepProgress {
    param([int]$Current, [int]$Total, [string]$Name)
    Write-Host ''
    $bar = [string]::new([char]0x2500, 52)
    Write-Host "  $bar" -ForegroundColor DarkGray
    Write-Host "  [$Current/$Total] " -NoNewline -ForegroundColor Cyan
    Write-Host $Name -ForegroundColor White
    Write-Host "  $bar" -ForegroundColor DarkGray
    Write-Host ''
}

function Show-StepResult {
    param([string]$Name, [string]$Status)
    switch ($Status) {
        'DONE' { Write-Host "  [DONE] $Name" -ForegroundColor Green }
        'FAIL' { Write-Host "  [FAIL] $Name" -ForegroundColor Red }
        'SKIP' { Write-Host "  [SKIP] $Name" -ForegroundColor Yellow }
    }
}

function Show-Summary {
    param([array]$ResultSet)

    $bar = [string]::new([char]0x2550, 52)

    Write-Host ''
    Write-Host ''
    Write-Host "  $bar" -ForegroundColor Cyan
    Write-Host '  RESULTS SUMMARY' -ForegroundColor White
    Write-Host "  $bar" -ForegroundColor Cyan
    Write-Host ''

    foreach ($r in $ResultSet) {
        $num    = $r.Index.ToString().PadLeft(2)
        $name   = $r.DisplayName.PadRight(36)
        $badge  = "[$($r.Status)]"

        $color = switch ($r.Status) {
            'DONE' { 'Green' }
            'FAIL' { 'Red' }
            'SKIP' { 'Yellow' }
            default { 'Gray' }
        }

        Write-Host "    $num. $name " -NoNewline -ForegroundColor Gray
        Write-Host $badge -ForegroundColor $color
    }

    $done = @($ResultSet | Where-Object { $_.Status -eq 'DONE' }).Count
    $fail = @($ResultSet | Where-Object { $_.Status -eq 'FAIL' }).Count
    $skip = @($ResultSet | Where-Object { $_.Status -eq 'SKIP' }).Count
    $total = $ResultSet.Count

    Write-Host ''
    Write-Host "  $bar" -ForegroundColor Cyan
    Write-Host -NoNewline '  DONE: ' -ForegroundColor Gray
    Write-Host -NoNewline "$done" -ForegroundColor Green
    Write-Host -NoNewline '  |  FAIL: ' -ForegroundColor Gray
    Write-Host -NoNewline "$fail" -ForegroundColor Red
    Write-Host -NoNewline '  |  SKIP: ' -ForegroundColor Gray
    Write-Host -NoNewline "$skip" -ForegroundColor Yellow
    Write-Host "  |  Total: $total" -ForegroundColor Gray
    Write-Host "  $bar" -ForegroundColor Cyan
    Write-Host ''
}
#endregion

#region --- Step Execution ---
function Invoke-LiteStep {
    param([PSCustomObject]$Step)

    $fullPath = Join-Path $PSScriptRoot $Step.ScriptPath

    if (-not (Test-Path $fullPath)) {
        Write-Log "Script not found, skipping: $($Step.ScriptPath)" -Level 'WARN'
        return 'SKIP'
    }

    $LASTEXITCODE = 0
    $exitCode = 0

    try {
        if ($NonInteractive) {
            & $fullPath -NonInteractive
        }
        else {
            & $fullPath
        }
        $exitCode = if ($null -ne $LASTEXITCODE) { $LASTEXITCODE } else { 0 }
    }
    catch {
        Write-ErrorLog "Step $($Step.Index) ($($Step.DisplayName)) threw: $_"
        if (-not $NonInteractive) {
            Write-Host "  [FAIL] Unhandled error: $_" -ForegroundColor Red
        }
        return 'FAIL'
    }

    if ($exitCode -eq 0) {
        Write-Log "Step $($Step.Index) ($($Step.DisplayName)) completed successfully."
        return 'DONE'
    }
    else {
        Write-Log "Step $($Step.Index) ($($Step.DisplayName)) failed with exit code $($exitCode)." -Level 'ERROR'
        return 'FAIL'
    }
}
#endregion

#region --- Main Logic ---

# ── NonInteractive mode ─────────────────────────────────────────────────
if ($NonInteractive) {
    Write-Log 'Starting Lite run (NonInteractive).'

    foreach ($step in $Steps) {
        $status = Invoke-LiteStep -Step $step
        $Results += [PSCustomObject]@{
            Index       = $step.Index
            DisplayName = $step.DisplayName
            ScriptPath  = $step.ScriptPath
            Status      = $status
        }
    }

    $done = @($Results | Where-Object { $_.Status -eq 'DONE' }).Count
    $fail = @($Results | Where-Object { $_.Status -eq 'FAIL' }).Count
    $skip = @($Results | Where-Object { $_.Status -eq 'SKIP' }).Count

    $output = [PSCustomObject]@{
        Timestamp    = (Get-Date -Format 'o')
        ScriptName   = $ScriptName
        ComputerName = $ComputerName
        SerialNumber = $SerialNumber
        CurrentUser  = $CurrentUser
        Steps        = $Results
        Summary      = [PSCustomObject]@{
            Total   = $Results.Count
            Done    = $done
            Failed  = $fail
            Skipped = $skip
        }
    }

    # Save JSON report to disk
    $reportPath = Join-Path $LogDir "$ScriptName-Report.json"
    try {
        $output | ConvertTo-Json -Depth 5 | Set-Content $reportPath -Encoding UTF8 -Force
    }
    catch {
        Write-ErrorLog "Failed to save report: $_"
    }

    $output | ConvertTo-Json -Depth 5 | Write-Output
    Write-Log "Lite run complete. Done=$done, Fail=$fail, Skip=$skip."
    if ($fail -gt 0) { exit 1 } else { exit 0 }
}

# ── Interactive mode ─────────────────────────────────────────────────────
Clear-Host
Show-Phoenix
Show-DeviceInfo
Show-StepList

Write-Log 'Starting Lite run (Interactive).'

$confirm = Read-Host '  Run all 11 steps? (Y/N)'
if ($confirm -notmatch '^[Yy]') {
    Write-Host ''
    Write-Host '  Cancelled. No steps were run.' -ForegroundColor Yellow
    Write-Host ''
    Write-Log 'User cancelled Lite run.'
    Read-Host '  Press Enter to close...'
    exit 0
}

Write-Host ''

$total = $Steps.Count
foreach ($step in $Steps) {
    Show-StepProgress -Current $step.Index -Total $total -Name $step.DisplayName

    $status = Invoke-LiteStep -Step $step

    Show-StepResult -Name $step.DisplayName -Status $status

    $Results += [PSCustomObject]@{
        Index       = $step.Index
        DisplayName = $step.DisplayName
        ScriptPath  = $step.ScriptPath
        Status      = $status
    }

    # Brief pause so the tech sees the result before next step starts
    Start-Sleep -Milliseconds 600
}

# ── Summary ──────────────────────────────────────────────────────────────
Show-Summary -ResultSet $Results

# Save JSON report alongside other output
$reportPath = Join-Path $LogDir "$ScriptName-Report.json"
try {
    $reportData = [PSCustomObject]@{
        Timestamp    = (Get-Date -Format 'o')
        ScriptName   = $ScriptName
        ComputerName = $ComputerName
        SerialNumber = $SerialNumber
        CurrentUser  = $CurrentUser
        Steps        = $Results
        Summary      = [PSCustomObject]@{
            Total   = $Results.Count
            Done    = @($Results | Where-Object { $_.Status -eq 'DONE' }).Count
            Failed  = @($Results | Where-Object { $_.Status -eq 'FAIL' }).Count
            Skipped = @($Results | Where-Object { $_.Status -eq 'SKIP' }).Count
        }
    }
    $reportData | ConvertTo-Json -Depth 5 | Set-Content $reportPath -Encoding UTF8 -Force
    Write-Log "Report saved to $($reportPath)."
    Write-Host "  Report saved: $reportPath" -ForegroundColor DarkGray
}
catch {
    Write-ErrorLog "Failed to save report: $_"
}

$failCount = @($Results | Where-Object { $_.Status -eq 'FAIL' }).Count
Write-Log "Lite run complete. Done=$(@($Results | Where-Object { $_.Status -eq 'DONE' }).Count), Fail=$failCount, Skip=$(@($Results | Where-Object { $_.Status -eq 'SKIP' }).Count)."

Write-Host ''
Read-Host '  Press Enter to close...'

#endregion
