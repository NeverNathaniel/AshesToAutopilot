<#
.SYNOPSIS
    Generates the toolkit HTML report on behalf of the desktop (Electron) host.

.DESCRIPTION
    Reconstructs the orchestrator state (steps, session, device identity) from
    a JSON payload file written by the host, then calls Export-HtmlReport from
    Toolkit-Report.ps1 — the same generator the console toolkit uses.

    Emits a JSON envelope ({ HtmlPath }) wrapped in sentinel lines.

.PARAMETER ToolkitRoot
    Root folder containing the Scripts\ tree.

.PARAMETER InputFile
    Path to a JSON payload with: RunLabel, StartTime, ComputerName,
    SerialNumber, CurrentUser, PrimaryProfile, Steps (array of step
    definitions), SessionSteps (map of index -> step session data), and
    Results (array of run results including ParsedData).
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ToolkitRoot,
    [Parameter(Mandatory)][string]$InputFile
)

$NonInteractive = $true # Suppress console echo from Write-Log
$ScriptName = 'Export-ToolkitReport'
. (Join-Path $PSScriptRoot 'Initialize-Toolkit.ps1')
$LogFile = "$LogDir\$ScriptName.log"
$ErrorActionPreference = 'Continue' # Match orchestrator behavior for report generation

Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue

$payload = Get-Content -LiteralPath $InputFile -Raw | ConvertFrom-Json

$script:ToolkitRoot    = $ToolkitRoot
$script:ComputerName   = $payload.ComputerName
$script:SerialNumber   = $payload.SerialNumber
$script:CurrentUser    = $payload.CurrentUser
$script:PrimaryProfile = $payload.PrimaryProfile

# Phase labels + lookup normally defined by the orchestrator / Toolkit-UI.ps1.
$script:PhaseLabels = [ordered]@{
    'ScanCheck'     = 'Scan & Check'
    'Backup'        = 'Backup'
    'Configure'     = 'Configure'
    'InstallUpdate' = 'Install & Update'
    'Autopilot'     = 'Autopilot'
}
function Get-PhaseLabel([string]$Phase) {
    if ($script:PhaseLabels.Contains($Phase)) { return $script:PhaseLabels[$Phase] }
    return $Phase
}

$script:Steps = @($payload.Steps)

# Export-HtmlReport expects Session.Steps to be a hashtable keyed by index.
$sessionSteps = @{}
if ($payload.SessionSteps) {
    foreach ($prop in $payload.SessionSteps.PSObject.Properties) {
        $sessionSteps[$prop.Name] = $prop.Value
    }
}
$script:Session = [PSCustomObject]@{
    StartTime = $payload.StartTime
    Steps     = $sessionSteps
}

. (Join-Path $PSScriptRoot 'Toolkit-Report.ps1')

$runLabel = if ($payload.RunLabel) { [string]$payload.RunLabel } else { 'Run' }
$htmlPath = Export-HtmlReport -ResultSet @($payload.Results) -RunLabel $runLabel

Write-Output '===ATA_RESULT_BEGIN==='
@{ HtmlPath = $htmlPath } | ConvertTo-Json -Compress
Write-Output '===ATA_RESULT_END==='
exit 0
