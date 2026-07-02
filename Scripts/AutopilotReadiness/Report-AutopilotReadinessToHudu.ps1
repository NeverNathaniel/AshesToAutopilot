<#
.SYNOPSIS
    Self-reports Autopilot readiness status to a Hudu asset record.

.DESCRIPTION
    Reads existing toolkit JSON outputs from C:\PreWipeOutput\Logs\ and submits
    a formatted Autopilot readiness report to Hudu as an asset. If the asset
    already exists it is updated; otherwise a new asset is created under the
    specified company.

    Covers: hardware readiness checks (TPM, SecureBoot, UEFI, CPU, RAM, Storage),
    Autopilot profile assignment, wipe verdict, and any blockers detected by the
    pre-wipe toolkit.

    Requires the HuduAPI PowerShell module. API key can be supplied directly
    or retrieved from Azure Key Vault.

.PARAMETER HuduBaseUrl
    Base URL of your Hudu instance (e.g. https://docs.contoso.com).

.PARAMETER HuduApiKey
    Hudu API key. If omitted, retrieved from Azure Key Vault using
    KeyVaultName and KeyVaultSecretName.

.PARAMETER KeyVaultName
    Name of the Azure Key Vault that holds the Hudu API key (used when
    HuduApiKey is not supplied directly).

.PARAMETER KeyVaultSecretName
    Name of the secret in the Key Vault that contains the Hudu API key.
    Defaults to 'HuduApiKey'.

.PARAMETER CompanyName
    Name of the company in Hudu to link the asset to.
    Defaults to the Active Directory domain name, or the local computer name
    if the machine is not domain-joined.

.PARAMETER AssetLayoutName
    Name of the Hudu asset layout to use. Created if it does not exist.
    Defaults to 'Autopilot Readiness'.

.PARAMETER NonInteractive
    Suppress all prompts. Output structured JSON to stdout. Exit cleanly.

.EXAMPLE
    .\Report-AutopilotReadinessToHudu.ps1 `
        -HuduBaseUrl 'https://docs.contoso.com' `
        -HuduApiKey  'abc123' `
        -CompanyName 'Contoso'

.EXAMPLE
    .\Report-AutopilotReadinessToHudu.ps1 `
        -HuduBaseUrl         'https://docs.contoso.com' `
        -KeyVaultName        'MyVault' `
        -KeyVaultSecretName  'HuduApiKey' `
        -CompanyName         'Contoso'

.NOTES
    Requires: Administrator, HuduAPI module (Install-Module HuduAPI)
    Optional: Az.KeyVault module when using Azure Key Vault credential retrieval
    Output:   C:\PreWipeOutput\Logs\HuduReport-Result.json

    Reads (if present):
      C:\PreWipeOutput\Logs\AutopilotReadiness-Report.json
      C:\PreWipeOutput\Logs\AutopilotAssignment-Report.json
      C:\PreWipeOutput\Logs\PreWipeSummary-Report.json
      C:\PreWipeOutput\Logs\BitLockerEscrow-Report.json
      C:\PreWipeOutput\Logs\OneDriveSyncStatus-Report.json
      C:\PreWipeOutput\Logs\DeviceHealth-Report.json

    Based on the Hudu Community Script method:
    https://github.com/Hudu-Technologies-Inc/Community-Scripts/blob/main/
    Information-and-Visualization/Endpoint-Self-Reporting/Self-Report-Device.ps1
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$HuduBaseUrl,

    [string]$HuduApiKey,

    [string]$KeyVaultName,

    [string]$KeyVaultSecretName = 'HuduApiKey',

    [string]$CompanyName,

    [string]$AssetLayoutName = 'Autopilot Readiness',

    [switch]$NonInteractive
)

#region --- Init ---
$ScriptName = 'Report-AutopilotReadinessToHudu'
. (Join-Path $PSScriptRoot '..\Common\Initialize-Toolkit.ps1')
$LogFile = "$LogDir\$ScriptName.log"
if (-not (Test-AdminElevation)) { exit 1 }
#endregion

#region --- Module Check ---
if (-not (Get-Module -Name HuduAPI -ListAvailable)) {
    Write-Host "ERROR: HuduAPI module is not installed. Run: Install-Module HuduAPI" -ForegroundColor Red
    exit 1
}
#endregion

#region --- HTML Helpers ---
function Set-HtmlTagAttributes {
    <#
    .SYNOPSIS
        Injects attribute string into the first occurrence of an HTML tag.
    #>
    param(
        [string]$Html,
        [string]$Tag,
        [string]$Attributes
    )
    # Match opening tag (with or without existing attributes)
    $pattern = "(<$Tag)(\s[^>]*)?(>)"
    if ($Html -match $pattern) {
        $Html = $Html -replace $pattern, "`$1 $Attributes`$2`$3"
    }
    return $Html
}

function Add-HtmlTableTheme {
    <#
    .SYNOPSIS
        Applies a consistent CSS theme to an HTML table string.
    #>
    param(
        [string]$Html,
        [string]$TableBorderColor  = '#cccccc',
        [string]$HeaderBgColor     = '#2c5f8a',
        [string]$HeaderFontColor   = '#ffffff',
        [string]$EvenRowBgColor    = '#f4f8fc',
        [string]$FontFamily        = 'Arial, sans-serif',
        [string]$FontSize          = '13px'
    )

    $tableStyle = "border-collapse:collapse; width:100%; font-family:$FontFamily; font-size:$FontSize;"
    $thStyle    = "background-color:$HeaderBgColor; color:$HeaderFontColor; padding:6px 10px; text-align:left; border:1px solid $TableBorderColor;"
    $tdStyle    = "padding:5px 10px; border:1px solid $TableBorderColor;"

    # Wrap in a div with alternating row style injection
    $styledTable = @"
<style>
  .hudu-ap-table tr:nth-child(even) td { background-color: $EvenRowBgColor; }
</style>
"@

    $Html = Set-HtmlTagAttributes -Html $Html -Tag 'table' -Attributes "class='hudu-ap-table' style='$tableStyle'"
    $Html = $Html -replace '<th([^>]*)>', "<th`$1 style='$thStyle'>"
    $Html = $Html -replace '<td([^>]*)>', "<td`$1 style='$tdStyle'>"
    return $styledTable + $Html
}

function ConvertTo-HtmlTable {
    <#
    .SYNOPSIS
        Converts a hashtable or PSCustomObject array to a themed HTML table.
    #>
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        $InputObject,
        [string[]]$Headers
    )
    process {
        $rows = @($InputObject)
        if ($rows.Count -eq 0) { return '<p><em>No data</em></p>' }

        if (-not $Headers) {
            if ($rows[0] -is [System.Collections.IDictionary]) {
                $Headers = $rows[0].Keys
            } else {
                $Headers = $rows[0].PSObject.Properties.Name
            }
        }

        $sb = [System.Text.StringBuilder]::new()
        [void]$sb.Append('<table><thead><tr>')
        foreach ($h in $Headers) { [void]$sb.Append("<th>$h</th>") }
        [void]$sb.Append('</tr></thead><tbody>')

        foreach ($row in $rows) {
            [void]$sb.Append('<tr>')
            foreach ($h in $Headers) {
                $val = if ($row -is [System.Collections.IDictionary]) { $row[$h] } else { $row.$h }
                if ($null -eq $val) { $val = '' }
                [void]$sb.Append("<td>$([System.Net.WebUtility]::HtmlEncode($val.ToString()))</td>")
            }
            [void]$sb.Append('</tr>')
        }
        [void]$sb.Append('</tbody></table>')

        return Add-HtmlTableTheme -Html $sb.ToString()
    }
}
#endregion

#region --- Load Toolkit JSON Outputs ---
function Get-JsonReport {
    param([string]$FileName)
    $path = Join-Path $LogDir $FileName
    if (Test-Path $path) {
        try {
            return Get-Content $path -Raw | ConvertFrom-Json
        } catch {
            Write-Log "Could not parse ${FileName}: $_" 'WARN'
        }
    }
    return $null
}

Write-Log "Loading toolkit JSON outputs..."
$readinessReport  = Get-JsonReport 'AutopilotReadiness-Report.json'
$assignmentReport = Get-JsonReport 'AutopilotAssignment-Report.json'
$summaryReport    = Get-JsonReport 'PreWipeSummary-Report.json'
$bitlockerReport  = Get-JsonReport 'BitLockerEscrow-Report.json'
$oneDriveReport   = Get-JsonReport 'OneDriveSyncStatus-Report.json'
$healthReport     = Get-JsonReport 'DeviceHealth-Report.json'
#endregion

#region --- Collect Device Identity ---
Write-Log "Collecting device identity..."
$computerName  = $env:COMPUTERNAME
$serialNumber  = $null
$deviceModel   = $null
$osCaption     = $null
$osBuild       = $null
$domainName    = $null

try {
    $bios      = Get-CimInstance -ClassName Win32_BIOS -ErrorAction Stop
    $cs        = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
    $os        = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    $serialNumber = $bios.SerialNumber
    $deviceModel  = "$($cs.Manufacturer) $($cs.Model)".Trim()
    $osCaption    = $os.Caption
    $osBuild      = $os.BuildNumber
    $domainName   = if ($cs.PartOfDomain) { $cs.Domain } else { $null }
    Write-Log "Device: $computerName | $deviceModel | $serialNumber | $osCaption ($osBuild)"
} catch {
    Write-ErrorLog "Failed to collect device identity: $_"
}

# Determine company name
if (-not $CompanyName) {
    $CompanyName = if ($domainName) { $domainName } else { $computerName }
    Write-Log "Company name not specified — using '$CompanyName'"
}
#endregion

#region --- Derive Summary Fields ---
$overallReadiness = if ($readinessReport)  { $readinessReport.OverallStatus }  else { 'NOT_RUN' }
$wipeVerdict      = if ($summaryReport)    { $summaryReport.WipeVerdict }       else { 'NOT_RUN' }
$profileDownloaded = if ($assignmentReport) { $assignmentReport.ProfileDownloaded } else { $false }
$tenantDomain     = if ($assignmentReport) { $assignmentReport.TenantDomain }  else { $null }
$lastChecked      = Get-Date -Format 'yyyy-MM-dd HH:mm'

# Blockers: prefer summary report, fall back to readiness failures
$blockers = @()
if ($summaryReport -and $summaryReport.Blockers) {
    $blockers = @($summaryReport.Blockers)
} elseif ($readinessReport -and $readinessReport.Failures) {
    $blockers = @($readinessReport.Failures)
}
#endregion

#region --- Build HTML Sections ---
Write-Log "Building HTML report sections..."

# --- Hardware Checks Table ---
$hwHtml = '<p><em>Autopilot readiness check not yet run.</em></p>'
if ($readinessReport -and $readinessReport.Checks) {
    $hwRows = foreach ($checkName in $readinessReport.Checks.PSObject.Properties.Name) {
        $c = $readinessReport.Checks.$checkName
        $detail = switch ($checkName) {
            'TPM'        { "v$($c.Version)" }
            'SecureBoot' { if ($c.Enabled) { 'Enabled' } else { 'Disabled' } }
            'CPU'        { $c.Name }
            'Memory'     { "$($c.InstalledGB) GB installed (requires $($c.RequiredGB) GB)" }
            'Storage'    { "$($c.SizeGB) GB total, $($c.FreeGB) GB free on $($c.Drive)" }
            'UEFI'       { $c.FirmwareType }
            default      { '' }
        }
        [PSCustomObject]@{
            Check   = $checkName
            Status  = $c.Status
            Detail  = $detail
        }
    }
    $hwHtml = $hwRows | ConvertTo-HtmlTable -Headers 'Check', 'Status', 'Detail'
}

# --- Autopilot Profile Table ---
$profileHtml = '<p><em>Autopilot assignment check not yet run.</em></p>'
if ($assignmentReport) {
    $profileRows = @(
        [PSCustomObject]@{ Field = 'Profile Downloaded';   Value = if ($assignmentReport.ProfileDownloaded) { 'Yes' } else { 'No' } }
        [PSCustomObject]@{ Field = 'Profile Name';         Value = $assignmentReport.ProfileName }
        [PSCustomObject]@{ Field = 'Profile Source';       Value = if ($assignmentReport.ProfileSource) { $assignmentReport.ProfileSource } else { 'None' } }
        [PSCustomObject]@{ Field = 'Forced Enrollment';    Value = if ($assignmentReport.ForcedEnrollment) { 'Yes' } else { 'No' } }
        [PSCustomObject]@{ Field = 'Tenant Domain';        Value = if ($assignmentReport.TenantDomain) { $assignmentReport.TenantDomain } else { '(not found)' } }
        [PSCustomObject]@{ Field = 'Tenant ID';            Value = if ($assignmentReport.TenantId) { $assignmentReport.TenantId } else { '(not found)' } }
        [PSCustomObject]@{ Field = 'Azure AD Joined';      Value = if ($assignmentReport.AzureADJoined) { 'Yes' } else { 'No' } }
        [PSCustomObject]@{ Field = 'Assigned User';        Value = if ($assignmentReport.AssignedUser) { $assignmentReport.AssignedUser } else { '(not embedded in profile)' } }
        [PSCustomObject]@{ Field = 'Assigned Device Name'; Value = if ($assignmentReport.DeviceName) { $assignmentReport.DeviceName } else { '(not set)' } }
    )
    $profileHtml = $profileRows | ConvertTo-HtmlTable -Headers 'Field', 'Value'
}

# --- Blockers Table ---
$blockersHtml = '<p><strong>No blockers detected.</strong></p>'
if ($blockers.Count -gt 0) {
    $blockerRows = $blockers | ForEach-Object { [PSCustomObject]@{ Blocker = $_ } }
    $blockersHtml = $blockerRows | ConvertTo-HtmlTable -Headers 'Blocker'
}

# --- Phase Progress Table ---
$phaseHtml = '<p><em>Pre-wipe summary not yet run.</em></p>'
if ($summaryReport -and $summaryReport.PhaseSummary) {
    $phaseRows = $summaryReport.PhaseSummary | ForEach-Object {
        [PSCustomObject]@{
            Phase      = $_.Phase
            Completed  = "$($_.ScriptsRan) / $($_.ScriptsTotal)"
            Percentage = $_.Completion
        }
    }
    $phaseHtml = $phaseRows | ConvertTo-HtmlTable -Headers 'Phase', 'Completed', 'Percentage'
}

# --- Security Status Table ---
$securityRows = @()
if ($bitlockerReport) {
    $securityRows += [PSCustomObject]@{ Check = 'BitLocker Escrowed'; Status = if ($bitlockerReport.AllEscrowed) { 'PASS' } else { 'FAIL' } }
}
if ($oneDriveReport) {
    $securityRows += [PSCustomObject]@{ Check = 'OneDrive Sync'; Status = if ($oneDriveReport.OverallVerdict -eq 'SAFE') { 'PASS' } else { $oneDriveReport.OverallVerdict } }
}
if ($readinessReport) {
    $sb = $readinessReport.Checks.SecureBoot
    $tp = $readinessReport.Checks.TPM
    if ($sb) { $securityRows += [PSCustomObject]@{ Check = 'Secure Boot'; Status = $sb.Status } }
    if ($tp) { $securityRows += [PSCustomObject]@{ Check = 'TPM 2.0'; Status = $tp.Status } }
}
$securityHtml = if ($securityRows.Count -gt 0) {
    $securityRows | ConvertTo-HtmlTable -Headers 'Check', 'Status'
} else {
    '<p><em>Security checks not yet run.</em></p>'
}
#endregion

#region --- Authenticate to Hudu ---
Write-Log "Authenticating to Hudu ($HuduBaseUrl)..."

# Install HuduAPI module if not present
if (-not (Get-Module -ListAvailable -Name HuduAPI)) {
    Write-Log "HuduAPI module not found — installing from PSGallery..."
    try {
        Install-Module -Name HuduAPI -Scope CurrentUser -Force -ErrorAction Stop
        Write-Log "HuduAPI installed."
    } catch {
        Write-ErrorLog "Failed to install HuduAPI: $_"
        exit 1
    }
}
Import-Module HuduAPI -ErrorAction Stop

# Resolve API key
if (-not $HuduApiKey) {
    if (-not $KeyVaultName) {
        Write-ErrorLog "No API key provided and no KeyVaultName specified. Supply -HuduApiKey or -KeyVaultName."
        exit 1
    }
    Write-Log "Retrieving Hudu API key from Key Vault '$KeyVaultName'..."
    try {
        if (-not (Get-Module -ListAvailable -Name Az.KeyVault)) {
            Install-Module -Name Az.KeyVault -Scope CurrentUser -Force -ErrorAction Stop
        }
        Import-Module Az.KeyVault -ErrorAction Stop
        $secret = Get-AzKeyVaultSecret -VaultName $KeyVaultName -Name $KeyVaultSecretName -AsPlainText -ErrorAction Stop
        $HuduApiKey = $secret
        Write-Log "API key retrieved from Key Vault."
    } catch {
        Write-ErrorLog "Failed to retrieve API key from Key Vault: $_"
        exit 1
    }
}

try {
    New-HuduAPIKey $HuduApiKey
    New-HuduBaseURL $HuduBaseUrl
    Write-Log "Hudu API initialized."
} catch {
    Write-ErrorLog "Failed to initialize Hudu API: $_"
    exit 1
}
#endregion

#region --- Resolve Hudu Company ---
Write-Log "Looking up company '$CompanyName' in Hudu..."
$company = $null
try {
    $company = Get-HuduCompanies -Name $CompanyName | Select-Object -First 1
} catch {
    Write-ErrorLog "Failed to query Hudu companies: $_"
    exit 1
}

if (-not $company) {
    Write-ErrorLog "Company '$CompanyName' not found in Hudu. Create it first or check the name."
    exit 1
}
Write-Log "Found company: $($company.name) (ID $($company.id))"
#endregion

#region --- Resolve or Create Asset Layout ---
Write-Log "Looking up asset layout '$AssetLayoutName'..."
$layout = $null
try {
    $layout = Get-HuduAssetLayouts -Name $AssetLayoutName | Select-Object -First 1
} catch {
    Write-ErrorLog "Failed to query asset layouts: $_"
    exit 1
}

if (-not $layout) {
    Write-Log "Layout '$AssetLayoutName' not found — creating it..."
    $layoutFields = @(
        @{ label = 'Serial Number';           field_type = 'Text';     show_in_list = $true;  required = $false }
        @{ label = 'Device Model';            field_type = 'Text';     show_in_list = $true;  required = $false }
        @{ label = 'Operating System';        field_type = 'Text';     show_in_list = $false; required = $false }
        @{ label = 'OS Build';                field_type = 'Text';     show_in_list = $false; required = $false }
        @{ label = 'Domain';                  field_type = 'Text';     show_in_list = $false; required = $false }
        @{ label = 'Autopilot Readiness';     field_type = 'Text';     show_in_list = $true;  required = $false }
        @{ label = 'Wipe Verdict';            field_type = 'Text';     show_in_list = $true;  required = $false }
        @{ label = 'Autopilot Profile';       field_type = 'Text';     show_in_list = $false; required = $false }
        @{ label = 'Tenant Domain';           field_type = 'Text';     show_in_list = $false; required = $false }
        @{ label = 'Last Checked';            field_type = 'Text';     show_in_list = $true;  required = $false }
        @{ label = 'Hardware Checks';         field_type = 'RichText'; show_in_list = $false; required = $false }
        @{ label = 'Security Status';         field_type = 'RichText'; show_in_list = $false; required = $false }
        @{ label = 'Autopilot Profile Details'; field_type = 'RichText'; show_in_list = $false; required = $false }
        @{ label = 'Phase Progress';          field_type = 'RichText'; show_in_list = $false; required = $false }
        @{ label = 'Blockers';               field_type = 'RichText'; show_in_list = $false; required = $false }
    )
    try {
        $layout = (New-HuduAssetLayout -Name $AssetLayoutName -Icon 'fas fa-laptop' -Color '#2c5f8a' -IconColor '#ffffff' -Fields $layoutFields -ErrorAction Stop).asset_layout
        Write-Log "Asset layout created (ID $($layout.id))."
    } catch {
        Write-ErrorLog "Failed to create asset layout: $_"
        exit 1
    }
} else {
    Write-Log "Using existing layout (ID $($layout.id))."
}
#endregion

#region --- Resolve or Create Asset ---
$assetName = "$computerName - Autopilot Readiness"
Write-Log "Looking up asset '$assetName' for company ID $($company.id)..."
$asset = $null
try {
    $asset = Get-HuduAssets -Name $assetName -AssetLayoutId $layout.id -CompanyId $company.id | Select-Object -First 1
} catch {
    Write-ErrorLog "Failed to query Hudu assets: $_"
    exit 1
}
#endregion

#region --- Build Field Values ---
# HuduAPI expects a hashtable keyed by the field label slug
# (label lowercased, spaces replaced with underscores)
$fields = @{
    'serial_number'             = if ($serialNumber) { $serialNumber } else { '' }
    'device_model'              = if ($deviceModel)  { $deviceModel }  else { '' }
    'operating_system'          = if ($osCaption)    { $osCaption }    else { '' }
    'os_build'                  = if ($osBuild)      { $osBuild }      else { '' }
    'domain'                    = if ($domainName)   { $domainName }   else { 'Not domain-joined' }
    'autopilot_readiness'       = $overallReadiness
    'wipe_verdict'              = $wipeVerdict
    'autopilot_profile'         = if ($profileDownloaded) { 'Downloaded' } else { 'Not downloaded' }
    'tenant_domain'             = if ($tenantDomain) { $tenantDomain } else { '' }
    'last_checked'              = $lastChecked
    'hardware_checks'           = $hwHtml
    'security_status'           = $securityHtml
    'autopilot_profile_details' = $profileHtml
    'phase_progress'            = $phaseHtml
    'blockers'                  = $blockersHtml
}
#endregion

#region --- Create or Update Asset ---
try {
    if ($asset) {
        Write-Log "Updating existing asset (ID $($asset.id))..."
        Set-HuduAsset -Id $asset.id -Name $assetName -AssetLayoutId $layout.id -CompanyId $company.id -Fields $fields | Out-Null
        Write-Log "Asset updated."
        $assetAction = 'Updated'
        $assetId     = $asset.id
    } else {
        Write-Log "Creating new asset '$assetName'..."
        $newAsset = (New-HuduAsset -Name $assetName -AssetLayoutId $layout.id -CompanyId $company.id -Fields $fields -ErrorAction Stop).asset
        Write-Log "Asset created (ID $($newAsset.id))."
        $assetAction = 'Created'
        $assetId     = $newAsset.id
    }
} catch {
    Write-ErrorLog "Failed to $( if ($asset) { 'update' } else { 'create' } ) asset: $_"
    exit 1
} finally {
    # Clear API credentials from memory
    try { Remove-HuduAPIKey -ErrorAction SilentlyContinue } catch {}
}
#endregion

#region --- Output Result ---
$Result = [PSCustomObject]@{
    Timestamp        = (Get-Date -Format 'o')
    Success          = $true
    AssetAction      = $assetAction
    AssetId          = $assetId
    AssetName        = $assetName
    CompanyName      = $CompanyName
    CompanyId        = $company.id
    HuduBaseUrl      = $HuduBaseUrl
    OverallReadiness = $overallReadiness
    WipeVerdict      = $wipeVerdict
    BlockerCount     = $blockers.Count
}

$Result | ConvertTo-Json -Depth 5 | Out-File "$LogDir\HuduReport-Result.json" -Force

if ($NonInteractive) {
    $Result | ConvertTo-Json -Depth 5
} else {
    Write-Host ''
    Write-Host '=== Hudu Autopilot Readiness Report ===' -ForegroundColor Cyan
    Write-Host "  Asset:       $assetName ($assetAction)" -ForegroundColor White
    Write-Host "  Asset ID:    $assetId"
    Write-Host "  Company:     $CompanyName (ID $($company.id))"
    Write-Host "  Readiness:   $overallReadiness" -ForegroundColor $(switch ($overallReadiness) { 'READY' { 'Green' } 'NOT READY' { 'Red' } default { 'Yellow' } })
    Write-Host "  Wipe Verdict: $wipeVerdict"     -ForegroundColor $(switch -Wildcard ($wipeVerdict) { 'READY*' { 'Green' } 'NOT*' { 'Red' } default { 'Yellow' } })
    if ($blockers.Count -gt 0) {
        Write-Host "  Blockers ($($blockers.Count)):" -ForegroundColor Red
        foreach ($b in $blockers) { Write-Host "    - $b" -ForegroundColor Red }
    } else {
        Write-Host '  No blockers.' -ForegroundColor Green
    }
    Write-Host ''
    Write-Host "Result: $LogDir\HuduReport-Result.json"
    Write-Host ''
}
#endregion

exit 0
