<#
.SYNOPSIS
    Lightweight pre-wipe orchestrator — runs 11 key checks sequentially with
    formatted table output, a rich results summary, and an HTML report.

.DESCRIPTION
    Streamlined version of Start-PreWipeToolkit.ps1. No PSMenu dependency, no
    session persistence, no interactive menu loop. Captures JSON output from
    every child script, displays results as formatted tables, and ends with a
    colour-coded summary showing what each script actually found. Also generates
    a professional one-page HTML report.

    Steps (11):
      1. Check OneDrive KFM
      2. Check OneDrive Sync Status
      3. Scan for Unbacked Data
      4. Get Downloads Size
      5. Get Installed Applications
      6. Get Storage Controller Mode
      7. Backup Browser Bookmarks
      8. Backup Desktop Background
      9. Backup Outlook Signatures
     10. Get Printers
     11. Check Autopilot Profile

.PARAMETER NonInteractive
    Suppresses all interactive prompts and display. Runs every step, emits a
    consolidated JSON object to stdout, then exits with code 0 or 1.

.NOTES
    Source repos used: None (orchestrator only; delegates to child scripts)
    Requirements  : Administrator privileges
    Output dir    : C:\PreWipeOutput\
    Log dir       : C:\PreWipeOutput\Logs\
    HTML report   : C:\PreWipeOutput\PreWipeReport_<ComputerName>_<timestamp>.html
    Does NOT modify any script in .\Scripts\ — calls them by path only.

.EXAMPLE
    .\Start-PreWipeToolkitLite.ps1

    Launches the lite pre-wipe run with confirmation prompt.

.EXAMPLE
    .\Start-PreWipeToolkitLite.ps1 -NonInteractive

    Runs all steps silently and outputs JSON results.
#>

[CmdletBinding()]
param(
    [switch]$NonInteractive
)

#region --- Init ---
$ScriptName = 'Start-PreWipeToolkitLite'
$OutputRoot  = 'C:\PreWipeOutput'
$LogDir      = Join-Path $OutputRoot 'Logs'
$LogFile     = Join-Path $LogDir "$ScriptName.log"
$ErrorLog    = Join-Path $OutputRoot 'errors.log'

foreach ($dir in @($OutputRoot, $LogDir)) {
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
}

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $entry = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message"
    $entry | Add-Content -Path $LogFile -Encoding UTF8
    if (-not $NonInteractive) {
        $color = switch ($Level) {
            'WARN'  { 'Yellow' }
            'ERROR' { 'Red' }
            default { 'Gray' }
        }
        Write-Host "  $Message" -ForegroundColor $color
    }
}

function Write-ErrorLog {
    param([string]$Message)
    $entry = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$ScriptName] ERROR: $Message"
    $entry | Add-Content -Path $ErrorLog -Encoding UTF8
    Write-Log -Message "ERROR: $Message" -Level 'ERROR'
}

# Detect primary (most recently active) profile for verdict evaluation
$script:PrimaryProfile = $null
try {
    $vpSkipSIDs   = @('S-1-5-18', 'S-1-5-19', 'S-1-5-20')
    $vpSkipNames  = @('ithlocal', 'itklocal', 'wsi', 'wsiaccount', 'defaultuser0', 'administrator', 'guest')
    $vpCutoff = (Get-Date).AddDays(-30)
    $primaryProfileObj = Get-CimInstance -ClassName Win32_UserProfile -ErrorAction Stop |
        Where-Object { -not $_.Special -and $vpSkipSIDs -notcontains $_.SID } |
        Where-Object { $vpSkipNames -notcontains (Split-Path $_.LocalPath -Leaf).ToLower() } |
        Where-Object { $_.LastUseTime -and $_.LastUseTime -ge $vpCutoff } |
        Sort-Object LastUseTime -Descending | Select-Object -First 1
    if ($primaryProfileObj) {
        $script:PrimaryProfile = Split-Path $primaryProfileObj.LocalPath -Leaf
        Write-Log "Primary profile (most recent): $($script:PrimaryProfile)"
    }
} catch {
    Write-Log "Could not determine primary profile: $_" -Level 'WARN'
}

$script:CompletedCount = 0

# Required for HTML encoding in the report
Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue
#endregion

#region --- Admin Check ---
$_principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $_principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    if ($NonInteractive) {
        [PSCustomObject]@{ Error = 'Must run as Administrator' } | ConvertTo-Json | Write-Output
        exit 1
    }
    Write-Host ''
    Write-Host '  ERROR: This script must run as Administrator.' -ForegroundColor Red
    Write-Host '  Right-click PowerShell > Run as Administrator, then try again.' -ForegroundColor Yellow
    Write-Host ''
    Read-Host '  Press Enter to close...'
    exit 1
}
#endregion

#region --- Device Info ---
$ComputerName = $env:COMPUTERNAME
$CurrentUser  = $env:USERNAME
try {
    $_bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction SilentlyContinue
    $SerialNumber = if ($_bios -and $_bios.SerialNumber) { $_bios.SerialNumber.Trim() } else { 'Unknown' }
}
catch {
    $SerialNumber = 'Unknown'
}
#endregion

#region --- Step Definitions ---
$Steps = @(
    [PSCustomObject]@{ Index = 1;  DisplayName = 'Check OneDrive KFM';           ScriptPath = 'Scripts\ConfigurationChecks\Test-OneDriveKFM.ps1' }
    [PSCustomObject]@{ Index = 2;  DisplayName = 'Check OneDrive Sync Status';   ScriptPath = 'Scripts\ConfigurationChecks\Test-OneDriveSyncStatus.ps1' }
    [PSCustomObject]@{ Index = 3;  DisplayName = 'Scan for Unbacked Data';       ScriptPath = 'Scripts\DataCollection\Find-UnbackedData.ps1' }
    [PSCustomObject]@{ Index = 4;  DisplayName = 'Get Downloads Size';           ScriptPath = 'Scripts\DataCollection\Get-DownloadsSize.ps1' }
    [PSCustomObject]@{ Index = 5;  DisplayName = 'Get Installed Applications';   ScriptPath = 'Scripts\DataCollection\Get-InstalledApplications.ps1' }
    [PSCustomObject]@{ Index = 6;  DisplayName = 'Get Storage Controller Mode';  ScriptPath = 'Scripts\ConfigurationChecks\Get-StorageMode.ps1' }
    [PSCustomObject]@{ Index = 7;  DisplayName = 'Backup Browser Bookmarks';     ScriptPath = 'Scripts\ConfigurationChanges\Backup-BrowserBookmarks.ps1' }
    [PSCustomObject]@{ Index = 8;  DisplayName = 'Backup Desktop Background';    ScriptPath = 'Scripts\ConfigurationChanges\Backup-DesktopBackground.ps1' }
    [PSCustomObject]@{ Index = 9;  DisplayName = 'Backup Outlook Signatures';    ScriptPath = 'Scripts\ConfigurationChanges\Backup-OutlookSignatures.ps1' }
    [PSCustomObject]@{ Index = 10; DisplayName = 'Get Printers';                 ScriptPath = 'Scripts\DataCollection\Get-Printers.ps1' }
    [PSCustomObject]@{ Index = 11; DisplayName = 'Check Autopilot Profile';      ScriptPath = 'Scripts\AutopilotReadiness\Get-AutopilotAssignment.ps1' }
)

$Results = @()
#endregion

#region --- Display Helpers ---
function Write-CyanBox {
    param([string[]]$Lines, [int]$MinWidth = 56)
    if (-not $Lines -or $Lines.Count -eq 0) { $Lines = @('') }
    $normalized = @($Lines | ForEach-Object { if ($null -eq $_) { '' } else { [string]$_ } })
    $maxLen = ($normalized | Measure-Object -Property Length -Maximum).Maximum
    if ($null -eq $maxLen) { $maxLen = 0 }
    $w = [Math]::Max($maxLen, $MinWidth)
    $bar = [string]::new([char]0x2550, $w + 2)
    Write-Host ''
    Write-Host ([char]0x2554 + $bar + [char]0x2557) -ForegroundColor Cyan
    foreach ($l in $normalized) {
        Write-Host ([char]0x2551 + ' ' + $l.PadRight($w) + ' ' + [char]0x2551) -ForegroundColor Cyan
    }
    Write-Host ([char]0x255A + $bar + [char]0x255D) -ForegroundColor Cyan
    Write-Host ''
}

function Show-Header {
    Write-Host ''
    Write-Host '  Pre-Wipe Toolkit Lite' -NoNewline -ForegroundColor White
    Write-Host ' · AshesToAutopilot' -ForegroundColor DarkGray
    Write-Host "  $ComputerName · SN: $SerialNumber · $CurrentUser" -ForegroundColor DarkGray

    # Progress bar
    $total   = $Steps.Count
    $done    = $script:CompletedCount
    $barLen  = 24
    $filled  = if ($total -gt 0) { [Math]::Floor(($done / $total) * $barLen) } else { 0 }
    $empty   = $barLen - $filled
    Write-Host -NoNewline '  '
    if ($filled -gt 0) { Write-Host -NoNewline ([string]::new([char]0x2588, $filled)) -ForegroundColor Green }
    if ($empty  -gt 0) { Write-Host -NoNewline ([string]::new([char]0x2591, $empty))  -ForegroundColor DarkGray }
    Write-Host "  $done/$total complete" -ForegroundColor Gray

    Write-Host "  $([string]::new([char]0x2500, 56))" -ForegroundColor DarkGray
    Write-Host ''
}

function Show-StepList {
    Write-Host '  Steps to run:' -ForegroundColor Cyan
    Write-Host ''
    foreach ($step in $Steps) {
        $num = $step.Index.ToString().PadLeft(2)
        Write-Host "    $($num). $($step.DisplayName)" -ForegroundColor Gray
    }
    Write-Host ''
}

function Show-Table {
    param([array]$Data, [string[]]$Properties)
    if (-not $Data -or $Data.Count -eq 0) {
        Write-Host '    (no data)' -ForegroundColor DarkGray
        return
    }
    $tableStr = $Data | Select-Object $Properties | Format-Table -AutoSize | Out-String
    $tableStr.Split("`n") | ForEach-Object {
        if ($_.Trim()) { Write-Host "    $_" -ForegroundColor Gray }
    }
}
#endregion

#region --- Per-Script Formatters & Summary Extractors ---

function Format-StepOutput {
    param([PSCustomObject]$Parsed, [string]$ScriptFile)
    if ($null -eq $Parsed) { return }

    switch -Wildcard ($ScriptFile) {
        '*Test-OneDriveKFM*' {
            if ($Parsed.Results) {
                Show-Table -Data $Parsed.Results -Properties 'Profile','KFM_Desktop','KFM_Documents','KFM_Pictures','SyncStatus'
            }
        }
        '*Test-OneDriveSyncStatus*' {
            if ($Parsed.Profiles) {
                $rows = @($Parsed.Profiles | ForEach-Object {
                    [PSCustomObject]@{
                        Profile    = $_.Profile
                        Status     = $_.OverallStatus
                        SafeToWipe = $_.SafeToWipe
                        Issues     = if ($_.Issues) { ($_.Issues -join '; ').Substring(0, [Math]::Min(50, ($_.Issues -join '; ').Length)) } else { '' }
                    }
                })
                Show-Table -Data $rows -Properties 'Profile','Status','SafeToWipe','Issues'
            }
        }
        '*Find-UnbackedData*' {
            if ($Parsed.ProfileFindings) {
                $rows = @($Parsed.ProfileFindings | ForEach-Object {
                    $prof = $_.Profile
                    if ($_.Findings) {
                        $_.Findings | ForEach-Object {
                            [PSCustomObject]@{
                                Profile  = $prof
                                Category = $_.Category
                                Path     = if ($_.Path.Length -gt 45) { '...' + $_.Path.Substring($_.Path.Length - 42) } else { $_.Path }
                                Size     = if ($_.SizeBytes -gt 1MB) { '{0:N1} MB' -f ($_.SizeBytes / 1MB) } elseif ($_.SizeBytes -gt 1KB) { '{0:N0} KB' -f ($_.SizeBytes / 1KB) } else { "$($_.SizeBytes) B" }
                            }
                        }
                    }
                })
                if ($rows.Count -gt 0) { Show-Table -Data $rows -Properties 'Profile','Category','Path','Size' }
                else { Write-Host '    No unbacked data found.' -ForegroundColor Green }
            }
            if ($Parsed.NonStandardApps -and $Parsed.NonStandardApps.Count -gt 0) {
                Write-Host ''
                Write-Host '    Non-Standard Apps:' -ForegroundColor Yellow
                Show-Table -Data $Parsed.NonStandardApps -Properties 'Name','Version','Publisher'
            }
        }
        '*Get-DownloadsSize*' {
            if ($Parsed.Results) {
                $rows = @($Parsed.Results | ForEach-Object {
                    [PSCustomObject]@{
                        Profile = $_.Profile
                        Size    = $_.SizeHuman
                        Files   = $_.FileCount
                        Copied  = if ($_.CopySuccess -eq $true) { "Yes ($($_.CopiedFiles) new)" } elseif ($_.CopySuccess -eq $false) { 'FAILED' } else { 'N/A' }
                    }
                })
                Show-Table -Data $rows -Properties 'Profile','Size','Files','Copied'
            }
        }
        '*Get-InstalledApplications*' {
            if ($Parsed.Applications) {
                $top = @($Parsed.Applications | Select-Object -First 15)
                Show-Table -Data $top -Properties 'DisplayName','DisplayVersion','Publisher','Scope'
                if ($Parsed.Applications.Count -gt 15) {
                    Write-Host "    ... and $($Parsed.Applications.Count - 15) more" -ForegroundColor DarkGray
                }
            }
        }
        '*Get-StorageMode*' {
            $rows = @([PSCustomObject]@{
                StorageMode = $Parsed.StorageMode
                IntelRST    = $Parsed.IntelRSTDetected
            })
            Show-Table -Data $rows -Properties 'StorageMode','IntelRST'
            if ($Parsed.Disks) {
                Show-Table -Data $Parsed.Disks -Properties 'Model','MediaType','InterfaceType',@{Name='SizeGB';Expression={'{0:N0}' -f $_.Size}}
            }
        }
        '*Backup-BrowserBookmarks*' {
            if ($Parsed.Results) {
                $rows = @($Parsed.Results | ForEach-Object {
                    $user = $_.UserProfile
                    if ($_.Browsers) {
                        $_.Browsers | ForEach-Object {
                            [PSCustomObject]@{
                                Profile  = $user
                                Browser  = $_.Browser
                                Sync     = $_.SyncStatus
                                BackedUp = $_.BackedUp
                            }
                        }
                    }
                })
                if ($rows.Count -gt 0) { Show-Table -Data $rows -Properties 'Profile','Browser','Sync','BackedUp' }
            }
        }
        '*Backup-DesktopBackground*' {
            if ($Parsed.Results) {
                Show-Table -Data $Parsed.Results -Properties 'Profile','IsCustom','Success','SkipReason'
            }
        }
        '*Backup-OutlookSignatures*' {
            if ($Parsed.Results) {
                Show-Table -Data $Parsed.Results -Properties 'Profile','Found','FileCount','Success'
            }
        }
        '*Get-Printers*' {
            if ($Parsed.Printers) {
                Show-Table -Data $Parsed.Printers -Properties 'Name','Type','PortName','DriverName','IsDefault'
            }
        }
        '*Get-AutopilotAssignment*' {
            $rows = @([PSCustomObject]@{
                Serial     = $Parsed.SerialNumber
                Downloaded = if ($Parsed.ProfileDownloaded) { 'YES' } else { 'NO' }
                Tenant     = if ($Parsed.TenantDomain) { $Parsed.TenantDomain } else { '(unknown)' }
                AzureAD    = if ($Parsed.AzureADJoined) { 'Joined' } else { 'No' }
                Profile    = if ($Parsed.ProfileName) { $Parsed.ProfileName } else { '(none)' }
                User       = if ($Parsed.AssignedUser) { $Parsed.AssignedUser } else { '(none)' }
            })
            Show-Table -Data $rows -Properties 'Serial','Downloaded','Tenant','AzureAD','Profile','User'
        }
    }
}

function Get-StepSummary {
    param([PSCustomObject]$Parsed, [string]$ScriptFile)
    if ($null -eq $Parsed) { return 'No output' }

    try {
        switch -Wildcard ($ScriptFile) {
            '*Test-OneDriveKFM*' {
                if (-not $Parsed.Results) { return 'No profiles' }
                $enabled = @($Parsed.Results | Where-Object { $_.KFM_Desktop -eq 'Enabled' -and $_.KFM_Documents -eq 'Enabled' -and $_.KFM_Pictures -eq 'Enabled' }).Count
                return "$enabled/$($Parsed.Results.Count) profiles fully KFM-enabled"
            }
            '*Test-OneDriveSyncStatus*' {
                return "$($Parsed.OverallVerdict) ($($Parsed.ProfilesChecked) profiles)"
            }
            '*Find-UnbackedData*' {
                $totalFindings = 0
                if ($Parsed.ProfileFindings) { $Parsed.ProfileFindings | ForEach-Object { $totalFindings += $_.FindingCount } }
                $appCount = if ($Parsed.NonStandardApps) { $Parsed.NonStandardApps.Count } else { 0 }
                if ($totalFindings -eq 0 -and $appCount -eq 0) { return 'Clean - nothing found' }
                return "$totalFindings item(s) at risk, $appCount non-std app(s)"
            }
            '*Get-DownloadsSize*' {
                if (-not $Parsed.Results) { return 'No profiles' }
                $totalBytes = ($Parsed.Results | Measure-Object -Property SizeBytes -Sum).Sum
                $totalFiles = ($Parsed.Results | Measure-Object -Property FileCount -Sum).Sum
                $sizeStr = if ($totalBytes -gt 1GB) { '{0:N1} GB' -f ($totalBytes / 1GB) } elseif ($totalBytes -gt 1MB) { '{0:N0} MB' -f ($totalBytes / 1MB) } else { '{0:N0} KB' -f ($totalBytes / 1KB) }
                $copied = @($Parsed.Results | Where-Object { $_.CopySuccess -eq $true }).Count
                $total  = $Parsed.Results.Count
                return "$sizeStr across $total user(s) - $copied/$total copied to Documents"
            }
            '*Get-InstalledApplications*' {
                return "$($Parsed.TotalCount) apps ($($Parsed.MachineCount) machine, $($Parsed.UserCount) user)"
            }
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
                $totalFiles = ($Parsed.Results | Measure-Object -Property FileCount -Sum).Sum
                return "$found user(s) with signatures, $totalFiles file(s) backed up"
            }
            '*Get-Printers*' {
                if (-not $Parsed.Printers -or $Parsed.Printers.Count -eq 0) { return 'No printers found' }
                $net   = @($Parsed.Printers | Where-Object { $_.Type -eq 'Network' }).Count
                $local = @($Parsed.Printers | Where-Object { $_.Type -eq 'Local' }).Count
                return "$($Parsed.TotalPrinters) printer(s) ($net network, $local local)"
            }
            '*Get-AutopilotAssignment*' {
                if ($Parsed.Error) { return "Error: $($Parsed.Error)" }
                if ($Parsed.ProfileDownloaded) {
                    $summary = 'Profile downloaded'
                    if ($Parsed.TenantDomain) { $summary += " ($($Parsed.TenantDomain))" }
                    if ($Parsed.AssignedUser) { $summary += " - $($Parsed.AssignedUser)" }
                    return $summary
                }
                return 'No Autopilot profile found locally'
            }
            default { return 'Completed' }
        }
    }
    catch {
        return 'Parse error'
    }
}

function Get-StepVerdict {
    param([PSCustomObject]$Parsed, [string]$ScriptFile, [string]$Status)

    if ($Status -eq 'FAIL') { return @{ Verdict = 'FAIL'; Reason = 'Script execution failed' } }
    if ($Status -eq 'SKIP') { return @{ Verdict = 'WARN'; Reason = 'Step was skipped' } }
    if ($null -eq $Parsed)  { return @{ Verdict = 'WARN'; Reason = 'No output to evaluate' } }

    try {
        switch -Wildcard ($ScriptFile) {
            '*Test-OneDriveKFM*' {
                if (-not $Parsed.Results -or $Parsed.Results.Count -eq 0) {
                    return @{ Verdict = 'WARN'; Reason = 'No profiles found to check' }
                }
                $allGood = $true; $primaryGood = $true
                foreach ($r in $Parsed.Results) {
                    $kfmOk = ($r.KFM_Desktop -eq 'Enabled' -and $r.KFM_Documents -eq 'Enabled' -and $r.KFM_Pictures -eq 'Enabled')
                    if (-not $kfmOk) {
                        $allGood = $false
                        if ($r.Profile -eq $script:PrimaryProfile) { $primaryGood = $false }
                    }
                }
                if ($allGood)         { return @{ Verdict = 'PASS'; Reason = 'All profiles KFM-enabled' } }
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
                $criticalFail = @('QuickBooks', 'QuickBooks_Bkp', 'Access_DB', 'Access_DB_Accdb', 'SQLite_DB', 'Generic_DB')
                $warnCategories = @('PST_Files', 'SSH_Keys', 'Cert_PFX', 'Cert_CER')
                $hasFail = $false; $hasWarn = $false
                if ($Parsed.ProfileFindings) {
                    foreach ($pf in $Parsed.ProfileFindings) {
                        if ($pf.Findings) {
                            foreach ($f in $pf.Findings) {
                                if ($criticalFail -contains $f.Category) { $hasFail = $true }
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
                foreach ($r in $Parsed.Results) {
                    if ($r.CopySuccess -eq $false) { $anyFail = $true }
                }
                if ($anyFail) { return @{ Verdict = 'FAIL'; Reason = 'Auto-copy failed for one or more profiles' } }
                return @{ Verdict = 'PASS'; Reason = 'Downloads backed up to Documents' }
            }
            '*Get-InstalledApplications*' {
                return @{ Verdict = 'PASS'; Reason = 'Informational' }
            }
            '*Get-StorageMode*' {
                if ($Parsed.StorageMode -match 'RAID|Intel RST|IntelRST') {
                    return @{ Verdict = 'WARN'; Reason = "Storage mode is $($Parsed.StorageMode) - may need AHCI conversion" }
                }
                return @{ Verdict = 'PASS'; Reason = "Storage mode: $($Parsed.StorageMode)" }
            }
            '*Backup-BrowserBookmarks*' {
                if (-not $Parsed.Results -or $Parsed.Results.Count -eq 0) {
                    return @{ Verdict = 'PASS'; Reason = 'No browser profiles found' }
                }
                $edgeSynced = $false; $allBackedUp = $true; $edgeBackedUp = $true
                $anyBrowserFound = $false
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
                        if ($b.BackedUp) { $userHasBackup = $true }
                        if ($b.SyncStatus -match 'Sync') { $userHasSync = $true }
                    }
                    if (-not $userHasBackup -and -not $userHasSync) { $noProtection = $true }
                }
                if ($noProtection) { return @{ Verdict = 'FAIL'; Reason = 'Profile(s) have no bookmark sync or backup' } }
                if ($edgeSynced -and $allBackedUp) { return @{ Verdict = 'PASS'; Reason = 'Edge synced, all bookmarks backed up' } }
                if (-not $edgeSynced -and $allBackedUp) { return @{ Verdict = 'WARN'; Reason = 'Edge not synced, but all bookmarks backed up' } }
                if ($edgeSynced -and -not $edgeBackedUp) { return @{ Verdict = 'WARN'; Reason = 'Edge synced but backup failed; other browsers OK' } }
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
                return @{ Verdict = 'PASS'; Reason = 'Informational' }
            }
            '*Get-AutopilotAssignment*' {
                if ($Parsed.ProfileDownloaded) {
                    return @{ Verdict = 'PASS'; Reason = 'Autopilot profile downloaded locally' }
                }
                return @{ Verdict = 'FAIL'; Reason = 'No Autopilot profile found on device' }
            }
            default { return @{ Verdict = 'PASS'; Reason = 'Completed' } }
        }
    }
    catch { return @{ Verdict = 'WARN'; Reason = "Evaluation error: $_" } }
}
#endregion

#region --- Step Execution (JSON Capture) ---
function Invoke-LiteStep {
    param([PSCustomObject]$Step)

    $fullPath = Join-Path $PSScriptRoot $Step.ScriptPath

    if (-not (Test-Path $fullPath)) {
        Write-Log "Script not found, skipping: $($Step.ScriptPath)" -Level 'WARN'
        return @{ Status = 'SKIP'; Parsed = $null; Summary = 'Script not found' }
    }

    $LASTEXITCODE = 0
    $exitCode = 0
    $jsonRaw  = ''
    $parsed   = $null

    try {
        $jsonRaw = & $fullPath -NonInteractive 2>&1 | Out-String
        $exitCode = if ($null -ne $LASTEXITCODE) { $LASTEXITCODE } else { 0 }
    }
    catch {
        Write-ErrorLog "Step $($Step.Index) ($($Step.DisplayName)) threw: $_"
        return @{ Status = 'FAIL'; Parsed = $null; Summary = "Error: $_" }
    }

    # Parse JSON
    try {
        if ($jsonRaw.Trim()) {
            $parsed = $jsonRaw | ConvertFrom-Json
        }
    }
    catch {
        Write-Log "Could not parse JSON from $($Step.DisplayName)" -Level 'WARN'
    }

    $summary = Get-StepSummary -Parsed $parsed -ScriptFile $Step.ScriptPath
    $status  = if ($exitCode -eq 0) { 'DONE' } else { 'FAIL' }

    Write-Log "Step $($Step.Index) ($($Step.DisplayName)): $status - $summary"

    $verdict = Get-StepVerdict -Parsed $parsed -ScriptFile $Step.ScriptPath -Status $status

    return @{
        Status        = $status
        Parsed        = $parsed
        Summary       = $summary
        RawJson       = $jsonRaw
        Verdict       = $verdict.Verdict
        VerdictReason = $verdict.Reason
    }
}
#endregion

#region --- Rich Summary Display ---
function Show-Summary {
    param([array]$ResultSet)

    $bar = [string]::new([char]0x2550, 62)

    Write-Host ''
    Write-Host "  $bar" -ForegroundColor Cyan
    Write-Host '  RESULTS SUMMARY' -ForegroundColor White
    Write-Host "  $bar" -ForegroundColor Cyan
    Write-Host ''

    foreach ($r in $ResultSet) {
        $num   = $r.Index.ToString().PadLeft(2)
        $name  = $r.DisplayName.PadRight(30)
        $badge = "[$($r.Status)]"
        $summ  = if ($r.Summary) { $r.Summary } else { '' }

        $badgeColor = switch ($r.Status) {
            'DONE' { 'Green' }
            'FAIL' { 'Red' }
            'SKIP' { 'Yellow' }
            default { 'Gray' }
        }

        $verdictIcon = switch ($r.Verdict) {
            'PASS' { '[OK]' }
            'WARN' { '[!!]' }
            'FAIL' { '[XX]' }
            default { '[--]' }
        }
        $verdictColor = switch ($r.Verdict) {
            'PASS' { 'Green' }
            'WARN' { 'Yellow' }
            'FAIL' { 'Red' }
            default { 'Gray' }
        }

        Write-Host "   $num. $name " -NoNewline -ForegroundColor Gray
        Write-Host $badge.PadRight(7) -NoNewline -ForegroundColor $badgeColor
        Write-Host " $verdictIcon" -NoNewline -ForegroundColor $verdictColor
        Write-Host " $summ" -ForegroundColor DarkGray
    }

    $done  = @($ResultSet | Where-Object { $_.Status -eq 'DONE' }).Count
    $fail  = @($ResultSet | Where-Object { $_.Status -eq 'FAIL' }).Count
    $skip  = @($ResultSet | Where-Object { $_.Status -eq 'SKIP' }).Count
    $total = $ResultSet.Count

    Write-Host ''
    Write-Host "  $bar" -ForegroundColor Cyan
    Write-Host -NoNewline '  DONE: ' -ForegroundColor Gray
    Write-Host -NoNewline "$done" -ForegroundColor Green
    Write-Host -NoNewline '  |  FAIL: ' -ForegroundColor Gray
    Write-Host -NoNewline "$fail" -ForegroundColor Red
    Write-Host -NoNewline '  |  SKIP: ' -ForegroundColor Gray
    Write-Host -NoNewline "$skip" -ForegroundColor Yellow
    Write-Host "  |  Total: $total" -ForegroundColor Gray
    Write-Host "  $bar" -ForegroundColor Cyan

    # Overall verdict
    $failCount = @($ResultSet | Where-Object { $_.Verdict -eq 'FAIL' }).Count
    $warnCount = @($ResultSet | Where-Object { $_.Verdict -eq 'WARN' }).Count
    Write-Host ''
    if ($failCount -eq 0 -and $warnCount -eq 0) {
        Write-Host '  READY TO WIPE' -ForegroundColor Green
    } elseif ($failCount -eq 0) {
        Write-Host "  READY TO WIPE ($warnCount warning(s))" -ForegroundColor Yellow
    } else {
        Write-Host "  NOT READY - $failCount issue(s) to resolve" -ForegroundColor Red
        foreach ($r in ($ResultSet | Where-Object { $_.Verdict -eq 'FAIL' })) {
            Write-Host "    - $($r.DisplayName): $($r.VerdictReason)" -ForegroundColor Red
        }
    }
    Write-Host ''
}
#endregion

#region --- HTML Report ---
function Export-HtmlReport {
    param([array]$ResultSet)

    $stamp    = Get-Date -Format 'yyyyMMdd-HHmmss'
    $htmlPath = Join-Path $OutputRoot "PreWipeReport_$($ComputerName)_$stamp.html"

    $done  = @($ResultSet | Where-Object { $_.Status -eq 'DONE' }).Count
    $fail  = @($ResultSet | Where-Object { $_.Status -eq 'FAIL' }).Count
    $skip  = @($ResultSet | Where-Object { $_.Status -eq 'SKIP' }).Count
    $total = $ResultSet.Count
    $now   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

    $sb = [System.Text.StringBuilder]::new()

    # ── HTML head + CSS ──────────────────────────────────────────────────
    $null = $sb.AppendLine(@'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Pre-Wipe Report</title>
<style>
  :root { --pass: #22c55e; --fail: #ef4444; --skip: #eab308; --bg: #f8fafc; --card: #fff; --border: #e2e8f0; --text: #1e293b; --muted: #64748b; }
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; background: var(--bg); color: var(--text); line-height: 1.5; }
  .header { background: #0f172a; color: #fff; padding: 24px 32px; }
  .header h1 { font-size: 1.5rem; font-weight: 600; }
  .header .subtitle { color: #94a3b8; font-size: 0.875rem; margin-top: 4px; }
  .device-info { display: flex; gap: 32px; margin-top: 12px; font-size: 0.8125rem; color: #cbd5e1; }
  .device-info span { display: inline-flex; align-items: center; gap: 4px; }
  .container { max-width: 900px; margin: 0 auto; padding: 24px 16px; }
  .badges { display: flex; gap: 12px; margin-bottom: 24px; }
  .badge { padding: 8px 20px; border-radius: 8px; font-weight: 600; font-size: 0.875rem; color: #fff; }
  .badge.pass { background: var(--pass); }
  .badge.fail { background: var(--fail); }
  .badge.skip { background: var(--skip); color: #422006; }
  .badge.total { background: #334155; }
  .card { background: var(--card); border: 1px solid var(--border); border-radius: 8px; margin-bottom: 12px; overflow: hidden; }
  .card-head { display: flex; justify-content: space-between; align-items: center; padding: 12px 16px; border-bottom: 1px solid var(--border); }
  .card-head .step-name { font-weight: 600; font-size: 0.9375rem; }
  .card-head .status { padding: 2px 10px; border-radius: 4px; font-size: 0.75rem; font-weight: 700; color: #fff; text-transform: uppercase; }
  .card-head .status.done { background: var(--pass); }
  .card-head .status.fail { background: var(--fail); }
  .card-head .status.skip { background: var(--skip); color: #422006; }
  .card-body { padding: 12px 16px; }
  .card-body .summary { color: var(--muted); font-size: 0.875rem; }
  .card-body table { width: 100%; border-collapse: collapse; margin-top: 8px; font-size: 0.8125rem; }
  .card-body th { text-align: left; padding: 4px 8px; border-bottom: 2px solid var(--border); color: var(--muted); font-weight: 600; }
  .card-body td { padding: 4px 8px; border-bottom: 1px solid var(--border); }
  .footer { text-align: center; color: var(--muted); font-size: 0.75rem; padding: 16px; margin-top: 24px; }
  .verdict { padding: 2px 10px; border-radius: 4px; font-size: 0.75rem; font-weight: 700; color: #fff; text-transform: uppercase; margin-left: 6px; }
  .verdict.pass { background: var(--pass); }
  .verdict.warn { background: var(--skip); color: #422006; }
  .verdict.fail { background: var(--fail); }
  .readiness { padding: 12px 20px; border-radius: 8px; font-weight: 600; font-size: 0.9375rem; margin-bottom: 24px; text-align: center; }
  .readiness.ready { background: #dcfce7; color: #166534; border: 1px solid #86efac; }
  .readiness.warnings { background: #fef9c3; color: #854d0e; border: 1px solid #fde047; }
  .readiness.not-ready { background: #fee2e2; color: #991b1b; border: 1px solid #fca5a5; }
  .fail-list { margin-top: 6px; font-size: 0.8125rem; font-weight: 400; }
  @media print { .header { background: #0f172a !important; -webkit-print-color-adjust: exact; print-color-adjust: exact; } .badge, .status { -webkit-print-color-adjust: exact; print-color-adjust: exact; } }
</style>
</head>
<body>
'@)

    # ── Header ───────────────────────────────────────────────────────────
    $null = $sb.AppendLine("<div class='header'>")
    $null = $sb.AppendLine("  <h1>Pre-Wipe Report</h1>")
    $null = $sb.AppendLine("  <div class='subtitle'>AshesToAutopilot &middot; Lite Run</div>")
    $null = $sb.AppendLine("  <div class='device-info'>")
    $null = $sb.AppendLine("    <span><strong>PC:</strong> $([System.Web.HttpUtility]::HtmlEncode($ComputerName))</span>")
    $null = $sb.AppendLine("    <span><strong>SN:</strong> $([System.Web.HttpUtility]::HtmlEncode($SerialNumber))</span>")
    $null = $sb.AppendLine("    <span><strong>User:</strong> $([System.Web.HttpUtility]::HtmlEncode($CurrentUser))</span>")
    $null = $sb.AppendLine("    <span><strong>Date:</strong> $now</span>")
    $null = $sb.AppendLine("  </div>")
    $null = $sb.AppendLine("</div>")

    # ── Badges ───────────────────────────────────────────────────────────
    $null = $sb.AppendLine("<div class='container'>")
    $null = $sb.AppendLine("<div class='badges'>")
    $null = $sb.AppendLine("  <div class='badge pass'>DONE: $done</div>")
    $null = $sb.AppendLine("  <div class='badge fail'>FAIL: $fail</div>")
    $null = $sb.AppendLine("  <div class='badge skip'>SKIP: $skip</div>")
    $null = $sb.AppendLine("  <div class='badge total'>Total: $total</div>")
    $null = $sb.AppendLine("</div>")

    # ── Readiness verdict ─────────────────────────────────────────────────
    $failVerdicts = @($ResultSet | Where-Object { $_.Verdict -eq 'FAIL' })
    $warnVerdicts = @($ResultSet | Where-Object { $_.Verdict -eq 'WARN' })
    if ($failVerdicts.Count -eq 0 -and $warnVerdicts.Count -eq 0) {
        $null = $sb.AppendLine("<div class='readiness ready'>&#10003; Ready to Wipe</div>")
    } elseif ($failVerdicts.Count -eq 0) {
        $null = $sb.AppendLine("<div class='readiness warnings'>&#9888; Ready to Wipe &mdash; $($warnVerdicts.Count) warning(s)</div>")
    } else {
        $null = $sb.AppendLine("<div class='readiness not-ready'>&#10007; Not Ready &mdash; $($failVerdicts.Count) issue(s) to resolve")
        $null = $sb.AppendLine("<div class='fail-list'>")
        foreach ($fv in $failVerdicts) {
            $null = $sb.AppendLine("$([System.Web.HttpUtility]::HtmlEncode($fv.DisplayName)): $([System.Web.HttpUtility]::HtmlEncode($fv.VerdictReason))<br/>")
        }
        $null = $sb.AppendLine("</div></div>")
    }

    # ── Step cards ───────────────────────────────────────────────────────
    foreach ($r in $ResultSet) {
        $statusClass = switch ($r.Status) { 'DONE' { 'done' } 'FAIL' { 'fail' } 'SKIP' { 'skip' } default { 'skip' } }
        $nameEnc = [System.Web.HttpUtility]::HtmlEncode($r.DisplayName)
        $summEnc = [System.Web.HttpUtility]::HtmlEncode($r.Summary)

        $null = $sb.AppendLine("<div class='card'>")
        $null = $sb.AppendLine("  <div class='card-head'>")
        $null = $sb.AppendLine("    <span class='step-name'>$($r.Index). $nameEnc</span>")
        $verdictClass = switch ($r.Verdict) { 'PASS' { 'pass' } 'WARN' { 'warn' } 'FAIL' { 'fail' } default { 'pass' } }
        $verdictLabel = switch ($r.Verdict) { 'PASS' { '&#10003; Pass' } 'WARN' { '&#9888; Warn' } 'FAIL' { '&#10007; Fail' } default { '' } }
        $reasonEnc = [System.Web.HttpUtility]::HtmlEncode($r.VerdictReason)
        $null = $sb.AppendLine("    <span class='status $statusClass'>$($r.Status)</span>")
        $null = $sb.AppendLine("    <span class='verdict $verdictClass' title='$reasonEnc'>$verdictLabel</span>")
        $null = $sb.AppendLine("  </div>")
        $null = $sb.AppendLine("  <div class='card-body'>")
        $null = $sb.AppendLine("    <div class='summary'>$summEnc</div>")
        if ($r.VerdictReason) {
            $vrEnc = [System.Web.HttpUtility]::HtmlEncode($r.VerdictReason)
            $vrColor = switch ($r.Verdict) { 'PASS' { 'var(--pass)' } 'WARN' { '#b45309' } 'FAIL' { 'var(--fail)' } default { 'var(--text)' } }
            $null = $sb.AppendLine("    <div class='summary' style='margin-top:4px;font-weight:600;color:$vrColor'>$vrEnc</div>")
        }

        # Build a mini HTML table from parsed data
        $tableHtml = Get-HtmlTable -Parsed $r.ParsedData -ScriptFile $r.ScriptPath
        if ($tableHtml) { $null = $sb.AppendLine($tableHtml) }

        $null = $sb.AppendLine("  </div>")
        $null = $sb.AppendLine("</div>")
    }

    # ── Footer ───────────────────────────────────────────────────────────
    $null = $sb.AppendLine("<div class='footer'>Generated $now by Start-PreWipeToolkitLite.ps1</div>")
    $null = $sb.AppendLine("</div></body></html>")

    try {
        $sb.ToString() | Set-Content $htmlPath -Encoding UTF8 -Force
        Write-Log "HTML report saved to $($htmlPath)."
        if (-not $NonInteractive) {
            Write-Host "  HTML report: $htmlPath" -ForegroundColor Cyan
        }
    }
    catch {
        Write-ErrorLog "Failed to save HTML report: $_"
    }

    return $htmlPath
}

function Get-HtmlTable {
    param($Parsed, [string]$ScriptFile)
    if ($null -eq $Parsed) { return '' }

    $rows = @()
    $cols = @()

    try {
        switch -Wildcard ($ScriptFile) {
            '*Test-OneDriveKFM*' {
                if ($Parsed.Results) {
                    $cols = @('Profile','KFM_Desktop','KFM_Documents','KFM_Pictures','SyncStatus')
                    $rows = @($Parsed.Results)
                }
            }
            '*Test-OneDriveSyncStatus*' {
                if ($Parsed.Profiles) {
                    $cols = @('Profile','OverallStatus','SafeToWipe')
                    $rows = @($Parsed.Profiles | ForEach-Object {
                        [PSCustomObject]@{ Profile = $_.Profile; OverallStatus = $_.OverallStatus; SafeToWipe = $_.SafeToWipe }
                    })
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
                if ($Parsed.Applications) {
                    $cols = @('DisplayName','DisplayVersion','Publisher','Scope')
                    $rows = @($Parsed.Applications | Select-Object -First 10)
                }
            }
            '*Get-StorageMode*' {
                if ($Parsed.Disks) {
                    $cols = @('Model','MediaType','InterfaceType')
                    $rows = @($Parsed.Disks)
                }
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
            '*Backup-DesktopBackground*' {
                if ($Parsed.Results) { $cols = @('Profile','IsCustom','Success','SkipReason'); $rows = @($Parsed.Results) }
            }
            '*Backup-OutlookSignatures*' {
                if ($Parsed.Results) { $cols = @('Profile','Found','FileCount','Success'); $rows = @($Parsed.Results) }
            }
            '*Get-Printers*' {
                if ($Parsed.Printers) { $cols = @('Name','Type','PortName','DriverName','IsDefault'); $rows = @($Parsed.Printers) }
            }
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
    }
    catch { return '' }

    if ($rows.Count -eq 0 -or $cols.Count -eq 0) { return '' }

    $html = [System.Text.StringBuilder]::new()
    $null = $html.AppendLine('<table>')
    $null = $html.Append('<tr>')
    foreach ($c in $cols) { $null = $html.Append("<th>$([System.Web.HttpUtility]::HtmlEncode($c))</th>") }
    $null = $html.AppendLine('</tr>')

    $limit = [Math]::Min($rows.Count, 15)
    for ($i = 0; $i -lt $limit; $i++) {
        $null = $html.Append('<tr>')
        foreach ($c in $cols) {
            $val = $rows[$i].$c
            if ($null -eq $val) { $val = '' }
            $null = $html.Append("<td>$([System.Web.HttpUtility]::HtmlEncode([string]$val))</td>")
        }
        $null = $html.AppendLine('</tr>')
    }

    if ($rows.Count -gt 15) {
        $null = $html.AppendLine("<tr><td colspan='$($cols.Count)' style='color:var(--muted);font-style:italic'>... and $($rows.Count - 15) more rows</td></tr>")
    }

    $null = $html.AppendLine('</table>')
    return $html.ToString()
}
#endregion

#region --- Main Logic ---

# ── NonInteractive mode ─────────────────────────────────────────────────
if ($NonInteractive) {
    Write-Log 'Starting Lite run (NonInteractive).'

    try {
        foreach ($step in $Steps) {
            $result = Invoke-LiteStep -Step $step
            $Results += [PSCustomObject]@{
                Index         = $step.Index
                DisplayName   = $step.DisplayName
                ScriptPath    = $step.ScriptPath
                Status        = $result.Status
                Summary       = $result.Summary
                ParsedData    = $result.Parsed
                Verdict       = $result.Verdict
                VerdictReason = $result.VerdictReason
            }
        }

        $done = @($Results | Where-Object { $_.Status -eq 'DONE' }).Count
        $fail = @($Results | Where-Object { $_.Status -eq 'FAIL' }).Count
        $skip = @($Results | Where-Object { $_.Status -eq 'SKIP' }).Count

        $output = [PSCustomObject]@{
            Timestamp    = (Get-Date -Format 'o')
            ScriptName   = $ScriptName
            ComputerName = $ComputerName
            SerialNumber = $SerialNumber
            CurrentUser  = $CurrentUser
            Steps        = @($Results | Select-Object Index, DisplayName, ScriptPath, Status, Summary)
            Summary      = [PSCustomObject]@{
                Total   = $Results.Count
                Done    = $done
                Failed  = $fail
                Skipped = $skip
            }
        }

        # Save JSON report
        $reportPath = Join-Path $LogDir "$ScriptName-Report.json"
        try { $output | ConvertTo-Json -Depth 5 | Set-Content $reportPath -Encoding UTF8 -Force }
        catch { Write-ErrorLog "Failed to save report: $_" }

        # Generate HTML report
        $null = Export-HtmlReport -ResultSet $Results

        $output | ConvertTo-Json -Depth 5 | Write-Output
        Write-Log "Lite run complete. Done=$done, Fail=$fail, Skip=$skip."
        if ($fail -gt 0) { exit 1 } else { exit 0 }
    }
    catch {
        Write-ErrorLog "Fatal error in NonInteractive run: $_"
        exit 1
    }
}

# ── Interactive mode ─────────────────────────────────────────────────────
Clear-Host
Show-Header
Show-StepList

Write-Log 'Starting Lite run (Interactive).'

$confirm = Read-Host '  Run all 11 steps? (Y/N)'
if ($confirm -notmatch '^[Yy]') {
    Write-Host ''
    Write-Host '  Cancelled. No steps were run.' -ForegroundColor Yellow
    Write-Host ''
    Write-Log 'User cancelled Lite run.'
    Read-Host '  Press Enter to continue'
    exit 0
}

try {
    $total = $Steps.Count
    foreach ($step in $Steps) {
        Clear-Host
        Show-Header

        Write-CyanBox -Lines @(
            $step.DisplayName
            "Step $($step.Index) of $total"
            $step.ScriptPath
        )

        $result = Invoke-LiteStep -Step $step

        # Display formatted table output
        if ($result.Parsed) {
            Format-StepOutput -Parsed $result.Parsed -ScriptFile $step.ScriptPath
        }

        # Show result badge
        $badgeColor = switch ($result.Status) { 'DONE' { 'Green' } 'FAIL' { 'Red' } 'SKIP' { 'Yellow' } default { 'Gray' } }
        Write-Host ''
        Write-Host "  [$($result.Status)] $($step.DisplayName)" -NoNewline -ForegroundColor $badgeColor
        Write-Host " - $($result.Summary)" -ForegroundColor DarkGray

        $Results += [PSCustomObject]@{
            Index         = $step.Index
            DisplayName   = $step.DisplayName
            ScriptPath    = $step.ScriptPath
            Status        = $result.Status
            Summary       = $result.Summary
            ParsedData    = $result.Parsed
            Verdict       = $result.Verdict
            VerdictReason = $result.VerdictReason
        }

        $script:CompletedCount++
        Start-Sleep -Milliseconds 800
    }

    # ── Summary ──────────────────────────────────────────────────────────
    Clear-Host
    Show-Header
    Show-Summary -ResultSet $Results

    # Save JSON report
    $reportPath = Join-Path $LogDir "$ScriptName-Report.json"
    try {
        $reportData = [PSCustomObject]@{
            Timestamp    = (Get-Date -Format 'o')
            ScriptName   = $ScriptName
            ComputerName = $ComputerName
            SerialNumber = $SerialNumber
            CurrentUser  = $CurrentUser
            Steps        = @($Results | Select-Object Index, DisplayName, ScriptPath, Status, Summary)
            Summary      = [PSCustomObject]@{
                Total   = $Results.Count
                Done    = @($Results | Where-Object { $_.Status -eq 'DONE' }).Count
                Failed  = @($Results | Where-Object { $_.Status -eq 'FAIL' }).Count
                Skipped = @($Results | Where-Object { $_.Status -eq 'SKIP' }).Count
            }
        }
        $reportData | ConvertTo-Json -Depth 5 | Set-Content $reportPath -Encoding UTF8 -Force
        Write-Host "  JSON report: $reportPath" -ForegroundColor DarkGray
    }
    catch {
        Write-ErrorLog "Failed to save JSON report: $_"
    }

    # Generate HTML report
    $htmlPath = Export-HtmlReport -ResultSet $Results
}
catch {
    Write-ErrorLog "Fatal error in interactive run: $_"
    Write-Host "  FATAL: Unexpected error - check $ErrorLog" -ForegroundColor Red
}

Write-Host ''
Read-Host '  Press Enter to continue'

#endregion
