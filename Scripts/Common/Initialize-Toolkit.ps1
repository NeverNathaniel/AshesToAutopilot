<#
.SYNOPSIS
    Shared initialization for AshesToAutopilot scripts.
.DESCRIPTION
    Dot-source this file near the top of every toolkit script. It defines the
    standard output paths, ensures they exist, sets a strict ErrorActionPreference,
    and exposes Write-Log, Write-ErrorLog, and Test-AdminElevation helpers.
.NOTES
    The calling script must define $ScriptName before dot-sourcing, and define
    $LogFile = "$LogDir\$ScriptName.log" after dot-sourcing.
#>

$OutputRoot = 'C:\PreWipeOutput'
$LogDir     = "$OutputRoot\Logs"
$ErrorLog   = "$OutputRoot\errors.log"

foreach ($d in @($OutputRoot, $LogDir)) {
    if (-not (Test-Path -LiteralPath $d)) {
        New-Item -ItemType Directory -Path $d -Force | Out-Null
    }
}

$ErrorActionPreference = 'Stop'

function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,
        [string]$Level = 'INFO'
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$timestamp] [$Level] $Message"

    if ($LogFile) {
        $line | Out-File -FilePath $LogFile -Append -Encoding UTF8
    }

    if (-not $NonInteractive) {
        switch ($Level) {
            'ERROR' { Write-Host $line -ForegroundColor Red }
            'WARN'  { Write-Host $line -ForegroundColor Yellow }
            default { Write-Host $line }
        }
    }
}

function Write-ErrorLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $name = if ($ScriptName) { $ScriptName } else { '<unknown>' }
    "[$timestamp] [ERROR] [$name] $Message" | Out-File -FilePath $ErrorLog -Append -Encoding UTF8

    Write-Log $Message 'ERROR'
}

function Test-AdminElevation {
    [CmdletBinding()]
    param()

    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        return $true
    }

    Write-Host 'ERROR: This script must be run as Administrator (elevated PowerShell).' -ForegroundColor Red
    return $false
}
