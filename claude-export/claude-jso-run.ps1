# claude-jso-run.ps1 — Entrypoint for the Claude Code thread export pipeline
#
# Dot-source this file to get all pipeline functions:
#
#   . "D:\aghado01\utils\jso-jackson\claude-export\claude-jso-run.ps1"
#   Invoke-ClaudeThreadExport -SourceDir $path
#   Invoke-ClaudeThreadExportBatch -SourceDir $path -MarkdownDir $outDir
#
# FUNCTIONS
# ---------
#   Get-ClaudeThreadPlan          Discover and group threads in a directory.
#   Invoke-ClaudeThreadExport     Full or partial pipeline: merged → exchanges → markdown.
#   Invoke-ClaudeThreadExportBatch  Batch: plan all threads, dispatch one export per leaf.
#
# PIPELINE STAGES
# ---------------
#   Merged     Export-ClaudeThread       → {WorkingDir}/raw/, {WorkingDir}/merged/
#   Exchanges  Get/Export-ClaudeExchanges → {WorkingDir}/exchanges/
#   Markdown   ConvertTo-ClaudeMarkdownV2 → resolved output path (see below)
#
# OUTPUT FILE NAMING
#   Artifacts are named `{OutputPrefix}-{threadId}.{jsonl|md}` across stages
#   (merged, exchanges, markdown). `-OutputPrefix` defaults to 'thread' for
#   single-thread runs. The batch runner overrides it with the project leaf
#   (last hyphen-segment of the source dir's leaf name, e.g. 'tools') so
#   artifacts self-identify when collected across directories.
#
# MARKDOWN OUTPUT RESOLUTION (in precedence order)
#   -MarkdownPath    exact output file path (single-thread only)
#   -MarkdownDir     write {OutputPrefix}-{threadId}.md flat into this directory
#   (neither)        write {OutputPrefix}-{threadId}.md into {WorkingDir}/output/
#
# WORKING DIRECTORY — single thread
#   Defaults to ~/.claude/tmp/claude-jso-run/{timestamp}/ via New-JobWorkingDir.
#   Pass -WorkingDir to override. Directory creation for all pipeline stages
#   is handled by each stage function — this script does none of it.
#
# WORKING DIRECTORY — batch
#   Defaults to ~/.claude/tmp/{projectSlug}/{YYYYMMDD_HHmmss}/, where
#   {projectSlug} is the full slug of the source dir's leaf name
#   (e.g. `C--Users-azrie--claude-tools`). Per-thread artifacts
#   land in {BatchRoot}/{leafUuid}/. Pass -WorkingDir to override.
#
# MARKDOWN DIRECTORY — batch default
#   Defaults to ~/.claude/tmp/markdown/ (flat, project-agnostic). Files are
#   named `{projectLeaf}-{threadId}.md` so different projects coexist without
#   collision; same-thread re-exports overwrite in place ("current state"
#   mirror, separate from the per-run JSONL archive under {projectLeaf}/{ts}/).
#
# THREAD CHAIN GROUPING (Get-ClaudeThreadPlan)
#   Sessions are grouped into chains via .jsonl.idx sentinels. A session with
#   a .idx file has been continued; absence of .idx marks a leaf. Walk sorted
#   by LastWriteTimeUtc, accumulate until a no-.idx session closes the chain.
#   Leaf UUIDs are the dispatch targets; prior UUIDs are omitted (Export-ClaudeThread
#   auto-discovers them via New-ClaudeThreadManifest -SessionIds).
#
# DEPENDENCIES (always re-sourced on load)
#   claude-jso-jackson.ps1, claude-jso-markdown-v2.ps1
# -----------------------------------------------------------------------

$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\claude-jso-jackson.ps1"
. "$PSScriptRoot\claude-jso-markdown-v2.ps1"

function Invoke-ClaudeThreadExport
{
    <#
    .SYNOPSIS
        Run the Claude thread export pipeline for a single source directory.
    .DESCRIPTION
        Orchestrates Export-ClaudeThread → Get/Export-ClaudeExchanges →
        ConvertTo-ClaudeMarkdownV2 in sequence. Use -RunThrough to stop after
        any stage. All directory creation is delegated to the stage functions.
    .PARAMETER SourceDir
        Directory containing the UUID-named .jsonl session files.
    .PARAMETER SessionIds
        Optional. Limit discovery to specific session UUIDs.
    .PARAMETER WorkingDir
        Root for all JSONL pipeline artifacts (raw/, merged/, exchanges/).
        Defaults to a timestamped directory under ~/.claude/tmp/claude-jso-run/.
    .PARAMETER RunThrough
        How far to run the pipeline. Merged | Exchanges | Markdown (default).
    .PARAMETER MarkdownPath
        Explicit output path for the markdown file. Highest precedence.
    .PARAMETER MarkdownDir
        Output directory for the markdown file. Writes thread-{threadId}.md
        flat into this directory. Created automatically if it does not exist.
    .PARAMETER Format
        Passed to ConvertTo-ClaudeMarkdownV2. Default: Structural.
    .PARAMETER Exclude
        Passed to ConvertTo-ClaudeMarkdownV2. Default: model-feeding profile.
    .PARAMETER UserLabel
        Human speaker label for diarized rendering. Passed to Get-ClaudeExchanges
        and stamped on every exchange envelope. Default: Aipithicus.
    .PARAMETER MaxToolInputLength
        Passed to ConvertTo-ClaudeMarkdownV2. Default: 500. $null = no truncation.
    .PARAMETER OutputPrefix
        Filename stem for merged, exchanges, and markdown artifacts:
        `{OutputPrefix}-{threadId}.{jsonl|md}`. Default `'thread'`. Batch runs
        pass the project leaf (e.g. `'tools'`).
    .OUTPUTS
        PSCustomObject { ThreadId, WorkingDir, MergedPath, ExchangesPath, MarkdownPath, Stats }
        Paths for stages not reached are $null.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SourceDir,

        [string[]]$SessionIds,

        [string]$WorkingDir,

        [ValidateSet('Merged', 'Exchanges', 'Markdown')]
        [string]$RunThrough = 'Markdown',

        [string]$MarkdownPath,
        [string]$MarkdownDir,

        [string]$UserLabel = 'Aipithicus',

        [ValidateSet('Diarized', 'Dialogue', 'Structural', 'House')]
        [string]$Format = 'Structural',

        [ValidateSet('thinking', 'tool-calls', 'tool-results', 'subagents',
            'synthetic', 'timestamps', 'session-markers', 'exchange-markers')]
        [string[]]$Exclude = @('thinking', 'tool-calls', 'tool-results',
            'subagents', 'synthetic', 'timestamps', 'session-markers', 'exchange-markers'),

        [AllowNull()]
        [Nullable[int]]$MaxToolInputLength = 500,

        [string]$OutputPrefix = 'thread'
    )

    $timer = [System.Diagnostics.Stopwatch]::StartNew()

    # --- Resolve working directory ---
    if (-not $WorkingDir)
    {
        $WorkingDir = New-JobWorkingDir -Prefix 'claude-jso-run'
    }

    # --- Stage 1: Merge ---
    $exportArgs = @{
        SourceDir    = $SourceDir
        WorkingDir   = $WorkingDir
        OutputPrefix = $OutputPrefix
    }
    if ($SessionIds) { $exportArgs.SessionIds = $SessionIds }

    $threadResult = Export-ClaudeThread @exportArgs
    $threadId  = $threadResult.Manifest.ThreadId
    $mergedPath = $threadResult.MergedPath

    if ($RunThrough -eq 'Merged')
    {
        $timer.Stop()
        return [PSCustomObject]@{
            ThreadId      = $threadId
            WorkingDir    = $WorkingDir
            MergedPath    = $mergedPath
            ExchangesPath = $null
            MarkdownPath  = $null
            Stats         = $threadResult.Stats
            Elapsed       = $timer.Elapsed
        }
    }

    # --- Stage 2: Exchanges ---
    $exchanges = Get-ClaudeExchanges -MergedJsonlPath $mergedPath -ThreadId $threadId -UserLabel $UserLabel
    $exchangeResult = Export-ClaudeExchanges -Exchanges $exchanges `
        -WorkingDir $WorkingDir -ThreadId $threadId -OutputPrefix $OutputPrefix
    $exchangesPath = $exchangeResult.ExchangesPath

    if ($RunThrough -eq 'Exchanges')
    {
        $timer.Stop()
        return [PSCustomObject]@{
            ThreadId      = $threadId
            WorkingDir    = $WorkingDir
            MergedPath    = $mergedPath
            ExchangesPath = $exchangesPath
            MarkdownPath  = $null
            Stats         = $threadResult.Stats
            Elapsed       = $timer.Elapsed
        }
    }

    # --- Stage 3: Markdown ---
    $resolvedMarkdownPath = if ($MarkdownPath)
    {
        $MarkdownPath
    }
    elseif ($MarkdownDir)
    {
        [System.IO.Path]::Combine($MarkdownDir, "$OutputPrefix-$threadId.md")
    }
    else
    {
        [System.IO.Path]::Combine($WorkingDir, 'output', "$OutputPrefix-$threadId.md")
    }

    ConvertTo-ClaudeMarkdownV2 `
        -ExchangesJsonlPath  $exchangesPath `
        -OutputPath          $resolvedMarkdownPath `
        -Format              $Format `
        -Exclude             $Exclude `
        -MaxToolInputLength  $MaxToolInputLength

    $timer.Stop()
    return [PSCustomObject]@{
        ThreadId      = $threadId
        WorkingDir    = $WorkingDir
        MergedPath    = $mergedPath
        ExchangesPath = $exchangesPath
        MarkdownPath  = $resolvedMarkdownPath
        Stats         = $threadResult.Stats
        Elapsed       = $timer.Elapsed
    }
}


function Get-ClaudeThreadPlan
{
    <#
    .SYNOPSIS
        Discover and group all threads in a source directory.
    .DESCRIPTION
        Enumerates UUID-named .jsonl session files, detects .jsonl.idx chain
        sentinels, and groups sessions into thread chains ordered oldest → leaf.
        Returns a plan object with chain groupings and the reduced leaf-only
        dispatch list.

        A session with a .jsonl.idx sentinel has been continued by a newer
        session. Walk sessions sorted by LastWriteTimeUtc and accumulate into
        the current chain until a session without a sentinel closes it.

        The returned LeafUuids are the correct dispatch targets for
        Invoke-ClaudeThreadExport: Export-ClaudeThread will auto-discover all
        prior sessions in the chain via New-ClaudeThreadManifest -SessionIds.
    .PARAMETER SourceDir
        Directory containing the UUID-named .jsonl session files.
    .OUTPUTS
        PSCustomObject {
            SourceDir, AllUuids, Chains, LeafUuids, PriorUuids, ChainCount
        }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SourceDir
    )

    if (-not [System.IO.Directory]::Exists($SourceDir))
    {
        throw "Source directory not found: $SourceDir"
    }

    $uuidPattern = '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.jsonl$'

    $jsonlFiles = [System.IO.Directory]::GetFiles($SourceDir, '*.jsonl')
    $sessionFiles = [System.Collections.Generic.List[System.IO.FileInfo]]::new()

    foreach ($f in $jsonlFiles)
    {
        $fi = [System.IO.FileInfo]::new($f)
        if ($fi.Name -match $uuidPattern) { $sessionFiles.Add($fi) }
    }

    if ($sessionFiles.Count -eq 0)
    {
        return [PSCustomObject]@{
            SourceDir  = $SourceDir
            AllUuids   = [string[]]@()
            Chains     = @()
            LeafUuids  = [string[]]@()
            PriorUuids = [string[]]@()
            ChainCount = 0
        }
    }

    $sorted = $sessionFiles | Sort-Object LastWriteTimeUtc

    # Group into chains: accumulate until a no-.idx session closes the chain
    $chains = [System.Collections.Generic.List[string[]]]::new()
    $currentChain = [System.Collections.Generic.List[string]]::new()

    foreach ($sf in $sorted)
    {
        $uuid = [System.IO.Path]::GetFileNameWithoutExtension($sf.Name)
        $hasIdx = [System.IO.File]::Exists($sf.FullName + '.idx')

        $currentChain.Add($uuid)

        if (-not $hasIdx)
        {
            $chains.Add($currentChain.ToArray())
            $currentChain = [System.Collections.Generic.List[string]]::new()
        }
    }

    # Flush any open chain (edge case: last session has .idx but no successor on disk)
    if ($currentChain.Count -gt 0) { $chains.Add($currentChain.ToArray()) }

    $allUuids   = [System.Collections.Generic.List[string]]::new()
    $leafUuids  = [System.Collections.Generic.List[string]]::new()
    $priorUuids = [System.Collections.Generic.List[string]]::new()

    foreach ($chain in $chains)
    {
        for ($i = 0; $i -lt $chain.Length; $i++)
        {
            $allUuids.Add($chain[$i])
            if ($i -eq $chain.Length - 1) { $leafUuids.Add($chain[$i]) }
            else                          { $priorUuids.Add($chain[$i]) }
        }
    }

    return [PSCustomObject]@{
        SourceDir  = $SourceDir
        AllUuids   = $allUuids.ToArray()
        Chains     = $chains.ToArray()
        LeafUuids  = $leafUuids.ToArray()
        PriorUuids = $priorUuids.ToArray()
        ChainCount = $chains.Count
    }
}


function Invoke-ClaudeThreadExportBatch
{
    <#
    .SYNOPSIS
        Batch export all threads in a source directory.
    .DESCRIPTION
        Calls Get-ClaudeThreadPlan to discover and group threads, then calls
        Invoke-ClaudeThreadExport once per chain leaf. Prior (non-leaf) sessions
        are passed as -SessionIds so Export-ClaudeThread picks them up automatically.

        Per-thread artifacts land in {BatchRoot}/{leafUuid}/. A shared -MarkdownDir
        accumulates all markdown files flat, one per thread.
    .PARAMETER SourceDir
        Directory containing the UUID-named .jsonl session files.
    .PARAMETER WorkingDir
        Batch root for all pipeline artifacts. Per-thread subdirs are created
        under it as {WorkingDir}/{leafUuid}/. When omitted, defaults to
        `~/.claude/tmp/{projectSlug}/{YYYYMMDD_HHmmss}/`, where `{projectSlug}`
        is the source directory's full leaf folder name
        (e.g. `C--Users-azrie--claude-tools`). Filenames inside still use
        the shorter `{projectLeaf}` (e.g. `tools-{threadId}.jsonl`).
    .PARAMETER MarkdownDir
        Flat output directory for all thread markdown files. Files are named
        `{projectLeaf}-{threadId}.md` (overwrite-in-place — same threadId
        across runs replaces the prior export, giving a "current state" view).
        Defaults to `~/.claude/tmp/markdown/`. Created if absent.
    .PARAMETER RunThrough
        How far to run each thread pipeline. Merged | Exchanges | Markdown (default).
    .PARAMETER UserLabel
        Human speaker label. Passed to every per-thread export. Default: Aipithicus.
    .PARAMETER Format
        Passed to ConvertTo-ClaudeMarkdownV2 for each thread. Default: Structural.
    .PARAMETER Exclude
        Passed to ConvertTo-ClaudeMarkdownV2 for each thread. Default: model-feeding profile.
    .PARAMETER MaxToolInputLength
        Passed to ConvertTo-ClaudeMarkdownV2. Default: 500. $null = no truncation.
    .OUTPUTS
        PSCustomObject { SourceDir, Plan, Results[], Elapsed }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SourceDir,

        [string]$WorkingDir,

        [string]$MarkdownDir,

        [ValidateSet('Merged', 'Exchanges', 'Markdown')]
        [string]$RunThrough = 'Markdown',

        [string]$UserLabel = 'Aipithicus',

        [ValidateSet('Diarized', 'Dialogue', 'Structural', 'House')]
        [string]$Format = 'Structural',

        [ValidateSet('thinking', 'tool-calls', 'tool-results', 'subagents',
            'synthetic', 'timestamps', 'session-markers', 'exchange-markers')]
        [string[]]$Exclude = @('thinking', 'tool-calls', 'tool-results',
            'subagents', 'synthetic', 'timestamps', 'session-markers', 'exchange-markers'),

        [AllowNull()]
        [Nullable[int]]$MaxToolInputLength = 500
    )

    $batchTimer = [System.Diagnostics.Stopwatch]::StartNew()

    # --- Discover and group threads ---
    $plan = Get-ClaudeThreadPlan -SourceDir $SourceDir

    if ($plan.ChainCount -eq 0)
    {
        Write-Warning "No threads found in: $SourceDir"
        $batchTimer.Stop()
        return [PSCustomObject]@{
            SourceDir = $SourceDir
            Plan      = $plan
            Results   = @()
            Elapsed   = $batchTimer.Elapsed
        }
    }

    Write-Host "Batch: $($plan.ChainCount) thread(s), $($plan.AllUuids.Count) session(s) total" -ForegroundColor Cyan
    if ($plan.PriorUuids.Count -gt 0)
    {
        Write-Host "  $($plan.PriorUuids.Count) prior session(s) subsumed into chains (skipped as dispatch targets)" -ForegroundColor Gray
    }

    # --- Derive project identifiers from source dir's leaf folder ---
    # `C:\...\projects\C--Users-azrie--claude-tools` yields:
    #   $sourceLeafFolder = 'C--Users-azrie--claude-tools'  (full slug → working-dir parent)
    #   $projectLeaf      = 'tools'                          (last segment → artifact prefix)
    $sourceLeafFolder = Split-Path -Leaf $SourceDir
    $projectLeaf = ($sourceLeafFolder -split '-' | Where-Object { $_ -ne '' })[-1]
    if (-not $projectLeaf) { $projectLeaf = $sourceLeafFolder }

    # --- Resolve batch working dir root ---
    if (-not $WorkingDir)
    {
        $stamp = [DateTime]::Now.ToString('yyyyMMdd_HHmmss')
        $WorkingDir = [System.IO.Path]::Combine(
            $env:CLAUDE_CONFIG_DIR, 'tmp', $sourceLeafFolder, $stamp)
    }
    $batchRoot = $WorkingDir

    # --- Resolve flat markdown dir default ---
    if (-not $MarkdownDir)
    {
        $MarkdownDir = [System.IO.Path]::Combine(
            $env:CLAUDE_CONFIG_DIR, 'tmp', 'markdown')
    }

    Write-Host "  projectLeaf: $projectLeaf" -ForegroundColor Gray
    Write-Host "  workingDir:  $batchRoot" -ForegroundColor Gray
    Write-Host "  markdownDir: $MarkdownDir" -ForegroundColor Gray

    # --- Dispatch one export per chain leaf ---
    $results = [System.Collections.Generic.List[object]]::new()
    [int]$idx = 0

    foreach ($chain in $plan.Chains)
    {
        $idx++
        $leafUuid = $chain[-1]
        $threadWorkingDir = [System.IO.Path]::Combine($batchRoot, $leafUuid)

        Write-Host "`n[$idx/$($plan.ChainCount)] Thread $leafUuid  ($($chain.Length) session(s))" -ForegroundColor Cyan

        # Pass ONLY the leaf UUID. New-ClaudeThreadManifest does its own
        # sentinel walk against $SourceDir to discover the full chain that
        # terminates at this leaf. Forwarding the full chain here would force
        # the manifest into mtime-only ordering of a pre-curated set, which
        # is unreliable when threads are revisited out of order.
        $exportArgs = @{
            SourceDir          = $SourceDir
            WorkingDir         = $threadWorkingDir
            SessionIds         = [string[]]@($leafUuid)
            RunThrough         = $RunThrough
            UserLabel          = $UserLabel
            Format             = $Format
            Exclude            = $Exclude
            MaxToolInputLength = $MaxToolInputLength
            OutputPrefix       = $projectLeaf
            MarkdownDir        = $MarkdownDir
        }

        $result = Invoke-ClaudeThreadExport @exportArgs
        $results.Add($result)
    }

    $batchTimer.Stop()
    Write-Host "`nBatch complete: $($results.Count) thread(s) in $([math]::Round($batchTimer.Elapsed.TotalSeconds, 1))s" -ForegroundColor Green

    return [PSCustomObject]@{
        SourceDir = $SourceDir
        Plan      = $plan
        Results   = $results.ToArray()
        Elapsed   = $batchTimer.Elapsed
    }
}
