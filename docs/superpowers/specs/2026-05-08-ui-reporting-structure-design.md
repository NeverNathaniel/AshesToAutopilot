# UI, Reporting & Structure Improvements — Design Spec

**Date:** 2026-05-08  
**Status:** Approved  
**Scope:** 15 selected improvements across terminal UI, HTML reporting, and structural cleanup  
**Approach:** In-place changes to existing files; orchestrator file split done last

---

## 1. Overview

This spec covers 15 improvements to the AshesToAutopilot toolkit, selected from a prioritised backlog review. The primary driver is a team of technicians who use this tool to prepare Windows devices for wipe and Autopilot re-enrollment — clarity of results and usability are the highest-priority concerns.

All changes are implemented in Approach A (in-place, split last): improvements are made within the existing single-file orchestrator structure first, then the file is split into modules as the final step. This avoids a risky upfront refactor blocking all other work.

**Items NOT in scope (deliberately excluded):**
- Remove 3-second startup banner delay (p2-1)
- Remove 2-second inter-step sleep (p2-2)

---

## 2. Prerequisites — Phase Label Restructure (p3-3)

Done first because it affects UI display, report grouping, and HTML anchor generation.

### Current state
All 22 steps (1–22) are assigned to the `'ScanCheckBackup'` phase. Steps 13–17 (ConfigurationChecks) and 18–22 (Backup-* scripts) are logically distinct but share a phase label.

### Change
Split `'ScanCheckBackup'` into two phases in `$script:Steps` and `$script:PhaseLabels`:

| Phase key | Display label | Steps |
|---|---|---|
| `'ScanCheck'` | `'Scan & Check'` | 1–17 |
| `'Backup'` | `'Backup'` | 18–22 |
| `'Configure'` | `'Configure'` | 23–24 (unchanged) |
| `'InstallUpdate'` | `'Install & Update'` | 25–27 (unchanged) |
| `'Autopilot'` | `'Autopilot'` | 28–31 (unchanged) |

### Impact
Every consumer of `Get-PhaseLabel` — menus, run headers, HTML report phase groupings, session summary — picks up the new labels automatically. No other logic changes required.

---

## 3. UI Changes

### 3.1 Verdict Storage (prerequisite for p1-1 and p1-2)

**Problem:** Verdicts are computed at runtime but never persisted. The session summary and main menu have no access to them after a run completes.

**Change:** Extend `Update-SessionStep` to accept and store `Verdict` and `VerdictReason`:

```
session.json → Steps["12"] → {
  Status: "DONE",
  Timestamp: "...",
  ExitCode: 0,
  Verdict: "FAIL",          ← new
  VerdictReason: "Primary profile not synced"  ← new
}
```

`Invoke-RunSteps` passes the verdict from `Invoke-StepCapture`'s result to `Update-SessionStep`. `Import-Session` reads the new fields when loading. Steps with no stored verdict (never run) default to `$null`.

### 3.2 Session Summary — Add Verdict Column (p1-1)

**File:** `Start-PreWipeToolkit.ps1` → `Show-SessionSummary`

**Current:** Each step row shows step number, name, and a DONE/FAIL/SKIP badge.  
**New:** Add a verdict indicator after the status badge sourced from session state:

```
  12  [DONE] [XX]  Test OneDrive Sync Status
  11  [DONE] [!!]  Test OneDrive KFM Status
   1  [DONE] [!!]  Scan for Unbacked Data
   6  [DONE] [OK]  Get Installed Applications
  30  [    ] [--]  Register Device with Autopilot
```

`[OK]` green / `[!!]` yellow / `[XX]` red / `[--]` dark gray (not run).

### 3.3 Main Menu Progress — Add Verdict Counts (p1-2)

**File:** `Start-PreWipeToolkit.ps1` → `Show-MainMenu`

**Current:** `"█████████░░░░░░░  12/31 complete  (0 failed)"`  
**New:** `"█████████░░░░░░░  12/31 complete   [!!] 2   [XX] 1"`

Verdict counts are derived from `$script:Session.Steps` where `Verdict` is stored. Zero counts are shown as muted gray; non-zero WARN is yellow, non-zero FAIL is red.

### 3.4 Single Step — Loop Back to Step List (p2-3)

**File:** `Start-PreWipeToolkit.ps1` → `Invoke-SingleStep`

**Current:** After `Invoke-StepInteractive` returns, `Invoke-SingleStep` does `return`, dropping back to the main menu loop.  
**Change:** Remove the `return` after `Invoke-StepInteractive`. The `while ($true)` loop continues, showing the step list again. Tech presses `0` or leaves input blank to return to the main menu.

The step list table re-renders after each run, so the completed step's status badge updates immediately.

### 3.5 Inline Re-Run of Failed Steps (p3-4)

**File:** `Start-PreWipeToolkit.ps1` → `Invoke-RunSteps`

**Current:** Run completes, shows summary, prompts "Press any key to return to menu."  
**Change:** After `Show-RunSummaryInline`, collect steps where `Status = 'FAIL'` OR `Verdict = 'FAIL'`. If any exist:

```
  Re-run 2 failed step(s)?  [Y] Yes    [N] No
```

If Y: call `Invoke-RunSteps` with the failed steps only, using label `"Retry — $n failed step(s)"`. The recursive call does not prompt for another re-run (one level only). If N: proceed to "Press any key to return to menu."

---

## 4. Reporting Changes

### 4.1 Action Items Panel (p1-3)

**File:** `Start-PreWipeToolkit.ps1` → `Export-HtmlReport`

**Position:** Inserted between the readiness banner and the per-step cards.

**Content:** An orange-bordered panel titled "Action Items Before Wipe". For each result where `Verdict = 'FAIL'` or `'WARN'`:
- Icon: red `✗` for FAIL, amber `⚠` for WARN
- Bold label: `"$($r.DisplayName) — $($r.VerdictReason)"`
- Detail text: a human-readable instruction per step, defined in a lookup table in `Export-HtmlReport`. Falls back to `VerdictReason` if no specific instruction is defined.

If there are no FAIL or WARN verdicts, the panel is omitted entirely.

**Instruction lookup table (initial entries):**

| Step match | Instruction |
|---|---|
| `*Test-OneDriveSyncStatus*` | "Open OneDrive and wait for full sync before wiping. Do not proceed until resolved." |
| `*Test-OneDriveKFM*` | "Enable Known Folder Move for the affected profile in OneDrive settings." |
| `*Find-UnbackedData*` | "Confirm with user whether the flagged files need manual backup before wipe." |
| `*Backup-BrowserBookmarks*` | "Remind user to sign into browser on new device to restore bookmarks." |
| `*Test-BitLockerEscrow*` | "Re-run step 23 to escrow BitLocker key. Do not wipe until key is backed up to Entra ID." |
| `*Test-AutopilotReadiness*` | "Device does not meet Autopilot hardware requirements. Review TPM/UEFI/Secure Boot status." |
| `*Get-AutopilotAssignment*` | "No Autopilot profile found. Assign device in Intune before wiping." |
| `*Register-AutopilotDevice*` | "Hardware hash upload failed. Re-run step 30 to retry registration." |
| default | *(use VerdictReason as-is)* |

### 4.2 Filter Bar and Phase Jump Links (p1-4)

**File:** `Start-PreWipeToolkit.ps1` → `Export-HtmlReport`

**Position:** Sticky bar below the action items panel, above the first card.

**Filter buttons:**
- `All (N)` — show all cards
- `Issues Only (N)` — show only `Verdict = 'FAIL'` or `'WARN'` cards
- `Warnings (N)` — show only `Verdict = 'WARN'` cards

Each card gets a `data-verdict` attribute (`"fail"`, `"warn"`, `"pass"`, `"none"`). Filtering is client-side JS toggling `display:none`. The active button is highlighted.

**Phase jump links:** Right-aligned in the filter bar. One link per phase, scrolling to an anchor `id` on each phase header `<div>`. Phases: Scan & Check, Backup, Configure, Install & Update, Autopilot.

### 4.3 Consolidated 31-Step Report (p2-4)

**File:** `Start-PreWipeToolkit.ps1` → `Export-HtmlReport`

**Current:** Report shows only the steps in the current run's `$ResultSet`.  
**Change:** After computing current-run results, `Export-HtmlReport` loads `session.json` and builds a complete 31-step view:

1. Start with all 31 `$script:Steps` in order.
2. For each step, if present in current `$ResultSet` → use current data (normal card styling).
3. If present in `session.json` with a prior verdict → render as a "prior session" card: dashed border, 75% opacity, `"From prior session · <date>"` badge.
4. If never run → render as a "not run" placeholder: dashed border, 50% opacity, `"NOT RUN"` status badge, no verdict.

Prior-session data is sourced from `session.json` `Steps[n].Verdict` and `Steps[n].VerdictReason` (stored by the verdict persistence change in §3.1). If a prior step has no stored verdict (session.json predates this feature), it shows status only.

### 4.4 Remove Application and Table Row Caps (p3-1, p3-2)

**File:** `Start-PreWipeToolkit.ps1` → `Get-HtmlTable`

**Changes:**
1. Delete `$limit = [Math]::Min($rows.Count, 15)` and the `$rows.Count -gt 15` overflow row. All tables render complete data.
2. In the `'*Get-InstalledApplications*'` case, remove `Select-Object -First 10`. All installed applications are included.
3. For the applications table only: wrap the `<table>` in a `<details><summary>Show all N applications ›</summary>…</details>` collapsible element, collapsed by default. All other tables render expanded.

### 4.5 Export Report Feedback (p4-2)

**File:** `Start-PreWipeToolkit.ps1` → wherever menu option `[6]` calls the export logic

**Terminal output after export:** List each generated file with its full path and size:
```
  Exported:
    HTML  C:\PreWipeOutput\PreWipeReport_LAPTOP-XK7F2_20260508-094122.html   42 KB
    JSON  C:\PreWipeOutput\PreWipeReport_LAPTOP-XK7F2_20260508-094122.json   18 KB
    TXT   C:\PreWipeOutput\PreWipeReport_LAPTOP-XK7F2_20260508-094122.txt     6 KB
```

**In the HTML report:** A "Report Exports" panel at the bottom of the report page (after all cards, before the footer) showing the same three files, paths, and sizes.

File sizes are computed with `(Get-Item $path).Length` after each file is written, formatted as KB.

### 4.6 Hudu Integration (p4-1)

**File:** `Start-PreWipeToolkit.ps1` → `Show-MainMenu` and main loop

**New menu option:** `[8]  Push to Hudu` — displayed only when `session.json` exists (at least one step has been run).

**Behaviour when selected:**
1. Check `Get-Module HuduAPI -ListAvailable`. If missing: display install instructions and prompt `[I] Install now  [N] Cancel`. If installing, run `Install-Module HuduAPI -Scope CurrentUser`.
2. If `$script:HuduBaseUrl` is not set, prompt: `"Hudu base URL (e.g. https://your-hudu.com): "`. Store in `$script:HuduBaseUrl` for the session.
3. Call `& (Join-Path $PSScriptRoot 'Scripts\AutopilotReadiness\Report-AutopilotReadinessToHudu.ps1') -HuduBaseUrl $script:HuduBaseUrl`.
4. Show success or error inline.

`$script:HuduBaseUrl` is not persisted to `session.json` (it's org-specific config, not device state).

---

## 5. Structural Cleanup

### 5.1 Staleness Check in Get-PreWipeSummary (p3-5)

**File:** `Scripts/AutopilotReadiness/Get-PreWipeSummary.ps1`

**Threshold:** 24 hours (hardcoded; can be parameterised later).

**Change:** When reading each JSON file via `$ScriptMap`, after parsing:
```powershell
$ageHours = ((Get-Date) - [datetime]$entry.Timestamp).TotalHours
$entry.Stale = $ageHours -gt 24
```

If `$entry.Stale`:
- Interactive output: amber `[STALE]` badge next to the script name, with the age in hours.
- JSON output: `Stale = $true` and `StaleHours = <n>` on the entry object.
- `OverallVerdict`: if any blocking step has stale data, append `" (WARNING: stale data — re-run affected steps)"` to the verdict string.

### 5.2 QuickCheckIndices Comment (p4-3)

**File:** `Start-PreWipeToolkit.ps1`

Add a block comment directly above `$script:QuickCheckIndices`:

```powershell
# Quick Check step selection rationale:
# These 12 steps are the minimum needed to assess wipe safety without modifying any settings.
# Selection criteria:
#   - OneDrive KFM + sync (steps 11, 12): primary data-loss blockers
#   - Unbacked data scan (step 1): identifies at-risk files outside OneDrive
#   - Downloads size (step 2): flags large folders that won't survive wipe
#   - Drive mappings (step 3): documents network drives for post-wipe reconnection
#   - Installed apps (step 6): documents software to reinstall
#   - Storage mode (step 13): identifies RAID configurations that complicate reinstall
#   - Browser bookmarks (step 18), desktop background (step 19),
#     Outlook signatures (step 20): lightweight backups
#   - Printers (step 4): inventory only, no changes made
#   - Autopilot assignment (step 29): confirms Autopilot profile is ready
```

### 5.3 Orchestrator File Split (p4-4)

**Done last**, after all other changes are verified working.

**New files** (dot-sourced from `Start-PreWipeToolkit.ps1` at the top of the script):

| File | Contents | Approx lines |
|---|---|---|
| `Scripts/Common/Toolkit-UI.ps1` | `Write-Log`, `Write-ErrorLog`, `Read-MenuKey`, `Get-PhaseLabel`, banners, `Get-ProgressBarString`, `Show-MainMenu`, `Write-RunHeader`, `Write-StepLine`, `Write-StepResultLine`, `Show-RunSummaryInline`, `Show-StepListTable`, `Show-SessionSummary` | ~360 |
| `Scripts/Common/Toolkit-Report.ps1` | `Get-StepSummary`, `Get-StepVerdict`, `Get-HtmlTable`, `Export-HtmlReport`, `Export-SessionReport` | ~450 |
| `Scripts/Common/Toolkit-Execution.ps1` | `Invoke-StepCapture`, `Invoke-StepInteractive`, `Invoke-RunSteps` | ~120 |

`Start-PreWipeToolkit.ps1` retains: param block, init/admin check, hardware info, step definitions, phase labels, session management functions (`Initialize-Session`, `Import-Session`, `Save-Session`, `Update-SessionStep`), primary profile detection, workflow action functions (`Invoke-QuickCheck`, `Invoke-FullPrep`, `Invoke-SingleStep`, `Invoke-CustomRun`), and the main menu loop. Target size: ~350 lines.

**Dot-source block** at top of orchestrator (after param block, before init):
```powershell
. (Join-Path $PSScriptRoot 'Scripts\Common\Toolkit-UI.ps1')
. (Join-Path $PSScriptRoot 'Scripts\Common\Toolkit-Report.ps1')
. (Join-Path $PSScriptRoot 'Scripts\Common\Toolkit-Execution.ps1')
```

---

## 6. Implementation Order

Changes should be applied in this sequence to avoid merge conflicts and ensure each layer builds on a working base:

1. **Phase labels** (p3-3) — touches `$script:Steps` and `$script:PhaseLabels` only; zero risk
2. **Verdict storage** (prerequisite for p1-1/p1-2) — extends `Update-SessionStep` and `Import-Session`
3. **Session summary verdict column** (p1-1)
4. **Main menu verdict counts** (p1-2)
5. **Single step looper** (p2-3) — one-line change
6. **Inline re-run** (p3-4) — additive to `Invoke-RunSteps`
7. **HTML: action items panel** (p1-3)
8. **HTML: filter bar and jump links** (p1-4)
9. **HTML: consolidated 31-step view** (p2-4) — depends on verdict storage
10. **HTML: remove row caps** (p3-1, p3-2)
11. **HTML: export feedback** (p4-2)
12. **Hudu integration** (p4-1)
13. **Staleness check in Get-PreWipeSummary** (p3-5)
14. **QuickCheckIndices comment** (p4-3)
15. **Orchestrator file split** (p4-4) — last; pure reorganisation of already-correct code

---

## 7. Files Modified

| File | Changes |
|---|---|
| `Start-PreWipeToolkit.ps1` | All UI, reporting, and structural changes (items 1–14 above); dot-source block added for split (item 15) |
| `Scripts/AutopilotReadiness/Get-PreWipeSummary.ps1` | Staleness check (p3-5) |
| `Scripts/Common/Toolkit-UI.ps1` | New file — extracted from orchestrator (p4-4) |
| `Scripts/Common/Toolkit-Report.ps1` | New file — extracted from orchestrator (p4-4) |
| `Scripts/Common/Toolkit-Execution.ps1` | New file — extracted from orchestrator (p4-4) |

No individual step scripts are modified.

---

## 8. Out of Scope

- Performance timing changes (banner delay, inter-step sleep)
- New step scripts
- Changes to existing Common helper scripts
- Hudu URL persistence across sessions
- Session history comparison across multiple devices
