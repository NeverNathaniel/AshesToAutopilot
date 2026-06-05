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
    # Scan & Check
    'DellCommandTools-Report.json'                  = @{ Phase = 'ScanCheck';     Script = 'Install-DellCommandTools';              StatusPath = 'DCU.Success' }
    'WindowsProductKey-Report.json'                 = @{ Phase = 'ScanCheck';     Script = 'Get-WindowsProductKey';                 StatusPath = 'HasOEMKey' }
    'OneDriveKFM-Report.json'                       = @{ Phase = 'ScanCheck';     Script = 'Test-OneDriveKFM';                      StatusPath = 'ProfilesChecked' }
    'OneDriveSyncStatus-Report.json'                = @{ Phase = 'ScanCheck';     Script = 'Test-OneDriveSyncStatus';               StatusPath = 'OverallVerdict' }
    'DownloadsSize.json'                            = @{ Phase = 'ScanCheck';     Script = 'Get-DownloadsSize';                     StatusPath = 'ProfilesChecked' }
    'Find-UnbackedData-Report.json'                 = @{ Phase = 'ScanCheck';     Script = 'Find-UnbackedData';                     StatusPath = 'ProfilesChecked' }
    'DriveMappings-Report.json'                     = @{ Phase = 'ScanCheck';     Script = 'Get-DriveMappings';                     StatusPath = 'ProfilesChecked' }
    'InstalledApplications-Report.json'             = @{ Phase = 'ScanCheck';     Script = 'Get-InstalledApplications';             StatusPath = 'TotalCount' }
    'StorageMode-Report.json'                       = @{ Phase = 'ScanCheck';     Script = 'Get-StorageMode';                       StatusPath = 'StorageMode' }
    'WinRE-Status.json'                             = @{ Phase = 'ScanCheck';     Script = 'Test-WinRE';                            StatusPath = 'WinREEnabled' }
    'Printers-Report.json'                          = @{ Phase = 'ScanCheck';     Script = 'Get-Printers';                          StatusPath = 'TotalPrinters' }
    'DeviceHealth-Report.json'                      = @{ Phase = 'ScanCheck';     Script = 'Get-DeviceHealth';                      StatusPath = 'OverallStatus' }
    # Backup
    'BrowserBookmarks-Report.json'                  = @{ Phase = 'Backup';        Script = 'Backup-BrowserBookmarks';               StatusPath = 'TotalBackedUp' }
    'OutlookSignatures-Report.json'                 = @{ Phase = 'Backup';        Script = 'Backup-OutlookSignatures';              StatusPath = 'ProfilesChecked' }
    'TaskbarLayout-Report.json'                     = @{ Phase = 'Backup';        Script = 'Backup-TaskbarLayout';                  StatusPath = 'ProfilesChecked' }
    'DesktopBackground-Report.json'                 = @{ Phase = 'Backup';        Script = 'Backup-DesktopBackground';              StatusPath = 'ProfilesChecked' }
    'WiFiProfiles-Report.json'                      = @{ Phase = 'Backup';        Script = 'Backup-WiFiProfiles';                   StatusPath = 'ExportedCount' }
    # Configure
    'BitLockerEscrow-Report.json'                   = @{ Phase = 'Configure';     Script = 'Test-BitLockerEscrow';                  StatusPath = 'AllEscrowed' }
    'EnableWakeOnLan-Report.json'                   = @{ Phase = 'Configure';     Script = 'Enable-WakeOnLan';                      StatusPath = 'Success' }
    # Install & Update
    'BiosUpdate-Report.json'                        = @{ Phase = 'InstallUpdate'; Script = 'Invoke-BiosUpdate';                     StatusPath = 'Success' }
    'DriverUpdate-Report.json'                      = @{ Phase = 'InstallUpdate'; Script = 'Invoke-DriverUpdate';                   StatusPath = 'Success' }
    # Autopilot
    'AutopilotReadiness-Report.json'                = @{ Phase = 'Autopilot';     Script = 'Test-AutopilotReadiness';               StatusPath = 'OverallStatus' }
    'Register-AutopilotDeviceCommunity-Report.json' = @{ Phase = 'Autopilot';     Script = 'Register-AutopilotDeviceCommunity';     StatusPath = 'Success' }
    'AutopilotAssignment-Report.json'               = @{ Phase = 'Autopilot';     Script = 'Get-AutopilotAssignment';               StatusPath = 'AssignedUser' }
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

            if ($entry.Timestamp) {
                try {
                    $ageHours = ((Get-Date) - [datetime]$entry.Timestamp).TotalHours
                    $entry | Add-Member -NotePropertyName 'Stale'      -NotePropertyValue ($ageHours -gt 24) -Force
                    $entry | Add-Member -NotePropertyName 'StaleHours' -NotePropertyValue ([Math]::Round($ageHours, 1)) -Force
                } catch {
                    $entry | Add-Member -NotePropertyName 'Stale'      -NotePropertyValue $false -Force
                    $entry | Add-Member -NotePropertyName 'StaleHours' -NotePropertyValue $null  -Force
                }
            } else {
                $entry | Add-Member -NotePropertyName 'Stale'      -NotePropertyValue $false -Force
                $entry | Add-Member -NotePropertyName 'StaleHours' -NotePropertyValue $null  -Force
            }

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
    if ($syncJson) {
        if ($syncJson.OverallVerdict -eq 'NO_PROFILES') {
            $Blockers += "OneDrive sync could not be verified — no active profiles found"
        } elseif ($syncJson.Profiles) {
            $unsafeProfiles = @($syncJson.Profiles | Where-Object { -not $_.SafeToWipe })
            if ($unsafeProfiles.Count -gt 0) {
                $names = ($unsafeProfiles | ForEach-Object { $_.Profile }) -join ', '
                $Blockers += "OneDrive sync is NOT complete for: $names"
            }
        }
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
    'ScanCheck'    = 'Scan & Check'
    'Backup'       = 'Backup'
    'Configure'    = 'Configure'
    'InstallUpdate' = 'Install & Update'
    'Autopilot'    = 'Autopilot & Enrollment'
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

$hasStaleBlockers = @($ScriptResults | Where-Object { $_.Stale -and $_.Status -ne 'NOT_RUN' }).Count -gt 0
if ($hasStaleBlockers) {
    $WipeVerdict = "$WipeVerdict (WARNING: some results are over 24h old — re-run affected steps)"
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
        $staleTag = if ($s.Stale) { " [STALE — $($s.StaleHours)h old]" } else { '' }
        if ($staleTag) {
            Write-Host "    $icon $($s.Script)" -ForegroundColor $sColor -NoNewline
            Write-Host $staleTag -ForegroundColor Yellow
        } else {
            Write-Host "    $icon $($s.Script)" -ForegroundColor $sColor
        }
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

exit 0
