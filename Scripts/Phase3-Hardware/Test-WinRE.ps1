<#
.SYNOPSIS
    Reports Windows Recovery Environment (WinRE) status.

.DESCRIPTION
    - Runs reagentc /info to check WinRE status.
    - Reports: WinRE enabled (yes/no), WinRE installed (yes/no), WinRE location.
    - Does NOT attempt repair. Reporting only.

.PARAMETER NonInteractive
    Suppress all prompts. Output structured JSON to stdout. Exit cleanly.

.EXAMPLE
    .\Test-WinRE.ps1
    .\Test-WinRE.ps1 -NonInteractive

.NOTES
    Source repos used:
    - garytown-master/OSD/HardwareReadiness_TS.ps1
      (reagentc invocation patterns)
    - No dedicated WinRE test script found in source repos.
      reagentc is a standard Windows tool.

    Requires: Administrator
    Output:   C:\PreWipeOutput\Logs\Test-WinRE.log
#>

[CmdletBinding()]
param(
    [switch]$NonInteractive
)

#region --- Init ---
$ScriptName = 'Test-WinRE'
$OutputRoot = 'C:\PreWipeOutput'
$LogDir     = "$OutputRoot\Logs"
$LogFile    = "$LogDir\$ScriptName.log"
$ErrorLog   = "$OutputRoot\errors.log"

if (-not (Test-Path $OutputRoot)) { New-Item -Path $OutputRoot -ItemType Directory -Force | Out-Null }
if (-not (Test-Path $LogDir))     { New-Item -Path $LogDir     -ItemType Directory -Force | Out-Null }

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    "$ts [$Level] $Message" | Out-File -FilePath $LogFile -Append
    if (-not $NonInteractive) { Write-Host "$ts [$Level] $Message" }
}

function Write-ErrorLog {
    param([string]$Message)
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    "$ts [ERROR] [$ScriptName] $Message" | Out-File -FilePath $ErrorLog -Append
    Write-Log $Message 'ERROR'
}

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "ERROR: This script must be run as Administrator." -ForegroundColor Red
    exit 1
}
#endregion

#region --- WinRE Check ---
$Result = [PSCustomObject]@{
    Timestamp    = (Get-Date -Format 'o')
    WinREEnabled = $false
    WinREInstalled = $false
    WinRELocation  = $null
    RawOutput      = $null
    Error          = $null
}

try {
    Write-Log "Running reagentc /info..."
    $reagentcOutput = & reagentc /info 2>&1 | Out-String
    $Result.RawOutput = $reagentcOutput.Trim()
    Write-Log "reagentc output: $reagentcOutput"

    # Parse output
    # Windows RE status:         Enabled
    # Windows RE location:       \\?\GLOBALROOT\device\harddisk0\partition3\Recovery\WindowsRE
    # Boot Configuration Data (BCD) identifier: {guid}

    if ($reagentcOutput -match 'Windows RE status\s*:\s*(\w+)') {
        $statusStr = $Matches[1].Trim()
        $Result.WinREEnabled   = $statusStr -eq 'Enabled'
        $Result.WinREInstalled = $statusStr -ne 'Disabled' -or ($reagentcOutput -match 'location')
        Write-Log "WinRE Status: $statusStr"
    }

    if ($reagentcOutput -match 'Windows RE location\s*:\s*(.+)') {
        $locationStr = $Matches[1].Trim()
        if ($locationStr -and $locationStr -ne '') {
            $Result.WinRELocation  = $locationStr
            $Result.WinREInstalled = $true
        }
        Write-Log "WinRE Location: $locationStr"
    }

    # Check for "not installed" pattern
    if ($reagentcOutput -match 'not.*install|could not be found|not found') {
        $Result.WinREInstalled = $false
        Write-Log "WinRE does not appear to be installed" 'WARN'
    }

} catch {
    Write-ErrorLog "reagentc failed: $_"
    $Result.Error = $_.ToString()
}
#endregion

#region --- Output ---
$Result | ConvertTo-Json -Depth 5 | Out-File "$OutputRoot\Logs\WinRE-Status.json" -Force

if ($NonInteractive) {
    $Result | ConvertTo-Json -Depth 5
} else {
    Write-Host ""
    Write-Host "=== WinRE Status ===" -ForegroundColor Cyan
    $enabledColor = if ($Result.WinREEnabled) { 'Green' } else { 'Red' }
    $installedColor = if ($Result.WinREInstalled) { 'Green' } else { 'Red' }
    Write-Host "  WinRE Enabled:   $($Result.WinREEnabled)" -ForegroundColor $enabledColor
    Write-Host "  WinRE Installed: $($Result.WinREInstalled)" -ForegroundColor $installedColor
    Write-Host "  WinRE Location:  $($Result.WinRELocation ?? 'Not found')"
    if (-not $Result.WinREEnabled -or -not $Result.WinREInstalled) {
        Write-Host ""
        Write-Host "  WARNING: WinRE is not fully configured. Run 'reagentc /enable' to attempt repair." -ForegroundColor Yellow
        Write-Host "  This script does not attempt repair - manual action required." -ForegroundColor Yellow
    }
    Write-Host ""
    Write-Host "Report: $OutputRoot\Logs\WinRE-Status.json"
    Write-Host ""
    Read-Host "Press Enter to continue"
}
#endregion
