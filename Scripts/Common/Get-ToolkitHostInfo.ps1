<#
.SYNOPSIS
    Emits host/device info as JSON for the desktop (Electron) host.

.DESCRIPTION
    Run once at app startup by the Electron main process. Reports computer
    name, BIOS serial, current user, elevation status, and the primary user
    profile (same selection logic as Start-PreWipeToolkit.ps1, used by
    Get-StepVerdict for OneDrive KFM/sync verdicts).

    Output is a single JSON object wrapped in sentinel lines so the host can
    extract it regardless of any console noise.
#>

[CmdletBinding()]
param()

# The Electron host reads our stdout as UTF-8; force it so non-ASCII serials
# or profile names don't corrupt the JSON envelope.
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false } catch {}
$OutputEncoding = New-Object System.Text.UTF8Encoding $false

$ErrorActionPreference = 'SilentlyContinue'

$computerName = $env:COMPUTERNAME
$currentUser  = $env:USERNAME

$serialNumber = 'Unknown'
$bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction SilentlyContinue
if ($bios -and $bios.SerialNumber) { $serialNumber = $bios.SerialNumber.Trim() }

$isElevated = $false
try {
    $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    $isElevated = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
} catch { $isElevated = $false }

# Primary profile selection — mirrors the Verdict Evaluation region of
# Start-PreWipeToolkit.ps1.
$primaryProfile = $null
try {
    $skipSIDs  = @('S-1-5-18', 'S-1-5-19', 'S-1-5-20')
    $skipNames = @('ithlocal', 'itklocal', 'wsi', 'wsiaccount', 'defaultuser0', 'administrator', 'guest')
    $cutoff    = (Get-Date).AddDays(-30)
    $profileObj = Get-CimInstance -ClassName Win32_UserProfile -ErrorAction Stop |
        Where-Object { -not $_.Special -and $skipSIDs -notcontains $_.SID } |
        Where-Object { $skipNames -notcontains (Split-Path $_.LocalPath -Leaf).ToLower() } |
        Where-Object { $_.LastUseTime -and $_.LastUseTime -ge $cutoff } |
        Sort-Object LastUseTime -Descending | Select-Object -First 1
    if ($profileObj) { $primaryProfile = Split-Path $profileObj.LocalPath -Leaf }
} catch { $primaryProfile = $null }

$info = [PSCustomObject]@{
    ComputerName   = $computerName
    SerialNumber   = $serialNumber
    CurrentUser    = $currentUser
    IsElevated     = $isElevated
    PrimaryProfile = $primaryProfile
}

Write-Output '===ATA_RESULT_BEGIN==='
$info | ConvertTo-Json -Compress
Write-Output '===ATA_RESULT_END==='
exit 0
