#Requires -Version 7.5
Set-StrictMode -Version Latest

<#
.SYNOPSIS
    End-to-end pipeline smoke test: crawl → ignore → ingest → colonel(file-read).

.DESCRIPTION
    The harness plays admiral (build-against-absent-admiral rule — see
    issues/v3/admiral-orchestration.md): it sequences the stages and mediates
    hand-offs exactly as admiral will, exercising the ItemDescriptor identity
    contract across every boundary:

      1. Crawler stamps identity at walk time
      2. Ignore consumes RelativePath as a pure filter (sentinel .gitignore,
         extension blacklist, no enrichment)
      3. Invoke-Ingest dispatches descriptor OBJECTS to colonel (the seam that
         was broken when Items were bare path strings)
      4. file-read copy-on-enriches — all identity fields (incl. LastWriteUtc)
         survive to Results; NUL-content guard _ChainHalts with ReadError

.NOTES
    Run from any directory:
        & "$PSScriptRoot\pipeline.smoke.tests.ps1"
#>

$v3 = Join-Path $PSScriptRoot '..\reposnapshot-v3'

# ---------------------------------------------------------------------------
# Minimal assertion framework (house pattern — see colonel-dispatch.tests.ps1)
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
# Fixture
# ---------------------------------------------------------------------------
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) "rs-pipeline-smoke-$([guid]::NewGuid().ToString('N').Substring(0,8))"
New-Item -ItemType Directory -Path (Join-Path $fixtureRoot 'sub') -Force | Out-Null
Set-Content -Path (Join-Path $fixtureRoot '.gitignore')     -Value '*.log'
Set-Content -Path (Join-Path $fixtureRoot 'keep.ps1')       -Value 'Write-Host "kept"'
Set-Content -Path (Join-Path $fixtureRoot 'noise.log')      -Value 'should be gitignored'
Set-Content -Path (Join-Path $fixtureRoot 'sub/nested.ps1') -Value '$x = 42'
[IO.File]::WriteAllBytes((Join-Path $fixtureRoot 'data.txt'), [byte[]](72, 105, 0, 33))   # NUL → binary halt
[IO.File]::WriteAllBytes((Join-Path $fixtureRoot 'image.png'), [byte[]](137, 80, 78, 71)) # ext-blacklisted

try
{
    # -----------------------------------------------------------------------
    Enter-Section '1. Stage modules import (admiral load-order responsibility)'
    # -----------------------------------------------------------------------
    Import-Module (Join-Path $v3 'rs.core.crawler.psm1') -Force
    Import-Module (Join-Path $v3 'rs.core.membrane.psm1') -Force
    Import-Module (Join-Path $v3 'rs.core.colonel.v2.psm1') -Force
    Import-Module (Join-Path $v3 'rs.core.ingest.psm1') -Force
    Assert-True ($null -ne (Get-Command Invoke-Ingest -ErrorAction SilentlyContinue)) 'all stage modules loaded'

    # -----------------------------------------------------------------------
    Enter-Section '2. Crawl (identity stamped at walk time)'
    # -----------------------------------------------------------------------
    $crawl = (New-FileSystemCrawler -RootPath $fixtureRoot).Invoke()
    Assert-True ($crawl.FileCount -eq 6) 'crawler sees all 6 files' "got $($crawl.FileCount)"

    # -----------------------------------------------------------------------
    Enter-Section '3. Ignore (pure filter over crawler identity)'
    # -----------------------------------------------------------------------
    $compiled = New-GlobCompiler -CrawlerGraph $crawl.Graph
    Assert-True (@($compiled.SentinelIgnoreFiles).Count -eq 1) '.gitignore discovered as sentinel'

    $filtered = Invoke-Membrane -CompiledNodes $compiled.CompiledNodes -CrawlerGraph $crawl.Graph
    $survivors = @($filtered.Graph.Values | ForEach-Object { $_.Files } | ForEach-Object { $_.RelativePath })
    Assert-True ($survivors.Count -eq 3) '3 survivors after sentinel+gitignore+extension filters' "got: $($survivors -join ', ')"
    Assert-True ($survivors -contains 'keep.ps1' -and $survivors -contains 'sub/nested.ps1' -and $survivors -contains 'data.txt') `
        'survivors are keep.ps1, sub/nested.ps1, data.txt'
    Assert-True ($survivors -notcontains 'noise.log') 'noise.log gitignored'
    Assert-True (@($filtered.Skipped | Where-Object { $_.Reason -eq 'ExtensionBlacklisted' }).Count -eq 1) `
        'image.png skipped by extension blacklist'

    # -----------------------------------------------------------------------
    Enter-Section '4. Ingest → colonel (descriptor objects, not strings — the seam)'
    # -----------------------------------------------------------------------
    $ingest = Invoke-Ingest -FilteredFsGraph $filtered `
        -Manifest @{ 'file-read' = (Join-Path $v3 'processors\file-read.ps1') } `
        -Steps @(@{ Key = 'file-read'; Config = @{} }) `
        -ChainExecutorPath (Join-Path $v3 'processors\chain-executor.ps1') `
        -SharedHelperPath (Join-Path $v3 'processors\bag-helpers.ps1')

    Assert-True (@($ingest.Errors).Count -eq 0) 'no compile/dispatch errors' ($ingest.Errors -join '; ')
    Assert-True (@($ingest.Results).Count -eq 3) 'Results count = 3 eligible items' "got $(@($ingest.Results).Count)"
    Assert-True (@($ingest.Skipped | Where-Object { $_.Reason -eq 'ExtensionBlacklisted' }).Count -eq 1) `
        'ignore-stage skips merged into ingest Skipped'

    # -----------------------------------------------------------------------
    Enter-Section '4b. Param forwarding routes to the right colonel function'
    # -----------------------------------------------------------------------
    # Regression (2026-08-04): the compile splat withheld a HARDCODED
    # @('Items','Plan'), so every other Invoke-Plan-only param fell through into
    # Compile-Plan, which rejects unknown names. The failure surfaced from
    # INSIDE the body — "A parameter cannot be found that matches parameter name
    # 'MaxWorkers'" — not from ingest's own binder, and only on a graph with
    # files (the count-0 early return fires before the routing lines, which is
    # why an empty-graph probe reports success and hides it). Both splats now
    # withhold the sibling command's surface by reflection.
    foreach ($dispatchOnly in @(
            @{ Name = 'MaxWorkers'; Value = 1 }
            @{ Name = 'ReservedCores'; Value = 0 }
            @{ Name = 'MinItemsPerWorker'; Value = 1 }
            @{ Name = 'WaitTimeoutMs'; Value = 60000 }
        ))
    {
        $splat = @{
            FilteredFsGraph   = $filtered
            Manifest          = @{ 'file-read' = (Join-Path $v3 'processors\file-read.ps1') }
            Steps             = @(@{ Key = 'file-read'; Config = @{} })
            ChainExecutorPath = (Join-Path $v3 'processors\chain-executor.ps1')
            SharedHelperPath  = (Join-Path $v3 'processors\bag-helpers.ps1')
            $dispatchOnly.Name = $dispatchOnly.Value
        }
        $threw = $null
        try { $r = Invoke-Ingest @splat } catch { $threw = $_.Exception.Message }
        Assert-True ($null -eq $threw) "dispatch-only param forwards without reaching Compile-Plan: $($dispatchOnly.Name)" $threw
        if ($null -eq $threw)
        {
            Assert-True (@($r.Results).Count -eq 3) "$($dispatchOnly.Name): pipeline still produced 3 results"
        }
    }

    # A compile-side param still reaches Compile-Plan (the split cuts both ways).
    $issRun = Invoke-Ingest -FilteredFsGraph $filtered `
        -Manifest @{ 'file-read' = (Join-Path $v3 'processors\file-read.ps1') } `
        -Steps @(@{ Key = 'file-read'; Config = @{} }) `
        -ChainExecutorPath (Join-Path $v3 'processors\chain-executor.ps1') `
        -SharedHelperPath (Join-Path $v3 'processors\bag-helpers.ps1') `
        -IssPreset 'Core' -MaxWorkers 1
    Assert-True (@($issRun.Errors).Count -eq 0) 'compile-side and dispatch-side params coexist in one call' ($issRun.Errors -join '; ')
    Assert-True ($issRun.Budget.Threads -eq 1) 'dispatch-side value actually took effect (Threads = 1)'

    # -----------------------------------------------------------------------
    Enter-Section '5. Results carry the full identity contract + enrichment'
    # -----------------------------------------------------------------------
    $byRel = @{}
    foreach ($r in $ingest.Results) { if ($null -ne $r) { $byRel[$r.RelativePath] = $r } }
    Assert-True ($byRel.Count -eq 3) 'all results addressable by RelativePath'

    $kept = $byRel['keep.ps1']
    foreach ($field in @('AbsolutePath', 'RelativePath', 'NodePath', 'SizeBytes', 'LastWriteUtc'))
    {
        Assert-True ($null -ne $kept.PSObject.Properties[$field]) "identity survives chain: $field"
    }
    Assert-True ($kept.LastWriteUtc -is [datetime]) 'LastWriteUtc still [datetime] after copy-on-enrich'
    Assert-True ($kept.Content -match 'kept') 'keep.ps1 Content read'
    Assert-True ($byRel['sub/nested.ps1'].Content -match '42') 'nested.ps1 Content read'
    Assert-True ($byRel['sub/nested.ps1'].NodePath -eq 'sub/') 'nested NodePath intact'

    $binary = $byRel['data.txt']
    Assert-True ($binary.ReadError -eq 'BinaryOrNulContent') 'NUL file halts with ReadError'
    Assert-True ($null -ne $binary.PSObject.Properties['_ChainHalt']) 'NUL file carries _ChainHalt'
    Assert-True ($null -eq $binary.PSObject.Properties['Content']) 'NUL file has no Content property'
}
catch
{
    # A terminating error inside the try block — a StrictMode property access, a
    # parameter-binding failure — would otherwise abort the suite SILENTLY:
    # finally runs, execution resumes after the block, and the summary prints a
    # PASSING count while the remaining asserts never ran. That mode is invisible
    # from outside (tests/run-all.ps1 cannot detect it — the counts are
    # self-consistent), so it has to be caught HERE.
    Assert-True $false "SUITE ABORTED: $($_.Exception.Message)" $_.ScriptStackTrace
}
finally
{
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
Write-Host "`n═══ pipeline.smoke: $script:Passed passed, $script:Failed failed ═══" -ForegroundColor $(if ($script:Failed -eq 0) { 'Green' } else { 'Red' })
if ($script:Failed -gt 0) { exit 1 }
