<#
.SYNOPSIS
    Unit tests for the step execution engine (Toolkit-Execution.ps1).

.DESCRIPTION
    Exercises Invoke-StepCapture against throwaway child scripts to verify:
    - a child that exits 1 is recorded as Status FAIL with its real exit code
      (guards the global LASTEXITCODE shadowing regression)
    - a child that writes a non-terminating error plus valid JSON still has
      its JSON parsed (stderr must not pollute the captured success stream)

    Runs on pwsh and Windows PowerShell 5.1. Exits 0 on pass, 1 on failure.

.EXAMPLE
    pwsh -NoProfile -File .\Tests\Test-ToolkitEngine.ps1
#>
[CmdletBinding()]
param(
    [string]$Repo = (Split-Path -Parent $PSScriptRoot)
)

# Stub the environment Invoke-StepCapture expects
function Write-Log { param($Message, $Level) }
function Write-ErrorLog { param($Message) }
function Get-StepSummary { param($Parsed, $ScriptFile) 'summary' }
function Get-StepVerdict { param($Parsed, $ScriptFile, $Status) @{ Verdict = 'PASS'; Reason = 'test' } }

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) "a2a-engine-test-$PID"
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
$script:ToolkitRoot = $tmp

Set-Content -Path (Join-Path $tmp 'child-exit1.ps1') -Value 'param([switch]$NonInteractive)
exit 1'
Set-Content -Path (Join-Path $tmp 'child-noisy.ps1') -Value 'param([switch]$NonInteractive)
Write-Error "noise" -ErrorAction Continue
''{"Verdict":"PASS"}''
exit 0'

. (Join-Path $Repo 'Scripts/Common/Toolkit-Execution.ps1')

$failures = 0
$r1 = Invoke-StepCapture -Step ([PSCustomObject]@{ Index = 1; DisplayName = 't1'; ScriptPath = 'child-exit1.ps1' })
$r2 = Invoke-StepCapture -Step ([PSCustomObject]@{ Index = 2; DisplayName = 't2'; ScriptPath = 'child-noisy.ps1' })

if ($r1.Status -ne 'FAIL')         { Write-Host "FAIL: exit-1 child recorded as Status=$($r1.Status) (want FAIL)"; $failures++ }
if ($r1.ExitCode -ne 1)            { Write-Host "FAIL: real exit code not persisted (got '$($r1.ExitCode)', want 1)"; $failures++ }
if ($r2.Status -ne 'DONE')         { Write-Host "FAIL: noisy exit-0 child recorded as Status=$($r2.Status) (want DONE)"; $failures++ }
if ($r2.Parsed.Verdict -ne 'PASS') { Write-Host "FAIL: stderr noise corrupted the JSON parse"; $failures++ }

Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue

if ($failures -eq 0) { Write-Host 'OK: engine tests pass'; exit 0 }
exit 1
