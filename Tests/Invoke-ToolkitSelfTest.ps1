<#
.SYNOPSIS
    On-device validation for the toolkit. Run this on a Windows machine
    (ideally under Windows PowerShell 5.1, as a tech would) before first
    field use of a new toolkit version.

.DESCRIPTION
    Runs the three repo test suites natively:
      1. Tests\Test-Ps51Compat.ps1   - encoding + parse + PS7-operator gate
      2. Tests\Test-ToolkitEngine.ps1 - step engine exit-code/stream tests
      3. Tests\Test-VerdictLogic.ps1  - verdict evaluator rules

    With -IncludeReadOnlySteps (requires Administrator) it also executes a
    small set of read-only data-collection steps with -NonInteractive and
    verifies each emits parseable JSON with its expected top-level fields.
    No settings are changed and nothing is backed up by these steps.

.PARAMETER IncludeReadOnlySteps
    Also smoke-run read-only steps (Get-Printers, Get-StorageMode,
    Get-DeviceHealth, Get-DriveMappings). Requires an elevated prompt.

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Tests\Invoke-ToolkitSelfTest.ps1
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Tests\Invoke-ToolkitSelfTest.ps1 -IncludeReadOnlySteps
#>
[CmdletBinding()]
param(
    [switch]$IncludeReadOnlySteps
)

$repo = Split-Path -Parent $PSScriptRoot
$overallFail = 0

Write-Host ''
Write-Host "Toolkit self-test on PowerShell $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))" -ForegroundColor Cyan
Write-Host ''

foreach ($suite in @('Test-Ps51Compat.ps1', 'Test-ToolkitEngine.ps1', 'Test-VerdictLogic.ps1', 'Test-RestoreLogic.ps1')) {
    Write-Host "--- $suite ---" -ForegroundColor Cyan
    & (Join-Path $PSScriptRoot $suite)
    if ($LASTEXITCODE -ne 0) { $overallFail++ }
}

if ($IncludeReadOnlySteps) {
    Write-Host '--- Read-only step smoke run (requires Administrator) ---' -ForegroundColor Cyan
    $smokeSteps = @(
        @{ Path = 'Scripts\DataCollection\Get-Printers.ps1';      Field = 'TotalPrinters' }
        @{ Path = 'Scripts\ConfigurationChecks\Get-StorageMode.ps1'; Field = 'StorageMode' }
        @{ Path = 'Scripts\DataCollection\Get-DeviceHealth.ps1';  Field = 'OverallStatus' }
        @{ Path = 'Scripts\DataCollection\Get-DriveMappings.ps1'; Field = 'Results' }
    )
    foreach ($step in $smokeSteps) {
        $full = Join-Path $repo $step.Path
        $name = Split-Path $step.Path -Leaf
        try {
            $raw = & $full -NonInteractive 2>$null | Out-String
            $json = $raw | ConvertFrom-Json
            if ($null -eq $json.PSObject.Properties[$step.Field]) {
                Write-Host "FAIL: $name JSON missing expected field '$($step.Field)'" -ForegroundColor Red
                $overallFail++
            } else {
                Write-Host "OK:   $name emitted parseable JSON (exit $LASTEXITCODE)" -ForegroundColor Green
            }
        } catch {
            Write-Host "FAIL: $name -> $_" -ForegroundColor Red
            $overallFail++
        }
    }
}

Write-Host ''
if ($overallFail -eq 0) {
    Write-Host 'SELF-TEST PASSED' -ForegroundColor Green
    exit 0
}
Write-Host "SELF-TEST FAILED ($overallFail suite/step failure(s))" -ForegroundColor Red
exit 1
