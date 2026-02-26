<#
.SYNOPSIS
    Scans user profiles for data not inside OneDrive-synced folders and flags non-standard apps.

.DESCRIPTION
    For each active user profile:
    - Scans for PST files, SSH keys, Sticky Notes, VPN configs, database files (.mdb/.accdb/.sqlite/.db),
      personal certificates (.pfx/.cer), QuickBooks files (.qbw/.qbb), local OneNote notebooks,
      and files on local drives outside any OneDrive folder.
    - Lists non-standard installed applications (ignoring Office, .NET, Visual C++, browsers,
      Windows built-ins, Dell tools, SentinelOne, Adobe Reader).
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
$OutputRoot = 'C:\PreWipeOutput'
$LogDir     = "$OutputRoot\Logs"
$LogFile    = "$LogDir\$ScriptName.log"
$ErrorLog   = "$OutputRoot\errors.log"

if (-not (Test-Path $OutputRoot)) { New-Item -Path $OutputRoot -ItemType Directory -Force | Out-Null }
if (-not (Test-Path $LogDir))     { New-Item -Path $LogDir     -ItemType Directory -Force | Out-Null }

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    "$ts [$Level] $Message" | Out-File -FilePath $LogFile -Append
    if (-not $NonInteractive) { Write-Host "$ts [$Level] $Message" }
}

function Write-ErrorLog {
    param([string]$Message)
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    "$ts [ERROR] [$ScriptName] $Message" | Out-File -FilePath $ErrorLog -Append
    Write-Log $Message 'ERROR'
}

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "ERROR: This script must be run as Administrator." -ForegroundColor Red
    exit 1
}
#endregion

#region --- Profile Enumeration ---
$SkipSIDs   = @('S-1-5-18', 'S-1-5-19', 'S-1-5-20')
$CutoffDate = (Get-Date).AddDays(-30)
$SkipNames  = @('ithlocal', 'itklocal')

$Profiles = @()
try {
    $AllProfiles = Get-CimInstance -ClassName Win32_UserProfile -ErrorAction Stop |
        Where-Object { -not $_.Special }
    foreach ($p in $AllProfiles) {
        $sid = $p.SID
        if ($SkipSIDs -contains $sid -or $sid -match '^S-1-5-(18|19|20)$') { continue }
        $folderName = Split-Path $p.LocalPath -Leaf
        if ($SkipNames -contains $folderName.ToLower()) { Write-Log "Skipping service account: $folderName"; continue }
        $lastUse = $p.LastUseTime
        if ($null -eq $lastUse -or $lastUse -lt $CutoffDate) { Write-Log "Skipping inactive: $folderName"; continue }
        $Profiles += $p
    }
} catch {
    Write-ErrorLog "Profile enumeration failed: $_"; exit 1
}
#endregion

#region --- App Ignore List ---
$IgnoredApps = @(
    '*Microsoft Office*', '*Microsoft 365*', '*.NET*', '*Visual C++*',
    '*Visual Studio*', '*Windows*', '*Google Chrome*', '*Microsoft Edge*',
    '*Brave*', '*Mozilla Firefox*', '*Dell*', '*SentinelOne*', '*Adobe Reader*',
    '*Adobe Acrobat Reader*', '*Microsoft Visual C++*', '*Intel*Driver*',
    '*Realtek*', '*NVIDIA*Graphics*', '*Windows SDK*'
)

function Test-AppIgnored {
    param([string]$AppName)
    foreach ($pattern in $IgnoredApps) {
        if ($AppName -like $pattern) { return $true }
    }
    return $false
}
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
            $params = @{ Path = $target.Path; Filter = $target.Filter; ErrorAction = 'SilentlyContinue' }
            if ($target.Recurse) { $params.Recurse = $true }
            $items = Get-ChildItem @params | Where-Object { -not $_.PSIsContainer }

            foreach ($item in $items) {
                # Check if inside any OneDrive path
                $inOneDrive = $false
                foreach ($odp in $OneDrivePaths) {
                    if ($item.FullName -like "$odp*") { $inOneDrive = $true; break }
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
            $onenoteFiles = Get-ChildItem -Path $onp -Filter '*.onetoc2' -Recurse -ErrorAction SilentlyContinue
            foreach ($onf in $onenoteFiles) {
                $inOneDrive = $false
                foreach ($odp in $OneDrivePaths) {
                    if ($onf.FullName -like "$odp*") { $inOneDrive = $true; break }
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
        } catch {}
    }

    return $findings
}
#endregion

#region --- Non-Standard Apps ---
function Get-NonStandardApps {
    $regPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $apps = @()
    foreach ($path in $regPaths) {
        $entries = Get-ItemProperty $path -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -and -not (Test-AppIgnored $_.DisplayName) }
        foreach ($e in $entries) {
            $apps += [PSCustomObject]@{
                Name      = $e.DisplayName
                Version   = $e.DisplayVersion
                Publisher = $e.Publisher
            }
        }
    }
    return $apps | Sort-Object Name -Unique
}
#endregion

#region --- Main ---
$AllProfileFindings = @()

foreach ($Profile in $Profiles) {
    $ProfilePath = $Profile.LocalPath
    $ProfileName = Split-Path $ProfilePath -Leaf
    $SID         = $Profile.SID

    Write-Log "Scanning profile: $ProfileName"

    # Load hive if needed
    $HiveLoaded = $false
    if (-not (Test-Path "Registry::HKEY_USERS\$SID")) {
        $NtuserDat = Join-Path $ProfilePath 'NTUSER.DAT'
        if (Test-Path $NtuserDat) {
            $null = reg load "HKU\$SID" $NtuserDat 2>&1
            $HiveLoaded = $true
            Start-Sleep -Milliseconds 500
        }
    }

    $odPaths  = Find-OneDrivePaths -ProfilePath $ProfilePath -SID $SID
    $findings = Search-UnbackedFiles -ProfilePath $ProfilePath -OneDrivePaths $odPaths

    if ($HiveLoaded) {
        [GC]::Collect(); Start-Sleep -Milliseconds 200
        $null = reg unload "HKU\$SID" 2>&1
    }

    $AllProfileFindings += [PSCustomObject]@{
        Profile     = $ProfileName
        OneDrivePaths = $odPaths
        Findings    = $findings
        FindingCount = $findings.Count
    }

    Write-Log "  Found $($findings.Count) potentially unbacked items for $ProfileName"
}

$NonStandardApps = @()
try {
    $NonStandardApps = Get-NonStandardApps
    Write-Log "Non-standard apps found: $($NonStandardApps.Count)"
} catch {
    Write-ErrorLog "App scan failed: $_"
}

$Result = [PSCustomObject]@{
    Timestamp       = (Get-Date -Format 'o')
    ProfileFindings = $AllProfileFindings
    NonStandardApps = $NonStandardApps
}

$Result | ConvertTo-Json -Depth 10 | Out-File "$OutputRoot\Logs\Find-UnbackedData-Report.json" -Force
#endregion

#region --- Output ---
if ($NonInteractive) {
    $Result | ConvertTo-Json -Depth 10
} else {
    Write-Host ""
    Write-Host "=== Unbacked Data Findings ===" -ForegroundColor Cyan
    foreach ($pf in $AllProfileFindings) {
        Write-Host "  Profile: $($pf.Profile) - $($pf.FindingCount) item(s)"
        foreach ($f in $pf.Findings) {
            Write-Host "    [$($f.Category)] $($f.Path)"
        }
    }
    Write-Host ""
    Write-Host "=== Non-Standard Applications ($($NonStandardApps.Count)) ===" -ForegroundColor Yellow
    foreach ($app in $NonStandardApps) {
        Write-Host "  $($app.Name) v$($app.Version) ($($app.Publisher))"
    }
    Write-Host ""
    Write-Host "Full report: $OutputRoot\Logs\Find-UnbackedData-Report.json"
    Write-Host ""
    Read-Host "Press Enter once you have reviewed the findings"
}
#endregion
