// Step definitions mirroring $script:Steps in Start-PreWipeToolkit.ps1.
// Indices 24-27 and 30 are intentionally absent; keep this table in sync with
// the orchestrator when steps are added or removed.

const PHASE_LABELS = {
  ScanCheck: 'Scan & Check',
  Backup: 'Backup',
  Configure: 'Configure',
  InstallUpdate: 'Install & Update',
  Autopilot: 'Autopilot'
};

// Quick Check step selection — 12 steps that assess wipe safety without
// modifying any settings. Rationale documented in Start-PreWipeToolkit.ps1.
const QUICK_CHECK_INDICES = [11, 12, 1, 2, 3, 6, 13, 18, 19, 20, 4, 29];

const STEPS = [
  { index: 1,  phase: 'ScanCheck',     displayName: 'Scan for Not-Backed-Up Data',           scriptPath: 'Scripts\\DataCollection\\Find-UnbackedData.ps1' },
  { index: 2,  phase: 'ScanCheck',     displayName: 'Check Downloads Folder Sizes',          scriptPath: 'Scripts\\DataCollection\\Get-DownloadsSize.ps1' },
  { index: 3,  phase: 'ScanCheck',     displayName: 'Get Drive Mappings',                    scriptPath: 'Scripts\\DataCollection\\Get-DriveMappings.ps1' },
  { index: 4,  phase: 'ScanCheck',     displayName: 'List Printers',                         scriptPath: 'Scripts\\DataCollection\\Get-Printers.ps1' },
  { index: 5,  phase: 'ScanCheck',     displayName: 'Get Windows Product Key',               scriptPath: 'Scripts\\DataCollection\\Get-WindowsProductKey.ps1' },
  { index: 6,  phase: 'ScanCheck',     displayName: 'Get Installed Applications',            scriptPath: 'Scripts\\DataCollection\\Get-InstalledApplications.ps1' },
  { index: 7,  phase: 'ScanCheck',     displayName: 'Get Device Health Report',              scriptPath: 'Scripts\\DataCollection\\Get-DeviceHealth.ps1' },
  { index: 8,  phase: 'ScanCheck',     displayName: 'Get Teams Chat & Meeting Data',         scriptPath: 'Scripts\\DataCollection\\Get-TeamsData.ps1' },
  { index: 9,  phase: 'ScanCheck',     displayName: 'Get Credential Manager Entries',        scriptPath: 'Scripts\\DataCollection\\Get-CredentialManagerEntries.ps1' },
  { index: 10, phase: 'ScanCheck',     displayName: 'Get Local Accounts',                    scriptPath: 'Scripts\\DataCollection\\Get-LocalAccounts.ps1' },
  { index: 11, phase: 'ScanCheck',     displayName: 'Test OneDrive KFM Status',              scriptPath: 'Scripts\\ConfigurationChecks\\Test-OneDriveKFM.ps1' },
  { index: 12, phase: 'ScanCheck',     displayName: 'Test OneDrive Sync Status',             scriptPath: 'Scripts\\ConfigurationChecks\\Test-OneDriveSyncStatus.ps1' },
  { index: 13, phase: 'ScanCheck',     displayName: 'Get Storage Controller Mode',           scriptPath: 'Scripts\\ConfigurationChecks\\Get-StorageMode.ps1' },
  { index: 14, phase: 'InstallUpdate', displayName: 'Check and Update BIOS (Dell DCU)',      scriptPath: 'Scripts\\ConfigurationChanges\\Invoke-BiosUpdate.ps1' },
  { index: 15, phase: 'InstallUpdate', displayName: 'Check and Update Drivers (Dell DCU)',   scriptPath: 'Scripts\\ConfigurationChanges\\Invoke-DriverUpdate.ps1' },
  { index: 16, phase: 'Configure',     displayName: 'Enable Wake-on-LAN (check and set)',    scriptPath: 'Scripts\\ConfigurationChanges\\Enable-WakeOnLan.ps1' },
  { index: 17, phase: 'ScanCheck',     displayName: 'Test Windows Recovery (WinRE)',         scriptPath: 'Scripts\\ConfigurationChecks\\Test-WinRE.ps1' },
  { index: 18, phase: 'Backup',        displayName: 'Backup Browser Bookmarks',              scriptPath: 'Scripts\\ConfigurationChanges\\Backup-BrowserBookmarks.ps1' },
  { index: 19, phase: 'Backup',        displayName: 'Backup Desktop Background',             scriptPath: 'Scripts\\ConfigurationChanges\\Backup-DesktopBackground.ps1' },
  { index: 20, phase: 'Backup',        displayName: 'Backup Outlook Signatures',             scriptPath: 'Scripts\\ConfigurationChanges\\Backup-OutlookSignatures.ps1' },
  { index: 21, phase: 'Backup',        displayName: 'Backup Taskbar Layout',                 scriptPath: 'Scripts\\ConfigurationChanges\\Backup-TaskbarLayout.ps1' },
  { index: 22, phase: 'Backup',        displayName: 'Backup Wi-Fi Profiles',                 scriptPath: 'Scripts\\ConfigurationChanges\\Backup-WiFiProfiles.ps1' },
  { index: 23, phase: 'Configure',     displayName: 'Escrow BitLocker Key to Entra ID',      scriptPath: 'Scripts\\ConfigurationChanges\\Test-BitLockerEscrow.ps1' },
  { index: 28, phase: 'Autopilot',     displayName: 'Test Autopilot Readiness',              scriptPath: 'Scripts\\AutopilotReadiness\\Test-AutopilotReadiness.ps1' },
  { index: 29, phase: 'Autopilot',     displayName: 'Get Autopilot Assignment',              scriptPath: 'Scripts\\AutopilotReadiness\\Get-AutopilotAssignment.ps1' },
  { index: 31, phase: 'Autopilot',     displayName: 'Pre-Wipe Summary',                      scriptPath: 'Scripts\\AutopilotReadiness\\Get-PreWipeSummary.ps1' },
  { index: 32, phase: 'Autopilot',     displayName: 'Register Device (OAuth · Community Mod)', scriptPath: 'Scripts\\AutopilotReadiness\\Register-AutopilotDeviceCommunity.ps1' }
];

module.exports = { STEPS, QUICK_CHECK_INDICES, PHASE_LABELS };
