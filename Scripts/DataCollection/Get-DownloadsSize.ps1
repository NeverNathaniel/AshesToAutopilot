<#
.SYNOPSIS
    Reports the size of each active user's Downloads folder and optionally copies it.

.DESCRIPTION
    For each active user profile (skipping system, inactive 30+ days, ithlocal/itklocal):
    - Calculates the size of the Downloads folder.
    - Interactive mode: reports size and prompts once whether to copy to Documents\Downloads_Backup.
    - NonInteractive mode: reports size, auto-copies Downloads to Documents\Downloads_Backup
      (incremental — skips files already present with same size), and emits JSON.

.PARAMETER NonInteractive
    Suppress all prompts. Output structured JSON to stdout. Exit cleanly.

.EXAMPLE
    .\Get-DownloadsSize.ps1
    .\Get-DownloadsSize.ps1 -NonInteractive

.NOTES
    Source repos used:
    - LazyAdmin-master/Office365/OneDriveSizeReport.ps1 (folder size calculation patterns)
    - public-main/IntuneConfig/Powershell/backupprofile.ps1 (profile path enumeration)
    No direct Downloads-size script found; folder sizing via Get-ChildItem -Recurse is standard.

    Requires: Administrator
    Output:   C:\PreWipeOutput\Logs\Get-DownloadsSize.log
#>

[CmdletBinding()]
param(
    [switch]$NonInteractive
)

#region --- Init ---
$ScriptName = 'Get-DownloadsSize'
. (Join-Path $PSScriptRoot '..\Common\Initialize-Toolkit.ps1')
. (Join-Path $PSScriptRoot '..\Common\Get-ActiveUserProfile.ps1')
$LogFile = "$LogDir\$ScriptName.log"
if (-not (Test-AdminElevation)) { exit 1 }
#endregion

function Format-Bytes {
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { return "{0:N2} GB" -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return "{0:N2} MB" -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return "{0:N2} KB" -f ($Bytes / 1KB) }
    return "$Bytes B"
}

#region --- Profile Enumeration ---
$Profiles = @(Get-ActiveUserProfile)
Write-Log "Active profiles to check: $($Profiles.Count)"
#endregion

#region --- Size Calculation ---
$Results = @()

foreach ($Profile in $Profiles) {
    $ProfilePath  = $Profile.LocalPath
    $ProfileName  = Split-Path $ProfilePath -Leaf
    $DownloadsDir = Join-Path $ProfilePath 'Downloads'

    $ProfileResult = [PSCustomObject]@{
        Profile       = $ProfileName
        ProfilePath   = $ProfilePath
        DownloadsPath = $DownloadsDir
        SizeBytes     = 0
        SizeHuman     = '0 B'
        FileCount     = 0
        FolderExists  = $false
        CopyRequested = $false
        CopyDest      = $null
        CopySuccess   = $null
        CopiedFiles   = 0
        SkippedFiles  = 0
        CopySkippedReason = $null
        Error         = $null
    }

    try {
        if (Test-Path -LiteralPath $DownloadsDir) {
            $ProfileResult.FolderExists = $true
            Write-Log "Calculating size of $DownloadsDir ..."
            $items = Get-ChildItem -LiteralPath $DownloadsDir -Recurse -Force -ErrorAction SilentlyContinue
            $size  = ($items | Where-Object { -not $_.PSIsContainer } | Measure-Object -Property Length -Sum).Sum
            $ProfileResult.SizeBytes = [long]$(if ($null -ne $size) { $size } else { 0 })
            $ProfileResult.SizeHuman = Format-Bytes $ProfileResult.SizeBytes
            $ProfileResult.FileCount = ($items | Where-Object { -not $_.PSIsContainer }).Count
            Write-Log "$ProfileName Downloads: $($ProfileResult.SizeHuman) ($($ProfileResult.FileCount) files)"
        } else {
            Write-Log "No Downloads folder found for $ProfileName"
        }
    } catch {
        Write-ErrorLog "Error sizing Downloads for $ProfileName : $_"
        $ProfileResult.Error = $_.ToString()
    }

    $Results += $ProfileResult
}
#endregion

#region --- NonInteractive Auto-Copy ---
if ($NonInteractive) {
    foreach ($r in ($Results | Where-Object { $_.FolderExists -and $_.FileCount -gt 0 })) {
        $destPath = Join-Path $r.ProfilePath 'Documents\Downloads_Backup'
        $r.CopyRequested = $true
        $r.CopyDest      = $destPath

        # Cap the auto-copy: doubling a huge Downloads folder can fill the disk mid-prep.
        $maxAutoCopyBytes = 20GB
        if ($r.SizeBytes -gt $maxAutoCopyBytes) {
            $r.CopySuccess       = $false
            $r.CopySkippedReason = "Downloads is $($r.SizeHuman) (> 20 GB auto-copy cap) — back up manually before wipe"
            Write-Log $r.CopySkippedReason 'WARN'
            continue
        }

        try {
            $srcFiles = Get-ChildItem -LiteralPath $r.DownloadsPath -Recurse -Force -ErrorAction SilentlyContinue |
                Where-Object { -not $_.PSIsContainer }

            if ($srcFiles.Count -eq 0) {
                $r.CopySuccess = $true
                $r.CopiedFiles = 0
                Write-Log "No files to copy for $($r.Profile)"
                continue
            }

            if (-not (Test-Path -LiteralPath $destPath)) {
                New-Item -Path $destPath -ItemType Directory -Force | Out-Null
            }

            $copiedCount = 0
            $skippedCount = 0
            foreach ($srcFile in $srcFiles) {
                $relativePath = $srcFile.FullName.Substring($r.DownloadsPath.Length)
                $destFile     = Join-Path $destPath $relativePath
                $destDir      = Split-Path $destFile -Parent

                if (-not (Test-Path -LiteralPath $destDir)) {
                    New-Item -Path $destDir -ItemType Directory -Force | Out-Null
                }

                # Incremental: skip if dest file exists with same size
                if (Test-Path -LiteralPath $destFile) {
                    $existingSize = (Get-Item -LiteralPath $destFile -Force).Length
                    if ($existingSize -eq $srcFile.Length) {
                        $skippedCount++
                        continue
                    }
                }

                Copy-Item -LiteralPath $srcFile.FullName -Destination $destFile -Force -ErrorAction Stop
                $copiedCount++
            }

            $r.CopySuccess  = $true
            $r.CopiedFiles  = $copiedCount
            $r.SkippedFiles = $skippedCount
            Write-Log "Auto-copy for $($r.Profile): $copiedCount copied, $skippedCount unchanged"
        } catch {
            Write-ErrorLog "Auto-copy failed for $($r.Profile): $_"
            $r.CopySuccess = $false
            $r.CopiedFiles = 0
        }
    }

    # Mark profiles with empty/missing Downloads as success (nothing to copy)
    foreach ($r in ($Results | Where-Object { -not $_.FolderExists -or $_.FileCount -eq 0 })) {
        if ($null -eq $r.CopySuccess) {
            $r.CopySuccess = $true
            $r.CopiedFiles = 0
        }
    }
}
#endregion

#region --- Interactive Copy Prompt ---
if (-not $NonInteractive) {
    Write-Host ""
    Write-Host "=== Downloads Folder Summary ===" -ForegroundColor Cyan
    foreach ($r in $Results) {
        if ($r.FolderExists) {
            Write-Host "  $($r.Profile): $($r.SizeHuman) ($($r.FileCount) files) at $($r.DownloadsPath)"
        } else {
            Write-Host "  $($r.Profile): No Downloads folder found"
        }
    }
    Write-Host ""

    $copyChoice = Read-Host "Copy any Downloads folder to Documents\Downloads_Backup? [Y/N]"
    if ($copyChoice -match '^[Yy]') {
        foreach ($r in ($Results | Where-Object { $_.FolderExists })) {
            $destPath = Join-Path $r.ProfilePath 'Documents\Downloads_Backup'
            Write-Log "Copying $($r.DownloadsPath) -> $destPath ..."
            try {
                if (-not (Test-Path $destPath)) {
                    New-Item -Path $destPath -ItemType Directory -Force | Out-Null
                }
                Copy-Item -Path "$($r.DownloadsPath)\*" -Destination $destPath -Recurse -Force -ErrorAction Stop
                $r.CopyRequested = $true
                $r.CopyDest      = $destPath
                $r.CopySuccess   = $true
                Write-Log "Copy complete for $($r.Profile)"
            } catch {
                Write-ErrorLog "Copy failed for $($r.Profile): $_"
                $r.CopyRequested = $true
                $r.CopyDest      = $destPath
                $r.CopySuccess   = $false
            }
        }
    }
}
#endregion

#region --- Output ---
$Summary = [PSCustomObject]@{
    Timestamp = (Get-Date -Format 'o')
    Results   = $Results
}

$Summary | ConvertTo-Json -Depth 5 | Out-File "$OutputRoot\Logs\DownloadsSize.json" -Force

if ($NonInteractive) {
    $Summary | ConvertTo-Json -Depth 5
} else {
    Write-Host ""
    Write-Host "Report saved: $OutputRoot\Logs\DownloadsSize.json"
    Write-Host ""
}
#endregion

exit 0
