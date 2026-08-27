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
.PARAMETER IncludeProcessors
    Which capabilities to run, as a SET — array position carries no meaning.
    Names are the slots declared in processors/default_sequencer.json
    ('StripComments', 'Indentation', 'Whitespace', 'ContentMetadata'), not
    processor filenames. Order comes from the sequencer's Group and Rank, and
    slots a named one Requires are pulled in automatically, as are slots marked
    Default (file_read).

    A slot may be ROUTED: 'StripComments' resolves to a different stripper per
    file extension. Planning therefore compiles one chain per distinct
    resolution across the corpus — a small set — and dispatch hands each item
    the chain its extension resolved to. A file no route claims still runs
    every other stage; its chain is simply one step shorter. Requesting
    StripComments over a mixed corpus means "strip where a stripper exists".

    Columns still separately controls optional wire columns (gidx, content_meta),
    except content_meta: that block is written only when rs.content_meta actually
    ran. Columns naming it without the processor is omitted, not rendered empty.
    Which content_meta sub-fields appear is the processor Fields list intersected
    with the admitted set in container.spec.jsonc.
.PARAMETER RunVerbatim
    Runs a literal chain instead of compiling from the sequencer: -Processors is
    taken as an ordered list, in the order given, identically for every file, and
    the canon is not consulted. Nothing is routed, so a language-specific
    processor named here runs on every file regardless of extension — which is
    the point. This is the instrument for deliberately violating the format's
    invariants; the cautions below are printed only in this mode, because under
    the sequencer they are guarantees rather than advice.
.PARAMETER Processors
    Only with -RunVerbatim: the literal chain after file_read, as an ordered array
    (file_read is prepended unless you place it yourself — without it there is no
    content and the chain yields nothing). Each entry is
    either a bare processor-key string (which defers to its
    processors/configs/<Key>.json defaults) or an object { Key; Config } with
    overrides, e.g.:
      @('rs.ps.strip', 'rs.whitespace', @{ Key = 'rs.indent'; Config = @{ TargetUnit = 4 } })
    Key must name a processors\<Key>.ps1 file. A chain missing rs.whitespace, or
    running rs.content_meta before other content mutators, prints a caution (not
    an error) — pad-breaks spacing and content_meta's enrich-only-tail contract
    are established invariants of this format, not requirements enforced here.
.PARAMETER SequenceManifest
    Path to the sequencer declaring the canon and its routes. Defaults to
    processors/default_sequencer.json.
.PARAMETER Columns
    Active psr wire columns (default: gidx, content_meta). content_meta is
    omitted at layout if rs.content_meta did not run, even when named here.
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

.PARAMETER Config
    An in-line config value — a hashtable (or any object with named
    properties, e.g. a ConvertFrom-Json result) supplying any parameter above
    by name. No file I/O; for callers composing settings programmatically.
    Mutually exclusive with -ConfigPath when both are explicitly passed.

.PARAMETER ConfigPath
    JSON file supplying any parameter above by name (PascalCase keys matching
    the parameter names, e.g. { "Root": "...", "Processors": [...] }). Defaults to
    user-config.json next to this script; silently skipped if that default
    file is absent. An explicitly-passed -ConfigPath that does not exist is an
    error. Mutually exclusive with -Config when both are explicitly passed.

.LINK
    docs/user-cli-and-config.md

    Precedence: CLI arg > (-Config or -ConfigPath, whichever was passed) >
    built-in default. -Root has no built-in default — it must come from the
    CLI or from whichever config source is in play.

.EXAMPLE
    ./rs.core.user.ps1
    # Reads every setting from user-config.json next to this script.

.EXAMPLE
    ./rs.core.user.ps1 -Root ../reposnapshot-v3 -SelectionPatterns '*.ps1','*.psm1'

.EXAMPLE
   # from utils/reposnapshot/ 
  &  ./reposnapshot-v3/rs.core.user.ps1 -ConfigPath './reposnapshot-v3/user-config.json'

.EXAMPLE
    ./rs.core.user.ps1 -Config @{ Root = '..\reposnapshot-v3'; IncludeProcessors = @('StripComments', 'Whitespace') }

.EXAMPLE
    ./rs.core.user.ps1 -Root ../reposnapshot-v3 -IncludeProcessors 'Indentation', 'Whitespace', 'ContentMetadata'
    # A set, not a sequence — the sequencer orders these, and pulls in file_read.

.EXAMPLE
    ./rs.core.user.ps1 -Root ../src -RunVerbatim -Processors 'rs.whitespace', 'rs.ps.strip'
    # Deliberately out of canon, on every file regardless of extension.
#>
[CmdletBinding()]
param(
    [string]$Root,
    [string]$OutRoot,
    [string[]]$SelectionPatterns = $null,
    [string[]]$Columns = @('gidx', 'content_meta'),
    [ValidateSet('Flat', 'ByFileType', 'ByRootDirectory')] [string]$Grouping = 'Flat',
    [ValidateSet('PathAsc', 'PathHash')] [string]$GroupSort = 'PathAsc',
    [switch]$OrderStrict,
    [ValidateSet('FrontLoad', 'Even')] [string]$PackObjective = 'FrontLoad',
    [long]$ShardQuotaBytes = 32768,
    [long]$ShardToleranceBytes = 4096,
    [ValidateRange(1, [int]::MaxValue)] [int]$MaxFilesPerShard = 100000,
    [switch]$PassThru,
    [string[]]$IncludeProcessors = $null,
    [switch]$RunVerbatim,
    [object[]]$Processors = $null,
    [string]$SequenceManifest = (Join-Path $PSScriptRoot 'processors\default_sequencer.json'),
    [object]$Config,
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'user-config.json')
)

#region ConfigMerge
# Resolution precedence: CLI Flags > Config (-Config or -ConfigPath) > Built-in Defaults.
# See docs/user-cli-and-config.md for resolution and binding invariants.
function Get-ConfigOverride ($Bound, $Cfg, [string]$Name, $Current) {
    if ($Bound.ContainsKey($Name)) { return $Current }
    if ($Cfg.ContainsKey($Name) -and $null -ne $Cfg[$Name]) { return $Cfg[$Name] }
    return $Current
}

function ConvertTo-ConfigHashtable ($Value) {
    if ($Value -is [System.Collections.IDictionary]) { return $Value }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $h = @{}
        foreach ($p in $Value.PSObject.Properties) { $h[$p.Name] = $p.Value }
        return $h
    }
    throw "rs.core.user: -Config must be a hashtable or an object with named properties (got $($Value.GetType().Name))."
}

# Normalize a -Processors entry to @{ Key; Config }. Bare string defers to processors/configs/<Key>.json.
function ConvertTo-ProcessorStep ($Entry) {
    if ($Entry -is [string]) { return @{ Key = $Entry; Config = @{} } }
    $h = if ($Entry -is [System.Management.Automation.PSCustomObject]) { ConvertTo-ConfigHashtable $Entry } else { $Entry }
    if ($h -isnot [System.Collections.IDictionary]) {
        throw "rs.core.user: a -Processors entry must be a processor-key string or an object with Key/Config (got $($Entry.GetType().Name))."
    }
    if (-not $h.ContainsKey('Key') -or [string]::IsNullOrWhiteSpace([string]$h['Key'])) {
        throw "rs.core.user: a -Processors entry is missing 'Key'."
    }
    $stepConfig = if ($h.ContainsKey('Config') -and $null -ne $h['Config']) {
        if ($h['Config'] -is [System.Management.Automation.PSCustomObject]) { ConvertTo-ConfigHashtable $h['Config'] } else { $h['Config'] }
    }
    else { @{} }
    return @{ Key = [string]$h['Key']; Config = $stepConfig }
}

$explicitConfig = $PSBoundParameters.ContainsKey('Config')
$explicitConfigPath = $PSBoundParameters.ContainsKey('ConfigPath')
if ($explicitConfig -and $explicitConfigPath) { throw "rs.core.user: pass -Config or -ConfigPath, not both." }

$cfg = $null
$configSource = $null
if ($explicitConfig) {
    $cfg = ConvertTo-ConfigHashtable $Config
    $configSource = '-Config (inline)'
}
elseif (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    if ($explicitConfigPath) { throw "rs.core.user: -ConfigPath '$ConfigPath' does not exist." }
}
else {
    $cfg = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json -AsHashtable
    $configSource = $ConfigPath
}

if ($null -ne $cfg) {
    $b = $PSBoundParameters
    $Root = Get-ConfigOverride $b $cfg 'Root' $Root
    $OutRoot = Get-ConfigOverride $b $cfg 'OutRoot' $OutRoot
    $SelectionPatterns = Get-ConfigOverride $b $cfg 'SelectionPatterns' $SelectionPatterns
    if ($null -ne $SelectionPatterns) { $SelectionPatterns = [string[]]$SelectionPatterns }
    $Columns = [string[]](Get-ConfigOverride $b $cfg 'Columns' $Columns)
    $Grouping = [string](Get-ConfigOverride $b $cfg 'Grouping' $Grouping)
    $GroupSort = [string](Get-ConfigOverride $b $cfg 'GroupSort' $GroupSort)
    $OrderStrict = [bool](Get-ConfigOverride $b $cfg 'OrderStrict' $OrderStrict.IsPresent)
    $PackObjective = [string](Get-ConfigOverride $b $cfg 'PackObjective' $PackObjective)
    $ShardQuotaBytes = [long](Get-ConfigOverride $b $cfg 'ShardQuotaBytes' $ShardQuotaBytes)
    $ShardToleranceBytes = [long](Get-ConfigOverride $b $cfg 'ShardToleranceBytes' $ShardToleranceBytes)
    $MaxFilesPerShard = [int](Get-ConfigOverride $b $cfg 'MaxFilesPerShard' $MaxFilesPerShard)
    $PassThru = [bool](Get-ConfigOverride $b $cfg 'PassThru' $PassThru.IsPresent)
    $IncludeProcessors = Get-ConfigOverride $b $cfg 'IncludeProcessors' $IncludeProcessors
    if ($null -ne $IncludeProcessors) { $IncludeProcessors = [string[]]@($IncludeProcessors) }
    $RunVerbatim = [bool](Get-ConfigOverride $b $cfg 'RunVerbatim' $RunVerbatim.IsPresent)
    $Processors = Get-ConfigOverride $b $cfg 'Processors' $Processors
    if ($null -ne $Processors) { $Processors = @($Processors) }
    $SequenceManifest = [string](Get-ConfigOverride $b $cfg 'SequenceManifest' $SequenceManifest)
}

if ([string]::IsNullOrEmpty($Root)) {
    throw "rs.core.user: -Root is required — pass -Root, set `"Root`" in a -Config object, or set `"Root`" in the -ConfigPath file."
}
if (-not (Test-Path -LiteralPath $Root -PathType Container)) { throw "rs.core.user: Root '$Root' is not a directory." }
#endregion

#region ModuleImports
$v3 = $PSScriptRoot
foreach ($m in 'crawler', 'membrane', 'colonel.v2', 'ingest', 'assemble', 'container', 'shards', 'serialize', 'manifest') {
    Import-Module (Join-Path $v3 "rs.core.$m.psm1") -Force -DisableNameChecking
}
#endregion

#region PathResolution
$rootFull = (Resolve-Path $Root).Path.TrimEnd('\', '/')
$leaf = Split-Path $rootFull -Leaf
if ([string]::IsNullOrEmpty($OutRoot)) {
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
$compiled = if ($null -ne $SelectionPatterns -and $SelectionPatterns.Count -gt 0) {
    New-GlobCompiler -CrawlerGraph $crawl.Graph -GlobSemantics Selection -SelectionPatterns $SelectionPatterns
}
else {
    New-GlobCompiler -CrawlerGraph $crawl.Graph
}
$filtered = Invoke-Membrane -CompiledNodes $compiled.CompiledNodes -CrawlerGraph $crawl.Graph
#endregion

#region IngestAndAssemble
# Discover all processors/*.ps1 scripts for step validation.
$procDir = Join-Path $v3 'processors'
$procManifest = @{}
foreach ($f in Get-ChildItem -LiteralPath $procDir -Filter '*.ps1' -File) {
    if ($f.Name -in 'chain_executor.ps1', 'bag_helpers.ps1') { continue }
    $procManifest[[IO.Path]::GetFileNameWithoutExtension($f.Name)] = $f.FullName
}

# Two modes. Under the sequencer the caller names capabilities and the compiler
# owns order, routing and the file_read prologue — so nothing is assembled here.
# Under -RunVerbatim the caller's literal chain is handed over untouched.
$ingestParams = @{
    FilteredFsGraph   = $filtered
    Manifest          = $procManifest
    ChainExecutorPath = (Join-Path $v3 'processors\chain_executor.ps1')
    SharedHelperPath  = (Join-Path $v3 'processors\bag_helpers.ps1')
}

if ($RunVerbatim) {
    if ($null -eq $Processors -or $Processors.Count -eq 0) {
        throw "rs.core.user: -RunVerbatim needs -Processors — it runs the chain you give it, and you gave none."
    }

    $steps = [System.Collections.Generic.List[object]]::new()
    foreach ($entry in $Processors) {
        $step = ConvertTo-ProcessorStep $entry
        if (-not $procManifest.ContainsKey($step.Key)) {
            throw "rs.core.user: -Processors names '$($step.Key)', which has no processors\$($step.Key).ps1. Known: $($procManifest.Keys -join ', ')."
        }
        $steps.Add($step)
    }

    # file_read is a prologue, not an invariant to violate: without it there is no
    # content and every chain silently yields nothing. Verbatim exists to break the
    # canon's ORDER and ROUTING, not to run against unread files. Prepended unless
    # the caller placed it themselves, which is how -Processors has always read.
    if (@($steps | ForEach-Object Key) -notcontains 'file_read') {
        $steps.Insert(0, @{ Key = 'file_read'; Config = @{} })
    }
    $ingestParams['Steps'] = @($steps)

    # Advisories, and only here. Under the sequencer these are compiler guarantees:
    # rs.content_meta lands last because its Group says so, and an omission is a
    # request the caller made rather than an accident to warn about.
    $resolvedKeys = @($steps | ForEach-Object Key)
    if ($resolvedKeys -notcontains 'rs.whitespace') {
        Write-Host "  caution: chain omits rs.whitespace — its pad-breaks op is what keeps the container codec's newline substitution regularly spaced. Fine if intentional." -ForegroundColor Yellow
    }
    $cmIdx = [array]::IndexOf($resolvedKeys, 'rs.content_meta')
    if ($cmIdx -ge 0 -and $cmIdx -ne $resolvedKeys.Count - 1) {
        Write-Host "  caution: rs.content_meta is not the last processor — its own contract calls for enrich-only TAIL placement, after every content mutator. Fine if intentional." -ForegroundColor Yellow
    }
    if (($Columns -contains 'content_meta') -and $resolvedKeys -notcontains 'rs.content_meta') {
        Write-Host "  caution: Columns requested content_meta but no rs.content_meta step runs — the column is omitted, not written empty." -ForegroundColor Yellow
    }
}
else {
    if ($null -ne $Processors -and $Processors.Count -gt 0) {
        throw "rs.core.user: -Processors is a literal chain and needs -RunVerbatim. To choose capabilities under the canon, use -IncludeProcessors."
    }

    $ingestParams['SequenceManifest'] = $SequenceManifest
    $ingestParams['IncludeProcessors'] = if ($null -ne $IncludeProcessors) { [string[]]@($IncludeProcessors) } else { [string[]]@() }
}

$ingest = Invoke-Ingest @ingestParams
if (@($ingest.Errors).Count -gt 0) {
    throw "rs.core.user: ingest reported errors — $($ingest.Errors -join '; ')"
}

# Run facts only. Internment and packing settings are rendered by New-Manifest
# from the colonel family and the shard plan — user does not join them here.
$runContext = [pscustomobject]@{
    RunStamp         = $runStamp
    Root             = ($rootFull -replace '\\', '/')
    GeneratorVersion = 'reposnapshot-v3'
    GlobSemantics    = if ($null -ne $SelectionPatterns) { 'Selection' } else { 'Ignore' }
    Patterns         = $SelectionPatterns
    Mode             = if ($RunVerbatim) { 'Verbatim' } else { 'Sequenced' }
    Requested        = if ($RunVerbatim) { @($Processors | ForEach-Object { if ($_ -is [string]) { $_ } else { $_.Key } }) } else { @($IncludeProcessors) }
    Columns          = $Columns
    ConfigSource     = $configSource
}
$ir = Invoke-Assemble -DispatchOutput $ingest -RunContext $runContext
#endregion

#region ShardAndSerialize
$sample = if (@($ir.Entries).Count -gt 0) { $ir.Entries[0] } else { $null }
$layout = Resolve-Layout -Header $ir.Header -Columns $Columns -Entry $sample
$effectiveColumns = @($layout.Columns | ForEach-Object Name | Where-Object { $_ -notin @('path', 'content_bytes', 'content') })
$runContext.Columns = $effectiveColumns
if ($null -ne $ir.Header.PSObject.Properties['Columns']) { $ir.Header.Columns = $effectiveColumns }
$plan = New-ShardPlan -Entries $ir.Entries -Layout $layout -Grouping $Grouping -GroupSort $GroupSort `
    -OrderStrict:$OrderStrict -PackObjective $PackObjective -ShardQuotaBytes $ShardQuotaBytes `
    -ShardToleranceBytes $ShardToleranceBytes -MaxFilesPerShard $MaxFilesPerShard -ShardStem $leaf

$null = [IO.Directory]::CreateDirectory($outDir)
$receipt = Invoke-Serialize -Plan $plan -Entries $ir.Entries -Layout $layout -OutDir $outDir
$treePath = Join-Path $outDir "${leaf}_tree.md"
$null = New-Manifest -Receipt $receipt -Shards $plan.Shards -Plan $plan.Plan -Layout $layout `
    -RunContext $runContext -TreePath $treePath -Family $ingest.Plan
#endregion

#region Output
Write-Host "reposnapshot: $($ir.Header.EntryCount) entries → $($receipt.ShardCount) shards, $($receipt.TotalBytes) bytes" -ForegroundColor Green
Write-Host "  $outDir" -ForegroundColor DarkGray
if ($plan.Plan.OversizedCount -gt 0) {
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
if ($PassThru) {
    $result['IR'] = $ir
    $result['Layout'] = $layout
    $result['Plan'] = $plan
    $result['Receipt'] = $receipt
}
[pscustomobject]$result
#endregion
