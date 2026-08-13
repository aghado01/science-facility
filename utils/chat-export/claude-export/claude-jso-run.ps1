# claude-jso-run.ps1 — Entrypoint for the Claude Code thread export pipeline
#
# Dot-source this file to get all pipeline functions:
#
#   . "D:\aghado01\science-facility\utils\chat-export\claude-export\claude-jso-run.ps1"
#
#   # by session id — nothing else needed; the transcript locates itself, and
#   # the project slug is a component of the path it resolves to
#   Invoke-ClaudeThreadExport      -SessionId $env:CLAUDE_CODE_SESSION_ID
#   Get-ClaudeThreadPlan           -SessionId $id
#   Invoke-ClaudeThreadExportBatch -SessionId $id -MarkdownDir $outDir
#
#   # by directory — when you are pointing at a project dir yourself
#   Invoke-ClaudeThreadExport      -SourceDir $path
#   Invoke-ClaudeThreadExportBatch -SourceDir $path -MarkdownDir $outDir
#
# AGENTS: do not dot-source this. Use the sibling script instead — it applies
# everyday defaults, takes bound parameters, and dot-sources this file itself:
#   & "…\claude-export\Export-ClaudeChat.ps1" -SessionId $env:CLAUDE_CODE_SESSION_ID
# See README.md.
#
# FUNCTIONS
# ---------
#   Resolve-ClaudeThreadPath      Locate a transcript from its session id alone.
#   Get-ClaudeThreadPlan          Discover and group threads in a directory.
#   Invoke-ClaudeThreadExport     Full or partial pipeline: merged → exchanges → markdown.
#   Invoke-ClaudeThreadExportBatch  Batch: plan all threads, dispatch one export per leaf.
#
# SESSION-ID ENTRY POINT
#   Transcripts live at {configRoot}/projects/{encodedProjectDir}/{sessionId}.jsonl,
#   and session UUIDs are unique across project dirs. Resolve-ClaudeThreadPath
#   probes each project dir for `{sessionId}.jsonl` (one level, no recursion) so a
#   caller holding only $env:CLAUDE_CODE_SESSION_ID can export without knowing the
#   project-dir encoding.
#
#   One lookup yields two facts: the transcript file, and — because the project
#   slug is a component of the path it was found at — the project directory. So
#   every entry point takes -SessionId and nothing else. There is no separate
#   project to name; what differs between them is the verb, not the input.
#   Resolution is fail-loud: malformed id, zero hits, or
#   multiple hits all throw — there is deliberately NO newest-mtime fallback and
#   no content search, because a silent fallback would turn a system fault into a
#   quiet wrong-thread export.
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
#   -MarkdownPath        exact output file path (single-thread only)
#   -MarkdownDir         write {OutputPrefix}-{threadId}.md flat into this directory
#   $env:JSO_EXPORT_DIR  standing deliverable destination; single-thread only,
#                        the batch runner ignores it (see below)
#   (none)               write {OutputPrefix}-{threadId}.md into {WorkingDir}/output/
#
# CLAUDE CONFIG ROOT
#   Both the transcript source ({root}/projects) and the artifact roots
#   ({root}/tmp) hang off one directory, discovered by Get-ClaudeConfigRoot.
#   It honours $env:CLAUDE_CONFIG_DIR when set but never requires it — that
#   variable is empty in most agent shells, and the old
#   `[Path]::Combine($env:CLAUDE_CONFIG_DIR, 'tmp')` therefore produced the
#   RELATIVE path `tmp`, scattering artifacts under the caller's cwd.
#
# WORKING DIRECTORY — single thread
#   Defaults to {configRoot}/tmp/claude-jso-run/{timestamp}/ via New-JobWorkingDir.
#   Pass -WorkingDir to override. Directory creation for all pipeline stages
#   is handled by each stage function — this script does none of it.
#
# WORKING DIRECTORY — batch
#   Defaults to {configRoot}/tmp/{projectSlug}/{YYYYMMDD_HHmmss}/, where
#   {projectSlug} is the full slug of the source dir's leaf name
#   (e.g. `C--Users-azrie--claude-tools`). Per-thread artifacts
#   land in {BatchRoot}/{leafUuid}/. Pass -WorkingDir to override.
#
# MARKDOWN DIRECTORY — batch default
#   Defaults to {configRoot}/tmp/markdown/ (flat, project-agnostic). Files are
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

function Resolve-ClaudeThreadPath
{
    <#
    .SYNOPSIS
        Locate a Claude Code transcript from its session id alone.
    .DESCRIPTION
        Transcripts are stored at {configRoot}/projects/{encodedProjectDir}/{sessionId}.jsonl.
        Session UUIDs are unique across project dirs, so the id alone is a
        sufficient key. This function probes every project dir for a file named
        `{sessionId}.jsonl` — one level deep, filename-only, no recursion.

        Deriving the project dir from the current working directory is
        deliberately NOT done: that would re-implement an undocumented encoding
        convention, and it would be wrong when exporting a thread that ran under
        a different cwd. Probing by UUID is exact in both cases.

        Resolution is fail-loud by design. A malformed id, zero hits, or more
        than one hit all throw. There is no newest-mtime fallback and no content
        search: an unresolvable session id signals a system fault, and a silent
        fallback would downgrade that fault into a quiet wrong-thread export.

        Nested non-UUID .jsonl strays exist below some project dirs; the
        one-level probe excludes them by construction.
    .PARAMETER SessionId
        The session UUID (transcript basename), e.g. from $env:CLAUDE_CODE_SESSION_ID.
        Note that $env:CLAUDE_CODE_HOST_SESSION_ID is a different id and is NOT
        the transcript key.
    .PARAMETER ConfigRoot
        Optional override for the Claude config root. When omitted the root is
        discovered by Get-ClaudeConfigRoot, which honours $env:CLAUDE_CONFIG_DIR
        when set but never requires it — it is empty in most agent shells.
    .OUTPUTS
        PSCustomObject { SessionId, JsonlPath, SourceDir, ProjectName, ConfigRoot }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SessionId,

        [string]$ConfigRoot
    )

    # --- Resolve the config root (throws if none holds a projects/ directory) ---
    $ConfigRoot = Get-ClaudeConfigRoot -ConfigRoot $ConfigRoot -RequireProjects
    $projectsRoot = Get-ClaudeProjectsRoot -ConfigRoot $ConfigRoot

    # --- Validate before probing: reject malformed ids rather than search for them ---
    $uuidPattern = '^[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}$'
    $regexOpts = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor
                 [System.Text.RegularExpressions.RegexOptions]::CultureInvariant
    if (-not [System.Text.RegularExpressions.Regex]::IsMatch($SessionId, $uuidPattern, $regexOpts))
    {
        throw "Malformed session id: '$SessionId'. Expected a UUID of the form 8-4-4-4-12 hex digits."
    }

    # --- Probe each project dir for {sessionId}.jsonl (one level, no recursion) ---
    $fileName = "$SessionId.jsonl"
    $hits = [System.Collections.Generic.List[string]]::new()

    foreach ($dir in [System.IO.Directory]::EnumerateDirectories($projectsRoot))
    {
        $candidate = [System.IO.Path]::Combine($dir, $fileName)
        if ([System.IO.File]::Exists($candidate)) { $hits.Add($candidate) }
    }

    if ($hits.Count -eq 0)
    {
        throw "No transcript found for session $SessionId under $projectsRoot"
    }

    if ($hits.Count -gt 1)
    {
        # Empirically impossible (UUIDs are unique across project dirs); if it
        # ever happens it is exactly the anomaly class this resolver must scream about.
        throw ("Ambiguous session id $SessionId — $($hits.Count) transcripts found:`n  " +
            ($hits -join "`n  "))
    }

    $jsonlPath = $hits[0]
    $sourceDir = [System.IO.Path]::GetDirectoryName($jsonlPath)

    return [PSCustomObject]@{
        SessionId   = $SessionId
        JsonlPath   = $jsonlPath
        SourceDir   = $sourceDir
        ProjectName = [System.IO.Path]::GetFileName($sourceDir)
        ConfigRoot  = $ConfigRoot
    }
}


function Invoke-ClaudeThreadExport
{
    <#
    .SYNOPSIS
        Run the Claude thread export pipeline for a single source directory.
    .DESCRIPTION
        Orchestrates Export-ClaudeThread → Get/Export-ClaudeExchanges →
        ConvertTo-ClaudeMarkdownV2 in sequence. Use -RunThrough to stop after
        any stage. All directory creation is delegated to the stage functions.

        Two entry points:
          BySourceDir (default)  -SourceDir [-SessionIds]  — original behaviour.
          BySessionId            -SessionId [-ConfigRoot]   — Resolve-ClaudeThreadPath
                                 locates the transcript, supplying SourceDir and
                                 pinning SessionIds to the one id. Downstream
                                 stages are unchanged: the chain walk in
                                 New-ClaudeThreadManifest still operates within
                                 the resolved SourceDir and picks up prior
                                 sessions in the chain.
    .PARAMETER SourceDir
        Directory containing the UUID-named .jsonl session files.
    .PARAMETER SessionIds
        Optional. Limit discovery to specific session UUIDs.
    .PARAMETER SessionId
        A single session UUID (e.g. $env:CLAUDE_CODE_SESSION_ID). The transcript
        directory is resolved via Resolve-ClaudeThreadPath; throws if the id is
        malformed or does not resolve to exactly one transcript.
    .PARAMETER ConfigRoot
        Optional override for the Claude config root when using -SessionId.
        See Resolve-ClaudeThreadPath.
    .PARAMETER WorkingDir
        Root for all JSONL pipeline artifacts (raw/, merged/, exchanges/).
        Defaults to a timestamped directory under {configRoot}/tmp/claude-jso-run/,
        where the root is discovered by Get-ClaudeConfigRoot.
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
    .PARAMETER NormalizeWhitespace
        Passed to ConvertTo-ClaudeMarkdownV2. Default: $true. Set to $false to
        bypass only the final Markdown postprocessor.
    .PARAMETER OutputEncoding
        Markdown file encoding passed to ConvertTo-ClaudeMarkdownV2. Default:
        Utf8. Utf16LE is the code-unit-preserving forensic option.
    .PARAMETER OutputPrefix
        Filename stem for merged, exchanges, and markdown artifacts:
        `{OutputPrefix}-{threadId}.{jsonl|md}`. Default `'thread'`. Batch runs
        pass the project leaf (e.g. `'tools'`).
    .OUTPUTS
        PSCustomObject { ThreadId, WorkingDir, MergedPath, ExchangesPath,
        MarkdownPath, NormalizeWhitespace, OutputEncoding, Stats }
        Paths for stages not reached are $null.
    #>
    [CmdletBinding(DefaultParameterSetName = 'BySourceDir')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'BySourceDir')]
        [string]$SourceDir,

        [Parameter(ParameterSetName = 'BySourceDir')]
        [string[]]$SessionIds,

        [Parameter(Mandatory, ParameterSetName = 'BySessionId')]
        [string]$SessionId,

        [Parameter(ParameterSetName = 'BySessionId')]
        [string]$ConfigRoot,

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

        [bool]$NormalizeWhitespace = $true,

        [ValidateSet('Utf8', 'Utf16LE')]
        [string]$OutputEncoding = 'Utf8',

        [string]$OutputPrefix = 'thread'
    )

    $timer = [System.Diagnostics.Stopwatch]::StartNew()

    # --- Resolve transcript location from the session id, if that is the entry point ---
    if ($PSCmdlet.ParameterSetName -eq 'BySessionId')
    {
        # An empty -ConfigRoot falls through to discovery, so it can be passed
        # through unconditionally.
        $resolved = Resolve-ClaudeThreadPath -SessionId $SessionId -ConfigRoot $ConfigRoot
        $SourceDir  = $resolved.SourceDir
        $SessionIds = [string[]]@($SessionId)

        Write-Host "Resolved session $SessionId → $($resolved.ProjectName)" -ForegroundColor Gray
    }

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
            NormalizeWhitespace = $NormalizeWhitespace
            OutputEncoding = $OutputEncoding
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
            NormalizeWhitespace = $NormalizeWhitespace
            OutputEncoding = $OutputEncoding
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
    elseif ($env:JSO_EXPORT_DIR)
    {
        # Standing destination for single-thread deliverables. Unlike the working
        # dir, this is a preference and not discoverable, so declaring it in the
        # environment is the only way to have a default at all. A per-call
        # -MarkdownDir still wins. Deliberately NOT consulted by the batch runner,
        # which would dump a hundred files into it.
        [System.IO.Path]::Combine($env:JSO_EXPORT_DIR, "$OutputPrefix-$threadId.md")
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
        -MaxToolInputLength  $MaxToolInputLength `
        -NormalizeWhitespace $NormalizeWhitespace `
        -OutputEncoding      $OutputEncoding

    $timer.Stop()
    return [PSCustomObject]@{
        ThreadId      = $threadId
        WorkingDir    = $WorkingDir
        MergedPath    = $mergedPath
        ExchangesPath = $exchangesPath
        MarkdownPath  = $resolvedMarkdownPath
        NormalizeWhitespace = $NormalizeWhitespace
        OutputEncoding = $OutputEncoding
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
    .PARAMETER SessionId
        Any session UUID belonging to the directory you want planned. Resolving
        the id yields its transcript path, and the project slug is a component
        of that path — so one lookup produces both the file and its directory,
        and there is nothing further to specify.

        This function plans a directory, so that is what it does with the
        resolved location. The scope lives in the function's name, not in the
        parameter's: `Get-ClaudeThreadPlan` returns chains, `Invoke-ClaudeThreadExport`
        exports the one thread. Same input, different verb.
    .PARAMETER ConfigRoot
        Optional override for the Claude config root. See Get-ClaudeConfigRoot.
    .OUTPUTS
        PSCustomObject {
            SourceDir, AllUuids, Chains, LeafUuids, PriorUuids, ChainCount
        }
    #>
    [CmdletBinding(DefaultParameterSetName = 'BySourceDir')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'BySourceDir')]
        [string]$SourceDir,

        [Parameter(Mandatory, ParameterSetName = 'BySessionId')]
        [string]$SessionId,

        [Parameter(ParameterSetName = 'BySessionId')]
        [string]$ConfigRoot
    )

    if ($PSCmdlet.ParameterSetName -eq 'BySessionId')
    {
        $SourceDir = (Resolve-ClaudeThreadPath -SessionId $SessionId -ConfigRoot $ConfigRoot).SourceDir
    }

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
    .PARAMETER SessionId
        Any session UUID belonging to the directory you want batched. Resolving
        the id yields its transcript path, and the project slug is a component
        of that path, so the directory comes with it — nothing else to specify.

        Being a batch runner, this exports every chain in that directory, which
        for a busy project is 100+ threads. The verb is the warning; the thread
        count is echoed before any work starts.
    .PARAMETER ConfigRoot
        Optional override for the Claude config root. See Get-ClaudeConfigRoot.
    .PARAMETER WorkingDir
        Batch root for all pipeline artifacts. Per-thread subdirs are created
        under it as {WorkingDir}/{leafUuid}/. When omitted, defaults to
        `{configRoot}/tmp/{projectSlug}/{YYYYMMDD_HHmmss}/`, where `{projectSlug}`
        is the source directory's full leaf folder name
        (e.g. `C--Users-azrie--claude-tools`). Filenames inside still use
        the shorter `{projectLeaf}` (e.g. `tools-{threadId}.jsonl`).
    .PARAMETER MarkdownDir
        Flat output directory for all thread markdown files. Files are named
        `{projectLeaf}-{threadId}.md` (overwrite-in-place — same threadId
        across runs replaces the prior export, giving a "current state" view).
        Defaults to `{configRoot}/tmp/markdown/`. Created if absent.
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
    .PARAMETER NormalizeWhitespace
        Passed through to every per-thread renderer. Default: $true. Set to
        $false to bypass only the final Markdown postprocessor.
    .PARAMETER OutputEncoding
        Markdown file encoding passed through to every thread renderer.
        Default: Utf8. Utf16LE is the code-unit-preserving forensic option.
    .OUTPUTS
        PSCustomObject { SourceDir, Plan, Results[], NormalizeWhitespace,
        OutputEncoding, Elapsed }
    #>
    [CmdletBinding(DefaultParameterSetName = 'BySourceDir')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'BySourceDir')]
        [string]$SourceDir,

        [Parameter(Mandatory, ParameterSetName = 'BySessionId')]
        [string]$SessionId,

        [Parameter(ParameterSetName = 'BySessionId')]
        [string]$ConfigRoot,

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
        [Nullable[int]]$MaxToolInputLength = 500,

        [bool]$NormalizeWhitespace = $true,

        [ValidateSet('Utf8', 'Utf16LE')]
        [string]$OutputEncoding = 'Utf8'
    )

    $batchTimer = [System.Diagnostics.Stopwatch]::StartNew()

    if ($PSCmdlet.ParameterSetName -eq 'BySessionId')
    {
        $resolved = Resolve-ClaudeThreadPath -SessionId $SessionId -ConfigRoot $ConfigRoot
        $SourceDir = $resolved.SourceDir
        Write-Host "Resolved session $SessionId → project $($resolved.ProjectName)" -ForegroundColor Gray
    }

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
            NormalizeWhitespace = $NormalizeWhitespace
            OutputEncoding = $OutputEncoding
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
        $stamp = Get-JobTimestamp
        $WorkingDir = [System.IO.Path]::Combine(
            (Get-ClaudeConfigRoot), 'tmp', $sourceLeafFolder, $stamp)
    }
    $batchRoot = $WorkingDir

    # --- Resolve flat markdown dir default ---
    if (-not $MarkdownDir)
    {
        $MarkdownDir = [System.IO.Path]::Combine(
            (Get-ClaudeConfigRoot), 'tmp', 'markdown')
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
            NormalizeWhitespace = $NormalizeWhitespace
            OutputEncoding     = $OutputEncoding
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
        NormalizeWhitespace = $NormalizeWhitespace
        OutputEncoding = $OutputEncoding
        Elapsed   = $batchTimer.Elapsed
    }
}
