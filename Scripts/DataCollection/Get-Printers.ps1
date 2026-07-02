<#
.SYNOPSIS
    Lists all installed printers, including the default printer, driver, port, and type.

.DESCRIPTION
    - Lists all installed printers via Win32_Printer.
    - Identifies the default printer.
    - Reports: printer name, port, driver, default (yes/no), network/local.

.PARAMETER NonInteractive
    Suppress all prompts. Output structured JSON to stdout. Exit cleanly.

.EXAMPLE
    .\Get-Printers.ps1
    .\Get-Printers.ps1 -NonInteractive

.NOTES
    Source repos used:
    - garytown-master/OSD/TroubleShootingSteps/Get-MachineInfo.ps1
      (Win32_Printer WMI query pattern)
    - No dedicated printer inventory script found in source repos.
      Win32_Printer is standard WMI.

    Requires: Administrator
    Output:   C:\PreWipeOutput\Logs\Get-Printers.log
#>

[CmdletBinding()]
param(
    [switch]$NonInteractive
)

#region --- Init ---
$ScriptName = 'Get-Printers'
. (Join-Path $PSScriptRoot '..\Common\Initialize-Toolkit.ps1')
$LogFile = "$LogDir\$ScriptName.log"
if (-not (Test-AdminElevation)) { exit 1 }
#endregion

#region --- Printer Inventory ---
# Virtual/software printer names and driver patterns to exclude
$ExcludeNames = @(
    'Microsoft Print to PDF',
    'Microsoft XPS Document Writer',
    'Fax',
    'OneNote',
    'Send To OneNote'
)

$PrinterList = @()
$CollectionError = $null

try {
    Write-Log "Querying installed printers via Win32_Printer..."
    $allPrinters = Get-CimInstance -ClassName Win32_Printer -ErrorAction Stop

    # Filter to physical printers only
    $printers = $allPrinters | Where-Object {
        $name   = $_.Name
        $driver = $_.DriverName
        $port   = $_.PortName

        $skipByName = $false
        foreach ($excl in $ExcludeNames) {
            if ($name -like "*$excl*") { $skipByName = $true; break }
        }
        if ($skipByName) { Write-Log "  Excluding virtual printer: $name"; return $false }

        if ($driver -match 'PDF|XPS') { Write-Log "  Excluding PDF/XPS driver printer: $name"; return $false }

        if ($port -match '^(PORTPROMPT:|nul:|SHRFAX:|FILE:)') { Write-Log "  Excluding virtual-port printer: $name"; return $false }

        return $true
    }

    Write-Log "Total printers: $($allPrinters.Count) | Physical after filter: $($printers.Count)"

    foreach ($p in $printers) {
        $isNetwork = $p.Network -or $p.PortName -match '(\\\\|^IP_|^WSD-|^HTTP|^TCP)'
        $printerType = if ($isNetwork) { 'Network' } else { 'Local' }

        $PrinterList += [PSCustomObject]@{
            Name       = $p.Name
            PortName   = $p.PortName
            DriverName = $p.DriverName
            IsDefault  = [bool]$p.Default
            Type       = $printerType
            Status     = $p.PrinterStatus
        }

        $defaultStr = if ($p.Default) { ' [DEFAULT]' } else { '' }
        Write-Log "  $($p.Name)$defaultStr | Port: $($p.PortName) | Driver: $($p.DriverName) | Type: $printerType"
    }
} catch {
    # Failure must be distinguishable from 'no printers' — a stopped Print Spooler
    # makes Win32_Printer throw, and a zero-printer PASS here loses the inventory.
    Write-ErrorLog "Printer enumeration failed: $_"
    $CollectionError = $_.ToString()
}

$DefaultPrinter = $PrinterList | Where-Object { $_.IsDefault } | Select-Object -First 1
Write-Log "Default printer: $(if ($null -ne $DefaultPrinter.Name) { $DefaultPrinter.Name } else { 'None found' })"
#endregion

#region --- Output ---
$Summary = [PSCustomObject]@{
    Timestamp       = (Get-Date -Format 'o')
    TotalPrinters   = $PrinterList.Count
    DefaultPrinter  = $DefaultPrinter.Name
    Printers        = $PrinterList
    CollectionError = $CollectionError
}

$Summary | ConvertTo-Json -Depth 5 | Out-File "$OutputRoot\Logs\Get-Printers-Report.json" -Force

if ($NonInteractive) {
    $Summary | ConvertTo-Json -Depth 5
} else {
    Write-Host ""
    Write-Host "=== Physical Printers ($($PrinterList.Count)) ===" -ForegroundColor Cyan
    if ($PrinterList.Count -eq 0) {
        Write-Host "  No physical printers found." -ForegroundColor Yellow
    } else {
        $PrinterList | Format-Table -AutoSize -Property Name, Type, PortName, DriverName, IsDefault, Status | Out-String | Write-Host
    }
    Write-Host "Default: $(if ($null -ne $DefaultPrinter.Name) { $DefaultPrinter.Name } else { 'None' })" -ForegroundColor Cyan
    Write-Host "Report: $OutputRoot\Logs\Get-Printers-Report.json"
    Write-Host ""
}
#endregion

exit 0
