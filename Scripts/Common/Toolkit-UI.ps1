# Toolkit-UI.ps1 — Terminal display functions for Start-PreWipeToolkit.ps1
# Dot-sourced by the orchestrator. Do not run directly.

function Write-Log { # Writes timestamped message to log file and console
    param([string]$Message, [string]$Level = 'INFO')
    "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message" | Add-Content -Path $LogFile -Encoding UTF8
    if (-not $NonInteractive) {
        $color = switch ($Level) { 'WARN' { 'Yellow' } 'ERROR' { 'Red' } default { 'Gray' } }
        Write-Host "  $Message" -ForegroundColor $color
    }
}

function Write-ErrorLog { # Logs errors to dedicated error log file
    param([string]$Message)
    "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$ScriptName] ERROR: $Message" | Add-Content -Path $ErrorLog -Encoding UTF8
    Write-Log -Message $Message -Level 'ERROR'
}

function Read-MenuKey { # Waits for single keypress
    $key = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') # Capture without echo
    return $key.Character.ToString().ToUpper() # Return uppercase char
}

function Get-PhaseLabel([string]$Phase) {
    if ($script:PhaseLabels.Contains($Phase)) { return $script:PhaseLabels[$Phase] }
    return $Phase
}

$script:FullBanner = @( # ASCII art full banner (13 lines)
   ' █████╗ ███████╗██╗  ██╗███████╗███████╗    ████████╗ ██████╗            '
   ' ██╔══██╗██╔════╝██║  ██║██╔════╝██╔════╝    ╚══██╔══╝██╔═══██╗          '
   ' ███████║███████╗███████║█████╗  ███████╗       ██║   ██║   ██║          '
   ' ██╔══██║╚════██║██╔══██║██╔══╝  ╚════██║       ██║   ██║   ██║          '
   ' ██║  ██║███████║██║  ██║███████╗███████║       ██║   ╚██████╔╝          '
   ' ╚═╝  ╚═╝╚══════╝╚═╝  ╚═╝╚══════╝╚══════╝       ╚═╝    ╚═════╝           '
   '                                                                         '
   ' █████╗ ██╗   ██╗████████╗ ██████╗ ██████╗ ██╗██╗      ██████╗ ████████╗ '
   ' ██╔══██╗██║   ██║╚══██╔══╝██╔═══██╗██╔══██╗██║██║     ██╔═══██╗╚══██╔══╝'
   ' ███████║██║   ██║   ██║   ██║   ██║██████╔╝██║██║     ██║   ██║   ██║   '
   ' ██╔══██║██║   ██║   ██║   ██║   ██║██╔═══╝ ██║██║     ██║   ██║   ██║   '
   ' ██║  ██║╚██████╔╝   ██║   ╚██████╔╝██║     ██║███████╗╚██████╔╝   ██║   '
   ' ╚═╝  ╚═╝ ╚═════╝    ╚═╝    ╚═════╝ ╚═╝     ╚═╝╚══════╝ ╚═════╝    ╚═╝   '
   '                                                                         '
   '     Pre-Wipe Preparation Toolkit for Windows Device Wipe & Autopilot    '
   '          Created by Nathan Sol | NeverNathaniel/AshesToAutopilot        '
)

$script:CompactBanner = @( # Compact 4-line banner
   '  ╔═══════════════════════════════════════════════════════════╗'
   '  ║   /_\ / __| || | __/ __| |_   _/ _ \                      ║'
   '  ║  / _ \\__ \ __ | _|\__ \   | || (_) |                     ║'
   '  ║ /_/_\_\___/_||_|___|___/__ |_| \___/___ _____             ║'
   '  ║   /_\| | | |_   _/ _ \| _ \_ _| |  / _ \_   _|            ║'
   '  ║  / _ \ |_| | | || (_) |  _/| || |_| (_) || |              ║'
   '  ║ /_/ \_\___/  |_| \___/|_| |___|____\___/ |_|              ║'
   '  ╚═══════════════════════════════════════════════════════════╝'
)

$script:IsInitialBanner = $true # Track if this is the first display

function Write-BannerFull { # Displays full ASCII banner (13 lines)
    Write-Host '' # Blank line
    foreach ($line in $script:FullBanner) {
        Write-Host $line -ForegroundColor Cyan # Display each line
    }
    Write-Host '' # Blank line
}

function Write-Banner { # Displays compact 4-line banner
    Write-Host '' # Blank line
    foreach ($line in $script:CompactBanner) {
        Write-Host $line -ForegroundColor Cyan # Display compact banner
    }
    Write-Host '' # Blank line
}

function Show-InitialBanner { # Shows full banner for 3 seconds, then compact on subsequent loops
    if ($script:IsInitialBanner) {
        Write-BannerFull # Display full banner
        Start-Sleep -Seconds 3 # Wait 3 seconds
        Clear-Host # Clear screen
        Write-Banner # Show compact banner
        $script:IsInitialBanner = $false # Set flag for next iterations
    } else {
        Write-Banner # Show compact banner on subsequent calls
    }
}

function Get-ProgressBarString { # Renders filled progress bar
    param([int]$Done, [int]$Total, [int]$Width = 24)
    $filled = if ($Total -gt 0) { [Math]::Floor(($Done / $Total) * $Width) } else { 0 }
    $empty  = $Width - $filled
    return ([string]::new([char]0x2588, $filled)) + ([string]::new([char]0x2591, $empty))
}

function Show-MainMenu { # Displays main menu with progress
    $done  = @($script:Steps | Where-Object { $_.Status -eq 'DONE' }).Count # Count completed steps
    $total = $script:Steps.Count # Total step count

    $warnV = @($script:Steps | Where-Object {
        $key = "$($_.Index)"
        $script:Session.Steps.ContainsKey($key) -and $script:Session.Steps[$key].Verdict -eq 'WARN'
    }).Count
    $failV = @($script:Steps | Where-Object {
        $key = "$($_.Index)"
        $script:Session.Steps.ContainsKey($key) -and $script:Session.Steps[$key].Verdict -eq 'FAIL'
    }).Count

    Clear-Host # Clear screen
    Show-InitialBanner # Show banner (full on first run, compact after)

    $inner   = 62
    $bar     = '═' * ($inner + 2)
    $progBar = Get-ProgressBarString -Done $done -Total $total -Width 24
    $baseTxt = "  $progBar  $done/$total complete"
    $warnPart = if ($warnV -gt 0) { "  [!!] $warnV" } else { '' }
    $failPart = if ($failV -gt 0) { "  [XX] $failV" } else { '' }
    $pad      = ' ' * [Math]::Max(0, $inner - $baseTxt.Length - $warnPart.Length - $failPart.Length)

    # Helper: render a box content line with Cyan borders and custom text color
    function Write-MenuLine([string]$Text, [string]$Color) {
        Write-Host -NoNewline "  ║ " -ForegroundColor Cyan
        Write-Host -NoNewline $Text.PadRight($inner) -ForegroundColor $Color
        Write-Host " ║" -ForegroundColor Cyan
    }

    Write-Host "  ╔$bar╗" -ForegroundColor Cyan
    Write-MenuLine "  $($script:ComputerName)  ·  SN: $($script:SerialNumber)  ·  $($script:CurrentUser)" DarkGray
    Write-Host -NoNewline "  ║ " -ForegroundColor Cyan
    Write-Host -NoNewline $baseTxt -ForegroundColor Cyan
    if ($warnPart) { Write-Host -NoNewline $warnPart -ForegroundColor Yellow }
    if ($failPart) { Write-Host -NoNewline $failPart -ForegroundColor Red }
    Write-Host "$pad ║" -ForegroundColor Cyan
    Write-Host ("  ║ {0} ║" -f ''.PadRight($inner)) -ForegroundColor Cyan
    Write-Host "  ╠$bar╣" -ForegroundColor Cyan
    Write-Host ("  ║ {0} ║" -f ''.PadRight($inner)) -ForegroundColor Cyan
    Write-MenuLine '  [1]  Quick Check       12 core steps' White
    Write-MenuLine "  [2]  Full Prep         all $($script:Steps.Count) steps"  White
    Write-MenuLine '  [3]  Run Single Step'                 White
    Write-MenuLine '  [4]  Custom Run        choose steps'  White
    Write-Host ("  ║ {0} ║" -f ''.PadRight($inner)) -ForegroundColor Cyan
    Write-MenuLine ("  " + ('─' * ($inner - 4))) DarkGray
    Write-Host ("  ║ {0} ║" -f ''.PadRight($inner)) -ForegroundColor Cyan
    Write-MenuLine '  [5]  View Session Summary' Gray
    Write-MenuLine '  [6]  Export Report'        Gray
    Write-MenuLine '  [7]  Reset Session'        Gray
    Write-Host ("  ║ {0} ║" -f ''.PadRight($inner)) -ForegroundColor Cyan
    Write-MenuLine ("  " + ('─' * ($inner - 4))) DarkGray
    Write-Host ("  ║ {0} ║" -f ''.PadRight($inner)) -ForegroundColor Cyan
    Write-MenuLine '  [Q]  Quit' DarkGray
    Write-Host ("  ║ {0} ║" -f ''.PadRight($inner)) -ForegroundColor Cyan
    Write-Host "  ╚$bar╝" -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  Press a key › ' -ForegroundColor DarkCyan -NoNewline
}

function Write-RunHeader { # Displays run mode header
    param([string]$Title, [string]$Sub, [int]$StepCount) # Title, subtitle, step count
    Clear-Host # Clear screen
    Write-BannerFull # Show full banner for run headers
    $inner = 62 # Box inner width
    $bar   = '═' * ($inner + 2) # Box border line
    Write-Host "  ╔$bar╗" -ForegroundColor Cyan # Top border
    Write-Host ("  ║ {0} ║" -f "  $Title".PadRight($inner)) -ForegroundColor White # Title line
    Write-Host ("  ║ {0} ║" -f "  $Sub  ·  $StepCount steps".PadRight($inner)) -ForegroundColor DarkGray # Subtitle line
    Write-Host "  ╚$bar╝" -ForegroundColor Cyan # Bottom border
    Write-Host '' # Blank line
}

function Write-StepLine { # Writes step header during run
    param([int]$Num, [int]$Total, [PSCustomObject]$Step)
    $label = " ── [Step $($Step.Index)  ·  $Num/$Total]  $($Step.DisplayName) "
    $dash  = '─' * [Math]::Max(2, 68 - $label.Length)
    Write-Host ''
    Write-Host "  $label$dash" -ForegroundColor DarkCyan
}

function Write-StepResultLine { # Displays step execution result
    param([hashtable]$Result) # Result hashtable from step execution
    $elapsed = if ($Result.Elapsed) { '{0:mm\:ss}' -f $Result.Elapsed } else { '--:--' } # Format elapsed time
    $vTag    = switch ($Result.Verdict) { 'PASS' { '[OK]' } 'WARN' { '[!!]' } 'FAIL' { '[XX]' } default { '[--]' } } # Verdict icon
    $vColor  = switch ($Result.Verdict) { 'PASS' { 'Green' } 'WARN' { 'Yellow' } 'FAIL' { 'Red' } default { 'Gray' } } # Verdict color
    $sColor  = switch ($Result.Status)  { 'DONE' { 'White' } 'FAIL' { 'Red' } 'SKIP' { 'Yellow' } default { 'Gray' } } # Status color

    Write-Host -NoNewline "  "
    Write-Host -NoNewline $vTag                -ForegroundColor $vColor
    Write-Host -NoNewline "  [$($Result.Status)]" -ForegroundColor $sColor
    Write-Host -NoNewline "  $($Result.Summary)" -ForegroundColor Gray
    Write-Host            "  ($elapsed)"          -ForegroundColor DarkGray

    if ($Result.VerdictReason -and $Result.Verdict -ne 'PASS') {
        Write-Host "       └─ $($Result.VerdictReason)" -ForegroundColor $vColor
    }
}

function Show-RunSummaryInline {
    param([PSCustomObject[]]$Results)

    $done  = @($Results | Where-Object { $_.Status -eq 'DONE' }).Count
    $fail  = @($Results | Where-Object { $_.Status -eq 'FAIL' }).Count
    $skip  = @($Results | Where-Object { $_.Status -eq 'SKIP' }).Count

    Write-Host ''
    Write-Host "  $('═' * 66)" -ForegroundColor Cyan
    Write-Host '  RESULTS SUMMARY' -ForegroundColor White
    Write-Host "  $('═' * 66)" -ForegroundColor Cyan
    Write-Host ''

    $lastPhase = ''
    foreach ($r in $Results) {
        $step = $script:Steps | Where-Object { $_.Index -eq $r.Index } | Select-Object -First 1
        if ($step -and $step.Phase -ne $lastPhase) {
            $lastPhase = $step.Phase
            Write-Host "   ── $(Get-PhaseLabel $lastPhase) ──" -ForegroundColor DarkGray
        }

        $num     = $r.Index.ToString().PadLeft(2)
        $name    = $r.DisplayName.PadRight(42)
        $elapsed = if ($r.Elapsed) { '{0:mm\:ss}' -f $r.Elapsed } else { '--:--' }
        $sColor  = switch ($r.Status)  { 'DONE' { 'White' } 'FAIL' { 'Red' } 'SKIP' { 'Yellow' } default { 'DarkGray' } }
        $vTag    = switch ($r.Verdict) { 'PASS' { '[OK]' } 'WARN' { '[!!]' } 'FAIL' { '[XX]' } default { '[--]' } }
        $vColor  = switch ($r.Verdict) { 'PASS' { 'Green' } 'WARN' { 'Yellow' } 'FAIL' { 'Red' } default { 'Gray' } }

        Write-Host -NoNewline "   $num  " -ForegroundColor DarkGray
        Write-Host -NoNewline $name       -ForegroundColor Gray
        Write-Host -NoNewline " [$($r.Status)]".PadRight(8) -ForegroundColor $sColor
        Write-Host -NoNewline " $vTag"    -ForegroundColor $vColor
        Write-Host            "  $elapsed" -ForegroundColor DarkGray
    }

    Write-Host ''
    Write-Host "  $('═' * 66)" -ForegroundColor Cyan
    Write-Host -NoNewline '  '
    Write-Host -NoNewline " DONE: $done" -ForegroundColor Green
    Write-Host -NoNewline "   FAIL: " -ForegroundColor Gray
    Write-Host -NoNewline "$fail" -ForegroundColor $(if ($fail -gt 0) { 'Red' } else { 'Gray' })
    Write-Host -NoNewline "   SKIP: " -ForegroundColor Gray
    Write-Host -NoNewline "$skip" -ForegroundColor $(if ($skip -gt 0) { 'Yellow' } else { 'Gray' })
    Write-Host "   Total: $($Results.Count)" -ForegroundColor Gray
    Write-Host "  $('═' * 66)" -ForegroundColor Cyan
    Write-Host ''

    $failV = @($Results | Where-Object { $_.Verdict -eq 'FAIL' })
    $warnV = @($Results | Where-Object { $_.Verdict -eq 'WARN' })

    if ($failV.Count -eq 0 -and $warnV.Count -eq 0) {
        Write-Host '  ╔══════════════════════════════════════╗' -ForegroundColor Green
        Write-Host '  ║   [OK]  READY TO WIPE               ║' -ForegroundColor Green
        Write-Host '  ╚══════════════════════════════════════╝' -ForegroundColor Green
    } elseif ($failV.Count -eq 0) {
        Write-Host '  ╔══════════════════════════════════════╗' -ForegroundColor Yellow
        Write-Host ("  ║   [!!]  READY — $($warnV.Count) warning(s)".PadRight(40) + '║') -ForegroundColor Yellow
        Write-Host '  ╚══════════════════════════════════════╝' -ForegroundColor Yellow
    } else {
        Write-Host '  ╔══════════════════════════════════════╗' -ForegroundColor Red
        Write-Host ("  ║   [XX]  NOT READY — $($failV.Count) issue(s)".PadRight(40) + '║') -ForegroundColor Red
        Write-Host '  ╚══════════════════════════════════════╝' -ForegroundColor Red
        Write-Host ''
        foreach ($fv in $failV) {
            Write-Host "    [XX] $($fv.DisplayName)" -ForegroundColor Red
            Write-Host "         $($fv.VerdictReason)" -ForegroundColor DarkRed
        }
    }
    Write-Host ''
}

function Show-StepListTable {
    param([string]$Title = 'ALL STEPS')
    Write-Host ''
    Write-Host "  $('═' * 66)" -ForegroundColor Cyan
    Write-Host "  $Title" -ForegroundColor White
    Write-Host "  $('═' * 66)" -ForegroundColor Cyan

    $lastPhase = ''
    foreach ($s in $script:Steps) {
        if ($s.Phase -ne $lastPhase) {
            $lastPhase = $s.Phase
            Write-Host ''
            Write-Host "   ── $(Get-PhaseLabel $lastPhase) ──" -ForegroundColor DarkGray
        }
        $badge = switch ($s.Status) {
            'DONE'    { '[DONE]' }
            'FAIL'    { '[FAIL]' }
            'SKIP'    { '[SKIP]' }
            'not-run' { '[    ]' }
            default   { '[    ]' }
        }
        $bColor = switch ($s.Status) {
            'DONE'    { 'Green'  }
            'FAIL'    { 'Red'    }
            'SKIP'    { 'Yellow' }
            default   { 'DarkGray' }
        }
        $num = $s.Index.ToString().PadLeft(2)
        Write-Host -NoNewline "   $num  " -ForegroundColor DarkGray
        Write-Host -NoNewline $badge      -ForegroundColor $bColor
        Write-Host "  $($s.DisplayName)" -ForegroundColor Gray
    }
    Write-Host ''
    Write-Host "  $('─' * 66)" -ForegroundColor DarkGray
}

function Show-SessionSummary { # Displays session progress overview
    Clear-Host # Clear screen
    Write-Banner # Show banner

    $done  = @($script:Steps | Where-Object { $_.Status -eq 'DONE' }).Count # Count completed
    $fail  = @($script:Steps | Where-Object { $_.Status -eq 'FAIL' }).Count # Count failed
    $skip  = @($script:Steps | Where-Object { $_.Status -eq 'SKIP' }).Count # Count skipped
    $norun = @($script:Steps | Where-Object { $_.Status -eq 'not-run' }).Count # Count not-run

    $progBar = Get-ProgressBarString -Done $done -Total $script:Steps.Count -Width 32

    Write-Host "  $('═' * 66)" -ForegroundColor Cyan
    Write-Host '  SESSION SUMMARY' -ForegroundColor White
    Write-Host "  $('═' * 66)" -ForegroundColor Cyan
    Write-Host ''
    Write-Host "  $progBar  $done/$($script:Steps.Count) complete" -ForegroundColor Cyan
    Write-Host ''
    Write-Host "  Started : $($script:Session.StartTime)" -ForegroundColor DarkGray
    Write-Host "  PC      : $($script:ComputerName)  ·  SN: $($script:SerialNumber)" -ForegroundColor DarkGray
    Write-Host ''

    $lastPhase = ''
    foreach ($step in $script:Steps) {
        if ($step.Phase -ne $lastPhase) {
            $lastPhase = $step.Phase
            Write-Host "   ── $(Get-PhaseLabel $lastPhase) ──" -ForegroundColor DarkGray
        }
        $badge  = switch ($step.Status) { 'DONE' { '[DONE]' } 'FAIL' { '[FAIL]' } 'SKIP' { '[SKIP]' } default { '[    ]' } }
        $bColor = switch ($step.Status) { 'DONE' { 'Green' } 'FAIL' { 'Red' } 'SKIP' { 'Yellow' } default { 'DarkGray' } }
        $stepKey  = "$($step.Index)"
        $sv       = if ($script:Session.Steps.ContainsKey($stepKey)) { $script:Session.Steps[$stepKey].Verdict } else { $null }
        $vTag     = switch ($sv) { 'PASS' { '[OK]' } 'WARN' { '[!!]' } 'FAIL' { '[XX]' } default { '[--]' } }
        $vColor   = switch ($sv) { 'PASS' { 'Green' } 'WARN' { 'Yellow' } 'FAIL' { 'Red' } default { 'DarkGray' } }
        $num      = $step.Index.ToString().PadLeft(2)
        Write-Host -NoNewline "   $num  " -ForegroundColor DarkGray
        Write-Host -NoNewline $badge      -ForegroundColor $bColor
        Write-Host -NoNewline " $vTag"    -ForegroundColor $vColor
        Write-Host "  $($step.DisplayName)" -ForegroundColor Gray
    }

    Write-Host ''
    Write-Host "  $('─' * 66)" -ForegroundColor DarkGray
    Write-Host -NoNewline "  "
    Write-Host -NoNewline " DONE: $done"   -ForegroundColor Green
    Write-Host -NoNewline "   FAIL: "      -ForegroundColor Gray
    Write-Host -NoNewline "$fail"          -ForegroundColor $(if ($fail -gt 0) { 'Red' } else { 'Gray' })
    Write-Host -NoNewline "   SKIP: "      -ForegroundColor Gray
    Write-Host -NoNewline "$skip"          -ForegroundColor $(if ($skip -gt 0) { 'Yellow' } else { 'Gray' })
    Write-Host "   Not Run: $norun"        -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  Press any key to return...' -ForegroundColor DarkGray
    $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
}
