<#
.SYNOPSIS
    Returns active, non-system Windows user profiles and helpers for hive load/unload.
.DESCRIPTION
    Centralizes the user-profile filtering logic duplicated across multiple
    DataCollection and AutopilotReadiness scripts. Also provides Mount-UserHive
    and Dismount-UserHive helpers for offline NTUSER.DAT access.
.NOTES
    Requires Initialize-Toolkit.ps1 to be dot-sourced first (uses Write-Log).
#>

function Get-ActiveUserProfile {
    [CmdletBinding()]
    param(
        [int]$CutoffDays = 30
    )

    $excludedSids  = @('S-1-5-18', 'S-1-5-19', 'S-1-5-20')
    $excludedNames = @('ithlocal', 'itklocal', 'wsi', 'wsiaccount', 'defaultuser0', 'administrator', 'guest')
    $cutoff = (Get-Date).AddDays(-[math]::Abs($CutoffDays))

    $profiles = Get-CimInstance -ClassName Win32_UserProfile -ErrorAction Stop

    $result = foreach ($p in $profiles) {
        if ($p.Special -eq $true) {
            Write-Log "Skipping special profile: $($p.LocalPath)" 'INFO'
            continue
        }
        if ($excludedSids -contains $p.SID) {
            Write-Log "Skipping system SID: $($p.SID)" 'INFO'
            continue
        }
        if ($p.SID -match '^S-1-5-(18|19|20)$') {
            Write-Log "Skipping system SID (pattern): $($p.SID)" 'INFO'
            continue
        }

        $folderName = Split-Path -Path $p.LocalPath -Leaf
        if ($excludedNames -contains $folderName.ToLowerInvariant()) {
            Write-Log "Skipping excluded profile name: $folderName" 'INFO'
            continue
        }

        if (-not $p.LastUseTime) {
            Write-Log "Skipping profile with null LastUseTime: $($p.LocalPath)" 'INFO'
            continue
        }
        if ($p.LastUseTime -lt $cutoff) {
            Write-Log "Skipping stale profile (LastUseTime $($p.LastUseTime)): $($p.LocalPath)" 'INFO'
            continue
        }

        $p
    }

    return $result
}

function Mount-UserHive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$UserProfile
    )

    $sid = $UserProfile.SID
    $ntuserDat = Join-Path $UserProfile.LocalPath 'NTUSER.DAT'

    if (Test-Path -LiteralPath "Registry::HKEY_USERS\$sid") {
        return $false
    }
    if (-not (Test-Path -LiteralPath $ntuserDat)) {
        Write-Log "NTUSER.DAT not found for $($UserProfile.LocalPath)" 'WARN'
        return $false
    }

    $null = & reg.exe load "HKU\$sid" "$ntuserDat" 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Log "reg load failed for SID $sid (exit $LASTEXITCODE)" 'WARN'
        return $false
    }
    return $true
}

function Dismount-UserHive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SID
    )

    [GC]::Collect()
    Start-Sleep -Milliseconds 200
    $null = & reg.exe unload "HKU\$SID" 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Log "reg unload failed for SID $SID (exit $LASTEXITCODE)" 'WARN'
    }
}
