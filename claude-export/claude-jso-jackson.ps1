

# claude-jso-jackson.ps1 — Claude Code session export: thread discovery + merged JSONL
#
# Dot-source this file to get the Claude-specific layer on top of jso-jackson.ps1:
#
#   . "$env:CLAUDE_CONFIG_DIR\tools\claude-jso-jackson.ps1"
#
# This file dot-sources jso-jackson.ps1 automatically.
#
# CLASSES
# ------
#   ClaudeSessionManifest   Thread manifest: ordered sessions + lateral file lists.
#   ClaudeRecordAnnotator   Stamps provenance fields onto JsonElement before write.
#   ClaudeThreadExporter    Orchestrates: discover → snapshot → traverse → merge → write.
#
# FUNCTIONS
# ---------
#   New-ClaudeThreadManifest   Discover all sessions + sidecars for a thread.
#   Export-ClaudeThread         Full pipeline: manifest → snapshots → merged JSONL + .jidx.
#
# DESIGN CONTRACT
# ---------------
#   - This file IS a user-facing entry point. jso-jackson.ps1 is not.
#   - Takes JsonElement[] from jso-jackson's Stream(), transforms to annotated
#     JSONL output.
#
#   LAYER BOUNDARY:
#   - jso-jackson.ps1 owns the read path: System.Text.Json land, no PSCustomObject.
#   - This file owns the write path: PSCustomObject is permitted and expected here.
#   - All JSON output goes through ConvertTo-CanonicalJson -Compress (from base).
#     No manual string construction. No hand-rolled escaping. Ever.
#
#   ANNOTATION:
#   - ClaudeRecordAnnotator.Annotate() deserializes the JsonElement into a
#     PSCustomObject via ConvertFrom-Json, merges annotation fields via
#     Merge-JsonObjects, then serializes via ConvertTo-CanonicalJson -Compress.
#   - Depth is computed automatically — never hardcoded.
#
#   DEDUP:
#   - Assistant record dedup: last occurrence wins per message.id.
#   - Uses bloom filter + HashSet hybrid from base (no false negatives).
#
#   TOOL MATCHING:
#   - Two-pass: pre-scan all records in Get-ClaudeExchanges to build a global
#     Dictionary<tool_use_id, (resultBlock, carrierTimestamp)> before decomposition.
#     This ensures tool_use blocks always have their results available regardless
#     of record ordering. The pendingToolResults side-channel approach is removed.
#
#   FILTERING:
#   - Minimal for first deliverable: drop queue-operation, system, attachment,
#     last-prompt. Exclude isMeta, isCompactSummary. Keep everything else
#     including tool-result carriers (consumed in pre-scan pass).
#   - Ordering: chronological by timestamp within each session, sessions by depth.
#
# DEPENDENCY
# ----------
#   jso-jackson.ps1 (dot-sourced below).
# -----------------------------------------------------------------------

$ErrorActionPreference = 'Stop'

# --- Dot-source base engine ---
. "$PSScriptRoot\jso-jackson.ps1"

#region --- ClaudeSessionManifest ---

class ClaudeSessionManifest
{
    # Ordered list of session entries, oldest first (depth 0 = root)
    [System.Collections.Generic.List[hashtable]] $Sessions

    # Thread ID — derived from the root session UUID
    [string] $ThreadId

    # Source directory containing the JSONL files
    [string] $SourceDir

    ClaudeSessionManifest([string]$sourceDir)
    {
        $this.SourceDir = $sourceDir
        $this.Sessions = [System.Collections.Generic.List[hashtable]]::new()
    }

    [void] AddSession([hashtable]$entry)
    {
        $this.Sessions.Add($entry)
    }

    [int] SessionCount() { return $this.Sessions.Count }

    [int] TotalFileCount()
    {
        [int]$count = 0
        foreach ($s in $this.Sessions)
        {
            $count++  # main session file
            $count += $s.SubagentFiles.Count
        }
        return $count
    }
}

#endregion

#region --- Thread Discovery ---

function New-ClaudeThreadManifest
{
    <#
    .SYNOPSIS
        Discover all sessions and sidecars for a Claude Code thread.
    .DESCRIPTION
        Given a source directory containing Claude Code JSONL exports, enumerates
        session files, discovers lateral sidecars (subagents/, tool-results/),
        and builds an ordered manifest.

        THREAD SCOPING / MOONWALK:
        Sessions are linked into threads via a filesystem-level signal, not
        via pointers inside the JSONL records. Claude Code records carry no
        `parent_session_id`; the only on-disk evidence that two sessions
        belong to the same thread is the `.jsonl.idx` sentinel.

        The sentinel:
            When a session is continued (the user resumes the conversation
            in a new session), Claude Code writes a zero-byte sentinel file
            named `<priorUuid>.jsonl.idx` next to the prior session's JSONL.
            The sentinel's existence — not its contents, size, or mtime —
            is the entire signal. It says "this session has a successor";
            it does NOT name the successor.

        The Jackson "moonwalk":
            Within a project directory, every UUID-named `.jsonl` is sorted
            by `LastWriteTimeUtc` and walked oldest-first. Each session is
            appended to the current chain. A session WITHOUT a sentinel
            terminates the chain (it is a leaf). The next session begins a
            new chain. Result: the directory partitions into one or more
            disjoint chains, each ending in a leaf.
                chain depth 0  -> oldest, sentinel present (root, continued)
                chain depth 1  -> sentinel present (continued)
                ...
                chain depth N  -> NO sentinel (current leaf)

        Why mtime within a chain is sound:
            mtime is unreliable for ABSOLUTE ordering across the directory
            (returning to an older thread bumps its mtime above unrelated
            newer threads), but within a single chain the prior must have
            been finalized before the successor began writing. The sentinel
            walk uses mtime only to establish relative order between members
            already known to belong to one chain via the sentinel pattern.

        Selecting one chain:
            With `-SessionIds`, the first id is treated as the leaf target;
            the chain that terminates at that leaf is returned. Without
            `-SessionIds`, the entire directory is collapsed into one
            ordered set (legacy single-thread direct-call mode).

        Edge case — trailing open chain:
            If the directory ends with one or more sentinel-bearing sessions
            and no terminating leaf, the accumulated set is flushed as an
            open chain. This is a prior whose successor is not (yet) on
            disk — usually a continued session whose continuation lives in
            a different project slug, or one that has not been written.

        HasIdxSentinel is recorded per-session on the manifest so callers
        can distinguish the leaf from its ancestors without re-stat'ing.

    .PARAMETER SourceDir
        Directory containing the .jsonl session files and companion subdirectories.
    .PARAMETER SessionIds
        Optional: limit to specific session UUIDs. If omitted, discovers all.
    .OUTPUTS
        ClaudeSessionManifest
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SourceDir,

        [string[]]$SessionIds
    )

    if (-not [System.IO.Directory]::Exists($SourceDir))
    {
        throw "Source directory not found: $SourceDir"
    }

    $manifest = [ClaudeSessionManifest]::new($SourceDir)

    # Discover ALL UUID-named .jsonl files at top level (no UUID filter yet —
    # chain resolution needs the full directory to walk sentinels correctly).
    $jsonlFiles = [System.IO.Directory]::GetFiles($SourceDir, '*.jsonl')
    $uuidPattern = '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.jsonl$'
    $sessionFiles = [System.Collections.Generic.List[System.IO.FileInfo]]::new()

    foreach ($f in $jsonlFiles)
    {
        $fi = [System.IO.FileInfo]::new($f)
        if ($fi.Name -match $uuidPattern) { $sessionFiles.Add($fi) }
    }

    # Initial sort by last-write time. Timestamps are not reliable for absolute
    # ordering across the directory (returning to an older thread bumps its
    # mtime), but they remain the only signal for relative order WITHIN a chain
    # since records carry no explicit parent-session pointer. Chain MEMBERSHIP
    # is established by the .jsonl.idx sentinel walk below, not by mtime.
    $allSorted = $sessionFiles | Sort-Object LastWriteTimeUtc

    # Group into chains via sentinel walk (same logic as Get-ClaudeThreadPlan).
    # Accumulate sessions into the current chain until one without an .idx
    # sentinel closes it. A trailing chain with only sentinel-bearing sessions
    # is flushed as an open chain (prior whose successor is not in this dir).
    $chains = [System.Collections.Generic.List[System.Collections.Generic.List[System.IO.FileInfo]]]::new()
    $currentChain = [System.Collections.Generic.List[System.IO.FileInfo]]::new()

    foreach ($sf in $allSorted)
    {
        $currentChain.Add($sf)
        $hasIdx = [System.IO.File]::Exists($sf.FullName + '.idx')
        if (-not $hasIdx)
        {
            $chains.Add($currentChain)
            $currentChain = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
        }
    }
    if ($currentChain.Count -gt 0) { $chains.Add($currentChain) }

    # Resolve which chain to materialise.
    #   With -SessionIds: the first id is treated as the LEAF UUID; we return
    #     the chain that terminates with it. Additional ids are ignored — chain
    #     membership comes from the sentinel walk, not from the caller.
    #   Without -SessionIds: legacy single-thread direct-call mode — treat the
    #     entire directory as one synthetic chain (preserves old behaviour for
    #     callers that pre-curated the source dir).
    if ($SessionIds -and $SessionIds.Count -gt 0)
    {
        $leafTarget = $SessionIds[0]
        $matchedChain = $null
        foreach ($chain in $chains)
        {
            $leafFile = $chain[$chain.Count - 1]
            $leafUuid = [System.IO.Path]::GetFileNameWithoutExtension($leafFile.Name)
            if ($leafUuid -eq $leafTarget) { $matchedChain = $chain; break }
        }
        if (-not $matchedChain)
        {
            throw "No chain found terminating with leaf UUID: $leafTarget"
        }
        $ordered = $matchedChain
    }
    else
    {
        $ordered = $allSorted
    }

    [int]$depth = 0
    foreach ($sf in $ordered)
    {
        $sessionUuid = [System.IO.Path]::GetFileNameWithoutExtension($sf.Name)

        # Discover companion directory
        $companionDir = [System.IO.Path]::Combine($SourceDir, $sessionUuid)
        $subagentFiles = [System.Collections.Generic.List[hashtable]]::new()
        $toolResultFiles = [System.Collections.Generic.List[string]]::new()
        $hasIdxSentinel = $false

        # Check for Claude's .idx sentinel (zero-byte compaction marker)
        $idxPath = $sf.FullName + '.idx'
        if ([System.IO.File]::Exists($idxPath))
        {
            $hasIdxSentinel = $true
        }

        if ([System.IO.Directory]::Exists($companionDir))
        {
            # Subagents
            $subagentDir = [System.IO.Path]::Combine($companionDir, 'subagents')
            if ([System.IO.Directory]::Exists($subagentDir))
            {
                $agentJsonls = [System.IO.Directory]::GetFiles($subagentDir, 'agent-*.jsonl')
                foreach ($aj in $agentJsonls)
                {
                    $agentId = [System.IO.Path]::GetFileNameWithoutExtension($aj)
                    $metaPath = [System.IO.Path]::ChangeExtension($aj, '.meta.json')

                    $agentType = $null
                    $agentDesc = $null
                    if ([System.IO.File]::Exists($metaPath))
                    {
                        $metaText = [System.IO.File]::ReadAllText($metaPath)
                        try
                        {
                            $metaEl = [System.Text.Json.JsonSerializer]::Deserialize(
                                $metaText, [System.Text.Json.JsonElement])
                            try { $agentType = $metaEl.GetProperty('agentType').GetString() } catch {}
                            try { $agentDesc = $metaEl.GetProperty('description').GetString() } catch {}
                        }
                        catch {}
                    }

                    $subagentFiles.Add(@{
                            SourcePath  = $aj
                            AgentId     = $agentId
                            AgentType   = $agentType
                            Description = $agentDesc
                        })
                }
            }

            # Tool results
            $toolResultDir = [System.IO.Path]::Combine($companionDir, 'tool-results')
            if ([System.IO.Directory]::Exists($toolResultDir))
            {
                $trFiles = [System.IO.Directory]::GetFiles($toolResultDir)
                foreach ($tr in $trFiles)
                {
                    $toolResultFiles.Add($tr)
                }
            }
        }

        $manifest.AddSession(@{
                SessionUuid     = $sessionUuid
                SourcePath      = $sf.FullName
                Depth           = $depth
                HasIdxSentinel  = $hasIdxSentinel
                SubagentFiles   = $subagentFiles
                ToolResultFiles = $toolResultFiles
            })

        $depth++
    }

    # Thread ID = root session UUID
    if ($manifest.Sessions.Count -gt 0)
    {
        $manifest.ThreadId = $manifest.Sessions[0].SessionUuid
    }

    return $manifest
}

#endregion

#region --- Current Session Locator ---

function ConvertTo-ClaudeProjectSlug
{
    <#
    .SYNOPSIS
        Encode a working-directory path into Claude Code's project slug.
    .DESCRIPTION
        Claude Code stores per-project session JSONLs under
        `~/.claude/projects/<slug>/`, where the slug is the absolute working
        directory with `:`, `\`, and `.` each replaced by `-`. Drive letter
        casing is preserved. No collapsing of consecutive `-`s.

        Examples:
            C:\Users\azrie\.claude\tools          -> C--Users-azrie--claude-tools
            c:\Users\azrie\PDenv\ps.core.pwshspc  -> c--Users-azrie-PDenv-ps-core-pwshspc
    .PARAMETER Path
        Absolute working-directory path. Defaults to $PWD.Path.
    .OUTPUTS
        [string] project slug
    #>
    [CmdletBinding()]
    param(
        [string]$Path = $PWD.Path
    )

    return ($Path -replace '[:\\.]', '-')
}

function Get-ClaudeCurrentSessionFile
{
    <#
    .SYNOPSIS
        Best-guess locator for the JSONL backing the *currently active* session.
    .DESCRIPTION
        Heuristic for entry points like an in-session "export this thread" skill
        that need to identify which JSONL the chat participant is running inside.
        Claude Code does not expose the live session UUID via env var.

        Algorithm:
            1. Encode CWD to project slug (see ConvertTo-ClaudeProjectSlug).
            2. Resolve `<ProjectsRoot>/<slug>/`.
            3. Enumerate UUID-named .jsonl files at that root, skip any with
               a `.jsonl.idx` sentinel (those are priors of continued chains).
            4. Return the leaf with the most recent LastWriteTimeUtc.

        Why mtime is OK *here* (unlike chain resolution): for "current session"
        the active JSONL is by definition the file being written to right now,
        so its mtime IS the most recent at the moment of lookup. The unreliable-
        mtime hazard for cross-thread ordering does not apply to a single-point
        snapshot of "which file moved last."

        Returns $null when the project slug directory does not exist (no Claude
        history for this CWD) or no leaf candidates are found. Throws only when
        $ProjectsRoot itself is missing (catastrophic config).
    .PARAMETER Cwd
        Working directory to translate into a project slug. Defaults to $PWD.Path.
    .PARAMETER ProjectsRoot
        Root of Claude Code's per-project storage. Defaults to
        `$env:CLAUDE_CONFIG_DIR/projects`.
    .OUTPUTS
        PSCustomObject {
            ProjectSlug, ProjectDir, SessionUuid, SessionPath, LastWriteTimeUtc
        }
        or $null if no candidate is found.
    #>
    [CmdletBinding()]
    param(
        [string]$Cwd = $PWD.Path,

        [string]$ProjectsRoot = (Join-Path $env:CLAUDE_CONFIG_DIR 'projects')
    )

    if (-not [System.IO.Directory]::Exists($ProjectsRoot))
    {
        throw "Claude projects root not found: $ProjectsRoot"
    }

    $slug = ConvertTo-ClaudeProjectSlug -Path $Cwd
    $projectDir = [System.IO.Path]::Combine($ProjectsRoot, $slug)

    if (-not [System.IO.Directory]::Exists($projectDir)) { return $null }

    $uuidPattern = '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.jsonl$'
    $jsonlFiles = [System.IO.Directory]::GetFiles($projectDir, '*.jsonl')

    $bestFile = $null
    foreach ($f in $jsonlFiles)
    {
        $fi = [System.IO.FileInfo]::new($f)
        if ($fi.Name -notmatch $uuidPattern) { continue }
        if ([System.IO.File]::Exists($fi.FullName + '.idx')) { continue }
        if ($null -eq $bestFile -or $fi.LastWriteTimeUtc -gt $bestFile.LastWriteTimeUtc)
        {
            $bestFile = $fi
        }
    }

    if ($null -eq $bestFile) { return $null }

    return [PSCustomObject]@{
        ProjectSlug      = $slug
        ProjectDir       = $projectDir
        SessionUuid      = [System.IO.Path]::GetFileNameWithoutExtension($bestFile.Name)
        SessionPath      = $bestFile.FullName
        LastWriteTimeUtc = $bestFile.LastWriteTimeUtc
    }
}

#endregion

#region --- Export-ClaudeThread ---

function Export-ClaudeThread
{
    <#
    .SYNOPSIS
        Full pipeline: discover thread → snapshot all files → merge → write unified JSONL + .jidx.
    .DESCRIPTION
        First deliverable: flat chronological merged JSONL with all sessions and subagents,
        deduplicated on message.id (last wins), minimally filtered, annotated with provenance.

        Writes to $WorkingDir/raw/ (per-file snapshots) and $WorkingDir/merged/ (unified output).

    .PARAMETER SourceDir
        Directory containing the .jsonl session files.
    .PARAMETER WorkingDir
        Job working directory (minted by New-JobWorkingDir or caller).
    .PARAMETER SessionIds
        Optional: limit to specific session UUIDs.
    .PARAMETER OutputPrefix
        Filename stem for merged output: `{OutputPrefix}-{threadId}.jsonl`.
        Default `'thread'`. Batch runs override this with the project leaf
        (e.g. `'tools'`) so artifacts self-identify across directories.
    .OUTPUTS
        PSCustomObject with MergedPath, IndexPath, RecordCount, Manifest, Stats.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SourceDir,

        [Parameter(Mandatory)]
        [string]$WorkingDir,

        [string[]]$SessionIds,

        [string]$OutputPrefix = 'thread'
    )

    $exportStarted = [System.Diagnostics.Stopwatch]::StartNew()

    # --- Phase 0: Discover ---
    Write-Host "Discovering thread..." -ForegroundColor Cyan
    $manifest = New-ClaudeThreadManifest -SourceDir $SourceDir -SessionIds $SessionIds

    if ($manifest.SessionCount() -eq 0)
    {
        throw "No session files found in: $SourceDir"
    }

    Write-Host "  Sessions: $($manifest.SessionCount())" -ForegroundColor Gray
    Write-Host "  Total files: $($manifest.TotalFileCount())" -ForegroundColor Gray

    # --- Phase 1: Snapshot all files into raw/ ---
    Write-Host "Snapshotting to raw/..." -ForegroundColor Cyan
    $rawDir = [System.IO.Path]::Combine($WorkingDir, 'raw')
    [void][System.IO.Directory]::CreateDirectory($rawDir)

    # Track snapshot results keyed by a normalized name
    $snapshots = [System.Collections.Generic.List[hashtable]]::new()

    foreach ($session in $manifest.Sessions)
    {
        $sessionUuid = $session.SessionUuid
        $depth = $session.Depth

        # Snapshot main session file
        $sessionFileName = "session-$sessionUuid.jsonl"
        $snap = New-JsonlSnapshot -SourcePath $session.SourcePath `
            -WorkingDir $rawDir -FileName $sessionFileName

        $snapshots.Add(@{
                SnapshotPath = $snap.SnapshotPath
                IndexPath    = $snap.IndexPath
                LineCount    = $snap.LineCount
                SessionUuid  = $sessionUuid
                Depth        = $depth
                IsLateral    = $false
                AgentId      = $null
                AgentType    = $null
                AgentDesc    = $null
            })

        Write-Host "  session-$sessionUuid  ($($snap.LineCount) lines)" -ForegroundColor Gray

        # Snapshot subagent files
        foreach ($sub in $session.SubagentFiles)
        {
            $subFileName = "subagent-$sessionUuid-$($sub.AgentId).jsonl"
            $subSnap = New-JsonlSnapshot -SourcePath $sub.SourcePath `
                -WorkingDir $rawDir -FileName $subFileName

            $snapshots.Add(@{
                    SnapshotPath = $subSnap.SnapshotPath
                    IndexPath    = $subSnap.IndexPath
                    LineCount    = $subSnap.LineCount
                    SessionUuid  = $sessionUuid
                    Depth        = $depth
                    IsLateral    = $true
                    AgentId      = $sub.AgentId
                    AgentType    = $sub.AgentType
                    AgentDesc    = $sub.Description
                })

            Write-Host "    $($sub.AgentId)  ($($subSnap.LineCount) lines)" -ForegroundColor DarkGray
        }
    }

    # --- Phase 2: Traverse, filter, dedup, annotate, merge ---
    Write-Host "Merging..." -ForegroundColor Cyan

    # Collect all annotated records into a single list for global timestamp sort
    $allRecords = [System.Collections.Generic.List[string]]::new()

    # message.id dedup tracker — global across all sessions.
    # Stores index into $allRecords so we can replace with later occurrence.
    $msgIdIndex = [System.Collections.Generic.Dictionary[string, int]]::new()

    # Stats
    [int]$totalRead = 0
    [int]$totalFiltered = 0
    [int]$totalDeduped = 0

    foreach ($snapInfo in $snapshots)
    {
        $file = [JsonlFile]::MountSnapshot($snapInfo.SnapshotPath, $snapInfo.IndexPath)

        # Traverse with minimal Claude-aware filtering:
        # - Include only user + assistant (drop queue-operation, system, attachment, last-prompt)
        # - Exclude isMeta, isCompactSummary
        $traversal = $file.Traverse().
        IncludePathValues('type', @('user', 'assistant')).
        ExcludeWhenTrue(@('isMeta', 'isCompactSummary'))

        $elements = $traversal.Stream()
        $totalRead += $snapInfo.LineCount

        foreach ($el in $elements)
        {
            $totalFiltered++

            # Build annotated JSON string: inject provenance fields into the record
            $annotatedJson = [ClaudeRecordAnnotator]::Annotate(
                $el,
                $snapInfo.SessionUuid,
                $snapInfo.Depth,
                $snapInfo.IsLateral,
                $snapInfo.AgentId,
                $snapInfo.AgentType,
                $snapInfo.AgentDesc,
                [System.IO.Path]::GetFileName($snapInfo.SnapshotPath)
            )

            if ([string]::IsNullOrWhiteSpace($annotatedJson))
            {
                Write-Verbose "Skipping empty annotated record from $($snapInfo.SnapshotPath)"
                continue
            }

            # Assistant dedup: if message.id exists and we've seen it before, replace
            $msgId = [JsonlTraversal]::GetElementValue($el, 'message.id')

            if ($null -ne $msgId -and $msgId -is [string] -and $msgId.Length -gt 0)
            {
                $msgIdStr = [string]$msgId
                if ($msgIdIndex.ContainsKey($msgIdStr))
                {
                    # Replace earlier occurrence with this one (last wins)
                    $prevIdx = $msgIdIndex[$msgIdStr]
                    $allRecords[$prevIdx] = $null  # mark for removal
                    $totalDeduped++
                }
                $msgIdIndex[$msgIdStr] = $allRecords.Count
            }

            $allRecords.Add($annotatedJson)
        }
    }

    # Remove deduped earlier occurrences. Assigning $null into List[string]
    # stores an empty string in PowerShell, so filter whitespace as well.
    $finalRecords = [System.Collections.Generic.List[string]]::new($allRecords.Count)
    foreach ($r in $allRecords)
    {
        if (-not [string]::IsNullOrWhiteSpace($r)) { $finalRecords.Add($r) }
    }

    # Sort by timestamp (extracted from the JSON string)
    # Parse each record to get timestamp for sorting, then sort
    $sortable = [System.Collections.Generic.List[System.Tuple[string, string]]]::new($finalRecords.Count)
    foreach ($json in $finalRecords)
    {
        $tsKey = ''
        try
        {
            $parsed = [System.Text.Json.JsonSerializer]::Deserialize($json, [System.Text.Json.JsonElement])
            $tsVal = [JsonlTraversal]::GetElementValue($parsed, 'timestamp')
            if ($null -ne $tsVal)
            {
                $tsKey = [string]$tsVal
            }
        }
        catch {}
        $sortable.Add([System.Tuple[string, string]]::new($tsKey, $json))
    }

    # Stable sort by timestamp string (ISO 8601 sorts lexicographically)
    $sortedArray = $sortable.ToArray()
    [System.Array]::Sort($sortedArray, [System.Comparison[System.Tuple[string, string]]] {
            param($a, $b)
            return [string]::Compare($a.Item1, $b.Item1, [System.StringComparison]::Ordinal)
        })

    # --- Phase 3: Write merged JSONL + .jidx ---
    Write-Host "Writing merged output..." -ForegroundColor Cyan
    $mergedDir = [System.IO.Path]::Combine($WorkingDir, 'merged')
    [void][System.IO.Directory]::CreateDirectory($mergedDir)

    $threadId = $manifest.ThreadId
    $mergedPath = [System.IO.Path]::Combine($mergedDir, "$OutputPrefix-$threadId.jsonl")
    $mergedIdxPath = [System.IO.Path]::ChangeExtension($mergedPath, '.jidx')

    $encoding = [System.Text.UTF8Encoding]::new($false)
    $offsets = [System.Collections.Generic.List[long]]::new()
    [long]$bytePos = 0
    [int]$writtenCount = 0

    $outFs = [System.IO.FileStream]::new(
        $mergedPath,
        [System.IO.FileMode]::Create,
        [System.IO.FileAccess]::Write
    )

    try
    {
        foreach ($entry in $sortedArray)
        {
            $jsonLine = $entry.Item2.Trim()
            if ([string]::IsNullOrWhiteSpace($jsonLine)) { continue }

            $offsets.Add($bytePos)

            $lineBytes = $encoding.GetBytes($jsonLine)
            $outFs.Write($lineBytes, 0, $lineBytes.Length)
            $outFs.WriteByte(0x0A)

            $bytePos += $lineBytes.Length + 1
            $writtenCount++
        }
    }
    finally { $outFs.Dispose() }

    # Build .jidx for the merged file
    $idxFs = [System.IO.FileStream]::new(
        $mergedIdxPath,
        [System.IO.FileMode]::Create,
        [System.IO.FileAccess]::Write
    )
    $bw = [System.IO.BinaryWriter]::new($idxFs)
    try
    {
        $bw.Write([System.Text.Encoding]::ASCII.GetBytes('JSOI'))
        $bw.Write([int]1)
        $bw.Write([int]$offsets.Count)
        foreach ($o in $offsets) { $bw.Write([long]$o) }
    }
    finally
    {
        $bw.Dispose()
        $idxFs.Dispose()
    }

    $exportStarted.Stop()

    $stats = [pscustomobject]@{
        TotalSourceRecords = $totalRead
        AfterFilter        = $totalFiltered
        Deduped            = $totalDeduped
        MergedRecords      = $writtenCount
        SessionCount       = $manifest.SessionCount()
        SubagentCount      = ($snapshots | Where-Object { $_.IsLateral }).Count
        ElapsedSeconds     = [math]::Round($exportStarted.Elapsed.TotalSeconds, 1)
    }

    Write-Host "  Merged: $writtenCount records ($($stats.ElapsedSeconds)s)" -ForegroundColor Green
    Write-Host "  Output: $mergedPath" -ForegroundColor Green

    return [pscustomobject]@{
        MergedPath  = $mergedPath
        IndexPath   = $mergedIdxPath
        RecordCount = $writtenCount
        Manifest    = $manifest
        Stats       = $stats
    }
}

#endregion

#region --- ClaudeRecordAnnotator ---

class ClaudeRecordAnnotator
{
    # Inject provenance annotation fields into a JsonElement and return as a
    # compact JSON string suitable for JSONL output.
    #
    # IMPLEMENTATION NOTE:
    # This class operates at the write-side boundary (claude layer owns PSCustomObject).
    # Pipeline: JsonElement → ConvertFrom-Json (PSCustomObject) → Merge-JsonObjects
    # (add annotation fields) → ConvertTo-CanonicalJson -Compress (final JSONL line).
    # No manual JSON string construction. No escaping. Depth is auto-computed.
    #
    # Annotation fields injected:
    #   ._sessionuuid   — source session UUID
    #   ._sessiondepth  — 0 = root, 1 = first resume, etc.
    #   ._islateral     — true if from a subagent/sidecar file
    #   ._agentid       — agent ID if lateral, null otherwise
    #   ._agenttype     — agent type if lateral, null otherwise
    #   ._agentdesc     — agent description from .meta.json if lateral, null otherwise
    #   ._sourcefile    — snapshot filename this record was read from

    static [string] Annotate(
        [System.Text.Json.JsonElement]$element,
        [string]$sessionUuid,
        [int]$depth,
        [bool]$isLateral,
        [string]$agentId,
        [string]$agentType,
        [string]$agentDesc,
        [string]$sourceFile
    )
    {
        # Deserialize original element into PSCustomObject
        $original = [System.Text.Json.JsonSerializer]::Serialize($element, [System.Text.Json.JsonElement])
        $base = $original | ConvertFrom-Json

        # Build annotation overlay — PSCustomObject, values pass through
        # ConvertTo-Json natively (no escaping needed)
        $annotation = [PSCustomObject]@{
            _sessionuuid  = $sessionUuid
            _sessiondepth = $depth
            _islateral    = $isLateral
            _agentid      = $agentId      # $null serializes as JSON null
            _agenttype    = $agentType
            _agentdesc    = $agentDesc
            _sourcefile   = $sourceFile
        }

        # Merge and serialize — depth auto-computed, no magic numbers
        $merged = Merge-JsonObjects -Base $base -Overlay $annotation
        return ConvertTo-CanonicalJson -InputObject $merged -Compress
    }
}

#endregion

# ---------------------------------------------------------------------------
# Exchange grouping stage — Get-ClaudeExchanges, Export-ClaudeGrouped
# ---------------------------------------------------------------------------
#
# EXCHANGE ENVELOPE SCHEMA
# ------------------------
#   _xid             "{threadId}-{xidx:D4}"   deterministic join key
#   _xidx            int   0-based exchange ordinal
#   _thread_id       string
#   _source_thread   filename of source merged JSONL
#   _session_uuid    string  session of the opening prompt record
#   _session_depth   int
#   _exchange_start  ISO 8601 timestamp of opening prompt
#   _exchange_end    ISO 8601 timestamp of last record in exchange
#   _turn_count      int  total atomic records in this exchange
#   _model           string  model of the assistant response (null if none / synthetic)
#   _user_label      string  human speaker label for diarized rendering (default: Aipithicus)
#   records          array of atomic typed records (see below)
#
# ATOMIC RECORD TYPES
# -------------------
#   prompt              human turn text
#   thinking            assistant thinking block (one entry per block)
#   response            assistant text block (one entry per block)
#   tool_call           matched tool_use + tool_result pair
#   tool_response_orphan  unmatched tool_result (warns)
#   subagent            lateral turn (_islateral=true)
#
# All atomic records carry: _type, _source_uuid, _timestamp
# -----------------------------------------------------------------------



# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

function script:Test-IsToolResultCarrier
{
    param([System.Text.Json.JsonElement]$el)

    # Returns $true if the record is a user record whose entire content array
    # consists only of tool_result blocks — i.e. a tool carrier, not a human prompt.
    $recType = $null
    try { $recType = $el.GetProperty('type').GetString() } catch { return $false }
    if ($recType -ne 'user') { return $false }

    $contentEl = [System.Text.Json.JsonElement]::new()
    try { $contentEl = $el.GetProperty('message').GetProperty('content') } catch { return $false }

    if ($contentEl.ValueKind -ne [System.Text.Json.JsonValueKind]::Array) { return $false }

    foreach ($block in $contentEl.EnumerateArray())
    {
        $bt = $null
        try { $bt = $block.GetProperty('type').GetString() } catch { return $true }
        if ($bt -ne 'tool_result') { return $false }
    }
    return $true
}


function script:Get-RecordTimestamp
{
    param([System.Text.Json.JsonElement]$el)
    try { return $el.GetProperty('timestamp').GetString() } catch { return '' }
}


function script:Get-RecordUuid
{
    param([System.Text.Json.JsonElement]$el)
    try { return $el.GetProperty('uuid').GetString() } catch { return $null }
}


function script:Build-ToolCallRecord
{
    # Construct a tool_call atomic record from a tool_use block + its matched tool_result block
    param(
        [System.Text.Json.JsonElement]$toolUseBlock,
        [System.Text.Json.JsonElement]$toolResultBlock,   # may be default/undefined
        [string]$carrierTimestamp,                        # timestamp of the tool_result carrier record
        [string]$sourceUuid,
        [string]$timestamp,
        [bool]$hasResult
    )

    $toolUseId = $null
    $toolName = $null
    try { $toolUseId = $toolUseBlock.GetProperty('id').GetString() } catch {}
    try { $toolName = $toolUseBlock.GetProperty('name').GetString() } catch {}

    $inputEl = [System.Text.Json.JsonElement]::new()
    try { $inputEl = $toolUseBlock.GetProperty('input') } catch {}

    # Deserialize to PSCustomObject so ConvertTo-CanonicalJson serializes it correctly
    $inputObj = $null
    if ($inputEl.ValueKind -notin @(
            [System.Text.Json.JsonValueKind]::Undefined,
            [System.Text.Json.JsonValueKind]::Null))
    {
        $inputJson = [System.Text.Json.JsonSerializer]::Serialize(
            $inputEl, [System.Text.Json.JsonElement])
        $inputObj = $inputJson | ConvertFrom-Json
    }

    $record = [ordered]@{
        _type        = 'tool_call'
        _source_uuid = $sourceUuid
        _timestamp   = $timestamp
        tool_use_id  = $toolUseId
        tool_name    = $toolName
        input        = $inputObj
        response     = $null
    }

    if ($hasResult)
    {
        $resultUseId = $null
        try { $resultUseId = $toolResultBlock.GetProperty('tool_use_id').GetString() } catch {}

        $resultContentEl = [System.Text.Json.JsonElement]::new()
        try { $resultContentEl = $toolResultBlock.GetProperty('content') } catch {}

        # Deserialize to PSCustomObject to avoid double-encoding on write
        $resultContentObj = $null
        if ($resultContentEl.ValueKind -notin @(
                [System.Text.Json.JsonValueKind]::Undefined,
                [System.Text.Json.JsonValueKind]::Null))
        {
            $resultContentJson = [System.Text.Json.JsonSerializer]::Serialize(
                $resultContentEl, [System.Text.Json.JsonElement])
            $resultContentObj = $resultContentJson | ConvertFrom-Json
        }

        $record.response = [ordered]@{
            tool_use_id = $resultUseId
            _timestamp  = $carrierTimestamp
            content     = $resultContentObj
        }
    }

    return $record
}


function script:Decompose-Record
{
    # Decompose a single merged JSONL JsonElement into one or more atomic typed records.
    # Returns a List of ordered hashtables.
    param(
        [System.Text.Json.JsonElement]$el,
        [System.Collections.Generic.Dictionary[string, System.Text.Json.JsonElement]]$toolResultMap,
        [System.Collections.Generic.Dictionary[string, string]]$toolResultTimestamps
    )

    $atomics = [System.Collections.Generic.List[object]]::new()

    $recType = $null
    $isLateral = $false
    $srcUuid = script:Get-RecordUuid $el
    $ts = script:Get-RecordTimestamp $el

    try { $recType = $el.GetProperty('type').GetString() } catch {}
    try { $isLateral = $el.GetProperty('_islateral').GetBoolean() } catch {}

    # --- Subagent lateral record ---
    if ($isLateral)
    {
        $agentType = $null
        $agentDesc = $null
        try { $agentType = $el.GetProperty('_agenttype').GetString() } catch {}
        try { $agentDesc = $el.GetProperty('_agentdesc').GetString() } catch {}

        $text = $null
        try
        {
            $contentEl = $el.GetProperty('message').GetProperty('content')
            if ($contentEl.ValueKind -eq [System.Text.Json.JsonValueKind]::Array)
            {
                $sb = [System.Text.StringBuilder]::new()
                foreach ($block in $contentEl.EnumerateArray())
                {
                    $bt = $null
                    try { $bt = $block.GetProperty('type').GetString() } catch { continue }
                    if ($bt -eq 'text')
                    {
                        $t = $null
                        try { $t = $block.GetProperty('text').GetString() } catch {}
                        if ($t) { [void]$sb.Append($t) }
                    }
                }
                $text = $sb.ToString()
            }
        }
        catch {}

        $atomics.Add([ordered]@{
                _type        = 'subagent'
                _source_uuid = $srcUuid
                _timestamp   = $ts
                _agenttype   = $agentType
                _agentdesc   = $agentDesc
                text         = $text
            })
        return $atomics
    }

    # --- User prompt record ---
    if ($recType -eq 'user' -and -not (script:Test-IsToolResultCarrier $el))
    {
        $text = $null
        try
        {
            $contentEl = $el.GetProperty('message').GetProperty('content')
            if ($contentEl.ValueKind -eq [System.Text.Json.JsonValueKind]::String)
            {
                $text = $contentEl.GetString()
            }
            elseif ($contentEl.ValueKind -eq [System.Text.Json.JsonValueKind]::Array)
            {
                $sb = [System.Text.StringBuilder]::new()
                foreach ($block in $contentEl.EnumerateArray())
                {
                    $bt = $null
                    try { $bt = $block.GetProperty('type').GetString() } catch { continue }
                    if ($bt -eq 'text')
                    {
                        $t = $null
                        try { $t = $block.GetProperty('text').GetString() } catch {}
                        if ($t) { [void]$sb.Append($t) }
                    }
                }
                $text = $sb.ToString()
            }
        }
        catch {}

        $atomics.Add([ordered]@{
                _type        = 'prompt'
                _source_uuid = $srcUuid
                _timestamp   = $ts
                text         = $text
            })
        return $atomics
    }

    # --- Tool-result carrier record ---
    # Results are pre-scanned before decomposition (two-pass approach).
    # Nothing to emit here — tool_use matching happens in the assistant branch below.
    if ($recType -eq 'user' -and (script:Test-IsToolResultCarrier $el))
    {
        return $atomics  # empty — results consumed via toolResultMap in assistant branch
    }

    # --- Assistant record ---
    if ($recType -eq 'assistant')
    {
        $contentEl = [System.Text.Json.JsonElement]::new()
        try { $contentEl = $el.GetProperty('message').GetProperty('content') } catch { return $atomics }

        if ($contentEl.ValueKind -ne [System.Text.Json.JsonValueKind]::Array) { return $atomics }

        # Collect tool_use blocks — we match results after iterating content
        $toolUseBlocks = [System.Collections.Generic.List[System.Text.Json.JsonElement]]::new()

        foreach ($block in $contentEl.EnumerateArray())
        {
            $bt = $null
            try { $bt = $block.GetProperty('type').GetString() } catch { continue }

            switch ($bt)
            {
                'thinking'
                {
                    $text = $null
                    try { $text = $block.GetProperty('thinking').GetString() } catch {}
                    if ($text -and $text.Trim().Length -gt 0)
                    {
                        $atomics.Add([ordered]@{
                                _type        = 'thinking'
                                _source_uuid = $srcUuid
                                _timestamp   = $ts
                                text         = $text
                            })
                    }
                }

                'text'
                {
                    $text = $null
                    try { $text = $block.GetProperty('text').GetString() } catch {}
                    if ($text -and $text.Trim().Length -gt 0)
                    {
                        $atomics.Add([ordered]@{
                                _type        = 'response'
                                _source_uuid = $srcUuid
                                _timestamp   = $ts
                                text         = $text
                            })
                    }
                }

                'tool_use'
                {
                    $toolUseBlocks.Add($block)
                }
            }
        }

        # Match tool_use blocks against the pre-scanned toolResultMap
        if ($toolUseBlocks.Count -gt 0)
        {
            foreach ($toolUseBlock in $toolUseBlocks)
            {
                $useId = $null
                try { $useId = $toolUseBlock.GetProperty('id').GetString() } catch {}

                if ($useId -and $toolResultMap.ContainsKey($useId))
                {
                    $atomics.Add((script:Build-ToolCallRecord `
                                -toolUseBlock $toolUseBlock `
                                -toolResultBlock $toolResultMap[$useId] `
                                -carrierTimestamp $toolResultTimestamps[$useId] `
                                -sourceUuid $srcUuid `
                                -timestamp $ts `
                                -hasResult $true))
                }
                else
                {
                    # No matching result — unmatched tool_use (incomplete exchange)
                    $atomics.Add((script:Build-ToolCallRecord `
                                -toolUseBlock $toolUseBlock `
                                -toolResultBlock ([System.Text.Json.JsonElement]::new()) `
                                -carrierTimestamp '' `
                                -sourceUuid $srcUuid `
                                -timestamp $ts `
                                -hasResult $false))
                }
            }

            # Orphan check: results in map whose tool_use_id has no matching tool_use in this record
            foreach ($orphanId in $toolResultMap.Keys)
            {
                $matchedByThisRecord = $false
                foreach ($tub in $toolUseBlocks)
                {
                    $uid = $null
                    try { $uid = $tub.GetProperty('id').GetString() } catch {}
                    if ($uid -eq $orphanId) { $matchedByThisRecord = $true; break }
                }
                # Only warn if the orphan's ID was expected in the current assistant block's context
                # (i.e., we have a result but no tool_use with that ID in this record)
                if (-not $matchedByThisRecord)
                {
                    # This is normal — results in toolResultMap belong to other assistant records too.
                    # Only flag if none of the blocks in the file has a matching tool_use.
                    # Skip per-record orphan warnings — the global map contains all results.
                }
            }
        }

        return $atomics
    }

    return $atomics
}


# ---------------------------------------------------------------------------
# Public functions
# ---------------------------------------------------------------------------

function Get-ClaudeExchanges
{
    <#
    .SYNOPSIS
        Parse a merged thread JSONL into an ordered list of exchange hashtables.
    .DESCRIPTION
        Reads a merged thread-*.jsonl produced by Export-ClaudeThread and groups
        records into exchange envelopes. Each exchange opens on a non-tool-result
        human turn and accumulates all subsequent records until the next such turn.

        Returns an ordered List of hashtables, each representing one exchange.
        The hashtables match the exchange JSONL envelope schema and can be passed
        directly to Export-ClaudeExchanges or consumed by subagent dispatch logic.
    .PARAMETER MergedJsonlPath
        Path to a thread-*.jsonl produced by Export-ClaudeThread.
    .PARAMETER ThreadId
        Thread ID string. If omitted, derived from the merged filename.
    .PARAMETER UserLabel
        Human speaker label stamped on every exchange envelope. Used by the
        markdown renderer for diarized output. Default: Aipithicus.
    .OUTPUTS
        System.Collections.Generic.List[hashtable]
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$MergedJsonlPath,

        [string]$ThreadId,

        [string]$UserLabel = 'Aipithicus'
    )

    if (-not [System.IO.File]::Exists($MergedJsonlPath))
    {
        throw "Merged JSONL not found: $MergedJsonlPath"
    }

    if (-not $ThreadId)
    {
        # Filename pattern: `{prefix}-{uuid}.jsonl` for any prefix (`thread`,
        # project leaf, etc.). Pull the trailing UUID directly rather than
        # assuming a specific prefix — keeps the fallback prefix-agnostic.
        $baseName = [System.IO.Path]::GetFileNameWithoutExtension($MergedJsonlPath)
        if ($baseName -match '([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$')
        {
            $ThreadId = $matches[1]
        }
        else
        {
            $ThreadId = $baseName
        }
    }

    $sourceFile = [System.IO.Path]::GetFileName($MergedJsonlPath)
    $encoding = [System.Text.UTF8Encoding]::new($false)
    $exchanges = [System.Collections.Generic.List[hashtable]]::new()

    # --- Pass 1: Pre-scan — build global tool_use_id → (resultBlock, carrierTimestamp) map ---
    # Tool-result carriers always appear AFTER the assistant records that emitted the matching
    # tool_use blocks. By pre-scanning we make all results available before decomposition.
    $toolResultMap = [System.Collections.Generic.Dictionary[string, System.Text.Json.JsonElement]]::new()
    $toolResultTimestamps = [System.Collections.Generic.Dictionary[string, string]]::new()

    $prescanFs = [System.IO.FileStream]::new(
        $MergedJsonlPath,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read,
        [System.IO.FileShare]::Read
    )
    $prescanReader = [System.IO.StreamReader]::new($prescanFs, $encoding)
    try
    {
        while ($null -ne ($prescanLine = $prescanReader.ReadLine()))
        {
            $prescanTrimmed = $prescanLine.Trim()
            if ($prescanTrimmed.Length -eq 0) { continue }

            [System.Text.Json.JsonElement]$prescanEl = [System.Text.Json.JsonElement]::new()
            try
            {
                $prescanEl = [System.Text.Json.JsonSerializer]::Deserialize(
                    $prescanTrimmed, [System.Text.Json.JsonElement])
            }
            catch { continue }

            if (script:Test-IsToolResultCarrier $prescanEl)
            {
                $carrierTs = ''
                try { $carrierTs = $prescanEl.GetProperty('timestamp').GetString() } catch {}

                try
                {
                    $contentEl = $prescanEl.GetProperty('message').GetProperty('content')
                    foreach ($block in $contentEl.EnumerateArray())
                    {
                        $rId = $null
                        try { $rId = $block.GetProperty('tool_use_id').GetString() } catch { continue }
                        if ($rId)
                        {
                            $toolResultMap[$rId] = $block
                            $toolResultTimestamps[$rId] = $carrierTs
                        }
                    }
                }
                catch {}
            }
        }
    }
    finally
    {
        $prescanReader.Dispose()
        $prescanFs.Dispose()
    }

    # Current open exchange state
    [int]$xidx = -1
    $currentRecords = $null
    [string]$xStart = $null
    [string]$xEnd = $null
    [string]$xSession = $null
    [int]$xDepth = 0
    [string]$xModel = $null

    # Inline close-exchange logic as a scriptblock to avoid script-scope leakage
    $closeExchange = {
        if ($null -eq $currentRecords) { return }
        $exchanges.Add(@{
                _xid            = "$ThreadId-$($xidx.ToString('D4'))"
                _xidx           = $xidx
                _thread_id      = $ThreadId
                _source_thread  = $sourceFile
                _session_uuid   = $xSession
                _session_depth  = $xDepth
                _exchange_start = $xStart
                _exchange_end   = $xEnd
                _turn_count     = $currentRecords.Count
                _model          = $xModel
                _user_label     = $UserLabel
                records         = $currentRecords
            })
    }

    $fs = [System.IO.FileStream]::new(
        $MergedJsonlPath,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read,
        [System.IO.FileShare]::Read
    )
    $sr = [System.IO.StreamReader]::new($fs, $encoding)

    try
    {
        while ($null -ne ($rawLine = $sr.ReadLine()))
        {
            $trimmed = $rawLine.Trim()
            if ($trimmed.Length -eq 0) { continue }

            [System.Text.Json.JsonElement]$el = [System.Text.Json.JsonElement]::new()
            try
            {
                $el = [System.Text.Json.JsonSerializer]::Deserialize(
                    $trimmed, [System.Text.Json.JsonElement])
            }
            catch
            {
                Write-Warning "Get-ClaudeExchanges: skipping unparseable line: $($_.Exception.Message)"
                continue
            }

            $recType = $null
            $isLateral = $false
            try { $recType = $el.GetProperty('type').GetString() } catch {}
            try { $isLateral = $el.GetProperty('_islateral').GetBoolean() } catch {}

            # Capture model from non-lateral assistant records (last-wins for the exchange)
            if ($recType -eq 'assistant' -and -not $isLateral)
            {
                $m = $null
                try { $m = $el.GetProperty('message').GetProperty('model').GetString() } catch {}
                if ($m -and $m -ne '<synthetic>') { $xModel = $m }
            }

            $isPromptBoundary = (
                $recType -eq 'user' -and
                -not $isLateral -and
                -not (script:Test-IsToolResultCarrier $el)
            )

            if ($isPromptBoundary)
            {
                # Close current exchange if open
                & $closeExchange

                # Open new exchange
                $xidx++
                $currentRecords = [System.Collections.Generic.List[object]]::new()
                $xStart = script:Get-RecordTimestamp $el
                $xEnd = $xStart
                $xModel = $null
                try { $xSession = $el.GetProperty('_sessionuuid').GetString() } catch { $xSession = $null }
                try { $xDepth = $el.GetProperty('_sessiondepth').GetInt32() } catch { $xDepth = 0 }
            }

            if ($null -eq $currentRecords)
            {
                # Records before the first human prompt — discard (preamble/system records)
                continue
            }

            # Decompose record into atomics and append to current exchange
            $atomics = script:Decompose-Record -el $el -toolResultMap $toolResultMap -toolResultTimestamps $toolResultTimestamps

            foreach ($atomic in $atomics)
            {
                [void]$currentRecords.Add($atomic)
                $ts = $atomic._timestamp
                if ($ts -and [string]::Compare($ts, $xEnd, [System.StringComparison]::Ordinal) -gt 0)
                {
                    $xEnd = $ts
                }
            }
        }

        # Close the final open exchange
        & $closeExchange
    }
    finally
    {
        $sr.Dispose()
        $fs.Dispose()
    }

    return , $exchanges
}

function Export-ClaudeExchanges
{
    <#
    .SYNOPSIS
        Write an exchanges JSONL from exchange list into an exchanges/ subdirectory.
    .DESCRIPTION
        Takes the output of Get-ClaudeExchanges and writes one JSONL line per
        exchange envelope to {WorkingDir}/exchanges/{OutputPrefix}-{threadId}.jsonl.

        Each line is a complete, self-contained exchange envelope with decomposed
        atomic records. Also writes a .jidx binary offset index alongside.
    .PARAMETER Exchanges
        Ordered list of exchange hashtables from Get-ClaudeExchanges.
    .PARAMETER WorkingDir
        Job working directory. Output is written to {WorkingDir}/exchanges/.
    .PARAMETER ThreadId
        Thread ID string used for output filename.
    .PARAMETER OutputPrefix
        Filename stem: `{OutputPrefix}-{threadId}.jsonl`. Default `'thread'`.
        Batch runs pass the project leaf (e.g. `'tools'`).
    .OUTPUTS
        PSCustomObject with ExchangesPath, IndexPath, ExchangeCount.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.Generic.List[hashtable]]$Exchanges,

        [Parameter(Mandatory)]
        [string]$WorkingDir,

        [Parameter(Mandatory)]
        [string]$ThreadId,

        [string]$OutputPrefix = 'thread'
    )

    $exchangesDir = [System.IO.Path]::Combine($WorkingDir, 'exchanges')
    [void][System.IO.Directory]::CreateDirectory($exchangesDir)

    $exchangesPath = [System.IO.Path]::Combine($exchangesDir, "$OutputPrefix-$ThreadId.jsonl")
    $idxPath = [System.IO.Path]::ChangeExtension($exchangesPath, '.jidx')
    $encoding = [System.Text.UTF8Encoding]::new($false)

    $outFs = [System.IO.FileStream]::new(
        $exchangesPath,
        [System.IO.FileMode]::Create,
        [System.IO.FileAccess]::Write
    )

    try
    {
        foreach ($xch in $Exchanges)
        {
            $jsonLine = ConvertTo-CanonicalJson -InputObject $xch -Compress
            $lineBytes = $encoding.GetBytes($jsonLine)
            $outFs.Write($lineBytes, 0, $lineBytes.Length)
            $outFs.WriteByte(0x0A)
        }
    }
    finally
    {
        $outFs.Flush()
        $outFs.Dispose()
    }

    # Build .jidx byte-scan index (byte-correct, no CRLF drift)
    [void][JsonlIndex]::Build($exchangesPath, $idxPath)

    Write-Host "  Exchanges: $exchangesPath ($($Exchanges.Count) exchanges)" -ForegroundColor Green

    return [PSCustomObject]@{
        ExchangesPath = $exchangesPath
        IndexPath     = $idxPath
        ExchangeCount = $Exchanges.Count
    }
}

#endregion
