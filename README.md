# AshesToAutopilot

A PowerShell toolkit for preparing Windows devices for wipe and Autopilot re-enrollment. Covers data preservation, hardware validation, firmware updates, and Autopilot registration — so nothing gets missed and nothing gets wiped that shouldn't be.

## Overview

Devices go through four phases before a wipe. Each phase is a folder of focused, independent scripts that can be run manually or chained together.

```
Scripts/
├── Phase1-Prerequisites/   # Tool installation and dependency checks
├── Phase2-DataBackup/      # User data audit and preservation
├── Phase3-Hardware/        # Hardware inventory, BIOS, drivers, WinRE
└── Phase4-Autopilot/       # Autopilot registration and profile validation
```

All output is written to `C:\PreWipeOutput\`. Scripts support a `-NonInteractive` flag for JSON-only stdout output, useful for automation pipelines.

## Requirements

- Windows 10/11
- PowerShell 5.1 or later (PowerShell 7+ recommended)
- Run as Administrator
- For Dell hardware scripts: Dell Command Update and/or Dell Command Configure installed

## Usage

Run scripts individually from an elevated PowerShell prompt:

```powershell
# Interactive mode — human-readable output
.\Scripts\Phase2-DataBackup\Find-UnbackedData.ps1

# Non-interactive mode — JSON output for automation
.\Scripts\Phase2-DataBackup\Find-UnbackedData.ps1 -NonInteractive
```

### Phase 1 — Prerequisites

| Script | Purpose |
|--------|---------|
| `Install-DellCommandTools.ps1` | Installs Dell Command Update and Dell Command Configure if on Dell hardware |

### Phase 2 — Data Backup

| Script | Purpose |
|--------|---------|
| `Find-UnbackedData.ps1` | Audits user profiles for data not covered by OneDrive or other backup |
| `Test-OneDriveKFM.ps1` | Confirms OneDrive Known Folder Move is active for Desktop, Documents, Pictures |
| `Test-BitLockerEscrow.ps1` | Verifies BitLocker recovery key is escrowed to Azure AD |
| `Backup-BrowserBookmarks.ps1` | Exports Chrome/Edge bookmarks to output folder |
| `Backup-OutlookSignatures.ps1` | Copies Outlook signature files to output folder |
| `Backup-DesktopBackground.ps1` | Saves current desktop wallpaper |
| `Backup-TaskbarLayout.ps1` | Exports taskbar pin layout |
| `Get-DownloadsSize.ps1` | Reports Downloads folder size per active user profile |
| `Get-DriveMappings.ps1` | Inventories mapped network drives per user profile |

### Phase 3 — Hardware

| Script | Purpose |
|--------|---------|
| `Test-BiosVersion.ps1` | Checks current BIOS version against latest available |
| `Update-Bios.ps1` | Applies BIOS update via Dell Command Update (Dell only) |
| `Test-DriverStatus.ps1` | Flags outdated or missing drivers |
| `Update-Drivers.ps1` | Runs driver updates via Dell Command Update (Dell only) |
| `Get-StorageMode.ps1` | Reports disk controller mode (AHCI/RAID/NVMe) |
| `Get-Printers.ps1` | Inventories installed printers |
| `Test-WakeOnLan.ps1` | Checks current Wake-on-LAN state |
| `Set-WakeOnLan.ps1` | Enables WoL via Dell Command Configure (Dell only) |
| `Test-WinRE.ps1` | Verifies Windows Recovery Environment is enabled |

### Phase 4 — Autopilot

| Script | Purpose |
|--------|---------|
| `Get-AutopilotAssignment.ps1` | Checks if device has an Autopilot profile assigned in Intune |
| `Test-AutopilotProfile.ps1` | Validates profile settings before wipe |
| `Register-AutopilotDevice.ps1` | Captures hardware hash and registers device with Autopilot |

## Output

All scripts write to `C:\PreWipeOutput\`:

```
C:\PreWipeOutput\
├── Logs\        # Script run logs
└── *.json       # Exported data (bookmarks, signatures, drive maps, etc.)
```

## Next Steps / Roadmap

- [ ] Master orchestration script (`Invoke-AshesToAutopilot.ps1`) to run all phases in sequence
- [ ] HTML summary report generated after all phases complete
- [ ] Support for non-Dell hardware firmware update paths (Lenovo, HP)
- [ ] Scheduled pre-wipe check mode (runs silently, flags issues via event log)
- [ ] Pester tests for each script
- [ ] Pipeline support (GitHub Actions syntax validation on push)

## Acknowledgements

Scripts in this toolkit draw on patterns and techniques from the following open-source repositories:

| Repository | Author | License |
|-----------|--------|---------|
| [LazyAdmin](https://lazyadmin.nl) | R. Mens | MIT |
| [Office365itpros](https://office365itpros.com) | Tony Redmond | MIT |
| [garytown](https://garytown.com) | Gary Blok | — |
| [PnP Script Samples](https://pnp.github.io/script-samples) | Microsoft 365 Community | MIT |
| public-main | Various | GPL-3.0 |
| powershell-scripts-master | Various | — |

Development assistance provided by [Claude](https://claude.ai) (Anthropic).

## License

MIT
