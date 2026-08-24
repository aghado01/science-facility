#Requires -Version 7.5

<#
.SYNOPSIS
    Canonical battery runner — runs every suite and refuses to report a false green.

.DESCRIPTION
    Counting PASS/FAIL lines is not enough to know a suite ran. Two ways a suite
    can stop early while still reading as clean:

      1. A suite wrapped in try{}/finally{} with no catch. A terminating error
         (a StrictMode property access, a parameter-binding failure) aborts the
         try block, finally runs, execution resumes AFTER the block, and the
         summary prints a passing count with asserts that never executed. Every
         suite now has a catch that records the abort as a failure — this runner
         is the backstop for any that regress or are added without one.
      2. A suite with no try at all. The error kills the script before it prints
         a summary, so it contributes zero fails and the total still looks green.

    So completion is verified two ways rather than inferred:
      - the suite must print its summary line (the completion signal), and
      - its self-reported total must match the PASS/FAIL lines actually emitted.

    Anything on the error stream is surfaced too: a suite can pass every assert
    while writing errors, which is worth seeing.

.PARAMETER Filter
    Optional wildcard over suite file names.

.PARAMETER ShowErrors
    Print captured error-stream text for each suite that produced any.

.NOTES
    Exit code 1 if any suite fails, aborts, or fails to complete.
        pwsh -File tests/run-all.ps1
#>
[CmdletBinding()]
param(
    [string] $Filter = '*',
    [switch] $ShowErrors
)

# After param() — a script's param block must precede any statement.
Set-StrictMode -Version Latest

$repoRoot = Split-Path $PSScriptRoot -Parent
$suitePaths = @(
    (Join-Path $PSScriptRoot 'contracts.tests.ps1')
    (Join-Path $PSScriptRoot 'crawler.tests.ps1')
    (Join-Path $PSScriptRoot 'membrane.tests.ps1')
    (Join-Path $PSScriptRoot 'pipeline.smoke.tests.ps1')
    (Join-Path $PSScriptRoot 'colonel-validation.tests.ps1')
    (Join-Path $PSScriptRoot 'colonel-dispatch.tests.ps1')
    (Join-Path $PSScriptRoot 'assemble.tests.ps1')
    (Join-Path $PSScriptRoot 'container.tests.ps1')
    (Join-Path $PSScriptRoot 'container-spec.tests.ps1')
    (Join-Path $PSScriptRoot 'shards-packer.tests.ps1')
    (Join-Path $PSScriptRoot 'shards-plan.tests.ps1')
    (Join-Path $PSScriptRoot 'serialize.tests.ps1')
    (Join-Path $PSScriptRoot 'selfie.tests.ps1')
    (Join-Path $PSScriptRoot 'mutator-chain.tests.ps1')
    (Join-Path $repoRoot 'reposnapshot-v3\processors\tests\rs-whitespace.tests.ps1')
    (Join-Path $repoRoot 'reposnapshot-v3\processors\tests\rs-indent.tests.ps1')
    (Join-Path $repoRoot 'reposnapshot-v3\processors\tests\rs-psstrip.tests.ps1')
    (Join-Path $repoRoot 'reposnapshot-v3\processors\tests\rs-csstrip.tests.ps1')
    (Join-Path $repoRoot 'reposnapshot-v3\processors\tests\rs-content_meta.tests.ps1')
    (Join-Path $repoRoot 'reposnapshot-v3\processors\tests\rs-numerics.tests.ps1')
    (Join-Path $repoRoot 'tools\tests\rs.dev.signatures.tests.ps1')
)

$rows = [System.Collections.Generic.List[pscustomobject]]::new()

foreach ($path in $suitePaths)
{
    $name = Split-Path $path -Leaf
    if ($name -notlike $Filter) { continue }

    if (-not (Test-Path -LiteralPath $path))
    {
        $rows.Add([pscustomobject]@{
                Suite = $name; Passed = 0; Failed = 0; Status = 'MISSING'; Note = $path; Errors = ''
            })
        continue
    }

    # PRE-PARSE before running. A parse error surfaces before invocation, so it
    # never lands in the transcript — the suite simply produces nothing, and a
    # runner that only inspects output has to infer the cause. Parsing first
    # names it exactly, and catches a corrupted suite without executing it.
    $syntaxErrors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$syntaxErrors)
    if ($syntaxErrors.Count -gt 0)
    {
        $rows.Add([pscustomobject]@{
                Suite  = $name; Passed = 0; Failed = 0; Status = 'PARSE-ERROR'
                Note   = "line $($syntaxErrors[0].Extent.StartLineNumber): $($syntaxErrors[0].Message)"
                Errors = ($syntaxErrors | ForEach-Object { $_.Message }) -join "`n"
            })
        continue
    }

    # *>&1, not 2>&1: the suites report via Write-Host, which writes to the
    # INFORMATION stream. Merging only the error stream captures nothing and
    # makes every suite look like it died — merge all streams.
    $errText = ''
    $out = (& $path *>&1) | Out-String

    # Split the transcript from anything that landed on the error stream.
    $lines = $out -split "`r?`n"
    # Anchor to the assert-line FORMAT, not a bare word match. '\bPASS\b' also
    # matches prose like "── 13. Empty Operations — pass-through", because '-'
    # is a word boundary — which is exactly the kind of loose counting this
    # runner exists to stop trusting.
    $emittedPass = @($lines | Where-Object { $_ -match '^\s*(PASS|ok)\s' }).Count
    $emittedFail = @($lines | Where-Object { $_ -match '^\s*FAIL\s' }).Count
    $errText = ($lines | Where-Object { $_ -match 'Exception|cannot be found|is not recognized|ParserError' }) -join "`n"

    # Completion signal: every suite prints a summary. Both house formats.
    $summary = $lines | Where-Object { $_ -match '(?:Passed:\s*(\d+)\s+Failed:\s*(\d+))|(?:═══.*?(\d+) passed, (\d+) failed)|(?:Results:\s*(\d+)/(\d+) passed)' } | Select-Object -Last 1

    $status = 'OK'
    $note = ''
    $reportedPass = $null
    $reportedFail = $null

    # A suite that could not be PARSED never runs at all. Caught first, because
    # a parse error dumps source lines into the transcript and those lines can
    # coincidentally satisfy the summary regex — which is exactly how an earlier
    # version of this runner reported ten corrupted suites as OK.
    $parseErr = @($lines | Where-Object { $_ -match 'ParserError|Unexpected attribute|missing the closing|Missing closing' })
    if ($parseErr.Count -gt 0)
    {
        $status = 'PARSE-ERROR'
        $note = ($parseErr[0].Trim() -replace '\s+', ' ')
    }
    elseif (($emittedPass + $emittedFail) -eq 0)
    {
        # No assert lines at all: the suite did not execute, whatever else the
        # transcript contains. Never infer success from a quiet run.
        $status = 'NO-ASSERTS'
        $note = 'suite emitted no PASS/FAIL lines — it did not run'
    }
    elseif (-not $summary)
    {
        $status = 'NO-SUMMARY'
        $note = 'suite did not reach its summary line — it died mid-run'
    }
    else
    {
        if ($summary -match 'Passed:\s*(\d+)\s+Failed:\s*(\d+)') { $reportedPass = [int]$Matches[1]; $reportedFail = [int]$Matches[2] }
        elseif ($summary -match '(\d+) passed, (\d+) failed') { $reportedPass = [int]$Matches[1]; $reportedFail = [int]$Matches[2] }
        elseif ($summary -match 'Results:\s*(\d+)/(\d+) passed') { $reportedPass = [int]$Matches[1]; $reportedFail = [int]$Matches[2] - [int]$Matches[1] }

        if ($reportedFail -gt 0) { $status = 'FAIL' }

        # Cross-check: the summary's own numbers must match the lines emitted.
        # A mismatch means output was lost or double-counted — do not trust it.
        if ($null -ne $reportedPass -and $reportedPass -ne $emittedPass)
        {
            $status = 'COUNT-MISMATCH'
            $note = "summary says $reportedPass passed, transcript shows $emittedPass"
        }
    }

    $rows.Add([pscustomobject]@{
            Suite  = $name
            Passed = $(if ($null -ne $reportedPass) { $reportedPass } else { $emittedPass })
            Failed = $(if ($null -ne $reportedFail) { $reportedFail } else { $emittedFail })
            Status = $status
            Note   = $note
            Errors = $errText
        })
}

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '════════════════════════════════════════════════════════════════' -ForegroundColor Yellow
foreach ($r in $rows)
{
    $colour = switch ($r.Status) { 'OK' { 'Green' } default { 'Red' } }
    Write-Host ("{0,-6} {1,-32} {2,5} pass {3,4} fail  {4}" -f $r.Status, $r.Suite, $r.Passed, $r.Failed, $r.Note) -ForegroundColor $colour
    if ($ShowErrors -and $r.Errors) { Write-Host ("        " + ($r.Errors -replace "`n", "`n        ")) -ForegroundColor DarkYellow }
}

$totalPass = ($rows | Measure-Object -Property Passed -Sum).Sum
$totalFail = ($rows | Measure-Object -Property Failed -Sum).Sum
$bad = @($rows | Where-Object { $_.Status -ne 'OK' })
$noisy = @($rows | Where-Object { $_.Errors })

Write-Host '────────────────────────────────────────────────────────────────' -ForegroundColor Yellow
Write-Host ("BATTERY: {0} suites · {1} passed · {2} failed" -f $rows.Count, $totalPass, $totalFail) `
    -ForegroundColor $(if ($bad.Count -eq 0) { 'Green' } else { 'Red' })
if ($noisy.Count -gt 0)
{
    Write-Host ("NOTE: {0} suite(s) wrote to the error stream — rerun with -ShowErrors" -f $noisy.Count) -ForegroundColor DarkYellow
}
if ($bad.Count -gt 0)
{
    Write-Host ("NOT GREEN: {0}" -f (($bad | ForEach-Object { "$($_.Suite) [$($_.Status)]" }) -join ', ')) -ForegroundColor Red
}
Write-Host '════════════════════════════════════════════════════════════════' -ForegroundColor Yellow

if ($bad.Count -gt 0) { exit 1 }
