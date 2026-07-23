#Requires -Version 7.6
Set-StrictMode -Version Latest

<#
.SYNOPSIS
    Formal test harness for rs.core.colonel.psm1.

.DESCRIPTION
    Covers:
      1. Module import and class availability
      2. ApplyAll serial dispatch — result envelope shape
      3. ApplyAll parallel dispatch — output identical to serial
      4. KeyMatch dispatch — per-item processor resolution
      5. ResultMode: Ordered / Unordered / None
      6. Capability mismatch — unknown processor key lands in Errors, no throw
      7. ISS preset matrix — Bare / Core / Full all load processor without ParameterBindingException

    Processor under test: tp-generic (whitespace normalizer) — used because it
    is the simplest processor with no external dependencies. rs-psstrip unit
    tests are in rs-psstrip.tests.ps1.

.NOTES
    Run from any directory:
        & "$PSScriptRoot\colonel.tests.ps1"

    All paths are resolved via $PSScriptRoot — no hardcoded absolutes.
    Existing files under .tests/ are informational only; this file is the canon harness.
#>

$colonelPath = Join-Path $PSScriptRoot '..\rs.core.colonel.psm1'
$tpGenericPath = Join-Path $PSScriptRoot '..\processors\format.ps1'

# ---------------------------------------------------------------------------
# Minimal assertion framework
# ---------------------------------------------------------------------------
$script:Passed = 0
$script:Failed = 0
$script:Section = ''

function Enter-Section ([string]$Name)
{
    $script:Section = $Name
    Write-Host "`n── $Name" -ForegroundColor Cyan
}

function Assert-True ([bool]$Condition, [string]$Label, [string]$Detail = '')
{
    if ($Condition)
    {
        $script:Passed++
        Write-Host "    PASS  $Label" -ForegroundColor Green
    }
    else
    {
        $script:Failed++
        $msg = "    FAIL  $Label"
        if ($Detail) { $msg += "  ($Detail)" }
        Write-Host $msg -ForegroundColor Red
    }
}

function Assert-Equal ($Actual, $Expected, [string]$Label)
{
    Assert-True ($Actual -eq $Expected) $Label "expected '$Expected', got '$Actual'"
}

function Assert-Contains ($Collection, $Value, [string]$Label)
{
    Assert-True ($Value -in $Collection) $Label "value '$Value' not found in collection"
}

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------
Write-Host '============================================================' -ForegroundColor Yellow
Write-Host ' colonel.tests.ps1' -ForegroundColor Yellow
Write-Host '============================================================' -ForegroundColor Yellow

Import-Module (Resolve-Path $colonelPath).Path -Force

# Shared test items — plain text, no PS syntax needed since tp-generic is language-agnostic
$item1 = [pscustomobject]@{ Id = 'a'; Path = 'a.txt'; Text = "hello   world`r`n" }
$item2 = [pscustomobject]@{ Id = 'b'; Path = 'b.txt'; Text = "  foo   bar  `r`n" }
$item3 = [pscustomobject]@{ Id = 'c'; Path = 'c.txt'; Text = "line1`r`nline2`r`n" }
$items = @($item1, $item2, $item3)

# ============================================================
# 1. Module import
# ============================================================
Enter-Section '1. Module import'

Assert-True ($null -ne (Get-Command 'New-RunspaceManager' -ErrorAction SilentlyContinue)) `
    'New-RunspaceManager is exported'
Assert-True ([RunMode].IsEnum) 'RunMode enum is accessible'
Assert-True ([ResultMode].IsEnum) 'ResultMode enum is accessible'
Assert-True ([IssPreset].IsEnum) 'IssPreset enum is accessible'

# ============================================================
# 2. ApplyAll serial dispatch — result envelope shape
# ============================================================
Enter-Section '2. ApplyAll serial (envelope shape)'

$run = (New-RunspaceManager -Config @{ Operations = @('lf', 'trim-trailing') }).
SetResultMode('Ordered').
Initialize(@{ 'tp-generic' = $tpGenericPath }).
Run($items, 'tp-generic')

Assert-True ($null -ne $run) 'Run() returns a value'
Assert-True ($run.PSObject.Properties['Results']) 'Envelope has Results property'
Assert-True ($run.PSObject.Properties['Errors']) 'Envelope has Errors property'
Assert-True ($run.PSObject.Properties['Warnings']) 'Envelope has Warnings property'
Assert-True ($run.PSObject.Properties['Timing']) 'Envelope has Timing property'
Assert-Equal $run.Results.Count 3 'Results.Count matches item count'
Assert-Equal $run.Errors.Count 0 'No errors on clean run'

# Verify lf op ran — CRLF should be gone
Assert-True ($run.Results[0].Text -notmatch "`r") 'Results[0]: CRLF normalized'
Assert-True ($run.Results[1].Text -notmatch "`r") 'Results[1]: CRLF normalized'
Assert-Equal $run.Results[0].Processor 'tp-generic' 'Results[0].Processor field set'

# ============================================================
# 3. ApplyAll parallel — same output as serial
# ============================================================
Enter-Section '3. ApplyAll parallel (regression vs serial)'

$runP = (New-RunspaceManager -Config @{ Operations = @('lf', 'trim-trailing') } -WorkerCount 2).
SetResultMode('Ordered').
Initialize(@{ 'tp-generic' = $tpGenericPath }).
Run($items, 'tp-generic')

Assert-Equal $runP.Errors.Count 0 'Parallel: no errors'
Assert-Equal $runP.Results.Count 3 'Parallel: Results.Count matches'

for ($i = 0; $i -lt $items.Count; $i++)
{
    Assert-Equal $runP.Results[$i].Text $run.Results[$i].Text "Parallel Results[$i].Text matches serial"
}

# ============================================================
# 4. KeyMatch dispatch
# ============================================================
Enter-Section '4. KeyMatch dispatch'

# Items carry a Type property; processor resolution driven by that property
$kmItems = @(
    [pscustomobject]@{ Id = 'x'; Path = 'x.txt'; Text = "hello   world`r`n"; Type = 'tp-generic' }
    [pscustomobject]@{ Id = 'y'; Path = 'y.txt'; Text = "foo   bar`r`n"; Type = 'tp-generic' }
)

$runKM = (New-RunspaceManager -Config @{ Operations = @('lf') }).
SetResultMode('Ordered').
Initialize(@{ 'tp-generic' = $tpGenericPath }).
Run($kmItems, [RunMode]::KeyMatch, 'Type')

Assert-Equal $runKM.Errors.Count 0 'KeyMatch: no errors'
Assert-Equal $runKM.Results.Count 2 'KeyMatch: Results.Count matches'
Assert-True ($runKM.Results[0].Text -notmatch "`r") 'KeyMatch Results[0]: lf applied'

# ============================================================
# 5. ResultMode: Unordered and None
# ============================================================
Enter-Section '5. ResultMode variants'

$runUnordered = (New-RunspaceManager -Config @{ Operations = @('lf') }).
SetResultMode('Unordered').
Initialize(@{ 'tp-generic' = $tpGenericPath }).
Run($items, 'tp-generic')

Assert-True ($null -ne $runUnordered) 'Unordered: run completes'
Assert-Equal $runUnordered.Errors.Count 0 'Unordered: no errors'
Assert-True ($runUnordered.Results.Count -gt 0) 'Unordered: Results non-empty'

$runNone = (New-RunspaceManager -Config @{ Operations = @('lf') }).
SetResultMode('None').
Initialize(@{ 'tp-generic' = $tpGenericPath }).
Run($items, 'tp-generic')

Assert-True ($null -ne $runNone) 'None: run completes'
Assert-Equal $runNone.Errors.Count 0 'None: no errors'
Assert-True ($null -eq $runNone.Results -or $runNone.Results.Count -eq 0) 'None: Results empty/null'

# ============================================================
# 6. Capability mismatch — unknown processor key
# ============================================================
Enter-Section '6. Capability mismatch (unknown processor key)'

# ApplyAll with a key that was never registered
$runMiss = (New-RunspaceManager -Config @{}).
SetResultMode('Ordered').
Initialize(@{ 'tp-generic' = $tpGenericPath }).
Run($items, 'not-a-processor')

Assert-True ($null -ne $runMiss) 'Mismatch: run completes without throw'
Assert-True ($runMiss.Errors.Count -gt 0) 'Mismatch: error recorded in Errors'

# KeyMatch with an item whose property value has no registered processor
$kmMissItems = @(
    [pscustomobject]@{ Id = 'z'; Path = 'z.txt'; Text = 'test'; Type = 'ghost-processor' }
)

$runKMMiss = (New-RunspaceManager -Config @{}).
SetResultMode('Ordered').
Initialize(@{ 'tp-generic' = $tpGenericPath }).
Run($kmMissItems, [RunMode]::KeyMatch, 'Type')

Assert-True ($null -ne $runKMMiss) 'KeyMatch mismatch: run completes without throw'
Assert-True ($runKMMiss.Errors.Count -gt 0) 'KeyMatch mismatch: error recorded'

# ============================================================
# 7. ISS preset matrix
# ============================================================
Enter-Section '7. ISS preset matrix (Bare / Core / Full)'

foreach ($preset in @('Bare', 'Core', 'Full'))
{
    $runPreset = (New-RunspaceManager -Config @{ Operations = @('lf') }).
    SetIssPreset([IssPreset]::$preset).
    SetResultMode('Ordered').
    Initialize(@{ 'tp-generic' = $tpGenericPath }).
    Run(@($item1), 'tp-generic')

    Assert-Equal $runPreset.Errors.Count 0 "ISS $preset : no errors"
    Assert-Equal $runPreset.Results.Count 1 "ISS $preset : result returned"
}

# ============================================================
# Summary
# ============================================================
Write-Host ''
Write-Host '============================================================' -ForegroundColor Yellow
$color = if ($script:Failed -eq 0) { 'Green' } else { 'Red' }
Write-Host "  Passed: $($script:Passed)   Failed: $($script:Failed)" -ForegroundColor $color
Write-Host '============================================================' -ForegroundColor Yellow
