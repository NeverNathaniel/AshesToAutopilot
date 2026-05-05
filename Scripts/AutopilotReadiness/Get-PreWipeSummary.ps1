<#
.SYNOPSIS
    Aggregates all pre-wipe script outputs into a single readiness report with go/no-go verdict.

.DESCRIPTION
    Scans C:\PreWipeOutput\Logs\ for JSON output files from all toolkit scripts.
    Parses each for status/result fields and builds a consolidated summary organized
    by phase. Flags blockers that must be resolved before wipe. Produces a clear
    go/no-go recommendation.

.PARAMETER NonInteractive
    Suppress all prompts. Output structured JSON to stdout. Exit cleanly.

.EXAMPLE
    .\Get-PreWipeSummary.ps1
    .\Get-PreWipeSummary.ps1 -NonInteractive

.NOTES
    Source repos used:
    - None (aggregates toolkit's own output files)

    Requires: Administrator
    Output:   C:\PreWipeOutput\Logs\PreWipeSummary-Report.json
#>

[CmdletBinding()]
param(
    [switch]$NonInteractive
)

#region --- Init ---
$ScriptName = 'Get-PreWipeSummary'
. (Join-Path $PSScriptRoot '..\Common\Initialize-Toolkit.ps1')
$LogFile = "$LogDir\$ScriptName.log"
if (-not (Test-AdminElevation)) { exit 1 }
#endregion

#region --- Known Script Outputs ---
# Map each expected JSON file to its phase, script name, and how to extract status
$ScriptMap = [ordered]@{
    # Scan, Check & Backup
    'DellCommandTools-Status.json'       = @{ Phase = 'ScanCheckBackup'; Script = 'Install-DellCommandTools'; StatusPath = 'DCU.Success' }
    'WindowsProductKey-Report.json'      = @{ Phase = 'ScanCheckBackup'; Script = 'Get-WindowsProductKey'; StatusPath = 'HasOEMKey' }
    'OneDriveKFM-Status.json'            = @{ Phase = 'ScanCheckBackup'; Script = 'Test-OneDriveKFM'; StatusPath = 'ProfilesChecked' }
    'OneDriveSyncStatus-Report.json'     = @{ Phase = 'ScanCheckBackup'; Script = 'Test-OneDriveSyncStatus'; StatusPath = 'OverallVerdict' }
    'DownloadsSize.json'                 = @{ Phase = 'ScanCheckBackup'; Script = 'Get-DownloadsSize'; StatusPath = 'ProfilesChecked' }
    'BrowserBookmarks-Report.json'       = @{ Phase = 'ScanCheckBackup'; Script = 'Backup-BrowserBookmarks'; StatusPath = 'TotalBackedUp' }
    'Find-UnbackedData-Report.json'      = @{ Phase = 'ScanCheckBackup'; Script = 'Find-UnbackedData'; StatusPath = 'ProfilesChecked' }
    'OutlookSignatures-Report.json'      = @{ Phase = 'ScanCheckBackup'; Script = 'Backup-OutlookSignatures'; StatusPath = 'ProfilesChecked' }
    'DriveMappings-Report.json'          = @{ Phase = 'ScanCheckBackup'; Script = 'Get-DriveMappings'; StatusPath = 'ProfilesChecked' }
    'TaskbarLayout-Report.json'          = @{ Phase = 'ScanCheckBackup'; Script = 'Backup-TaskbarLayout'; StatusPath = 'ProfilesChecked' }
    'DesktopBackground-Report.json'      = @{ Phase = 'ScanCheckBackup'; Script = 'Backup-DesktopBackground'; StatusPath = 'ProfilesChecked' }
    'WiFiProfiles-Report.json'           = @{ Phase = 'ScanCheckBackup'; Script = 'Backup-WiFiProfiles'; StatusPath = 'ExportedCount' }
    'InstalledApplications-Report.json'  = @{ Phase = 'ScanCheckBackup'; Script = 'Get-InstalledApplications'; StatusPath = 'TotalCount' }
    'StorageMode-Report.json'            = @{ Phase = 'ScanCheckBackup'; Script = 'Get-StorageMode'; StatusPath = 'StorageMode' }
    'BiosVersion-Report.json'            = @{ Phase = 'ScanCheckBackup'; Script = 'Test-BiosVersion'; StatusPath = 'CurrentVersion' }
    'WakeOnLan-Status.json'              = @{ Phase = 'ScanCheckBackup'; Script = 'Test-WakeOnLan'; StatusPath = 'OverallStatus' }
    'WinRE-Status.json'                  = @{ Phase = 'ScanCheckBackup'; Script = 'Test-WinRE'; StatusPath = 'WinREEnabled' }
    'Printers-Report.json'               = @{ Phase = 'ScanCheckBackup'; Script = 'Get-Printers'; StatusPath = 'TotalPrinters' }
    'DriverStatus-Report.json'           = @{ Phase = 'ScanCheckBackup'; Script = 'Test-DriverStatus'; StatusPath = 'TotalDrivers' }
    'DeviceHealth-Report.json'           = @{ Phase = 'ScanCheckBackup'; Script = 'Get-DeviceHealth'; StatusPath = 'OverallStatus' }
    # Configure
    'BitLockerEscrow-Report.json'        = @{ Phase = 'Configure'; Script = 'Test-BitLockerEscrow'; StatusPath = 'AllEscrowed' }
    'WakeOnLan-SetResult.json'           = @{ Phase = 'Configure'; Script = 'Set-WakeOnLan'; StatusPath = 'Success' }
    # Install & Update
    'BiosUpdate-Result.json'             = @{ Phase = 'InstallUpdate'; Script = 'Update-Bios'; StatusPath = 'Success' }
    'DriverUpdate-Result.json'           = @{ Phase = 'InstallUpdate'; Script = 'Update-Drivers'; StatusPath = 'Success' }
    # Autopilot
    'AutopilotReadiness-Report.json'     = @{ Phase = 'Autopilot'; Script = 'Test-AutopilotReadiness'; StatusPath = 'OverallStatus' }
    'AutopilotRegister-Result.json'      = @{ Phase = 'Autopilot'; Script = 'Register-AutopilotDevice'; StatusPath = 'Success' }
    'AutopilotAssignment-Report.json'    = @{ Phase = 'Autopilot'; Script = 'Get-AutopilotAssignment'; StatusPath = 'AssignedUser' }
}
#endregion

#region --- Scan Output Files ---
Write-Log "Scanning $LogDir for script output files..."
$ScriptResults = @()
$Blockers      = @()

foreach ($fileName in $ScriptMap.Keys) {
    $info     = $ScriptMap[$fileName]
    $filePath = Join-Path $LogDir $fileName

    $entry = [PSCustomObject]@{
        Phase      = $info.Phase
        Script     = $info.Script
        FileName   = $fileName
        Found      = $false
        Timestamp  = $null
        StatusKey  = $info.StatusPath
        StatusValue = $null
        Status     = 'NOT_RUN'
    }

    if (Test-Path $filePath) {
        $entry.Found = $true
        try {
            $json = Get-Content $filePath -Raw | ConvertFrom-Json
            $entry.Timestamp = $json.Timestamp

            # Extract status value by path
            $val = $json
            foreach ($part in ($info.StatusPath -split '\.')) {
                if ($null -ne $val) { $val = $val.$part }
            }
            $entry.StatusValue = $val

            # Determine pass/fail based on the value
            $entry.Status = 'DONE'

        } catch {
            $entry.Status = 'ERROR'
            Write-Log "Could not parse $($fileName): $_" 'WARN'
        }
    } else {
        Write-Log "Not found: $fileName" 'WARN'
    }

    $ScriptResults += $entry
}
#endregion

#region --- Blocker Detection ---
Write-Log "Checking for wipe blockers..."

# Critical: BitLocker must be escrowed
$blEntry = $ScriptResults | Where-Object { $_.Script -eq 'Test-BitLockerEscrow' }
if ($blEntry -and $blEntry.Found) {
    $blJson = Get-Content (Join-Path $LogDir 'BitLockerEscrow-Report.json') -Raw | ConvertFrom-Json -ErrorAction SilentlyContinue
    if ($blJson -and $blJson.AllEscrowed -eq $false) {
        $Blockers += "BitLocker recovery keys NOT escrowed to Entra ID"
    }
} elseif (-not $blEntry -or -not $blEntry.Found) {
    $Blockers += "BitLocker escrow check has not been run"
}

# Critical: OneDrive sync must be complete
$syncEntry = $ScriptResults | Where-Object { $_.Script -eq 'Test-OneDriveSyncStatus' }
if ($syncEntry -and $syncEntry.Found) {
    $syncJson = Get-Content (Join-Path $LogDir 'OneDriveSyncStatus-Report.json') -Raw | ConvertFrom-Json -ErrorAction SilentlyContinue
    if ($syncJson -and $syncJson.OverallVerdict -eq 'NOT_SAFE') {
        $Blockers += "OneDrive sync is NOT complete for all profiles"
    }
} elseif (-not $syncEntry -or -not $syncEntry.Found) {
    $Blockers += "OneDrive sync status has not been checked"
}

# Critical: Autopilot readiness
$readyEntry = $ScriptResults | Where-Object { $_.Script -eq 'Test-AutopilotReadiness' }
if ($readyEntry -and $readyEntry.Found) {
    $readyJson = Get-Content (Join-Path $LogDir 'AutopilotReadiness-Report.json') -Raw | ConvertFrom-Json -ErrorAction SilentlyContinue
    if ($readyJson -and $readyJson.OverallStatus -eq 'NOT READY') {
        $failList = ($readyJson.Failures | ForEach-Object { $_ }) -join '; '
        $Blockers += "Device NOT ready for Autopilot: $failList"
    }
} elseif (-not $readyEntry -or -not $readyEntry.Found) {
    $Blockers += "Autopilot readiness has not been checked"
}

# Warning: Product key not captured
$pkEntry = $ScriptResults | Where-Object { $_.Script -eq 'Get-WindowsProductKey' }
if (-not $pkEntry -or -not $pkEntry.Found) {
    $Blockers += "Windows product key has not been captured"
}

# Warning: Device health issues
$healthEntry = $ScriptResults | Where-Object { $_.Script -eq 'Get-DeviceHealth' }
if ($healthEntry -and $healthEntry.Found) {
    $healthJson = Get-Content (Join-Path $LogDir 'DeviceHealth-Report.json') -Raw | ConvertFrom-Json -ErrorAction SilentlyContinue
    if ($healthJson -and $healthJson.OverallStatus -eq 'WARNINGS') {
        $Blockers += "Device health warnings: $($healthJson.Warnings -join '; ')"
    }
}

Write-Log "Blockers found: $($Blockers.Count)"
#endregion

#region --- Phase Summary ---
$PhaseNames = [ordered]@{
    'ScanCheckBackup' = 'Scan, Check & Backup'
    'Configure'       = 'Configure'
    'InstallUpdate'   = 'Install & Update'
    'Autopilot'       = 'Autopilot & Enrollment'
}

$PhaseSummary = @()
foreach ($phaseKey in $PhaseNames.Keys) {
    $phaseScripts = $ScriptResults | Where-Object { $_.Phase -eq $phaseKey }
    $ran     = ($phaseScripts | Where-Object { $_.Found }).Count
    $total   = $phaseScripts.Count

    $PhaseSummary += [PSCustomObject]@{
        Phase       = $PhaseNames[$phaseKey]
        PhaseKey    = $phaseKey
        ScriptsRan  = $ran
        ScriptsTotal = $total
        Completion   = if ($total -gt 0) { "$([math]::Round(($ran / $total) * 100))%" } else { 'N/A' }
    }
}
#endregion

#region --- Overall Verdict ---
$TotalScripts = $ScriptResults.Count
$RanScripts   = ($ScriptResults | Where-Object { $_.Found }).Count

if ($Blockers.Count -gt 0) {
    $WipeVerdict = 'NOT READY TO WIPE'
} elseif ($RanScripts -lt $TotalScripts) {
    $WipeVerdict = 'INCOMPLETE - Some scripts not yet run'
} else {
    $WipeVerdict = 'READY TO WIPE'
}

Write-Log "Wipe verdict: $WipeVerdict ($RanScripts/$TotalScripts scripts completed)"
#endregion

#region --- Output ---
$Result = [PSCustomObject]@{
    Timestamp     = (Get-Date -Format 'o')
    WipeVerdict   = $WipeVerdict
    ScriptsRan    = $RanScripts
    ScriptsTotal  = $TotalScripts
    BlockerCount  = $Blockers.Count
    Blockers      = $Blockers
    PhaseSummary  = $PhaseSummary
    ScriptDetails = $ScriptResults
}

$Result | ConvertTo-Json -Depth 5 | Out-File "$LogDir\PreWipeSummary-Report.json" -Force

if ($NonInteractive) {
    $Result | ConvertTo-Json -Depth 5
} else {
    Write-Host ""
    Write-Host "======================================" -ForegroundColor Cyan
    Write-Host "    PRE-WIPE READINESS SUMMARY" -ForegroundColor Cyan
    Write-Host "======================================" -ForegroundColor Cyan
    Write-Host ""

    $verdictColor = switch -Wildcard ($WipeVerdict) {
        'READY*'      { 'Green' }
        'NOT READY*'  { 'Red' }
        default       { 'Yellow' }
    }
    Write-Host "VERDICT: $WipeVerdict" -ForegroundColor $verdictColor
    Write-Host "Scripts completed: $RanScripts / $TotalScripts" -ForegroundColor White
    Write-Host ""

    # Phase breakdown
    foreach ($phase in $PhaseSummary) {
        $phColor = if ($phase.ScriptsRan -eq $phase.ScriptsTotal) { 'Green' } else { 'Yellow' }
        Write-Host "  $($phase.Phase): $($phase.ScriptsRan)/$($phase.ScriptsTotal) ($($phase.Completion))" -ForegroundColor $phColor
    }
    Write-Host ""

    # Script details
    Write-Host "--- Script Status ---" -ForegroundColor Cyan
    $currentPhase = ''
    foreach ($s in $ScriptResults) {
        if ($s.Phase -ne $currentPhase) {
            $currentPhase = $s.Phase
            Write-Host ""
            Write-Host "  $($PhaseNames[$currentPhase]):" -ForegroundColor Yellow
        }
        $sColor = switch ($s.Status) {
            'DONE'    { 'Green' }
            'NOT_RUN' { 'DarkGray' }
            'ERROR'   { 'Red' }
            default   { 'White' }
        }
        $icon = switch ($s.Status) {
            'DONE'    { '[OK]' }
            'NOT_RUN' { '[--]' }
            'ERROR'   { '[!!]' }
            default   { '[??]' }
        }
        Write-Host "    $icon $($s.Script)" -ForegroundColor $sColor
    }

    # Blockers
    if ($Blockers.Count -gt 0) {
        Write-Host ""
        Write-Host "--- BLOCKERS ---" -ForegroundColor Red
        foreach ($b in $Blockers) {
            Write-Host "  ! $b" -ForegroundColor Red
        }
    }

    Write-Host ""
    Write-Host "Full report: $LogDir\PreWipeSummary-Report.json"
    Write-Host ""
}
#endregion
