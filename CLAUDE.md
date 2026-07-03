# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repo Is

AshesToAutopilot is a Windows PowerShell toolkit for pre-wipe device preparation. A tech runs `Start-PreWipeToolkit.ps1` on a Windows device before reimaging it; the toolkit scans, backs up, configures, and validates Autopilot readiness. It runs on **Windows only** and requires **Administrator elevation**. There are no external module dependencies for the core toolkit.

The repo also contains a **portable Electron desktop app** (`app/` + `package.json`) that fronts the same PowerShell scripts — see "Desktop App (Electron)" below.

## Linting

PSScriptAnalyzer is the only linter. It is installed in the Claude Code web session environment automatically via `.claude/hooks/session-start.sh`.

```powershell
# Lint the entire repo (matches CI)
Invoke-ScriptAnalyzer -Path . -Recurse -IncludeRule 'PSAvoidGlobalAliases','PSAvoidUsingConvertToSecureStringWithPlainText'

# Lint a single file
Invoke-ScriptAnalyzer -Path .\Scripts\DataCollection\Find-UnbackedData.ps1
```

CI runs four rules (`PSAvoidGlobalAliases`, `PSAvoidUsingConvertToSecureStringWithPlainText`, `PSUseBOMForUnicodeEncodedFile`, `PSAvoidAssignmentToAutomaticVariable`) via `.github/workflows/powershell.yml` on every push/PR to `main`. Results are uploaded to GitHub Code Scanning as SARIF.

## Testing

`Tests/` contains the regression gates, all runnable on pwsh (any OS) and Windows PowerShell 5.1. CI runs the first three on every push/PR:

```powershell
.\Tests\Test-Ps51Compat.ps1      # encoding + PS 5.1 parse simulation + PS7-operator scan
.\Tests\Test-ToolkitEngine.ps1   # step engine exit-code/stream-capture tests
.\Tests\Test-VerdictLogic.ps1    # verdict evaluator (fail-closed wipe-safety) rules
.\Tests\Invoke-ToolkitSelfTest.ps1 [-IncludeReadOnlySteps]  # on-device pre-deployment check (Windows)
```

Encoding policy: **every `.ps1` file carries a UTF-8 BOM.** Windows PowerShell 5.1 reads BOM-less files as ANSI, and non-ASCII characters (em-dashes, box-drawing) decode to smart quotes that break parsing. `Test-Ps51Compat.ps1` fails any non-ASCII file without a BOM.

## Running Scripts

Scripts run on Windows and require Admin elevation. They cannot execute in the Linux container that Claude Code uses; PSScriptAnalyzer and the `Tests/` suites are the available substitutes for functional testing (the Common-module functions under test are pure enough to run on pwsh anywhere).

```powershell
# Launch the interactive toolkit
.\Start-PreWipeToolkit.ps1

# Non-interactive mode — emits current session state as JSON, then exits
.\Start-PreWipeToolkit.ps1 -NonInteractive | ConvertFrom-Json

# Run any individual script in non-interactive mode
.\Scripts\DataCollection\Find-UnbackedData.ps1 -NonInteractive | ConvertFrom-Json
```

## Release Build

```bash
git archive --format=zip --output=AshesToAutopilot.zip HEAD
# Attach AshesToAutopilot.zip to the GitHub release

# Portable desktop app (run on Windows; requires Node.js 18+)
npm install
npm run dist   # emits dist/AshesToAutopilot-Portable-<version>.exe
```

Before cutting a release: all three `Tests/` suites must pass, `CHANGELOG.md` gets an entry for any tech-visible behavior change, and a Windows device should run `Tests\Invoke-ToolkitSelfTest.ps1 -IncludeReadOnlySteps` (elevated) at least once per release.

## Adding a New Step Script

Checklist — every item is load-bearing:

1. Follow `Scripts/DataCollection/Get-TeamsData.ps1` as the reference implementation (init skeleton, `-LiteralPath`/`-Force` discipline, hive lifecycle).
2. Save with a **UTF-8 BOM** (CI-enforced; BOM-less non-ASCII breaks PS 5.1 parsing).
3. Write the report JSON to `Logs\<Script-BaseName>-Report.json` — single-step runs re-read this exact filename.
4. Add a mapping case to `Get-StepVerdictFromData` in `Toolkit-Report.ps1` (and usually `Get-StepSummary`/`Get-HtmlTable`). Unmapped scripts surface as WARN, never PASS.
5. Exit `0` when the script ran to completion (even with warning-level findings — the verdict mapping grades severity); exit `1` only for crashes or blocking failures, and emit the result JSON before any `exit 1`.
6. Fail closed: a check that cannot collect its data must set an `Error`/`CollectionError` field that the verdict mapping turns into WARN — never let an empty result read as a clean PASS.
7. Register the step in `$script:Steps` in `Start-PreWipeToolkit.ps1` and, if it belongs in the summary, in `$ScriptMap` in `Get-PreWipeSummary.ps1`. The desktop app's `app/steps.js` mirrors `$script:Steps` — **keep it in sync too.**
8. Run `.\Tests\Test-Ps51Compat.ps1` and the other suites before committing.

## Desktop App (Electron)

`app/` contains an Electron host that replaces the console orchestrator UI while reusing the PowerShell engine:

- `app/main.js` — main process. Spawns `powershell.exe` per step via `Scripts/Common/Invoke-ToolkitStep.ps1`, persists the same `C:\PreWipeOutput\session.json` schema as `Save-Session`, and generates the HTML report via `Scripts/Common/Export-ToolkitReport.ps1`. The console toolkit and the app are session-interoperable.
- `app/steps.js` — JS mirror of `$script:Steps`, `$script:QuickCheckIndices`, and `$script:PhaseLabels` from `Start-PreWipeToolkit.ps1`. **Keep in sync when steps change.**
- `app/preload.js` + `app/renderer/` — context-isolated IPC bridge and the UI (vanilla HTML/CSS/JS, no framework).
- Host shims print a JSON result envelope between `===ATA_RESULT_BEGIN===` / `===ATA_RESULT_END===` sentinel lines; `extractEnvelope()` in `main.js` parses it.
- electron-builder packages a Windows `portable` target with `requireAdministrator`; `Scripts/` and `Start-PreWipeToolkit.ps1` ship as `extraResources` under `resources/toolkit` so PowerShell can execute them from disk.
- `npm start` runs the app in dev against the repo tree. On non-Windows it opens in UI preview mode (steps can't execute); a headless smoke test is available via `xvfb-run -a env ATA_SCREENSHOT=/tmp/ui.png npx electron --no-sandbox .`

---

## Architecture

### Orchestrator → Execution Engine → Individual Scripts

`Start-PreWipeToolkit.ps1` is the sole entry point. It dot-sources three Common modules at startup:

```powershell
. Scripts\Common\Toolkit-UI.ps1
. Scripts\Common\Toolkit-Report.ps1
. Scripts\Common\Toolkit-Execution.ps1
```

It defines `$script:Steps` — an array of 27 `PSCustomObject` entries, each with `Index`, `Phase`, `DisplayName`, `ScriptPath`, and `Status`. The main loop maps key presses to workflow functions (`Invoke-QuickCheck`, `Invoke-FullPrep`, `Invoke-SingleStep`, `Invoke-CustomRun`), all of which ultimately call `Invoke-RunSteps` in `Toolkit-Execution.ps1`.

`Invoke-StepCapture` (in `Toolkit-Execution.ps1`) invokes each script in-process via the call operator with `-NonInteractive` (no child process — a step that calls `[Environment]::Exit()` would terminate the whole toolkit), captures the success stream as a string, parses it as JSON, and evaluates a verdict independently of the exit code.

### Script I/O Contract

Every script in `Scripts/` follows this pattern:

- Accepts `-NonInteractive` as a switch parameter
- Emits structured JSON to stdout (always for data-collection scripts; required for orchestrator use)
- Returns exit code `0` for success or non-blocking warnings, `1` for crashes or blocking failures
- Writes its JSON to `Logs\<Script-BaseName>-Report.json` (single-step runs re-read this file)

Scripts do NOT emit a `Verdict` field. Verdicts (`PASS`/`WARN`/`FAIL`) are computed centrally by per-script mappings in `Get-StepVerdict` (`Toolkit-Report.ps1`) from the parsed JSON — a new script needs a mapping case there, or its results silently default to PASS. Exit code determines `DONE` vs `FAIL` status; the verdict drives the color-coded display and report.

### Verdict Semantics

| Verdict | Display      | Meaning                          |
|---------|--------------|----------------------------------|
| `PASS`  | `[OK]` green | Safe to proceed                  |
| `WARN`  | `[!!]` yellow | Review before wiping            |
| `FAIL`  | `[XX]` red   | Blocking — must resolve before wipe |

### Session Persistence

Session state is stored in `C:\PreWipeOutput\session.json` and survives reboots. `Import-Session` loads it on startup and restores step statuses into `$script:Steps`. `Update-SessionStep` + `Save-Session` write to disk after each step completes. The `-NonInteractive` flag on the orchestrator itself emits this session state as JSON and exits without opening the menu.

### Step Index Numbering

Steps are numbered 1–32 with intentional gaps (indices 24–27 and 30 are absent). The Quick Check preset runs indices `@(11, 12, 1, 2, 3, 6, 13, 18, 19, 20, 4, 29)` — the selection rationale is documented in the comments directly above `$script:QuickCheckIndices` in `Start-PreWipeToolkit.ps1`.

### Common Module Responsibilities

| File | Provides |
|------|----------|
| `Initialize-Toolkit.ps1` | `Write-Log`, `Write-ErrorLog`, admin elevation check |
| `Get-ActiveUserProfile.ps1` | User profile enumeration (filters system/service accounts and profiles inactive >30 days); registry hive mount/unmount for reading offline `NTUSER.DAT` |
| `Toolkit-Execution.ps1` | `Invoke-RunSteps`, `Invoke-StepCapture`, `Invoke-StepInteractive` |
| `Toolkit-UI.ps1` | ASCII banners, menu rendering, `Read-MenuKey`, `Show-StepListTable`, `Show-MainMenu`, `Show-SessionSummary` |
| `Toolkit-Report.ps1` | `Get-StepVerdict`, `Get-StepSummary`, HTML report generation, `Export-SessionReport`, JSON/TXT session export |
| `Find-DellCommandTool.ps1` | Locates Dell Command Update and Dell Command Configure executables |
| `Get-ToolkitHostInfo.ps1` | Desktop-app shim: device identity, elevation, primary profile as JSON |
| `Invoke-ToolkitStep.ps1` | Desktop-app shim: standalone `Invoke-StepCapture` equivalent — runs one step, returns status/verdict/summary envelope |
| `Export-ToolkitReport.ps1` | Desktop-app shim: rebuilds orchestrator state from a JSON payload and calls `Export-HtmlReport` |

### Script Organization by Phase

Scripts are grouped into four subdirectories matching the `Phase` field on each step:

- **`DataCollection/`** — 10 read-only inventory scripts; always emit JSON to stdout
- **`ConfigurationChecks/`** — 4 read-only status checks (OneDrive KFM/sync, storage mode, WinRE)
- **`ConfigurationChanges/`** — 10 scripts that back up user data or modify settings (BitLocker, WoL, Dell updates, backups)
- **`AutopilotReadiness/`** — 4 orchestrated steps for TPM/UEFI validation and device registration; plus `Report-AutopilotReadinessToHudu.ps1` which is run manually post-wipe and requires the `HuduAPI` module

### Dell-Specific Behavior

`Invoke-BiosUpdate.ps1` and `Invoke-DriverUpdate.ps1` depend on Dell Command Update and Dell Command Configure. `Find-DellCommandTool.ps1` handles discovery; `Install-DellCommandTools.ps1` (not a menu step — invoked on demand by the two updaters) downloads and installs them. `Test-AutopilotReadiness.ps1` contains explicit detection logic for known-problematic TPM manufacturers (Infineon, STMicro, Nuvoton).

### Output Location (on the Windows target device)

The root is ACL-restricted to SYSTEM + Administrators at creation (both the orchestrator and `Initialize-Toolkit.ps1` apply it, SID-based and idempotent) because it can hold cleartext Wi-Fi PSKs and captured BitLocker recovery keys.

```
C:\PreWipeOutput\
├── session.json                  # Live session state — survives reboots
├── PreWipeReport_<PC>_<ts>.html  # HTML report generated after each run
├── PreWipeReport_<PC>_<ts>.json  # JSON session export
├── PreWipeReport_<PC>_<ts>.txt   # Plain text export
├── errors.log                    # Aggregated errors from step scripts
├── Bookmarks\  Signatures\  Taskbar\  Wallpaper\   # Per-user backup folders
├── WiFiProfiles\                 # Exported Wi-Fi XMLs (cleartext PSKs)
├── BitLockerRecoveryKeys\        # Only on devices with no Entra/AD escrow target
├── Scripts\                      # Cached community Autopilot script
└── Logs\
    ├── *.log                     # Per-script run logs (incl. Start-PreWipeToolkit_Errors_<date>.log)
    └── *-Report.json             # Structured JSON output per script
```
