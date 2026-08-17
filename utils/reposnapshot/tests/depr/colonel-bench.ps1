#Requires -Version 7.5
using namespace System.Diagnostics
<#
.SYNOPSIS
    Benchmarks rs.core.colonel — init time + run time across varying file counts.

.PARAMETER CorpusPath
    Directory to read source files from.
    Default: .discussion/github-stroll-files (34 .md files).

.PARAMETER Filter
    Glob filter for Get-ChildItem within CorpusPath.  Default: *.md

.PARAMETER Processor
    Key name for the processor.  Default: format

.PARAMETER ProcessorPath
    Path to the processor script.
    Default: ../processors/format.ps1 (relative to this file)

.PARAMETER FileCounts
    Array of item counts to sweep in the run benchmark.
    Default: 1,3,5,10,20 and the full corpus size.

.PARAMETER InitIterations
    Number of init benchmark iterations.  Default: 5

.PARAMETER RunIterations
    Number of run benchmark iterations per file-count step.  Default: 3

.PARAMETER TestName
    Short label for the run, used in the results directory name (e.g. 'rs-psstrip').
    Required when -Export is specified.

.PARAMETER Export
    Writes processed file output to
    tests/results-temp/{callerScript}_{testName}_{timestamp}/

.EXAMPLE
    # Default stroll-corpus benchmark
    .\colonel-bench.ps1

.EXAMPLE
    # Run rs-psstrip against test-cases and export results
    .\colonel-bench.ps1 `
        -CorpusPath    .\test-cases `
        -Filter        '*.ps1' `
        -Processor     'rs-psstrip' `
        -ProcessorPath ..\processors\rs-psstrip.ps1 `
        -FileCounts    @(1, 2) `
        -TestName      'rs-psstrip' `
        -Export
#>
param(
    [string] $CorpusPath = 'C:/Users/azrie/PDenv/UserGithub/PowerShellCore/.discussion/github-stroll-files',
    [string] $Filter = '*.md',
    [string] $Processor = 'format',
    [string] $ProcessorPath = "$PSScriptRoot/../processors/format.ps1",
    [int[]]  $FileCounts = @(),
    [int]    $InitIterations = 5,
    [int]    $RunIterations = 3,
    [string] $TestName = '',
    [switch] $Export
)

if ($Export -and -not $TestName)
{
    Write-Error '-TestName is required when -Export is specified.'
    exit 1
}

$ColonelPath = "$PSScriptRoot/../rs.core.colonel.psm1"

# ── Export helper ─────────────────────────────────────────────────────────────
function Write-BenchResults
{
    param([object[]]$Results, [string]$TestName)
    $callerScript = [System.IO.Path]::GetFileNameWithoutExtension($PSCommandPath)
    $timestamp = (Get-Date).ToString('yyyyMMdd_HHmmss')
    $dirName = '{0}_{1}_{2}' -f $callerScript, $TestName, $timestamp
    $outDir = Join-Path $PSScriptRoot "results-temp/$dirName"
    $null = New-Item -ItemType Directory -Path $outDir -Force

    foreach ($r in $Results)
    {
        if ($null -eq $r) { continue }
        $text = if ($r -is [string]) { $r }
        elseif ($null -ne $r.PSObject.Properties['Text']) { $r.Text }
        else { $r | Out-String }
        $name = if ($null -ne $r.PSObject.Properties['Id'] -and $r.Id) { $r.Id }
        else { [System.IO.Path]::GetFileName($r.Path) }
        if (-not $name) { $name = 'item.txt' }
        [System.IO.File]::WriteAllText((Join-Path $outDir $name), $text)
    }

    Write-Host "  Exported $($Results.Count) file(s) → $outDir" -ForegroundColor Cyan
    return $outDir
}

# ── Benchmark helper ──────────────────────────────────────────────────────────
function Measure-Runs
{
    param([scriptblock]$Sb, [int]$Iterations = 3)
    $times = 1..$Iterations | ForEach-Object {
        $sw = [Stopwatch]::StartNew()
        $result = & $Sb
        $sw.Stop()
        [pscustomobject]@{ Ms = $sw.ElapsedMilliseconds; Result = $result }
    }
    [pscustomobject]@{
        MinMs = ($times | Measure-Object Ms -Minimum).Minimum
        AvgMs = [math]::Round(($times | Measure-Object Ms -Average).Average, 0)
        MaxMs = ($times | Measure-Object Ms -Maximum).Maximum
        Last  = $times[-1].Result
    }
}

Import-Module $ColonelPath -Force

# ── Pre-read corpus into memory (isolate I/O from colonel timing) ─────────────
$allItems = @(
    Get-ChildItem -LiteralPath $CorpusPath -Filter $Filter |
    Sort-Object Length |
    ForEach-Object {
        [pscustomobject]@{
            Id   = $_.Name
            Path = $_.FullName
            Text = [System.IO.File]::ReadAllText($_.FullName)
        }
    }
)

if ($allItems.Count -eq 0)
{
    Write-Error "No files matching '$Filter' found in '$CorpusPath'."
    exit 1
}

Write-Host "`nCorpus    : $($allItems.Count) files  ($Filter  ←  $CorpusPath)" -ForegroundColor Cyan
Write-Host "Total     : $([math]::Round(($allItems | Measure-Object -Property { $_.Text.Length } -Sum).Sum / 1KB, 0)) KB" -ForegroundColor Cyan
Write-Host "Processor : $Processor  ($ProcessorPath)`n" -ForegroundColor Cyan

$manifest = @{ $Processor = $ProcessorPath }

# Derive sweep counts: honour param if supplied, otherwise default sweep capped at corpus
if ($FileCounts.Count -eq 0)
{
    $defaults = @(1, 3, 5, 10, 20)
    $FileCounts = @(@($defaults | Where-Object { $_ -lt $allItems.Count }) + @($allItems.Count) | Select-Object -Unique)
}

# ─────────────────────────────────────────────────────────────────────────────
# 1. INIT BENCHMARK
# ─────────────────────────────────────────────────────────────────────────────
Write-Host '━━━ INIT (LoadProcessorsFromManifest) ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━' -ForegroundColor Yellow

$initBench = Measure-Runs -Iterations $InitIterations {
    $mgr = New-RunspaceManager
    $mgr.Initialize($manifest) | Out-Null
    $mgr
}

Write-Host ("  min={0}ms  avg={1}ms  max={2}ms  ({3} iterations)" -f
    $initBench.MinMs, $initBench.AvgMs, $initBench.MaxMs, $InitIterations) -ForegroundColor Green
Write-Host ("  Processors loaded: {0}" -f $initBench.Last.ProcessorManifest.Count)
Write-Host ("  Warnings: {0}`n" -f $initBench.Last.LifetimeWarnings.Count)

# ─────────────────────────────────────────────────────────────────────────────
# 2. RUN BENCHMARK
# ─────────────────────────────────────────────────────────────────────────────
Write-Host ("━━━ RUN ({0}, {1} iterations each) ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -f $Processor, $RunIterations) -ForegroundColor Yellow
Write-Host ('{0,-6} {1,-8} {2,-8} {3,-8} {4,-8} {5,-10} {6}' -f
    'Files', 'MinMs', 'AvgMs', 'MaxMs', 'Threads', 'Path', 'BudgetDetail') -ForegroundColor Cyan
Write-Host ('-' * 75)

$mgr = New-RunspaceManager -Config @{ IncludeMeta = $false }
$mgr.Initialize($manifest) | Out-Null

$lastRunResult = $null

foreach ($n in $FileCounts)
{
    $items = [object[]]($allItems | Select-Object -First $n)

    $bench = Measure-Runs -Iterations $RunIterations {
        $mgr.Run($items, $Processor)
    }

    $runResult = $bench.Last
    $lastRunResult = $runResult
    $timing = $runResult.Timing
    $budget = $runResult.Budget
    $threads = $budget.Threads

    $path = if ($null -ne $timing.SerialRunspaceOpenMs) { 'Serial' }
    elseif ($null -ne $timing.PoolOpenMs) { 'Pool' }
    else { '?' }

    $pathMs = if ($path -eq 'Serial')
    {
        "rsOpen={0}ms  process={1}ms" -f $timing.SerialRunspaceOpenMs, $timing.SerialProcessMs
    }
    elseif ($path -eq 'Pool')
    {
        "poolOpen={0}ms  dispatch={1}ms" -f $timing.PoolOpenMs, $timing.DispatchMs
    }
    else { '' }

    $budgetDetail = "graded K={0} tau={1}" -f $budget.K, $budget.Tau
    $pathColor = if ($path -eq 'Serial') { 'Green' } else { 'Magenta' }

    Write-Host ('{0,-6} {1,-8} {2,-8} {3,-8} {4,-8}' -f
        $n, $bench.MinMs, $bench.AvgMs, $bench.MaxMs, $threads) -NoNewline
    Write-Host ('{0,-10}' -f $path) -ForegroundColor $pathColor -NoNewline
    Write-Host ('{0}  [{1}]' -f $pathMs, $budgetDetail)
}

# ─────────────────────────────────────────────────────────────────────────────
# 3. CORPUS BREAKDOWN
# ─────────────────────────────────────────────────────────────────────────────
Write-Host ''
Write-Host '━━━ CORPUS BREAKDOWN ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━' -ForegroundColor Yellow
$allItems | ForEach-Object {
    [pscustomobject]@{
        File = $_.Id.Substring(0, [Math]::Min(50, $_.Id.Length))
        KB   = [math]::Round($_.Text.Length / 1KB, 1)
    }
} | Format-Table -AutoSize

# ─────────────────────────────────────────────────────────────────────────────
# 4. OPTIONAL EXPORT
# ─────────────────────────────────────────────────────────────────────────────
if ($Export)
{
    Write-Host '━━━ EXPORT ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━' -ForegroundColor Yellow
    $mgrExport = New-RunspaceManager   # IncludeMeta=$true (default) so Id/Path are in results
    $mgrExport.Initialize($manifest) | Out-Null
    $exportRun = $mgrExport.Run([object[]]$allItems, $Processor)
    Write-BenchResults -Results $exportRun.Results -TestName $TestName
}
