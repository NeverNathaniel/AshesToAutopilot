# Toolkit-Report.ps1 — HTML report and session export functions for Start-PreWipeToolkit.ps1
# Dot-sourced by the orchestrator. Do not run directly.

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
            '*Get-InstalledApplications*' { return @{ Verdict = 'PASS'; Reason = 'Informational' } }
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
            '*Get-Printers*'              { return @{ Verdict = 'PASS'; Reason = 'Informational' } }
            '*Get-DriveMappings*'         { return @{ Verdict = 'PASS'; Reason = 'Informational' } }
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
            '*Get-TeamsData*'               { return @{ Verdict = 'PASS'; Reason = 'Informational' } }
            '*Get-CredentialManagerEntries*'{ return @{ Verdict = 'PASS'; Reason = 'Informational' } }
            '*Get-LocalAccounts*'           { return @{ Verdict = 'PASS'; Reason = 'Informational' } }
            '*Register-AutopilotDevice*' {
                if ($Parsed.Success -eq $true) { return @{ Verdict = 'PASS'; Reason = "Device registered (upload: $($Parsed.UploadStatus))" } }
                if ($Parsed.UploadStatus -eq 'UploadFailed') { return @{ Verdict = 'FAIL'; Reason = "Autopilot upload failed: $($Parsed.Error)" } }
                if ($Parsed.UploadStatus -eq 'HashCollected') { return @{ Verdict = 'WARN'; Reason = 'Hash collected but not uploaded' } }
                return @{ Verdict = 'FAIL'; Reason = 'Registration did not complete successfully' }
            }
            default                         { return @{ Verdict = 'PASS'; Reason = 'Completed' } }
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
