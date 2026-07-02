<#
.SYNOPSIS
    Checks BitLocker status on all fixed drives and verifies/escrows recovery keys to Entra ID (Azure AD).

.DESCRIPTION
    - Checks all fixed drives for BitLocker status.
    - Escrows each encrypted drive's recovery key to the best available target:
        Entra-joined (incl. hybrid) -> BackupToAAD-BitLockerKeyProtector
        Domain-joined (on-prem AD)  -> Backup-BitLockerKeyProtector (AD DS),
                                       falling back to local key capture
        Workgroup                   -> recovery password captured to
                                       C:\PreWipeOutput\BitLockerRecoveryKeys (WARN;
                                       tech must move the file to secure storage)
    - Reports: drive letter, encryption status, escrow status, action taken.

.PARAMETER NonInteractive
    Suppress all prompts. Output structured JSON to stdout. Exit cleanly.

.EXAMPLE
    .\Test-BitLockerEscrow.ps1
    .\Test-BitLockerEscrow.ps1 -NonInteractive

.NOTES
    Source repos used:
    - No dedicated BitLocker escrow script found in source repos.
      Implemented using native BitLocker cmdlets (Get-BitLockerVolume,
      BackupToAAD-BitLockerKeyProtector) which are standard PowerShell.
    - Dell-EMPS.ps1 references autoSuspendBitLocker parameter in DCU for context.

    Requires: Administrator
    Output:   C:\PreWipeOutput\Logs\Test-BitLockerEscrow.log
#>

[CmdletBinding()]
param(
    [switch]$NonInteractive
)

#region --- Init ---
$ScriptName = 'Test-BitLockerEscrow'
. (Join-Path $PSScriptRoot '..\Common\Initialize-Toolkit.ps1')
$LogFile = "$LogDir\$ScriptName.log"
if (-not (Test-AdminElevation)) { exit 1 }
#endregion

#region --- BitLocker Check ---
$Results = @()

# Determine join state once, up front. Escrow-failure classification must not
# guess from exception text: real escrow errors often mention 'Azure AD' and were being
# misclassified as not-joined, which silently passed the wipe gate.
$azureAdJoined = $false
$domainJoined  = $false
try {
    $dsregOut = (& dsregcmd /status 2>$null) | Out-String
    $azureAdJoined = $dsregOut -match 'AzureAdJoined\s*:\s*YES'
    $domainJoined  = $dsregOut -match 'DomainJoined\s*:\s*YES'
    Write-Log "Entra ID joined: $azureAdJoined | Domain joined: $domainJoined"
} catch {
    Write-Log "dsregcmd unavailable - assuming not joined: $_" 'WARN'
}

# Last-resort escrow target for devices with no directory to escrow to: capture
# the recovery password into the output folder so the key exists SOMEWHERE
# before the wipe. Surfaces as WARN with a move-to-secure-storage instruction
# (same handling as the exported WiFi PSK files).
function Save-RecoveryKeyLocally {
    param($VolResult, $Drive, $Protector)
    $rp = $Protector.RecoveryPassword
    if (-not $rp) {
        $VolResult.EscrowStatus = 'EscrowFailed'
        $VolResult.Error        = 'No directory escrow target available and the recovery password could not be read'
        Write-ErrorLog "  $Drive : recovery password unreadable - key is not backed up anywhere"
        return
    }
    $keyDir = "$OutputRoot\BitLockerRecoveryKeys"
    if (-not (Test-Path $keyDir)) { New-Item -ItemType Directory -Path $keyDir -Force | Out-Null }
    $keyFile = Join-Path $keyDir "$($env:COMPUTERNAME)_$($Drive -replace '[:\\]', '')_RecoveryKey.txt"
    @(
        "Computer          : $env:COMPUTERNAME"
        "Drive             : $Drive"
        "Key Protector ID  : $($Protector.KeyProtectorId)"
        "Recovery Password : $rp"
        "Captured          : $(Get-Date -Format 'o')"
        ""
        "Move this file to secure storage (password manager / documentation system)"
        "before wiping. It is the ONLY copy of this recovery key."
    ) | Out-File -FilePath $keyFile -Encoding UTF8 -Force
    $VolResult.EscrowStatus = 'KeyCapturedLocally'
    $VolResult.ActionTaken  = "RecoveryKeySavedTo $keyFile"
    Write-Log "  Recovery key captured to $keyFile - move to secure storage before wipe" 'WARN'
}

try {
    # Check system drive first, then any additional data volumes
    $sysDrive   = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop
    $dataVolumes = Get-BitLockerVolume -ErrorAction SilentlyContinue |
        Where-Object { $_.MountPoint -ne $env:SystemDrive -and $_.VolumeType -eq 'Data' }
    $volumes = @($sysDrive) + @($dataVolumes) | Where-Object { $_ }

    foreach ($vol in $volumes) {
        $drive = $vol.MountPoint
        Write-Log "Checking BitLocker on drive: $drive"

        $volResult = [PSCustomObject]@{
            DriveLetter      = $drive
            VolumeType       = $vol.VolumeType
            EncryptionStatus = $vol.ProtectionStatus.ToString()
            EncryptionMethod = $vol.EncryptionMethod
            PercentEncrypted = $vol.EncryptionPercentage
            RecoveryKeyID    = $null
            EscrowStatus     = 'NotApplicable'
            ActionTaken      = 'None'
            Error            = $null
        }

        if ($vol.ProtectionStatus -eq 'On') {
            Write-Log "  Drive $drive is BitLocker protected"

            # Find recovery key protectors
            $recoveryProtectors = $vol.KeyProtector | Where-Object { $_.KeyProtectorType -eq 'RecoveryPassword' }

            if ($recoveryProtectors) {
                $protector = $recoveryProtectors | Select-Object -First 1
                $volResult.RecoveryKeyID = $protector.KeyProtectorId

                Write-Log "  Recovery Key ID: $($protector.KeyProtectorId)"

                if ($azureAdJoined) {
                    # Entra-joined (including hybrid): escrow to Entra ID.
                    # BackupToAAD-BitLockerKeyProtector is idempotent; on a joined
                    # device ANY failure here is a blocking escrow failure.
                    try {
                        Write-Log "  Attempting to escrow recovery key to Entra ID..."
                        BackupToAAD-BitLockerKeyProtector -MountPoint $drive -KeyProtectorId $protector.KeyProtectorId -ErrorAction Stop
                        $volResult.EscrowStatus = 'EscrowedToEntraID'
                        $volResult.ActionTaken  = 'EscrowedToEntraID'
                        Write-Log "  Escrow command executed successfully for $drive"
                    } catch {
                        $errMsg = $_.ToString()
                        Write-ErrorLog "  Escrow failed for $drive : $errMsg"
                        $volResult.EscrowStatus = 'EscrowFailed'
                        $volResult.ActionTaken  = 'EscrowAttemptFailed'
                        $volResult.Error        = $errMsg
                    }
                } elseif ($domainJoined) {
                    # On-prem AD only: escrow to Active Directory; if the domain
                    # rejects it (schema/policy), fall back to local key capture.
                    try {
                        Write-Log "  Attempting to escrow recovery key to Active Directory..."
                        Backup-BitLockerKeyProtector -MountPoint $drive -KeyProtectorId $protector.KeyProtectorId -ErrorAction Stop
                        $volResult.EscrowStatus = 'EscrowedToAD'
                        $volResult.ActionTaken  = 'EscrowedToActiveDirectory'
                        Write-Log "  AD escrow succeeded for $drive"
                    } catch {
                        Write-Log "  AD escrow failed ($_) - falling back to local key capture" 'WARN'
                        Save-RecoveryKeyLocally -VolResult $volResult -Drive $drive -Protector $protector
                    }
                } else {
                    # Workgroup device: no directory to escrow to. Capture the key
                    # locally so it exists somewhere before the wipe.
                    Save-RecoveryKeyLocally -VolResult $volResult -Drive $drive -Protector $protector
                }
            } else {
                $volResult.EscrowStatus = 'NoRecoveryKey'
                $volResult.Error = 'No RecoveryPassword key protector found. Cannot escrow.'
                Write-Log "  ERROR: No RecoveryPassword protector on $drive - escrow cannot proceed" 'ERROR'
                if (-not $NonInteractive) {
                    Write-Host "  ERROR: $drive has no RecoveryPassword protector - escrow skipped." -ForegroundColor Red
                }
            }
        } elseif ($vol.ProtectionStatus -eq 'Off') {
            Write-Log "  Drive $($drive): BitLocker protection is OFF (may be fully decrypted)"
            $volResult.EscrowStatus = 'NotEncrypted'
        } else {
            Write-Log "  Drive $($drive): Protection status = $($vol.ProtectionStatus)"
        }

        $Results += $volResult
    }
} catch {
    Write-ErrorLog "BitLocker check failed: $_"
    $Results += [PSCustomObject]@{
        DriveLetter      = 'N/A'
        Error            = $_.ToString()
        EscrowStatus     = 'Error'
    }
}
#endregion

#region --- Output ---
# Every key must exist SOMEWHERE (Entra ID, AD, or a captured file) before wipe.
# KeyCapturedLocally satisfies the gate but surfaces as WARN — the tech must move
# the file to secure storage. NotEncrypted volumes have no keys to escrow.
$allEscrowed = -not ($Results | Where-Object {
    $_.EscrowStatus -in @('EscrowFailed', 'NoRecoveryKey', 'Error')
})
$keysCapturedLocally = [bool]($Results | Where-Object { $_.EscrowStatus -eq 'KeyCapturedLocally' })

$Summary = [PSCustomObject]@{
    Timestamp           = (Get-Date -Format 'o')
    AllEscrowed         = [bool]$allEscrowed
    KeysCapturedLocally = $keysCapturedLocally
    EntraIdJoined       = $azureAdJoined
    DomainJoined        = $domainJoined
    Results             = $Results
}

$Summary | ConvertTo-Json -Depth 5 | Out-File "$OutputRoot\Logs\Test-BitLockerEscrow-Report.json" -Force

if ($NonInteractive) {
    $Summary | ConvertTo-Json -Depth 5
} else {
    Write-Host ""
    Write-Host "=== BitLocker Escrow Status ===" -ForegroundColor Cyan
    $Results | Select-Object DriveLetter, VolumeType, EncryptionStatus, EscrowStatus, ActionTaken, Error |
        Format-Table -AutoSize | Out-String | Write-Host
    foreach ($r in $Results) {
        if ($r.EscrowStatus -eq 'NoRecoveryKey' -or $r.EscrowStatus -eq 'EscrowFailed') {
            Write-Host "  FAIL $($r.DriveLetter): $($r.Error)" -ForegroundColor Red
        } elseif ($r.EscrowStatus -eq 'EscrowedToEntraID') {
            Write-Host "  OK   $($r.DriveLetter): Escrowed to Entra ID." -ForegroundColor Green
        } elseif ($r.EscrowStatus -eq 'EscrowedToAD') {
            Write-Host "  OK   $($r.DriveLetter): Escrowed to Active Directory." -ForegroundColor Green
        } elseif ($r.EscrowStatus -eq 'KeyCapturedLocally') {
            Write-Host "  WARN $($r.DriveLetter): $($r.ActionTaken) - move this file to secure storage before wiping." -ForegroundColor Yellow
        } elseif ($r.EscrowStatus -eq 'NotEncrypted') {
            Write-Host "  WARN $($r.DriveLetter): BitLocker not enabled." -ForegroundColor Yellow
        }
    }
    Write-Host ""
    Write-Host "Report: $OutputRoot\Logs\Test-BitLockerEscrow-Report.json"
    Write-Host ""
}
#endregion

if (-not $allEscrowed) { exit 1 }

exit 0
