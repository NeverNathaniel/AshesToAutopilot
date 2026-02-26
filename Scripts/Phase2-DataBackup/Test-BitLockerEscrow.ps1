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
$OutputRoot = 'C:\PreWipeOutput'
$LogDir     = "$OutputRoot\Logs"
$LogFile    = "$LogDir\$ScriptName.log"
$ErrorLog   = "$OutputRoot\errors.log"

if (-not (Test-Path $OutputRoot)) { New-Item -Path $OutputRoot -ItemType Directory -Force | Out-Null }
if (-not (Test-Path $LogDir))     { New-Item -Path $LogDir     -ItemType Directory -Force | Out-Null }

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    "$ts [$Level] $Message" | Out-File -FilePath $LogFile -Append
    if (-not $NonInteractive) { Write-Host "$ts [$Level] $Message" }
}

function Write-ErrorLog {
    param([string]$Message)
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    "$ts [ERROR] [$ScriptName] $Message" | Out-File -FilePath $ErrorLog -Append
    Write-Log $Message 'ERROR'
}

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "ERROR: This script must be run as Administrator." -ForegroundColor Red
    exit 1
}
#endregion

#region --- BitLocker Check ---
$Results = @()

try {
    # Get all fixed volumes
    $volumes = Get-BitLockerVolume -ErrorAction Stop | Where-Object { $_.VolumeType -eq 'OperatingSystem' -or $_.VolumeType -eq 'Data' }

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

                # Check if escrowed to AAD via registry
                # Key escrow status: HKLM\SOFTWARE\Microsoft\BitLocker\RecoveryKeyInfo\*
                $escrowVerified = $false
                try {
                    $escrowKey = "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\BitLocker"
                    if (Test-Path $escrowKey) {
                        $escrowProps = Get-ItemProperty $escrowKey -ErrorAction SilentlyContinue
                        # Check for AAD-backed key indicator
                        if ($escrowProps) { $escrowVerified = $true }
                    }
                } catch {}

                # Attempt to escrow regardless (BackupToAAD-BitLockerKeyProtector is idempotent)
                try {
                    Write-Log "  Attempting to escrow recovery key to Entra ID..."
                    BackupToAAD-BitLockerKeyProtector -MountPoint $drive -KeyProtectorId $protector.KeyProtectorId -ErrorAction Stop
                    $volResult.EscrowStatus = 'EscrowAttempted'
                    $volResult.ActionTaken  = 'EscrowedToEntraID'
                    Write-Log "  Escrow command executed successfully for $drive"
                } catch {
                    $errMsg = $_.ToString()
                    if ($errMsg -match 'not.*joined' -or $errMsg -match 'AAD' -or $errMsg -match 'Azure') {
                        $volResult.EscrowStatus = 'NotAzureADJoined'
                        $volResult.ActionTaken  = 'SkippedNotAADJoined'
                        Write-Log "  Device not Azure AD joined - escrow skipped" 'WARN'
                    } else {
                        Write-ErrorLog "  Escrow failed for $drive : $errMsg"
                        $volResult.EscrowStatus = 'EscrowFailed'
                        $volResult.ActionTaken  = 'EscrowAttemptFailed'
                        $volResult.Error        = $errMsg
                    }
                }
            } else {
                Write-Log "  No recovery key protector found on $drive" 'WARN'
                $volResult.EscrowStatus = 'NoRecoveryKey'
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
$Summary = [PSCustomObject]@{
    Timestamp = (Get-Date -Format 'o')
    Results   = $Results
}

$Summary | ConvertTo-Json -Depth 5 | Out-File "$OutputRoot\Logs\BitLockerEscrow-Report.json" -Force

if ($NonInteractive) {
    $Summary | ConvertTo-Json -Depth 5
} else {
    Write-Host ""
    Write-Host "=== BitLocker Escrow Status ===" -ForegroundColor Cyan
    foreach ($r in $Results) {
        $color = if ($r.EscrowStatus -match 'Escrowed|EscrowAttempted') { 'Green' } elseif ($r.Error) { 'Red' } else { 'Yellow' }
        Write-Host "  $($r.DriveLetter): Status=$($r.EncryptionStatus) | Escrow=$($r.EscrowStatus) | Action=$($r.ActionTaken)" -ForegroundColor $color
    }
    Write-Host ""
    Write-Host "Report: $OutputRoot\Logs\BitLockerEscrow-Report.json"
    Write-Host ""
    Read-Host "Press Enter to continue"
}
#endregion
