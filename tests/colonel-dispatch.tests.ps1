#Requires -Version 7.5
Set-StrictMode -Version Latest

<#
.SYNOPSIS
    Dispatch-mechanics tests for rs.core.colonel.v2 (Compile-Plan / Invoke-Plan).

.DESCRIPTION
    Successor to the retired v1 harness (colonel.tests.ps1, which targeted the
    removed rs.core.colonel.psm1 ApplyAll/KeyMatch/ResultMode API). Validation
    coverage lives in colonel-validation.tests.ps1; this suite covers the
    dispatch machinery:
      1. Compile-Plan input validation (empty manifest, unreferenced key)
      2. Multi-step chain: ordering (index-stable), enrichment, Config delivery
      3. Serial (MaxWorkers 1) ≡ parallel results; Budget/Timing envelope
      4. _ChainHalt: remaining steps skipped for that item only
      5. Per-item error capture: ErrorBag entry, item returns pre-step state,
         other items unaffected
      6. Empty Items: early-return envelope (AllowEmptyCollection regression)

.NOTES
    Run from any directory:
        & "$PSScriptRoot\colonel-dispatch.tests.ps1"
#>

$v3 = Join-Path $PSScriptRoot '..\reposnapshot-v3'
$chainExec = Join-Path $v3 'processors\chain-executor.ps1'

# ---------------------------------------------------------------------------
# Minimal assertion framework (house pattern)
# ---------------------------------------------------------------------------
$script:Passed = 0
$script:Failed = 0

function Enter-Section ([string]$Name)
{
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

# ---------------------------------------------------------------------------
# Fixture processors
# ---------------------------------------------------------------------------
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) "rs-colonel-disp-$([guid]::NewGuid().ToString('N').Substring(0,8))"
New-Item -ItemType Directory -Path $fixtureRoot | Out-Null

Set-Content -Path (Join-Path $fixtureRoot 'stage1.ps1') -Value @'
param($Item, $Config)
$result = [PSCustomObject]@{}
foreach ($p in $Item.PSObject.Properties)
{
    $result | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value
}
if ($null -ne $result.PSObject.Properties['Boom'] -and $result.Boom) { throw 'stage1 exploded' }
$result | Add-Member -NotePropertyName Stage1 -NotePropertyValue 'ran'
if ($null -ne $result.PSObject.Properties['Halt'] -and $result.Halt)
{
    $result | Add-Member -NotePropertyName _ChainHalt -NotePropertyValue $true
}
return $result
'@

Set-Content -Path (Join-Path $fixtureRoot 'stage2.ps1') -Value @'
param($Item, $Config)
$result = [PSCustomObject]@{}
foreach ($p in $Item.PSObject.Properties)
{
    $result | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value
}
$result | Add-Member -NotePropertyName Stage2 -NotePropertyValue ('ran:' + $Config['Tag'])
return $result
'@

try
{
    Import-Module (Join-Path $v3 'rs.core.colonel.v2.psm1') -Force -WarningAction SilentlyContinue

    $manifest = @{
        'stage1' = (Join-Path $fixtureRoot 'stage1.ps1')
        'stage2' = (Join-Path $fixtureRoot 'stage2.ps1')
    }
    $steps = @(
        @{ Key = 'stage1'; Config = @{} },
        @{ Key = 'stage2'; Config = @{ Tag = 'cfg' } }
    )

    # -----------------------------------------------------------------------
    Enter-Section '1. Compile-Plan input validation'
    # -----------------------------------------------------------------------
    $cEmpty = Compile-Plan -Manifest @{} -Steps $steps -ChainExecutorPath $chainExec
    Assert-True (@($cEmpty.Errors).Count -gt 0 -and $null -eq $cEmpty.Plan) 'empty manifest → error, no plan'

    $cMissing = Compile-Plan -Manifest @{ 'stage1' = $manifest['stage1'] } -Steps $steps -ChainExecutorPath $chainExec
    Assert-True ((@($cMissing.Errors) -join ' ') -match 'absent from the manifest') 'step key absent from manifest → named error'

    $compiled = Compile-Plan -Manifest $manifest -Steps $steps -ChainExecutorPath $chainExec
    Assert-True (@($compiled.Errors).Count -eq 0 -and $null -ne $compiled.Plan) 'two-step plan compiles clean'

    # -----------------------------------------------------------------------
    Enter-Section '2. Multi-step chain: ordering, enrichment, Config delivery'
    # -----------------------------------------------------------------------
    $items = @(0..23 | ForEach-Object { [pscustomobject]@{ Idx = $_ } })
    $run = Invoke-Plan -Items $items -Plan $compiled.Plan

    Assert-True (@($run.Errors).Count -eq 0) 'dispatch clean' ($run.Errors -join '; ')
    Assert-True (@($run.Results).Count -eq 24) 'all 24 results present'
    $orderOk = $true
    for ($i = 0; $i -lt 24; $i++) { if ($run.Results[$i].Idx -ne $i) { $orderOk = $false; break } }
    Assert-True $orderOk 'results are index-stable (Results[i].Idx == i)'
    Assert-True ($run.Results[7].Stage1 -eq 'ran' -and $run.Results[7].Stage2 -eq 'ran:cfg') 'both stages ran; per-step Config delivered'

    # -----------------------------------------------------------------------
    Enter-Section '3. Serial ≡ parallel; Budget/Timing envelope'
    # -----------------------------------------------------------------------
    $serial = Invoke-Plan -Items $items -Plan $compiled.Plan -MaxWorkers 1
    $parallel = Invoke-Plan -Items $items -Plan $compiled.Plan -MaxWorkers 4 -MinItemsPerWorker 1

    Assert-True ($parallel.Budget.Threads -gt 1) 'parallel run used multiple workers' "threads=$($parallel.Budget.Threads)"
    Assert-True ($serial.Budget.Threads -eq 1) 'serial run used one worker'
    $same = $true
    for ($i = 0; $i -lt 24; $i++)
    {
        if ($serial.Results[$i].Idx -ne $parallel.Results[$i].Idx -or
            $serial.Results[$i].Stage2 -ne $parallel.Results[$i].Stage2) { $same = $false; break }
    }
    Assert-True $same 'serial and parallel results identical (order + content)'
    Assert-True ($run.Timing.TotalMs -ge 0 -and $null -ne $run.Budget) 'Budget + Timing present on envelope'

    # -----------------------------------------------------------------------
    Enter-Section '4. _ChainHalt skips remaining steps for that item only'
    # -----------------------------------------------------------------------
    $haltItems = @(
        [pscustomobject]@{ Idx = 0 },
        [pscustomobject]@{ Idx = 1; Halt = $true },
        [pscustomobject]@{ Idx = 2 }
    )
    $haltRun = Invoke-Plan -Items $haltItems -Plan $compiled.Plan
    Assert-True (@($haltRun.Errors).Count -eq 0) 'halt is not an error'
    Assert-True ($haltRun.Results[1].Stage1 -eq 'ran') 'halted item completed the halting step'
    Assert-True ($null -ne $haltRun.Results[1].PSObject.Properties['_ChainHalt']) 'halted item carries _ChainHalt'
    Assert-True ($null -eq $haltRun.Results[1].PSObject.Properties['Stage2']) 'halted item skipped stage2'
    Assert-True ($haltRun.Results[0].Stage2 -eq 'ran:cfg' -and $haltRun.Results[2].Stage2 -eq 'ran:cfg') 'neighbors unaffected'

    # -----------------------------------------------------------------------
    Enter-Section '5. Per-item error capture'
    # -----------------------------------------------------------------------
    $boomItems = @(
        [pscustomobject]@{ Idx = 0 },
        [pscustomobject]@{ Idx = 1; Boom = $true },
        [pscustomobject]@{ Idx = 2 }
    )
    $boomRun = Invoke-Plan -Items $boomItems -Plan $compiled.Plan
    Assert-True ((@($boomRun.Errors) -join ' ') -match "Item \[1\] step 'stage1'") 'error names item index and step key'
    Assert-True ($null -eq $boomRun.Results[1].PSObject.Properties['Stage1']) 'failed item returned pre-step state'
    Assert-True ($boomRun.Results[0].Stage2 -eq 'ran:cfg' -and $boomRun.Results[2].Stage2 -eq 'ran:cfg') 'other items completed normally'

    # -----------------------------------------------------------------------
    Enter-Section '6. Empty Items — early-return envelope'
    # -----------------------------------------------------------------------
    $empty = Invoke-Plan -Items @() -Plan $compiled.Plan
    Assert-True (@($empty.Results).Count -eq 0 -and @($empty.Errors).Count -eq 0) `
        'empty Items binds (AllowEmptyCollection) and returns clean empty envelope'
}
finally
{
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
Write-Host "`n═══ colonel-dispatch: $script:Passed passed, $script:Failed failed ═══" -ForegroundColor $(if ($script:Failed -eq 0) { 'Green' } else { 'Red' })
if ($script:Failed -gt 0) { exit 1 }
