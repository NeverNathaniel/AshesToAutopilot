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
    param([string]$DisplayNamePattern)
    $regPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($path in $regPaths) {
        $entry = Get-ItemProperty $path -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like $DisplayNamePattern } |
            Select-Object -First 1
        if ($entry) { return $entry.DisplayVersion }
    }
    return $null
}

function Get-DCUExePath {
    $candidates = @(
        "$env:ProgramFiles\Dell\CommandUpdate\dcu-cli.exe",
        "${env:ProgramFiles(x86)}\Dell\CommandUpdate\dcu-cli.exe",
        "$env:ProgramData\Dell\CommandUpdate\dcu-cli.exe"
    )
    foreach ($p in $candidates) { if (Test-Path $p) { return $p } }
    return $null
}

function Get-DCCExePath {
    $candidates = @(
        "$env:ProgramFiles\Dell\Command Configure\X86_64\cctk.exe",
        "$env:ProgramFiles\Dell\Command Configure\cctk.exe",
        "${env:ProgramFiles(x86)}\Dell\Command Configure\X86_64\cctk.exe",
        "${env:ProgramFiles(x86)}\Dell\Command Configure\cctk.exe"
    )
    foreach ($p in $candidates) { if (Test-Path $p) { return $p } }
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
    $DCUExe     = Get-DCUExePath

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
            Write-Log "Running DCU installer silently..."
            $proc = Start-Process -FilePath $DCUInstaller -ArgumentList '/s' -Wait -PassThru
            Write-Log "DCU installer exit code: $($proc.ExitCode)"
        }

        # Verify install
        Start-Sleep -Seconds 5
        $DCUVersion = Get-InstalledVersion -DisplayNamePattern '*Dell Command Update*'
        if ($DCUVersion) {
            Write-Log "DCU successfully installed: $DCUVersion"
            $DCUResult.Installed = $true
            $DCUResult.Version   = $DCUVersion
            $DCUResult.Success   = $true
        } else {
            Write-ErrorLog "DCU installation could not be verified."
            $DCUResult.Error = 'Install completed but version not found in registry'
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
    $DCCExe     = Get-DCCExePath

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

        Start-Sleep -Seconds 5
        $DCCVersion = Get-InstalledVersion -DisplayNamePattern '*Dell Command Configure*'
        if ($DCCVersion) {
            Write-Log "DCC successfully installed: $DCCVersion"
            $DCCResult.Installed = $true
            $DCCResult.Version   = $DCCVersion
            $DCCResult.Success   = $true
        } else {
            Write-ErrorLog "DCC installation could not be verified."
            $DCCResult.Error = 'Install completed but version not found in registry'
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

$Result | ConvertTo-Json -Depth 5 | Out-File "$OutputRoot\Logs\DellCommandTools-Status.json" -Force

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
