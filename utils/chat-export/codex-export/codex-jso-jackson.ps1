# codex-jso-jackson.ps1 — Codex rollout ingest and exchange-envelope IR
#
# Minimal pipeline:
#   rollout JSONL -> stable snapshot -> exchange envelopes JSONL + .jidx
#
# Provider-specific rollout resolution and parsing live here. Generic JSONL
# snapshot, exchange I/O, run/path, and frozen-source contracts live in shared.

$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\..\shared\jsonl.ps1"

function Get-CodexHome
{
    [CmdletBinding()]
    param([string]$CodexHome)

    if ([string]::IsNullOrWhiteSpace($CodexHome))
    {
        $CodexHome = $env:CODEX_HOME
    }
    if ([string]::IsNullOrWhiteSpace($CodexHome))
    {
        $profileRoot = [Environment]::GetFolderPath(
            [Environment+SpecialFolder]::UserProfile)
        $CodexHome = [System.IO.Path]::Combine($profileRoot, '.codex')
    }

    return [System.IO.Path]::GetFullPath($CodexHome)
}

function script:ConvertTo-CodexIsoTimestamp
{
    param([object]$Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [datetime])
    {
        return $Value.ToUniversalTime().ToString('o')
    }
    if ($Value -is [datetimeoffset])
    {
        return $Value.ToUniversalTime().ToString('o')
    }

    $text = [string]$Value
    [datetimeoffset]$parsed = [datetimeoffset]::MinValue
    if ([datetimeoffset]::TryParse(
            $text,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AssumeUniversal,
            [ref]$parsed))
    {
        return $parsed.ToUniversalTime().ToString('o')
    }
    return $text
}

function script:ConvertFrom-CodexJsonString
{
    param([object]$Value)

    return ConvertFrom-ChatJsonString -Value $Value
}

function script:Get-CodexMessageText
{
    param([object]$Payload)

    $parts = [System.Collections.Generic.List[string]]::new()
    foreach ($block in @($Payload.content))
    {
        if ($null -eq $block) { continue }
        switch ([string]$block.type)
        {
            { $_ -in @('input_text', 'output_text', 'text') }
            {
                if (-not [string]::IsNullOrWhiteSpace([string]$block.text))
                {
                    [void]$parts.Add(([string]$block.text).TrimEnd())
                }
            }
            { $_ -in @('local_image', 'localImage') }
            {
                if ($block.path) { [void]$parts.Add("[local image: $($block.path)]") }
            }
            { $_ -in @('input_image', 'image', 'image_url') }
            {
                [void]$parts.Add('[image]')
            }
        }
    }

    if ($parts.Count -eq 0 -and
        -not [string]::IsNullOrWhiteSpace([string]$Payload.message))
    {
        [void]$parts.Add(([string]$Payload.message).TrimEnd())
    }

    return ($parts -join "`n`n")
}

function script:Get-CodexReasoningText
{
    param([object]$Payload)

    $parts = [System.Collections.Generic.List[string]]::new()
    foreach ($summary in @($Payload.summary))
    {
        if ($null -ne $summary -and
            -not [string]::IsNullOrWhiteSpace([string]$summary.text))
        {
            [void]$parts.Add(([string]$summary.text).TrimEnd())
        }
    }
    foreach ($content in @($Payload.content))
    {
        if ($null -ne $content -and
            -not [string]::IsNullOrWhiteSpace([string]$content.text))
        {
            [void]$parts.Add(([string]$content.text).TrimEnd())
        }
    }
    return ($parts -join "`n`n")
}

function script:Get-CodexSessionMeta
{
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $encoding = [System.Text.UTF8Encoding]::new($false)
    $share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
    $fs = [System.IO.FileStream]::new(
        $Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share)
    $sr = [System.IO.StreamReader]::new($fs, $encoding)
    try
    {
        while ($null -ne ($line = $sr.ReadLine()))
        {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $record = $line | ConvertFrom-Json -Depth 100
            if ($record.type -eq 'session_meta') { return $record.payload }
            break
        }
    }
    finally
    {
        $sr.Dispose()
        $fs.Dispose()
    }
    return $null
}

function script:ConvertTo-CodexNonNegativeInt64
{
    param(
        [object]$Value,
        [Parameter(Mandatory)]
        [string]$Label
    )

    $text = if ($null -eq $Value)
    {
        ''
    }
    else
    {
        [Convert]::ToString($Value, [Globalization.CultureInfo]::InvariantCulture)
    }
    [long]$parsed = 0
    $valid = [long]::TryParse(
        $text,
        [Globalization.NumberStyles]::Integer,
        [Globalization.CultureInfo]::InvariantCulture,
        [ref]$parsed)
    if (-not $valid -or $parsed -lt 0)
    {
        throw "$Label must be a non-negative 64-bit integer; got '$text'."
    }
    return $parsed
}

function script:Get-CodexJsonlNewlineStats
{
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [AllowNull()]
        [Nullable[long]]$ByteLength = $null
    )

    $share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
    $fs = [System.IO.FileStream]::new(
        $Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share)
    try
    {
        [long]$sourceLength = $fs.Length
        [long]$scanLength = if ($null -eq $ByteLength)
        {
            $sourceLength
        }
        else
        {
            [long]$ByteLength
        }
        if ($scanLength -gt $sourceLength)
        {
            throw ("Codex rollout span requests $scanLength bytes, but the source " +
                "contains only $sourceLength bytes: $Path")
        }

        [byte[]]$buffer = [byte[]]::new(1048576)
        [long]$remaining = $scanLength
        [long]$scanned = 0
        [long]$newlineCount = 0
        [long]$previousNewlineOffset = 0
        [long]$lastNewlineOffset = 0
        [int]$lastByte = -1

        while ($remaining -gt 0)
        {
            $wanted = [int][Math]::Min([long]$buffer.Length, $remaining)
            $read = $fs.Read($buffer, 0, $wanted)
            if ($read -le 0)
            {
                throw "Codex rollout changed while reading its byte span: $Path"
            }

            $searchFrom = 0
            while ($searchFrom -lt $read)
            {
                $index = [Array]::IndexOf[byte](
                    $buffer, [byte]0x0A, $searchFrom, $read - $searchFrom)
                if ($index -lt 0) { break }
                $previousNewlineOffset = $lastNewlineOffset
                $lastNewlineOffset = $scanned + $index + 1
                $newlineCount++
                $searchFrom = $index + 1
            }

            $lastByte = [int]$buffer[$read - 1]
            $scanned += $read
            $remaining -= $read
        }

        return [pscustomobject]@{
            SourceLength          = $sourceLength
            ScannedByteLength     = $scanLength
            NewlineCount          = $newlineCount
            PreviousNewlineOffset = $previousNewlineOffset
            LastNewlineOffset     = $lastNewlineOffset
            LastByte              = $lastByte
        }
    }
    finally { $fs.Dispose() }
}

function script:Read-CodexByteRange
{
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [long]$Offset,

        [Parameter(Mandatory)]
        [long]$Length
    )

    if ($Length -gt [int]::MaxValue)
    {
        throw "Codex JSONL record exceeds the supported in-memory size: $Length bytes."
    }

    $share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
    $fs = [System.IO.FileStream]::new(
        $Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share)
    try
    {
        if ($Offset + $Length -gt $fs.Length)
        {
            throw "Codex rollout changed while reading its final record: $Path"
        }
        $fs.Position = $Offset
        [byte[]]$bytes = [byte[]]::new([int]$Length)
        $readTotal = 0
        while ($readTotal -lt $bytes.Length)
        {
            $read = $fs.Read($bytes, $readTotal, $bytes.Length - $readTotal)
            if ($read -le 0)
            {
                throw "Codex rollout changed while reading its final record: $Path"
            }
            $readTotal += $read
        }
        return $bytes
    }
    finally { $fs.Dispose() }
}

function script:Get-CodexJsonlExtent
{
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $stats = script:Get-CodexJsonlNewlineStats -Path $Path
    if ($stats.SourceLength -eq 0)
    {
        return [pscustomobject]@{
            SourceLength             = [long]0
            CompleteByteLength       = [long]0
            RecordCount              = [long]0
            NeedsTerminatingNewline  = $false
            TailDropped              = $false
        }
    }

    $endsWithNewline = $stats.LastNewlineOffset -eq $stats.SourceLength
    [long]$recordStart = if ($endsWithNewline)
    {
        $stats.PreviousNewlineOffset
    }
    else
    {
        $stats.LastNewlineOffset
    }
    [long]$recordEnd = if ($endsWithNewline)
    {
        $stats.SourceLength - 1
    }
    else
    {
        $stats.SourceLength
    }
    [long]$recordLength = $recordEnd - $recordStart
    $recordBytes = script:Read-CodexByteRange `
        -Path $Path -Offset $recordStart -Length $recordLength
    $encoding = [System.Text.UTF8Encoding]::new($false, $true)
    try
    {
        $recordText = $encoding.GetString($recordBytes).Trim()
    }
    catch
    {
        $recordText = $null
    }

    $validFinalRecord = $false
    if (-not [string]::IsNullOrWhiteSpace($recordText))
    {
        try
        {
            $document = [System.Text.Json.JsonDocument]::Parse($recordText)
            $document.Dispose()
            $validFinalRecord = $true
        }
        catch { $validFinalRecord = $false }
    }

    if ($validFinalRecord)
    {
        return [pscustomobject]@{
            SourceLength             = [long]$stats.SourceLength
            CompleteByteLength       = [long]$stats.SourceLength
            RecordCount              = [long]($stats.NewlineCount + $(if ($endsWithNewline) { 0 } else { 1 }))
            NeedsTerminatingNewline  = -not $endsWithNewline
            TailDropped              = $false
        }
    }

    [long]$completeLength = $recordStart
    [long]$completeRecords = if ($endsWithNewline)
    {
        [Math]::Max(0, $stats.NewlineCount - 1)
    }
    else
    {
        $stats.NewlineCount
    }
    return [pscustomobject]@{
        SourceLength             = [long]$stats.SourceLength
        CompleteByteLength       = $completeLength
        RecordCount              = $completeRecords
        NeedsTerminatingNewline  = $false
        TailDropped              = -not [string]::IsNullOrWhiteSpace($recordText)
    }
}

function script:Get-CodexPrefixInfo
{
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [long]$ByteLength
    )

    $stats = script:Get-CodexJsonlNewlineStats -Path $Path -ByteLength $ByteLength
    if ($ByteLength -gt 0 -and $stats.LastByte -ne 0x0A)
    {
        throw ("Codex history_base byte offset $ByteLength does not end on a " +
            "JSONL record boundary: $Path")
    }
    return [pscustomobject]@{
        ByteLength  = $ByteLength
        RecordCount = [long]$stats.NewlineCount
    }
}

function script:Get-CodexPhysicalSegmentId
{
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$ThreadId
    )

    $uuidAtom = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
    $escapedThreadId = [regex]::Escape($ThreadId)
    $match = [regex]::Match(
        [System.IO.Path]::GetFileName($Path),
        "-$escapedThreadId(?:_(?<segment>$uuidAtom))?\.jsonl$",
        [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $match.Success) { return $null }
    if ($match.Groups['segment'].Success)
    {
        return $match.Groups['segment'].Value.ToLowerInvariant()
    }
    return $ThreadId.ToLowerInvariant()
}

function Resolve-CodexThreadPath
{
    <#
    .SYNOPSIS
        Resolve a logical Codex thread into its canonical rollout-segment chain.
    .DESCRIPTION
        Newer Codex runtimes can split one logical thread across physical JSONL
        rollouts. A child session_meta.history_base names its predecessor and
        the exact byte prefix retained from it. This resolver follows those
        links backward, validates every prefix/ordinal boundary, and returns a
        manifest while retaining RolloutPath as the selected leaf for callers
        written against the earlier single-file contract.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ThreadId,

        [string]$CodexHome,

        [string]$LeafSegmentId
    )

    $uuidPattern = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
    if ($ThreadId -notmatch $uuidPattern)
    {
        throw "Malformed Codex thread id: '$ThreadId'. Expected an 8-4-4-4-12 UUID."
    }
    $ThreadId = $ThreadId.ToLowerInvariant()
    if (-not [string]::IsNullOrWhiteSpace($LeafSegmentId))
    {
        if ($LeafSegmentId -notmatch $uuidPattern)
        {
            throw "Malformed Codex leaf segment id: '$LeafSegmentId'. Expected an 8-4-4-4-12 UUID."
        }
        $LeafSegmentId = $LeafSegmentId.ToLowerInvariant()
    }

    $resolvedHome = Get-CodexHome -CodexHome $CodexHome
    $sessionsDir = [System.IO.Path]::Combine($resolvedHome, 'sessions')
    $archivedDir = [System.IO.Path]::Combine($resolvedHome, 'archived_sessions')
    $pattern = "*-$ThreadId*.jsonl"
    $hits = [System.Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase)

    if ([System.IO.Directory]::Exists($sessionsDir))
    {
        foreach ($path in [System.IO.Directory]::GetFiles(
                $sessionsDir, $pattern, [System.IO.SearchOption]::AllDirectories))
        {
            [void]$hits.Add([System.IO.Path]::GetFullPath($path))
        }
    }
    if ([System.IO.Directory]::Exists($archivedDir))
    {
        foreach ($path in [System.IO.Directory]::GetFiles(
                $archivedDir, $pattern, [System.IO.SearchOption]::TopDirectoryOnly))
        {
            [void]$hits.Add([System.IO.Path]::GetFullPath($path))
        }
    }

    $archivedPrefix = [System.IO.Path]::GetFullPath($archivedDir).TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
    $candidates = [System.Collections.Generic.List[object]]::new()
    foreach ($path in @($hits | Sort-Object))
    {
        $segmentId = script:Get-CodexPhysicalSegmentId -Path $path -ThreadId $ThreadId
        if ([string]::IsNullOrWhiteSpace($segmentId)) { continue }

        $meta = script:Get-CodexSessionMeta -Path $path
        if ($null -eq $meta)
        {
            throw "The rollout has no leading session_meta record: $path"
        }
        if ([string]$meta.id -ne $ThreadId)
        {
            throw "Rollout metadata id '$($meta.id)' does not match requested thread '$ThreadId': $path"
        }

        $predecessorId = $null
        [long]$baseOrdinal = 0
        [long]$baseByteOffset = 0
        if ($null -ne $meta.history_base)
        {
            $history = $meta.history_base
            $required = @('thread_id', 'end_ordinal_exclusive', 'end_byte_offset')
            foreach ($propertyName in $required)
            {
                if ($history.PSObject.Properties.Name -notcontains $propertyName)
                {
                    throw "Codex history_base is missing '$propertyName': $path"
                }
            }
            $predecessorId = ([string]$history.thread_id).ToLowerInvariant()
            if ($predecessorId -notmatch $uuidPattern)
            {
                throw "Codex history_base.thread_id is malformed in $path."
            }
            $baseOrdinal = script:ConvertTo-CodexNonNegativeInt64 `
                -Value $history.end_ordinal_exclusive `
                -Label "history_base.end_ordinal_exclusive in $path"
            $baseByteOffset = script:ConvertTo-CodexNonNegativeInt64 `
                -Value $history.end_byte_offset `
                -Label "history_base.end_byte_offset in $path"
        }

        $extent = script:Get-CodexJsonlExtent -Path $path
        [void]$candidates.Add([pscustomobject]@{
            ThreadId              = $ThreadId
            SegmentId             = $segmentId
            Path                  = $path
            IsArchived            = [System.IO.Path]::GetFullPath($path).StartsWith(
                $archivedPrefix, [StringComparison]::OrdinalIgnoreCase)
            Meta                  = $meta
            PredecessorSegmentId  = $predecessorId
            BaseOrdinal           = $baseOrdinal
            BaseByteOffset        = $baseByteOffset
            EffectiveEndOrdinal   = $baseOrdinal + [long]$extent.RecordCount
            Extent                = $extent
        })
    }

    if ($candidates.Count -eq 0)
    {
        throw "No Codex rollout found for thread $ThreadId under $resolvedHome."
    }

    $candidateById = [System.Collections.Generic.Dictionary[string, object]]::new(
        [StringComparer]::OrdinalIgnoreCase)
    foreach ($candidate in $candidates)
    {
        if ($candidateById.ContainsKey($candidate.SegmentId))
        {
            throw ("Duplicate Codex physical segment id '$($candidate.SegmentId)':`n  " +
                "$($candidateById[$candidate.SegmentId].Path)`n  $($candidate.Path)")
        }
        $candidateById.Add($candidate.SegmentId, $candidate)
    }

    $referencedIds = [System.Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase)
    foreach ($candidate in $candidates)
    {
        if (-not [string]::IsNullOrWhiteSpace($candidate.PredecessorSegmentId))
        {
            [void]$referencedIds.Add($candidate.PredecessorSegmentId)
        }
    }
    $leaves = @($candidates | Where-Object {
            -not $referencedIds.Contains($_.SegmentId)
        })
    if ($leaves.Count -eq 0)
    {
        throw "Codex rollout graph for thread $ThreadId has no leaf; the history_base links contain a cycle."
    }

    $selected = $null
    $selectionReason = $null
    if (-not [string]::IsNullOrWhiteSpace($LeafSegmentId))
    {
        $matches = @($leaves | Where-Object { $_.SegmentId -eq $LeafSegmentId })
        if ($matches.Count -ne 1)
        {
            throw "Codex leaf segment '$LeafSegmentId' was not found among the leaves for thread $ThreadId."
        }
        $selected = $matches[0]
        $selectionReason = 'explicit-leaf-segment-id'
    }
    elseif ($leaves.Count -eq 1)
    {
        $selected = $leaves[0]
        $selectionReason = 'unique-graph-leaf'
    }
    else
    {
        [long]$maximumOrdinal = ($leaves |
            Measure-Object -Property EffectiveEndOrdinal -Maximum).Maximum
        $maximumLeaves = @($leaves | Where-Object {
                $_.EffectiveEndOrdinal -eq $maximumOrdinal
            })
        if ($maximumLeaves.Count -ne 1)
        {
            $descriptions = $maximumLeaves | ForEach-Object {
                "segment=$($_.SegmentId) ordinal=$($_.EffectiveEndOrdinal) path=$($_.Path)"
            }
            throw ("Ambiguous Codex thread $ThreadId; multiple leaves end at cumulative " +
                "ordinal $maximumOrdinal. Supply -LeafSegmentId explicitly:`n  " +
                ($descriptions -join "`n  "))
        }
        $selected = $maximumLeaves[0]
        $selectionReason = 'greatest-cumulative-ordinal'
    }

    $reverseChain = [System.Collections.Generic.List[object]]::new()
    $visited = [System.Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase)
    $cursor = $selected
    while ($null -ne $cursor)
    {
        if (-not $visited.Add($cursor.SegmentId))
        {
            throw "Cycle detected while resolving Codex physical segment '$($cursor.SegmentId)'."
        }
        [void]$reverseChain.Add($cursor)
        if ([string]::IsNullOrWhiteSpace($cursor.PredecessorSegmentId)) { break }
        if (-not $candidateById.ContainsKey($cursor.PredecessorSegmentId))
        {
            throw ("Codex physical segment '$($cursor.SegmentId)' references missing " +
                "predecessor '$($cursor.PredecessorSegmentId)'.")
        }
        $cursor = $candidateById[$cursor.PredecessorSegmentId]
    }
    $chain = $reverseChain.ToArray()
    [Array]::Reverse($chain)

    $spans = [System.Collections.Generic.List[object]]::new()
    [long]$cumulativeOrdinal = 0
    for ($index = 0; $index -lt $chain.Count; $index++)
    {
        $segment = $chain[$index]
        if ([long]$segment.BaseOrdinal -ne $cumulativeOrdinal)
        {
            throw ("Codex cumulative ordinal mismatch at segment '$($segment.SegmentId)': " +
                "history_base declares $($segment.BaseOrdinal), reconstructed $cumulativeOrdinal.")
        }

        $isLeaf = $index -eq ($chain.Count - 1)
        if ($isLeaf)
        {
            $includedByteLength = [long]$segment.Extent.CompleteByteLength
            $includedRecordCount = [long]$segment.Extent.RecordCount
            $needsTerminatingNewline = [bool]$segment.Extent.NeedsTerminatingNewline
            $tailDropped = [bool]$segment.Extent.TailDropped
        }
        else
        {
            $child = $chain[$index + 1]
            $prefix = script:Get-CodexPrefixInfo `
                -Path $segment.Path `
                -ByteLength ([long]$child.BaseByteOffset)
            $includedByteLength = [long]$prefix.ByteLength
            $includedRecordCount = [long]$prefix.RecordCount
            $needsTerminatingNewline = $false
            $tailDropped = $false
            [long]$expectedLocalRecords = [long]$child.BaseOrdinal - $cumulativeOrdinal
            if ($includedRecordCount -ne $expectedLocalRecords)
            {
                throw ("Codex history_base ordinal mismatch between '$($segment.SegmentId)' " +
                    "and '$($child.SegmentId)': byte prefix contains $includedRecordCount " +
                    "records, metadata declares $expectedLocalRecords.")
            }
        }

        [long]$discardedRecords = [Math]::Max(
            0, [long]$segment.Extent.RecordCount - $includedRecordCount)
        [long]$discardedBytes = [Math]::Max(
            0, [long]$segment.Extent.SourceLength - $includedByteLength)
        [void]$spans.Add([pscustomobject]@{
            SegmentId               = $segment.SegmentId
            Path                    = $segment.Path
            IsArchived              = $segment.IsArchived
            IsLeaf                  = $isLeaf
            PredecessorSegmentId    = $segment.PredecessorSegmentId
            BaseOrdinal             = [long]$segment.BaseOrdinal
            IncludedByteLength      = $includedByteLength
            IncludedRecordCount     = $includedRecordCount
            EffectiveEndOrdinal     = $cumulativeOrdinal + $includedRecordCount
            SourceByteLength        = [long]$segment.Extent.SourceLength
            SourceRecordCount       = [long]$segment.Extent.RecordCount
            DiscardedByteCount      = $discardedBytes
            DiscardedRecordCount    = $discardedRecords
            NeedsTerminatingNewline = $needsTerminatingNewline
            TailDropped             = $tailDropped
            CliVersion              = [string]$segment.Meta.cli_version
        })
        $cumulativeOrdinal += $includedRecordCount
    }

    $selectedMeta = $selected.Meta
    return [pscustomobject]@{
        ThreadId          = $ThreadId
        RolloutPath       = $selected.Path
        RolloutPaths      = @($spans | ForEach-Object { $_.Path })
        IsArchived        = $selected.IsArchived
        CodexHome         = $resolvedHome
        CreatedAt         = script:ConvertTo-CodexIsoTimestamp $selectedMeta.timestamp
        Cwd               = [string]$selectedMeta.cwd
        Originator        = [string]$selectedMeta.originator
        CliVersion        = [string]$selectedMeta.cli_version
        ModelProvider     = [string]$selectedMeta.model_provider
        Source            = $selectedMeta.source
        SessionId         = [string]$selectedMeta.session_id
        ThreadSource      = [string]$selectedMeta.thread_source
        CandidateCount    = $candidates.Count
        SegmentCount      = $spans.Count
        Fragmented        = $spans.Count -gt 1
        SelectedSegmentId = $selected.SegmentId
        SelectionReason   = $selectionReason
        EffectiveRecords  = $cumulativeOrdinal
        Segments          = $spans.ToArray()
    }
}

function New-CodexJsonlSnapshot
{
    <#
    .SYNOPSIS
        Snapshot an actively appended Codex rollout and build its .jidx.
    .DESCRIPTION
        Codex keeps active rollouts open. This reader deliberately uses
        FileShare.ReadWrite|Delete, then drops an incomplete JSON tail if the
        snapshot races an in-progress append.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SourcePath,

        [Parameter(Mandatory)]
        [string]$WorkingDir,

        [string]$FileName
    )

    if (-not [System.IO.File]::Exists($SourcePath))
    {
        throw "Codex rollout not found: $SourcePath"
    }
    return New-ChatJsonlSnapshot `
        -SourcePath $SourcePath `
        -WorkingDir $WorkingDir `
        -FileName $FileName
}

function script:Copy-CodexFilePrefix
{
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [System.IO.Stream]$Destination,

        [Parameter(Mandatory)]
        [long]$ByteLength
    )

    $share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
    $source = [System.IO.FileStream]::new(
        $Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share)
    try
    {
        if ($ByteLength -gt $source.Length)
        {
            throw ("Codex rollout span requests $ByteLength bytes, but the source " +
                "contains only $($source.Length) bytes: $Path")
        }
        [byte[]]$buffer = [byte[]]::new(1048576)
        [long]$remaining = $ByteLength
        while ($remaining -gt 0)
        {
            $wanted = [int][Math]::Min([long]$buffer.Length, $remaining)
            $read = $source.Read($buffer, 0, $wanted)
            if ($read -le 0)
            {
                throw "Codex rollout changed while copying its canonical span: $Path"
            }
            $Destination.Write($buffer, 0, $read)
            $remaining -= $read
        }
    }
    finally { $source.Dispose() }
}

function New-CodexThreadSnapshot
{
    <#
    .SYNOPSIS
        Materialize one canonical JSONL snapshot from a resolved segment chain.
    .DESCRIPTION
        Ancestors contribute only the byte prefixes named by their children.
        The selected leaf contributes every complete record visible at snapshot
        time. The resulting file can be consumed by the existing exchange parser
        exactly like the earlier single-rollout snapshot.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Resolution,

        [Parameter(Mandatory)]
        [string]$WorkingDir,

        [string]$FileName
    )

    $segments = @($Resolution.Segments)
    if ($segments.Count -eq 0)
    {
        throw 'The Codex thread resolution contains no canonical segments.'
    }
    [void][System.IO.Directory]::CreateDirectory($WorkingDir)
    if ([string]::IsNullOrWhiteSpace($FileName))
    {
        $FileName = "rollout-$($Resolution.ThreadId).jsonl"
    }

    $snapshotPath = [System.IO.Path]::Combine($WorkingDir, $FileName)
    $indexPath = [System.IO.Path]::ChangeExtension($snapshotPath, '.jidx')
    $destination = [System.IO.FileStream]::new(
        $snapshotPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)
    $materialized = [System.Collections.Generic.List[object]]::new()
    [long]$includedRecords = 0
    [long]$discardedRecords = 0
    [long]$discardedBytes = 0
    $tailDropped = $false

    try
    {
        for ($index = 0; $index -lt $segments.Count; $index++)
        {
            $segment = $segments[$index]
            if ([long]$segment.BaseOrdinal -ne $includedRecords)
            {
                throw ("Codex segment manifest changed before snapshot at " +
                    "'$($segment.SegmentId)': expected base ordinal $includedRecords, " +
                    "got $($segment.BaseOrdinal).")
            }

            $extent = script:Get-CodexJsonlExtent -Path $segment.Path
            if ([bool]$segment.IsLeaf)
            {
                [long]$byteLength = $extent.CompleteByteLength
                [long]$recordCount = $extent.RecordCount
                $needsTerminatingNewline = [bool]$extent.NeedsTerminatingNewline
                $segmentTailDropped = [bool]$extent.TailDropped
            }
            else
            {
                [long]$byteLength = $segment.IncludedByteLength
                $prefix = script:Get-CodexPrefixInfo `
                    -Path $segment.Path `
                    -ByteLength $byteLength
                [long]$recordCount = $prefix.RecordCount
                $needsTerminatingNewline = $false
                $segmentTailDropped = $false
                if ($recordCount -ne [long]$segment.IncludedRecordCount)
                {
                    throw ("Codex ancestor prefix changed before snapshot for " +
                        "'$($segment.SegmentId)'.")
                }
            }

            script:Copy-CodexFilePrefix `
                -Path $segment.Path `
                -Destination $destination `
                -ByteLength $byteLength
            if ($needsTerminatingNewline)
            {
                $destination.WriteByte(0x0A)
            }

            [long]$segmentDiscardedRecords = [Math]::Max(
                0, [long]$extent.RecordCount - $recordCount)
            [long]$segmentDiscardedBytes = [Math]::Max(
                0, [long]$extent.SourceLength - $byteLength)
            [void]$materialized.Add([pscustomobject]@{
                SegmentId               = $segment.SegmentId
                Path                    = $segment.Path
                IsArchived              = $segment.IsArchived
                IsLeaf                  = $segment.IsLeaf
                PredecessorSegmentId    = $segment.PredecessorSegmentId
                BaseOrdinal             = [long]$segment.BaseOrdinal
                IncludedByteLength      = $byteLength
                IncludedRecordCount     = $recordCount
                EffectiveEndOrdinal     = $includedRecords + $recordCount
                SourceByteLength        = [long]$extent.SourceLength
                SourceRecordCount       = [long]$extent.RecordCount
                DiscardedByteCount      = $segmentDiscardedBytes
                DiscardedRecordCount    = $segmentDiscardedRecords
                NeedsTerminatingNewline = $needsTerminatingNewline
                TailDropped             = $segmentTailDropped
                CliVersion              = $segment.CliVersion
            })

            $includedRecords += $recordCount
            $discardedRecords += $segmentDiscardedRecords
            $discardedBytes += $segmentDiscardedBytes
            if ([bool]$segment.IsLeaf) { $tailDropped = $segmentTailDropped }
        }
    }
    finally { $destination.Dispose() }

    $idx = [JsonlIndex]::Build($snapshotPath, $indexPath)
    if ([long]$idx.LineCount -ne $includedRecords)
    {
        throw ("Canonical Codex snapshot index contains $($idx.LineCount) records; " +
            "the segment manifest reconstructed $includedRecords.")
    }

    $result = [pscustomobject]@{
        SnapshotPath      = $snapshotPath
        IndexPath         = $indexPath
        LineCount         = [long]$idx.LineCount
        TailDropped       = $tailDropped
        SourcePath        = $Resolution.RolloutPath
        SourcePaths       = @($materialized | ForEach-Object { $_.Path })
        SourceCount       = $materialized.Count
        CandidateCount    = [int]$Resolution.CandidateCount
        SegmentCount      = $materialized.Count
        Fragmented        = $materialized.Count -gt 1
        SelectedSegmentId = [string]$Resolution.SelectedSegmentId
        SelectionReason   = [string]$Resolution.SelectionReason
        DiscardedRecords  = $discardedRecords
        DiscardedBytes    = $discardedBytes
        Segments          = $materialized.ToArray()
    }
    return Assert-ChatFrozenSourceContract -FrozenSource $result
}

function script:New-CodexToolCallAtomic
{
    param(
        [object]$Payload,
        [string]$Timestamp,
        [string]$TurnId,
        [System.Collections.Generic.Dictionary[string, object]]$OutputMap
    )

    $callId = [string]$Payload.call_id
    if ([string]::IsNullOrWhiteSpace($callId)) { $callId = [string]$Payload.id }

    $toolName = [string]$Payload.name
    if ([string]::IsNullOrWhiteSpace($toolName)) { $toolName = [string]$Payload.tool }
    if ([string]::IsNullOrWhiteSpace($toolName)) { $toolName = [string]$Payload.type }

    $toolInput = $null
    if ($Payload.PSObject.Properties.Name -contains 'arguments')
    {
        $toolInput = script:ConvertFrom-CodexJsonString $Payload.arguments
    }
    elseif ($Payload.PSObject.Properties.Name -contains 'input')
    {
        $toolInput = script:ConvertFrom-CodexJsonString $Payload.input
    }
    elseif ($Payload.PSObject.Properties.Name -contains 'query')
    {
        $toolInput = [ordered]@{ query = $Payload.query }
    }

    $response = $null
    if ($callId -and $OutputMap.ContainsKey($callId))
    {
        $matched = $OutputMap[$callId]
        $response = [ordered]@{
            tool_use_id = $callId
            _timestamp  = $matched.Timestamp
            content     = $matched.Content
        }
    }

    return [ordered]@{
        _type        = 'tool_call'
        _source_uuid = if ($Payload.id) { [string]$Payload.id } else { $callId }
        _timestamp   = $Timestamp
        _turn_id     = $TurnId
        tool_use_id  = $callId
        tool_name    = $toolName
        tool_kind    = [string]$Payload.type
        status       = [string]$Payload.status
        input        = $toolInput
        response     = $response
    }
}

function Get-CodexExchanges
{
    <#
    .SYNOPSIS
        Normalize a snapshot rollout into exchange-envelope objects.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SnapshotPath,

        [Parameter(Mandatory)]
        [string]$ThreadId,

        [string]$UserLabel = 'Aipithicus'
    )

    if (-not [System.IO.File]::Exists($SnapshotPath))
    {
        throw "Snapshot not found: $SnapshotPath"
    }

    $outputMap = [System.Collections.Generic.Dictionary[string, object]]::new(
        [StringComparer]::Ordinal)
    $hasTurnContext = $false

    foreach ($line in [System.IO.File]::ReadLines($SnapshotPath))
    {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $record = $line | ConvertFrom-Json -Depth 100 } catch { continue }
        if ($record.type -eq 'turn_context')
        {
            $hasTurnContext = $true
            continue
        }
        if ($record.type -ne 'response_item') { continue }
        $payload = $record.payload
        if ($payload.type -notin @(
                'function_call_output', 'custom_tool_call_output', 'tool_search_output'))
        {
            continue
        }
        $callId = [string]$payload.call_id
        if ([string]::IsNullOrWhiteSpace($callId)) { continue }

        $content = if ($payload.PSObject.Properties.Name -contains 'output')
        {
            script:ConvertFrom-CodexJsonString $payload.output
        }
        elseif ($payload.PSObject.Properties.Name -contains 'content')
        {
            $payload.content
        }
        else { $payload }

        $outputMap[$callId] = [pscustomobject]@{
            Timestamp = script:ConvertTo-CodexIsoTimestamp $record.timestamp
            Content   = $content
        }
    }

    $meta = script:Get-CodexSessionMeta -Path $SnapshotPath
    $sessionDepth = 0
    try
    {
        if ($null -ne $meta.source.subagent.thread_spawn.depth)
        {
            $sessionDepth = [int]$meta.source.subagent.thread_spawn.depth
        }
    }
    catch { $sessionDepth = 0 }

    $exchanges = [System.Collections.Generic.List[object]]::new()
    $state = [pscustomobject]@{
        CurrentTurnId = $null
        CurrentModel  = $null
        CurrentEffort = $null
        AcceptUser    = $false
        Current       = $null
    }

    $closeExchange = {
        if ($null -eq $state.Current) { return }
        $state.Current._exchange_end = $state.Current._last_timestamp
        $state.Current._turn_count = $state.Current.records.Count
        $state.Current.Remove('_last_timestamp')
        [void]$exchanges.Add($state.Current)
        $state.Current = $null
    }

    $addAtomic = {
        param([object]$Atomic)
        if ($null -eq $state.Current -or $null -eq $Atomic) { return }
        [void]$state.Current.records.Add($Atomic)
        if ($Atomic._timestamp)
        {
            $state.Current._last_timestamp = [string]$Atomic._timestamp
        }
    }

    foreach ($line in [System.IO.File]::ReadLines($SnapshotPath))
    {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $record = $line | ConvertFrom-Json -Depth 100 } catch { continue }
        $payload = $record.payload
        $timestamp = script:ConvertTo-CodexIsoTimestamp $record.timestamp

        if ($record.type -eq 'event_msg')
        {
            switch ([string]$payload.type)
            {
                'task_started'
                {
                    & $closeExchange
                    $state.CurrentTurnId = [string]$payload.turn_id
                    $state.CurrentModel = $null
                    $state.CurrentEffort = $null
                    # Imported/legacy rollouts may have no turn_context records.
                    # In that format the first user response_item follows
                    # task_started directly and is the visible prompt.
                    $state.AcceptUser = -not $hasTurnContext
                }
                'task_complete'
                {
                    if ($state.Current)
                    {
                        $state.Current._status = 'completed'
                        $state.Current._last_timestamp = $timestamp
                    }
                    & $closeExchange
                }
                'turn_aborted'
                {
                    if ($state.Current)
                    {
                        $state.Current._status = 'interrupted'
                        $state.Current._last_timestamp = $timestamp
                    }
                    & $closeExchange
                }
                'thread_rolled_back'
                {
                    & $closeExchange
                    $turnsToDrop = [Math]::Max(0, [int]$payload.num_turns)
                    for ($drop = 0; $drop -lt $turnsToDrop; $drop++)
                    {
                        if ($exchanges.Count -eq 0) { break }
                        $lastTurnId = [string]$exchanges[$exchanges.Count - 1]._turn_id
                        while ($exchanges.Count -gt 0 -and
                            [string]$exchanges[$exchanges.Count - 1]._turn_id -eq $lastTurnId)
                        {
                            $exchanges.RemoveAt($exchanges.Count - 1)
                        }
                    }
                }
                'sub_agent_activity'
                {
                    if ($state.Current)
                    {
                        & $addAtomic ([ordered]@{
                            _type        = 'subagent'
                            _source_uuid = [string]$payload.event_id
                            _timestamp   = $timestamp
                            _turn_id     = $state.CurrentTurnId
                            _agentid     = [string]$payload.agent_thread_id
                            _agenttype   = [string]$payload.kind
                            _agentdesc   = [string]$payload.agent_path
                            text         = ''
                        })
                    }
                }
            }
            continue
        }

        if ($record.type -eq 'turn_context')
        {
            if ($payload.turn_id) { $state.CurrentTurnId = [string]$payload.turn_id }
            $state.CurrentModel = [string]$payload.model
            $state.CurrentEffort = [string]$payload.effort
            $state.AcceptUser = $true
            continue
        }

        if ($record.type -ne 'response_item') { continue }

        switch ([string]$payload.type)
        {
            'message'
            {
                $role = [string]$payload.role
                $text = script:Get-CodexMessageText $payload

                if ($role -eq 'user')
                {
                    # Desktop bootstrap can persist model-visible user context
                    # before turn_context. It is not a visible human turn.
                    if (-not $state.AcceptUser -and $null -eq $state.Current) { continue }
                    if ([string]::IsNullOrWhiteSpace($text)) { continue }

                    & $closeExchange
                    $xidx = $exchanges.Count
                    $records = [System.Collections.Generic.List[object]]::new()
                    [void]$records.Add([ordered]@{
                        _type        = 'prompt'
                        _source_uuid = if ($payload.id) { [string]$payload.id } else { $ThreadId }
                        _timestamp   = $timestamp
                        _turn_id     = $state.CurrentTurnId
                        text         = $text
                    })
                    $state.Current = [ordered]@{
                        _xid            = "$ThreadId-$($xidx.ToString('D4'))"
                        _xidx           = $xidx
                        _thread_id      = $ThreadId
                        _turn_id        = $state.CurrentTurnId
                        _source_thread  = [System.IO.Path]::GetFileName($SnapshotPath)
                        _session_uuid   = $ThreadId
                        _session_depth  = $sessionDepth
                        _exchange_start = $timestamp
                        _exchange_end   = $timestamp
                        _turn_count     = 1
                        _model          = $state.CurrentModel
                        _effort         = $state.CurrentEffort
                        _user_label     = $UserLabel
                        _status         = 'in_progress'
                        _last_timestamp = $timestamp
                        records         = $records
                    }
                    $state.AcceptUser = $false
                }
                elseif ($role -eq 'assistant' -and
                    $state.Current -and
                    -not [string]::IsNullOrWhiteSpace($text))
                {
                    & $addAtomic ([ordered]@{
                        _type        = 'response'
                        _source_uuid = if ($payload.id) { [string]$payload.id } else { $ThreadId }
                        _timestamp   = $timestamp
                        _turn_id     = $state.CurrentTurnId
                        phase        = if ($payload.phase) { [string]$payload.phase } else { 'final_answer' }
                        text         = $text
                    })
                }
            }
            'agent_message'
            {
                $text = script:Get-CodexMessageText $payload
                if ($state.Current -and -not [string]::IsNullOrWhiteSpace($text))
                {
                    & $addAtomic ([ordered]@{
                        _type        = 'response'
                        _source_uuid = if ($payload.id) { [string]$payload.id } else { $ThreadId }
                        _timestamp   = $timestamp
                        _turn_id     = $state.CurrentTurnId
                        phase        = if ($payload.phase) { [string]$payload.phase } else { 'final_answer' }
                        text         = $text
                    })
                }
            }
            'reasoning'
            {
                $text = script:Get-CodexReasoningText $payload
                if ($state.Current -and -not [string]::IsNullOrWhiteSpace($text))
                {
                    & $addAtomic ([ordered]@{
                        _type        = 'thinking'
                        _source_uuid = if ($payload.id) { [string]$payload.id } else { $ThreadId }
                        _timestamp   = $timestamp
                        _turn_id     = $state.CurrentTurnId
                        text         = $text
                    })
                }
            }
            { $_ -in @('function_call', 'custom_tool_call', 'tool_search_call') }
            {
                if ($state.Current)
                {
                    $atomic = script:New-CodexToolCallAtomic `
                        -Payload $payload `
                        -Timestamp $timestamp `
                        -TurnId $state.CurrentTurnId `
                        -OutputMap $outputMap
                    & $addAtomic $atomic
                }
            }
        }
    }

    & $closeExchange
    return $exchanges.ToArray()
}

function Export-CodexExchanges
{
    <#
    .SYNOPSIS
        Write one canonical JSONL record per exchange and build a .jidx.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Exchanges,

        [Parameter(Mandatory)]
        [string]$WorkingDir,

        [Parameter(Mandatory)]
        [string]$ThreadId,

        [string]$OutputPrefix = 'thread'
    )

    return Export-ChatExchanges `
        -Exchanges $Exchanges `
        -WorkingDir $WorkingDir `
        -Identity $ThreadId `
        -OutputPrefix $OutputPrefix
}
