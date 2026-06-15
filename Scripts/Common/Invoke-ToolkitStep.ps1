<#
.SYNOPSIS
    Runs one toolkit step on behalf of the desktop (Electron) host.

.DESCRIPTION
    Equivalent of Invoke-StepCapture in Toolkit-Execution.ps1, packaged as a
    standalone entry point: executes the step script with -NonInteractive,
    captures its output, parses the JSON, and evaluates Get-StepSummary /
    Get-StepVerdict from Toolkit-Report.ps1 so verdict rules live in one place.

    Emits a single JSON result envelope wrapped in sentinel lines so the host
    can extract it regardless of any console noise from the step script.

.PARAMETER ToolkitRoot
    Root folder containing the Scripts\ tree.

.PARAMETER ScriptPath
    Step script path relative to ToolkitRoot (e.g. Scripts\DataCollection\Get-Printers.ps1).

.PARAMETER PrimaryProfile
    Primary user profile name, used by KFM/sync verdict evaluation. Optional.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ToolkitRoot,
    [Parameter(Mandatory)][string]$ScriptPath,
    [string]$PrimaryProfile
)

# The Electron host reads our stdout as UTF-8, but Windows PowerShell defaults
# to the console's OEM code page. Any non-ASCII byte (paths, app names, the
# toolkit's own em dashes/middots) would then corrupt the JSON and make the
# host's JSON.parse fail — which surfaces as "Step host did not return a
# result". Force UTF-8 (no BOM) so the result envelope round-trips intact.
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false } catch {}
$OutputEncoding = New-Object System.Text.UTF8Encoding $false

# Defined first so it is available even if later setup fails.
function Write-ResultEnvelope {
    param([hashtable]$Envelope)
    Write-Output '===ATA_RESULT_BEGIN==='
    $Envelope | ConvertTo-Json -Depth 12 -Compress
    Write-Output '===ATA_RESULT_END==='
}

# Safety net: any terminating error (including while dot-sourcing the common
# modules) still yields an envelope, so the host shows the real error instead
# of an opaque "no result".
trap {
    Write-ResultEnvelope @{
        Status = 'FAIL'; ExitCode = 1; Summary = "Host shim error: $_"
        Verdict = 'FAIL'; VerdictReason = 'Step host crashed before producing a result'
        ElapsedSeconds = $null; Parsed = $null
    }
    exit 0
}

$NonInteractive = $true # Suppress console echo from Write-Log
$ScriptName = 'Invoke-ToolkitStep'
. (Join-Path $PSScriptRoot 'Initialize-Toolkit.ps1')
$LogFile = "$LogDir\$ScriptName.log"
$ErrorActionPreference = 'Continue' # Match orchestrator behavior for step invocation

Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue

$script:ToolkitRoot    = $ToolkitRoot
$script:PrimaryProfile = if ($PrimaryProfile) { $PrimaryProfile } else { $null }

. (Join-Path $PSScriptRoot 'Toolkit-Report.ps1') # Get-StepSummary / Get-StepVerdict

$fullPath = Join-Path $ToolkitRoot $ScriptPath

if (-not (Test-Path $fullPath)) {
    Write-Log "Script not found, skipping: $ScriptPath" -Level 'WARN'
    Write-ResultEnvelope @{
        Status = 'SKIP'; ExitCode = $null; Summary = 'Script not found'
        Verdict = 'WARN'; VerdictReason = 'Step was skipped — script missing'
        ElapsedSeconds = 0; Parsed = $null
    }
    exit 0
}

$LASTEXITCODE = 0
$exitCode = 0
$parsed   = $null

$sw = [System.Diagnostics.Stopwatch]::StartNew()
try {
    # Merge all streams so step console noise lands here, not on our stdout.
    $jsonRaw  = & $fullPath -NonInteractive *>&1 | Out-String
    $exitCode = if ($null -ne $LASTEXITCODE) { $LASTEXITCODE } else { 0 }
} catch {
    $sw.Stop()
    Write-ErrorLog "Step $ScriptPath threw: $_"
    Write-ResultEnvelope @{
        Status = 'FAIL'; ExitCode = $exitCode; Summary = "Error: $_"
        Verdict = 'FAIL'; VerdictReason = 'Script execution failed'
        ElapsedSeconds = [Math]::Round($sw.Elapsed.TotalSeconds, 1); Parsed = $null
    }
    exit 0
}
$sw.Stop()

$trimmed = if ($null -ne $jsonRaw) { $jsonRaw.Trim() } else { '' }
if ($trimmed) {
    try {
        $parsed = $trimmed | ConvertFrom-Json
    } catch {
        # Console noise mixed with JSON — try the outermost object boundaries.
        $first = $trimmed.IndexOf('{')
        $last  = $trimmed.LastIndexOf('}')
        if ($first -ge 0 -and $last -gt $first) {
            try { $parsed = $trimmed.Substring($first, $last - $first + 1) | ConvertFrom-Json } catch {
                Write-Log "Could not parse JSON from $ScriptPath" -Level 'WARN'
            }
        } else {
            Write-Log "Could not parse JSON from $ScriptPath" -Level 'WARN'
        }
    }
}

$status  = if ($exitCode -eq 0) { 'DONE' } else { 'FAIL' }
$summary = Get-StepSummary -Parsed $parsed -ScriptFile $ScriptPath
$verdict = Get-StepVerdict -Parsed $parsed -ScriptFile $ScriptPath -Status $status

Write-Log "Step $ScriptPath : $status — $summary"

Write-ResultEnvelope @{
    Status         = $status
    ExitCode       = $exitCode
    Summary        = $summary
    Verdict        = $verdict.Verdict
    VerdictReason  = $verdict.Reason
    ElapsedSeconds = [Math]::Round($sw.Elapsed.TotalSeconds, 1)
    Parsed         = $parsed
}
exit 0
