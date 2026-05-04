# AshesToAutopilot

A pure-PowerShell toolkit for preparing Windows devices for wipe and Autopilot re-enrollment. Covers data preservation, hardware validation, configuration backups, firmware updates, and Autopilot registration — so nothing gets missed and nothing gets wiped that shouldn't be.

## Quick Start

```powershell
# Open an elevated PowerShell prompt, then:

# Full interactive dashboard (29 steps, session persistence, retro TUI)
.\Start-PreWipeToolkit.ps1

# Quick lite run (11 key checks, sequential, HTML report)
.\Start-PreWipeToolkitLite.ps1
```

> **Requirements:** Windows 10/11 · PowerShell 5.1+ (7+ recommended) · Run as Administrator

## Orchestrators

### `Start-PreWipeToolkit.ps1` — Full Dashboard

A retro-styled split-pane TUI with a rainbow gradient ASCII banner. No external modules required — everything is pure PowerShell using ANSI escape sequences.

**Features:**
- 29 steps across 4 categories with arrow-key navigation and scrolling
- Live status badges (`[DONE]` / `[FAIL]` / `[SKIP]`) and progress bar
- Right-side panel showing session status, selected step details, and last result
- Session persistence (`C:\PreWipeOutput\session.json`) — resume where you left off
- Workflow actions: Run All, Export Report, Reset Session

```powershell
# Interactive dashboard
.\Start-PreWipeToolkit.ps1

# JSON status dump (for automation / polling)
.\Start-PreWipeToolkit.ps1 -NonInteractive
```

### `Start-PreWipeToolkitLite.ps1` — Quick Run

A streamlined sequential runner that executes 11 key checks, displays results as formatted tables, and generates a professional HTML report.

**Features:**
- Runs all 11 checks with a single confirmation
- Per-step formatted table output and verdict evaluation (PASS / WARN / FAIL)
- Colour-coded summary with overall wipe-readiness verdict
- Auto-generated HTML report saved to `C:\PreWipeOutput\`

```powershell
# Interactive run with table output
.\Start-PreWipeToolkitLite.ps1

# Silent run — JSON to stdout, HTML report saved
.\Start-PreWipeToolkitLite.ps1 -NonInteractive
```

## Project Structure

```
AshesToAutopilot/
├── Start-PreWipeToolkit.ps1         # Full 29-step interactive dashboard
├── Start-PreWipeToolkitLite.ps1     # Quick 11-step sequential runner
└── Scripts/
    ├── AutopilotReadiness/          # Autopilot registration & profile checks
    ├── ConfigurationChanges/        # Backups, installs, and config writes
    ├── ConfigurationChecks/         # Read-only hardware & software checks
    └── DataCollection/              # Data audits and inventory scans
```

## Scripts Reference

### DataCollection — Read-Only Scans & Inventory

| Script | Purpose |
|--------|---------|
| `Find-UnbackedData.ps1` | Audits user profiles for data not covered by OneDrive |
| `Get-DeviceHealth.ps1` | Collects device health and hardware diagnostics |
| `Get-DownloadsSize.ps1` | Reports Downloads folder size per user profile |
| `Get-DriveMappings.ps1` | Inventories mapped network drives per user |
| `Get-InstalledApplications.ps1` | Lists all installed applications (machine + user scope) |
| `Get-Printers.ps1` | Inventories installed printers (network + local) |
| `Get-WindowsProductKey.ps1` | Retrieves the Windows product key |

### ConfigurationChecks — Read-Only Validation

| Script | Purpose |
|--------|---------|
| `Get-StorageMode.ps1` | Reports disk controller mode (AHCI / RAID / NVMe) |
| `Test-BiosVersion.ps1` | Checks current BIOS version against latest available (Dell) |
| `Test-DriverStatus.ps1` | Flags outdated or missing drivers via Dell Command Update |
| `Test-OneDriveKFM.ps1` | Confirms Known Folder Move is active for Desktop, Documents, Pictures |
| `Test-OneDriveSyncStatus.ps1` | Validates OneDrive sync status per profile |
| `Test-WakeOnLan.ps1` | Checks current Wake-on-LAN state |
| `Test-WinRE.ps1` | Verifies Windows Recovery Environment is enabled |

### ConfigurationChanges — Backups, Installs & Config Writes

| Script | Purpose |
|--------|---------|
| `Backup-BrowserBookmarks.ps1` | Exports Chrome/Edge bookmarks to output folder |
| `Backup-DesktopBackground.ps1` | Saves current desktop wallpaper per user |
| `Backup-OutlookSignatures.ps1` | Copies Outlook signature files to output folder |
| `Backup-TaskbarLayout.ps1` | Exports taskbar pin layout |
| `Backup-WiFiProfiles.ps1` | Exports saved Wi-Fi profiles |
| `Install-DellCommandTools.ps1` | Installs Dell Command Update and Dell Command Configure |
| `Set-WakeOnLan.ps1` | Enables WoL via Dell Command Configure |
| `Test-BitLockerEscrow.ps1` | Verifies/escrows BitLocker recovery key to Entra ID |
| `Update-Bios.ps1` | Applies BIOS update via Dell Command Update (may reboot) |
| `Update-Drivers.ps1` | Runs driver updates via Dell Command Update |

### AutopilotReadiness — Registration & Profile Validation

| Script | Purpose |
|--------|---------|
| `Get-AutopilotAssignment.ps1` | Checks if device has an Autopilot profile (local + Graph API) |
| `Get-PreWipeSummary.ps1` | Generates a final pre-wipe summary report |
| `Register-AutopilotDevice.ps1` | Captures hardware hash and registers with Autopilot |
| `Report-AutopilotReadinessToHudu.ps1` | Reports Autopilot readiness status to Hudu |
| `Test-AutopilotProfile.ps1` | Validates Autopilot profile settings |
| `Test-AutopilotReadiness.ps1` | Comprehensive Autopilot readiness check |

## Output

All scripts write to `C:\PreWipeOutput\`:

```
C:\PreWipeOutput\
├── Logs/                    # Timestamped run logs and error logs
├── session.json             # Dashboard session state (resume support)
├── PreWipeReport_*.html     # HTML reports (Lite runner)
├── PreWipeReport_*.json     # JSON exports
└── PreWipeReport_*.txt      # Plain-text exports
```

Every script supports a `-NonInteractive` flag that emits structured JSON to stdout — useful for automation, CI/CD pipelines, or feeding results into other tools.

## Acknowledgements

Scripts in this toolkit draw on patterns and techniques from the following open-source projects:

| Repository | Author | License |
|-----------|--------|---------|
| [LazyAdmin](https://lazyadmin.nl) | R. Mens | MIT |
| [Office365itpros](https://office365itpros.com) | Tony Redmond | MIT |
| [garytown](https://garytown.com) | Gary Blok | — |
| [PnP Script Samples](https://pnp.github.io/script-samples) | Microsoft 365 Community | MIT |

Development assistance provided by [Claude](https://claude.ai) (Anthropic).

## License

MIT
