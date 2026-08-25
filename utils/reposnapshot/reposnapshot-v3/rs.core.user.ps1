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
    Applies PowerShell comment stripping (code corpora only). Sugar for the
    single-processor case; ignored when -Processors is given — build the same
    step into -Processors instead.
.PARAMETER Processors
    The ingest chain after file-read, as an ordered array. Each entry is
    either a bare processor-key string (default Config: {}) or an object
    { Key; Config }, e.g.:
      @('rs-whitespace', @{ Key = 'rs-indent'; Config = @{ Operations = @('detab','min-indent','tabify'); TargetUnit = 2 } })
    Key must name a processors\<Key>.ps1 file. When given, this fully
    replaces the legacy PsStrip-driven chain (file-read → [rs-psstrip] →
    rs-whitespace → [rs-content_meta]) — nothing after file-read is implied.
    Columns still separately controls what lands on the wire: a processor's
    fields only appear there if the matching column is also requested, and a
    requested column with no processor computing it renders empty.
    A resolved chain missing rs-whitespace, or running rs-content_meta before
    other content mutators, prints a caution (not an error) — pad-breaks
    spacing and content_meta's enrich-only-tail contract are established
    invariants of this format, not requirements enforced here.
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

.PARAMETER Config
    An in-line config value — a hashtable (or any object with named
    properties, e.g. a ConvertFrom-Json result) supplying any parameter above
    by name. No file I/O; for callers composing settings programmatically.
    Mutually exclusive with -ConfigPath when both are explicitly passed.

.PARAMETER ConfigPath
    JSON file supplying any parameter above by name (PascalCase keys matching
    the parameter names, e.g. { "Root": "...", "PsStrip": true }). Defaults to
    user-config.json next to this script; silently skipped if that default
    file is absent. An explicitly-passed -ConfigPath that does not exist is an
    error. Mutually exclusive with -Config when both are explicitly passed.

    Precedence: CLI arg > (-Config or -ConfigPath, whichever was passed) >
    built-in default. -Root has no built-in default — it must come from the
    CLI or from whichever config source is in play.

.EXAMPLE
    ./rs.core.user.ps1
    # Reads every setting from user-config.json next to this script.

.EXAMPLE
    ./rs.core.user.ps1 -Root ../reposnapshot-v3 -SelectionPatterns '*.ps1','*.psm1' -PsStrip

.EXAMPLE
    ./rs.core.user.ps1 -ConfigPath ./recipes/full-audit.json

.EXAMPLE
    ./rs.core.user.ps1 -Config @{ Root = '..\reposnapshot-v3'; PsStrip = $true }

.EXAMPLE
    ./rs.core.user.ps1 -Root ../reposnapshot-v3 -Processors 'rs-indent', 'rs-whitespace', 'rs-content_meta'
#>
[CmdletBinding()]
param(
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
    [switch]$PassThru,
    [object[]]$Processors = $null,
    [object]$Config,
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'user-config.json')
)

#region ConfigMerge
# Three ways settings can arrive, in this order of resolution:
#   1. -Config <hashtable-or-object>  — an in-line value, no file I/O.
#   2. -ConfigPath <file>             — explicit file path, read and parsed.
#   3. (neither passed)               — user-config.json beside this script,
#                                        used if present, silently skipped if
#                                        not (that default path "existing" is
#                                        not the same as being explicitly
#                                        passed — only an explicit -ConfigPath
#                                        that is missing is an error).
# -Config and -ConfigPath are mutually exclusive when BOTH are explicitly
# passed — ConfigPath's own default value doesn't count as "passed" here;
# $PSBoundParameters is what distinguishes an explicit flag from a default.
#
# -Root dropped [Parameter(Mandatory)] so an unbound Root can fall through to
# the config below — PowerShell binds/prompts for Mandatory params BEFORE the
# script body runs, which would pre-empt ever reaching a config at all. Root
# has no ValidateSet/ValidateRange to lean on, so every path (CLI-bound,
# config-sourced, or plain missing) gets the same explicit Container check
# below.
#
# Grouping/GroupSort/PackObjective/MaxFilesPerShard keep their param-block
# ValidateSet/ValidateRange working for free: PowerShell re-validates a
# variable against its own attribute on every reassignment within the same
# scope, not just at initial parameter binding — so a bad config value throws
# PowerShell's own clear error right at the assignment lines below, no extra
# checking needed.
function Get-ConfigOverride ($Bound, $Cfg, [string]$Name, $Current)
{
    if ($Bound.ContainsKey($Name)) { return $Current }
    if ($Cfg.ContainsKey($Name) -and $null -ne $Cfg[$Name]) { return $Cfg[$Name] }
    return $Current
}

function ConvertTo-ConfigHashtable ($Value)
{
    if ($Value -is [System.Collections.IDictionary]) { return $Value }
    if ($Value -is [System.Management.Automation.PSCustomObject])
    {
        $h = @{}
        foreach ($p in $Value.PSObject.Properties) { $h[$p.Name] = $p.Value }
        return $h
    }
    throw "rs.core.user: -Config must be a hashtable or an object with named properties (got $($Value.GetType().Name))."
}

# Normalizes one -Processors entry to the @{ Key; Config } shape Compile-Plan
# expects (see processors\chain-executor.ps1's CHAINING CONTRACT). A bare
# string is sugar for "this key, default Config {}".
function ConvertTo-ProcessorStep ($Entry)
{
    if ($Entry -is [string]) { return @{ Key = $Entry; Config = @{} } }
    $h = if ($Entry -is [System.Management.Automation.PSCustomObject]) { ConvertTo-ConfigHashtable $Entry } else { $Entry }
    if ($h -isnot [System.Collections.IDictionary])
    {
        throw "rs.core.user: a -Processors entry must be a processor-key string or an object with Key/Config (got $($Entry.GetType().Name))."
    }
    if (-not $h.ContainsKey('Key') -or [string]::IsNullOrWhiteSpace([string]$h['Key']))
    {
        throw "rs.core.user: a -Processors entry is missing 'Key'."
    }
    $stepConfig = if ($h.ContainsKey('Config') -and $null -ne $h['Config'])
    {
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
if ($explicitConfig)
{
    $cfg = ConvertTo-ConfigHashtable $Config
    $configSource = '-Config (inline)'
}
elseif (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf))
{
    if ($explicitConfigPath) { throw "rs.core.user: -ConfigPath '$ConfigPath' does not exist." }
}
else
{
    $cfg = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json -AsHashtable
    $configSource = $ConfigPath
}

if ($null -ne $cfg)
{
    $b = $PSBoundParameters

    $Root                = Get-ConfigOverride $b $cfg 'Root' $Root
    $OutRoot             = Get-ConfigOverride $b $cfg 'OutRoot' $OutRoot
    $SelectionPatterns   = Get-ConfigOverride $b $cfg 'SelectionPatterns' $SelectionPatterns
    if ($null -ne $SelectionPatterns) { $SelectionPatterns = [string[]]$SelectionPatterns }
    $PsStrip             = [bool](Get-ConfigOverride $b $cfg 'PsStrip' $PsStrip.IsPresent)
    $Columns             = [string[]](Get-ConfigOverride $b $cfg 'Columns' $Columns)
    $Grouping            = [string](Get-ConfigOverride $b $cfg 'Grouping' $Grouping)
    $GroupSort           = [string](Get-ConfigOverride $b $cfg 'GroupSort' $GroupSort)
    $OrderStrict         = [bool](Get-ConfigOverride $b $cfg 'OrderStrict' $OrderStrict.IsPresent)
    $PackObjective       = [string](Get-ConfigOverride $b $cfg 'PackObjective' $PackObjective)
    $ShardQuotaBytes     = [long](Get-ConfigOverride $b $cfg 'ShardQuotaBytes' $ShardQuotaBytes)
    $ShardToleranceBytes = [long](Get-ConfigOverride $b $cfg 'ShardToleranceBytes' $ShardToleranceBytes)
    $MaxFilesPerShard    = [int](Get-ConfigOverride $b $cfg 'MaxFilesPerShard' $MaxFilesPerShard)
    $PassThru            = [bool](Get-ConfigOverride $b $cfg 'PassThru' $PassThru.IsPresent)
    $Processors          = Get-ConfigOverride $b $cfg 'Processors' $Processors
    if ($null -ne $Processors) { $Processors = @($Processors) }
}

if ([string]::IsNullOrEmpty($Root))
{
    throw "rs.core.user: -Root is required — pass -Root, set `"Root`" in a -Config object, or set `"Root`" in the -ConfigPath file."
}
if (-not (Test-Path -LiteralPath $Root -PathType Container)) { throw "rs.core.user: Root '$Root' is not a directory." }
#endregion

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
# Every processors\*.ps1 file (minus the two infra scripts) is registered
# regardless of what actually runs — Compile-Plan only reads manifest entries
# whose Key is referenced by $steps, so this costs nothing and needs no edit
# when a new processor file shows up.
$procDir = Join-Path $v3 'processors'
$procManifest = @{}
foreach ($f in Get-ChildItem -LiteralPath $procDir -Filter '*.ps1' -File)
{
    if ($f.Name -in 'chain-executor.ps1', 'bag-helpers.ps1') { continue }
    $procManifest[[IO.Path]::GetFileNameWithoutExtension($f.Name)] = $f.FullName
}

$steps = [System.Collections.Generic.List[object]]::new()
$steps.Add(@{ Key = 'file-read'; Config = @{} })

if ($null -ne $Processors -and $Processors.Count -gt 0)
{
    # explicit chain — fully replaces the legacy PsStrip/Columns-driven default
    foreach ($entry in $Processors)
    {
        $step = ConvertTo-ProcessorStep $entry
        if (-not $procManifest.ContainsKey($step.Key))
        {
            throw "rs.core.user: -Processors names '$($step.Key)', which has no processors\$($step.Key).ps1. Known: $($procManifest.Keys -join ', ')."
        }
        $steps.Add($step)
    }
}
else
{
    # legacy default chain — unchanged from before -Processors existed
    if ($PsStrip)
    {
        $steps.Add(@{ Key = 'rs-psstrip'; Config = @{} })
    }
    $steps.Add(@{ Key = 'rs-whitespace'; Config = @{} })
    if ($Columns -contains 'content_meta')
    {
        $steps.Add(@{ Key = 'rs-content_meta'; Config = @{} })
    }
}

# Soft cautions, not errors — an explicit -Processors chain is allowed to
# violate these; they are established invariants of the format (pad-breaks
# spacing, content_meta's enrich-only-tail contract), not rules enforced here.
$resolvedKeys = @($steps | ForEach-Object Key)
if ($resolvedKeys -notcontains 'rs-whitespace')
{
    Write-Host "  caution: chain omits rs-whitespace — its pad-breaks op is what keeps the container codec's newline substitution regularly spaced. Fine if intentional." -ForegroundColor Yellow
}
$cmIdx = [array]::IndexOf($resolvedKeys, 'rs-content_meta')
if ($cmIdx -ge 0 -and $cmIdx -ne $resolvedKeys.Count - 1)
{
    Write-Host "  caution: rs-content_meta is not the last processor — its own contract calls for enrich-only TAIL placement, after every content mutator. Fine if intentional." -ForegroundColor Yellow
}
if (($Columns -contains 'content_meta') -and $resolvedKeys -notcontains 'rs-content_meta')
{
    Write-Host "  caution: Columns requests content_meta but no rs-content_meta step runs — that wire column will render empty." -ForegroundColor Yellow
}
if ($PsStrip -and $null -ne $Processors -and $Processors.Count -gt 0)
{
    Write-Host "  note: -PsStrip is ignored — -Processors was given, and takes over the whole chain after file-read." -ForegroundColor DarkGray
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
        ConfigSource  = $configSource
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
