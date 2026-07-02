# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repo Is

AshesToAutopilot is a Windows PowerShell toolkit for pre-wipe device preparation. A tech runs `Start-PreWipeToolkit.ps1` on a Windows device before reimaging it; the toolkit scans, backs up, configures, and validates Autopilot readiness. It runs on **Windows only** and requires **Administrator elevation**. There are no external module dependencies for the core toolkit.

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

Scripts run on Windows and require Admin elevation. They cannot execute in the Linux container that Claude Code uses; PSScriptAnalyzer is the available substitute for functional testing.

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
```

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

### Script Organization by Phase

Scripts are grouped into four subdirectories matching the `Phase` field on each step:

- **`DataCollection/`** — 10 read-only inventory scripts; always emit JSON to stdout
- **`ConfigurationChecks/`** — 4 read-only status checks (OneDrive KFM/sync, storage mode, WinRE)
- **`ConfigurationChanges/`** — 10 scripts that back up user data or modify settings (BitLocker, WoL, Dell updates, backups)
- **`AutopilotReadiness/`** — 4 orchestrated steps for TPM/UEFI validation and device registration; plus `Report-AutopilotReadinessToHudu.ps1` which is run manually post-wipe and requires the `HuduAPI` module

### Dell-Specific Behavior

`Invoke-BiosUpdate.ps1` and `Invoke-DriverUpdate.ps1` depend on Dell Command Update and Dell Command Configure. `Find-DellCommandTool.ps1` handles discovery; `Install-DellCommandTools.ps1` (not a menu step — invoked on demand by the two updaters) downloads and installs them. `Test-AutopilotReadiness.ps1` contains explicit detection logic for known-problematic TPM manufacturers (Infineon, STMicro, Nuvoton).

### Output Location (on the Windows target device)

```
C:\PreWipeOutput\
├── session.json                  # Live session state — survives reboots
├── PreWipeReport_<PC>_<ts>.html  # HTML report generated after each run
├── PreWipeReport_<PC>_<ts>.json  # JSON session export
├── PreWipeReport_<PC>_<ts>.txt   # Plain text export
├── errors.log                    # Aggregated errors from step scripts
└── Logs\
    ├── *.log                     # Per-script run logs (incl. Start-PreWipeToolkit_Errors_<date>.log)
    └── *-Report.json             # Structured JSON output per script
```
