# AshesToAutopilot Audit Remediation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix all defects identified in `docs/audit/script-audit-2026-05-05.md`, prioritised from critical correctness bugs down to low-severity cleanup.

**Architecture:** Fixes are applied directly to existing scripts. No new files are created except where a helper already exists and needs to be adopted. Each task targets one audit finding or one cross-cutting category. Tasks are grouped by severity: Critical → High (PS 5.1) → High (swallowed exceptions) → Medium (helper adoption) → Low (cleanup).

**Tech Stack:** PowerShell 5.1 target (Windows 10/11 default shell). Syntax checked locally with `pwsh 7` (`$PSVersionTable.PSVersion` ≥ 5.1 syntax only). Scripts run on Windows; macOS is the dev machine.

**Syntax-check command (run after every edit):**
```powershell
pwsh -NoProfile -Command "
  \$errors = @()
  \$null = [System.Management.Automation.Language.Parser]::ParseFile('<path>', [ref]\$null, [ref]\$errors)
  if (\$errors) { \$errors | ForEach-Object { Write-Error \$_.Message }; exit 1 }
  Write-Host 'Syntax OK'
"
```

---

## Priority 1 — Critical Correctness Bugs

These four fixes prevent silent false-PASS verdicts that could allow a device to be wiped without a successful Autopilot registration or with unsynced/unencrypted data.

---

### Task 1: Fix Register-AutopilotDevice.ps1 — Success left true on upload failure (F30-01)

**File:** `Scripts/AutopilotReadiness/Register-AutopilotDevice.ps1`

**Problem:** `$Result.Success = $true` is set at line 151 (after hash collection), before the upload is attempted. The upload `catch` block at lines 183–191 sets `$Result.Error` and `$Result.UploadStatus = 'UploadFailed'` but never sets `$Result.Success = $false`. So a failed upload produces JSON with `"Success": true`.

- [ ] **Step 1: Change Success assignment — only mark true after successful upload**

In `Scripts/AutopilotReadiness/Register-AutopilotDevice.ps1`, replace:

```powershell
    if (Test-Path $csvPath) {
        $csvData = Import-Csv $csvPath -ErrorAction Stop
        $hashEntry = $csvData | Select-Object -First 1
        $Result.HardwareHash = if ($hashEntry.'Hardware Hash') { "PRESENT (length: $($hashEntry.'Hardware Hash'.Length))" } else { 'Not collected' }
        Write-Log "Hardware hash collected. CSV saved to $csvPath"
        $Result.UploadStatus = 'HashCollected'
        $Result.Success      = $true
    } else {
        throw "Output CSV not created at $csvPath"
    }
```

with:

```powershell
    if (Test-Path $csvPath) {
        $csvData = Import-Csv $csvPath -ErrorAction Stop
        $hashEntry = $csvData | Select-Object -First 1
        $Result.HardwareHash = if ($hashEntry.'Hardware Hash') { "PRESENT (length: $($hashEntry.'Hardware Hash'.Length))" } else { 'Not collected' }
        Write-Log "Hardware hash collected. CSV saved to $csvPath"
        $Result.UploadStatus = 'HashCollected'
    } else {
        throw "Output CSV not created at $csvPath"
    }
```

- [ ] **Step 2: Set Success=true only after upload succeeds; add Success=false in upload catch**

In the upload region, replace:

```powershell
    Get-WindowsAutopilotInfo @uploadParams -ErrorAction Stop

    $Result.UploadStatus   = 'Uploaded'
    $Result.UploadResponse = 'Device submitted to Autopilot successfully'
    $Result.Success        = $true
    Write-Log "Device successfully registered with Autopilot"

} catch {
    $errMsg = $_.ToString()
    Write-ErrorLog "Autopilot upload failed: $errMsg"
    # Upload failure is non-fatal if hash was collected
    $Result.UploadStatus   = 'UploadFailed'
    $Result.UploadResponse = $errMsg
    # Hash was collected, so partial success
    $Result.Error = "Upload failed (hash saved to $csvPath): $errMsg"
}
```

with:

```powershell
    Get-WindowsAutopilotInfo @uploadParams -ErrorAction Stop

    $Result.UploadStatus   = 'Uploaded'
    $Result.UploadResponse = 'Device submitted to Autopilot successfully'
    $Result.Success        = $true
    Write-Log "Device successfully registered with Autopilot"

} catch {
    $errMsg = $_.ToString()
    Write-ErrorLog "Autopilot upload failed: $errMsg"
    $Result.UploadStatus   = 'UploadFailed'
    $Result.UploadResponse = $errMsg
    $Result.Success        = $false
    $Result.Error = "Upload failed (hash saved to $csvPath): $errMsg"
}
```

- [ ] **Step 3: Syntax check**

```powershell
pwsh -NoProfile -Command "
  \$errors = @()
  \$null = [System.Management.Automation.Language.Parser]::ParseFile('/Users/nsol/GithubRepos/AshesToAutopilot/Scripts/AutopilotReadiness/Register-AutopilotDevice.ps1', [ref]\$null, [ref]\$errors)
  if (\$errors) { \$errors | ForEach-Object { Write-Error \$_.Message }; exit 1 }
  Write-Host 'Syntax OK'
"
```

Expected: `Syntax OK`

- [ ] **Step 4: Commit**

```bash
git add Scripts/AutopilotReadiness/Register-AutopilotDevice.ps1
git commit -m "fix: Register-AutopilotDevice — set Success=false when upload fails (F30-01)"
```

---

### Task 2: Add Get-StepVerdict case for Register-AutopilotDevice (CC-11)

**File:** `Start-PreWipeToolkit.ps1`

**Problem:** `Get-StepVerdict`'s `switch` statement has no case for `Register-AutopilotDevice`, so it falls through to `default { return @{ Verdict = 'PASS' } }` unconditionally — meaning the orchestrator always verdicts PASS for step 30 regardless of JSON content.

- [ ] **Step 1: Add a verdict case for Register-AutopilotDevice**

In `Start-PreWipeToolkit.ps1`, in the `Get-StepVerdict` function's `switch` block, find the `'*Get-AutopilotAssignment*'` case (around line 728) and insert the new case immediately before the `default` branch:

```powershell
            '*Register-AutopilotDevice*' {
                if ($Parsed.Success -eq $true) { return @{ Verdict = 'PASS'; Reason = "Device registered (upload: $($Parsed.UploadStatus))" } }
                if ($Parsed.UploadStatus -eq 'UploadFailed') { return @{ Verdict = 'FAIL'; Reason = "Autopilot upload failed: $($Parsed.Error)" } }
                if ($Parsed.UploadStatus -eq 'HashCollected') { return @{ Verdict = 'WARN'; Reason = 'Hash collected but not uploaded' } }
                return @{ Verdict = 'FAIL'; Reason = 'Registration did not complete successfully' }
            }
```

Place this before:
```powershell
            default                         { return @{ Verdict = 'PASS'; Reason = 'Completed' } }
```

- [ ] **Step 2: Syntax check**

```powershell
pwsh -NoProfile -Command "
  \$errors = @()
  \$null = [System.Management.Automation.Language.Parser]::ParseFile('/Users/nsol/GithubRepos/AshesToAutopilot/Start-PreWipeToolkit.ps1', [ref]\$null, [ref]\$errors)
  if (\$errors) { \$errors | ForEach-Object { Write-Error \$_.Message }; exit 1 }
  Write-Host 'Syntax OK'
"
```

Expected: `Syntax OK`

- [ ] **Step 3: Commit**

```bash
git add Start-PreWipeToolkit.ps1
git commit -m "fix: add Get-StepVerdict case for Register-AutopilotDevice (CC-11)"
```

---

### Task 3: Fix OneDrive sync verdict mismatch in Get-PreWipeSummary (CC-08 / F12-01)

**File:** `Scripts/AutopilotReadiness/Get-PreWipeSummary.ps1`

**Problem (line 141):** `Get-PreWipeSummary` checks `$syncJson.OverallVerdict -eq 'NOT_SAFE'` to decide whether to add a blocker. But:
1. The orchestrator (`Get-StepVerdict`, line 613) checks `Profiles[*].SafeToWipe` — so the same data is evaluated two different ways.
2. `OverallVerdict = 'NO_PROFILES'` passes silently through both evaluators, even though sync was never verified.

Fix: make `Get-PreWipeSummary` use `Profiles[*].SafeToWipe` to match the orchestrator, and add a `NO_PROFILES` blocker.

- [ ] **Step 1: Replace the OneDrive sync blocker check**

In `Scripts/AutopilotReadiness/Get-PreWipeSummary.ps1`, find (around line 137–146):

```powershell
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
```

Replace with:

```powershell
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
```

- [ ] **Step 2: Syntax check**

```powershell
pwsh -NoProfile -Command "
  \$errors = @()
  \$null = [System.Management.Automation.Language.Parser]::ParseFile('/Users/nsol/GithubRepos/AshesToAutopilot/Scripts/AutopilotReadiness/Get-PreWipeSummary.ps1', [ref]\$null, [ref]\$errors)
  if (\$errors) { \$errors | ForEach-Object { Write-Error \$_.Message }; exit 1 }
  Write-Host 'Syntax OK'
"
```

Expected: `Syntax OK`

- [ ] **Step 3: Commit**

```bash
git add Scripts/AutopilotReadiness/Get-PreWipeSummary.ps1
git commit -m "fix: align OneDrive sync blocker to check Profiles[*].SafeToWipe, handle NO_PROFILES (CC-08)"
```

---

### Task 4: Fix Test-BitLockerEscrow — Error status silently passes allEscrowed (F23-02 / CC-12)

**File:** `Scripts/ConfigurationChanges/Test-BitLockerEscrow.ps1`

**Problem (lines 162–164):** The outer `catch` at line 151 adds an entry with `EscrowStatus = 'Error'` to `$Results`. But `$allEscrowed` is computed as:
```powershell
$allEscrowed = -not ($Results | Where-Object { $_.EscrowStatus -in @('EscrowFailed', 'NoRecoveryKey') })
```
The string `'Error'` is not in that list, so `$allEscrowed = $true` even when `Get-BitLockerVolume` threw an exception. Fix: add `'Error'` to the exclusion list.

- [ ] **Step 1: Add 'Error' to allEscrowed filter**

In `Scripts/ConfigurationChanges/Test-BitLockerEscrow.ps1`, replace (around line 162):

```powershell
$allEscrowed = -not ($Results | Where-Object {
    $_.EscrowStatus -in @('EscrowFailed', 'NoRecoveryKey')
})
```

with:

```powershell
$allEscrowed = -not ($Results | Where-Object {
    $_.EscrowStatus -in @('EscrowFailed', 'NoRecoveryKey', 'Error')
})
```

- [ ] **Step 2: Syntax check**

```powershell
pwsh -NoProfile -Command "
  \$errors = @()
  \$null = [System.Management.Automation.Language.Parser]::ParseFile('/Users/nsol/GithubRepos/AshesToAutopilot/Scripts/ConfigurationChanges/Test-BitLockerEscrow.ps1', [ref]\$null, [ref]\$errors)
  if (\$errors) { \$errors | ForEach-Object { Write-Error \$_.Message }; exit 1 }
  Write-Host 'Syntax OK'
"
```

Expected: `Syntax OK`

- [ ] **Step 3: Commit**

```bash
git add Scripts/ConfigurationChanges/Test-BitLockerEscrow.ps1
git commit -m "fix: add 'Error' status to allEscrowed exclusion list in Test-BitLockerEscrow (F23-02)"
```

---

## Priority 2 — PowerShell 5.1 Compatibility (CC-06)

The `??` null-coalescing operator is PS 7+ only. On PS 5.1 (the Windows default), these scripts throw a **parse error** and produce no output at all.

---

### Task 5: Fix Get-DownloadsSize.ps1 — PS 5.1 null-coalescing (F2-01)

**File:** `Scripts/DataCollection/Get-DownloadsSize.ps1`

- [ ] **Step 1: Replace ?? operator at line 134**

Find:
```powershell
            $ProfileResult.SizeBytes = [long]($size ?? 0)
```

Replace with:
```powershell
            $ProfileResult.SizeBytes = [long](if ($null -ne $size) { $size } else { 0 })
```

- [ ] **Step 2: Syntax check**

```powershell
pwsh -NoProfile -Command "
  \$errors = @()
  \$null = [System.Management.Automation.Language.Parser]::ParseFile('/Users/nsol/GithubRepos/AshesToAutopilot/Scripts/DataCollection/Get-DownloadsSize.ps1', [ref]\$null, [ref]\$errors)
  if (\$errors) { \$errors | ForEach-Object { Write-Error \$_.Message }; exit 1 }
  Write-Host 'Syntax OK'
"
```

Expected: `Syntax OK`

- [ ] **Step 3: Commit**

```bash
git add Scripts/DataCollection/Get-DownloadsSize.ps1
git commit -m "fix: replace ?? operator with PS 5.1-compatible if/else in Get-DownloadsSize (F2-01)"
```

---

### Task 6: Fix Get-Printers.ps1 — PS 5.1 null-coalescing (F4-01)

**File:** `Scripts/DataCollection/Get-Printers.ps1`

Two occurrences at lines 121 and 144.

- [ ] **Step 1: Replace ?? at line 121**

Find:
```powershell
Write-Log "Default printer: $($DefaultPrinter.Name ?? 'None found')"
```

Replace with:
```powershell
Write-Log "Default printer: $(if ($null -ne $DefaultPrinter.Name) { $DefaultPrinter.Name } else { 'None found' })"
```

- [ ] **Step 2: Replace ?? at line 144**

Find:
```powershell
    Write-Host "Default: $($DefaultPrinter.Name ?? 'None')" -ForegroundColor Cyan
```

Replace with:
```powershell
    Write-Host "Default: $(if ($null -ne $DefaultPrinter.Name) { $DefaultPrinter.Name } else { 'None' })" -ForegroundColor Cyan
```

- [ ] **Step 3: Syntax check**

```powershell
pwsh -NoProfile -Command "
  \$errors = @()
  \$null = [System.Management.Automation.Language.Parser]::ParseFile('/Users/nsol/GithubRepos/AshesToAutopilot/Scripts/DataCollection/Get-Printers.ps1', [ref]\$null, [ref]\$errors)
  if (\$errors) { \$errors | ForEach-Object { Write-Error \$_.Message }; exit 1 }
  Write-Host 'Syntax OK'
"
```

Expected: `Syntax OK`

- [ ] **Step 4: Commit**

```bash
git add Scripts/DataCollection/Get-Printers.ps1
git commit -m "fix: replace ?? operators with PS 5.1-compatible if/else in Get-Printers (F4-01)"
```

---

### Task 7: Fix Update-Drivers.ps1 — PS 5.1 null-coalescing (F26-01)

**File:** `Scripts/ConfigurationChanges/Update-Drivers.ps1`

- [ ] **Step 1: Replace ?? at line 144**

Find:
```powershell
    $meaning   = $ExitCodeMap[$exitCode] ?? "ExitCode $exitCode (unknown)"
```

Replace with:
```powershell
    $meaning   = if ($ExitCodeMap.ContainsKey($exitCode)) { $ExitCodeMap[$exitCode] } else { "ExitCode $exitCode (unknown)" }
```

- [ ] **Step 2: Syntax check**

```powershell
pwsh -NoProfile -Command "
  \$errors = @()
  \$null = [System.Management.Automation.Language.Parser]::ParseFile('/Users/nsol/GithubRepos/AshesToAutopilot/Scripts/ConfigurationChanges/Update-Drivers.ps1', [ref]\$null, [ref]\$errors)
  if (\$errors) { \$errors | ForEach-Object { Write-Error \$_.Message }; exit 1 }
  Write-Host 'Syntax OK'
"
```

Expected: `Syntax OK`

- [ ] **Step 3: Commit**

```bash
git add Scripts/ConfigurationChanges/Update-Drivers.ps1
git commit -m "fix: replace ?? operator with PS 5.1-compatible ContainsKey check in Update-Drivers (F26-01)"
```

---

### Task 8: Fix Update-Bios.ps1 — PS 5.1 null-coalescing (F27-01)

**File:** `Scripts/ConfigurationChanges/Update-Bios.ps1`

- [ ] **Step 1: Locate and replace ?? at line 145**

First read the file around line 145 to confirm exact text, then replace:
```powershell
    $meaning   = $ExitCodeMap[$exitCode] ?? "ExitCode $exitCode (unknown)"
```

with:
```powershell
    $meaning   = if ($ExitCodeMap.ContainsKey($exitCode)) { $ExitCodeMap[$exitCode] } else { "ExitCode $exitCode (unknown)" }
```

- [ ] **Step 2: Syntax check**

```powershell
pwsh -NoProfile -Command "
  \$errors = @()
  \$null = [System.Management.Automation.Language.Parser]::ParseFile('/Users/nsol/GithubRepos/AshesToAutopilot/Scripts/ConfigurationChanges/Update-Bios.ps1', [ref]\$null, [ref]\$errors)
  if (\$errors) { \$errors | ForEach-Object { Write-Error \$_.Message }; exit 1 }
  Write-Host 'Syntax OK'
"
```

Expected: `Syntax OK`

- [ ] **Step 3: Commit**

```bash
git add Scripts/ConfigurationChanges/Update-Bios.ps1
git commit -m "fix: replace ?? operator with PS 5.1-compatible ContainsKey check in Update-Bios (F27-01)"
```

---

## Priority 3 — Swallowed Exception Cleanup (CC-12)

These empty `catch {}` blocks suppress errors and allow scripts to report false-success to the orchestrator.

---

### Task 9: Fix Find-UnbackedData.ps1 — empty catch (F1-01)

**File:** `Scripts/DataCollection/Find-UnbackedData.ps1`

**Problem (lines 216–218):** An empty `catch {}` inside the per-profile file-attribute loop silently discards exceptions. Access-denied errors are invisible; the script under-reports findings.

- [ ] **Step 1: Read the file around lines 210–225 to identify exact block**

```bash
sed -n '210,225p' /Users/nsol/GithubRepos/AshesToAutopilot/Scripts/DataCollection/Find-UnbackedData.ps1
```

- [ ] **Step 2: Replace empty catch with Write-ErrorLog**

Find the empty `catch {}` block inside the per-profile file enumeration loop (near line 216) and replace it:

```powershell
        } catch {}
```

with:

```powershell
        } catch {
            Write-ErrorLog "Failed to enumerate file attributes in profile loop: $_"
        }
```

- [ ] **Step 3: Syntax check**

```powershell
pwsh -NoProfile -Command "
  \$errors = @()
  \$null = [System.Management.Automation.Language.Parser]::ParseFile('/Users/nsol/GithubRepos/AshesToAutopilot/Scripts/DataCollection/Find-UnbackedData.ps1', [ref]\$null, [ref]\$errors)
  if (\$errors) { \$errors | ForEach-Object { Write-Error \$_.Message }; exit 1 }
  Write-Host 'Syntax OK'
"
```

Expected: `Syntax OK`

- [ ] **Step 4: Commit**

```bash
git add Scripts/DataCollection/Find-UnbackedData.ps1
git commit -m "fix: log exceptions instead of swallowing them in Find-UnbackedData (F1-01)"
```

---

### Task 10: Fix Get-StorageMode.ps1 — two empty catch blocks (F13-01)

**File:** `Scripts/ConfigurationChecks/Get-StorageMode.ps1`

**Problem (lines 132–134 and 152–154):** Two empty `catch {}` blocks surround RST and NVMe detection. Silently falls through to `StorageMode = 'Unknown'` on WMI failure, masking the error.

- [ ] **Step 1: Read lines 128–158 to confirm both empty catch blocks**

```bash
sed -n '128,158p' /Users/nsol/GithubRepos/AshesToAutopilot/Scripts/ConfigurationChecks/Get-StorageMode.ps1
```

- [ ] **Step 2: Replace first empty catch (RST detection, ~line 132)**

Find:
```powershell
        } catch {}
```
(first occurrence around line 132, inside RST detection block)

Replace with:
```powershell
        } catch {
            Write-ErrorLog "RST detection failed: $_"
        }
```

- [ ] **Step 3: Replace second empty catch (NVMe detection, ~line 152)**

Find the second occurrence of `} catch {}` (NVMe detection block) and replace with:
```powershell
        } catch {
            Write-ErrorLog "NVMe detection failed: $_"
        }
```

- [ ] **Step 4: Syntax check**

```powershell
pwsh -NoProfile -Command "
  \$errors = @()
  \$null = [System.Management.Automation.Language.Parser]::ParseFile('/Users/nsol/GithubRepos/AshesToAutopilot/Scripts/ConfigurationChecks/Get-StorageMode.ps1', [ref]\$null, [ref]\$errors)
  if (\$errors) { \$errors | ForEach-Object { Write-Error \$_.Message }; exit 1 }
  Write-Host 'Syntax OK'
"
```

Expected: `Syntax OK`

- [ ] **Step 5: Commit**

```bash
git add Scripts/ConfigurationChecks/Get-StorageMode.ps1
git commit -m "fix: log exceptions instead of swallowing them in Get-StorageMode (F13-01)"
```

---

## Priority 4 — Initialize-Toolkit.ps1 Adoption (CC-02)

26 scripts duplicate `$OutputRoot`/`$LogDir`/`$ErrorLog` setup, dir creation, `Write-Log`, `Write-ErrorLog`, and `Test-AdminElevation`. All should dot-source `Scripts/Common/Initialize-Toolkit.ps1` instead.

**The standard init region for a script in any subfolder of `Scripts/` is:**

```powershell
#region --- Init ---
$ScriptName = 'ScriptNameHere'
. (Join-Path $PSScriptRoot '..\Common\Initialize-Toolkit.ps1')
$LogFile = "$LogDir\$ScriptName.log"
if (-not (Test-AdminElevation)) { exit 1 }
#endregion
```

Replace the entire inline init block (everything from `$ScriptName = ...` through the admin elevation check) with the four lines above. The `$OutputRoot`, `$LogDir`, `$ErrorLog`, dir-creation loop, `Write-Log`, `Write-ErrorLog`, and `Test-AdminElevation` are all provided by `Initialize-Toolkit.ps1`.

**Note:** `Initialize-Toolkit.ps1` uses `$NonInteractive` and `$LogFile` which must be in scope — both are defined by the calling script before/after dot-sourcing respectively, so the order matters: `$ScriptName` first, dot-source, then `$LogFile`.

Scripts that are already compliant (do NOT need this task): `Get-TeamsData.ps1`, `Get-CredentialManagerEntries.ps1`, `Get-LocalAccounts.ps1`, `Backup-WiFiProfiles.ps1`, `Test-AutopilotReadiness.ps1`, `Get-PreWipeSummary.ps1`.

Tasks 11–20 below cover all 26 non-compliant scripts in batches by folder.

---

### Task 11: Initialize-Toolkit adoption — DataCollection batch (CC-02)

**Files (8 scripts):**
- `Scripts/DataCollection/Find-UnbackedData.ps1`
- `Scripts/DataCollection/Get-DownloadsSize.ps1`
- `Scripts/DataCollection/Get-DriveMappings.ps1`
- `Scripts/DataCollection/Get-Printers.ps1`
- `Scripts/DataCollection/Get-WindowsProductKey.ps1`
- `Scripts/DataCollection/Get-InstalledApplications.ps1`
- `Scripts/DataCollection/Get-DeviceHealth.ps1`
- `Scripts/DataCollection/Get-TeamsData.ps1` ← already compliant, skip

For **each** of the 7 non-compliant scripts:

- [ ] **Step 1: Read the script's init region to identify exact text to replace**

Look for the block starting with `$ScriptName = ...` and ending after the admin elevation check. It will look like:

```powershell
#region --- Init ---
$ScriptName = '<name>'
$OutputRoot = 'C:\PreWipeOutput'
$LogDir     = "$OutputRoot\Logs"
$LogFile    = "$LogDir\$ScriptName.log"
$ErrorLog   = "$OutputRoot\errors.log"

if (-not (Test-Path $OutputRoot)) { New-Item -Path $OutputRoot -ItemType Directory -Force | Out-Null }
if (-not (Test-Path $LogDir))     { New-Item -Path $LogDir     -ItemType Directory -Force | Out-Null }

function Write-Log { ... }
function Write-ErrorLog { ... }

if (-not ([Security.Principal.WindowsPrincipal]...).IsInRole(...)) {
    Write-Host "ERROR: ..." -ForegroundColor Red
    exit 1
}
#endregion
```

- [ ] **Step 2: Replace inline init block with dot-source pattern**

Replace the entire `#region --- Init ---` block with:

```powershell
#region --- Init ---
$ScriptName = '<original-ScriptName-value>'
. (Join-Path $PSScriptRoot '..\Common\Initialize-Toolkit.ps1')
$LogFile = "$LogDir\$ScriptName.log"
if (-not (Test-AdminElevation)) { exit 1 }
#endregion
```

- [ ] **Step 3: Syntax check each edited script**

```powershell
@(
  'Find-UnbackedData','Get-DownloadsSize','Get-DriveMappings',
  'Get-Printers','Get-WindowsProductKey','Get-InstalledApplications','Get-DeviceHealth'
) | ForEach-Object {
  $path = "/Users/nsol/GithubRepos/AshesToAutopilot/Scripts/DataCollection/$_.ps1"
  $errors = @()
  $null = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errors)
  if ($errors) { Write-Error "$_`: $($errors[0].Message)" } else { Write-Host "OK: $_" }
}
```

Expected: `OK: <scriptname>` for each of the 7 scripts.

- [ ] **Step 4: Commit**

```bash
git add Scripts/DataCollection/Find-UnbackedData.ps1 Scripts/DataCollection/Get-DownloadsSize.ps1 \
  Scripts/DataCollection/Get-DriveMappings.ps1 Scripts/DataCollection/Get-Printers.ps1 \
  Scripts/DataCollection/Get-WindowsProductKey.ps1 Scripts/DataCollection/Get-InstalledApplications.ps1 \
  Scripts/DataCollection/Get-DeviceHealth.ps1
git commit -m "refactor: adopt Initialize-Toolkit.ps1 in DataCollection scripts (CC-02)"
```

---

### Task 12: Initialize-Toolkit adoption — ConfigurationChecks batch (CC-02)

**Files (7 scripts — all non-compliant):**
- `Scripts/ConfigurationChecks/Test-OneDriveSyncStatus.ps1`
- `Scripts/ConfigurationChecks/Test-OneDriveKFM.ps1`
- `Scripts/ConfigurationChecks/Get-StorageMode.ps1`
- `Scripts/ConfigurationChecks/Test-BiosVersion.ps1`
- `Scripts/ConfigurationChecks/Test-DriverStatus.ps1`
- `Scripts/ConfigurationChecks/Test-WakeOnLan.ps1`
- `Scripts/ConfigurationChecks/Test-WinRE.ps1`

Follow the same pattern as Task 11: read each script's init region, replace the entire inline block with the four-line dot-source pattern.

- [ ] **Step 1: Edit each of the 7 scripts** (follow Task 11 steps 1–2 for each)

- [ ] **Step 2: Syntax check all 7 scripts**

```powershell
@(
  'Test-OneDriveSyncStatus','Test-OneDriveKFM','Get-StorageMode',
  'Test-BiosVersion','Test-DriverStatus','Test-WakeOnLan','Test-WinRE'
) | ForEach-Object {
  $path = "/Users/nsol/GithubRepos/AshesToAutopilot/Scripts/ConfigurationChecks/$_.ps1"
  $errors = @()
  $null = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errors)
  if ($errors) { Write-Error "$_`: $($errors[0].Message)" } else { Write-Host "OK: $_" }
}
```

Expected: `OK: <scriptname>` for all 7 scripts.

- [ ] **Step 3: Commit**

```bash
git add Scripts/ConfigurationChecks/
git commit -m "refactor: adopt Initialize-Toolkit.ps1 in ConfigurationChecks scripts (CC-02)"
```

---

### Task 13: Initialize-Toolkit adoption — ConfigurationChanges batch (CC-02)

**Files (9 scripts — all non-compliant):**
- `Scripts/ConfigurationChanges/Backup-BrowserBookmarks.ps1`
- `Scripts/ConfigurationChanges/Backup-DesktopBackground.ps1`
- `Scripts/ConfigurationChanges/Backup-OutlookSignatures.ps1`
- `Scripts/ConfigurationChanges/Backup-TaskbarLayout.ps1`
- `Scripts/ConfigurationChanges/Test-BitLockerEscrow.ps1`
- `Scripts/ConfigurationChanges/Set-WakeOnLan.ps1`
- `Scripts/ConfigurationChanges/Install-DellCommandTools.ps1`
- `Scripts/ConfigurationChanges/Update-Drivers.ps1`
- `Scripts/ConfigurationChanges/Update-Bios.ps1`

`Backup-WiFiProfiles.ps1` is already compliant — skip it.

Follow the same pattern as Task 11.

- [ ] **Step 1: Edit each of the 9 scripts** (follow Task 11 steps 1–2 for each)

- [ ] **Step 2: Syntax check all 9 scripts**

```powershell
@(
  'Backup-BrowserBookmarks','Backup-DesktopBackground','Backup-OutlookSignatures',
  'Backup-TaskbarLayout','Test-BitLockerEscrow','Set-WakeOnLan',
  'Install-DellCommandTools','Update-Drivers','Update-Bios'
) | ForEach-Object {
  $path = "/Users/nsol/GithubRepos/AshesToAutopilot/Scripts/ConfigurationChanges/$_.ps1"
  $errors = @()
  $null = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errors)
  if ($errors) { Write-Error "$_`: $($errors[0].Message)" } else { Write-Host "OK: $_" }
}
```

Expected: `OK: <scriptname>` for all 9 scripts.

- [ ] **Step 3: Commit**

```bash
git add Scripts/ConfigurationChanges/
git commit -m "refactor: adopt Initialize-Toolkit.ps1 in ConfigurationChanges scripts (CC-02)"
```

---

### Task 14: Initialize-Toolkit adoption — AutopilotReadiness batch (CC-02)

**Files (2 non-compliant scripts):**
- `Scripts/AutopilotReadiness/Register-AutopilotDevice.ps1`
- `Scripts/AutopilotReadiness/Get-AutopilotAssignment.ps1`
- `Scripts/AutopilotReadiness/Report-AutopilotReadinessToHudu.ps1`

`Test-AutopilotReadiness.ps1` and `Get-PreWipeSummary.ps1` are already compliant — skip them.

Follow the same pattern as Task 11.

- [ ] **Step 1: Edit each of the 3 scripts** (follow Task 11 steps 1–2 for each)

- [ ] **Step 2: Syntax check all 3 scripts**

```powershell
@(
  'Register-AutopilotDevice','Get-AutopilotAssignment','Report-AutopilotReadinessToHudu'
) | ForEach-Object {
  $path = "/Users/nsol/GithubRepos/AshesToAutopilot/Scripts/AutopilotReadiness/$_.ps1"
  $errors = @()
  $null = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errors)
  if ($errors) { Write-Error "$_`: $($errors[0].Message)" } else { Write-Host "OK: $_" }
}
```

Expected: `OK: <scriptname>` for all 3 scripts.

- [ ] **Step 3: Commit**

```bash
git add Scripts/AutopilotReadiness/Register-AutopilotDevice.ps1 \
  Scripts/AutopilotReadiness/Get-AutopilotAssignment.ps1 \
  Scripts/AutopilotReadiness/Report-AutopilotReadinessToHudu.ps1
git commit -m "refactor: adopt Initialize-Toolkit.ps1 in AutopilotReadiness scripts (CC-02)"
```

---

## Priority 5 — Dell Tool Path Adoption (CC-03)

7 scripts define inline DCU/DCC path searches instead of calling `Find-DellCommandUpdate` / `Find-DellCommandConfigure` from `Scripts/Common/Find-DellCommandTool.ps1`.

**Standard pattern to replace inline path blocks:**

```powershell
# Remove inline DCU/DCC path blocks like:
#   $DCUPaths = @(...); $DCUExe = $null; foreach ($p in $DCUPaths) { ... }
# Replace with:
. (Join-Path $PSScriptRoot '..\Common\Find-DellCommandTool.ps1')
$DCUExe = Find-DellCommandUpdate    # or Find-DellCommandConfigure for DCC
```

Note: If the script already dot-sources `Initialize-Toolkit.ps1` (after Task 12/13), add the `Find-DellCommandTool.ps1` dot-source on the next line after the existing one. Do not add a second `Initialize-Toolkit.ps1` dot-source.

---

### Task 15: Dell tool path adoption — ConfigurationChecks batch (CC-03)

**Files:**
- `Scripts/ConfigurationChecks/Test-BiosVersion.ps1` (DCU, lines 96–101)
- `Scripts/ConfigurationChecks/Test-DriverStatus.ps1` (DCU, lines 78–83)
- `Scripts/ConfigurationChecks/Test-WakeOnLan.ps1` (DCC — local `Get-DCCExePath` function, lines 73–82)

For each script:

- [ ] **Step 1: Read the script to identify the inline path block**

- [ ] **Step 2: Add Find-DellCommandTool dot-source after Initialize-Toolkit dot-source**

```powershell
. (Join-Path $PSScriptRoot '..\Common\Initialize-Toolkit.ps1')
. (Join-Path $PSScriptRoot '..\Common\Find-DellCommandTool.ps1')
```

- [ ] **Step 3: Remove the inline path block and replace usages**

For DCU scripts (`Test-BiosVersion`, `Test-DriverStatus`): delete the `$DCUPaths`/loop block and replace `$DCUExe = ...` with `$DCUExe = Find-DellCommandUpdate`.

For `Test-WakeOnLan`: delete the `function Get-DCCExePath { ... }` and replace all calls to `Get-DCCExePath` with `Find-DellCommandConfigure`.

- [ ] **Step 4: Syntax check all 3 scripts**

```powershell
@('Test-BiosVersion','Test-DriverStatus','Test-WakeOnLan') | ForEach-Object {
  $path = "/Users/nsol/GithubRepos/AshesToAutopilot/Scripts/ConfigurationChecks/$_.ps1"
  $errors = @()
  $null = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errors)
  if ($errors) { Write-Error "$_`: $($errors[0].Message)" } else { Write-Host "OK: $_" }
}
```

Expected: `OK: <scriptname>` for all 3.

- [ ] **Step 5: Commit**

```bash
git add Scripts/ConfigurationChecks/Test-BiosVersion.ps1 \
  Scripts/ConfigurationChecks/Test-DriverStatus.ps1 \
  Scripts/ConfigurationChecks/Test-WakeOnLan.ps1
git commit -m "refactor: adopt Find-DellCommandTool helpers in ConfigurationChecks scripts (CC-03)"
```

---

### Task 16: Dell tool path adoption — ConfigurationChanges batch (CC-03)

**Files:**
- `Scripts/ConfigurationChanges/Set-WakeOnLan.ps1` (DCC — local `Get-DCCExePath`, lines 74–83)
- `Scripts/ConfigurationChanges/Install-DellCommandTools.ps1` (DCU+DCC — inline `Get-DCUExePath`/`Get-DCCExePath`, lines 101–119)
- `Scripts/ConfigurationChanges/Update-Drivers.ps1` (DCU — inline paths, lines 90–95)
- `Scripts/ConfigurationChanges/Update-Bios.ps1` (DCU — inline paths, lines 90–95)

Follow the same pattern as Task 15.

- [ ] **Step 1: Edit each of the 4 scripts** (read inline block, add dot-source, replace usages)

- [ ] **Step 2: Syntax check all 4 scripts**

```powershell
@('Set-WakeOnLan','Install-DellCommandTools','Update-Drivers','Update-Bios') | ForEach-Object {
  $path = "/Users/nsol/GithubRepos/AshesToAutopilot/Scripts/ConfigurationChanges/$_.ps1"
  $errors = @()
  $null = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errors)
  if ($errors) { Write-Error "$_`: $($errors[0].Message)" } else { Write-Host "OK: $_" }
}
```

Expected: `OK: <scriptname>` for all 4.

- [ ] **Step 3: Commit**

```bash
git add Scripts/ConfigurationChanges/Set-WakeOnLan.ps1 \
  Scripts/ConfigurationChanges/Install-DellCommandTools.ps1 \
  Scripts/ConfigurationChanges/Update-Drivers.ps1 \
  Scripts/ConfigurationChanges/Update-Bios.ps1
git commit -m "refactor: adopt Find-DellCommandTool helpers in ConfigurationChanges scripts (CC-03)"
```

---

## Priority 6 — Get-ActiveUserProfile Adoption (CC-10)

10 profile-iterating scripts use inline `Win32_UserProfile` queries with their own skip-lists. All should call `Get-ActiveUserProfile` (and `Mount-UserHive`/`Dismount-UserHive`) from `Scripts/Common/Get-ActiveUserProfile.ps1`.

Only `Get-TeamsData.ps1` already uses the helper.

**Standard pattern:**

```powershell
. (Join-Path $PSScriptRoot '..\Common\Initialize-Toolkit.ps1')
. (Join-Path $PSScriptRoot '..\Common\Get-ActiveUserProfile.ps1')
# ...
$Profiles = Get-ActiveUserProfile   # replaces the inline Win32_UserProfile block
```

For scripts that load registry hives, replace inline `reg load`/`reg unload` calls with `Mount-UserHive`/`Dismount-UserHive`.

---

### Task 17: Get-ActiveUserProfile adoption — DataCollection batch (CC-10)

**Files:**
- `Scripts/DataCollection/Find-UnbackedData.ps1`
- `Scripts/DataCollection/Get-DownloadsSize.ps1`
- `Scripts/DataCollection/Get-DriveMappings.ps1`
- `Scripts/DataCollection/Get-InstalledApplications.ps1`

For each script:

- [ ] **Step 1: Read the script's profile enumeration block** (the `Win32_UserProfile` query + skip-list)

- [ ] **Step 2: Add Get-ActiveUserProfile dot-source** (after Initialize-Toolkit dot-source)

```powershell
. (Join-Path $PSScriptRoot '..\Common\Initialize-Toolkit.ps1')
. (Join-Path $PSScriptRoot '..\Common\Get-ActiveUserProfile.ps1')
```

- [ ] **Step 3: Replace inline profile enumeration block**

Delete the `$SkipSIDs`, `$CutoffDate`, `$SkipNames`, `$AllProfiles = Get-CimInstance ...` block and replace the `$Profiles` population with:

```powershell
$Profiles = @(Get-ActiveUserProfile)
```

- [ ] **Step 4: Replace inline hive load/unload (if used by the script)**

For scripts that call `reg load`/`reg unload` directly, replace with:

```powershell
$HiveLoaded = Mount-UserHive -UserProfile $profile
# ... access registry ...
if ($HiveLoaded) { Dismount-UserHive -SID $profile.SID }
```

- [ ] **Step 5: Syntax check all 4 scripts**

```powershell
@('Find-UnbackedData','Get-DownloadsSize','Get-DriveMappings','Get-InstalledApplications') | ForEach-Object {
  $path = "/Users/nsol/GithubRepos/AshesToAutopilot/Scripts/DataCollection/$_.ps1"
  $errors = @()
  $null = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errors)
  if ($errors) { Write-Error "$_`: $($errors[0].Message)" } else { Write-Host "OK: $_" }
}
```

Expected: `OK: <scriptname>` for all 4.

- [ ] **Step 6: Commit**

```bash
git add Scripts/DataCollection/Find-UnbackedData.ps1 Scripts/DataCollection/Get-DownloadsSize.ps1 \
  Scripts/DataCollection/Get-DriveMappings.ps1 Scripts/DataCollection/Get-InstalledApplications.ps1
git commit -m "refactor: adopt Get-ActiveUserProfile in DataCollection scripts (CC-10)"
```

---

### Task 18: Get-ActiveUserProfile adoption — ConfigurationChecks and Changes batches (CC-10)

**Files:**
- `Scripts/ConfigurationChecks/Test-OneDriveKFM.ps1`
- `Scripts/ConfigurationChecks/Test-OneDriveSyncStatus.ps1`
- `Scripts/ConfigurationChanges/Backup-BrowserBookmarks.ps1`
- `Scripts/ConfigurationChanges/Backup-DesktopBackground.ps1`
- `Scripts/ConfigurationChanges/Backup-OutlookSignatures.ps1`
- `Scripts/ConfigurationChanges/Backup-TaskbarLayout.ps1`

Follow the same pattern as Task 17 (steps 1–4) for each of the 6 scripts.

- [ ] **Step 1: Edit each of the 6 scripts**

- [ ] **Step 2: Syntax check all 6 scripts**

```powershell
@(
  '/Users/nsol/GithubRepos/AshesToAutopilot/Scripts/ConfigurationChecks/Test-OneDriveKFM.ps1',
  '/Users/nsol/GithubRepos/AshesToAutopilot/Scripts/ConfigurationChecks/Test-OneDriveSyncStatus.ps1',
  '/Users/nsol/GithubRepos/AshesToAutopilot/Scripts/ConfigurationChanges/Backup-BrowserBookmarks.ps1',
  '/Users/nsol/GithubRepos/AshesToAutopilot/Scripts/ConfigurationChanges/Backup-DesktopBackground.ps1',
  '/Users/nsol/GithubRepos/AshesToAutopilot/Scripts/ConfigurationChanges/Backup-OutlookSignatures.ps1',
  '/Users/nsol/GithubRepos/AshesToAutopilot/Scripts/ConfigurationChanges/Backup-TaskbarLayout.ps1'
) | ForEach-Object {
  $errors = @()
  $null = [System.Management.Automation.Language.Parser]::ParseFile($_, [ref]$null, [ref]$errors)
  $name = Split-Path $_ -Leaf
  if ($errors) { Write-Error "$name`: $($errors[0].Message)" } else { Write-Host "OK: $name" }
}
```

Expected: `OK: <scriptname>` for all 6.

- [ ] **Step 3: Commit**

```bash
git add Scripts/ConfigurationChecks/Test-OneDriveKFM.ps1 \
  Scripts/ConfigurationChecks/Test-OneDriveSyncStatus.ps1 \
  Scripts/ConfigurationChanges/Backup-BrowserBookmarks.ps1 \
  Scripts/ConfigurationChanges/Backup-DesktopBackground.ps1 \
  Scripts/ConfigurationChanges/Backup-OutlookSignatures.ps1 \
  Scripts/ConfigurationChanges/Backup-TaskbarLayout.ps1
git commit -m "refactor: adopt Get-ActiveUserProfile in ConfigurationChecks and ConfigurationChanges scripts (CC-10)"
```

---

## Priority 7 — Low-Severity Cleanup

---

### Task 19: Add `exit 0` to all 24 missing scripts (CC-09)

**Affected scripts (24 total):** Find-UnbackedData, Get-DriveMappings, Get-Printers, Get-WindowsProductKey, Get-InstalledApplications, Get-DeviceHealth, Test-OneDriveKFM, Get-StorageMode, Test-BiosVersion, Test-DriverStatus, Test-WakeOnLan, Test-WinRE, Backup-BrowserBookmarks, Backup-DesktopBackground, Backup-OutlookSignatures, Backup-TaskbarLayout, Test-BitLockerEscrow, Set-WakeOnLan, Install-DellCommandTools, Update-Drivers, Update-Bios, Get-AutopilotAssignment, Register-AutopilotDevice, Report-AutopilotReadinessToHudu

- [ ] **Step 1: For each of the 24 scripts, append `exit 0` as the final line (after the closing `#endregion` of the output section)**

The exit 0 should be the last line of each file. In scripts that already have `exit 1` paths, `exit 0` goes on a new line at the very end.

- [ ] **Step 2: Syntax check a sample (5 scripts) to confirm no accidental damage**

```powershell
@(
  '/Users/nsol/GithubRepos/AshesToAutopilot/Scripts/DataCollection/Find-UnbackedData.ps1',
  '/Users/nsol/GithubRepos/AshesToAutopilot/Scripts/ConfigurationChecks/Test-WinRE.ps1',
  '/Users/nsol/GithubRepos/AshesToAutopilot/Scripts/ConfigurationChanges/Update-Bios.ps1',
  '/Users/nsol/GithubRepos/AshesToAutopilot/Scripts/AutopilotReadiness/Get-AutopilotAssignment.ps1',
  '/Users/nsol/GithubRepos/AshesToAutopilot/Scripts/AutopilotReadiness/Register-AutopilotDevice.ps1'
) | ForEach-Object {
  $errors = @()
  $null = [System.Management.Automation.Language.Parser]::ParseFile($_, [ref]$null, [ref]$errors)
  $name = Split-Path $_ -Leaf
  if ($errors) { Write-Error "$name`: $($errors[0].Message)" } else { Write-Host "OK: $name" }
}
```

Expected: `OK: <scriptname>` for all 5.

- [ ] **Step 3: Commit**

```bash
git add Scripts/
git commit -m "fix: add explicit exit 0 on clean success path to all scripts missing it (CC-09)"
```

---

### Task 20: Normalize inconsistent JSON output filenames (CC-05)

**Five scripts use non-standard suffixes.** Standard is `<Noun>-Report.json`.

| Script | Current filename | Correct filename |
|--------|-----------------|-----------------|
| `Test-OneDriveKFM.ps1` | `OneDriveKFM-Status.json` | `OneDriveKFM-Report.json` |
| `Set-WakeOnLan.ps1` | `WakeOnLan-SetResult.json` | `WakeOnLan-Report.json` |
| `Install-DellCommandTools.ps1` | `DellCommandTools-Status.json` | `DellCommandTools-Report.json` |
| `Update-Drivers.ps1` | `DriverUpdate-Result.json` | `DriverUpdate-Report.json` |
| `Update-Bios.ps1` | `BiosUpdate-Result.json` | `BiosUpdate-Report.json` |

`Get-PreWipeSummary.ps1`'s `$ScriptMap` must be updated to match the new names.

- [ ] **Step 1: Update output filename in Test-OneDriveKFM.ps1**

Find: `OneDriveKFM-Status.json`  
Replace with: `OneDriveKFM-Report.json`

- [ ] **Step 2: Update output filename in Set-WakeOnLan.ps1**

Find: `WakeOnLan-SetResult.json`  
Replace with: `WakeOnLan-Report.json`

- [ ] **Step 3: Update output filename in Install-DellCommandTools.ps1**

Find: `DellCommandTools-Status.json`  
Replace with: `DellCommandTools-Report.json`

- [ ] **Step 4: Update output filename in Update-Drivers.ps1**

Find: `DriverUpdate-Result.json`  
Replace with: `DriverUpdate-Report.json`

- [ ] **Step 5: Update output filename in Update-Bios.ps1**

Find: `BiosUpdate-Result.json`  
Replace with: `BiosUpdate-Report.json`

- [ ] **Step 6: Update $ScriptMap in Get-PreWipeSummary.ps1**

In `Scripts/AutopilotReadiness/Get-PreWipeSummary.ps1`, update the `$ScriptMap` keys to match:

```powershell
'OneDriveKFM-Report.json'         # was: 'OneDriveKFM-Status.json'
'DellCommandTools-Report.json'    # was: 'DellCommandTools-Status.json'
'WakeOnLan-Report.json'           # was: 'WakeOnLan-SetResult.json'
'BiosUpdate-Report.json'          # was: 'BiosUpdate-Result.json'
'DriverUpdate-Report.json'        # was: 'DriverUpdate-Result.json'
```

Also update `Start-PreWipeToolkit.ps1` if it references any of these filenames directly (search the file for each old name and update).

- [ ] **Step 7: Syntax check affected scripts**

```powershell
@(
  '/Users/nsol/GithubRepos/AshesToAutopilot/Scripts/ConfigurationChecks/Test-OneDriveKFM.ps1',
  '/Users/nsol/GithubRepos/AshesToAutopilot/Scripts/ConfigurationChanges/Set-WakeOnLan.ps1',
  '/Users/nsol/GithubRepos/AshesToAutopilot/Scripts/ConfigurationChanges/Install-DellCommandTools.ps1',
  '/Users/nsol/GithubRepos/AshesToAutopilot/Scripts/ConfigurationChanges/Update-Drivers.ps1',
  '/Users/nsol/GithubRepos/AshesToAutopilot/Scripts/ConfigurationChanges/Update-Bios.ps1',
  '/Users/nsol/GithubRepos/AshesToAutopilot/Scripts/AutopilotReadiness/Get-PreWipeSummary.ps1'
) | ForEach-Object {
  $errors = @()
  $null = [System.Management.Automation.Language.Parser]::ParseFile($_, [ref]$null, [ref]$errors)
  $name = Split-Path $_ -Leaf
  if ($errors) { Write-Error "$name`: $($errors[0].Message)" } else { Write-Host "OK: $name" }
}
```

Expected: `OK: <scriptname>` for all 6.

- [ ] **Step 8: Commit**

```bash
git add Scripts/ConfigurationChecks/Test-OneDriveKFM.ps1 \
  Scripts/ConfigurationChanges/Set-WakeOnLan.ps1 \
  Scripts/ConfigurationChanges/Install-DellCommandTools.ps1 \
  Scripts/ConfigurationChanges/Update-Drivers.ps1 \
  Scripts/ConfigurationChanges/Update-Bios.ps1 \
  Scripts/AutopilotReadiness/Get-PreWipeSummary.ps1
git commit -m "fix: normalize JSON output filenames to -Report.json convention (CC-05)"
```

---

### Task 21: Fix README folder misclassification (CC-04)

**File:** `README.md`

Five scripts are documented under "Scan, Check & Backup" but live in `Scripts/ConfigurationChanges/` and perform write operations: `Backup-BrowserBookmarks`, `Backup-DesktopBackground`, `Backup-OutlookSignatures`, `Backup-TaskbarLayout`, `Backup-WiFiProfiles`.

- [ ] **Step 1: Read the README section listing these scripts**

```bash
grep -n -A2 "Backup-" /Users/nsol/GithubRepos/AshesToAutopilot/README.md | head -40
```

- [ ] **Step 2: Move the 5 Backup-* entries to a "Configuration Changes — Backups" section**

Add a `### Configuration Changes — Backups` subsection (or merge into the existing Configuration Changes section) and move the five entries there. Remove them from the "Scan, Check & Backup" section.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: move Backup-* scripts to Configuration Changes section in README (CC-04)"
```

---

### Task 22: Document Report-AutopilotReadinessToHudu.ps1 (CC-07)

**File:** `README.md`, `Scripts/AutopilotReadiness/Report-AutopilotReadinessToHudu.ps1`

This 572-line script is entirely absent from the orchestrator, README, and `Get-PreWipeSummary`. The F32-02 issue (mandatory `-HuduBaseUrl` parameter incompatible with orchestrator's `-NonInteractive`-only invocation) makes it unsuitable for orchestrator inclusion without changes.

Recommended approach (per audit): document it explicitly as a "post-run reporting" script.

- [ ] **Step 1: Add a post-run reporting section to README.md**

After the main steps table, add a section:

```markdown
## Post-Run Reporting

### Report-AutopilotReadinessToHudu.ps1

Posts a structured pre-wipe readiness report to a Hudu IT documentation instance.
This script is **not part of the orchestrated workflow** and must be run manually.

**Prerequisites:**
- The `HuduAPI` PowerShell module must be installed: `Install-Module HuduAPI`
- A Hudu instance with API access

**Usage:**
```powershell
.\Scripts\AutopilotReadiness\Report-AutopilotReadinessToHudu.ps1 -HuduBaseUrl "https://your-hudu.com"
```

Run this after `Start-PreWipeToolkit.ps1` completes to create a permanent record of the pre-wipe state.
```

- [ ] **Step 2: Add an Import-Module guard to the script itself**

In `Scripts/AutopilotReadiness/Report-AutopilotReadinessToHudu.ps1`, after the `#region --- Init ---` block, add:

```powershell
#region --- Module Check ---
if (-not (Get-Module -Name HuduAPI -ListAvailable)) {
    Write-Host "ERROR: HuduAPI module is not installed. Run: Install-Module HuduAPI" -ForegroundColor Red
    exit 1
}
#endregion
```

- [ ] **Step 3: Syntax check**

```powershell
pwsh -NoProfile -Command "
  \$errors = @()
  \$null = [System.Management.Automation.Language.Parser]::ParseFile('/Users/nsol/GithubRepos/AshesToAutopilot/Scripts/AutopilotReadiness/Report-AutopilotReadinessToHudu.ps1', [ref]\$null, [ref]\$errors)
  if (\$errors) { \$errors | ForEach-Object { Write-Error \$_.Message }; exit 1 }
  Write-Host 'Syntax OK'
"
```

Expected: `Syntax OK`

- [ ] **Step 4: Commit**

```bash
git add README.md Scripts/AutopilotReadiness/Report-AutopilotReadinessToHudu.ps1
git commit -m "docs: document Report-AutopilotReadinessToHudu.ps1 as post-run reporting script (CC-07)"
```

---

## Completion Checklist

Use this table to track overall progress across sessions:

| Task | Audit Ref | Severity | Status |
|------|-----------|----------|--------|
| 1: Register-AutopilotDevice Success=false on upload fail | F30-01 | CRITICAL | ⬜ |
| 2: Get-StepVerdict case for Register-AutopilotDevice | CC-11 | CRITICAL | ⬜ |
| 3: OneDrive sync verdict mismatch in Get-PreWipeSummary | CC-08/F12-01 | CRITICAL | ⬜ |
| 4: BitLockerEscrow allEscrowed edge case | F23-02/CC-12 | CRITICAL | ⬜ |
| 5: Get-DownloadsSize PS 5.1 ?? operator | F2-01 | HIGH | ⬜ |
| 6: Get-Printers PS 5.1 ?? operators | F4-01 | HIGH | ⬜ |
| 7: Update-Drivers PS 5.1 ?? operator | F26-01 | HIGH | ⬜ |
| 8: Update-Bios PS 5.1 ?? operator | F27-01 | HIGH | ⬜ |
| 9: Find-UnbackedData empty catch | F1-01/CC-12 | HIGH | ⬜ |
| 10: Get-StorageMode two empty catches | F13-01/CC-12 | HIGH | ⬜ |
| 11: Initialize-Toolkit adoption — DataCollection | CC-02 | MEDIUM | ⬜ |
| 12: Initialize-Toolkit adoption — ConfigurationChecks | CC-02 | MEDIUM | ⬜ |
| 13: Initialize-Toolkit adoption — ConfigurationChanges | CC-02 | MEDIUM | ⬜ |
| 14: Initialize-Toolkit adoption — AutopilotReadiness | CC-02 | MEDIUM | ⬜ |
| 15: Dell tool path adoption — ConfigurationChecks | CC-03 | MEDIUM | ⬜ |
| 16: Dell tool path adoption — ConfigurationChanges | CC-03 | MEDIUM | ⬜ |
| 17: Get-ActiveUserProfile adoption — DataCollection | CC-10 | MEDIUM | ⬜ |
| 18: Get-ActiveUserProfile adoption — Checks/Changes | CC-10 | MEDIUM | ⬜ |
| 19: Add exit 0 to 24 scripts | CC-09 | LOW | ⬜ |
| 20: Normalize JSON output filenames | CC-05 | LOW | ⬜ |
| 21: Fix README folder misclassification | CC-04 | LOW | ⬜ |
| 22: Document Report-AutopilotReadinessToHudu | CC-07 | LOW | ⬜ |

---

*Plan written 2026-05-07. Source audit: `docs/audit/script-audit-2026-05-05.md`.*
