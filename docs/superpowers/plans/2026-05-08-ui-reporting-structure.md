# UI, Reporting & Structure Improvements — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement 15 improvements to the AshesToAutopilot toolkit covering terminal UI clarity, HTML report usability, and structural cleanup — all in-place within the existing orchestrator, with file split done last.

**Architecture:** All changes except Task 14 (Get-PreWipeSummary) and Task 16 (file split) are in `Start-PreWipeToolkit.ps1`. Changes build sequentially: phase labels first (affects all grouping), then verdict storage (prerequisite for UI verdict display and consolidated HTML), then UI changes, then HTML changes, then structural cleanup. The file split in Task 16 is a pure code-move — no logic changes at that stage.

**Tech Stack:** PowerShell 5.1+, HTML/CSS/vanilla JS (inline in HTML report), no external modules except HuduAPI (Task 13, optional)

**Note on testing:** This project has no Pester test suite. Each task includes manual verification steps: run the script in a PowerShell window and confirm the described output, or open the generated HTML in a browser.

---

## File Map

| File | Tasks | Nature |
|---|---|---|
| `Start-PreWipeToolkit.ps1` | 1–13, 15, 16 | Modify |
| `Scripts/AutopilotReadiness/Get-PreWipeSummary.ps1` | 14 | Modify |
| `Scripts/Common/Toolkit-UI.ps1` | 16 | Create (new) |
| `Scripts/Common/Toolkit-Report.ps1` | 16 | Create (new) |
| `Scripts/Common/Toolkit-Execution.ps1` | 16 | Create (new) |

---

## Task 1: Phase Labels (p3-3)

**Files:**
- Modify: `Start-PreWipeToolkit.ps1` — `$script:PhaseLabels` (line ~94) and `$script:Steps` (lines ~107–138)

- [ ] **Step 1: Update `$script:PhaseLabels`**

Find the `$script:PhaseLabels` block (currently has 4 keys). Replace it:

```powershell
$script:PhaseLabels = [ordered]@{
    'ScanCheck'     = 'Scan & Check'
    'Backup'        = 'Backup'
    'Configure'     = 'Configure'
    'InstallUpdate' = 'Install & Update'
    'Autopilot'     = 'Autopilot'
}
```

- [ ] **Step 2: Update `$script:Steps` — steps 1–17 to `'ScanCheck'`**

In the `$script:Steps` array, find all 17 entries with `Phase = 'ScanCheckBackup'` that map to scripts in `DataCollection\` and `ConfigurationChecks\`. Change their Phase value to `'ScanCheck'`. These are steps with `Index` 1 through 17.

- [ ] **Step 3: Update `$script:Steps` — steps 18–22 to `'Backup'`**

Find entries with `Index` 18 through 22 (the `Backup-*.ps1` scripts). Change `Phase = 'ScanCheckBackup'` to `Phase = 'Backup'` on each.

- [ ] **Step 4: Verify**

Run `.\Start-PreWipeToolkit.ps1` as Administrator. Open menu option `[5] View Session Summary`. The phase headers in the step list should now read "Scan & Check", "Backup", "Configure", "Install & Update", "Autopilot" instead of the old "Scan, Check & Backup" label. Press Q to exit.

- [ ] **Step 5: Commit**

```powershell
git add Start-PreWipeToolkit.ps1
git commit -m "refactor: split ScanCheckBackup into ScanCheck and Backup phases (p3-3)"
```

---

## Task 2: Verdict Storage

**Files:**
- Modify: `Start-PreWipeToolkit.ps1` — `Update-SessionStep` (~line 203), `Import-Session` (~line 158), `Invoke-RunSteps` (~line 1081)

This is a prerequisite for Tasks 3, 4, and 10. It extends session.json to persist verdicts.

- [ ] **Step 1: Extend `Update-SessionStep`**

Find the function signature:
```powershell
function Update-SessionStep { # Updates step status after execution
    param([int]$Index, [string]$Status, $ExitCode)
```

Replace with:
```powershell
function Update-SessionStep {
    param([int]$Index, [string]$Status, $ExitCode, [string]$Verdict = $null, [string]$VerdictReason = $null)
```

In the function body, after the `ExitCode` assignment line, add:
```powershell
    $script:Session.Steps[$key].Verdict      = $Verdict
    $script:Session.Steps[$key].VerdictReason = $VerdictReason
```

- [ ] **Step 2: Extend `Import-Session` to read verdict fields**

In `Import-Session`, find the block that builds each step entry:
```powershell
            $steps[$prop.Name] = @{
                Status    = $prop.Value.Status
                Timestamp = $prop.Value.Timestamp
                ExitCode  = $prop.Value.ExitCode
            }
```

Replace with:
```powershell
            $steps[$prop.Name] = @{
                Status        = $prop.Value.Status
                Timestamp     = $prop.Value.Timestamp
                ExitCode      = $prop.Value.ExitCode
                Verdict       = $prop.Value.Verdict
                VerdictReason = $prop.Value.VerdictReason
            }
```

- [ ] **Step 3: Update `Invoke-RunSteps` to pass verdict to `Update-SessionStep`**

In `Invoke-RunSteps`, find the existing call:
```powershell
        Update-SessionStep -Index $step.Index -Status $step.Status -ExitCode ($result.Status -eq 'DONE' ? 0 : 1)
```

Replace with:
```powershell
        $exitCodeVal = if ($result.Status -eq 'DONE') { 0 } else { 1 }
        Update-SessionStep -Index $step.Index -Status $step.Status -ExitCode $exitCodeVal `
            -Verdict $result.Verdict -VerdictReason $result.VerdictReason
```

- [ ] **Step 4: Verify**

Run a Quick Check (option `[1]`). After it completes, open `C:\PreWipeOutput\session.json` in a text editor. Each step entry should now have `"Verdict": "PASS"` (or WARN/FAIL) and `"VerdictReason": "..."` fields.

- [ ] **Step 5: Commit**

```powershell
git add Start-PreWipeToolkit.ps1
git commit -m "feat: persist verdict and VerdictReason to session.json per step"
```

---

## Task 3: Session Summary — Verdict Column (p1-1)

**Files:**
- Modify: `Start-PreWipeToolkit.ps1` — `Show-SessionSummary` (~line 1225)

- [ ] **Step 1: Add verdict display to step list loop**

In `Show-SessionSummary`, find the per-step rendering loop. It currently contains:
```powershell
        $num    = $step.Index.ToString().PadLeft(2)
        Write-Host -NoNewline "   $num  " -ForegroundColor DarkGray
        Write-Host -NoNewline $badge      -ForegroundColor $bColor
        Write-Host "  $($step.DisplayName)" -ForegroundColor Gray
```

Replace with:
```powershell
        $stepKey  = "$($step.Index)"
        $sv       = if ($script:Session.Steps.ContainsKey($stepKey)) { $script:Session.Steps[$stepKey].Verdict } else { $null }
        $vTag     = switch ($sv) { 'PASS' { '[OK]' } 'WARN' { '[!!]' } 'FAIL' { '[XX]' } default { '[--]' } }
        $vColor   = switch ($sv) { 'PASS' { 'Green' } 'WARN' { 'Yellow' } 'FAIL' { 'Red' } default { 'DarkGray' } }
        $num      = $step.Index.ToString().PadLeft(2)
        Write-Host -NoNewline "   $num  " -ForegroundColor DarkGray
        Write-Host -NoNewline $badge      -ForegroundColor $bColor
        Write-Host -NoNewline " $vTag"    -ForegroundColor $vColor
        Write-Host "  $($step.DisplayName)" -ForegroundColor Gray
```

- [ ] **Step 2: Verify**

Run at least one step, then open menu option `[5]`. Each step row should now show a verdict badge (`[OK]`, `[!!]`, `[XX]`, or `[--]` for not-run) between the status badge and the step name.

- [ ] **Step 3: Commit**

```powershell
git add Start-PreWipeToolkit.ps1
git commit -m "feat: show verdict column in session summary (p1-1)"
```

---

## Task 4: Main Menu Verdict Counts (p1-2)

**Files:**
- Modify: `Start-PreWipeToolkit.ps1` — `Show-MainMenu` (~line 288)

- [ ] **Step 1: Compute verdict counts**

In `Show-MainMenu`, after the existing `$done`, `$fail`, `$total` lines, add:
```powershell
    $warnV = @($script:Steps | Where-Object {
        $key = "$($_.Index)"
        $script:Session.Steps.ContainsKey($key) -and $script:Session.Steps[$key].Verdict -eq 'WARN'
    }).Count
    $failV = @($script:Steps | Where-Object {
        $key = "$($_.Index)"
        $script:Session.Steps.ContainsKey($key) -and $script:Session.Steps[$key].Verdict -eq 'FAIL'
    }).Count
```

- [ ] **Step 2: Update the progress text string**

Find the current `$progTxt` line:
```powershell
    $progTxt = "$progBar  $done/$total complete$(if ($fail -gt 0) { "  ($fail failed)" })"
```

Replace with:
```powershell
    $warnStr = if ($warnV -gt 0) { "  [!!] $warnV" } else { '' }
    $failStr = if ($failV -gt 0) { "  [XX] $failV" } else { '' }
    $progTxt = "$progBar  $done/$total complete$warnStr$failStr"
```

- [ ] **Step 3: Verify**

Run one or two steps that produce WARN or FAIL verdicts (e.g. a device where OneDrive KFM is not fully enabled). Return to the main menu. The progress line should show `[!!] 1` or `[XX] 1` in yellow/red alongside the completion count.

- [ ] **Step 4: Commit**

```powershell
git add Start-PreWipeToolkit.ps1
git commit -m "feat: show WARN/FAIL verdict counts in main menu progress bar (p1-2)"
```

---

## Task 5: Single Step Looper (p2-3)

**Files:**
- Modify: `Start-PreWipeToolkit.ps1` — `Invoke-SingleStep` (~line 1156)

- [ ] **Step 1: Remove the `return` after `Invoke-StepInteractive`**

Find in `Invoke-SingleStep`:
```powershell
            if ($step) {
                Invoke-StepInteractive -Step $step
                return
            }
```

Replace with:
```powershell
            if ($step) {
                Invoke-StepInteractive -Step $step
            }
```

- [ ] **Step 2: Verify**

Run the toolkit. Select `[3] Run Single Step`. Run a step. Confirm the script returns to the step-picker list rather than the main menu. Press `0` to confirm that exits back to the main menu.

- [ ] **Step 3: Commit**

```powershell
git add Start-PreWipeToolkit.ps1
git commit -m "fix: keep single-step picker open after running a step (p2-3)"
```

---

## Task 6: Inline Re-Run of Failed Steps (p3-4)

**Files:**
- Modify: `Start-PreWipeToolkit.ps1` — `Invoke-RunSteps` (~line 1060)

- [ ] **Step 1: Add re-run prompt after `Show-RunSummaryInline`**

In `Invoke-RunSteps`, find the block after `Show-RunSummaryInline`:
```powershell
    $null = Export-HtmlReport -ResultSet $resultArray -RunLabel $RunLabel

    Write-Host '' # Blank line
    Write-Host '  Press any key to return to menu...' -ForegroundColor DarkGray
    $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') # Wait for keypress

    return $resultArray # Return results
```

Replace with:
```powershell
    $null = Export-HtmlReport -ResultSet $resultArray -RunLabel $RunLabel

    $failedResults = @($runResults | Where-Object { $_.Status -eq 'FAIL' -or $_.Verdict -eq 'FAIL' })
    if ($failedResults.Count -gt 0) {
        $failedSteps = @($failedResults | ForEach-Object {
            $idx = $_.Index
            $script:Steps | Where-Object { $_.Index -eq $idx } | Select-Object -First 1
        } | Where-Object { $_ })
        Write-Host ''
        Write-Host -NoNewline "  Re-run $($failedSteps.Count) failed step(s)?  " -ForegroundColor Yellow
        Write-Host -NoNewline '[Y] Yes    [N] No  ' -ForegroundColor DarkCyan
        $rerunKey = Read-MenuKey
        Write-Host ''
        if ($rerunKey -eq 'Y') {
            $null = Invoke-RunSteps -StepsToRun $failedSteps `
                -RunLabel "Retry — $($failedSteps.Count) step(s)" `
                -RunSub 'Re-run of failed steps'
            return $resultArray
        }
    }

    Write-Host ''
    Write-Host '  Press any key to return to menu...' -ForegroundColor DarkGray
    $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')

    return $resultArray
```

- [ ] **Step 2: Verify**

Run a Custom Run that includes a step you can make fail (e.g., run `Register-AutopilotDevice` on an unregistered device). After the summary appears, confirm the re-run prompt shows. Press N, confirm it goes to the "Press any key" prompt. Run again and press Y — confirm only the failed steps are re-run.

- [ ] **Step 3: Commit**

```powershell
git add Start-PreWipeToolkit.ps1
git commit -m "feat: prompt to re-run failed steps after batch run completes (p3-4)"
```

---

## Task 7: HTML Report — CSS Additions

**Files:**
- Modify: `Start-PreWipeToolkit.ps1` — `Export-HtmlReport` CSS here-string (~line 869)

This task adds all CSS needed for Tasks 8–12. Add it once here so subsequent tasks just write HTML.

- [ ] **Step 1: Extend the CSS here-string**

In `Export-HtmlReport`, find the line that ends the existing CSS:
```
  .footer{text-align:center;color:var(--muted);font-size:.75rem;padding:16px;margin-top:24px}
```

Insert the following new CSS classes on the next line, before the closing `</style>`:
```css
  .action-panel{background:#fff7ed;border:1.5px solid #fed7aa;border-radius:8px;padding:16px 20px;margin-bottom:16px}
  .action-panel h3{font-size:.75rem;font-weight:700;color:#9a3412;text-transform:uppercase;letter-spacing:.06em;margin-bottom:10px}
  .action-item{display:flex;gap:10px;align-items:flex-start;margin-bottom:8px;font-size:.8375rem}
  .action-item:last-child{margin-bottom:0}
  .action-icon{flex-shrink:0;width:18px;height:18px;border-radius:50%;display:flex;align-items:center;justify-content:center;font-size:.65rem;font-weight:900;color:#fff;margin-top:1px}
  .action-icon.fail{background:var(--fail)}.action-icon.warn{background:#d97706}
  .action-label{font-weight:600;color:#1e293b;margin-bottom:2px}
  .action-detail{color:#64748b;font-size:.8rem}
  .filter-bar{display:flex;gap:8px;margin-bottom:16px;align-items:center;flex-wrap:wrap}
  .filter-bar .filter-label{font-size:.7rem;font-weight:700;color:var(--muted);text-transform:uppercase;letter-spacing:.08em}
  .filter-btn{padding:4px 14px;border-radius:20px;border:1.5px solid var(--border);background:#fff;font-size:.8rem;font-weight:600;cursor:pointer;color:var(--muted);font-family:inherit}
  .filter-btn.active{background:#0f172a;color:#fff;border-color:#0f172a}
  .phase-jumps{display:flex;gap:6px;margin-left:auto;flex-wrap:wrap}
  .phase-jump{padding:3px 10px;border-radius:20px;border:1px solid var(--border);background:#fff;font-size:.75rem;color:var(--muted);text-decoration:none}
  .phase-header{font-size:.7rem;font-weight:700;text-transform:uppercase;letter-spacing:.1em;color:var(--muted);padding:20px 0 6px;border-bottom:1px solid var(--border);margin-bottom:10px;margin-top:4px}
  .card.prev-session{opacity:.78;border-style:dashed}
  .card.not-run{opacity:.45;border-style:dashed}
  .prev-badge{font-size:.7rem;font-weight:600;color:var(--muted);background:#f1f5f9;border:1px solid var(--border);border-radius:4px;padding:1px 8px;margin-left:8px}
  details summary{cursor:pointer;padding:6px 0;font-size:.8rem;font-weight:600;color:#4f46e5;-webkit-user-select:none;user-select:none;margin-top:6px;list-style:none}
  details summary::-webkit-details-marker{display:none}
  .export-panel{margin-top:24px;padding:14px 18px;background:#f8fafc;border:1px solid var(--border);border-radius:8px;font-size:.8125rem}
  .export-panel h4{font-weight:700;margin-bottom:8px;color:var(--text);font-size:.875rem}
  .export-grid{display:grid;grid-template-columns:3rem 1fr 4rem;gap:3px 12px;align-items:center;color:var(--muted)}
  .export-grid .path{word-break:break-all}
  .export-grid .size{color:var(--text);font-weight:600;text-align:right}
```

- [ ] **Step 2: Verify the HTML still renders**

Run Quick Check. Open the generated HTML report in a browser. Confirm it looks correct (new CSS classes don't break existing layout — they only apply to elements not yet added).

- [ ] **Step 3: Commit**

```powershell
git add Start-PreWipeToolkit.ps1
git commit -m "style: add CSS for action panel, filter bar, consolidated report, export panel"
```

---

## Task 8: HTML Report — Action Items Panel (p1-3)

**Files:**
- Modify: `Start-PreWipeToolkit.ps1` — `Export-HtmlReport` (~line 905) and new helper function `Get-ActionInstruction`

- [ ] **Step 1: Add `Get-ActionInstruction` helper function**

Add this function anywhere in the `#region --- HTML Report ---` block, before `Export-HtmlReport`:

```powershell
function Get-ActionInstruction {
    param([string]$ScriptFile, [string]$VerdictReason)
    switch -Wildcard ($ScriptFile) {
        '*Test-OneDriveSyncStatus*' { return 'Open OneDrive and wait for full sync to complete. Do not wipe until all files are uploaded.' }
        '*Test-OneDriveKFM*'        { return 'Enable Known Folder Move for the affected profile: OneDrive tray icon &rsaquo; Settings &rsaquo; Backup &rsaquo; Manage backup.' }
        '*Find-UnbackedData*'       { return 'Review flagged files with the user and manually back up anything not in OneDrive before wiping.' }
        '*Backup-BrowserBookmarks*' { return 'Remind the user to sign into their browser on the new device to restore synced bookmarks.' }
        '*Test-BitLockerEscrow*'    { return 'Re-run step 23 to escrow the BitLocker key to Entra ID. Do not wipe until the key is backed up.' }
        '*Test-AutopilotReadiness*' { return 'Device does not meet Autopilot hardware requirements. Check TPM version, UEFI mode, and Secure Boot status before proceeding.' }
        '*Get-AutopilotAssignment*' { return 'Assign the device an Autopilot profile in Intune (Devices &rsaquo; Enrollment &rsaquo; Autopilot) before wiping.' }
        '*Register-AutopilotDevice*'{ return 'Hardware hash upload failed. Re-run step 30. If the issue persists, upload the hash CSV manually via Intune.' }
        '*Get-DownloadsSize*'       { return 'Auto-copy to Documents failed. Manually copy the Downloads folder contents to a safe location before wiping.' }
        default                     { return [System.Web.HttpUtility]::HtmlEncode($VerdictReason) }
    }
}
```

- [ ] **Step 2: Insert action items panel into `Export-HtmlReport`**

In `Export-HtmlReport`, find the line that closes the readiness div:
```powershell
    $null = $sb.AppendLine('</div>')
```
(This is the `</div>` that closes the readiness banner block, just before the per-step cards loop.)

After that line, add:
```powershell
    $actionItems = @($ResultSet | Where-Object { $_.Verdict -eq 'FAIL' -or $_.Verdict -eq 'WARN' })
    if ($actionItems.Count -gt 0) {
        $null = $sb.AppendLine("<div class='action-panel'>")
        $null = $sb.AppendLine("<h3>&#9888; Action Items Before Wipe</h3>")
        foreach ($ai in $actionItems) {
            $iconClass = if ($ai.Verdict -eq 'FAIL') { 'fail' } else { 'warn' }
            $iconChar  = if ($ai.Verdict -eq 'FAIL') { '&#10007;' } else { '&#9888;' }
            $label     = [System.Web.HttpUtility]::HtmlEncode($ai.DisplayName)
            $reason    = [System.Web.HttpUtility]::HtmlEncode($ai.VerdictReason)
            $instr     = Get-ActionInstruction -ScriptFile $ai.ScriptPath -VerdictReason $ai.VerdictReason
            $null = $sb.AppendLine("<div class='action-item'>")
            $null = $sb.AppendLine("<div class='action-icon $iconClass'>$iconChar</div>")
            $null = $sb.AppendLine("<div><div class='action-label'>$label &mdash; $reason</div><div class='action-detail'>$instr</div></div>")
            $null = $sb.AppendLine("</div>")
        }
        $null = $sb.AppendLine("</div>")
    }
```

- [ ] **Step 3: Verify**

Run a step that produces a WARN or FAIL verdict. Open the generated HTML report. An orange "Action Items Before Wipe" panel should appear between the readiness banner and the first step card, listing specific instructions. If all verdicts are PASS, the panel should be absent.

- [ ] **Step 4: Commit**

```powershell
git add Start-PreWipeToolkit.ps1
git commit -m "feat: add action items panel to HTML report for FAIL/WARN verdicts (p1-3)"
```

---

## Task 9: HTML Report — Filter Bar and Phase Anchors (p1-4)

**Files:**
- Modify: `Start-PreWipeToolkit.ps1` — `Export-HtmlReport` (filter bar HTML + JS, and `data-verdict` on cards)

- [ ] **Step 1: Compute filter bar counts**

In `Export-HtmlReport`, after the action items panel block (added in Task 8), add:
```powershell
    $issueCount = @($ResultSet | Where-Object { $_.Verdict -eq 'FAIL' -or $_.Verdict -eq 'WARN' }).Count
    $warnCount  = @($ResultSet | Where-Object { $_.Verdict -eq 'WARN' }).Count
    $phaseKeys  = @($script:Steps | Select-Object -ExpandProperty Phase -Unique)
```

- [ ] **Step 2: Emit the filter bar HTML**

Immediately after the counts block:
```powershell
    $null = $sb.AppendLine("<div class='filter-bar'>")
    $null = $sb.AppendLine("<span class='filter-label'>Show:</span>")
    $null = $sb.AppendLine("<button class='filter-btn active' onclick='filterCards(""all"",this)'>All ($($ResultSet.Count))</button>")
    $null = $sb.AppendLine("<button class='filter-btn' onclick='filterCards(""issues"",this)'>Issues Only ($issueCount)</button>")
    $null = $sb.AppendLine("<button class='filter-btn' onclick='filterCards(""warn"",this)'>Warnings ($warnCount)</button>")
    $null = $sb.AppendLine("<div class='phase-jumps'>")
    foreach ($pk in $phaseKeys) {
        $pl = Get-PhaseLabel $pk
        $null = $sb.AppendLine("<a class='phase-jump' href='#phase-$($pk.ToLower())'>$([System.Web.HttpUtility]::HtmlEncode($pl))</a>")
    }
    $null = $sb.AppendLine("</div>")
    $null = $sb.AppendLine("</div>")
```

- [ ] **Step 3: Add filter JavaScript**

Note: `data-verdict` attributes on cards and phase header `id` anchors are added in Task 10 as part of the consolidated loop rewrite. The filter bar here will be fully functional once Task 10 is complete.

Before the `</body>` closing tag, add:
```powershell
    $null = $sb.AppendLine(@'
<script>
function filterCards(mode,btn){
  document.querySelectorAll('.filter-btn').forEach(function(b){b.classList.remove('active')});
  btn.classList.add('active');
  document.querySelectorAll('.card').forEach(function(c){
    var v=c.dataset.verdict;
    if(mode==='all'){c.style.display=''}
    else if(mode==='issues'){c.style.display=(v==='fail'||v==='warn')?'':'none'}
    else if(mode==='warn'){c.style.display=(v==='warn')?'':'none'}
  });
}
</script>
'@)
```

- [ ] **Step 5: Verify**

Run Quick Check. Open the HTML report. Confirm:
- Phase headers ("Scan & Check", "Backup", "Autopilot") appear between groups of cards
- Phase jump links in the filter bar scroll to the correct header
- "Issues Only" button hides all PASS cards
- "All" button shows all cards again

- [ ] **Step 6: Commit**

```powershell
git add Start-PreWipeToolkit.ps1
git commit -m "feat: add filter bar and phase jump links to HTML report (p1-4)"
```

---

## Task 10: HTML Report — Consolidated 31-Step View (p2-4)

**Files:**
- Modify: `Start-PreWipeToolkit.ps1` — `Export-HtmlReport` (cards rendering loop)

Depends on Task 2 (verdict storage). Steps not in the current run are sourced from `session.json`.

- [ ] **Step 1: Replace the per-step cards loop**

Find the existing loop (declared after the filter bar additions from Task 9):
```powershell
    foreach ($r in $ResultSet) {
```

Replace the entire loop with the following consolidated loop. This loop iterates all 31 steps, grouping by phase, and renders current/prior/not-run cards:

```powershell
    $lastPhase   = ''
    $resultIndex = @{}
    foreach ($r in $ResultSet) { $resultIndex["$($r.Index)"] = $r }

    foreach ($step in $script:Steps) {
        if ($step.Phase -ne $lastPhase) {
            $lastPhase = $step.Phase
            $pl = Get-PhaseLabel $lastPhase
            $null = $sb.AppendLine("<div class='phase-header' id='phase-$($lastPhase.ToLower())'>&#8212; $([System.Web.HttpUtility]::HtmlEncode($pl))</div>")
        }

        $stepKey = "$($step.Index)"
        $r = $resultIndex[$stepKey]

        if ($r) {
            # Current run card
            $sc  = switch ($r.Status)  { 'DONE' { 'done' } 'FAIL' { 'fail' } 'SKIP' { 'skip' } default { 'skip' } }
            $vc  = switch ($r.Verdict) { 'PASS' { 'pass' } 'WARN' { 'warn' } 'FAIL' { 'fail' } default { 'pass' } }
            $vl  = switch ($r.Verdict) { 'PASS' { '&#10003; Pass' } 'WARN' { '&#9888; Warn' } 'FAIL' { '&#10007; Fail' } default { '' } }
            $vrCol = switch ($r.Verdict) { 'PASS' { 'var(--pass)' } 'WARN' { '#b45309' } 'FAIL' { 'var(--fail)' } default { 'var(--text)' } }

            $null = $sb.AppendLine("<div class='card' data-verdict='$vc'><div class='card-head'><span class='step-name'>$($r.Index). $([System.Web.HttpUtility]::HtmlEncode($r.DisplayName))</span>")
            $null = $sb.AppendLine("<span><span class='status $sc'>$($r.Status)</span><span class='verdict $vc' title='$([System.Web.HttpUtility]::HtmlEncode($r.VerdictReason))'>$vl</span></span></div>")
            $null = $sb.AppendLine("<div class='card-body'><div class='summary'>$([System.Web.HttpUtility]::HtmlEncode($r.Summary))</div>")
            if ($r.VerdictReason) {
                $null = $sb.AppendLine("<div class='summary' style='margin-top:4px;font-weight:600;color:$vrCol'>$([System.Web.HttpUtility]::HtmlEncode($r.VerdictReason))</div>")
            }
            $tableHtml = Get-HtmlTable -Parsed $r.ParsedData -ScriptFile $r.ScriptPath
            if ($tableHtml) { $null = $sb.AppendLine($tableHtml) }
            $null = $sb.AppendLine('</div></div>')

        } elseif ($script:Session.Steps.ContainsKey($stepKey) -and $script:Session.Steps[$stepKey].Status -and $script:Session.Steps[$stepKey].Status -ne 'not-run') {
            # Prior session card
            $sd       = $script:Session.Steps[$stepKey]
            $priorVc  = switch ($sd.Verdict) { 'PASS' { 'pass' } 'WARN' { 'warn' } 'FAIL' { 'fail' } default { 'pass' } }
            $priorVl  = switch ($sd.Verdict) { 'PASS' { '&#10003; Pass' } 'WARN' { '&#9888; Warn' } 'FAIL' { '&#10007; Fail' } default { '' } }
            $priorSc  = switch ($sd.Status)  { 'DONE' { 'done' } 'FAIL' { 'fail' } 'SKIP' { 'skip' } default { 'skip' } }
            $priorTs  = if ($sd.Timestamp) { try { ([datetime]$sd.Timestamp).ToString('yyyy-MM-dd HH:mm') } catch { $sd.Timestamp } } else { 'prior session' }

            $null = $sb.AppendLine("<div class='card prev-session' data-verdict='$priorVc'><div class='card-head'>")
            $null = $sb.AppendLine("<span class='step-name'>$($step.Index). $([System.Web.HttpUtility]::HtmlEncode($step.DisplayName)) <span class='prev-badge'>Prior session &middot; $priorTs</span></span>")
            $null = $sb.AppendLine("<span><span class='status $priorSc'>$($sd.Status)</span>$(if ($sd.Verdict) { "<span class='verdict $priorVc'>$priorVl</span>" })</span></div>")
            if ($sd.VerdictReason) {
                $null = $sb.AppendLine("<div class='card-body'><div class='summary'>$([System.Web.HttpUtility]::HtmlEncode($sd.VerdictReason))</div></div>")
            }
            $null = $sb.AppendLine('</div>')

        } else {
            # Not yet run placeholder
            $null = $sb.AppendLine("<div class='card not-run' data-verdict='none'><div class='card-head'>")
            $null = $sb.AppendLine("<span class='step-name'>$($step.Index). $([System.Web.HttpUtility]::HtmlEncode($step.DisplayName))</span>")
            $null = $sb.AppendLine("<span><span class='status skip' style='background:#94a3b8'>NOT RUN</span></span></div>")
            $null = $sb.AppendLine('</div>')
        }
    }
```

- [ ] **Step 2: Verify no duplicate phase-header code exists**

The old `foreach ($r in $ResultSet)` loop is fully replaced by the new loop in Step 1. Confirm there is no leftover `$lastPhase` variable declaration or phase-header `AppendLine` call outside the new loop.

- [ ] **Step 3: Verify**

Run only Quick Check (12 steps). Open the HTML. Confirm:
- All 31 step cards appear, grouped under correct phase headers
- The 12 steps just run show normal (solid border) cards
- Steps run in prior sessions show dashed/muted cards with "Prior session · date" badge
- Steps never run show "NOT RUN" placeholder cards
- Filter bar shows the correct count for the 12 current-run steps

- [ ] **Step 4: Commit**

```powershell
git add Start-PreWipeToolkit.ps1
git commit -m "feat: HTML report shows all 31 steps across sessions (p2-4)"
```

---

## Task 11: HTML Report — Remove Row Caps (p3-1, p3-2)

**Files:**
- Modify: `Start-PreWipeToolkit.ps1` — `Get-HtmlTable` (~line 750)

- [ ] **Step 1: Remove the 15-row limit**

In `Get-HtmlTable`, find:
```powershell
    $limit = [Math]::Min($rows.Count, 15)
    for ($i = 0; $i -lt $limit; $i++) {
```

Replace with:
```powershell
    for ($i = 0; $i -lt $rows.Count; $i++) {
```

Then find and delete the overflow row:
```powershell
    if ($rows.Count -gt 15) {
        $null = $html.AppendLine("<tr><td colspan='$($cols.Count)' style='color:var(--muted);font-style:italic'>… and $($rows.Count - 15) more rows</td></tr>")
    }
```

Delete those 3 lines entirely.

- [ ] **Step 2: Remove the 10-application cap**

In `Get-HtmlTable`, find the `'*Get-InstalledApplications*'` case:
```powershell
            '*Get-InstalledApplications*' {
                if ($Parsed.Applications) { $cols = @('DisplayName','DisplayVersion','Publisher','Scope'); $rows = @($Parsed.Applications | Select-Object -First 10) }
            }
```

Replace with:
```powershell
            '*Get-InstalledApplications*' {
                if ($Parsed.Applications) { $cols = @('DisplayName','DisplayVersion','Publisher','Scope'); $rows = @($Parsed.Applications) }
            }
```

- [ ] **Step 3: Wrap the applications table in a collapsible `<details>` element**

In `Get-HtmlTable`, the function currently returns the full `$html.ToString()`. Add a wrapper for the applications case. After building `$html` (which contains the `<table>` string), add this conditional wrap before the final `return`:

```powershell
    $tableStr = $html.ToString()
    if ($ScriptFile -match 'Get-InstalledApplications' -and $rows.Count -gt 0) {
        return "<details><summary>Show all $($rows.Count) applications &#8250;</summary>$tableStr</details>"
    }
    return $tableStr
```

Remove the existing `return $html.ToString()` line.

- [ ] **Step 4: Verify**

Run step 6 (Get-InstalledApplications). Open the HTML. Confirm:
- The applications section shows a "Show all N applications ›" toggle, collapsed by default
- Expanding it shows all applications, not just 10
- Other tables (e.g. printers, drive mappings) show all rows without a "… and N more" truncation line

- [ ] **Step 5: Commit**

```powershell
git add Start-PreWipeToolkit.ps1
git commit -m "fix: remove 15-row table cap and 10-app limit from HTML report (p3-1, p3-2)"
```

---

## Task 12: Export Report Feedback (p4-2)

**Files:**
- Modify: `Start-PreWipeToolkit.ps1` — `Export-HtmlReport` (add export panel to HTML) and `Export-SessionReport` (add file sizes to terminal output, add HTML generation)

- [ ] **Step 1: Add export panel to `Export-HtmlReport`**

`Export-HtmlReport` already writes the HTML file at path `$htmlPath`. After the file is written (after the `try { $sb.ToString() | Set-Content ...` block), add an export panel to the HTML itself.

Find the try block that writes the HTML:
```powershell
    try {
        $sb.ToString() | Set-Content $htmlPath -Encoding UTF8 -Force
        Write-Log "HTML report: $htmlPath"
        Write-Host "  HTML report: $htmlPath" -ForegroundColor Cyan
    } catch {
```

Before that try block, insert the export panel HTML into `$sb`:
```powershell
    $htmlSizeKb = [Math]::Round($sb.Length / 1024, 0)
    $null = $sb.AppendLine("<div class='export-panel'><h4>&#128190; This Report</h4>")
    $null = $sb.AppendLine("<div class='export-grid'>")
    $null = $sb.AppendLine("<span>HTML</span><span class='path'>$([System.Web.HttpUtility]::HtmlEncode($htmlPath))</span><span class='size'>~$htmlSizeKb KB</span>")
    $null = $sb.AppendLine("</div></div>")
    $null = $sb.AppendLine("<div class='footer'>Generated $now by Start-PreWipeToolkit.ps1</div>")
    $null = $sb.AppendLine('</div></body></html>')
```

Note: remove any existing `$null = $sb.AppendLine("<div class='footer'>...")` and closing tags that were already appended earlier, since they're now included in the block above. Ensure the footer and closing tags appear only once.

- [ ] **Step 2: Update `Export-SessionReport` to generate HTML and show file sizes**

In `Export-SessionReport`, after the TXT export try/catch block, add:

```powershell
    $htmlPath = $null
    try {
        $allResults = @($script:Steps | ForEach-Object {
            $key = "$($_.Index)"
            $sd  = if ($script:Session.Steps.ContainsKey($key)) { $script:Session.Steps[$key] } else { $null }
            [PSCustomObject]@{
                Index         = $_.Index
                Phase         = $_.Phase
                DisplayName   = $_.DisplayName
                ScriptPath    = $_.ScriptPath
                Status        = if ($sd) { $sd.Status } else { 'not-run' }
                Summary       = if ($sd -and $sd.VerdictReason) { $sd.VerdictReason } else { '' }
                ParsedData    = $null
                Elapsed       = $null
                Verdict       = if ($sd) { $sd.Verdict } else { $null }
                VerdictReason = if ($sd) { $sd.VerdictReason } else { $null }
            }
        })
        $htmlPath = Export-HtmlReport -ResultSet $allResults -RunLabel 'Session Export'
    } catch {
        Write-ErrorLog "HTML export failed: $_"
        Write-Host "  HTML export failed: $_" -ForegroundColor Red
    }
```

Then replace the existing terminal output (the individual `Write-Host "  JSON : ..."` lines) with consolidated output that includes file sizes:

```powershell
    Write-Host ''
    Write-Host '  Exported:' -ForegroundColor Cyan
    foreach ($entry in @(
        @{ Label = 'JSON'; Path = $jsonPath }
        @{ Label = 'TXT '; Path = $txtPath  }
        @{ Label = 'HTML'; Path = $htmlPath }
    )) {
        if ($entry.Path -and (Test-Path $entry.Path)) {
            $kb = [Math]::Round((Get-Item $entry.Path).Length / 1024, 0)
            Write-Host -NoNewline "    $($entry.Label)  " -ForegroundColor DarkGray
            Write-Host -NoNewline $entry.Path -ForegroundColor Gray
            Write-Host "  ($kb KB)" -ForegroundColor DarkGray
        }
    }
```

- [ ] **Step 3: Verify**

Run any steps. Press menu `[6] Export Report`. Confirm:
- Terminal shows three export lines with file paths and KB sizes
- Opening the generated HTML shows an "Export Panel" section at the bottom with the file path

- [ ] **Step 4: Commit**

```powershell
git add Start-PreWipeToolkit.ps1
git commit -m "feat: show export paths and file sizes after export (p4-2)"
```

---

## Task 13: Hudu Integration (p4-1)

**Files:**
- Modify: `Start-PreWipeToolkit.ps1` — add `$script:HuduBaseUrl`, `Invoke-HuduReport`, menu display, and main loop switch case

- [ ] **Step 1: Add `$script:HuduBaseUrl` initialisation**

In the `#region --- Hardware Info ---` block (or near other `$script:` variable declarations), add:
```powershell
$script:HuduBaseUrl = $null
```

- [ ] **Step 2: Add `Invoke-HuduReport` function**

Add the following function in the `#region --- Workflow Actions ---` section:

```powershell
function Invoke-HuduReport {
    Clear-Host
    Write-Banner
    Write-Host ''
    Write-Host "  $('═' * 62)" -ForegroundColor Cyan
    Write-Host '  PUSH TO HUDU' -ForegroundColor White
    Write-Host "  $('═' * 62)" -ForegroundColor Cyan
    Write-Host ''

    if (-not (Get-Module HuduAPI -ListAvailable -ErrorAction SilentlyContinue)) {
        Write-Host '  HuduAPI module is not installed.' -ForegroundColor Yellow
        Write-Host '  Install with: Install-Module HuduAPI -Scope CurrentUser' -ForegroundColor DarkGray
        Write-Host ''
        Write-Host '  [I] Install now    [N] Cancel  ' -ForegroundColor DarkCyan -NoNewline
        $k = Read-MenuKey; Write-Host ''
        if ($k -ne 'I') { return }
        try {
            Write-Host '  Installing HuduAPI...' -ForegroundColor Gray
            Install-Module HuduAPI -Scope CurrentUser -Force -ErrorAction Stop
            Write-Host '  Installed successfully.' -ForegroundColor Green
        } catch {
            Write-Host "  Install failed: $_" -ForegroundColor Red
            Write-Host ''
            Write-Host '  Press any key to return...' -ForegroundColor DarkGray
            $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
            return
        }
    }

    if (-not $script:HuduBaseUrl) {
        Write-Host '  Hudu base URL (e.g. https://your-hudu.com): ' -ForegroundColor DarkCyan -NoNewline
        $script:HuduBaseUrl = (Read-Host).Trim()
        if (-not $script:HuduBaseUrl) { return }
    } else {
        Write-Host "  Using: $($script:HuduBaseUrl)" -ForegroundColor DarkGray
    }

    Write-Host ''
    Write-Host '  Pushing report to Hudu...' -ForegroundColor Gray
    Write-Host ''

    $huduScript = Join-Path $PSScriptRoot 'Scripts\AutopilotReadiness\Report-AutopilotReadinessToHudu.ps1'
    try {
        & $huduScript -HuduBaseUrl $script:HuduBaseUrl
        Write-Host ''
        Write-Host '  Report pushed to Hudu successfully.' -ForegroundColor Green
    } catch {
        Write-Host ''
        Write-Host "  Push failed: $_" -ForegroundColor Red
    }

    Write-Host ''
    Write-Host '  Press any key to return to menu...' -ForegroundColor DarkGray
    $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
}
```

- [ ] **Step 3: Add menu option `[8]` to `Show-MainMenu`**

In `Show-MainMenu`, find the separator line before `[Q] Quit` and add the Hudu option conditionally:
```powershell
    if (Test-Path $SessionFile) {
        Write-Host ("  ║ {0} ║" -f '  [8]  Push to Hudu'.PadRight($inner)) -ForegroundColor Gray
    }
```

Add it in the lower section of the menu, after the `[7] Reset Session` line.

- [ ] **Step 4: Add `'8'` case to the main loop switch**

In the main loop switch block (around line 1388), add:
```powershell
            '8' { if (Test-Path $SessionFile) { Invoke-HuduReport } }
```

- [ ] **Step 5: Verify**

Run any step so session.json exists. Return to main menu. Option `[8] Push to Hudu` should appear. Select it. Confirm it prompts for the URL. (You don't need a real Hudu instance — confirm the flow reaches the URL prompt and handles cancel correctly.)

- [ ] **Step 6: Commit**

```powershell
git add Start-PreWipeToolkit.ps1
git commit -m "feat: add Push to Hudu option to main menu (p4-1)"
```

---

## Task 14: Staleness Check in Get-PreWipeSummary (p3-5)

**Files:**
- Modify: `Scripts/AutopilotReadiness/Get-PreWipeSummary.ps1` — JSON file reading loop (~line 80)

- [ ] **Step 1: Add staleness computation inside the JSON reading loop**

In `Get-PreWipeSummary.ps1`, find the section inside the `foreach ($fileName in $ScriptMap.Keys)` loop where the JSON is parsed:

```powershell
    if (Test-Path $filePath) {
        $entry.Found = $true
        try {
            $json = Get-Content $filePath -Raw | ConvertFrom-Json
            $entry.Timestamp = $json.Timestamp
```

After `$entry.Timestamp = $json.Timestamp`, add:
```powershell
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
```

- [ ] **Step 2: Add stale warning to interactive output**

In `Get-PreWipeSummary.ps1`, find the section that writes each script's result to the console (in interactive mode). It will be inside the loop processing `$ScriptResults`. Where each entry is printed, add a stale indicator:

```powershell
        $staleTag = if ($result.Stale) { " [STALE — $($result.StaleHours)h old]" } else { '' }
```

And append `$staleTag` to the line that writes the script name/status to the console.

- [ ] **Step 3: Add stale warning to the overall verdict**

In `Get-PreWipeSummary.ps1`, find where `$OverallVerdict` is set (near the end of the script). After it is set, add:

```powershell
$hasStaleBlockers = @($ScriptResults | Where-Object { $_.Stale -and $_.Status -ne 'NOT_RUN' }).Count -gt 0
if ($hasStaleBlockers) {
    $OverallVerdict = "$OverallVerdict (WARNING: some results are over 24h old — re-run affected steps)"
}
```

- [ ] **Step 4: Verify**

Copy a report JSON file in `C:\PreWipeOutput\Logs\` and manually set its `Timestamp` field to a date more than 24 hours ago. Run `Get-PreWipeSummary.ps1` interactively. The stale entry should show a yellow `[STALE — Xh old]` tag.

- [ ] **Step 5: Commit**

```powershell
git add Scripts/AutopilotReadiness/Get-PreWipeSummary.ps1
git commit -m "feat: flag stale JSON inputs (>24h) in Get-PreWipeSummary (p3-5)"
```

---

## Task 15: QuickCheckIndices Comment (p4-3)

**Files:**
- Modify: `Start-PreWipeToolkit.ps1` — `$script:QuickCheckIndices` (~line 92)

- [ ] **Step 1: Add the rationale comment**

Find:
```powershell
$script:QuickCheckIndices = @(11, 12, 1, 2, 3, 6, 13, 18, 19, 20, 4, 29) # 12 core steps for quick scan
```

Replace with:
```powershell
# Quick Check step selection — 12 steps that assess wipe safety without modifying any settings.
# Selection rationale:
#   11, 12 — OneDrive KFM + sync: primary data-loss blockers (run first)
#    1     — Unbacked data scan: identifies at-risk files outside OneDrive
#    2     — Downloads size: flags large folders that won't survive wipe
#    3     — Drive mappings: documents network drives to reconnect post-wipe
#    6     — Installed apps: documents software to reinstall
#   13     — Storage mode: identifies RAID configurations that complicate reinstall
#   18, 19, 20 — Browser bookmarks, desktop background, Outlook signatures: lightweight backups
#    4     — Printers: inventory only, no changes made
#   29     — Autopilot assignment: confirms Autopilot profile is present on device
$script:QuickCheckIndices = @(11, 12, 1, 2, 3, 6, 13, 18, 19, 20, 4, 29)
```

- [ ] **Step 2: Commit**

```powershell
git add Start-PreWipeToolkit.ps1
git commit -m "docs: document QuickCheckIndices step selection rationale (p4-3)"
```

---

## Task 16: Orchestrator File Split (p4-4)

**Files:**
- Create: `Scripts/Common/Toolkit-UI.ps1`
- Create: `Scripts/Common/Toolkit-Report.ps1`
- Create: `Scripts/Common/Toolkit-Execution.ps1`
- Modify: `Start-PreWipeToolkit.ps1` — add dot-source block, remove moved functions

**Do this task last.** All logic must be verified working before splitting. The split is a pure code-move.

- [ ] **Step 1: Create `Scripts/Common/Toolkit-UI.ps1`**

Create the file and move the following functions from `Start-PreWipeToolkit.ps1` into it, keeping them in the same order:
- `Write-Log`
- `Write-ErrorLog`
- `Read-MenuKey`
- `Get-PhaseLabel`
- All banner variables and functions: `$script:FullBanner`, `$script:CompactBanner`, `$script:IsInitialBanner`, `Write-BannerFull`, `Write-Banner`, `Show-InitialBanner`
- `Get-ProgressBarString`
- `Show-MainMenu`
- `Write-RunHeader`
- `Write-StepLine`
- `Write-StepResultLine`
- `Show-RunSummaryInline`
- `Show-StepListTable`
- `Show-SessionSummary`

Add a header comment at the top of the new file:
```powershell
# Toolkit-UI.ps1 — Terminal display functions for Start-PreWipeToolkit.ps1
# Dot-sourced by the orchestrator. Do not run directly.
```

- [ ] **Step 2: Create `Scripts/Common/Toolkit-Report.ps1`**

Create the file and move these functions from `Start-PreWipeToolkit.ps1`:
- `Get-ActionInstruction` (added in Task 8)
- `Get-StepSummary`
- `Get-StepVerdict`
- `Get-HtmlTable`
- `Export-HtmlReport`
- `Export-SessionReport`

Add header:
```powershell
# Toolkit-Report.ps1 — HTML report and session export functions for Start-PreWipeToolkit.ps1
# Dot-sourced by the orchestrator. Do not run directly.
```

- [ ] **Step 3: Create `Scripts/Common/Toolkit-Execution.ps1`**

Create the file and move:
- `Invoke-StepCapture`
- `Invoke-StepInteractive`
- `Invoke-RunSteps`

Add header:
```powershell
# Toolkit-Execution.ps1 — Step execution functions for Start-PreWipeToolkit.ps1
# Dot-sourced by the orchestrator. Do not run directly.
```

- [ ] **Step 4: Add dot-source block to `Start-PreWipeToolkit.ps1`**

At the top of `Start-PreWipeToolkit.ps1`, after the `param([switch]$NonInteractive)` line and before `#region --- Init / Admin Check ---`, add:

```powershell
. (Join-Path $PSScriptRoot 'Scripts\Common\Toolkit-UI.ps1')
. (Join-Path $PSScriptRoot 'Scripts\Common\Toolkit-Report.ps1')
. (Join-Path $PSScriptRoot 'Scripts\Common\Toolkit-Execution.ps1')
```

- [ ] **Step 5: Remove moved functions from `Start-PreWipeToolkit.ps1`**

Delete the function bodies that were moved to the three new files. The `#region` markers that enclosed them can be removed or updated to just `#region --- [UI | Report | Execution] — see Scripts/Common/Toolkit-*.ps1 ---`.

- [ ] **Step 6: Verify**

Run `.\Start-PreWipeToolkit.ps1`. The menu should appear and all functionality should work identically to before the split. Run Quick Check and verify the HTML report generates correctly. Run `Export-SessionReport` (option 6) and verify the export still works.

- [ ] **Step 7: Commit**

```powershell
git add Start-PreWipeToolkit.ps1 Scripts/Common/Toolkit-UI.ps1 Scripts/Common/Toolkit-Report.ps1 Scripts/Common/Toolkit-Execution.ps1
git commit -m "refactor: split orchestrator into Toolkit-UI, Toolkit-Report, Toolkit-Execution modules (p4-4)"
```

---

## Self-Review Checklist

- [x] **p3-3** Phase label split → Task 1
- [x] **Verdict storage** (prerequisite) → Task 2
- [x] **p1-1** Session summary verdict column → Task 3
- [x] **p1-2** Main menu verdict counts → Task 4
- [x] **p2-3** Single step looper → Task 5
- [x] **p3-4** Inline re-run → Task 6
- [x] **CSS additions** (prerequisite for HTML tasks) → Task 7
- [x] **p1-3** Action items panel → Task 8
- [x] **p1-4** Filter bar + phase anchors → Task 9
- [x] **p2-4** Consolidated 31-step view → Task 10
- [x] **p3-1, p3-2** Row cap removal → Task 11
- [x] **p4-2** Export feedback → Task 12
- [x] **p4-1** Hudu integration → Task 13
- [x] **p3-5** Staleness check → Task 14
- [x] **p4-3** QuickCheckIndices comment → Task 15
- [x] **p4-4** File split → Task 16
