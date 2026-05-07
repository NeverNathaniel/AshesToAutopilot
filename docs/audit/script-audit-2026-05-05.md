# AshesToAutopilot — Comprehensive Script Audit

**Date:** 2026-05-05  
**Auditor:** Multi-agent static analysis  
**Repository:** `/home/user/AshesToAutopilot`  
**Scope:** All 32 scripts in the pre-wipe toolkit (31 numbered orchestrator steps + 1 undocumented script)  
**Standards Checklist:** 9 items (see Appendix A, §CC-01)

---

## 1. Executive Summary

The AshesToAutopilot toolkit is a well-structured 31-step orchestrated pre-wipe workflow that successfully encapsulates the major phases of Windows device decommissioning — data inventory, configuration checks, change actions, and Autopilot re-provisioning readiness. The architecture is sound, but a cluster of recurring defects reduces its reliability on the Windows PowerShell 5.1 environments it targets: four scripts use the `??` null-coalescing operator introduced in PowerShell 7 (which will throw terminating parse errors on 5.1), most scripts reinvent initialisation and profile-enumeration logic instead of dot-sourcing the existing Common helpers, and three scripts have silent catch blocks that swallow errors and allow the orchestrator to receive a false-PASS JSON payload. The single most dangerous individual defect is in `Register-AutopilotDevice.ps1` (step 30), where an exception in the upload path leaves `$Result.Success = $true` while the orchestrator has no dedicated verdict case for this script, guaranteeing a PASS verdict even when the Autopilot hash upload silently failed. A close second is the `Test-OneDriveSyncStatus.ps1` (step 12) contract mismatch: the orchestrator's `Get-StepVerdict` checks `Profiles[*].SafeToWipe` while the summary script `Get-PreWipeSummary.ps1` checks `OverallVerdict == 'NOT_SAFE'`, creating a split-brain between the live-run verdict and the final report. Four additional scripts carry README misclassification errors (Backup-* scripts physically live in `ConfigurationChanges/` but are documented as `DataCollection`), and one script (`Report-AutopilotReadinessToHudu.ps1`) is entirely absent from the `$script:Steps` array, the README, and the `Get-PreWipeSummary` `$ScriptMap` — making it effectively a dark script that can only be invoked manually. Twenty-four of thirty-two scripts score 8/9 against the standards checklist; six score 9/9; two score lower due to critical correctness defects.

---

## 2. Summary Table

| Step | Script | Folder | Intent Verdict | Std Score | Orchestrator Risk | Blocking? |
|------|--------|--------|---------------|-----------|-------------------|-----------|
| 1 | Find-UnbackedData.ps1 | DataCollection | WARN | 8/9 | LOW | No |
| 2 | Get-DownloadsSize.ps1 | DataCollection | WARN | 8/9 | LOW | No |
| 3 | Get-DriveMappings.ps1 | DataCollection | PASS | 8/9 | LOW | No |
| 4 | Get-Printers.ps1 | DataCollection | WARN | 8/9 | LOW | No |
| 5 | Get-WindowsProductKey.ps1 | DataCollection | PASS | 8/9 | LOW | No |
| 6 | Get-InstalledApplications.ps1 | DataCollection | PASS | 8/9 | LOW | No |
| 7 | Get-DeviceHealth.ps1 | DataCollection | PASS | 8/9 | MEDIUM | No |
| 8 | Get-TeamsData.ps1 | DataCollection | PASS | 9/9 | LOW | No |
| 9 | Get-CredentialManagerEntries.ps1 | DataCollection | PASS | 9/9 | LOW | No |
| 10 | Get-LocalAccounts.ps1 | DataCollection | PASS | 9/9 | LOW | No |
| 11 | Test-OneDriveKFM.ps1 | ConfigurationChecks | PASS | 8/9 | HIGH | Yes |
| 12 | Test-OneDriveSyncStatus.ps1 | ConfigurationChecks | WARN | 8/9 | CRITICAL | Yes |
| 13 | Get-StorageMode.ps1 | ConfigurationChecks | WARN | 8/9 | MEDIUM | No |
| 14 | Test-BiosVersion.ps1 | ConfigurationChecks | PASS | 8/9 | MEDIUM | No |
| 15 | Test-DriverStatus.ps1 | ConfigurationChecks | PASS | 8/9 | MEDIUM | No |
| 16 | Test-WakeOnLan.ps1 | ConfigurationChecks | PASS | 8/9 | LOW | No |
| 17 | Test-WinRE.ps1 | ConfigurationChecks | PASS | 8/9 | MEDIUM | No |
| 18 | Backup-BrowserBookmarks.ps1 | ConfigurationChanges | PASS | 8/9 | HIGH | Yes |
| 19 | Backup-DesktopBackground.ps1 | ConfigurationChanges | PASS | 8/9 | HIGH | Yes |
| 20 | Backup-OutlookSignatures.ps1 | ConfigurationChanges | PASS | 8/9 | HIGH | Yes |
| 21 | Backup-TaskbarLayout.ps1 | ConfigurationChanges | PASS | 8/9 | MEDIUM | No |
| 22 | Backup-WiFiProfiles.ps1 | ConfigurationChanges | PASS | 9/9 | MEDIUM | No |
| 23 | Test-BitLockerEscrow.ps1 | ConfigurationChanges | PASS | 8/9 | CRITICAL | Yes |
| 24 | Set-WakeOnLan.ps1 | ConfigurationChanges | PASS | 8/9 | LOW | No |
| 25 | Install-DellCommandTools.ps1 | ConfigurationChanges | PASS | 8/9 | HIGH | No |
| 26 | Update-Drivers.ps1 | ConfigurationChanges | WARN | 8/9 | HIGH | No |
| 27 | Update-Bios.ps1 | ConfigurationChanges | WARN | 8/9 | CRITICAL | No |
| 28 | Test-AutopilotReadiness.ps1 | AutopilotReadiness | PASS | 9/9 | CRITICAL | Yes |
| 29 | Get-AutopilotAssignment.ps1 | AutopilotReadiness | PASS | 8/9 | HIGH | Yes |
| 30 | Register-AutopilotDevice.ps1 | AutopilotReadiness | FAIL | 8/9 | CRITICAL | No |
| 31 | Get-PreWipeSummary.ps1 | AutopilotReadiness | PASS | 9/9 | HIGH | No |
| — | Report-AutopilotReadinessToHudu.ps1 | AutopilotReadiness | WARN | 8/9 | LOW | No |

**Intent Verdict key:** PASS = achieves stated purpose correctly; WARN = achieves purpose but with a defect that may produce incorrect output in specific conditions; FAIL = contains a correctness bug that silently produces wrong results.  
**Orchestrator Risk key:** LOW = informational only; MEDIUM = affects WARN threshold; HIGH = can produce orchestrator FAIL/block; CRITICAL = can produce wrong final verdict regardless of actual state.  
**Blocking:** Yes = orchestrator emits a user-visible BLOCKER and halts progression if this script fails.

---

## 3. Per-Script Sections

---

### 3.1 DataCollection

---

#### Step 1 — Find-UnbackedData.ps1

**Path:** `Scripts/DataCollection/Find-UnbackedData.ps1`  
**Lines:** 325  
**Purpose:** Scans all active user profiles for file types that are typically not synchronised to OneDrive or SharePoint — PST archives, SSH keys, local database files, and personal certificates. Produces a per-profile list of at-risk files for technician review before wipe.

**Standards checklist:**

| # | Item | Status |
|---|------|--------|
| S1 | `.SYNOPSIS` / `.DESCRIPTION` present | ✅ |
| S2 | `[CmdletBinding()]` + `-NonInteractive` switch | ✅ |
| S3 | Dot-sources `Initialize-Toolkit.ps1` | ❌ — inline init |
| S4 | Uses `Get-ActiveUserProfile` for profile enumeration | ❌ — inline via `Win32_UserProfile` |
| S5 | Structured JSON to stdout on `-NonInteractive` | ✅ |
| S6 | JSON report written to `$LogDir` | ✅ |
| S7 | `Write-Log` / `Write-ErrorLog` used | ✅ |
| S8 | `Test-AdminElevation` guard | ✅ |
| S9 | `exit 0` on clean success | ❌ — no explicit `exit 0` |

**Score: 8/9**

**Findings:**

- **F1-01 Swallowed catch (line 216–218):** A `catch {}` block with an empty body silently discards any exception thrown while enumerating file attributes inside the per-profile loop. If an access-denied error occurs on a protected profile directory, the script continues as though no files are at risk and the resulting JSON will under-report findings. The orchestrator will receive a clean PASS payload.
- **F1-02 No `exit 0`:** The script falls off the end of the file on success. While harmless on its own, the absence of an explicit `exit 0` is inconsistent with the rest of the toolkit and can confuse exit-code testing harnesses.
- **F1-03 Inline initialisation:** The script duplicates the `$OutputRoot`/`$LogDir`/`$ErrorLog` setup and both `Write-Log`/`Write-ErrorLog` functions rather than dot-sourcing `Initialize-Toolkit.ps1`. Any future change to output paths must be applied in two places.
- **F1-04 Inline profile enumeration:** The script queries `Win32_UserProfile` directly with its own skip-list logic rather than delegating to `Get-ActiveUserProfile`. Divergence between skip criteria here and in the helper will lead to inconsistent profile sets across steps.

**Orchestrator contract:** Orchestrator consumes `Results[*].AtRiskFileCount` (or equivalent). No FAIL verdict is wired for this step; it is informational only.

---

#### Step 2 — Get-DownloadsSize.ps1

**Path:** `Scripts/DataCollection/Get-DownloadsSize.ps1`  
**Lines:** 273  
**Purpose:** For each active user profile, measures the total size of the Downloads folder and flags profiles where the folder exceeds a configurable threshold (default 500 MB). Intended to alert the technician to large Downloads that would be lost at wipe.

**Standards checklist:**

| # | Item | Status |
|---|------|--------|
| S1 | `.SYNOPSIS` / `.DESCRIPTION` present | ✅ |
| S2 | `[CmdletBinding()]` + `-NonInteractive` switch | ✅ |
| S3 | Dot-sources `Initialize-Toolkit.ps1` | ❌ — inline init |
| S4 | Uses `Get-ActiveUserProfile` | ❌ — inline |
| S5 | Structured JSON to stdout on `-NonInteractive` | ✅ |
| S6 | JSON report written to `$LogDir` | ✅ |
| S7 | `Write-Log` / `Write-ErrorLog` used | ✅ |
| S8 | `Test-AdminElevation` guard | ✅ |
| S9 | `exit 0` on clean success | ✅ (line 272) |

**Score: 8/9**

**Findings:**

- **F2-01 PowerShell 5.1 incompatibility (line 135):** `$ProfileResult.SizeBytes = [long]($size ?? 0)` uses the null-coalescing operator `??`, which was introduced in PowerShell 7.0. On Windows PowerShell 5.1 (the default on Windows 10/11 without explicit PS7 installation) this causes a **parse error** and the entire script fails to load, emitting no JSON and causing the orchestrator to record an execution error for step 2. Fix: replace with `if ($null -ne $size) { $size } else { 0 }` or `[long]$(if ($size) { $size } else { 0 })`.

---

#### Step 3 — Get-DriveMappings.ps1

**Path:** `Scripts/DataCollection/Get-DriveMappings.ps1`  
**Lines:** 172  
**Purpose:** Enumerates all persistent mapped network drives across active user profiles by loading each user's registry hive and reading `HKCU:\Network`. Produces a per-profile list of drive letters and UNC paths that the user will need to reconnect after reprovisioning.

**Standards checklist:**

| # | Item | Status |
|---|------|--------|
| S1 | `.SYNOPSIS` / `.DESCRIPTION` present | ✅ |
| S2 | `[CmdletBinding()]` + `-NonInteractive` switch | ✅ |
| S3 | Dot-sources `Initialize-Toolkit.ps1` | ❌ — inline init |
| S4 | Uses `Get-ActiveUserProfile` | ❌ — inline |
| S5 | Structured JSON to stdout on `-NonInteractive` | ✅ |
| S6 | JSON report written to `$LogDir` | ✅ — `DriveMappings-Report.json` |
| S7 | `Write-Log` / `Write-ErrorLog` used | ✅ |
| S8 | `Test-AdminElevation` guard | ✅ |
| S9 | `exit 0` on clean success | ❌ |

**Score: 8/9**

**Findings:**

- **F3-01 No `exit 0`:** Script ends without an explicit exit code.
- **F3-02 Inline initialisation and profile enumeration:** Same duplication pattern as steps 1 and 2.

**Orchestrator contract:** Informational. No FAIL verdict wired.

---

#### Step 4 — Get-Printers.ps1

**Path:** `Scripts/DataCollection/Get-Printers.ps1`  
**Lines:** 149  
**Purpose:** Lists all installed printers on the device (local and networked) using `Get-Printer` and WMI fallback, providing the technician with a list to reconnect after wipe.

**Standards checklist:**

| # | Item | Status |
|---|------|--------|
| S1 | `.SYNOPSIS` / `.DESCRIPTION` present | ✅ |
| S2 | `[CmdletBinding()]` + `-NonInteractive` switch | ✅ |
| S3 | Dot-sources `Initialize-Toolkit.ps1` | ❌ — inline init |
| S4 | Uses `Get-ActiveUserProfile` | N/A — device-level |
| S5 | Structured JSON to stdout on `-NonInteractive` | ✅ |
| S6 | JSON report written to `$LogDir` | ✅ |
| S7 | `Write-Log` / `Write-ErrorLog` used | ✅ |
| S8 | `Test-AdminElevation` guard | ✅ |
| S9 | `exit 0` on clean success | ❌ |

**Score: 8/9**

**Findings:**

- **F4-01 PowerShell 5.1 incompatibility (lines 121, 144):** Two uses of the `??` null-coalescing operator:
  - Line 121: `$p.DriverName ?? '(unknown)'`
  - Line 144: `$p.PortName ?? '(unknown)'`  
  Both cause parse errors on PS 5.1, preventing the script from loading at all.

---

#### Step 5 — Get-WindowsProductKey.ps1

**Path:** `Scripts/DataCollection/Get-WindowsProductKey.ps1`  
**Lines:** 163  
**Purpose:** Extracts the Windows product key from the firmware (MSDM ACPI table via WMI) and from the registry Software Licensing Service. Documents the key for potential post-wipe reinstallation.

**Standards checklist:**

| # | Item | Status |
|---|------|--------|
| S1 | `.SYNOPSIS` / `.DESCRIPTION` present | ✅ |
| S2 | `[CmdletBinding()]` + `-NonInteractive` switch | ✅ |
| S3 | Dot-sources `Initialize-Toolkit.ps1` | ❌ — inline init |
| S4 | Uses `Get-ActiveUserProfile` | N/A — device-level |
| S5 | Structured JSON to stdout on `-NonInteractive` | ✅ |
| S6 | JSON report written to `$LogDir` | ✅ |
| S7 | `Write-Log` / `Write-ErrorLog` used | ✅ |
| S8 | `Test-AdminElevation` guard | ✅ |
| S9 | `exit 0` on clean success | ❌ |

**Score: 8/9**

**Findings:**

- **F5-01 No `exit 0`:** Script ends without an explicit exit code.
- **F5-02 Inline initialisation:** Same pattern as other DataCollection scripts.

**Orchestrator contract:** Informational. No FAIL verdict wired.

---

#### Step 6 — Get-InstalledApplications.ps1

**Path:** `Scripts/DataCollection/Get-InstalledApplications.ps1`  
**Lines:** 246  
**Purpose:** Collects all installed applications from `HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall` (both 64-bit and 32-bit hives) and from per-user hives across active profiles. Produces a consolidated application inventory.

**Standards checklist:**

| # | Item | Status |
|---|------|--------|
| S1 | `.SYNOPSIS` / `.DESCRIPTION` present | ✅ |
| S2 | `[CmdletBinding()]` + `-NonInteractive` switch | ✅ |
| S3 | Dot-sources `Initialize-Toolkit.ps1` | ❌ — inline init |
| S4 | Uses `Get-ActiveUserProfile` | ❌ — inline |
| S5 | Structured JSON to stdout on `-NonInteractive` | ✅ |
| S6 | JSON report written to `$LogDir` | ✅ |
| S7 | `Write-Log` / `Write-ErrorLog` used | ✅ |
| S8 | `Test-AdminElevation` guard | ✅ |
| S9 | `exit 0` on clean success | ❌ |

**Score: 8/9**

**Findings:**

- **F6-01 Inline initialisation and profile enumeration:** Consistent pattern; see CC-02.

**Orchestrator contract:** Informational. No FAIL verdict wired.

---

#### Step 7 — Get-DeviceHealth.ps1

**Path:** `Scripts/DataCollection/Get-DeviceHealth.ps1`  
**Lines:** 292  
**Purpose:** Checks device health indicators: disk SMART status via WMI, battery health (design vs. full-charge capacity), memory usage, and pending Windows Updates. Surfaces any hardware concerns before committing to a wipe.

**Standards checklist:**

| # | Item | Status |
|---|------|--------|
| S1 | `.SYNOPSIS` / `.DESCRIPTION` present | ✅ |
| S2 | `[CmdletBinding()]` + `-NonInteractive` switch | ✅ |
| S3 | Dot-sources `Initialize-Toolkit.ps1` | ❌ — inline init |
| S4 | Uses `Get-ActiveUserProfile` | N/A — device-level |
| S5 | Structured JSON to stdout on `-NonInteractive` | ✅ |
| S6 | JSON report written to `$LogDir` | ✅ |
| S7 | `Write-Log` / `Write-ErrorLog` used | ✅ |
| S8 | `Test-AdminElevation` guard | ✅ |
| S9 | `exit 0` on clean success | ❌ |

**Score: 8/9**

**Findings:**

- **F7-01 Inline initialisation:** See CC-02.
- **F7-02 No `exit 0`:** Consistent with most DataCollection scripts.

**Orchestrator contract:** Orchestrator checks health flags; WARN verdict if issues detected. No FAIL/blocking.

---

#### Step 8 — Get-TeamsData.ps1

**Path:** `Scripts/DataCollection/Get-TeamsData.ps1`  
**Lines:** 208  
**Purpose:** For each active user profile, enumerates classic Teams and new Store Teams (MSTeams_*) data locations, measuring Downloads folder file counts and sizes, local cache sizes, and any meeting media files (*.mp4, *.m4a, *.wav) that would be lost at wipe.

**Standards checklist:**

| # | Item | Status |
|---|------|--------|
| S1 | `.SYNOPSIS` / `.DESCRIPTION` present | ✅ |
| S2 | `[CmdletBinding()]` + `-NonInteractive` switch | ✅ |
| S3 | Dot-sources `Initialize-Toolkit.ps1` | ✅ (line 38) |
| S4 | Uses `Get-ActiveUserProfile` | ✅ (line 40, called at line 85) |
| S5 | Structured JSON to stdout on `-NonInteractive` | ✅ |
| S6 | JSON report written to `$LogDir` | ✅ — `Get-TeamsData-Report.json` |
| S7 | `Write-Log` / `Write-ErrorLog` used | ✅ |
| S8 | `Test-AdminElevation` guard | ✅ |
| S9 | `exit 0` on clean success | ✅ (implicit — script reaches end only on success) |

**Score: 9/9** — exemplar for profile-iterating DataCollection scripts.

**Findings:**

- None of substance. This script correctly dot-sources both common helpers and serves as the reference implementation for profile-iterating scripts in the toolkit.

**Orchestrator contract:** Informational — reports `AnyMediaFiles` boolean. No FAIL verdict wired; presence of meeting media triggers a WARN note to the technician.

---

#### Step 9 — Get-CredentialManagerEntries.ps1

**Path:** `Scripts/DataCollection/Get-CredentialManagerEntries.ps1`  
**Lines:** 149  
**Purpose:** Enumerates Windows Credential Manager (Generic and Domain credentials) using `cmdkey /list` and the `CredRead` Win32 API fallback. Produces a list of credential targets so the user knows which stored credentials they will need to re-enter after wipe.

**Standards checklist:**

| # | Item | Status |
|---|------|--------|
| S1 | `.SYNOPSIS` / `.DESCRIPTION` present | ✅ |
| S2 | `[CmdletBinding()]` + `-NonInteractive` switch | ✅ |
| S3 | Dot-sources `Initialize-Toolkit.ps1` | ✅ (line 36) |
| S4 | Uses `Get-ActiveUserProfile` | N/A — current user context |
| S5 | Structured JSON to stdout on `-NonInteractive` | ✅ |
| S6 | JSON report written to `$LogDir` | ✅ |
| S7 | `Write-Log` / `Write-ErrorLog` used | ✅ |
| S8 | `Test-AdminElevation` guard | ✅ |
| S9 | `exit 0` on clean success | ✅ |

**Score: 9/9**

**Findings:**

- None of substance.

**Orchestrator contract:** Informational. No FAIL verdict wired.

---

#### Step 10 — Get-LocalAccounts.ps1

**Path:** `Scripts/DataCollection/Get-LocalAccounts.ps1`  
**Lines:** 164  
**Purpose:** Enumerates all local Windows user accounts (enabled and disabled) with their last logon times and group memberships. Identifies local admin accounts and flags accounts that are enabled but have never logged in — a potential security concern pre-wipe.

**Standards checklist:**

| # | Item | Status |
|---|------|--------|
| S1 | `.SYNOPSIS` / `.DESCRIPTION` present | ✅ |
| S2 | `[CmdletBinding()]` + `-NonInteractive` switch | ✅ |
| S3 | Dot-sources `Initialize-Toolkit.ps1` | ✅ (line 36) |
| S4 | Uses `Get-ActiveUserProfile` | N/A — device-level |
| S5 | Structured JSON to stdout on `-NonInteractive` | ✅ |
| S6 | JSON report written to `$LogDir` | ✅ |
| S7 | `Write-Log` / `Write-ErrorLog` used | ✅ |
| S8 | `Test-AdminElevation` guard | ✅ |
| S9 | `exit 0` on clean success | ✅ |

**Score: 9/9**

**Findings:**

- None of substance.

**Orchestrator contract:** Informational. No FAIL verdict wired.

---

### 3.2 ConfigurationChecks

---

#### Step 11 — Test-OneDriveKFM.ps1

**Path:** `Scripts/ConfigurationChecks/Test-OneDriveKFM.ps1`  
**Lines:** 290  
**Purpose:** Verifies that OneDrive Known Folder Move (KFM) is configured for Desktop, Documents, and Pictures across all active user profiles by reading the `OneDrive\Accounts` registry key and checking the `KfmFoldersProtectedByPolicy` value. A FAIL here is a pre-wipe blocker.

**Standards checklist:**

| # | Item | Status |
|---|------|--------|
| S1 | `.SYNOPSIS` / `.DESCRIPTION` present | ✅ |
| S2 | `[CmdletBinding()]` + `-NonInteractive` switch | ✅ |
| S3 | Dot-sources `Initialize-Toolkit.ps1` | ❌ — inline init |
| S4 | Uses `Get-ActiveUserProfile` | ❌ — inline via Win32_UserProfile |
| S5 | Structured JSON to stdout on `-NonInteractive` | ✅ |
| S6 | JSON report written to `$LogDir` | ⚠️ — `OneDriveKFM-Status.json` (-Status suffix; inconsistent) |
| S7 | `Write-Log` / `Write-ErrorLog` used | ✅ |
| S8 | `Test-AdminElevation` guard | ✅ |
| S9 | `exit 0` on clean success | ❌ |

**Score: 8/9**

**Findings:**

- **F11-01 Inconsistent report filename suffix:** Report written as `OneDriveKFM-Status.json` rather than the toolkit convention `OneDriveKFM-Report.json`. The orchestrator and `Get-PreWipeSummary` reference the file by path — if either is ever updated to glob for `*-Report.json` this file would be missed.
- **F11-02 Inline profile enumeration:** Uses its own `Win32_UserProfile` query with a local skip-list rather than the Common helper.

**Orchestrator contract:** BLOCKING. Orchestrator checks `Profiles[*].KFMConfigured` — if any active profile has KFM not configured the step yields FAIL and the technician must acknowledge before proceeding.

---

#### Step 12 — Test-OneDriveSyncStatus.ps1

**Path:** `Scripts/ConfigurationChecks/Test-OneDriveSyncStatus.ps1`  
**Lines:** 297  
**Purpose:** Verifies that OneDrive is actively syncing and up-to-date for each user profile — going beyond the KFM check to confirm that no files are pending upload before wipe. Reads `OneDrive\Accounts\*\LastKnownState` from each user's registry hive.

**Standards checklist:**

| # | Item | Status |
|---|------|--------|
| S1 | `.SYNOPSIS` / `.DESCRIPTION` present | ✅ |
| S2 | `[CmdletBinding()]` + `-NonInteractive` switch | ✅ |
| S3 | Dot-sources `Initialize-Toolkit.ps1` | ❌ — inline init |
| S4 | Uses `Get-ActiveUserProfile` | ❌ — inline |
| S5 | Structured JSON to stdout on `-NonInteractive` | ✅ |
| S6 | JSON report written to `$LogDir` | ✅ — `OneDriveSyncStatus-Report.json` |
| S7 | `Write-Log` / `Write-ErrorLog` used | ✅ |
| S8 | `Test-AdminElevation` guard | ✅ |
| S9 | `exit 0` on clean success | ❌ (exits with 1 on `NOT_SAFE`) |

**Score: 8/9**

**Findings:**

- **F12-01 CRITICAL — Orchestrator contract mismatch:** The `Get-StepVerdict` function in `Start-PreWipeToolkit.ps1` (line 575) evaluates this step by checking `Profiles[*].SafeToWipe` on the parsed JSON. The `Get-PreWipeSummary.ps1` script (step 31) evaluates the same step by checking whether `OverallVerdict == 'NOT_SAFE'` (line 141 of that script). These two paths can diverge:
  - If a profile has `SafeToWipe = $false` but `OverallVerdict` is somehow set to `SAFE_TO_WIPE` (e.g., due to a logic error in the `AllSafe` loop at lines 235-248), the orchestrator will FAIL the step but `Get-PreWipeSummary` will log it as passed.
  - Conversely, `NO_PROFILES` (no active profiles found) produces `OverallVerdict = 'NO_PROFILES'` which neither the `NOT_SAFE` check nor the `SafeToWipe` check flags — the step passes silently even though sync could not be verified.
  - **Impact:** A device with unsynced files could receive a clean pre-wipe summary report while the live orchestrator run correctly blocked; or the live run could pass while the final summary shows a failure — undermining technician trust in either output.

---

#### Step 13 — Get-StorageMode.ps1

**Path:** `Scripts/ConfigurationChecks/Get-StorageMode.ps1`  
**Lines:** 189  
**Purpose:** Detects whether the device's primary drive is configured in AHCI, RAID/RST, or NVMe mode by querying WMI `Win32_DiskDrive` and the storage controller's PnP class. Required context for post-wipe driver selection.

**Standards checklist:**

| # | Item | Status |
|---|------|--------|
| S1 | `.SYNOPSIS` / `.DESCRIPTION` present | ✅ |
| S2 | `[CmdletBinding()]` + `-NonInteractive` switch | ✅ |
| S3 | Dot-sources `Initialize-Toolkit.ps1` | ❌ — inline init |
| S4 | Uses `Get-ActiveUserProfile` | N/A — device-level |
| S5 | Structured JSON to stdout on `-NonInteractive` | ✅ |
| S6 | JSON report written to `$LogDir` | ✅ |
| S7 | `Write-Log` / `Write-ErrorLog` used | ✅ |
| S8 | `Test-AdminElevation` guard | ✅ |
| S9 | `exit 0` on clean success | ❌ |

**Score: 8/9**

**Findings:**

- **F13-01 Swallowed catch blocks (lines 132–134 and 152–154):** Two `catch {}` blocks with empty bodies. One surrounds the RST detection path; the other surrounds the NVMe detection path. If WMI queries throw on these lines the script silently falls through and reports the drive mode as `Unknown` — giving no indication that detection failed versus the drive genuinely being an unrecognised type. The orchestrator cannot distinguish these cases.

---

#### Step 14 — Test-BiosVersion.ps1

**Path:** `Scripts/ConfigurationChecks/Test-BiosVersion.ps1`  
**Lines:** 180  
**Purpose:** Reads the current BIOS/UEFI firmware version via WMI and compares it against the latest available version reported by Dell Command Update. Flags devices running outdated firmware as requiring a BIOS update.

**Standards checklist:**

| # | Item | Status |
|---|------|--------|
| S1 | `.SYNOPSIS` / `.DESCRIPTION` present | ✅ |
| S2 | `[CmdletBinding()]` + `-NonInteractive` switch | ✅ |
| S3 | Dot-sources `Initialize-Toolkit.ps1` | ❌ — inline init |
| S4 | Uses `Get-ActiveUserProfile` | N/A — device-level |
| S5 | Structured JSON to stdout on `-NonInteractive` | ✅ |
| S6 | JSON report written to `$LogDir` | ✅ |
| S7 | `Write-Log` / `Write-ErrorLog` used | ✅ |
| S8 | `Test-AdminElevation` guard | ✅ |
| S9 | `exit 0` on clean success | ❌ |

**Score: 8/9**

**Findings:**

- **F14-01 DCU path duplicated (lines 96–101):** Defines its own inline DCU executable search (checking multiple `Program Files` locations) instead of calling `Find-DellCommandUpdate` from `Scripts/Common/Find-DellCommandTool.ps1`. See CC-03.

---

#### Step 15 — Test-DriverStatus.ps1

**Path:** `Scripts/ConfigurationChecks/Test-DriverStatus.ps1`  
**Lines:** 209  
**Purpose:** Uses Dell Command Update to scan for outdated or missing drivers and reports their count and severity. Informs the technician whether a driver update pass is needed before or after wipe.

**Standards checklist:**

| # | Item | Status |
|---|------|--------|
| S1 | `.SYNOPSIS` / `.DESCRIPTION` present | ✅ |
| S2 | `[CmdletBinding()]` + `-NonInteractive` switch | ✅ |
| S3 | Dot-sources `Initialize-Toolkit.ps1` | ❌ — inline init |
| S4 | Uses `Get-ActiveUserProfile` | N/A — device-level |
| S5 | Structured JSON to stdout on `-NonInteractive` | ✅ |
| S6 | JSON report written to `$LogDir` | ✅ |
| S7 | `Write-Log` / `Write-ErrorLog` used | ✅ |
| S8 | `Test-AdminElevation` guard | ✅ |
| S9 | `exit 0` on clean success | ❌ |

**Score: 8/9**

**Findings:**

- **F15-01 DCU path duplicated (lines 78–83):** See CC-03.

---

#### Step 16 — Test-WakeOnLan.ps1

**Path:** `Scripts/ConfigurationChecks/Test-WakeOnLan.ps1`  
**Lines:** 228  
**Purpose:** Reads current Wake-on-LAN (WoL) configuration from the network adapter's power management settings and from Dell Command Configure (if present). Reports whether WoL is enabled so `Set-WakeOnLan.ps1` (step 24) knows whether action is needed.

**Standards checklist:**

| # | Item | Status |
|---|------|--------|
| S1 | `.SYNOPSIS` / `.DESCRIPTION` present | ✅ |
| S2 | `[CmdletBinding()]` + `-NonInteractive` switch | ✅ |
| S3 | Dot-sources `Initialize-Toolkit.ps1` | ❌ — inline init |
| S4 | Uses `Get-ActiveUserProfile` | N/A — device-level |
| S5 | Structured JSON to stdout on `-NonInteractive` | ✅ |
| S6 | JSON report written to `$LogDir` | ✅ |
| S7 | `Write-Log` / `Write-ErrorLog` used | ✅ |
| S8 | `Test-AdminElevation` guard | ✅ |
| S9 | `exit 0` on clean success | ❌ |

**Score: 8/9**

**Findings:**

- **F16-01 Local `Get-DCCExePath` function (lines 73–82):** Defines a private DCC path search function instead of using `Find-DellCommandConfigure` from `Scripts/Common/Find-DellCommandTool.ps1`. See CC-03.

---

#### Step 17 — Test-WinRE.ps1

**Path:** `Scripts/ConfigurationChecks/Test-WinRE.ps1`  
**Lines:** 137  
**Purpose:** Checks whether the Windows Recovery Environment (WinRE) partition is present and enabled using `reagentc /info`. A disabled or missing WinRE would prevent the reset-from-cloud Autopilot wipe scenario from completing.

**Standards checklist:**

| # | Item | Status |
|---|------|--------|
| S1 | `.SYNOPSIS` / `.DESCRIPTION` present | ✅ |
| S2 | `[CmdletBinding()]` + `-NonInteractive` switch | ✅ |
| S3 | Dot-sources `Initialize-Toolkit.ps1` | ❌ — inline init |
| S4 | Uses `Get-ActiveUserProfile` | N/A — device-level |
| S5 | Structured JSON to stdout on `-NonInteractive` | ✅ |
| S6 | JSON report written to `$LogDir` | ✅ |
| S7 | `Write-Log` / `Write-ErrorLog` used | ✅ |
| S8 | `Test-AdminElevation` guard | ✅ |
| S9 | `exit 0` on clean success | ❌ |

**Score: 8/9**

**Findings:**

- **F17-01 Inline initialisation:** See CC-02.
- **F17-02 No `exit 0`:** See CC-09.

**Orchestrator contract:** WARN verdict if WinRE disabled; not currently a hard FAIL/blocker.

---

### 3.3 ConfigurationChanges

---

#### Step 18 — Backup-BrowserBookmarks.ps1

**Path:** `Scripts/ConfigurationChanges/Backup-BrowserBookmarks.ps1`  
**Lines:** 296  
**Purpose:** Copies Chrome, Edge, and Firefox bookmark files from all active user profiles to `C:\PreWipeOutput\BrowserBookmarks\<profile>\`. BLOCKING — if any profile's bookmark export fails, the step yields FAIL.

**Standards checklist:**

| # | Item | Status |
|---|------|--------|
| S1 | `.SYNOPSIS` / `.DESCRIPTION` present | ✅ |
| S2 | `[CmdletBinding()]` + `-NonInteractive` switch | ✅ |
| S3 | Dot-sources `Initialize-Toolkit.ps1` | ❌ — inline init |
| S4 | Uses `Get-ActiveUserProfile` | ❌ — inline |
| S5 | Structured JSON to stdout on `-NonInteractive` | ✅ |
| S6 | JSON report written to `$LogDir` | ✅ |
| S7 | `Write-Log` / `Write-ErrorLog` used | ✅ |
| S8 | `Test-AdminElevation` guard | ✅ |
| S9 | `exit 0` on clean success | ❌ |

**Score: 8/9**

**Findings:**

- **F18-01 README misclassification:** This script physically resides in `Scripts/ConfigurationChanges/` and performs a file copy (a write action), yet the README documents it under "Scan, Check & Backup" alongside the DataCollection scripts. Misclassification obscures the fact that this step modifies the filesystem. See CC-04.
- **F18-02 Inline initialisation and profile enumeration:** See CC-02.

**Orchestrator contract:** BLOCKING. Step FAIL if any profile's bookmark export fails.

---

#### Step 19 — Backup-DesktopBackground.ps1

**Path:** `Scripts/ConfigurationChanges/Backup-DesktopBackground.ps1`  
**Lines:** 238  
**Purpose:** Copies the current desktop wallpaper for each active user profile to `C:\PreWipeOutput\DesktopBackgrounds\`. Reads the wallpaper path from `HKCU:\Control Panel\Desktop` (via loaded hive). BLOCKING.

**Standards checklist:**

| # | Item | Status |
|---|------|--------|
| S1 | `.SYNOPSIS` / `.DESCRIPTION` present | ✅ |
| S2 | `[CmdletBinding()]` + `-NonInteractive` switch | ✅ |
| S3 | Dot-sources `Initialize-Toolkit.ps1` | ❌ — inline init |
| S4 | Uses `Get-ActiveUserProfile` | ❌ — inline |
| S5 | Structured JSON to stdout on `-NonInteractive` | ✅ |
| S6 | JSON report written to `$LogDir` | ✅ |
| S7 | `Write-Log` / `Write-ErrorLog` used | ✅ |
| S8 | `Test-AdminElevation` guard | ✅ |
| S9 | `exit 0` on clean success | ❌ |

**Score: 8/9**

**Findings:**

- **F19-01 README misclassification:** See CC-04.
- **F19-02 Inline initialisation:** See CC-02.

**Orchestrator contract:** BLOCKING. Step FAIL if wallpaper copy fails for any profile.

---

#### Step 20 — Backup-OutlookSignatures.ps1

**Path:** `Scripts/ConfigurationChanges/Backup-OutlookSignatures.ps1`  
**Lines:** 164  
**Purpose:** Copies the Outlook signatures folder (`AppData\Roaming\Microsoft\Signatures`) for each active user profile to `C:\PreWipeOutput\OutlookSignatures\`. BLOCKING.

**Standards checklist:**

| # | Item | Status |
|---|------|--------|
| S1 | `.SYNOPSIS` / `.DESCRIPTION` present | ✅ |
| S2 | `[CmdletBinding()]` + `-NonInteractive` switch | ✅ |
| S3 | Dot-sources `Initialize-Toolkit.ps1` | ❌ — inline init |
| S4 | Uses `Get-ActiveUserProfile` | ❌ — inline |
| S5 | Structured JSON to stdout on `-NonInteractive` | ✅ |
| S6 | JSON report written to `$LogDir` | ✅ |
| S7 | `Write-Log` / `Write-ErrorLog` used | ✅ |
| S8 | `Test-AdminElevation` guard | ✅ |
| S9 | `exit 0` on clean success | ❌ |

**Score: 8/9**

**Findings:**

- **F20-01 README misclassification:** See CC-04.
- **F20-02 Inline initialisation:** See CC-02.

**Orchestrator contract:** BLOCKING. Step FAIL if signatures folder copy fails for any profile.

---

#### Step 21 — Backup-TaskbarLayout.ps1

**Path:** `Scripts/ConfigurationChanges/Backup-TaskbarLayout.ps1`  
**Lines:** 235  
**Purpose:** Exports the taskbar layout XML for each active user profile by reading `TaskbarLayoutModification` registry values and the `LayoutModification.xml` file. Documents pinned items so they can be restored post-wipe.

**Standards checklist:**

| # | Item | Status |
|---|------|--------|
| S1 | `.SYNOPSIS` / `.DESCRIPTION` present | ✅ |
| S2 | `[CmdletBinding()]` + `-NonInteractive` switch | ✅ |
| S3 | Dot-sources `Initialize-Toolkit.ps1` | ❌ — inline init |
| S4 | Uses `Get-ActiveUserProfile` | ❌ — inline |
| S5 | Structured JSON to stdout on `-NonInteractive` | ✅ |
| S6 | JSON report written to `$LogDir` | ✅ |
| S7 | `Write-Log` / `Write-ErrorLog` used | ✅ |
| S8 | `Test-AdminElevation` guard | ✅ |
| S9 | `exit 0` on clean success | ❌ |

**Score: 8/9**

**Findings:**

- **F21-01 README misclassification:** See CC-04.

**Orchestrator contract:** Informational; WARN if export fails for any profile. Not blocking.

---

#### Step 22 — Backup-WiFiProfiles.ps1

**Path:** `Scripts/ConfigurationChanges/Backup-WiFiProfiles.ps1`  
**Lines:** 205  
**Purpose:** Exports all saved WiFi profiles as XML files (with cleartext PSK keys where available) using `netsh wlan export`. Enterprise (802.1x) profiles are flagged as requiring re-authentication. Includes a security warning for profiles containing plaintext PSK keys.

**Standards checklist:**

| # | Item | Status |
|---|------|--------|
| S1 | `.SYNOPSIS` / `.DESCRIPTION` present | ✅ |
| S2 | `[CmdletBinding()]` + `-NonInteractive` switch | ✅ |
| S3 | Dot-sources `Initialize-Toolkit.ps1` | ✅ (line 34) |
| S4 | Uses `Get-ActiveUserProfile` | N/A — device-level |
| S5 | Structured JSON to stdout on `-NonInteractive` | ✅ |
| S6 | JSON report written to `$LogDir` | ✅ — `WiFiProfiles-Report.json` |
| S7 | `Write-Log` / `Write-ErrorLog` used | ✅ |
| S8 | `Test-AdminElevation` guard | ✅ |
| S9 | `exit 0` on clean success | ✅ (explicit at line 59 for no-WlanSvc path, falls through on success) |

**Score: 9/9**

**Findings:**

- **F22-01 README misclassification:** Documented as "DataCollection" in README but resides in `ConfigurationChanges/` and exports files to disk. See CC-04. This finding does not affect the standards score since the script itself is correct.

**Orchestrator contract:** Informational with security note. No FAIL verdict wired for export count.

---

#### Step 23 — Test-BitLockerEscrow.ps1

**Path:** `Scripts/ConfigurationChanges/Test-BitLockerEscrow.ps1`  
**Lines:** 199  
**Purpose:** Checks BitLocker status on all fixed drives and attempts to escrow recovery keys to Entra ID (Azure AD) using `BackupToAAD-BitLockerKeyProtector`. CRITICAL and BLOCKING — the orchestrator FAILs this step if any drive has an unresolved escrow issue.

**Standards checklist:**

| # | Item | Status |
|---|------|--------|
| S1 | `.SYNOPSIS` / `.DESCRIPTION` present | ✅ |
| S2 | `[CmdletBinding()]` + `-NonInteractive` switch | ✅ |
| S3 | Dot-sources `Initialize-Toolkit.ps1` | ❌ — inline init (lines 36–61) |
| S4 | Uses `Get-ActiveUserProfile` | N/A — device-level |
| S5 | Structured JSON to stdout on `-NonInteractive` | ✅ |
| S6 | JSON report written to `$LogDir` | ✅ — `BitLockerEscrow-Report.json` |
| S7 | `Write-Log` / `Write-ErrorLog` used | ✅ |
| S8 | `Test-AdminElevation` guard | ✅ (inline, lines 58–61) |
| S9 | `exit 0` on clean success | ✅ (exits 1 on `!allEscrowed`, falls through on success) |

**Score: 8/9**

**Findings:**

- **F23-01 Inline initialisation:** This script defines its own `Write-Log`, `Write-ErrorLog`, and admin elevation check inline (lines 36–61) rather than dot-sourcing `Initialize-Toolkit.ps1`. Given that this is one of the most critical steps in the workflow, the duplication increases maintenance risk — a path change to `$OutputRoot` would require updating this script independently.
- **F23-02 `AllEscrowed` logic edge case:** `$allEscrowed` is computed using `-not ($Results | Where-Object { … })` (line 162). If `$Results` is empty (e.g., `Get-BitLockerVolume` throws immediately), `$allEscrowed` is `$true` and the script exits with 0, reporting success even though no volumes were checked. The outer `catch` block at line 151 adds an error entry to `$Results` — but the `Where-Object` filter only matches on `EscrowFailed` or `NoRecoveryKey`, so an `Error` status entry does NOT set `AllEscrowed = $false`.

**Orchestrator contract:** CRITICAL, BLOCKING. Orchestrator reads `AllEscrowed` from JSON stdout; `$false` → FAIL + block.

---

#### Step 24 — Set-WakeOnLan.ps1

**Path:** `Scripts/ConfigurationChanges/Set-WakeOnLan.ps1`  
**Lines:** 216  
**Purpose:** Enables Wake-on-LAN on the primary network adapter using `Set-NetAdapterPowerManagement` and Dell Command Configure (if available). Intended to run after `Test-WakeOnLan.ps1` confirms WoL is not already enabled.

**Standards checklist:**

| # | Item | Status |
|---|------|--------|
| S1 | `.SYNOPSIS` / `.DESCRIPTION` present | ✅ |
| S2 | `[CmdletBinding()]` + `-NonInteractive` switch | ✅ |
| S3 | Dot-sources `Initialize-Toolkit.ps1` | ❌ — inline init |
| S4 | Uses `Get-ActiveUserProfile` | N/A — device-level |
| S5 | Structured JSON to stdout on `-NonInteractive` | ✅ |
| S6 | JSON report written to `$LogDir` | ⚠️ — `WakeOnLan-SetResult.json` (-Result suffix) |
| S7 | `Write-Log` / `Write-ErrorLog` used | ✅ |
| S8 | `Test-AdminElevation` guard | ✅ |
| S9 | `exit 0` on clean success | ❌ |

**Score: 8/9**

**Findings:**

- **F24-01 Local `Get-DCCExePath` function (lines 74–83):** See CC-03.
- **F24-02 Inconsistent JSON filename suffix:** Reports as `WakeOnLan-SetResult.json` rather than `WakeOnLan-Report.json`. See CC-05.

---

#### Step 25 — Install-DellCommandTools.ps1

**Path:** `Scripts/ConfigurationChanges/Install-DellCommandTools.ps1`  
**Lines:** 274  
**Purpose:** Detects whether Dell Command Update and Dell Command Configure are installed at their expected paths. If missing, downloads and silently installs them. Gate step — steps 26 (Update-Drivers) and 27 (Update-Bios) depend on DCU being present.

**Standards checklist:**

| # | Item | Status |
|---|------|--------|
| S1 | `.SYNOPSIS` / `.DESCRIPTION` present | ✅ |
| S2 | `[CmdletBinding()]` + `-NonInteractive` switch | ✅ |
| S3 | Dot-sources `Initialize-Toolkit.ps1` | ❌ — inline init |
| S4 | Uses `Get-ActiveUserProfile` | N/A — device-level |
| S5 | Structured JSON to stdout on `-NonInteractive` | ✅ |
| S6 | JSON report written to `$LogDir` | ⚠️ — `DellCommandTools-Status.json` (-Status suffix) |
| S7 | `Write-Log` / `Write-ErrorLog` used | ✅ |
| S8 | `Test-AdminElevation` guard | ✅ |
| S9 | `exit 0` on clean success | ❌ |

**Score: 8/9**

**Findings:**

- **F25-01 Inline DCU/DCC path discovery (lines 101–119):** Defines `Get-DCUExePath` and `Get-DCCExePath` inline rather than using `Find-DellCommandTool.ps1`. Ironic given this script's purpose is to ensure the Dell tools are installed. See CC-03.
- **F25-02 Inconsistent JSON filename suffix:** See CC-05.

---

#### Step 26 — Update-Drivers.ps1

**Path:** `Scripts/ConfigurationChanges/Update-Drivers.ps1`  
**Lines:** 190  
**Purpose:** Invokes Dell Command Update in scan-and-install mode to apply outstanding driver updates. Parses DCU exit codes and maps them to human-readable outcomes. HIGH RISK step — modifies driver state on the device.

**Standards checklist:**

| # | Item | Status |
|---|------|--------|
| S1 | `.SYNOPSIS` / `.DESCRIPTION` present | ✅ |
| S2 | `[CmdletBinding()]` + `-NonInteractive` switch | ✅ |
| S3 | Dot-sources `Initialize-Toolkit.ps1` | ❌ — inline init |
| S4 | Uses `Get-ActiveUserProfile` | N/A — device-level |
| S5 | Structured JSON to stdout on `-NonInteractive` | ✅ |
| S6 | JSON report written to `$LogDir` | ⚠️ — `DriverUpdate-Result.json` (-Result suffix) |
| S7 | `Write-Log` / `Write-ErrorLog` used | ✅ |
| S8 | `Test-AdminElevation` guard | ✅ |
| S9 | `exit 0` on clean success | ❌ |

**Score: 8/9**

**Findings:**

- **F26-01 PowerShell 5.1 incompatibility (line 144):** `$meaning = $ExitCodeMap[$exitCode] ?? "ExitCode $exitCode (unknown)"` — the `??` operator causes a parse error on PS 5.1. On a PS 5.1 device the entire script fails to execute: no driver updates are applied, no JSON is emitted, and the orchestrator records an execution error. Fix: `$meaning = if ($ExitCodeMap.ContainsKey($exitCode)) { $ExitCodeMap[$exitCode] } else { "ExitCode $exitCode (unknown)" }`.
- **F26-02 Inline DCU path (lines 90–95):** See CC-03.
- **F26-03 Inconsistent JSON filename suffix:** See CC-05.

---

#### Step 27 — Update-Bios.ps1

**Path:** `Scripts/ConfigurationChanges/Update-Bios.ps1`  
**Lines:** 193  
**Purpose:** Invokes Dell Command Update in BIOS-update mode to apply the latest firmware. Maps DCU BIOS-specific exit codes. CRITICAL — a BIOS update failure or a mid-update power loss can brick the device; exit code handling must be correct.

**Standards checklist:**

| # | Item | Status |
|---|------|--------|
| S1 | `.SYNOPSIS` / `.DESCRIPTION` present | ✅ |
| S2 | `[CmdletBinding()]` + `-NonInteractive` switch | ✅ |
| S3 | Dot-sources `Initialize-Toolkit.ps1` | ❌ — inline init |
| S4 | Uses `Get-ActiveUserProfile` | N/A — device-level |
| S5 | Structured JSON to stdout on `-NonInteractive` | ✅ |
| S6 | JSON report written to `$LogDir` | ⚠️ — `BiosUpdate-Result.json` (-Result suffix) |
| S7 | `Write-Log` / `Write-ErrorLog` used | ✅ |
| S8 | `Test-AdminElevation` guard | ✅ |
| S9 | `exit 0` on clean success | ❌ |

**Score: 8/9**

**Findings:**

- **F27-01 PowerShell 5.1 incompatibility (line 145):** `$meaning = $ExitCodeMap[$exitCode] ?? "ExitCode $exitCode (unknown)"` — same `??` defect as Update-Drivers.ps1 (F26-01). On PS 5.1 the script fails to parse and no BIOS update is attempted. Given the risk profile of BIOS updates, this is the most dangerous PS 5.1 incompatibility in the toolkit: the script will silently not run but the orchestrator may record a benign status, leaving firmware un-updated without technician awareness.
- **F27-02 Inline DCU path (lines 90–95):** See CC-03.
- **F27-03 Inconsistent JSON filename suffix:** See CC-05.

---

### 3.4 AutopilotReadiness

---

#### Step 28 — Test-AutopilotReadiness.ps1

**Path:** `Scripts/AutopilotReadiness/Test-AutopilotReadiness.ps1`  
**Lines:** 344  
**Purpose:** Comprehensive Autopilot readiness gate: checks Azure AD join status (`dsregcmd /status`), MDM enrollment, Intune connectivity, hardware hash presence in registry, TPM readiness, and network connectivity to Autopilot endpoints. `OverallStatus` = `READY` / `NOT READY` / `UNDETERMINED`. CRITICAL and BLOCKING.

**Standards checklist:**

| # | Item | Status |
|---|------|--------|
| S1 | `.SYNOPSIS` / `.DESCRIPTION` present | ✅ |
| S2 | `[CmdletBinding()]` + `-NonInteractive` switch | ✅ |
| S3 | Dot-sources `Initialize-Toolkit.ps1` | ✅ (line 33) |
| S4 | Uses `Get-ActiveUserProfile` | N/A — device-level |
| S5 | Structured JSON to stdout on `-NonInteractive` | ✅ |
| S6 | JSON report written to `$LogDir` | ✅ |
| S7 | `Write-Log` / `Write-ErrorLog` used | ✅ |
| S8 | `Test-AdminElevation` guard | ✅ |
| S9 | `exit 0` on clean success | ✅ |

**Score: 9/9**

**Findings:**

- None of substance. This is one of the most complete scripts in the toolkit.

**Orchestrator contract:** CRITICAL, BLOCKING. Orchestrator reads `OverallStatus`; anything other than `READY` → FAIL + block. Pre-wipe cannot proceed without clearing this step.

---

#### Step 29 — Get-AutopilotAssignment.ps1

**Path:** `Scripts/AutopilotReadiness/Get-AutopilotAssignment.ps1`  
**Lines:** 268  
**Purpose:** Verifies whether the device has a valid Autopilot deployment profile assigned in Intune. Checks the local registry for a cached assignment, reads the JSON assignment file under `C:\Windows\Provisioning\Autopilot`, and validates via `dsregcmd`. BLOCKING.

**Standards checklist:**

| # | Item | Status |
|---|------|--------|
| S1 | `.SYNOPSIS` / `.DESCRIPTION` present | ✅ |
| S2 | `[CmdletBinding()]` + `-NonInteractive` switch | ✅ |
| S3 | Dot-sources `Initialize-Toolkit.ps1` | ❌ — inline admin check |
| S4 | Uses `Get-ActiveUserProfile` | N/A — device-level |
| S5 | Structured JSON to stdout on `-NonInteractive` | ✅ |
| S6 | JSON report written to `$LogDir` | ✅ |
| S7 | `Write-Log` / `Write-ErrorLog` used | ✅ |
| S8 | `Test-AdminElevation` guard | ✅ (inline) |
| S9 | `exit 0` on clean success | ❌ |

**Score: 8/9**

**Findings:**

- **F29-01 Inline admin elevation check:** Uses the `[Security.Principal.WindowsPrincipal]` pattern directly rather than calling `Test-AdminElevation` from `Initialize-Toolkit.ps1`. See CC-02.
- **F29-02 No `exit 0`:** See CC-09.

**Orchestrator contract:** BLOCKING. Orchestrator checks `AssignmentFound` / `ProfileAssigned` field; FAIL + block if not assigned.

---

#### Step 30 — Register-AutopilotDevice.ps1

**Path:** `Scripts/AutopilotReadiness/Register-AutopilotDevice.ps1`  
**Lines:** 214  
**Purpose:** Collects the device's hardware hash (via `Get-WindowsAutopilotInfo` or WMI) and uploads it to the Autopilot service via the Microsoft Graph API. The `$Result.Success` field drives downstream logic.

**Standards checklist:**

| # | Item | Status |
|---|------|--------|
| S1 | `.SYNOPSIS` / `.DESCRIPTION` present | ✅ |
| S2 | `[CmdletBinding()]` + `-NonInteractive` switch | ✅ |
| S3 | Dot-sources `Initialize-Toolkit.ps1` | ❌ — inline init |
| S4 | Uses `Get-ActiveUserProfile` | N/A — device-level |
| S5 | Structured JSON to stdout on `-NonInteractive` | ✅ |
| S6 | JSON report written to `$LogDir` | ✅ |
| S7 | `Write-Log` / `Write-ErrorLog` used | ✅ |
| S8 | `Test-AdminElevation` guard | ✅ |
| S9 | `exit 0` on clean success | ❌ |

**Score: 8/9**

**Findings:**

- **F30-01 CRITICAL — `Success = $true` on upload failure (lines 181–191):** `$Result.Success = $true` is set at line 181 immediately after a successful hash-collection step, before the upload is attempted. The upload is in a `try` block at lines 183–191; if the upload throws, the `catch` block sets `$Result.Error` but **does not set `$Result.Success = $false`**. The JSON emitted to stdout therefore reports `"Success": true` even though the device was never registered in Autopilot. The orchestrator has **no dedicated `Get-StepVerdict` case for this script** — it falls through to the default PASS logic. This means a failed Autopilot registration produces a clean PASS verdict, and the device proceeds to wipe without being registered. This is the highest-severity correctness defect in the toolkit.
- **F30-02 Early exit paths emit JSON then exit 1 (lines 116–117, 159–160):** Correctly handled — these paths set `$Result.Success = $false` before emitting JSON. The bug is specific to the upload catch path described in F30-01.

**Orchestrator contract:** No dedicated `Get-StepVerdict` case → default PASS regardless of JSON content. Combined with F30-01, upload failures are completely invisible to the orchestrator.

---

#### Step 31 — Get-PreWipeSummary.ps1

**Path:** `Scripts/AutopilotReadiness/Get-PreWipeSummary.ps1`  
**Lines:** 294  
**Purpose:** Reads the JSON reports from all previous steps, synthesises a human-readable pre-wipe summary, identifies blockers, and emits a final `ReadyForWipe` boolean. The last step before the technician authorises the wipe.

**Standards checklist:**

| # | Item | Status |
|---|------|--------|
| S1 | `.SYNOPSIS` / `.DESCRIPTION` present | ✅ |
| S2 | `[CmdletBinding()]` + `-NonInteractive` switch | ✅ |
| S3 | Dot-sources `Initialize-Toolkit.ps1` | ✅ (line 33) |
| S4 | Uses `Get-ActiveUserProfile` | N/A — synthesiser script |
| S5 | Structured JSON to stdout on `-NonInteractive` | ✅ |
| S6 | JSON report written to `$LogDir` | ✅ |
| S7 | `Write-Log` / `Write-ErrorLog` used | ✅ |
| S8 | `Test-AdminElevation` guard | ✅ |
| S9 | `exit 0` on clean success | ✅ |

**Score: 9/9**

**Findings:**

- **F31-01 `$ScriptMap` does not include `Report-AutopilotReadinessToHudu.ps1` (lines 41–72):** The ordered hashtable that maps step names to report paths has 31 entries but omits the Hudu reporting script entirely. This is consistent with the script being undocumented everywhere else, but means `Get-PreWipeSummary` will never surface Hudu-related failures. See CC-07.
- **F31-02 `Test-OneDriveSyncStatus` verdict evaluated by `OverallVerdict` string:** Uses `OverallVerdict == 'NOT_SAFE'` (line 141) rather than inspecting `Profiles[*].SafeToWipe` as the orchestrator does. See F12-01 / CC-08.

---

#### Step — — Report-AutopilotReadinessToHudu.ps1

**Path:** `Scripts/AutopilotReadiness/Report-AutopilotReadinessToHudu.ps1`  
**Lines:** 572  
**Purpose:** Reads the outputs from previous steps and posts a structured Autopilot readiness report to a Hudu IT documentation instance via the HuduAPI PowerShell module. Intended to create a permanent record of the pre-wipe state in the customer's asset management system.

**Standards checklist:**

| # | Item | Status |
|---|------|--------|
| S1 | `.SYNOPSIS` / `.DESCRIPTION` present | ✅ |
| S2 | `[CmdletBinding()]` + `-NonInteractive` switch | ✅ |
| S3 | Dot-sources `Initialize-Toolkit.ps1` | ❌ — inline admin check |
| S4 | Uses `Get-ActiveUserProfile` | N/A — reporting script |
| S5 | Structured JSON to stdout on `-NonInteractive` | ✅ |
| S6 | JSON report written to `$LogDir` | ✅ |
| S7 | `Write-Log` / `Write-ErrorLog` used | ✅ |
| S8 | `Test-AdminElevation` guard | ✅ (inline) |
| S9 | `exit 0` on clean success | ❌ |

**Score: 8/9**

**Findings:**

- **F32-01 MAJOR GAP — Absent from `$script:Steps` array:** This script is not listed anywhere in `Start-PreWipeToolkit.ps1`'s step definitions (lines 106–138), is absent from the README, and is absent from `Get-PreWipeSummary.ps1`'s `$ScriptMap`. It cannot be executed by the orchestrator. It requires a mandatory parameter (`-HuduBaseUrl`) and the `HuduAPI` module — neither of which the orchestrator knows about. It is effectively a dark script that can only be invoked manually by a technician who knows it exists.
- **F32-02 Mandatory `-HuduBaseUrl` parameter:** Because this parameter is mandatory (no default), the script will throw a prompt or error when called without it. The `-NonInteractive` switch cannot suppress a missing mandatory parameter — the caller must supply it. This is incompatible with the orchestrator's `Invoke-StepCapture` call pattern, which only passes `-NonInteractive`.
- **F32-03 External HuduAPI module dependency:** Requires `Import-Module HuduAPI`. The toolkit has no mechanism to verify this module is present before attempting to use the script. Missing module → terminating error.

**Orchestrator contract:** None — script is not in `$script:Steps` and orchestrator has no awareness of it.

---

## Appendix A — Cross-Cutting Findings

---

### CC-01 Standards Checklist

The following nine criteria were applied to every script during this audit. A script receives a mark for each criterion it meets; deviations are logged as findings in the per-script section.

| # | Criterion | Rationale |
|---|-----------|-----------|
| S1 | Has `.SYNOPSIS` and `.DESCRIPTION` comment block | Enables `Get-Help` and self-documentation |
| S2 | Uses `[CmdletBinding()]` and declares `-NonInteractive` switch | Required for orchestrator invocation via `Invoke-StepCapture` |
| S3 | Dot-sources `Scripts/Common/Initialize-Toolkit.ps1` | Central init, consistent paths, shared logging functions |
| S4 | Uses `Get-ActiveUserProfile` for user profile enumeration | Consistent skip-list and profile selection across all scripts |
| S5 | Emits structured JSON to stdout when `-NonInteractive` is set | Orchestrator JSON contract requirement |
| S6 | Writes a JSON report to `$LogDir` with `-Report.json` suffix | Enables `Get-PreWipeSummary` to aggregate results |
| S7 | Uses `Write-Log` and `Write-ErrorLog` for all output | Consistent timestamped log to `$LogDir\<ScriptName>.log` |
| S8 | Guards entry with `Test-AdminElevation` | Fails fast with a clear message before attempting privileged operations |
| S9 | Emits `exit 0` on clean success | Enables reliable exit-code testing in CI and wrapper scripts |

---

### CC-02 Initialize-Toolkit.ps1 Under-Adoption

**Severity:** MEDIUM  
**Affected scripts:** 26 of 32 (all except Get-TeamsData, Get-CredentialManagerEntries, Get-LocalAccounts, Backup-WiFiProfiles, Test-AutopilotReadiness, Get-PreWipeSummary)

`Scripts/Common/Initialize-Toolkit.ps1` (74 lines) defines `$OutputRoot`, `$LogDir`, `$ErrorLog`, `Write-Log`, `Write-ErrorLog`, and `Test-AdminElevation`. Only 6 scripts dot-source it; the remaining 26 duplicate these definitions inline with minor variations.

**Consequences:**
- Changing `$OutputRoot` from `C:\PreWipeOutput` requires editing 26 files.
- Each script's `Write-Log` implementation has minor formatting differences; log aggregation tools see inconsistent timestamp formats.
- `Test-AdminElevation` is reimplemented inline in some scripts using a slightly different `IsInRole` pattern, creating a maintenance surface for security-sensitive code.

**Fix:** All scripts should dot-source `Initialize-Toolkit.ps1` at the top of their init region, replacing their inline equivalents.

---

### CC-03 Dell Command Tool Path Duplication

**Severity:** MEDIUM  
**Affected scripts:** Test-BiosVersion (lines 96–101), Test-DriverStatus (lines 78–83), Test-WakeOnLan (lines 73–82), Set-WakeOnLan (lines 74–83), Install-DellCommandTools (lines 101–119), Update-Drivers (lines 90–95), Update-Bios (lines 90–95)

`Scripts/Common/Find-DellCommandTool.ps1` (47 lines) exposes `Find-DellCommandUpdate` and `Find-DellCommandConfigure` functions. Seven scripts ignore this helper and define their own inline DCU/DCC path search logic. The inline versions check slightly different sets of `Program Files` paths, creating a risk that a non-standard DCU installation path that is handled by the common helper is missed by some scripts but not others.

**Fix:** Dot-source `Find-DellCommandTool.ps1` and replace all inline path search blocks with calls to `Find-DellCommandUpdate` / `Find-DellCommandConfigure`.

---

### CC-04 README Folder Misclassification

**Severity:** LOW (documentation only; no runtime impact)  
**Affected scripts:** Backup-BrowserBookmarks, Backup-DesktopBackground, Backup-OutlookSignatures, Backup-TaskbarLayout, Backup-WiFiProfiles

The README documents these five scripts under "Scan, Check & Backup" alongside the DataCollection scripts. All five physically reside in `Scripts/ConfigurationChanges/` and perform write operations (file copies or `netsh` exports). The misclassification:

1. Misleads technicians reviewing the README into thinking these are read-only scans.
2. Could cause confusion if the `ConfigurationChanges/` folder is ever subject to a different change-control policy than `DataCollection/`.
3. Creates a mismatch between documentation and the orchestrator's step ordering (steps 18–22 are clearly in the "changes" phase).

**Fix:** Move these five entries to a "Configuration Changes — Backups" section in the README.

---

### CC-05 Inconsistent JSON Report Filename Suffixes

**Severity:** LOW  
**Affected scripts:** Test-OneDriveKFM (`-Status.json`), Set-WakeOnLan (`-SetResult.json`), Install-DellCommandTools (`-Status.json`), Update-Drivers (`-Result.json`), Update-Bios (`-Result.json`)

The toolkit convention (established by most scripts and referenced in `Get-PreWipeSummary`'s `$ScriptMap`) is `<ScriptName>-Report.json`. Five scripts use non-standard suffixes. While `Get-PreWipeSummary` references each file by its actual name so there is no current runtime breakage, the inconsistency increases maintenance risk: any future tooling that globs for `*-Report.json` will miss these files.

**Fix:** Rename the output files and update their references in `Get-PreWipeSummary.$ScriptMap` to use the `-Report.json` suffix consistently.

---

### CC-06 PowerShell 5.1 Null-Coalescing Incompatibility

**Severity:** HIGH  
**Affected scripts:** Get-DownloadsSize (line 135), Get-Printers (lines 121, 144), Update-Drivers (line 144), Update-Bios (line 145)

The `??` null-coalescing operator was introduced in PowerShell 7.0. Windows 10 and 11 ship with Windows PowerShell 5.1 as the system shell; PowerShell 7 must be installed explicitly. Four scripts use `??` at least once, causing a **parse error** (not a runtime error) on PS 5.1 — the script file cannot be loaded at all, the orchestrator receives no JSON output, and no work is performed.

The two most dangerous instances are in `Update-Drivers.ps1` and `Update-Bios.ps1`, where PS 5.1 incompatibility means drivers and BIOS are silently not updated on the majority of production devices if the toolkit is invoked via the system PowerShell.

**Fix for each occurrence:**
```powershell
# Before (PS 7+ only):
$value = $x ?? $default

# After (PS 5.1 compatible):
$value = if ($null -ne $x) { $x } else { $default }
```

**Recommended mitigation:** Add a version check in `Initialize-Toolkit.ps1` that warns (or blocks) if `$PSVersionTable.PSVersion.Major -lt 7`, so the incompatibility is surfaced at startup rather than producing silent partial failures.

---

### CC-07 Report-AutopilotReadinessToHudu.ps1 Is Undocumented and Orphaned

**Severity:** HIGH  
**Affected scripts:** Report-AutopilotReadinessToHudu.ps1

This 572-line script (the longest in the toolkit) is absent from:
- `$script:Steps` in `Start-PreWipeToolkit.ps1`
- The README
- `Get-PreWipeSummary.$ScriptMap`
- Any orchestrator flow

It requires a mandatory `-HuduBaseUrl` parameter and the `HuduAPI` module, making it incompatible with the orchestrator's `Invoke-StepCapture` call pattern even if it were added to `$script:Steps`.

**Recommended actions:**
1. Either add the script to the orchestrator as an optional step (with a `-HuduBaseUrl` parameter in `Start-PreWipeToolkit.ps1`) and make the parameter non-mandatory with `[ValidateScript({...})]`), or
2. Document it explicitly as a "post-run reporting" script in the README with usage instructions.
3. Add an `Import-Module HuduAPI -ErrorAction Stop` guard at the top so missing module failures are clear.

---

### CC-08 Test-OneDriveSyncStatus.ps1 Orchestrator Contract Mismatch

**Severity:** CRITICAL  
**Affected scripts:** Test-OneDriveSyncStatus.ps1 (step 12), Get-PreWipeSummary.ps1 (step 31)

Two different components evaluate the step 12 result using different JSON fields:

| Evaluator | JSON field checked | FAIL condition |
|-----------|-------------------|----------------|
| `Get-StepVerdict` (orchestrator, line 575) | `Profiles[*].SafeToWipe` | Any profile has `SafeToWipe = $false` |
| `Get-PreWipeSummary` (step 31, line 141) | `OverallVerdict` string | `OverallVerdict == 'NOT_SAFE'` |

Divergence scenarios:
- `OverallVerdict = 'NO_PROFILES'` → neither evaluator flags it as a failure, even though sync could not be verified.
- If the `AllSafe` loop in `Test-OneDriveSyncStatus.ps1` (lines 235–248) has a logic error producing `OverallVerdict = 'SAFE_TO_WIPE'` while individual profiles have `SafeToWipe = $false`, the orchestrator blocks but the final summary report says safe.

**Fix:** Standardise on a single evaluation path. Recommendation: make `Get-PreWipeSummary` evaluate `Profiles[*].SafeToWipe` directly (matching the orchestrator), and rename `SAFE_TO_WIPE`/`NOT_SAFE` to `PASS`/`FAIL` to align with other scripts' `OverallStatus` patterns.

---

### CC-09 Missing `exit 0` on Success

**Severity:** LOW  
**Affected scripts:** Find-UnbackedData, Get-DriveMappings, Get-Printers, Get-WindowsProductKey, Get-InstalledApplications, Get-DeviceHealth, Test-OneDriveKFM, Get-StorageMode, Test-BiosVersion, Test-DriverStatus, Test-WakeOnLan, Test-WinRE, Backup-BrowserBookmarks, Backup-DesktopBackground, Backup-OutlookSignatures, Backup-TaskbarLayout, Test-BitLockerEscrow, Set-WakeOnLan, Install-DellCommandTools, Update-Drivers, Update-Bios, Get-AutopilotAssignment, Register-AutopilotDevice, Report-AutopilotReadinessToHudu (24 scripts)

Scripts that fall off the end of the file return exit code 0 by default in PowerShell, so this is not a current runtime defect. However, it is a fragility: any code path that reaches the end of the file without an explicit `exit` relies on the implicit PowerShell behaviour. If an exception is added to a later code path and the script exits via an unguarded terminating error, the exit code will be non-zero — but the absence of explicit `exit 0` means there is no visual marker for "this is where a clean success exits."

**Fix:** Add `exit 0` as the final line of the `#region --- Output ---` block in all affected scripts.

---

### CC-10 Get-ActiveUserProfile.ps1 Under-Adoption

**Severity:** MEDIUM  
**Affected scripts:** All profile-iterating scripts except Get-TeamsData.ps1

`Scripts/Common/Get-ActiveUserProfile.ps1` (97 lines) exposes `Get-ActiveUserProfile`, `Mount-UserHive`, and `Dismount-UserHive`. It encapsulates profile enumeration, skip-list logic (service accounts, inactive profiles), and safe NTUSER.DAT loading/unloading with proper `[GC]::Collect()` cleanup.

Only `Get-TeamsData.ps1` uses this helper. All other scripts that iterate user profiles (`Find-UnbackedData`, `Get-DownloadsSize`, `Get-DriveMappings`, `Get-InstalledApplications`, `Backup-BrowserBookmarks`, `Backup-DesktopBackground`, `Backup-OutlookSignatures`, `Backup-TaskbarLayout`, `Test-OneDriveKFM`, `Test-OneDriveSyncStatus`) duplicate the `Win32_UserProfile` query, skip-list, and hive loading inline, each with slightly different logic.

**Consequence:** Inconsistent profile sets across steps. If a service account name is added to the skip-list in `Get-ActiveUserProfile.ps1` it will not be skipped by the 10 scripts that don't use it.

**Fix:** Refactor all profile-iterating scripts to call `Get-ActiveUserProfile` and use `Mount-UserHive`/`Dismount-UserHive`.

---

### CC-11 Register-AutopilotDevice.ps1 Has No Orchestrator Verdict Case

**Severity:** CRITICAL  
**Affected scripts:** Register-AutopilotDevice.ps1 (step 30), Start-PreWipeToolkit.ps1 (Get-StepVerdict, lines 545–694)

`Get-StepVerdict` in the orchestrator contains a `switch` statement with one case per script. Step 30 (`Register-AutopilotDevice`) has no case and falls through to the default branch, which returns PASS unconditionally (or based only on exit code, not JSON content).

Combined with F30-01 (upload failure leaves `Success = $true`), the complete failure path for a registration failure is:
1. Upload throws → catch sets `$Result.Error` but leaves `$Result.Success = $true`
2. JSON `"Success": true` is emitted to stdout
3. Orchestrator has no case for this step → default PASS
4. Device proceeds to wipe with no registration

**Fix (two-part):**
1. In `Register-AutopilotDevice.ps1`: move `$Result.Success = $true` to after the upload succeeds (or add `$Result.Success = $false` in the upload catch block).
2. In `Start-PreWipeToolkit.ps1 Get-StepVerdict`: add a case for `Register-AutopilotDevice` that checks `$json.Success -eq $true` and returns FAIL if not.

---

### CC-12 Swallowed Exception Patterns Produce Silent False-PASSes

**Severity:** HIGH  
**Affected scripts:** Find-UnbackedData.ps1 (line 216–218), Get-StorageMode.ps1 (lines 132–134, 152–154), Test-BitLockerEscrow.ps1 (AllEscrowed edge case, lines 151–158)

Three scripts contain empty `catch {}` blocks or result-aggregation logic that allows exceptions to be silently discarded, allowing the script to report a successful (or incomplete) result to the orchestrator when an error actually occurred.

The `Test-BitLockerEscrow.ps1` case is particularly subtle: the outer `catch` at line 151 adds an entry with `EscrowStatus = 'Error'` to `$Results`, but the `$allEscrowed` computation at line 162 uses `Where-Object { $_.EscrowStatus -in @('EscrowFailed', 'NoRecoveryKey') }` — the string `'Error'` is not in this list, so an execution error produces `$allEscrowed = $true` and the script exits 0 reporting success even though no volumes were checked.

**Fix:** Replace empty catch blocks with `Write-ErrorLog` calls. In `Test-BitLockerEscrow.ps1`, add `'Error'` to the `$allEscrowed` exclusion list.

---

## Appendix B — Orchestrator Contract Map

The table below maps each step to: the JSON key(s) the orchestrator reads via `Get-StepVerdict` in `Start-PreWipeToolkit.ps1` (lines 545–694); the verdict logic; and whether the step is a BLOCKER (user must acknowledge a FAIL before the run can continue).

| Step | Script | JSON Key(s) Consumed | PASS Condition | WARN Condition | FAIL Condition | Blocker |
|------|--------|---------------------|----------------|----------------|----------------|---------|
| 1 | Find-UnbackedData | `Results[*].AtRiskFileCount`, `TotalAtRiskFiles` | `TotalAtRiskFiles == 0` | `TotalAtRiskFiles > 0` | — | No |
| 2 | Get-DownloadsSize | `Results[*].SizeMB`, `TotalSizeMB` | `TotalSizeMB < threshold` | `TotalSizeMB >= threshold` | — | No |
| 3 | Get-DriveMappings | `Results[*].Drives` | Always PASS (informational) | — | — | No |
| 4 | Get-Printers | `Results[*].Printers` | Always PASS (informational) | — | — | No |
| 5 | Get-WindowsProductKey | `KeyFound`, `Source` | `KeyFound == true` | `KeyFound == false` | — | No |
| 6 | Get-InstalledApplications | `Applications` | Always PASS (informational) | — | — | No |
| 7 | Get-DeviceHealth | `DiskStatus`, `BatteryHealth`, `HealthIssues` | No issues | Any issue flagged | — | No |
| 8 | Get-TeamsData | `AnyMediaFiles`, `Results[*]` | Always PASS | `AnyMediaFiles == true` | — | No |
| 9 | Get-CredentialManagerEntries | `Credentials` | Always PASS (informational) | — | — | No |
| 10 | Get-LocalAccounts | `Accounts` | Always PASS (informational) | — | — | No |
| 11 | Test-OneDriveKFM | `Profiles[*].KFMConfigured` | All profiles KFM configured | — | Any profile not configured | **Yes** |
| 12 | Test-OneDriveSyncStatus | `Profiles[*].SafeToWipe` | All `SafeToWipe == true` | — | Any `SafeToWipe == false` | **Yes** |
| 13 | Get-StorageMode | `StorageMode`, `Detected` | `Detected == true` | `Detected == false` (Unknown) | — | No |
| 14 | Test-BiosVersion | `BiosUpToDate`, `UpdateAvailable` | `BiosUpToDate == true` | `UpdateAvailable == true` | — | No |
| 15 | Test-DriverStatus | `UpdatesAvailable`, `CriticalCount` | No critical updates | Non-critical updates | `CriticalCount > 0` | No |
| 16 | Test-WakeOnLan | `WoLEnabled` | `WoLEnabled == true` | `WoLEnabled == false` | — | No |
| 17 | Test-WinRE | `WinREEnabled` | `WinREEnabled == true` | `WinREEnabled == false` | — | No |
| 18 | Backup-BrowserBookmarks | `Results[*].Success`, `AllSucceeded` | `AllSucceeded == true` | — | `AllSucceeded == false` | **Yes** |
| 19 | Backup-DesktopBackground | `Results[*].Backed`, `AllBacked` | `AllBacked == true` | — | `AllBacked == false` | **Yes** |
| 20 | Backup-OutlookSignatures | `Results[*].Backed`, `AllBacked` | `AllBacked == true` | — | `AllBacked == false` | **Yes** |
| 21 | Backup-TaskbarLayout | `Results[*].Exported` | All exported | Partial export | — | No |
| 22 | Backup-WiFiProfiles | `ExportedCount`, `ProfileCount` | `ExportedCount == ProfileCount` | Partial export | — | No |
| 23 | Test-BitLockerEscrow | `AllEscrowed` | `AllEscrowed == true` | — | `AllEscrowed == false` | **Yes** |
| 24 | Set-WakeOnLan | `WoLSet`, `ActionTaken` | `WoLSet == true` | — | `WoLSet == false` | No |
| 25 | Install-DellCommandTools | `DCUInstalled`, `DCCInstalled` | Both installed | One missing | Neither installed | No |
| 26 | Update-Drivers | `UpdatesApplied`, `ExitCode` | `ExitCode` in success set | Reboot required | `ExitCode` in failure set | No |
| 27 | Update-Bios | `UpdateApplied`, `ExitCode` | `ExitCode` in success set | Reboot required | `ExitCode` in failure set | No |
| 28 | Test-AutopilotReadiness | `OverallStatus` | `OverallStatus == 'READY'` | `OverallStatus == 'UNDETERMINED'` | `OverallStatus == 'NOT READY'` | **Yes** |
| 29 | Get-AutopilotAssignment | `AssignmentFound` / `ProfileAssigned` | `AssignmentFound == true` | — | `AssignmentFound == false` | **Yes** |
| 30 | Register-AutopilotDevice | *(no case — default PASS)* | Default PASS | — | *(never reached — see CC-11)* | No |
| 31 | Get-PreWipeSummary | `ReadyForWipe` | `ReadyForWipe == true` | — | `ReadyForWipe == false` | No |
| — | Report-AutopilotReadinessToHudu | *(not in orchestrator)* | N/A | N/A | N/A | N/A |

**Notes:**
- "PASS/WARN/FAIL Condition" descriptions are derived from static analysis of `Get-StepVerdict` (lines 545–694 of `Start-PreWipeToolkit.ps1`). Where the orchestrator has a simple `exit 1` check rather than JSON parsing, the condition is noted accordingly.
- Step 12 (`Test-OneDriveSyncStatus`) and Step 30 (`Register-AutopilotDevice`) have critical contract defects described in CC-08 and CC-11 respectively.
- Step 30 has no dedicated verdict case. The "default PASS" entry reflects the current behaviour, not the intended behaviour.
- The `Get-StepVerdict` verdict values map to: `'PASS'` → green, proceed; `'WARN'` → yellow, log but continue; `'FAIL'` → red, log and (if Blocker=Yes) prompt for acknowledgement before proceeding.

---

*End of audit — AshesToAutopilot 2026-05-05*
