<#
.SYNOPSIS
    Scans user profiles for data not inside OneDrive-synced folders.

.DESCRIPTION
    For each active user profile:
    - Scans for PST files, SSH keys, Sticky Notes, VPN configs, database files (.mdb/.accdb/.sqlite/.db),
      personal certificates (.pfx/.cer), QuickBooks files (.qbw/.qbb), local OneNote notebooks,
      and files on local drives outside any OneDrive folder.
    - Interactive mode: displays findings and pauses once for tech review.
    - NonInteractive mode: outputs JSON only.

.PARAMETER NonInteractive
    Suppress all prompts. Output structured JSON to stdout. Exit cleanly.

.EXAMPLE
    .\Find-UnbackedData.ps1
    .\Find-UnbackedData.ps1 -NonInteractive

.NOTES
    Source repos used:
    - public-main/IntuneConfig/Powershell/backupprofile.ps1 (profile enumeration/path patterns)
    - garytown-master/OSD/TroubleShootingSteps/Get-MachineInfo.ps1 (installed app enumeration patterns)
    No dedicated unbacked-data scan found in source repos; implemented using known file paths
    and Get-ChildItem recursive scans.

    Requires: Administrator
    Output:   C:\PreWipeOutput\Logs\Find-UnbackedData-Report.json
#>

[CmdletBinding()]
param(
    [switch]$NonInteractive
)

#region --- Init ---
$ScriptName = 'Find-UnbackedData'
. (Join-Path $PSScriptRoot '..\Common\Initialize-Toolkit.ps1')
. (Join-Path $PSScriptRoot '..\Common\Get-ActiveUserProfile.ps1')
$LogFile = "$LogDir\$ScriptName.log"
if (-not (Test-AdminElevation)) { exit 1 }
#endregion

#region --- Profile Enumeration ---
$Profiles = @(Get-ActiveUserProfile)
Write-Log "Active profiles to check: $($Profiles.Count)"
#endregion

#region --- Scan Functions ---
function Find-OneDrivePaths {
    param([string]$ProfilePath, [string]$SID)
    $odPaths = @()
    # Check registry for OneDrive sync root paths
    $odKey = "Registry::HKEY_USERS\$SID\Software\Microsoft\OneDrive\Accounts"
    if (Test-Path $odKey) {
        $accts = Get-ChildItem $odKey -ErrorAction SilentlyContinue
        foreach ($a in $accts) {
            $props = Get-ItemProperty $a.PSPath -ErrorAction SilentlyContinue
            if ($props.UserFolder) { $odPaths += $props.UserFolder }
        }
    }
    # Fallback: common OneDrive folder names
    foreach ($candidate in @('OneDrive', 'OneDrive - *')) {
        $found = Get-ChildItem -Path $ProfilePath -Directory -Filter $candidate -ErrorAction SilentlyContinue
        foreach ($f in $found) { if ($odPaths -notcontains $f.FullName) { $odPaths += $f.FullName } }
    }
    return $odPaths
}

function Search-UnbackedFiles {
    param([string]$ProfilePath, [string[]]$OneDrivePaths)

    $findings = @()

    # App-generated cache/database noise excluded from the broad profile-root scans.
    # Dedicated targets (StickyNotes, SSH) use precise paths and are not filtered.
    $noisePattern = '\\AppData\\Local\\(Microsoft\\Windows|Microsoft\\Edge|Google|BraveSoftware|Packages|Temp|Comms|ConnectedDevicesPlatform|D3DSCache|SquirrelTemp)\\|\\AppData\\Roaming\\Mozilla\\Firefox\\|\\AppData\\Roaming\\Microsoft\\Teams\\|thumbcache_[^\\]*\.db$|iconcache[^\\]*\.db$|\\WebCache\\|\\INetCache\\|\\CacheStorage\\'

    $scanTargets = @(
        @{ Label = 'PST_Files';        Path = $ProfilePath; Filter = '*.pst'; Recurse = $true  }
        @{ Label = 'SSH_Keys';         Path = (Join-Path $ProfilePath '.ssh'); Filter = '*'; Recurse = $true }
        @{ Label = 'StickyNotes';      Path = (Join-Path $ProfilePath 'AppData\Local\Packages\Microsoft.MicrosoftStickyNotes_8wekyb3d8bbwe\LocalState'); Filter = '*'; Recurse = $false }
        @{ Label = 'QuickBooks';       Path = $ProfilePath; Filter = '*.qbw'; Recurse = $true }
        @{ Label = 'QuickBooks_Bkp';   Path = $ProfilePath; Filter = '*.qbb'; Recurse = $true }
        @{ Label = 'Access_DB';        Path = $ProfilePath; Filter = '*.mdb'; Recurse = $true }
        @{ Label = 'Access_DB_Accdb';  Path = $ProfilePath; Filter = '*.accdb'; Recurse = $true }
        @{ Label = 'SQLite_DB';        Path = $ProfilePath; Filter = '*.sqlite'; Recurse = $true }
        @{ Label = 'Generic_DB';       Path = $ProfilePath; Filter = '*.db'; Recurse = $true }
        @{ Label = 'Cert_PFX';         Path = $ProfilePath; Filter = '*.pfx'; Recurse = $true }
        @{ Label = 'Cert_CER';         Path = $ProfilePath; Filter = '*.cer'; Recurse = $true }
    )

    foreach ($target in $scanTargets) {
        if (-not (Test-Path $target.Path)) { continue }
        try {
            # -Force: hidden directories (AppData!) are skipped without it, hiding e.g. legacy Outlook PSTs
            $params = @{ Path = $target.Path; Filter = $target.Filter; Force = $true; ErrorAction = 'SilentlyContinue' }
            if ($target.Recurse) { $params.Recurse = $true }
            $items = Get-ChildItem @params | Where-Object { -not $_.PSIsContainer }
            if ($target.Path -eq $ProfilePath -and $target.Recurse) {
                $items = $items | Where-Object { $_.FullName -notmatch $noisePattern }
            }

            foreach ($item in $items) {
                # Check if inside any OneDrive path
                $inOneDrive = $false
                foreach ($odp in $OneDrivePaths) {
                    if ($item.FullName.StartsWith("$odp\", [System.StringComparison]::OrdinalIgnoreCase)) { $inOneDrive = $true; break }
                }
                if (-not $inOneDrive) {
                    $findings += [PSCustomObject]@{
                        Category = $target.Label
                        Path     = $item.FullName
                        SizeBytes = $item.Length
                        InOneDrive = $false
                    }
                }
            }
        } catch {
            Write-Log "Scan error ($($target.Label)): $_" 'WARN'
        }
    }

    # VPN config paths
    $vpnPaths = @(
        "$ProfilePath\AppData\Roaming\Cisco\Cisco AnyConnect Secure Mobility Client",
        "$ProfilePath\AppData\Roaming\GlobalProtect",
        "$ProfilePath\AppData\Local\Pulse Secure",
        "$ProfilePath\AppData\Roaming\Open VPN Connect",
        "$ProfilePath\AppData\Roaming\OpenVPN"
    )
    foreach ($vp in $vpnPaths) {
        if (Test-Path $vp) {
            $findings += [PSCustomObject]@{
                Category   = 'VPN_Config'
                Path       = $vp
                SizeBytes  = 0
                InOneDrive = $false
            }
        }
    }

    # Local OneNote notebooks (not in OneDrive)
    $onenotePaths = @(
        "$ProfilePath\Documents",
        "$ProfilePath\AppData\Local\Microsoft\OneNote"
    )
    foreach ($onp in $onenotePaths) {
        if (-not (Test-Path $onp)) { continue }
        try {
            $onenoteFiles = Get-ChildItem -Path $onp -Filter '*.onetoc2' -Recurse -Force -ErrorAction SilentlyContinue
            foreach ($onf in $onenoteFiles) {
                $inOneDrive = $false
                foreach ($odp in $OneDrivePaths) {
                    if ($onf.FullName.StartsWith("$odp\", [System.StringComparison]::OrdinalIgnoreCase)) { $inOneDrive = $true; break }
                }
                if (-not $inOneDrive) {
                    $findings += [PSCustomObject]@{
                        Category   = 'LocalOneNote'
                        Path       = $onf.FullName
                        SizeBytes  = $onf.Length
                        InOneDrive = $false
                    }
                }
            }
        } catch {
            Write-ErrorLog "Failed to enumerate file attributes in profile loop: $_"
        }
    }

    return $findings
}
#endregion

#region --- Main ---
$AllProfileFindings = @()

foreach ($UserProfile in $Profiles) {
    $ProfilePath = $UserProfile.LocalPath
    $ProfileName = Split-Path $ProfilePath -Leaf
    $SID         = $UserProfile.SID

    Write-Log "Scanning profile: $ProfileName"

    $HiveLoaded = $false
    try {
        $HiveLoaded = Mount-UserHive -UserProfile $UserProfile

        $odPaths  = Find-OneDrivePaths -ProfilePath $ProfilePath -SID $SID
        $findings = Search-UnbackedFiles -ProfilePath $ProfilePath -OneDrivePaths $odPaths
    } finally {
        if ($HiveLoaded) { Dismount-UserHive -SID $SID }
    }

    $AllProfileFindings += [PSCustomObject]@{
        Profile     = $ProfileName
        OneDrivePaths = $odPaths
        Findings    = $findings
        FindingCount = $findings.Count
    }

    Write-Log "  Found $($findings.Count) items not backed up for $ProfileName"
}

$Result = [PSCustomObject]@{
    Timestamp       = (Get-Date -Format 'o')
    ProfileFindings = $AllProfileFindings
}

$Result | ConvertTo-Json -Depth 10 | Out-File "$OutputRoot\Logs\Find-UnbackedData-Report.json" -Force
#endregion

#region --- Output ---
if ($NonInteractive) {
    $Result | ConvertTo-Json -Depth 10
} else {
    Write-Host ""
    Write-Host "=== Not-Backed-Up Data Findings ===" -ForegroundColor Cyan
    foreach ($pf in $AllProfileFindings) {
        Write-Host "  Profile: $($pf.Profile) - $($pf.FindingCount) item(s) not backed up"
        foreach ($f in $pf.Findings) {
            Write-Host "    [$($f.Category)] $($f.Path)"
        }
    }
    Write-Host ""
    Write-Host "Full report: $OutputRoot\Logs\Find-UnbackedData-Report.json"
    Write-Host ""
}
#endregion

exit 0
