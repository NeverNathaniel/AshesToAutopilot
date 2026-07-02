# AshesToAutopilot

A PowerShell toolkit for preparing Windows devices for wipe and Autopilot re-enrollment. Covers data preservation, hardware validation, firmware updates, and Autopilot registration so nothing gets missed and nothing gets wiped that shouldn't be.

---

## Installation

Download the latest release zip, extract it, and run the orchestrator from an elevated PowerShell prompt:

```powershell
# From an elevated PowerShell prompt
$dest = "C:\AshesToAutopilot"
Invoke-WebRequest -Uri "https://github.com/NeverNathaniel/AshesToAutopilot/releases/latest/download/AshesToAutopilot.zip" -OutFile "$env:TEMP\AshesToAutopilot.zip"
Expand-Archive -Path "$env:TEMP\AshesToAutopilot.zip" -DestinationPath $dest -Force
Set-Location $dest
.\Start-PreWipeToolkit.ps1
```

No execution policy changes required — the toolkit unblocks all scripts automatically on first run.

> **For each release:** build the zip with `git archive --format=zip --output=AshesToAutopilot.zip HEAD` and attach it to the GitHub release as `AshesToAutopilot.zip`.

---

## Quick Start

Launch the interactive orchestrator from an elevated PowerShell prompt:

```powershell
.\Start-PreWipeToolkit.ps1
```

This opens a numbered menu. Press a key to select:

```
[1]  Quick Check       12 core steps — fast scan & backup essentials
[2]  Full Prep         all 27 steps in sequence
[3]  Run Single Step
[4]  Custom Run        choose steps by number
[5]  View Session Summary
[6]  Export Report
[7]  Reset Session
[Q]  Quit
```

Progress and results accumulate inline. A session file (`C:\PreWipeOutput\session.json`) is saved after each step so you can resume across reboots. An HTML report is generated automatically after any run.

---

## Requirements

- Windows 10 / 11
- PowerShell 5.1 or later (7+ recommended)
- Run as Administrator
- Dell hardware scripts require Dell Command Update and/or Dell Command Configure

---

## Run Modes

### Quick Check (12 steps)
Fast assessment — read-only checks and lightweight backups only. Covers the most common blocking issues before a wipe. Includes:

- OneDrive KFM and sync status
- Unbacked data scan
- Downloads folder size and auto-copy
- Drive mappings inventory
- Installed applications list
- Storage controller mode
- Browser bookmarks, desktop wallpaper, Outlook signatures
- Printer inventory
- Autopilot profile assignment

### Full Prep (27 steps)
Runs all steps in sequence including Dell firmware/driver updates, WoL configuration, BitLocker escrow, Teams data, credential manager entries, Wi-Fi profiles, and Autopilot registration.

### Single Step / Custom Run
Select any step by number, or enter a comma-separated list (e.g. `1,3,11,12`) to run a custom subset.

---

## Script Reference

### Scan & Check

| # | Script | Purpose |
|---|--------|---------|
| 1 | `Find-UnbackedData.ps1` | Scans user profiles for data outside OneDrive (databases, PSTs, SSH keys, certificates) |
| 2 | `Get-DownloadsSize.ps1` | Reports Downloads size per user and auto-copies to Documents |
| 3 | `Get-DriveMappings.ps1` | Inventories mapped network drives per user profile |
| 4 | `Get-Printers.ps1` | Lists installed printers (local and network) |
| 5 | `Get-WindowsProductKey.ps1` | Retrieves Windows product key from firmware |
| 6 | `Get-InstalledApplications.ps1` | Lists all installed applications (machine and user scope) |
| 7 | `Get-DeviceHealth.ps1` | Reports disk health, battery wear, and event log warnings |
| 8 | `Get-TeamsData.ps1` | Documents Teams chat files and meeting recordings for user awareness |
| 9 | `Get-CredentialManagerEntries.ps1` | Lists Windows Credential Manager entries so users know what to re-enter |
| 10 | `Get-LocalAccounts.ps1` | Enumerates local user accounts and group memberships |
| 11 | `Test-OneDriveKFM.ps1` | Confirms Known Folder Move is active for Desktop, Documents, Pictures |
| 12 | `Test-OneDriveSyncStatus.ps1` | Verifies OneDrive sync is current and safe to wipe |
| 13 | `Get-StorageMode.ps1` | Reports disk controller mode (AHCI / RAID / NVMe) |
| 17 | `Test-WinRE.ps1` | Verifies Windows Recovery Environment is enabled |

### Install & Update

These steps check and apply updates via Dell Command Update. They live in `Scripts/ConfigurationChanges/`.

| # | Script | Purpose |
|---|--------|---------|
| 14 | `Invoke-BiosUpdate.ps1` | Checks BIOS version and applies Dell DCU update if one is available (may reboot) |
| 15 | `Invoke-DriverUpdate.ps1` | Checks driver status and applies available Dell DCU driver updates |

### Configuration Changes — Backups

These scripts write files to the output folder. They live in `Scripts/ConfigurationChanges/`.

| # | Script | Purpose |
|---|--------|---------|
| 18 | `Backup-BrowserBookmarks.ps1` | Exports Chrome/Edge/Firefox bookmarks to output folder |
| 19 | `Backup-DesktopBackground.ps1` | Saves current desktop wallpaper |
| 20 | `Backup-OutlookSignatures.ps1` | Copies Outlook signature files to output folder |
| 21 | `Backup-TaskbarLayout.ps1` | Exports taskbar pin layout |
| 22 | `Backup-WiFiProfiles.ps1` | Exports saved Wi-Fi profiles |

### Configuration Changes — Configure

| # | Script | Purpose |
|---|--------|---------|
| 16 | `Enable-WakeOnLan.ps1` | Enables WoL via BIOS, NIC settings, and Windows power policy |
| 23 | `Test-BitLockerEscrow.ps1` | Verifies and escrows BitLocker recovery key to Entra ID |

### Autopilot

| # | Script | Purpose |
|---|--------|---------|
| 28 | `Test-AutopilotReadiness.ps1` | Validates TPM, UEFI, Secure Boot, and Autopilot hardware requirements |
| 29 | `Get-AutopilotAssignment.ps1` | Checks if device has an Autopilot profile assigned in Intune |
| 31 | `Get-PreWipeSummary.ps1` | Produces final pre-wipe readiness summary |
| 32 | `Register-AutopilotDeviceCommunity.ps1` | Captures hardware hash and registers device via OAuth (community module) |

---

## Post-Run Reporting

### Report-AutopilotReadinessToHudu.ps1

Posts a structured pre-wipe readiness report to a Hudu IT documentation instance. Run manually after `Start-PreWipeToolkit.ps1` completes.

**Prerequisites:**
- The `HuduAPI` PowerShell module: `Install-Module HuduAPI`
- A Hudu instance with API access

**Usage:**
```
.\Scripts\AutopilotReadiness\Report-AutopilotReadinessToHudu.ps1 -HuduBaseUrl "https://your-hudu.com"
```

---

## Output

All output is written to `C:\PreWipeOutput\`:

```
C:\PreWipeOutput\
├── session.json                  # Session state — survives reboots
├── PreWipeReport_<PC>_<ts>.html  # HTML report generated after each run
├── PreWipeReport_<PC>_<ts>.json  # JSON session export
├── PreWipeReport_<PC>_<ts>.txt   # Plain text session export
├── errors.log                    # Aggregated errors from step scripts
└── Logs\
    ├── *.log                     # Per-script run logs
    └── *-Report.json             # Structured output from each script
```

---

## Non-Interactive Mode

Every script accepts `-NonInteractive` to suppress prompts and emit structured JSON to stdout. Useful for automation pipelines:

```powershell
.\Scripts\DataCollection\Find-UnbackedData.ps1 -NonInteractive | ConvertFrom-Json
```

The orchestrator also supports `-NonInteractive` — it emits current session state as JSON and exits without opening the menu.

---

## Repository Structure

```
Start-PreWipeToolkit.ps1           # Main orchestrator (run this)
Scripts/
├── Common/                        # Shared helper functions
│   ├── Toolkit-UI.ps1             # Terminal display and menu rendering
│   ├── Toolkit-Report.ps1         # HTML report and session export
│   ├── Toolkit-Execution.ps1      # Step execution engine
│   ├── Initialize-Toolkit.ps1     # Write-Log, Test-AdminElevation
│   ├── Get-ActiveUserProfile.ps1  # Profile enumeration, hive mounting
│   └── Find-DellCommandTool.ps1   # Dell tool discovery
├── DataCollection/                # Read-only scans and inventories
├── ConfigurationChecks/           # Read-only status checks
├── ConfigurationChanges/          # Scripts that modify settings or write backups
└── AutopilotReadiness/            # Autopilot validation and registration
```

---

## Verdict Semantics

The orchestrator captures JSON output from each script and evaluates a verdict independently of the exit code:

| Verdict | Meaning |
|---------|---------|
| `[OK]` green | Check passed — safe to proceed |
| `[!!]` yellow | Warning — review before wiping |
| `[XX]` red | Blocking issue — must resolve before wipe |

Exit code 0 means the script ran without crashing. Exit code 1 means either a crash or a blocking condition was found (e.g. OneDrive not synced, BitLocker escrow failed). The HTML report shows both.

---

## Acknowledgements

Scripts draw on patterns from the following open-source repositories:

| Repository | Author | License |
|-----------|--------|---------|
| [LazyAdmin](https://lazyadmin.nl) | R. Mens | MIT |
| [Office365itpros](https://office365itpros.com) | Tony Redmond | MIT |
| [garytown](https://garytown.com) | Gary Blok | — |
| [PnP Script Samples](https://pnp.github.io/script-samples) | Microsoft 365 Community | MIT |

Development assistance provided by [Claude](https://claude.ai) (Anthropic).

## License

MIT
