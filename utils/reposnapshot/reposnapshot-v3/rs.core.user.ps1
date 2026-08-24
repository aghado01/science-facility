#Requires -Version 7.5

<#
.SYNOPSIS
    rs.core.user — the convenience entry point: point it at a directory, get a
    complete sharded snapshot (shard files + tree manifest) in a runstamped
    output directory. One script over the six stage calls.

.DESCRIPTION
    Runs the whole v3 chain — crawl → membrane → ingest (file-read →
    rs-whitespace [→ rs-psstrip] → rs-content_meta) → assemble →
    Resolve-Layout → New-ShardPlan → Invoke-Serialize → New-Manifest — with
    ergonomic defaults. Imports the rs.core modules by relative path; psd1
    module packaging is the planned follow-on (TODO: reshape into a module).

    OUTPUT CONVENTION: every run writes into its own runstamped directory,
        <OutRoot>/<yyyyMMdd_HHmmss>/<RootLeaf>_s001.txt … <RootLeaf>_tree.md
    Default OutRoot = <Root>/.snapshot — the house convention: snapshots live
    UNDER the crawled tree, and the membrane keeps them out of the next run.
    Under Ignore semantics that is automatic ('.snapshot/' is in the
    membrane's IgnoreDefaults, and the usual .gitignore rule is picked up by
    the sentinel scan); under Selection semantics the patterns simply do not
    include it — or exclude it explicitly with a negated selection. No writer
    guard: protection is the membrane's job, by design. Runstamp collisions
    within one second get a numeric suffix.

.PARAMETER Root
    The directory to snapshot.
.PARAMETER OutRoot
    Where runstamped output directories accumulate. Default: see above.
.PARAMETER SelectionPatterns
    When given, the membrane runs SELECTION semantics — only matching files
    pass (e.g. '*.ps1','*.psm1'). Default: IGNORE semantics with the standard
    defaults and sentinel files (.gitignore/.snapignore).
.PARAMETER PsStrip
    Add rs-psstrip to the chain (PowerShell comment stripping — code-lane
    corpora only; it is lexically PS-aware and belongs nowhere near prose).
.PARAMETER Columns
    Optional psr columns to enable. Default gidx + content_meta; the
    rs-content_meta step is included in the chain exactly when the column is.
.PARAMETER PassThru
    Also return Plan, Receipt, Layout, and the IR on the result object.

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

$v3 = $PSScriptRoot
foreach ($m in 'crawler', 'membrane', 'colonel.v2', 'ingest', 'assemble', 'container', 'shards', 'serialize', 'manifest')
{
    # colonel's dispatch verbs are internal vocabulary, not user surface —
    # suppress the unapproved-verb warning in this user-facing tool
    Import-Module (Join-Path $v3 "rs.core.$m.psm1") -Force -DisableNameChecking
}

# ── resolve paths and the output convention ─────────────────────────────────
$rootFull = (Resolve-Path $Root).Path.TrimEnd('\', '/')
$leaf = Split-Path $rootFull -Leaf
if ([string]::IsNullOrEmpty($OutRoot))
{
    # house convention: snapshots live under the crawled tree; the membrane
    # keeps .snapshot/ out of the next run (IgnoreDefaults / gitignore
    # sentinel under Ignore semantics; pattern discipline under Selection)
    $OutRoot = Join-Path $rootFull '.snapshot'
}
$outFull = [IO.Path]::GetFullPath($OutRoot)

$runStamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$outDir = Join-Path $outFull $runStamp
$n = 1
while (Test-Path $outDir) { $n++; $outDir = Join-Path $outFull "${runStamp}_$n" }
$runStamp = Split-Path $outDir -Leaf

# ── crawl → membrane ────────────────────────────────────────────────────────
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

# ── ingest (chain follows the switches) → assemble ──────────────────────────
$procManifest = @{
    'file-read'     = (Join-Path $v3 'processors\file-read.ps1')
    'rs-whitespace' = (Join-Path $v3 'processors\rs-whitespace.ps1')
}
$steps = [System.Collections.Generic.List[object]]::new()
$steps.Add(@{ Key = 'file-read'; Config = @{} })
$steps.Add(@{ Key = 'rs-whitespace'; Config = @{ Operations = @('lf', 'trim-trailing', 'trim-doc') } })
if ($PsStrip)
{
    $procManifest['rs-psstrip'] = (Join-Path $v3 'processors\rs-psstrip.ps1')
    $steps.Add(@{ Key = 'rs-psstrip'; Config = @{ Operations = @('block-comments', 'doc-strings', 'comment-blocks', 'line-comments') } })
}
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

# ── layout → plan → write ───────────────────────────────────────────────────
$layout = Resolve-Layout -Header $ir.Header -Columns $Columns
$plan = New-ShardPlan -Entries $ir.Entries -Layout $layout -Grouping $Grouping -GroupSort $GroupSort `
    -OrderStrict:$OrderStrict -PackObjective $PackObjective -ShardQuotaBytes $ShardQuotaBytes `
    -ShardToleranceBytes $ShardToleranceBytes -MaxFilesPerShard $MaxFilesPerShard -ShardStem $leaf

$null = [IO.Directory]::CreateDirectory($outDir)
$receipt = Invoke-Serialize -Plan $plan -Entries $ir.Entries -Layout $layout -OutDir $outDir
$treePath = Join-Path $outDir "${leaf}_tree.md"
$null = New-Manifest -Receipt $receipt -Shards $plan.Shards -Plan $plan.Plan -Layout $layout `
    -RunContext $runContext -TreePath $treePath

# ── summary ─────────────────────────────────────────────────────────────────
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
