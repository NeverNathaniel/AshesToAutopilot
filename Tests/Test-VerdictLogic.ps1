<#
.SYNOPSIS
    Unit tests for the verdict evaluator (Get-StepVerdict in Toolkit-Report.ps1).

.DESCRIPTION
    Verifies the wipe-safety-critical evaluation rules:
    - non-zero exit + parseable JSON keeps the per-script reason and can
      never be upgraded to PASS
    - fail-closed handling of missing/corrupt step output
    - the graded verdicts for BitLocker escrow, WiFi export failures,
      Downloads size cap, enumeration failures, and Autopilot warnings

    Runs on pwsh and Windows PowerShell 5.1. Exits 0 on pass, 1 on failure.

.EXAMPLE
    pwsh -NoProfile -File .\Tests\Test-VerdictLogic.ps1
#>
[CmdletBinding()]
param(
    [string]$Repo = (Split-Path -Parent $PSScriptRoot)
)

. (Join-Path $Repo 'Scripts/Common/Toolkit-Report.ps1')

$script:failures = 0
function Assert {
    param([string]$Name, [bool]$Condition)
    if (-not $Condition) { Write-Host "FAIL: $Name"; $script:failures++ }
}

# --- Exit-code / status interplay -------------------------------------------
$v = Get-StepVerdict -Parsed ([PSCustomObject]@{ OverallStatus = 'NOT READY' }) -ScriptFile 'Test-AutopilotReadiness.ps1' -Status 'FAIL'
Assert 'FAIL status + JSON keeps the mapped reason' ($v.Verdict -eq 'FAIL' -and $v.Reason -ne 'Script execution failed')

$v = Get-StepVerdict -Parsed $null -ScriptFile 'Whatever.ps1' -Status 'FAIL'
Assert 'FAIL status + no JSON is a generic crash FAIL' ($v.Verdict -eq 'FAIL' -and $v.Reason -eq 'Script execution failed')

$v = Get-StepVerdict -Parsed $null -ScriptFile 'Whatever.ps1' -Status 'DONE'
Assert 'DONE + no JSON is WARN' ($v.Verdict -eq 'WARN')

$v = Get-StepVerdict -Parsed ([PSCustomObject]@{ Anything = 1 }) -ScriptFile 'Unknown-Script.ps1' -Status 'FAIL'
Assert 'non-zero exit can never be PASS' ($v.Verdict -eq 'FAIL' -and $v.Reason -like '*script exited non-zero*')

$v = Get-StepVerdict -Parsed $null -ScriptFile 'Whatever.ps1' -Status 'SKIP'
Assert 'SKIP is WARN' ($v.Verdict -eq 'WARN' -and $v.Reason -eq 'Step was skipped')

# --- BitLocker escrow ---------------------------------------------------------
$v = Get-StepVerdict -Parsed ([PSCustomObject]@{ AllEscrowed = $false }) -ScriptFile 'Test-BitLockerEscrow.ps1' -Status 'FAIL'
Assert 'escrow failure is blocking FAIL' ($v.Verdict -eq 'FAIL')
$v = Get-StepVerdict -Parsed ([PSCustomObject]@{ AllEscrowed = $true; KeysCapturedLocally = $true }) -ScriptFile 'Test-BitLockerEscrow.ps1' -Status 'DONE'
Assert 'locally captured key is WARN not PASS' ($v.Verdict -eq 'WARN')
$v = Get-StepVerdict -Parsed ([PSCustomObject]@{ AllEscrowed = $true; KeysCapturedLocally = $false }) -ScriptFile 'Test-BitLockerEscrow.ps1' -Status 'DONE'
Assert 'directory-escrowed keys are PASS' ($v.Verdict -eq 'PASS')

# --- Downloads ---------------------------------------------------------------
$p = [PSCustomObject]@{ Results = @([PSCustomObject]@{ CopySuccess = $false; CopySkippedReason = 'Downloads is 25 GB (over cap)' }) }
$v = Get-StepVerdict -Parsed $p -ScriptFile 'Get-DownloadsSize.ps1' -Status 'DONE'
Assert 'size-cap skip is WARN not FAIL' ($v.Verdict -eq 'WARN')

$p = [PSCustomObject]@{ Results = @([PSCustomObject]@{ CopySuccess = $false; CopySkippedReason = $null }) }
$v = Get-StepVerdict -Parsed $p -ScriptFile 'Get-DownloadsSize.ps1' -Status 'DONE'
Assert 'real copy failure is FAIL' ($v.Verdict -eq 'FAIL')

# --- WiFi export --------------------------------------------------------------
$v = Get-StepVerdict -Parsed ([PSCustomObject]@{ WlanService = 'Running'; ProfileCount = 12; ExportedCount = 0; FailedCount = 12 }) -ScriptFile 'Backup-WiFiProfiles.ps1' -Status 'DONE'
Assert 'total WiFi export failure is FAIL' ($v.Verdict -eq 'FAIL')
$v = Get-StepVerdict -Parsed ([PSCustomObject]@{ WlanService = 'Running'; ProfileCount = 12; ExportedCount = 10; FailedCount = 2 }) -ScriptFile 'Backup-WiFiProfiles.ps1' -Status 'DONE'
Assert 'partial WiFi export failure is WARN' ($v.Verdict -eq 'WARN')

# --- Enumeration failures cannot read as clean ---------------------------------
$v = Get-StepVerdict -Parsed ([PSCustomObject]@{ TotalPrinters = 0; Printers = @(); CollectionError = 'Spooler down' }) -ScriptFile 'Get-Printers.ps1' -Status 'DONE'
Assert 'printer enumeration failure is WARN' ($v.Verdict -eq 'WARN')
$v = Get-StepVerdict -Parsed ([PSCustomObject]@{ EntryCount = 0; CollectionError = 'cmdkey failed' }) -ScriptFile 'Get-CredentialManagerEntries.ps1' -Status 'DONE'
Assert 'credential enumeration failure is WARN' ($v.Verdict -eq 'WARN')
$v = Get-StepVerdict -Parsed ([PSCustomObject]@{ AccountCount = 3; AdminCount = 0; AdminCountUnknown = $true }) -ScriptFile 'Get-LocalAccounts.ps1' -Status 'DONE'
Assert 'unknown admin membership is WARN' ($v.Verdict -eq 'WARN')
$v = Get-StepVerdict -Parsed ([PSCustomObject]@{ StorageMode = 'Unknown'; Error = 'WMI down' }) -ScriptFile 'Get-StorageMode.ps1' -Status 'DONE'
Assert 'unknown storage mode is WARN' ($v.Verdict -eq 'WARN')

# --- Autopilot ----------------------------------------------------------------
$v = Get-StepVerdict -Parsed ([PSCustomObject]@{ OverallStatus = 'READY WITH WARNINGS'; Warnings = @('TPM NOT READY') }) -ScriptFile 'Test-AutopilotReadiness.ps1' -Status 'DONE'
Assert 'READY WITH WARNINGS is WARN' ($v.Verdict -eq 'WARN')
$v = Get-StepVerdict -Parsed ([PSCustomObject]@{ AutopilotDisabled = $true; ProfileDownloaded = $true }) -ScriptFile 'Get-AutopilotAssignment.ps1' -Status 'DONE'
Assert 'IsAutoPilotDisabled is WARN' ($v.Verdict -eq 'WARN')

# --- Pre-wipe summary -----------------------------------------------------------
$v = Get-StepVerdict -Parsed ([PSCustomObject]@{ WipeVerdict = 'READY TO WIPE'; StaleWarning = 'results over 24h old'; ScriptsRan = 23; ScriptsTotal = 23 }) -ScriptFile 'Get-PreWipeSummary.ps1' -Status 'DONE'
Assert 'stale READY is WARN' ($v.Verdict -eq 'WARN')
$v = Get-StepVerdict -Parsed ([PSCustomObject]@{ WipeVerdict = 'NOT READY TO WIPE'; BlockerCount = 2; Blockers = @('a', 'b') }) -ScriptFile 'Get-PreWipeSummary.ps1' -Status 'FAIL'
Assert 'NOT READY is FAIL' ($v.Verdict -eq 'FAIL')

if ($script:failures -eq 0) { Write-Host 'OK: verdict tests pass'; exit 0 }
exit 1
