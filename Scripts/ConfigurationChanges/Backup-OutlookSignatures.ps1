<#
.SYNOPSIS
    Backs up Outlook email signatures for all active user profiles.

.DESCRIPTION
    For each active user profile (skipping system, inactive 30+ days, ithlocal/itklocal):
    - Checks if Outlook signatures exist at AppData\Roaming\Microsoft\Signatures.
    - If present, copies the entire Signatures folder to C:\PreWipeOutput\Signatures\{UserProfile}\.

.PARAMETER NonInteractive
    Suppress all prompts. Output structured JSON to stdout. Exit cleanly.

.EXAMPLE
    .\Backup-OutlookSignatures.ps1
    .\Backup-OutlookSignatures.ps1 -NonInteractive

.NOTES
    Source repos used:
    - public-main/Powershell Scripts/Signature-Script/Outlook-Signature-Remediation/detect-signature.ps1
      (signature detection path and existence check pattern)
    - public-main/Powershell Scripts/Signature-Script/remediate-signature.ps1
      (AppData Signatures path references)

    Requires: Administrator
    Output:   C:\PreWipeOutput\Signatures\
#>

[CmdletBinding()]
param(
    [switch]$NonInteractive
)

#region --- Init ---
$ScriptName = 'Backup-OutlookSignatures'
. (Join-Path $PSScriptRoot '..\Common\Initialize-Toolkit.ps1')
. (Join-Path $PSScriptRoot '..\Common\Get-ActiveUserProfile.ps1')
$LogFile    = "$LogDir\$ScriptName.log"
if (-not (Test-AdminElevation)) { exit 1 }
$SigRoot    = "$OutputRoot\Signatures"
if (-not (Test-Path $SigRoot)) { New-Item -Path $SigRoot -ItemType Directory -Force | Out-Null }
#endregion

#region --- Profile Enumeration ---
$Profiles = @(Get-ActiveUserProfile)
Write-Log "Active profiles: $($Profiles.Count)"
#endregion

#region --- Backup Loop ---
$Results = @()

foreach ($Profile in $Profiles) {
    $ProfilePath  = $Profile.LocalPath
    $ProfileName  = Split-Path $ProfilePath -Leaf
    $SigSource    = Join-Path $ProfilePath 'AppData\Roaming\Microsoft\Signatures'

    $Result = [PSCustomObject]@{
        Profile       = $ProfileName
        SignaturesPath = $SigSource
        Found         = $false
        FileCount     = 0
        BackupDest    = $null
        Success       = $false
        Error         = $null
    }

    if (Test-Path $SigSource) {
        $sigFiles = Get-ChildItem -Path $SigSource -Recurse -Force -ErrorAction SilentlyContinue |
            Where-Object { -not $_.PSIsContainer }
        $Result.Found     = $true
        $Result.FileCount = $sigFiles.Count

        if ($sigFiles.Count -gt 0) {
            $dest = Join-Path $SigRoot $ProfileName
            try {
                if (-not (Test-Path $dest)) { New-Item -Path $dest -ItemType Directory -Force | Out-Null }
                Copy-Item -Path "$SigSource\*" -Destination $dest -Recurse -Force -ErrorAction Stop
                $Result.BackupDest = $dest
                $Result.Success    = $true
                Write-Log "Backed up $($sigFiles.Count) signature file(s) for $ProfileName -> $dest"
            } catch {
                Write-ErrorLog "Backup failed for $ProfileName : $_"
                $Result.Error = $_.ToString()
            }
        } else {
            Write-Log "Signatures folder exists but is empty for $ProfileName" 'WARN'
        }
    } else {
        Write-Log "No Signatures folder found for $ProfileName"
    }

    $Results += $Result
}
#endregion

#region --- Output ---
$Summary = [PSCustomObject]@{
    Timestamp = (Get-Date -Format 'o')
    Results   = $Results
}

$Summary | ConvertTo-Json -Depth 5 | Out-File "$OutputRoot\Logs\Backup-OutlookSignatures-Report.json" -Force

if ($NonInteractive) {
    $Summary | ConvertTo-Json -Depth 5
} else {
    Write-Host ""
    Write-Host "=== Outlook Signatures Backup ===" -ForegroundColor Cyan
    foreach ($r in $Results) {
        if ($r.Found -and $r.Success) {
            Write-Host "  $($r.Profile): $($r.FileCount) file(s) backed up -> $($r.BackupDest)" -ForegroundColor Green
        } elseif ($r.Found -and -not $r.Success) {
            Write-Host "  $($r.Profile): BACKUP FAILED - $($r.Error)" -ForegroundColor Red
        } else {
            Write-Host "  $($r.Profile): No signatures found"
        }
    }
    Write-Host ""
    Write-Host "Backups saved to: $SigRoot"
    Write-Host ""
}
#endregion

exit 0
