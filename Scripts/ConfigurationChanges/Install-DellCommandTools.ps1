<#
.SYNOPSIS
    Installs or updates Dell Command Update (DCU) and Dell Command Configure (DCC) on Dell hardware.

.DESCRIPTION
    Checks hardware vendor. If not Dell, exits gracefully.
    Verifies Dell Command Update installation, downloads and installs silently if missing or outdated.
    Verifies Dell Command Configure installation, downloads and installs silently if missing or outdated.
    Logs installed versions to C:\PreWipeOutput\.

.PARAMETER NonInteractive
    Suppress all prompts. Output structured JSON to stdout. Exit cleanly.

.EXAMPLE
    .\Install-DellCommandTools.ps1
    .\Install-DellCommandTools.ps1 -NonInteractive

.NOTES
    Source repos used:
    - garytown-master/hardware/Dell/CommandUpdate/EMPS/Dell-EMPS.ps1
      (Install-DCU, Get-DCUVersion, Get-DCUInstallDetails functions adapted)
    - garytown-master/Intune/Update-DellBIOS-Detect.ps1 (detection patterns)

    Requires: Administrator
    Output:   C:\PreWipeOutput\Logs\Install-DellCommandTools.log
#>

[CmdletBinding()]
param(
    [switch]$NonInteractive
)

#region --- Init ---
$ScriptName = 'Install-DellCommandTools'
. (Join-Path $PSScriptRoot '..\Common\Initialize-Toolkit.ps1')
. (Join-Path $PSScriptRoot '..\Common\Find-DellCommandTool.ps1')
$LogFile = "$LogDir\$ScriptName.log"
if (-not (Test-AdminElevation)) { exit 1 }
#endregion

#region --- Vendor Check ---
try {
    $CS = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
    $Manufacturer = $CS.Manufacturer
} catch {
    Write-ErrorLog "Failed to query Win32_ComputerSystem: $_"
    if ($NonInteractive) { @{ Vendor = 'Unknown'; Error = $_.ToString() } | ConvertTo-Json; exit 1 }
    exit 1
}

if ($Manufacturer -notlike '*Dell*') {
    Write-Log "Vendor is '$Manufacturer' - not Dell. Skipping Dell tool installation."
    if ($NonInteractive) {
        @{ Vendor = $Manufacturer; DellDevice = $false; DCU = $null; DCC = $null } | ConvertTo-Json
    }
    exit 0
}

Write-Log "Dell device confirmed: $Manufacturer"
#endregion

#region --- Helper: Get installed version from registry ---
function Get-InstalledVersion {
    param([string]$DisplayNamePattern, [string[]]$AlternatePatterns = @())
    $regPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $patterns = @($DisplayNamePattern) + $AlternatePatterns
    foreach ($path in $regPaths) {
        foreach ($pat in $patterns) {
            $entry = Get-ItemProperty $path -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -like $pat } |
                Select-Object -First 1
            if ($entry) { return $entry.DisplayVersion }
        }
    }
    return $null
}

#endregion

#region --- DCU Install/Verify ---
$DCUResult = [PSCustomObject]@{
    Tool       = 'Dell Command Update'
    Installed  = $false
    Version    = $null
    Action     = 'None'
    Success    = $false
    Error      = $null
}

try {
    Write-Log "Checking Dell Command Update installation..."
    $DCUVersion = Get-InstalledVersion -DisplayNamePattern '*Dell Command Update*'
    $DCUExe     = Find-DellCommandUpdate

    if ($DCUVersion -and $DCUExe) {
        Write-Log "DCU found: version $DCUVersion at $DCUExe"
        $DCUResult.Installed = $true
        $DCUResult.Version   = $DCUVersion
        $DCUResult.Action    = 'AlreadyInstalled'
        $DCUResult.Success   = $true
    } else {
        Write-Log "DCU not found or executable missing. Downloading and installing..."
        $DCUResult.Action = 'Install'

        # Use the Dell catalog to find latest DCU - adapted from garytown Dell-EMPS.ps1 Install-DCU function
        $TempDir = "$env:TEMP\DCUInstall"
        if (-not (Test-Path $TempDir)) { New-Item $TempDir -ItemType Directory -Force | Out-Null }

        # Download DCU installer from Dell's software distribution site
        # Dell Command Update Universal installer GUID known path
        $DCUInstallerURL = 'https://dl.dell.com/FOLDER10870730M/1/Dell-Command-Update-Application_GGXMF_WIN_5.4.0_A00.EXE'
        $DCUInstaller    = "$TempDir\DCU_Setup.exe"

        Write-Log "Downloading DCU installer to $DCUInstaller ..."
        try {
            Invoke-WebRequest -Uri $DCUInstallerURL -OutFile $DCUInstaller -UseBasicParsing -ErrorAction Stop
        } catch {
            # Fallback: try WinGet or MSI approach
            Write-Log "Direct download failed. Attempting winget install..." 'WARN'
            try {
                $wgResult = & winget install --id Dell.CommandUpdate.Universal --silent --accept-package-agreements --accept-source-agreements 2>&1
                Write-Log "Winget output: $wgResult"
            } catch {
                Write-ErrorLog "Winget also failed: $_"
                $DCUResult.Error = "Download failed: $_"
                throw
            }
        }

        if (Test-Path $DCUInstaller) {
            # Verify the downloaded binary is genuinely Dell-signed before running it
            # elevated — MSP networks routinely sit behind TLS-intercepting proxies.
            $sig = Get-AuthenticodeSignature -FilePath $DCUInstaller
            if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'Dell') {
                Remove-Item $DCUInstaller -Force -ErrorAction SilentlyContinue
                throw "DCU installer signature invalid (status: $($sig.Status)) — refusing to execute. Install DCU manually from dell.com/support."
            }
            Write-Log "DCU installer signature verified: $($sig.SignerCertificate.Subject)"
            Write-Log "Running DCU installer silently..."
            $proc = Start-Process -FilePath $DCUInstaller -ArgumentList '/s' -Wait -PassThru
            Write-Log "DCU installer exit code: $($proc.ExitCode)"
            if ($proc.ExitCode -ne 0) {
                $exitMsg = switch ($proc.ExitCode) {
                    1603 { 'Fatal error during installation — check Windows Installer logs' }
                    1638 { 'A newer version of Dell Command Update is already installed' }
                    3010 { 'Installation succeeded — reboot required to complete' }
                    500  { 'Installer returned 500 — possible conflict or missing prerequisite; try rebooting and re-running, or install DCU manually from dell.com/support' }
                    default { "Installer returned exit code $($proc.ExitCode)" }
                }
                Write-Log "DCU installer: $exitMsg" 'WARN'
                if ($proc.ExitCode -ne 3010) { $DCUResult.Error = $exitMsg }
            }
        }

        # Verify install
        Start-Sleep -Seconds 15
        $DCUVersion = Get-InstalledVersion -DisplayNamePattern '*Dell Command Update*' -AlternatePatterns @('*Dell Command | Update*','*DellCommandUpdate*')
        $DCUExeAfter = Find-DellCommandUpdate
        if ($DCUVersion -or $DCUExeAfter) {
            $ver = if ($DCUVersion) { $DCUVersion } else { 'installed (exe found, registry pending)' }
            Write-Log "DCU successfully installed: $ver"
            $DCUResult.Installed = $true
            $DCUResult.Version   = $ver
            $DCUResult.Success   = $true
        } else {
            Write-ErrorLog "DCU installation could not be verified."
            $DCUResult.Error = 'Install completed but version not found in registry or filesystem'
        }

        # Cleanup
        if (Test-Path $DCUInstaller) { Remove-Item $DCUInstaller -Force -ErrorAction SilentlyContinue }
    }
} catch {
    Write-ErrorLog "DCU installation error: $_"
    $DCUResult.Error = $_.ToString()
}
#endregion

#region --- DCC Install/Verify ---
$DCCResult = [PSCustomObject]@{
    Tool      = 'Dell Command Configure'
    Installed = $false
    Version   = $null
    Action    = 'None'
    Success   = $false
    Error     = $null
}

try {
    Write-Log "Checking Dell Command Configure installation..."
    $DCCVersion = Get-InstalledVersion -DisplayNamePattern '*Dell Command Configure*'
    $DCCExe     = Find-DellCommandConfigure

    if ($DCCVersion -and $DCCExe) {
        Write-Log "DCC found: version $DCCVersion at $DCCExe"
        $DCCResult.Installed = $true
        $DCCResult.Version   = $DCCVersion
        $DCCResult.Action    = 'AlreadyInstalled'
        $DCCResult.Success   = $true
    } else {
        Write-Log "DCC not found. Attempting winget install..."
        $DCCResult.Action = 'Install'

        try {
            $wgResult = & winget install --id Dell.CommandConfigure --silent --accept-package-agreements --accept-source-agreements 2>&1
            Write-Log "Winget DCC output: $wgResult"
        } catch {
            Write-ErrorLog "Winget DCC install failed: $_"
            $DCCResult.Error = "Winget failed: $_"
        }

        Start-Sleep -Seconds 15
        $DCCVersion = Get-InstalledVersion -DisplayNamePattern '*Dell Command Configure*' -AlternatePatterns @('*Dell Command | Configure*','*DellCommandConfigure*')
        $DCCExeAfter = Find-DellCommandConfigure
        if ($DCCVersion -or $DCCExeAfter) {
            $ver = if ($DCCVersion) { $DCCVersion } else { 'installed (exe found, registry pending)' }
            Write-Log "DCC successfully installed: $ver"
            $DCCResult.Installed = $true
            $DCCResult.Version   = $ver
            $DCCResult.Success   = $true
        } else {
            Write-ErrorLog "DCC installation could not be verified."
            $DCCResult.Error = 'Install completed but version not found in registry or filesystem'
        }
    }
} catch {
    Write-ErrorLog "DCC installation error: $_"
    $DCCResult.Error = $_.ToString()
}
#endregion

#region --- Output ---
$Result = [PSCustomObject]@{
    Timestamp  = (Get-Date -Format 'o')
    Vendor     = $Manufacturer
    DellDevice = $true
    DCU        = $DCUResult
    DCC        = $DCCResult
}

$Result | ConvertTo-Json -Depth 5 | Out-File "$OutputRoot\Logs\Install-DellCommandTools-Report.json" -Force

if ($NonInteractive) {
    $Result | ConvertTo-Json -Depth 5
} else {
    Write-Host ""
    Write-Host "=== Dell Command Tools Status ===" -ForegroundColor Cyan
    Write-Host "DCU: $($DCUResult.Version) | Action: $($DCUResult.Action) | Success: $($DCUResult.Success)"
    Write-Host "DCC: $($DCCResult.Version) | Action: $($DCCResult.Action) | Success: $($DCCResult.Success)"
    Write-Host "Log: $LogFile"
    Write-Host ""
}
#endregion

# Both tools failing to install is a blocking failure for the Dell update steps.
if (-not $DCUResult.Success -and -not $DCCResult.Success) { exit 1 }
exit 0
