<#
.SYNOPSIS
    Unit tests for the pure restore-plan logic in Scripts\Restore\Restore-Common.ps1.

.DESCRIPTION
    Exercises source-profile selection (fail-closed on ambiguity), the drive-
    mapping plan (profile filtering, in-use letters), the printer plan
    (network-vs-local classification), and the bookmark copy/stage decisions.
    Runs on pwsh (any OS) and Windows PowerShell 5.1. Exits 0 on pass.

.EXAMPLE
    pwsh -NoProfile -File .\Tests\Test-RestoreLogic.ps1
#>
[CmdletBinding()]
param(
    [string]$Repo = (Split-Path -Parent $PSScriptRoot)
)

. (Join-Path $Repo 'Scripts/Restore/Restore-Common.ps1')

$script:failures = 0
function Assert {
    param([string]$Name, [bool]$Condition)
    if (-not $Condition) { Write-Host "FAIL: $Name"; $script:failures++ }
}

# --- Select-SourceProfile -----------------------------------------------------
$c = @('alice', 'bob')
Assert 'requested profile wins (case-insensitive)' ((Select-SourceProfile -Candidates $c -Requested 'ALICE') -eq 'alice')
Assert 'requested-but-absent returns null (fail closed)' ($null -eq (Select-SourceProfile -Candidates $c -Requested 'carol'))
Assert 'current username auto-match' ((Select-SourceProfile -Candidates $c -CurrentUserName 'Bob') -eq 'bob')
Assert 'single candidate auto-selected' ((Select-SourceProfile -Candidates @('solo') -CurrentUserName 'someoneelse') -eq 'solo')
Assert 'ambiguous returns null (fail closed)' ($null -eq (Select-SourceProfile -Candidates $c -CurrentUserName 'carol'))
Assert 'empty candidates returns null' ($null -eq (Select-SourceProfile -Candidates @() -CurrentUserName 'x'))

# --- New-DriveMappingPlan -----------------------------------------------------
$mappings = @(
    [PSCustomObject]@{ Profile = 'alice'; DriveLetter = 'H:'; UNCPath = '\\srv\home';  Persistent = $true }
    [PSCustomObject]@{ Profile = 'alice'; DriveLetter = 'S:'; UNCPath = '\\srv\share'; Persistent = $false }
    [PSCustomObject]@{ Profile = 'bob';   DriveLetter = 'Q:'; UNCPath = '\\srv\bob';   Persistent = $true }
    [PSCustomObject]@{ Profile = 'alice'; DriveLetter = 'X:'; UNCPath = $null;         Persistent = $true }
)
$plan = New-DriveMappingPlan -Mappings $mappings -SourceProfile 'alice' -LettersInUse @('S:')
Assert 'other profiles excluded from plan' (-not ($plan | Where-Object { $_.DriveLetter -eq 'Q:' }))
Assert 'free letter maps' (($plan | Where-Object { $_.DriveLetter -eq 'H:' }).Action -eq 'Map')
Assert 'in-use letter skipped' (($plan | Where-Object { $_.DriveLetter -eq 'S:' }).Action -eq 'Skipped')
Assert 'missing UNC skipped' (($plan | Where-Object { $_.DriveLetter -eq 'X:' }).Action -eq 'Skipped')
Assert 'persistence preserved' (($plan | Where-Object { $_.DriveLetter -eq 'H:' }).Persistent -eq $true)

# --- New-PrinterPlan ------------------------------------------------------------
$printers = @(
    [PSCustomObject]@{ Name = '\\print01\Accounting'; PortName = '\\print01\Accounting'; Type = 'Network'; IsDefault = $true }
    [PSCustomObject]@{ Name = 'Front Desk HP';        PortName = 'IP_10.0.0.50';         Type = 'Network'; IsDefault = $false }
    [PSCustomObject]@{ Name = 'USB Label Printer';    PortName = 'USB001';               Type = 'Local';   IsDefault = $false }
)
$pplan = New-PrinterPlan -Printers $printers
Assert 'UNC network printer connects' (($pplan | Where-Object { $_.Name -like '*Accounting*' }).Action -eq 'Connect')
Assert 'default flag carried' (($pplan | Where-Object { $_.Name -like '*Accounting*' }).IsDefault -eq $true)
Assert 'IP-port network printer is manual' (($pplan | Where-Object { $_.Name -eq 'Front Desk HP' }).Action -eq 'Manual')
Assert 'local printer is manual' (($pplan | Where-Object { $_.Name -eq 'USB Label Printer' }).Action -eq 'Manual')

# --- New-BookmarkDecision --------------------------------------------------------
Assert 'firefox always staged' ((New-BookmarkDecision -Browser 'Firefox' -TargetProfileExists $true -TargetBookmarksExist $false).Action -eq 'Stage')
Assert 'chromium copies into empty existing profile' ((New-BookmarkDecision -Browser 'Edge' -TargetProfileExists $true -TargetBookmarksExist $false).Action -eq 'Copy')
Assert 'chromium never clobbers existing bookmarks' ((New-BookmarkDecision -Browser 'Chrome' -TargetProfileExists $true -TargetBookmarksExist $true).Action -eq 'Stage')
Assert 'missing browser profile stages' ((New-BookmarkDecision -Browser 'Chrome' -TargetProfileExists $false -TargetBookmarksExist $false).Action -eq 'Stage')

if ($script:failures -eq 0) { Write-Host 'OK: restore logic tests pass'; exit 0 }
exit 1
