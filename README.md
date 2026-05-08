# AshesToAutopilot

A PowerShell toolkit for preparing Windows devices for wipe and Autopilot re-enrollment. Covers data preservation, hardware validation, firmware updates, and Autopilot registration so nothing gets missed and nothing gets wiped that shouldn't be.

---

## Quick Start

Launch the interactive orchestrator from an elevated PowerShell prompt:

```powershell
.\Start-PreWipeToolkit.ps1
```

This opens a numbered menu. Press a key to select:

```
[1]  Quick Check       12 core steps — fast scan & backup essentials
[2]  Full Prep         all 31 steps in sequence
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

### Full Prep (31 steps)
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
| 14 | `Test-BiosVersion.ps1` | Checks BIOS version against latest available (Dell) |
| 15 | `Test-DriverStatus.ps1` | Flags outdated or missing drivers via Dell Command Update |
| 16 | `Test-WakeOnLan.ps1` | Checks current Wake-on-LAN state |
| 17 | `Test-WinRE.ps1` | Verifies Windows Recovery Environment is enabled |

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
| 23 | `Test-BitLockerEscrow.ps1` | Verifies and escrows BitLocker recovery key to Entra ID |
| 24 | `Set-WakeOnLan.ps1` | Enables WoL via BIOS, NIC settings, and Windows power policy |

### Configuration Changes — Install & Update

| # | Script | Purpose |
|---|--------|---------|
| 25 | `Install-DellCommandTools.ps1` | Installs Dell Command Update and Dell Command Configure |
| 26 | `Update-Drivers.ps1` | Applies driver updates via Dell Command Update |
| 27 | `Update-Bios.ps1` | Applies BIOS update via Dell Command Update (may reboot) |

### Autopilot

| # | Script | Purpose |
|---|--------|---------|
| 28 | `Test-AutopilotReadiness.ps1` | Validates TPM, UEFI, Secure Boot, and Autopilot hardware requirements |
| 29 | `Get-AutopilotAssignment.ps1` | Checks if device has an Autopilot profile assigned in Intune |
| 30 | `Register-AutopilotDevice.ps1` | Captures hardware hash and registers device with Autopilot |
| 31 | `Get-PreWipeSummary.ps1` | Produces final pre-wipe readiness summary |

---

## Output

All output is written to `C:\PreWipeOutput\`:

```
C:\PreWipeOutput\
├── session.json                  # Session state — survives reboots
├── PreWipeReport_<PC>_<ts>.html  # HTML report generated after each run
├── PreWipeReport_<PC>_<ts>.json  # JSON session export
├── PreWipeReport_<PC>_<ts>.txt   # Plain text session export
└── Logs\
    ├── *.log                     # Per-script run logs
    ├── *.json                    # Structured output from each script
    └── errors.log                # Aggregated error log
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
│   ├── Initialize-Toolkit.ps1     # Write-Log, Test-AdminElevation
│   ├── Get-ActiveUserProfile.ps1  # Profile enumeration, hive mounting
│   └── Find-DellCommandTool.ps1   # Dell tool discovery
├── DataCollection/                # Read-only scans and backups
├── ConfigurationChecks/           # Read-only status checks
├── ConfigurationChanges/          # Scripts that modify settings
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
