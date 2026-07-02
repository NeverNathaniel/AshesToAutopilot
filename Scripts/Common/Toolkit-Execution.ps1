<#
.SYNOPSIS
    Step execution engine for Start-PreWipeToolkit.ps1.

.DESCRIPTION
    Dot-sourced by the orchestrator at startup. Provides Invoke-RunSteps,
    Invoke-StepCapture, and Invoke-StepInteractive. Runs each step as a child
    process with -NonInteractive, captures JSON output, and evaluates verdicts
    independently of exit code. Not intended to be run directly.
#>

function Invoke-StepCapture { # Executes step and captures output
    param([PSCustomObject]$Step) # Step object to execute

    $fullPath = Join-Path $script:ToolkitRoot $Step.ScriptPath # Resolve full script path

    if (-not (Test-Path $fullPath)) {
        Write-Log "Script not found, skipping: $($Step.ScriptPath)" -Level 'WARN' # Log missing script
        return @{ Status = 'SKIP'; Parsed = $null; Summary = 'Script not found'; Elapsed = $null; ExitCode = $null; Verdict = 'WARN'; VerdictReason = 'Step was skipped — script missing' } # Return skip
    }

    $global:LASTEXITCODE = 0 # Reset engine exit code (a plain assignment here would create a function-local shadow)
    $exitCode = 0 # Initialize exit code
    $parsed   = $null # Initialize parsed output

    $sw = [System.Diagnostics.Stopwatch]::StartNew() # Start timer
    try {
        $rawOutput = & $fullPath -NonInteractive 2>&1 # Execute; success + error streams as separate objects
        $exitCode  = if ($null -ne $global:LASTEXITCODE) { $global:LASTEXITCODE } else { 0 } # Capture real exit code
        $errRecs   = @($rawOutput | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] })
        foreach ($e in $errRecs) { Write-Log "Step $($Step.Index) stderr: $e" -Level 'WARN' }
        $jsonRaw   = ($rawOutput | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }) | Out-String # JSON must come only from the success stream
    } catch {
        $sw.Stop() # Stop timer
        Write-ErrorLog "Step $($Step.Index) ($($Step.DisplayName)) threw: $_" # Log exception
        return @{ Status = 'FAIL'; Parsed = $null; Summary = "Error: $_"; Elapsed = $sw.Elapsed; ExitCode = 1; Verdict = 'FAIL'; VerdictReason = 'Script execution failed' } # Return failure
    }
    $sw.Stop() # Stop timer

    try {
        if ($jsonRaw.Trim()) { $parsed = $jsonRaw | ConvertFrom-Json } # Parse JSON output
    } catch {
        Write-Log "Could not parse JSON from $($Step.DisplayName)" -Level 'WARN' # Log parse error
    }

    $status  = if ($exitCode -eq 0) { 'DONE' } else { 'FAIL' }
    $summary = Get-StepSummary -Parsed $parsed -ScriptFile $Step.ScriptPath
    $verdict = Get-StepVerdict -Parsed $parsed -ScriptFile $Step.ScriptPath -Status $status

    Write-Log "Step $($Step.Index) ($($Step.DisplayName)): $status — $summary"

    return @{
        Status        = $status
        Parsed        = $parsed
        Summary       = $summary
        Elapsed       = $sw.Elapsed
        ExitCode      = $exitCode
        Verdict       = $verdict.Verdict
        VerdictReason = $verdict.Reason
    }
}

function Invoke-StepInteractive { # Runs step interactively with output
    param([PSCustomObject]$Step) # Step to execute

    $fullPath = Join-Path $script:ToolkitRoot $Step.ScriptPath # Resolve full path
    Clear-Host # Clear screen
    Write-Banner # Display banner

    $inner = 62; $bar = '═' * ($inner + 2)
    Write-Host "  ╔$bar╗" -ForegroundColor Cyan
    Write-Host ("  ║ {0} ║" -f "  Step $($Step.Index) — $($Step.DisplayName)".PadRight($inner)) -ForegroundColor White
    Write-Host ("  ║ {0} ║" -f "  $(Get-PhaseLabel $Step.Phase)  ·  $($Step.ScriptPath)".PadRight($inner)) -ForegroundColor DarkGray
    Write-Host "  ╚$bar╝" -ForegroundColor Cyan
    Write-Host ''

    if (-not (Test-Path $fullPath)) {
        Write-Host "  [SKIP] Script not found: $($Step.ScriptPath)" -ForegroundColor Yellow
        $Step.Status = 'SKIP'
        Update-SessionStep -Index $Step.Index -Status 'SKIP' -ExitCode $null `
            -Verdict 'WARN' -VerdictReason 'Step was skipped — script missing'
        Save-Session
        Write-Host ''
        Write-Host '  Press any key to return to menu...' -ForegroundColor DarkGray
        $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
        return
    }

    Write-Host "  $('─' * 62)" -ForegroundColor DarkGray
    Write-Host ''

    $global:LASTEXITCODE = 0 # Reset engine exit code (a plain assignment here would create a function-local shadow)
    $exitCode = 0
    $stepStart = Get-Date # Freshness gate: only report JSON written by THIS run counts
    try {
        & $fullPath
        $exitCode = if ($null -ne $global:LASTEXITCODE) { $global:LASTEXITCODE } else { 0 }
    } catch {
        Write-Host ''
        Write-Host "  [FAIL] Unhandled error: $_" -ForegroundColor Red
        Write-ErrorLog "Step $($Step.Index) ($($Step.DisplayName)) threw: $_"
        $exitCode = -1
    }

    Write-Host ''
    Write-Host "  $('─' * 62)" -ForegroundColor DarkGray
    Write-Host ''

    if ($exitCode -eq 0) {
        $Step.Status = 'DONE'
        Write-Host '  [DONE] Completed.' -ForegroundColor White
    } else {
        $Step.Status = 'FAIL'
        Write-Host "  [FAIL] Exited with code $exitCode — review output above." -ForegroundColor Red
    }

    # Read JSON and derive verdict for single-step runs. A report left over from a
    # previous run cannot describe THIS run — only trust files written after stepStart.
    $scriptBaseName = [System.IO.Path]::GetFileNameWithoutExtension($Step.ScriptPath)
    $jsonPath = Join-Path $LogDir "$scriptBaseName-Report.json"
    $stepVerdict = $null; $stepVerdictReason = $null
    if ((Test-Path $jsonPath) -and ((Get-Item $jsonPath).LastWriteTime -ge $stepStart)) {
        try {
            $parsed = Get-Content $jsonPath -Raw | ConvertFrom-Json
            $vResult = Get-StepVerdict -Parsed $parsed -ScriptFile $Step.ScriptPath -Status $Step.Status
            $stepVerdict = $vResult.Verdict
            $stepVerdictReason = $vResult.Reason
        } catch { }
    }
    if (-not $stepVerdict) { $stepVerdict = if ($exitCode -eq 0) { 'PASS' } else { 'FAIL' } }

    Update-SessionStep -Index $Step.Index -Status $Step.Status -ExitCode $exitCode -Verdict $stepVerdict -VerdictReason $stepVerdictReason
    Save-Session

    Write-Host ''
    Write-Host '  Press any key to return to menu...' -ForegroundColor DarkGray
    $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
}

#endregion

#region --- Run Engine ---

function Invoke-RunSteps { # Executes batch of steps and collects results
    param(
        [PSCustomObject[]]$StepsToRun, # Steps to execute
        [string]$RunLabel, # Run mode label (e.g., 'Quick Check')
        [string]$RunSub # Subtitle description
    )

    $total      = $StepsToRun.Count # Total steps in run
    $counts     = @{ DONE = 0; FAIL = 0; SKIP = 0 } # Result counters
    $runResults = [System.Collections.Generic.List[PSCustomObject]]::new() # Collect all results

    Write-RunHeader -Title $RunLabel -Sub $RunSub -StepCount $total

    $i = 0 # Step counter
    foreach ($step in $StepsToRun) {
        $i++ # Increment counter
        Write-StepLine -Num $i -Total $total -Step $step # Display step header

        $result = Invoke-StepCapture -Step $step # Execute step and capture output

        $step.Status = $result.Status # Update step status
        Update-SessionStep -Index $step.Index -Status $step.Status -ExitCode $result.ExitCode `
            -Verdict $result.Verdict -VerdictReason $result.VerdictReason
        Save-Session # Persist session state

        switch ($step.Status) {
            'DONE' { $counts.DONE++ }
            'FAIL' { $counts.FAIL++ }
            'SKIP' { $counts.SKIP++ }
        }

        Write-StepResultLine -Result $result

        $runResults.Add([PSCustomObject]@{
            Index         = $step.Index
            Phase         = $step.Phase
            DisplayName   = $step.DisplayName
            ScriptPath    = $step.ScriptPath
            Status        = $result.Status
            Summary       = $result.Summary
            ParsedData    = $result.Parsed
            Elapsed       = $result.Elapsed
            Verdict       = $result.Verdict
            VerdictReason = $result.VerdictReason
        })

        if ($i -lt $total) { Start-Sleep -Seconds 2 }
    }

    $resultArray = $runResults.ToArray() # Convert to array
    Show-RunSummaryInline -Results $resultArray # Display inline summary
    $null = Export-HtmlReport -ResultSet $resultArray -RunLabel $RunLabel # Generate HTML report

    $failedResults = @($runResults | Where-Object { $_.Status -eq 'FAIL' -or $_.Verdict -eq 'FAIL' })
    if ($failedResults.Count -gt 0) {
        $failedSteps = @($failedResults | ForEach-Object {
            $idx = $_.Index
            $script:Steps | Where-Object { $_.Index -eq $idx } | Select-Object -First 1
        } | Where-Object { $_ })
        Write-Host ''
        Write-Host -NoNewline "  Re-run $($failedSteps.Count) failed step(s)?  " -ForegroundColor Yellow
        Write-Host -NoNewline '[Y] Yes    [N] No  ' -ForegroundColor DarkCyan
        $rerunKey = Read-MenuKey
        Write-Host ''
        if ($rerunKey -eq 'Y') {
            $null = Invoke-RunSteps -StepsToRun $failedSteps `
                -RunLabel "Retry — $($failedSteps.Count) step(s)" `
                -RunSub 'Re-run of failed steps'
            return $resultArray
        }
    }

    Write-Host ''
    Write-Host '  Press any key to return to menu...' -ForegroundColor DarkGray
    $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')

    return $resultArray # Return results
}
