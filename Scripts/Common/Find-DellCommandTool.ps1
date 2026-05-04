<#
.SYNOPSIS
    Locates Dell Command Update (dcu-cli.exe) and Dell Command Configure (cctk.exe).
.DESCRIPTION
    Centralizes the Dell tool path detection duplicated across multiple
    ConfigurationChecks and ConfigurationChanges scripts.
.NOTES
    Returns the first existing path found, or $null if none of the candidates exist.
#>

function Find-DellCommandUpdate {
    [CmdletBinding()]
    param()

    $candidates = @(
        "$env:ProgramFiles\Dell\CommandUpdate\dcu-cli.exe"
        "${env:ProgramFiles(x86)}\Dell\CommandUpdate\dcu-cli.exe"
        "$env:ProgramData\Dell\CommandUpdate\dcu-cli.exe"
    )

    foreach ($path in $candidates) {
        if ($path -and (Test-Path -LiteralPath $path)) {
            return $path
        }
    }
    return $null
}

function Find-DellCommandConfigure {
    [CmdletBinding()]
    param()

    $candidates = @(
        "$env:ProgramFiles\Dell\Command Configure\X86_64\cctk.exe"
        "$env:ProgramFiles\Dell\Command Configure\cctk.exe"
        "${env:ProgramFiles(x86)}\Dell\Command Configure\X86_64\cctk.exe"
        "${env:ProgramFiles(x86)}\Dell\Command Configure\cctk.exe"
    )

    foreach ($path in $candidates) {
        if ($path -and (Test-Path -LiteralPath $path)) {
            return $path
        }
    }
    return $null
}
