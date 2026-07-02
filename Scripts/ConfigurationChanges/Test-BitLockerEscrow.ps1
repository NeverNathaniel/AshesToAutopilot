<#
.SYNOPSIS
    Checks BitLocker status on all fixed drives and verifies/escrows recovery keys to Entra ID (Azure AD).

.DESCRIPTION
    - Checks all fixed drives for BitLocker status.
    - For each encrypted drive: checks if recovery key is escrowed to Entra ID.
    - If not escrowed, attempts to escrow using BackupToAAD-BitLockerKeyProtector.
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

# Determine Entra ID join state once, up front. Escrow-failure classification must not
# guess from exception text: real escrow errors often mention 'Azure AD' and were being
# misclassified as not-joined, which silently passed the wipe gate.
$azureAdJoined = $false
try {
    $dsregOut = (& dsregcmd /status 2>$null) | Out-String
    $azureAdJoined = $dsregOut -match 'AzureAdJoined\s*:\s*YES'
    Write-Log "Entra ID joined: $azureAdJoined"
} catch {
    Write-Log "dsregcmd unavailable - assuming not Entra ID joined: $_" 'WARN'
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

                if (-not $azureAdJoined) {
                    # Not joined: escrow to Entra ID is impossible. This is a blocking
                    # state for the wipe gate, not a silent skip.
                    $volResult.EscrowStatus = 'NotAzureADJoined'
                    $volResult.ActionTaken  = 'SkippedNotAADJoined'
                    Write-Log "  Device not Entra ID joined - escrow not possible" 'WARN'
                } else {
                    # Attempt to escrow (BackupToAAD-BitLockerKeyProtector is idempotent).
                    # On a joined device, ANY failure here is an escrow failure.
                    try {
                        Write-Log "  Attempting to escrow recovery key to Entra ID..."
                        BackupToAAD-BitLockerKeyProtector -MountPoint $drive -KeyProtectorId $protector.KeyProtectorId -ErrorAction Stop
                        $volResult.EscrowStatus = 'EscrowAttempted'
                        $volResult.ActionTaken  = 'EscrowedToEntraID'
                        Write-Log "  Escrow command executed successfully for $drive"
                    } catch {
                        $errMsg = $_.ToString()
                        Write-ErrorLog "  Escrow failed for $drive : $errMsg"
                        $volResult.EscrowStatus = 'EscrowFailed'
                        $volResult.ActionTaken  = 'EscrowAttemptFailed'
                        $volResult.Error        = $errMsg
                    }
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
# NotAzureADJoined counts as NOT escrowed: nothing was backed up anywhere.
# NotEncrypted volumes are excluded — there are no keys to escrow.
$allEscrowed = -not ($Results | Where-Object {
    $_.EscrowStatus -in @('EscrowFailed', 'NoRecoveryKey', 'Error', 'NotAzureADJoined')
})

$Summary = [PSCustomObject]@{
    Timestamp   = (Get-Date -Format 'o')
    AllEscrowed = [bool]$allEscrowed
    Results     = $Results
}

$Summary | ConvertTo-Json -Depth 5 | Out-File "$OutputRoot\Logs\BitLockerEscrow-Report.json" -Force

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
        } elseif ($r.EscrowStatus -eq 'EscrowAttempted') {
            Write-Host "  OK   $($r.DriveLetter): Escrow command succeeded." -ForegroundColor Green
        } elseif ($r.EscrowStatus -eq 'NotEncrypted') {
            Write-Host "  WARN $($r.DriveLetter): BitLocker not enabled." -ForegroundColor Yellow
        } elseif ($r.EscrowStatus -eq 'NotAzureADJoined') {
            Write-Host "  FAIL $($r.DriveLetter): Device not Entra ID joined - recovery key is NOT backed up anywhere." -ForegroundColor Red
        }
    }
    Write-Host ""
    Write-Host "Report: $OutputRoot\Logs\BitLockerEscrow-Report.json"
    Write-Host ""
}
#endregion

if (-not $allEscrowed) { exit 1 }

exit 0
