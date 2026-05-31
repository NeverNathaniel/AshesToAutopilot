# Toolkit-Report.ps1 — HTML report and session export functions for Start-PreWipeToolkit.ps1
# Dot-sourced by the orchestrator. Do not run directly.

function Get-ActionInstruction {
    param([string]$ScriptFile, [string]$VerdictReason)
    switch -Wildcard ($ScriptFile) {
        '*Test-OneDriveSyncStatus*'          { return 'Open OneDrive and wait for full sync to complete. Do not wipe until all files are uploaded.' }
        '*Test-OneDriveKFM*'                 { return 'Enable Known Folder Move for the affected profile: OneDrive tray icon &rsaquo; Settings &rsaquo; Backup &rsaquo; Manage backup.' }
        '*Find-UnbackedData*'                { return 'Review flagged files with the user and manually back up anything not in OneDrive before wiping.' }
        '*Backup-BrowserBookmarks*'          { return 'Remind the user to sign into their browser on the new device to restore synced bookmarks.' }
        '*Backup-WiFiProfiles*'              { return 'Move or delete C:\PreWipeOutput\WiFiProfiles\ after restoring profiles to the new device &mdash; exported XML files contain cleartext PSK passwords.' }
        '*Test-BitLockerEscrow*'             { return 'Re-run step 23 to escrow the BitLocker key to Entra ID. Do not wipe until the key is backed up.' }
        '*Test-AutopilotReadiness*'          { return 'Device does not meet Autopilot hardware requirements. Check TPM version, UEFI mode, and Secure Boot status before proceeding.' }
        '*Get-AutopilotAssignment*'          { return 'Assign the device an Autopilot profile in Intune (Devices &rsaquo; Enrollment &rsaquo; Autopilot) before wiping.' }
        '*Register-AutopilotDeviceCommunity*'{ return 'OAuth registration failed. Re-run step 32 interactively via [3] Run Single Step and sign in when prompted. For NeedsInteractiveAuth, choose Run Single Step from the main menu.' }
        '*Register-AutopilotDevice*'         { return 'Hardware hash upload failed. Re-run step 30. If the issue persists, upload the hash CSV manually via Intune.' }
        '*Get-DownloadsSize*'                { return 'Auto-copy to Documents failed. Manually copy the Downloads folder contents to a safe location before wiping.' }
        '*Test-BiosVersion*'                 { return 'Run Update-BIOS (step 27) to apply the available BIOS update before wiping.' }
        '*Test-DriverStatus*'                { return 'Run Update-Drivers (step 26) to apply available driver updates before wiping.' }
        '*Test-WakeOnLan*'                   { return 'Run Set-Wake-on-LAN (step 24) to enable WOL on this device before wiping.' }
        '*Set-WakeOnLan*'                    { return 'WOL configuration partially failed. Check NIC power management settings in Device Manager and re-run step 24.' }
        '*Install-DellCommandTools*'         { return 'Re-run step 25. Dell Command Update and Configure are required for BIOS and driver updates on Dell hardware.' }
        '*Update-Bios*'                      { return 'Reboot the device to complete the BIOS update, then verify the BIOS version before wiping.' }
        '*Update-Drivers*'                   { return 'Reboot the device to complete driver installation, then proceed with the wipe from a clean boot.' }
        '*Get-TeamsData*'                    { return 'Back up Teams meeting recordings before wiping. Files are typically in C:\Users\&lt;user&gt;\Videos or OneDrive\Recordings.' }
        '*Get-LocalAccounts*'                { return 'Verify local admin accounts with the end user. Remove any unexpected admin accounts before wiping.' }
        default                              { return [System.Web.HttpUtility]::HtmlEncode($VerdictReason) }
    }
}

function Get-StepSummary { # Generates human-readable summary from step output
    param([PSCustomObject]$Parsed, [string]$ScriptFile) # Parsed JSON output and script path
    if ($null -eq $Parsed) { return 'No output' } # Handle null output
    try {
        switch -Wildcard ($ScriptFile) { # Match script and extract key metrics
            '*Test-OneDriveKFM*' {
                if (-not $Parsed.Results) { return 'No profiles' }
                $enabled = @($Parsed.Results | Where-Object { $_.KFM_Desktop -eq 'Enabled' -and $_.KFM_Documents -eq 'Enabled' -and $_.KFM_Pictures -eq 'Enabled' }).Count
                return "$enabled/$($Parsed.Results.Count) profiles fully KFM-enabled"
            }
            '*Test-OneDriveSyncStatus*' { return "$($Parsed.OverallVerdict) ($($Parsed.ProfilesChecked) profiles)" }
            '*Find-UnbackedData*' {
                $totalFindings = 0
                if ($Parsed.ProfileFindings) { $Parsed.ProfileFindings | ForEach-Object { $totalFindings += $_.FindingCount } }
                $appCount = if ($Parsed.NonStandardApps) { $Parsed.NonStandardApps.Count } else { 0 }
                if ($totalFindings -eq 0 -and $appCount -eq 0) { return 'Clean — nothing found' }
                return "$totalFindings item(s) at risk, $appCount non-std app(s)"
            }
            '*Get-DownloadsSize*' {
                if (-not $Parsed.Results) { return 'No profiles' }
                $totalBytes = ($Parsed.Results | Measure-Object -Property SizeBytes -Sum).Sum
                $totalFiles = ($Parsed.Results | Measure-Object -Property FileCount -Sum).Sum
                $sizeStr = if ($totalBytes -gt 1GB) { '{0:N1} GB' -f ($totalBytes / 1GB) } `
                           elseif ($totalBytes -gt 1MB) { '{0:N0} MB' -f ($totalBytes / 1MB) } `
                           else { '{0:N0} KB' -f ($totalBytes / 1KB) }
                $copied = @($Parsed.Results | Where-Object { $_.CopySuccess -eq $true }).Count
                return "$sizeStr across $($Parsed.Results.Count) user(s)  $copied/$($Parsed.Results.Count) copied"
            }
            '*Get-InstalledApplications*' { return "$($Parsed.TotalCount) apps ($($Parsed.MachineCount) machine, $($Parsed.UserCount) user)" }
            '*Get-StorageMode*' {
                $diskInfo = ''
                if ($Parsed.Disks -and $Parsed.Disks.Count -gt 0) {
                    $d = $Parsed.Disks[0]
                    $diskInfo = " ($($d.MediaType) {0:N0} GB)" -f $d.Size
                }
                return "$($Parsed.StorageMode)$diskInfo"
            }
            '*Backup-BrowserBookmarks*' {
                $backed = 0; $total = 0
                if ($Parsed.Results) {
                    $Parsed.Results | ForEach-Object {
                        if ($_.Browsers) { $_.Browsers | ForEach-Object { $total++; if ($_.BackedUp) { $backed++ } } }
                    }
                }
                return "$backed/$total browser profile(s) backed up"
            }
            '*Backup-DesktopBackground*' {
                if (-not $Parsed.Results) { return 'No profiles' }
                $ok = @($Parsed.Results | Where-Object { $_.Success -eq $true }).Count
                return "$ok/$($Parsed.Results.Count) wallpaper(s) backed up"
            }
            '*Backup-OutlookSignatures*' {
                if (-not $Parsed.Results) { return 'No profiles' }
                $found = @($Parsed.Results | Where-Object { $_.Found -eq $true }).Count
                $files = ($Parsed.Results | Measure-Object -Property FileCount -Sum).Sum
                return "$found user(s) with signatures, $files file(s) backed up"
            }
            '*Get-Printers*' {
                if (-not $Parsed.Printers -or $Parsed.Printers.Count -eq 0) { return 'No printers found' }
                $net   = @($Parsed.Printers | Where-Object { $_.Type -eq 'Network' }).Count
                $local = @($Parsed.Printers | Where-Object { $_.Type -eq 'Local'   }).Count
                return "$($Parsed.TotalPrinters) printer(s) ($net network, $local local)"
            }
            '*Get-AutopilotAssignment*' {
                if ($Parsed.Error) { return "Error: $($Parsed.Error)" }
                if ($Parsed.ProfileDownloaded) {
                    $s = 'Profile downloaded'
                    if ($Parsed.TenantDomain) { $s += " ($($Parsed.TenantDomain))" }
                    if ($Parsed.AssignedUser)  { $s += " — $($Parsed.AssignedUser)" }
                    return $s
                }
                return 'No Autopilot profile found locally'
            }
            '*Get-DriveMappings*' {
                if (-not $Parsed.Results) { return 'No drive mappings found' }
                $persistent = @($Parsed.Results | Where-Object { $_.Persistent }).Count
                return "$($Parsed.Results.Count) mapping(s) ($persistent persistent)"
            }
            '*Test-BitLockerEscrow*' {
                if ($null -eq $Parsed.AllEscrowed) { return 'Completed' }
                return if ($Parsed.AllEscrowed) { 'All drives escrowed to Entra ID' } else { 'Escrow failed on one or more drives' }
            }
            '*Test-WinRE*' {
                return if ($Parsed.WinREEnabled) { "WinRE enabled — $($Parsed.WinRELocation)" } else { 'WinRE NOT enabled' }
            }
            '*Test-AutopilotReadiness*' {
                if ($Parsed.OverallStatus) { return $Parsed.OverallStatus }
                return 'Completed'
            }
            '*Get-WindowsProductKey*' {
                if ($Parsed.HasOEMKey -eq $true) {
                    $ch = if ($Parsed.Activation -and $Parsed.Activation.ProductKeyChannel) { $Parsed.Activation.ProductKeyChannel } else { '' }
                    $pk = if ($Parsed.Activation -and $Parsed.Activation.PartialProductKey) { "XXXXX-$($Parsed.Activation.PartialProductKey)" } else { '' }
                    return "OEM key detected · $ch · $pk".TrimEnd(' ·').TrimEnd()
                }
                $status = if ($Parsed.Activation -and $Parsed.Activation.LicenseStatus) { $Parsed.Activation.LicenseStatus } else { 'Unknown' }
                return "No embedded OEM key · License: $status"
            }
            '*Get-DeviceHealth*' {
                $diskCount = if ($Parsed.Disks) { $Parsed.Disks.Count } else { 0 }
                $s = "$($Parsed.OverallStatus) · $diskCount disk(s)"
                if ($Parsed.IsLaptop -and $Parsed.Battery -and $Parsed.Battery.EstimatedChargePercent) { $s += " · Battery $($Parsed.Battery.EstimatedChargePercent)%" }
                if ($Parsed.Warnings -and $Parsed.Warnings.Count -gt 0) { $s += " · $($Parsed.Warnings.Count) warning(s)" }
                return $s
            }
            '*Get-TeamsData*' {
                $classic = @($Parsed.Results | Where-Object { $_.ClassicTeamsPresent }).Count
                $new     = @($Parsed.Results | Where-Object { $_.NewTeamsPresent }).Count
                $media   = if ($Parsed.AnyMediaFiles) { ' · meeting recordings found' } else { '' }
                return "$($Parsed.ProfilesChecked) profile(s) · Classic: $classic · New Teams: $new$media"
            }
            '*Get-CredentialManagerEntries*' { return "$($Parsed.EntryCount) credential(s) in Windows Credential Manager" }
            '*Get-LocalAccounts*' { return "$($Parsed.AccountCount) account(s) · $($Parsed.AdminCount) admin(s)" }
            '*Test-BiosVersion*' {
                if (-not $Parsed.IsDell) { return "Non-Dell ($($Parsed.Manufacturer)) — BIOS check skipped" }
                if ($Parsed.Error) { return "BIOS check error: $($Parsed.Error)" }
                $upd = if ($Parsed.UpdateAvailable -eq $true) { " · Update available: v$($Parsed.LatestAvailable)" } else { ' · Up to date' }
                return "BIOS v$($Parsed.CurrentVersion)$upd"
            }
            '*Test-DriverStatus*' {
                if (-not $Parsed.IsDell) { return "Non-Dell ($($Parsed.Manufacturer)) — Dell DCU driver check skipped" }
                $prob = if ($Parsed.ProblematicDrivers -gt 0) { " · $($Parsed.ProblematicDrivers) problematic" } else { '' }
                $dcu  = if ($Parsed.DCUScan -and $Parsed.DCUScan.UpdateAvailable) { ' · DCU updates available' } else { '' }
                return "$($Parsed.TotalDrivers) driver(s)$prob$dcu"
            }
            '*Test-WakeOnLan*' {
                $nicCount   = if ($Parsed.NICs) { $Parsed.NICs.Count } else { 0 }
                $wolEnabled = @($Parsed.NICs | Where-Object { $_.WOLMagicPacket -eq 'Enabled' }).Count
                $bios       = if ($Parsed.BIOS_WOL_Status) { " · BIOS: $($Parsed.BIOS_WOL_Status)" } else { '' }
                return "$wolEnabled/$nicCount NIC(s) with WOL enabled$bios"
            }
            '*Backup-TaskbarLayout*' {
                if (-not $Parsed.Results) { return 'No profiles found' }
                $ok = @($Parsed.Results | Where-Object { $_.Success -eq $true }).Count
                $v  = if ($Parsed.IsWin11) { 'Win11' } else { 'Win10' }
                return "$ok/$($Parsed.Results.Count) profile(s) backed up · $v"
            }
            '*Backup-WiFiProfiles*' {
                if ($Parsed.WlanService -ne 'Running') { return 'No WLAN service — likely a desktop without WiFi' }
                $ent    = if ($Parsed.EnterpriseCount -gt 0) { " · $($Parsed.EnterpriseCount) enterprise (no PSK)" } else { '' }
                $active = if ($Parsed.ActiveSSID) { " · Connected: $($Parsed.ActiveSSID)" } else { '' }
                return "$($Parsed.ExportedCount)/$($Parsed.ProfileCount) profile(s) exported$ent$active"
            }
            '*Set-WakeOnLan*' {
                $changes  = if ($Parsed.Changes) { $Parsed.Changes.Count } else { 0 }
                $nicOk    = @($Parsed.NICs | Where-Object { $_.Success -eq $true }).Count
                $nicTotal = if ($Parsed.NICs) { $Parsed.NICs.Count } else { 0 }
                $bios     = if ($Parsed.BIOS_WOL -and $Parsed.BIOS_WOL.Attempted) { " · BIOS WOL: $(if ($Parsed.BIOS_WOL.Success) {'OK'} else {'Failed'})" } else { '' }
                return "$changes change(s) made · $nicOk/$nicTotal NIC(s) configured$bios"
            }
            '*Install-DellCommandTools*' {
                if ($Parsed.DellDevice -eq $false) { return "Non-Dell ($($Parsed.Vendor)) — tool install skipped" }
                $dcu = if ($Parsed.DCU -and $Parsed.DCU.Version) { "DCU v$($Parsed.DCU.Version)" } else { 'DCU not installed' }
                $dcc = if ($Parsed.DCC -and $Parsed.DCC.Version) { "DCC v$($Parsed.DCC.Version)" } else { 'DCC not installed' }
                return "$dcu · $dcc"
            }
            '*Update-Bios*' {
                if ($Parsed.IsDell -eq $false) { return "Non-Dell ($($Parsed.Vendor)) — BIOS update skipped" }
                if ($Parsed.ExitMeaning) { return $Parsed.ExitMeaning }
                return 'Completed'
            }
            '*Update-Drivers*' {
                if ($Parsed.IsDell -eq $false) { return "Non-Dell ($($Parsed.Vendor)) — driver update skipped" }
                if ($Parsed.ExitMeaning) { return $Parsed.ExitMeaning }
                return 'Completed'
            }
            '*Register-AutopilotDeviceCommunity*' {
                if ($Parsed.UploadStatus -eq 'NeedsInteractiveAuth') { return 'Requires interactive run — use [3] Run Single Step to sign in via OAuth' }
                if ($Parsed.Success -eq $true) {
                    $s = 'Registered via community script'
                    if ($Parsed.AuthAccount) { $s += " · Auth: $($Parsed.AuthAccount)" }
                    if ($Parsed.AuthMethod)  { $s += " ($($Parsed.AuthMethod))" }
                    return $s
                }
                $errSnip = if ($Parsed.Error) { '— ' + $Parsed.Error.Substring(0, [Math]::Min(60, $Parsed.Error.Length)) } else { '' }
                return "Upload: $($Parsed.UploadStatus) $errSnip".Trim()
            }
            '*Register-AutopilotDevice*' {
                if ($Parsed.Success -eq $true) {
                    $s = "Registered · Serial: $($Parsed.SerialNumber)"
                    if ($Parsed.ModuleVersion) { $s += " · Module v$($Parsed.ModuleVersion)" }
                    return $s
                }
                if ($Parsed.UploadStatus) { return "Upload: $($Parsed.UploadStatus) · Serial: $($Parsed.SerialNumber)" }
                return 'Completed'
            }
            '*Get-PreWipeSummary*' {
                if ($Parsed.WipeVerdict) { return "$($Parsed.WipeVerdict) · $($Parsed.BlockerCount) blocker(s) · $($Parsed.ScriptsRan)/$($Parsed.ScriptsTotal) scripts run" }
                return 'Completed'
            }
            default { return 'Completed' }
        }
    } catch { return 'Parse error' }
}

function Get-StepVerdict { # Evaluates step result (PASS/WARN/FAIL)
    param([PSCustomObject]$Parsed, [string]$ScriptFile, [string]$Status) # Parsed output, script path, execution status

    if ($Status -eq 'FAIL') { return @{ Verdict = 'FAIL'; Reason = 'Script execution failed' } } # Execution error = fail
    if ($Status -eq 'SKIP') { return @{ Verdict = 'WARN'; Reason = 'Step was skipped' } } # Skipped step = warn
    if ($null  -eq $Parsed) { return @{ Verdict = 'WARN'; Reason = 'No output to evaluate' } } # No output = warn

    try {
        switch -Wildcard ($ScriptFile) {
            '*Test-OneDriveKFM*' {
                if (-not $Parsed.Results -or $Parsed.Results.Count -eq 0) {
                    return @{ Verdict = 'WARN'; Reason = 'No profiles found to check' }
                }
                $allGood = $true; $primaryGood = $true
                foreach ($r in $Parsed.Results) {
                    if ($r.KFM_Desktop -ne 'Enabled' -or $r.KFM_Documents -ne 'Enabled' -or $r.KFM_Pictures -ne 'Enabled') {
                        $allGood = $false
                        if ($r.Profile -eq $script:PrimaryProfile) { $primaryGood = $false }
                    }
                }
                if ($allGood)          { return @{ Verdict = 'PASS'; Reason = 'All profiles KFM-enabled' } }
                if (-not $primaryGood) { return @{ Verdict = 'FAIL'; Reason = "Primary profile ($($script:PrimaryProfile)) missing KFM" } }
                return @{ Verdict = 'WARN'; Reason = 'Secondary profile(s) missing KFM' }
            }
            '*Test-OneDriveSyncStatus*' {
                if (-not $Parsed.Profiles -or $Parsed.Profiles.Count -eq 0) {
                    return @{ Verdict = 'WARN'; Reason = 'No profiles found to check' }
                }
                $allSafe = $true; $primarySafe = $true
                foreach ($p in $Parsed.Profiles) {
                    if (-not $p.SafeToWipe) {
                        $allSafe = $false
                        if ($p.Profile -eq $script:PrimaryProfile) { $primarySafe = $false }
                    }
                }
                if ($allSafe)          { return @{ Verdict = 'PASS'; Reason = 'All profiles synced and safe' } }
                if (-not $primarySafe) { return @{ Verdict = 'FAIL'; Reason = "Primary profile ($($script:PrimaryProfile)) not synced" } }
                return @{ Verdict = 'WARN'; Reason = 'Secondary profile(s) not synced' }
            }
            '*Find-UnbackedData*' {
                $criticalFail   = @('QuickBooks', 'QuickBooks_Bkp', 'Access_DB', 'Access_DB_Accdb', 'SQLite_DB', 'Generic_DB')
                $warnCategories = @('PST_Files', 'SSH_Keys', 'Cert_PFX', 'Cert_CER')
                $hasFail = $false; $hasWarn = $false
                if ($Parsed.ProfileFindings) {
                    foreach ($pf in $Parsed.ProfileFindings) {
                        if ($pf.Findings) {
                            foreach ($f in $pf.Findings) {
                                if ($criticalFail   -contains $f.Category) { $hasFail = $true }
                                if ($warnCategories -contains $f.Category) { $hasWarn = $true }
                            }
                        }
                    }
                }
                if ($hasFail) { return @{ Verdict = 'FAIL'; Reason = 'Database or QuickBooks files found outside OneDrive' } }
                if ($hasWarn) { return @{ Verdict = 'WARN'; Reason = 'PSTs, SSH keys, or certificates found outside OneDrive' } }
                return @{ Verdict = 'PASS'; Reason = 'No critical unbacked data found' }
            }
            '*Get-DownloadsSize*' {
                if (-not $Parsed.Results) { return @{ Verdict = 'PASS'; Reason = 'No profiles with Downloads' } }
                $anyFail = $false
                foreach ($r in $Parsed.Results) { if ($r.CopySuccess -eq $false) { $anyFail = $true } }
                if ($anyFail) { return @{ Verdict = 'FAIL'; Reason = 'Auto-copy failed for one or more profiles' } }
                return @{ Verdict = 'PASS'; Reason = 'Downloads backed up to Documents' }
            }
            '*Get-InstalledApplications*' { return @{ Verdict = 'PASS'; Reason = "$($Parsed.TotalCount) application(s) documented" } }
            '*Get-StorageMode*' {
                if ($Parsed.StorageMode -match 'RAID|Intel RST|IntelRST') {
                    return @{ Verdict = 'WARN'; Reason = "Storage mode is $($Parsed.StorageMode) — may need AHCI conversion" }
                }
                return @{ Verdict = 'PASS'; Reason = "Storage mode: $($Parsed.StorageMode)" }
            }
            '*Backup-BrowserBookmarks*' {
                if (-not $Parsed.Results -or $Parsed.Results.Count -eq 0) {
                    return @{ Verdict = 'PASS'; Reason = 'No browser profiles found' }
                }
                $edgeSynced = $false; $allBackedUp = $true; $edgeBackedUp = $true; $anyBrowserFound = $false
                foreach ($userResult in $Parsed.Results) {
                    if (-not $userResult.Browsers) { continue }
                    foreach ($b in $userResult.Browsers) {
                        $anyBrowserFound = $true
                        $isEdge = ($b.Browser -match 'Edge')
                        if ($isEdge -and $b.SyncStatus -match 'Sync') { $edgeSynced = $true }
                        if (-not $b.BackedUp) {
                            $allBackedUp = $false
                            if ($isEdge) { $edgeBackedUp = $false }
                        }
                    }
                }
                if (-not $anyBrowserFound) { return @{ Verdict = 'PASS'; Reason = 'No browsers detected' } }
                $noProtection = $false
                foreach ($userResult in $Parsed.Results) {
                    if (-not $userResult.Browsers) { continue }
                    $userHasBackup = $false; $userHasSync = $false
                    foreach ($b in $userResult.Browsers) {
                        if ($b.BackedUp)                  { $userHasBackup = $true }
                        if ($b.SyncStatus -match 'Sync')  { $userHasSync   = $true }
                    }
                    if (-not $userHasBackup -and -not $userHasSync) { $noProtection = $true }
                }
                if ($noProtection)                       { return @{ Verdict = 'FAIL'; Reason = 'Profile(s) have no bookmark sync or backup' } }
                if ($edgeSynced -and $allBackedUp)       { return @{ Verdict = 'PASS'; Reason = 'Edge synced, all bookmarks backed up' } }
                if (-not $edgeSynced -and $allBackedUp)  { return @{ Verdict = 'WARN'; Reason = 'Edge not synced, but all bookmarks backed up' } }
                if ($edgeSynced -and -not $edgeBackedUp) { return @{ Verdict = 'WARN'; Reason = 'Edge synced but backup failed' } }
                return @{ Verdict = 'WARN'; Reason = 'Partial bookmark coverage' }
            }
            '*Backup-DesktopBackground*' {
                if (-not $Parsed.Results) { return @{ Verdict = 'PASS'; Reason = 'No profiles checked' } }
                $anyCustomFailed = $false
                foreach ($r in $Parsed.Results) {
                    if ($r.IsCustom -eq $true -and $r.Success -ne $true) { $anyCustomFailed = $true }
                }
                if ($anyCustomFailed) { return @{ Verdict = 'FAIL'; Reason = 'Custom wallpaper backup failed' } }
                return @{ Verdict = 'PASS'; Reason = 'Wallpapers backed up (or default)' }
            }
            '*Backup-OutlookSignatures*' {
                if (-not $Parsed.Results) { return @{ Verdict = 'PASS'; Reason = 'No profiles checked' } }
                $anyFoundNotBacked = $false
                foreach ($r in $Parsed.Results) {
                    if ($r.Found -eq $true -and $r.Success -ne $true) { $anyFoundNotBacked = $true }
                }
                if ($anyFoundNotBacked) { return @{ Verdict = 'FAIL'; Reason = 'Signature backup failed' } }
                return @{ Verdict = 'PASS'; Reason = 'Signatures backed up (or none found)' }
            }
            '*Get-Printers*' {
                if (-not $Parsed.Printers -or $Parsed.Printers.Count -eq 0) { return @{ Verdict = 'PASS'; Reason = 'No printers found' } }
                $net = @($Parsed.Printers | Where-Object { $_.Type -eq 'Network' }).Count
                return @{ Verdict = 'PASS'; Reason = "$($Parsed.TotalPrinters) printer(s) documented ($net network)" }
            }
            '*Get-DriveMappings*' {
                if (-not $Parsed.Results -or $Parsed.Results.Count -eq 0) { return @{ Verdict = 'PASS'; Reason = 'No drive mappings found' } }
                $persistent = @($Parsed.Results | Where-Object { $_.Persistent }).Count
                return @{ Verdict = 'PASS'; Reason = "$($Parsed.Results.Count) mapping(s) documented ($persistent persistent)" }
            }
            '*Test-BitLockerEscrow*' {
                if ($Parsed.AllEscrowed -eq $true)  { return @{ Verdict = 'PASS'; Reason = 'All drives escrowed to Entra ID' } }
                if ($Parsed.AllEscrowed -eq $false) { return @{ Verdict = 'FAIL'; Reason = 'Escrow failed — BitLocker key not backed up' } }
                return @{ Verdict = 'WARN'; Reason = 'Escrow status unknown' }
            }
            '*Test-WinRE*' {
                if ($Parsed.WinREEnabled) { return @{ Verdict = 'PASS'; Reason = 'WinRE enabled' } }
                return @{ Verdict = 'WARN'; Reason = 'WinRE not enabled — run reagentc /enable' }
            }
            '*Test-AutopilotReadiness*' {
                if ($Parsed.OverallStatus -eq 'READY')     { return @{ Verdict = 'PASS'; Reason = 'Device meets Autopilot hardware requirements' } }
                if ($Parsed.OverallStatus -eq 'NOT READY') { return @{ Verdict = 'FAIL'; Reason = 'Device does not meet Autopilot hardware requirements' } }
                return @{ Verdict = 'WARN'; Reason = 'Autopilot readiness status unknown' }
            }
            '*Get-AutopilotAssignment*' {
                if ($Parsed.ProfileDownloaded) { return @{ Verdict = 'PASS'; Reason = 'Autopilot profile downloaded locally' } }
                return @{ Verdict = 'FAIL'; Reason = 'No Autopilot profile found on device' }
            }
            '*Get-TeamsData*' {
                if ($Parsed.AnyMediaFiles) { return @{ Verdict = 'WARN'; Reason = 'Teams meeting recordings found — back up before wiping' } }
                return @{ Verdict = 'PASS'; Reason = "$($Parsed.ProfilesChecked) profile(s) checked — no meeting recordings" }
            }
            '*Get-CredentialManagerEntries*' {
                $count = if ($null -ne $Parsed.EntryCount) { $Parsed.EntryCount } else { 0 }
                return @{ Verdict = 'PASS'; Reason = "$count credential(s) documented" }
            }
            '*Get-LocalAccounts*' {
                $adminCount = if ($null -ne $Parsed.AdminCount) { $Parsed.AdminCount } else { 0 }
                if ($adminCount -gt 1) { return @{ Verdict = 'WARN'; Reason = "$adminCount admin accounts found — verify before wiping" } }
                return @{ Verdict = 'PASS'; Reason = "$($Parsed.AccountCount) account(s) documented" }
            }
            '*Get-WindowsProductKey*' {
                if ($Parsed.HasOEMKey -eq $true) { return @{ Verdict = 'PASS'; Reason = 'OEM embedded product key detected' } }
                if ($Parsed.HasOEMKey -eq $false) { return @{ Verdict = 'WARN'; Reason = 'No embedded OEM key — document license before wiping' } }
                return @{ Verdict = 'WARN'; Reason = 'Could not determine product key status' }
            }
            '*Get-DeviceHealth*' {
                if ($Parsed.OverallStatus -eq 'HEALTHY') { return @{ Verdict = 'PASS'; Reason = 'No hardware issues detected' } }
                if ($Parsed.OverallStatus -eq 'WARNINGS') {
                    $warn = if ($Parsed.Warnings -and $Parsed.Warnings.Count -gt 0) { ($Parsed.Warnings | Select-Object -First 2) -join '; ' } else { 'Hardware warnings present' }
                    return @{ Verdict = 'WARN'; Reason = $warn }
                }
                return @{ Verdict = 'WARN'; Reason = 'Device health status unknown' }
            }
            '*Test-BiosVersion*' {
                if ($Parsed.IsDell -eq $false) { return @{ Verdict = 'PASS'; Reason = 'Non-Dell device — BIOS version check not applicable' } }
                if ($Parsed.Error) { return @{ Verdict = 'WARN'; Reason = "BIOS check error: $($Parsed.Error)" } }
                if ($Parsed.UpdateAvailable -eq $true) { return @{ Verdict = 'WARN'; Reason = "BIOS update available: v$($Parsed.LatestAvailable) (current: v$($Parsed.CurrentVersion))" } }
                return @{ Verdict = 'PASS'; Reason = "BIOS is current: v$($Parsed.CurrentVersion)" }
            }
            '*Test-DriverStatus*' {
                if ($Parsed.IsDell -eq $false) { return @{ Verdict = 'PASS'; Reason = 'Non-Dell device — Dell DCU driver check not applicable' } }
                if ($Parsed.ProblematicDrivers -gt 0) { return @{ Verdict = 'WARN'; Reason = "$($Parsed.ProblematicDrivers) driver(s) with issues — run Update-Drivers (step 26)" } }
                if ($Parsed.DCUScan -and $Parsed.DCUScan.UpdateAvailable) { return @{ Verdict = 'WARN'; Reason = 'Driver updates available via Dell Command Update' } }
                return @{ Verdict = 'PASS'; Reason = "All $($Parsed.TotalDrivers) driver(s) healthy" }
            }
            '*Test-WakeOnLan*' {
                if (-not $Parsed.NICs -or $Parsed.NICs.Count -eq 0) { return @{ Verdict = 'WARN'; Reason = 'No NICs found to check' } }
                $notEnabled = @($Parsed.NICs | Where-Object { $_.WOLMagicPacket -ne 'Enabled' }).Count
                if ($notEnabled -gt 0) { return @{ Verdict = 'WARN'; Reason = "$notEnabled NIC(s) without WOL — run Set-WakeOnLan (step 24)" } }
                return @{ Verdict = 'PASS'; Reason = "WOL enabled on all $($Parsed.NICs.Count) NIC(s)" }
            }
            '*Backup-TaskbarLayout*' {
                if (-not $Parsed.Results) { return @{ Verdict = 'PASS'; Reason = 'No profiles found' } }
                $failed = @($Parsed.Results | Where-Object { $_.Success -ne $true }).Count
                if ($failed -gt 0) { return @{ Verdict = 'WARN'; Reason = "Taskbar backup failed for $failed profile(s)" } }
                return @{ Verdict = 'PASS'; Reason = "All $($Parsed.Results.Count) profile(s) backed up" }
            }
            '*Backup-WiFiProfiles*' {
                if ($Parsed.WlanService -ne 'Running') { return @{ Verdict = 'PASS'; Reason = 'No WLAN service — not a wireless device' } }
                if ($Parsed.SecurityWarning) { return @{ Verdict = 'WARN'; Reason = 'PSK passwords in exported XML — secure C:\PreWipeOutput\WiFiProfiles\ before wiping' } }
                if ($Parsed.ProfileCount -eq 0) { return @{ Verdict = 'PASS'; Reason = 'No WiFi profiles found' } }
                return @{ Verdict = 'PASS'; Reason = "$($Parsed.ExportedCount)/$($Parsed.ProfileCount) profile(s) exported" }
            }
            '*Set-WakeOnLan*' {
                if (-not $Parsed.NICs -or $Parsed.NICs.Count -eq 0) { return @{ Verdict = 'WARN'; Reason = 'No NICs found to configure' } }
                $nicFailed = @($Parsed.NICs | Where-Object { $_.Success -ne $true }).Count
                $biosOk    = ($Parsed.IsDell -eq $false) -or (-not $Parsed.BIOS_WOL) -or ($Parsed.BIOS_WOL.Attempted -eq $false) -or ($Parsed.BIOS_WOL.Success -eq $true)
                if ($nicFailed -gt 0) { return @{ Verdict = 'WARN'; Reason = "WOL configuration failed on $nicFailed NIC(s)" } }
                if (-not $biosOk) { return @{ Verdict = 'WARN'; Reason = 'BIOS WOL not set — DCC failed. Cold boot may be needed.' } }
                return @{ Verdict = 'PASS'; Reason = "WOL configured on $($Parsed.NICs.Count) NIC(s)" }
            }
            '*Install-DellCommandTools*' {
                if ($Parsed.DellDevice -eq $false) { return @{ Verdict = 'PASS'; Reason = 'Non-Dell device — Dell tools not applicable' } }
                $dcuOk = $Parsed.DCU -and $Parsed.DCU.Success -eq $true
                $dccOk = $Parsed.DCC -and $Parsed.DCC.Success -eq $true
                if ($dcuOk -and $dccOk) { return @{ Verdict = 'PASS'; Reason = "DCU v$($Parsed.DCU.Version) and DCC v$($Parsed.DCC.Version) ready" } }
                if (-not $dcuOk) { return @{ Verdict = 'FAIL'; Reason = "Dell Command Update installation failed: $($Parsed.DCU.Error)" } }
                return @{ Verdict = 'WARN'; Reason = "Dell Command Configure installation failed: $($Parsed.DCC.Error)" }
            }
            '*Update-Bios*' {
                if ($Parsed.IsDell -eq $false) { return @{ Verdict = 'PASS'; Reason = 'Non-Dell device — BIOS update not applicable' } }
                if ($Parsed.Success -eq $true -and $Parsed.RebootNeeded -eq $false) { return @{ Verdict = 'PASS'; Reason = $Parsed.ExitMeaning } }
                if ($Parsed.Success -eq $true -and $Parsed.RebootNeeded -eq $true) { return @{ Verdict = 'WARN'; Reason = 'BIOS updated — reboot required before wiping' } }
                if ($Parsed.Success -eq $false) { return @{ Verdict = 'FAIL'; Reason = "BIOS update failed: $($Parsed.ExitMeaning)" } }
                return @{ Verdict = 'WARN'; Reason = 'BIOS update status unknown' }
            }
            '*Update-Drivers*' {
                if ($Parsed.IsDell -eq $false) { return @{ Verdict = 'PASS'; Reason = 'Non-Dell device — driver update not applicable' } }
                if ($Parsed.Success -eq $true -and $Parsed.RebootNeeded -eq $false) { return @{ Verdict = 'PASS'; Reason = $Parsed.ExitMeaning } }
                if ($Parsed.Success -eq $true -and $Parsed.RebootNeeded -eq $true) { return @{ Verdict = 'WARN'; Reason = 'Drivers updated — reboot required before wiping' } }
                if ($Parsed.Success -eq $false) { return @{ Verdict = 'FAIL'; Reason = "Driver update failed: $($Parsed.ExitMeaning)" } }
                return @{ Verdict = 'WARN'; Reason = 'Driver update status unknown' }
            }
            '*Register-AutopilotDeviceCommunity*' {
                if ($Parsed.Success -eq $true)                        { return @{ Verdict = 'PASS'; Reason = 'Device registered via community script (OAuth)' } }
                if ($Parsed.UploadStatus -eq 'NeedsInteractiveAuth') { return @{ Verdict = 'WARN'; Reason = 'Requires interactive sign-in — run via [3] Run Single Step' } }
                if ($Parsed.UploadStatus -eq 'ExecutionFailed')      { return @{ Verdict = 'FAIL'; Reason = "Community script execution failed: $($Parsed.Error)" } }
                if ($Parsed.UploadStatus -eq 'Failed')               { return @{ Verdict = 'FAIL'; Reason = if ($Parsed.Error) { $Parsed.Error } else { 'Community script reported failure' } } }
                return @{ Verdict = 'FAIL'; Reason = 'OAuth registration did not complete successfully' }
            }
            '*Register-AutopilotDevice*' {
                if ($Parsed.Success -eq $true) { return @{ Verdict = 'PASS'; Reason = "Device registered (upload: $($Parsed.UploadStatus))" } }
                if ($Parsed.UploadStatus -eq 'UploadFailed')   { return @{ Verdict = 'FAIL'; Reason = "Autopilot upload failed: $($Parsed.Error)" } }
                if ($Parsed.UploadStatus -eq 'HashCollected')  { return @{ Verdict = 'WARN'; Reason = 'Hash collected but not yet uploaded' } }
                return @{ Verdict = 'FAIL'; Reason = 'Registration did not complete successfully' }
            }
            '*Get-PreWipeSummary*' {
                if ($Parsed.WipeVerdict -match '^READY TO WIPE$')     { return @{ Verdict = 'PASS'; Reason = "READY TO WIPE · $($Parsed.ScriptsRan)/$($Parsed.ScriptsTotal) scripts run" } }
                if ($Parsed.WipeVerdict -match 'NOT READY')            { return @{ Verdict = 'FAIL'; Reason = "$($Parsed.BlockerCount) blocker(s): $(($Parsed.Blockers | Select-Object -First 2) -join '; ')" } }
                if ($Parsed.WipeVerdict -match 'INCOMPLETE')           { return @{ Verdict = 'WARN'; Reason = "Incomplete — $($Parsed.ScriptsRan)/$($Parsed.ScriptsTotal) scripts run" } }
                return @{ Verdict = 'WARN'; Reason = 'Summary status unknown' }
            }
            default { return @{ Verdict = 'PASS'; Reason = 'Completed' } }
        }
    } catch { return @{ Verdict = 'WARN'; Reason = "Evaluation error: $_" } }
}

function Get-HtmlTable { # Extracts data table from step output
    param($Parsed, [string]$ScriptFile) # Parsed JSON and script path
    if ($null -eq $Parsed) { return '' } # Return empty if no parsed data
    $rows = @(); $cols = @() # Initialize rows and column headers
    try {
        switch -Wildcard ($ScriptFile) { # Match script type and extract table
            '*Test-OneDriveKFM*' {
                if ($Parsed.Results) { $cols = @('Profile','KFM_Desktop','KFM_Documents','KFM_Pictures','SyncStatus'); $rows = @($Parsed.Results) }
            }
            '*Test-OneDriveSyncStatus*' {
                if ($Parsed.Profiles) {
                    $cols = @('Profile','OverallStatus','SafeToWipe')
                    $rows = @($Parsed.Profiles | ForEach-Object { [PSCustomObject]@{ Profile = $_.Profile; OverallStatus = $_.OverallStatus; SafeToWipe = $_.SafeToWipe } })
                }
            }
            '*Find-UnbackedData*' {
                if ($Parsed.ProfileFindings) {
                    $cols = @('Profile','Category','Path')
                    $rows = @($Parsed.ProfileFindings | ForEach-Object {
                        $p = $_.Profile
                        if ($_.Findings) { $_.Findings | ForEach-Object { [PSCustomObject]@{ Profile = $p; Category = $_.Category; Path = $_.Path } } }
                    })
                }
            }
            '*Get-DownloadsSize*' {
                if ($Parsed.Results) {
                    $cols = @('Profile','SizeHuman','FileCount','CopyStatus')
                    $rows = @($Parsed.Results | ForEach-Object {
                        [PSCustomObject]@{
                            Profile    = $_.Profile
                            SizeHuman  = $_.SizeHuman
                            FileCount  = $_.FileCount
                            CopyStatus = if ($_.CopySuccess -eq $true) { "Copied ($($_.CopiedFiles) new)" } elseif ($_.CopySuccess -eq $false) { 'FAILED' } else { 'N/A' }
                        }
                    })
                }
            }
            '*Get-InstalledApplications*' {
                if ($Parsed.Applications) { $cols = @('DisplayName','DisplayVersion','Publisher','Scope'); $rows = @($Parsed.Applications) }
            }
            '*Get-StorageMode*' {
                if ($Parsed.Disks) { $cols = @('Model','MediaType','InterfaceType'); $rows = @($Parsed.Disks) }
            }
            '*Backup-BrowserBookmarks*' {
                if ($Parsed.Results) {
                    $cols = @('Profile','Browser','Sync','BackedUp')
                    $rows = @($Parsed.Results | ForEach-Object {
                        $u = $_.UserProfile
                        if ($_.Browsers) { $_.Browsers | ForEach-Object { [PSCustomObject]@{ Profile = $u; Browser = $_.Browser; Sync = $_.SyncStatus; BackedUp = $_.BackedUp } } }
                    })
                }
            }
            '*Backup-DesktopBackground*'  { if ($Parsed.Results) { $cols = @('Profile','IsCustom','Success','SkipReason'); $rows = @($Parsed.Results) } }
            '*Backup-OutlookSignatures*'   { if ($Parsed.Results) { $cols = @('Profile','Found','FileCount','Success'); $rows = @($Parsed.Results) } }
            '*Get-Printers*'               { if ($Parsed.Printers) { $cols = @('Name','Type','PortName','DriverName','IsDefault'); $rows = @($Parsed.Printers) } }
            '*Get-DriveMappings*'          { if ($Parsed.Results)  { $cols = @('DriveLetter','UNCPath','Persistent','Profile'); $rows = @($Parsed.Results) } }
            '*Get-AutopilotAssignment*' {
                $cols = @('Serial','Downloaded','Tenant','AzureAD','Profile','User')
                $rows = @([PSCustomObject]@{
                    Serial     = $Parsed.SerialNumber
                    Downloaded = if ($Parsed.ProfileDownloaded) { 'YES' } else { 'NO' }
                    Tenant     = if ($Parsed.TenantDomain) { $Parsed.TenantDomain } else { '(unknown)' }
                    AzureAD    = if ($Parsed.AzureADJoined) { 'Joined' } else { 'No' }
                    Profile    = if ($Parsed.ProfileName) { $Parsed.ProfileName } else { '(none)' }
                    User       = if ($Parsed.AssignedUser) { $Parsed.AssignedUser } else { '(none)' }
                })
            }
            '*Register-AutopilotDeviceCommunity*' {
                $cols = @('Serial','AuthAccount','AuthMethod','UploadStatus','GraphModVer')
                $rows = @([PSCustomObject]@{
                    Serial       = if ($Parsed.SerialNumber)    { $Parsed.SerialNumber }           else { '(unknown)' }
                    AuthAccount  = if ($Parsed.AuthAccount)     { $Parsed.AuthAccount }            else { '(community script)' }
                    AuthMethod   = if ($Parsed.AuthMethod)      { $Parsed.AuthMethod }             else { '(community script)' }
                    UploadStatus = if ($Parsed.UploadStatus)    { $Parsed.UploadStatus }           else { '(unknown)' }
                    GraphModVer  = if ($Parsed.GraphModVersion) { "v$($Parsed.GraphModVersion)" }  else { '(unknown)' }
                })
            }
            '*Register-AutopilotDevice*' {
                $cols = @('Serial','ModuleVersion','Hash','UploadStatus','GroupTag','AssignedUser')
                $rows = @([PSCustomObject]@{
                    Serial        = if ($Parsed.SerialNumber)   { $Parsed.SerialNumber }   else { '' }
                    ModuleVersion = if ($Parsed.ModuleVersion)  { "v$($Parsed.ModuleVersion)" } else { '' }
                    Hash          = if ($Parsed.HardwareHash)   { $Parsed.HardwareHash }   else { '' }
                    UploadStatus  = if ($Parsed.UploadStatus)   { $Parsed.UploadStatus }   else { '' }
                    GroupTag      = if ($Parsed.GroupTag)        { $Parsed.GroupTag }        else { '' }
                    AssignedUser  = if ($Parsed.AssignedUser)   { $Parsed.AssignedUser }   else { '' }
                })
            }
            '*Get-WindowsProductKey*' {
                $cols = @('HasOEMKey','Channel','PartialKey','LicenseStatus','OS','Build')
                $rows = @([PSCustomObject]@{
                    HasOEMKey     = if ($Parsed.HasOEMKey -eq $true) { 'YES' } else { 'NO' }
                    Channel       = if ($Parsed.Activation) { $Parsed.Activation.ProductKeyChannel } else { '' }
                    PartialKey    = if ($Parsed.Activation -and $Parsed.Activation.PartialProductKey) { "XXXXX-$($Parsed.Activation.PartialProductKey)" } else { '' }
                    LicenseStatus = if ($Parsed.Activation) { $Parsed.Activation.LicenseStatus } else { '' }
                    OS            = if ($Parsed.OS) { $Parsed.OS.Caption } else { '' }
                    Build         = if ($Parsed.OS) { $Parsed.OS.BuildNumber } else { '' }
                })
            }
            '*Get-DeviceHealth*' {
                if ($Parsed.Disks) {
                    $cols = @('Disk','Type','SizeGB','Health','WearLevel','ReadErrors','WriteErrors')
                    $rows = @($Parsed.Disks | ForEach-Object {
                        [PSCustomObject]@{
                            Disk        = $_.FriendlyName
                            Type        = "$($_.MediaType) ($($_.BusType))"
                            SizeGB      = if ($null -ne $_.SizeGB) { '{0:N0}' -f $_.SizeGB } else { '' }
                            Health      = $_.HealthStatus
                            WearLevel   = if ($null -ne $_.WearLevel) { "$($_.WearLevel)%" } else { 'N/A' }
                            ReadErrors  = if ($null -ne $_.ReadErrors) { $_.ReadErrors } else { '0' }
                            WriteErrors = if ($null -ne $_.WriteErrors) { $_.WriteErrors } else { '0' }
                        }
                    })
                }
            }
            '*Get-TeamsData*' {
                if ($Parsed.Results) {
                    $cols = @('Profile','Classic','ClassicCacheMB','NewTeams','NewCacheMB','Recordings')
                    $rows = @($Parsed.Results | ForEach-Object {
                        [PSCustomObject]@{
                            Profile        = $_.Profile
                            Classic        = if ($_.ClassicTeamsPresent) { 'Yes' } else { 'No' }
                            ClassicCacheMB = if ($null -ne $_.ClassicLocalCacheSizeMB) { '{0:N0}' -f $_.ClassicLocalCacheSizeMB } else { '0' }
                            NewTeams       = if ($_.NewTeamsPresent) { 'Yes' } else { 'No' }
                            NewCacheMB     = if ($null -ne $_.NewTeamsCacheSizeMB) { '{0:N0}' -f $_.NewTeamsCacheSizeMB } else { '0' }
                            Recordings     = if ($_.MeetingMediaFiles) { $_.MeetingMediaFiles.Count } else { '0' }
                        }
                    })
                }
            }
            '*Get-CredentialManagerEntries*' {
                if ($Parsed.Entries) {
                    $cols = @('Target','Type','User')
                    $rows = @($Parsed.Entries | ForEach-Object { [PSCustomObject]@{ Target = $_.Target; Type = $_.Type; User = $_.User } })
                }
            }
            '*Get-LocalAccounts*' {
                if ($Parsed.NonSystemAccounts) {
                    $cols = @('Name','Enabled','IsAdmin','LastLogon')
                    $rows = @($Parsed.NonSystemAccounts | ForEach-Object {
                        [PSCustomObject]@{
                            Name      = $_.Name
                            Enabled   = if ($_.Enabled) { 'Yes' } else { 'No' }
                            IsAdmin   = if ($_.IsAdmin) { 'YES' } else { 'No' }
                            LastLogon = if ($_.LastLogon) { try { ([datetime]$_.LastLogon).ToString('yyyy-MM-dd') } catch { $_.LastLogon } } else { 'Never' }
                        }
                    })
                }
            }
            '*Test-BiosVersion*' {
                $cols = @('Manufacturer','CurrentVersion','ReleaseDate','LatestAvailable','UpdateAvailable')
                $rows = @([PSCustomObject]@{
                    Manufacturer    = if ($Parsed.Manufacturer)     { $Parsed.Manufacturer }     else { '' }
                    CurrentVersion  = if ($Parsed.CurrentVersion)   { $Parsed.CurrentVersion }   else { '' }
                    ReleaseDate     = if ($Parsed.ReleaseDate)       { $Parsed.ReleaseDate }       else { '' }
                    LatestAvailable = if ($Parsed.LatestAvailable)   { $Parsed.LatestAvailable }   else { 'N/A' }
                    UpdateAvailable = if ($Parsed.UpdateAvailable -eq $true) { 'YES' } elseif ($Parsed.UpdateAvailable -eq $false) { 'No' } else { 'Unknown' }
                })
            }
            '*Test-DriverStatus*' {
                $driverList = if ($Parsed.Drivers) { @($Parsed.Drivers | Where-Object { $_.HasIssue -eq $true }) } else { @() }
                if ($driverList.Count -eq 0 -and $Parsed.Drivers) { $driverList = @($Parsed.Drivers | Select-Object -First 15) }
                if ($driverList.Count -gt 0) {
                    $cols = @('DeviceName','Class','DriverVersion','HasIssue','IssueCode')
                    $rows = @($driverList | ForEach-Object {
                        [PSCustomObject]@{
                            DeviceName    = $_.DeviceName
                            Class         = $_.DeviceClass
                            DriverVersion = $_.DriverVersion
                            HasIssue      = if ($_.HasIssue) { 'YES' } else { 'No' }
                            IssueCode     = if ($_.IssueCode) { $_.IssueCode } else { '' }
                        }
                    })
                }
            }
            '*Test-WakeOnLan*' {
                if ($Parsed.NICs) {
                    $cols = @('NIC','WOLMagicPacket','WakeOnPattern','PMWakeEnabled')
                    $rows = @($Parsed.NICs | ForEach-Object {
                        [PSCustomObject]@{
                            NIC            = $_.NICName
                            WOLMagicPacket = $_.WOLMagicPacket
                            WakeOnPattern  = $_.WakeOnPattern
                            PMWakeEnabled  = $_.PMWakeEnabled
                        }
                    })
                }
            }
            '*Backup-TaskbarLayout*' {
                if ($Parsed.Results) {
                    $cols = @('Profile','WindowsVer','FilesBackedUp','RegExported','Success')
                    $rows = @($Parsed.Results | ForEach-Object {
                        [PSCustomObject]@{
                            Profile       = $_.Profile
                            WindowsVer    = $_.WindowsVersion
                            FilesBackedUp = if ($_.FilesBackedUp) { $_.FilesBackedUp.Count } else { 0 }
                            RegExported   = if ($_.RegExported) { 'Yes' } else { 'No' }
                            Success       = if ($_.Success) { 'Yes' } else { 'FAILED' }
                        }
                    })
                }
            }
            '*Backup-WiFiProfiles*' {
                if ($Parsed.Profiles) {
                    $cols = @('SSID','Authentication','KeyType','Exported','Enterprise')
                    $rows = @($Parsed.Profiles | ForEach-Object {
                        [PSCustomObject]@{
                            SSID           = $_.SSID
                            Authentication = if ($_.Authentication) { $_.Authentication } else { 'Unknown' }
                            KeyType        = if ($_.KeyType) { $_.KeyType } else { '' }
                            Exported       = if ($_.Exported) { 'Yes' } else { 'No' }
                            Enterprise     = if ($_.NeedsReauth) { 'YES' } else { 'No' }
                        }
                    })
                }
            }
            '*Set-WakeOnLan*' {
                if ($Parsed.NICs) {
                    $cols = @('NIC','WOLMagicPacket','PMWakeEnabled','Success')
                    $rows = @($Parsed.NICs | ForEach-Object {
                        [PSCustomObject]@{
                            NIC            = $_.NICName
                            WOLMagicPacket = $_.WOLMagicPacket
                            PMWakeEnabled  = $_.PMWakeEnabled
                            Success        = if ($_.Success) { 'Yes' } else { 'FAILED' }
                        }
                    })
                }
            }
            '*Install-DellCommandTools*' {
                if ($Parsed.DellDevice -eq $true) {
                    $cols = @('Tool','Version','Action','Success')
                    $rows = @(
                        [PSCustomObject]@{ Tool = 'Dell Command Update';    Version = if ($Parsed.DCU -and $Parsed.DCU.Version) { $Parsed.DCU.Version } else { 'N/A' }; Action = if ($Parsed.DCU) { $Parsed.DCU.Action } else { '' }; Success = if ($Parsed.DCU -and $Parsed.DCU.Success) { 'Yes' } else { 'No' } }
                        [PSCustomObject]@{ Tool = 'Dell Command Configure'; Version = if ($Parsed.DCC -and $Parsed.DCC.Version) { $Parsed.DCC.Version } else { 'N/A' }; Action = if ($Parsed.DCC) { $Parsed.DCC.Action } else { '' }; Success = if ($Parsed.DCC -and $Parsed.DCC.Success) { 'Yes' } else { 'No' } }
                    )
                }
            }
            '*Update-Bios*' {
                $cols = @('Vendor','ExitCode','Result','RebootNeeded')
                $rows = @([PSCustomObject]@{
                    Vendor       = if ($Parsed.Vendor)      { $Parsed.Vendor }      else { '' }
                    ExitCode     = if ($null -ne $Parsed.ExitCode) { $Parsed.ExitCode } else { 'N/A' }
                    Result       = if ($Parsed.ExitMeaning) { $Parsed.ExitMeaning } else { 'N/A' }
                    RebootNeeded = if ($Parsed.RebootNeeded -eq $true) { 'YES' } else { 'No' }
                })
            }
            '*Update-Drivers*' {
                $cols = @('Vendor','ExitCode','Result','RebootNeeded')
                $rows = @([PSCustomObject]@{
                    Vendor       = if ($Parsed.Vendor)      { $Parsed.Vendor }      else { '' }
                    ExitCode     = if ($null -ne $Parsed.ExitCode) { $Parsed.ExitCode } else { 'N/A' }
                    Result       = if ($Parsed.ExitMeaning) { $Parsed.ExitMeaning } else { 'N/A' }
                    RebootNeeded = if ($Parsed.RebootNeeded -eq $true) { 'YES' } else { 'No' }
                })
            }
            '*Test-BitLockerEscrow*' {
                if ($Parsed.Volumes) {
                    $cols = @('Drive','VolumeType','EncryptionStatus','PercentEncrypted','EscrowStatus')
                    $rows = @($Parsed.Volumes | ForEach-Object {
                        [PSCustomObject]@{
                            Drive            = $_.DriveLetter
                            VolumeType       = $_.VolumeType
                            EncryptionStatus = $_.EncryptionStatus
                            PercentEncrypted = if ($null -ne $_.PercentEncrypted) { "$($_.PercentEncrypted)%" } else { '' }
                            EscrowStatus     = $_.EscrowStatus
                        }
                    })
                }
            }
            '*Test-WinRE*' {
                $cols = @('WinREEnabled','Location','Status')
                $rows = @([PSCustomObject]@{
                    WinREEnabled = if ($Parsed.WinREEnabled) { 'YES' } else { 'NO' }
                    Location     = if ($Parsed.WinRELocation) { $Parsed.WinRELocation } else { 'N/A' }
                    Status       = if ($Parsed.WinREEnabled) { 'OK' } else { 'Missing — run: reagentc /enable' }
                })
            }
            '*Test-AutopilotReadiness*' {
                if ($Parsed.Checks -and $Parsed.Checks.PSObject.Properties) {
                    $cols = @('Check','Status','Detail')
                    $rows = @($Parsed.Checks.PSObject.Properties | ForEach-Object {
                        $chk = $_.Value
                        [PSCustomObject]@{
                            Check  = $_.Name
                            Status = if ($chk.Status)  { $chk.Status }  else { '' }
                            Detail = if ($chk.Detail)  { $chk.Detail }  else { '' }
                        }
                    })
                } elseif ($Parsed.Failures -and $Parsed.Failures.Count -gt 0) {
                    $cols = @('Failure')
                    $rows = @($Parsed.Failures | ForEach-Object { [PSCustomObject]@{ Failure = $_ } })
                }
            }
            '*Get-PreWipeSummary*' {
                if ($Parsed.Blockers -and $Parsed.Blockers.Count -gt 0) {
                    $cols = @('Blocker')
                    $rows = @($Parsed.Blockers | ForEach-Object { [PSCustomObject]@{ Blocker = $_ } })
                } elseif ($Parsed.PhaseSummary) {
                    $cols = @('Phase','ScriptsRan','ScriptsTotal','Completion')
                    $rows = @($Parsed.PhaseSummary)
                }
            }
        }
    } catch { return '' }
    if ($rows.Count -eq 0 -or $cols.Count -eq 0) { return '' }

    $html = [System.Text.StringBuilder]::new()
    $null = $html.AppendLine('<table>')
    $null = $html.Append('<tr>')
    foreach ($c in $cols) { $null = $html.Append("<th>$([System.Web.HttpUtility]::HtmlEncode($c))</th>") }
    $null = $html.AppendLine('</tr>')
    for ($i = 0; $i -lt $rows.Count; $i++) {
        $null = $html.Append('<tr>')
        foreach ($c in $cols) {
            $val = $rows[$i].$c
            if ($null -eq $val) { $val = '' }
            $null = $html.Append("<td>$([System.Web.HttpUtility]::HtmlEncode([string]$val))</td>")
        }
        $null = $html.AppendLine('</tr>')
    }
    $null = $html.AppendLine('</table>')

    $tableStr = $html.ToString()
    if ($ScriptFile -match 'Get-InstalledApplications' -and $rows.Count -gt 0) {
        return "<details><summary>Show all $($rows.Count) applications &#8250;</summary>$tableStr</details>"
    }
    return $tableStr
}

function Export-HtmlReport { # Generates styled HTML report from results
    param([PSCustomObject[]]$ResultSet, [string]$RunLabel = 'Run') # Result set and run label

    $stamp    = Get-Date -Format 'yyyyMMdd-HHmmss' # Timestamp for filename
    $htmlPath = Join-Path $OutputRoot "PreWipeReport_$($script:ComputerName)_$stamp.html" # Output file path
    $now      = Get-Date -Format 'yyyy-MM-dd HH:mm:ss' # Current timestamp

    $done  = @($ResultSet | Where-Object { $_.Status -eq 'DONE' }).Count
    $fail  = @($ResultSet | Where-Object { $_.Status -eq 'FAIL' }).Count
    $skip  = @($ResultSet | Where-Object { $_.Status -eq 'SKIP' }).Count

    $failV = @($ResultSet | Where-Object { $_.Verdict -eq 'FAIL' })
    $warnV = @($ResultSet | Where-Object { $_.Verdict -eq 'WARN' })

    $readinessClass = if ($failV.Count -eq 0 -and $warnV.Count -eq 0) { 'ready' } elseif ($failV.Count -eq 0) { 'warnings' } else { 'not-ready' }
    $readinessText  = if ($failV.Count -eq 0 -and $warnV.Count -eq 0) { '&#10003; Ready to Wipe' } `
                      elseif ($failV.Count -eq 0) { "&#9888; Ready to Wipe &mdash; $($warnV.Count) warning(s)" } `
                      else { "&#10007; Not Ready &mdash; $($failV.Count) issue(s) to resolve" }

    $sb = [System.Text.StringBuilder]::new()
    $null = $sb.AppendLine(@'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Pre-Wipe Report</title>
<style>
  :root{--pass:#22c55e;--fail:#ef4444;--skip:#eab308;--bg:#f8fafc;--card:#fff;--border:#e2e8f0;--text:#1e293b;--muted:#64748b}
  *{margin:0;padding:0;box-sizing:border-box}
  body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;background:var(--bg);color:var(--text);line-height:1.5}
  .header{background:#0f172a;color:#fff;padding:24px 32px}
  .header h1{font-size:1.5rem;font-weight:600}
  .header .sub{color:#94a3b8;font-size:.875rem;margin-top:4px}
  .device-info{display:flex;gap:32px;margin-top:12px;font-size:.8125rem;color:#cbd5e1}
  .container{max-width:900px;margin:0 auto;padding:24px 16px}
  .badges{display:flex;gap:12px;margin-bottom:24px}
  .badge{padding:8px 20px;border-radius:8px;font-weight:600;font-size:.875rem;color:#fff}
  .badge.pass{background:var(--pass)}.badge.fail{background:var(--fail)}.badge.skip{background:var(--skip);color:#422006}.badge.total{background:#334155}
  .card{background:var(--card);border:1px solid var(--border);border-radius:8px;margin-bottom:12px;overflow:hidden}
  .card-head{display:flex;justify-content:space-between;align-items:center;padding:12px 16px;border-bottom:1px solid var(--border)}
  .card-head .step-name{font-weight:600;font-size:.9375rem}
  .status{padding:2px 10px;border-radius:4px;font-size:.75rem;font-weight:700;color:#fff;text-transform:uppercase}
  .status.done{background:var(--pass)}.status.fail{background:var(--fail)}.status.skip{background:var(--skip);color:#422006}
  .verdict{padding:2px 10px;border-radius:4px;font-size:.75rem;font-weight:700;color:#fff;text-transform:uppercase;margin-left:6px}
  .verdict.pass{background:var(--pass)}.verdict.warn{background:var(--skip);color:#422006}.verdict.fail{background:var(--fail)}
  .card-body{padding:12px 16px}.card-body .summary{color:var(--muted);font-size:.875rem}
  .card-body table{width:100%;border-collapse:collapse;margin-top:8px;font-size:.8125rem}
  .card-body th{text-align:left;padding:4px 8px;border-bottom:2px solid var(--border);color:var(--muted);font-weight:600}
  .card-body td{padding:4px 8px;border-bottom:1px solid var(--border)}
  .readiness{padding:12px 20px;border-radius:8px;font-weight:600;font-size:.9375rem;margin-bottom:24px;text-align:center}
  .readiness.ready{background:#dcfce7;color:#166534;border:1px solid #86efac}
  .readiness.warnings{background:#fef9c3;color:#854d0e;border:1px solid #fde047}
  .readiness.not-ready{background:#fee2e2;color:#991b1b;border:1px solid #fca5a5}
  .footer{text-align:center;color:var(--muted);font-size:.75rem;padding:16px;margin-top:24px}
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
</style>
</head>
<body>
'@)
    $null = $sb.AppendLine("<div class='header'><h1>Pre-Wipe Report</h1><div class='sub'>AshesToAutopilot &middot; $([System.Web.HttpUtility]::HtmlEncode($RunLabel))</div>")
    $null = $sb.AppendLine("<div class='device-info'><span><strong>PC:</strong> $([System.Web.HttpUtility]::HtmlEncode($script:ComputerName))</span><span><strong>SN:</strong> $([System.Web.HttpUtility]::HtmlEncode($script:SerialNumber))</span><span><strong>User:</strong> $([System.Web.HttpUtility]::HtmlEncode($script:CurrentUser))</span><span><strong>Date:</strong> $now</span></div></div>")
    $null = $sb.AppendLine("<div class='container'>")
    $null = $sb.AppendLine("<div class='badges'><div class='badge pass'>DONE: $done</div><div class='badge fail'>FAIL: $fail</div><div class='badge skip'>SKIP: $skip</div><div class='badge total'>Total: $($ResultSet.Count)</div></div>")
    $null = $sb.AppendLine("<div class='readiness $readinessClass'>$readinessText")
    if ($failV.Count -gt 0) {
        $null = $sb.AppendLine("<div style='margin-top:6px;font-size:.8125rem;font-weight:400'>")
        foreach ($fv in $failV) {
            $null = $sb.AppendLine("$([System.Web.HttpUtility]::HtmlEncode($fv.DisplayName)): $([System.Web.HttpUtility]::HtmlEncode($fv.VerdictReason))<br/>")
        }
        $null = $sb.AppendLine('</div>')
    }
    $null = $sb.AppendLine('</div>')

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

    $issueCount = @($ResultSet | Where-Object { $_.Verdict -eq 'FAIL' -or $_.Verdict -eq 'WARN' }).Count
    $warnCount  = @($ResultSet | Where-Object { $_.Verdict -eq 'WARN' }).Count
    $phaseKeys  = @($script:Steps | Select-Object -ExpandProperty Phase -Unique)

    $null = $sb.AppendLine("<div class='filter-bar'>")
    $null = $sb.AppendLine("<span class='filter-label'>Show:</span>")
    $null = $sb.AppendLine("<button class='filter-btn active' onclick='filterCards(""all"",this)'>All ($($script:Steps.Count))</button>")
    $null = $sb.AppendLine("<button class='filter-btn' onclick='filterCards(""issues"",this)'>Issues Only ($issueCount)</button>")
    $null = $sb.AppendLine("<button class='filter-btn' onclick='filterCards(""warn"",this)'>Warnings ($warnCount)</button>")
    $null = $sb.AppendLine("<div class='phase-jumps'>")
    foreach ($pk in $phaseKeys) {
        $pl = Get-PhaseLabel $pk
        $null = $sb.AppendLine("<a class='phase-jump' href='#phase-$($pk.ToLower())'>$([System.Web.HttpUtility]::HtmlEncode($pl))</a>")
    }
    $null = $sb.AppendLine("</div>")
    $null = $sb.AppendLine("</div>")

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
  document.querySelectorAll('.phase-header').forEach(function(h){
    var sib=h.nextElementSibling;
    var hasVisible=false;
    while(sib&&!sib.classList.contains('phase-header')){
      if(sib.classList.contains('card')&&sib.style.display!=='none'){hasVisible=true;break}
      sib=sib.nextElementSibling;
    }
    h.style.display=hasVisible?'':'none';
  });
}
</script>
'@)

    $htmlSizeKb = [Math]::Round($sb.Length / 1024, 0)
    $null = $sb.AppendLine("<div class='export-panel'><h4>&#128190; This Report</h4>")
    $null = $sb.AppendLine("<div class='export-grid'>")
    $null = $sb.AppendLine("<span>HTML</span><span class='path'>$([System.Web.HttpUtility]::HtmlEncode($htmlPath))</span><span class='size'>~$htmlSizeKb KB</span>")
    $null = $sb.AppendLine("</div></div>")
    $null = $sb.AppendLine("<div class='footer'>Generated $now by Start-PreWipeToolkit.ps1</div>")
    $null = $sb.AppendLine('</div></body></html>')

    try {
        $sb.ToString() | Set-Content $htmlPath -Encoding UTF8 -Force
        Write-Log "HTML report: $htmlPath"
        Write-Host "  HTML report: $htmlPath" -ForegroundColor Cyan
    } catch {
        Write-ErrorLog "Failed to save HTML report: $_"
    }
    return $htmlPath
}

function Export-SessionReport { # Exports session as JSON and text
    Clear-Host # Clear screen
    Write-Host '' # Blank line
    Write-Host '  Exporting Session Report...' -ForegroundColor Cyan
    Write-Host '' # Blank line

    $stamp    = Get-Date -Format 'yyyyMMdd-HHmmss' # Timestamp for filename
    $baseName = "PreWipeReport_$($script:ComputerName)_$stamp" # Base filename
    $jsonPath = Join-Path $OutputRoot "$baseName.json" # JSON file path
    $txtPath  = Join-Path $OutputRoot "$baseName.txt" # Text file path

    try {
        $script:Session | ConvertTo-Json -Depth 5 | Set-Content $jsonPath -Encoding UTF8 -Force
    } catch {
        Write-ErrorLog "JSON export failed: $_"
        Write-Host "  JSON export failed: $_" -ForegroundColor Red
    }

    try {
        $lines = [System.Collections.Generic.List[string]]::new()
        $lines.Add('Pre-Wipe Toolkit — Session Report')
        $lines.Add('==================================')
        $lines.Add("Computer     : $($script:ComputerName)")
        $lines.Add("Serial       : $($script:SerialNumber)")
        $lines.Add("User         : $($script:CurrentUser)")
        $lines.Add("Session Start: $($script:Session.StartTime)")
        $lines.Add("Generated    : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
        $lines.Add('')
        foreach ($group in ($script:Steps | Group-Object Phase)) {
            $lines.Add("--- $(Get-PhaseLabel $group.Name) ---")
            foreach ($step in $group.Group) {
                $stepData = $script:Session.Steps["$($step.Index)"]
                $ts       = if ($stepData -and $stepData.Timestamp) { "  ($($stepData.Timestamp))" } else { '' }
                $lines.Add("  [$($step.Status.PadRight(7))] $($step.DisplayName)$ts")
            }
            $lines.Add('')
        }
        $done  = @($script:Steps | Where-Object { $_.Status -eq 'DONE' }).Count
        $fail  = @($script:Steps | Where-Object { $_.Status -eq 'FAIL' }).Count
        $skip  = @($script:Steps | Where-Object { $_.Status -eq 'SKIP' }).Count
        $norun = @($script:Steps | Where-Object { $_.Status -eq 'not-run' }).Count
        $lines.Add('--- Summary ---')
        $lines.Add("  Done    : $done")
        $lines.Add("  Failed  : $fail")
        $lines.Add("  Skipped : $skip")
        $lines.Add("  Not Run : $norun")
        $lines | Set-Content $txtPath -Encoding UTF8 -Force
    } catch {
        Write-ErrorLog "TXT export failed: $_"
        Write-Host "  TXT export failed: $_" -ForegroundColor Red
    }

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

    Write-Host ''
    Write-Host '  Press any key to return...' -ForegroundColor DarkGray
    $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
}
