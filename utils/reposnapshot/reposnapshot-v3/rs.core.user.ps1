#Requires -Version 7.5

<#
.SYNOPSIS
    rs.core.user — convenient high-level CLI entry point for RepoSnapshot V3.

.DESCRIPTION
    Runs the full end-to-end v3 pipeline:
      Crawl → Membrane → Ingest → Assemble → Resolve-Layout → New-ShardPlan →
      Invoke-Serialize → New-Manifest

.PARAMETER Root
    The directory to snapshot.
.PARAMETER OutRoot
    Output directory for runstamped snapshot folders (defaults to <Root>/.snapshot).
.PARAMETER SelectionPatterns
    When supplied, membrane runs Selection semantics. Default: Ignore semantics.
.PARAMETER PsStrip
    Applies PowerShell comment stripping (code corpora only).
.PARAMETER Columns
    Active psr wire columns (default: gidx, content_meta).
.PARAMETER Grouping
    Sharding partition mode: 'Flat', 'ByFileType', or 'ByRootDirectory'.
.PARAMETER GroupSort
    Entry sorting strategy within groups: 'PathAsc' or 'PathHash'.
.PARAMETER OrderStrict
    Preserves exact input order during bin packing.
.PARAMETER PackObjective
    Bin distribution shape: 'FrontLoad' (default) or 'Even'.
.PARAMETER ShardQuotaBytes
    Target shard byte limit (default: 32768).
.PARAMETER ShardToleranceBytes
    Allowed shard expansion before creating a new bin (default: 4096).
.PARAMETER MaxFilesPerShard
    Maximum entries per shard (default: 100000).
.PARAMETER PassThru
    Returns the intermediate IR, Layout, Plan, and Receipt objects on the output.

.EXAMPLE
    ./rs.core.user.ps1 -Root ../reposnapshot-v3 -SelectionPatterns '*.ps1','*.psm1' -PsStrip
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path $_ -PathType Container })]
    [string]$Root,
    [string]$OutRoot,
    [string[]]$SelectionPatterns = $null,
    [switch]$PsStrip,
    [string[]]$Columns = @('gidx', 'content_meta'),
    [ValidateSet('Flat', 'ByFileType', 'ByRootDirectory')] [string]$Grouping = 'Flat',
    [ValidateSet('PathAsc', 'PathHash')] [string]$GroupSort = 'PathAsc',
    [switch]$OrderStrict,
    [ValidateSet('FrontLoad', 'Even')] [string]$PackObjective = 'FrontLoad',
    [long]$ShardQuotaBytes = 32768,
    [long]$ShardToleranceBytes = 4096,
    [ValidateRange(1, [int]::MaxValue)] [int]$MaxFilesPerShard = 100000,
    [switch]$PassThru
)

#region ModuleImports
$v3 = $PSScriptRoot
foreach ($m in 'crawler', 'membrane', 'colonel.v2', 'ingest', 'assemble', 'container', 'shards', 'serialize', 'manifest')
{
    Import-Module (Join-Path $v3 "rs.core.$m.psm1") -Force -DisableNameChecking
}
#endregion

#region PathResolution
$rootFull = (Resolve-Path $Root).Path.TrimEnd('\', '/')
$leaf = Split-Path $rootFull -Leaf
if ([string]::IsNullOrEmpty($OutRoot))
{
    $OutRoot = Join-Path $rootFull '.snapshot'
}
$outFull = [IO.Path]::GetFullPath($OutRoot)

$runStamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$outDir = Join-Path $outFull $runStamp
$n = 1
while (Test-Path $outDir) { $n++; $outDir = Join-Path $outFull "${runStamp}_$n" }
$runStamp = Split-Path $outDir -Leaf
#endregion

#region CrawlAndMembrane
$crawl = (New-FileSystemCrawler -RootPath $rootFull).Invoke()
$compiled = if ($null -ne $SelectionPatterns -and $SelectionPatterns.Count -gt 0)
{
    New-GlobCompiler -CrawlerGraph $crawl.Graph -GlobSemantics Selection -SelectionPatterns $SelectionPatterns
}
else
{
    New-GlobCompiler -CrawlerGraph $crawl.Graph
}
$filtered = Invoke-Membrane -CompiledNodes $compiled.CompiledNodes -CrawlerGraph $crawl.Graph
#endregion

#region IngestAndAssemble
$procManifest = @{
    'file-read'     = (Join-Path $v3 'processors\file-read.ps1')
    'rs-whitespace' = (Join-Path $v3 'processors\rs-whitespace.ps1')
}
$steps = [System.Collections.Generic.List[object]]::new()
$steps.Add(@{ Key = 'file-read'; Config = @{} })

if ($PsStrip)
{
    $procManifest['rs-psstrip'] = (Join-Path $v3 'processors\rs-psstrip.ps1')
    $steps.Add(@{ Key = 'rs-psstrip'; Config = @{ Operations = @('block-comments', 'doc-strings', 'comment-blocks', 'line-comments') } })
}
$steps.Add(@{ Key = 'rs-whitespace'; Config = @{} })
if ($Columns -contains 'content_meta')
{
    $procManifest['rs-content_meta'] = (Join-Path $v3 'processors\rs-content_meta.ps1')
    $steps.Add(@{ Key = 'rs-content_meta'; Config = @{} })
}

$ingest = Invoke-Ingest -FilteredFsGraph $filtered -Manifest $procManifest -Steps @($steps) `
    -ChainExecutorPath (Join-Path $v3 'processors\chain-executor.ps1') `
    -SharedHelperPath (Join-Path $v3 'processors\bag-helpers.ps1')
if (@($ingest.Errors).Count -gt 0)
{
    throw "rs.core.user: ingest reported errors — $($ingest.Errors -join '; ')"
}

$runContext = [pscustomobject]@{
    RunStamp         = $runStamp
    Root             = ($rootFull -replace '\\', '/')
    GeneratorVersion = 'reposnapshot-v3'
    ConfigEcho       = [pscustomobject]@{
        GlobSemantics = if ($null -ne $SelectionPatterns) { 'Selection' } else { 'Ignore' }
        Patterns      = $SelectionPatterns
        Chain         = @($steps | ForEach-Object Key)
        Columns       = $Columns
    }
}
$ir = Invoke-Assemble -DispatchOutput $ingest -RunContext $runContext
#endregion

#region ShardAndSerialize
$layout = Resolve-Layout -Header $ir.Header -Columns $Columns
$plan = New-ShardPlan -Entries $ir.Entries -Layout $layout -Grouping $Grouping -GroupSort $GroupSort `
    -OrderStrict:$OrderStrict -PackObjective $PackObjective -ShardQuotaBytes $ShardQuotaBytes `
    -ShardToleranceBytes $ShardToleranceBytes -MaxFilesPerShard $MaxFilesPerShard -ShardStem $leaf

$null = [IO.Directory]::CreateDirectory($outDir)
$receipt = Invoke-Serialize -Plan $plan -Entries $ir.Entries -Layout $layout -OutDir $outDir
$treePath = Join-Path $outDir "${leaf}_tree.md"
$null = New-Manifest -Receipt $receipt -Shards $plan.Shards -Plan $plan.Plan -Layout $layout `
    -RunContext $runContext -TreePath $treePath
#endregion

#region Output
Write-Host "reposnapshot: $($ir.Header.EntryCount) entries → $($receipt.ShardCount) shards, $($receipt.TotalBytes) bytes" -ForegroundColor Green
Write-Host "  $outDir" -ForegroundColor DarkGray
if ($plan.Plan.OversizedCount -gt 0)
{
    Write-Host "  $($plan.Plan.OversizedCount) oversized shard(s) — declared under Hazards in the tree" -ForegroundColor Yellow
}

$result = [ordered]@{
    RunStamp       = $runStamp
    Root           = $rootFull
    OutDir         = $outDir
    TreePath       = $treePath
    EntryCount     = $ir.Header.EntryCount
    ShardCount     = $receipt.ShardCount
    TotalBytes     = $receipt.TotalBytes
    OversizedCount = $plan.Plan.OversizedCount
}
if ($PassThru)
{
    $result['IR'] = $ir
    $result['Layout'] = $layout
    $result['Plan'] = $plan
    $result['Receipt'] = $receipt
}
[pscustomobject]$result
#endregion
