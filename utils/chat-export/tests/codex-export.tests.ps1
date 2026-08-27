$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\..\codex-export\codex-jso-run.ps1"

[int]$script:AssertionCount = 0

function Assert-Equal
{
    param(
        [object]$Actual,
        [object]$Expected,
        [string]$Label
    )

    $script:AssertionCount++
    if ($Actual -ne $Expected)
    {
        throw "$Label — expected '$Expected', got '$Actual'."
    }
}

function Assert-True
{
    param(
        [bool]$Condition,
        [string]$Label
    )

    $script:AssertionCount++
    if (-not $Condition) { throw "$Label — condition was false." }
}

function Assert-ThrowsLike
{
    param(
        [scriptblock]$Action,
        [string]$Pattern,
        [string]$Label
    )

    $script:AssertionCount++
    try
    {
        [void](& $Action)
    }
    catch
    {
        if ($_.Exception.Message -notmatch $Pattern)
        {
            throw "$Label — wrong error: $($_.Exception.Message)"
        }
        return
    }
    throw "$Label — expected an exception matching '$Pattern'."
}

function New-CodexFixtureTurnRecords
{
    param(
        [string]$TurnId,
        [string]$Prompt,
        [string]$Response,
        [string]$Timestamp
    )

    return @(
        [ordered]@{
            timestamp = $Timestamp
            type      = 'event_msg'
            payload   = [ordered]@{ type = 'task_started'; turn_id = $TurnId }
        },
        [ordered]@{
            timestamp = $Timestamp
            type      = 'turn_context'
            payload   = [ordered]@{
                turn_id = $TurnId
                model   = 'codex-test'
                effort  = 'medium'
            }
        },
        [ordered]@{
            timestamp = $Timestamp
            type      = 'response_item'
            payload   = [ordered]@{
                type    = 'message'
                role    = 'user'
                id      = "$TurnId-user"
                content = @([ordered]@{ type = 'input_text'; text = $Prompt })
            }
        },
        [ordered]@{
            timestamp = $Timestamp
            type      = 'response_item'
            payload   = [ordered]@{
                type    = 'message'
                role    = 'assistant'
                id      = "$TurnId-assistant"
                phase   = 'final_answer'
                content = @([ordered]@{ type = 'output_text'; text = $Response })
            }
        },
        [ordered]@{
            timestamp = $Timestamp
            type      = 'event_msg'
            payload   = [ordered]@{ type = 'task_complete'; turn_id = $TurnId }
        }
    )
}

function New-CodexFixtureSegmentRecords
{
    param(
        [string]$ThreadId,
        [string]$Prompt,
        [string]$TurnId,
        [string]$Timestamp,
        [object]$HistoryBase,
        [string]$DiscardedPrompt
    )

    $meta = [ordered]@{
        id             = $ThreadId
        timestamp      = $Timestamp
        cwd            = 'D:\fixture'
        originator     = 'codex-export-test'
        cli_version    = 'test'
        model_provider = 'openai'
        source         = [ordered]@{}
        session_id     = $ThreadId
        thread_source  = 'test'
    }
    if ($null -ne $HistoryBase) { $meta.history_base = $HistoryBase }

    $records = [System.Collections.Generic.List[object]]::new()
    [void]$records.Add([ordered]@{
            timestamp = $Timestamp
            type      = 'session_meta'
            payload   = $meta
        })
    foreach ($record in @(New-CodexFixtureTurnRecords `
            -TurnId $TurnId `
            -Prompt $Prompt `
            -Response "response to $Prompt" `
            -Timestamp $Timestamp))
    {
        [void]$records.Add($record)
    }

    if (-not [string]::IsNullOrWhiteSpace($DiscardedPrompt))
    {
        foreach ($record in @(New-CodexFixtureTurnRecords `
                -TurnId "$TurnId-discarded" `
                -Prompt $DiscardedPrompt `
                -Response "discarded response" `
                -Timestamp $Timestamp))
        {
            [void]$records.Add($record)
        }
    }
    return $records.ToArray()
}

function Write-CodexFixtureJsonl
{
    param(
        [string]$Path,
        [object[]]$Records
    )

    $directory = [System.IO.Path]::GetDirectoryName($Path)
    if ($directory) { [void][System.IO.Directory]::CreateDirectory($directory) }
    $encoding = [System.Text.UTF8Encoding]::new($false)
    $stream = [System.IO.MemoryStream]::new()
    $offsets = [System.Collections.Generic.List[long]]::new()
    try
    {
        foreach ($record in $Records)
        {
            $json = ConvertTo-CanonicalJson -InputObject $record -Compress
            $bytes = $encoding.GetBytes($json)
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.WriteByte(0x0A)
            [void]$offsets.Add($stream.Length)
        }
        [System.IO.File]::WriteAllBytes($Path, $stream.ToArray())
    }
    finally { $stream.Dispose() }

    return [pscustomobject]@{
        Path    = $Path
        Offsets = $offsets.ToArray()
        Count   = $Records.Count
    }
}

function Get-CodexFixtureRolloutPath
{
    param(
        [string]$CodexHome,
        [string]$ThreadId,
        [string]$SegmentId,
        [string]$Stamp,
        [switch]$Archived
    )

    $directory = if ($Archived)
    {
        Join-Path $CodexHome 'archived_sessions'
    }
    else
    {
        Join-Path $CodexHome 'sessions\2026\08\27'
    }
    $name = "rollout-$Stamp-$ThreadId"
    if (-not [string]::IsNullOrWhiteSpace($SegmentId))
    {
        $name += "_$SegmentId"
    }
    return Join-Path $directory "$name.jsonl"
}

$temporaryBase = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd(
    [System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
$temporaryRoot = Join-Path $temporaryBase (
    'codex-export-tests-' + [guid]::NewGuid().ToString('N'))
[void][System.IO.Directory]::CreateDirectory($temporaryRoot)

try
{
    # Regression: one logical thread has an exact-name aborted bootstrap plus a
    # canonical history_base chain split between archived and active storage.
    $threadId = 'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa'
    $rootId = '11111111-1111-4111-8111-111111111111'
    $middleId = '22222222-2222-4222-8222-222222222222'
    $leafId = '33333333-3333-4333-8333-333333333333'
    $codexHome = Join-Path $temporaryRoot 'fragmented-home'

    $orphanPath = Get-CodexFixtureRolloutPath `
        -CodexHome $codexHome -ThreadId $threadId `
        -Stamp '2026-08-27T00-00-00'
    [void](Write-CodexFixtureJsonl -Path $orphanPath -Records (
            New-CodexFixtureSegmentRecords `
                -ThreadId $threadId `
                -Prompt 'orphan bootstrap' `
                -TurnId 'orphan-turn' `
                -Timestamp '2026-08-27T00:00:00Z'))

    $rootPath = Get-CodexFixtureRolloutPath `
        -CodexHome $codexHome -ThreadId $threadId -SegmentId $rootId `
        -Stamp '2026-08-27T00-00-01' -Archived
    $rootWrite = Write-CodexFixtureJsonl -Path $rootPath -Records (
        New-CodexFixtureSegmentRecords `
            -ThreadId $threadId `
            -Prompt 'root prompt' `
            -TurnId 'root-turn' `
            -Timestamp '2026-08-27T00:00:01Z' `
            -DiscardedPrompt 'discarded root tail')

    $middleHistory = [ordered]@{
        thread_id            = $rootId
        end_ordinal_exclusive = 6
        end_byte_offset       = $rootWrite.Offsets[5]
    }
    $middlePath = Get-CodexFixtureRolloutPath `
        -CodexHome $codexHome -ThreadId $threadId -SegmentId $middleId `
        -Stamp '2026-08-27T00-00-02'
    $middleWrite = Write-CodexFixtureJsonl -Path $middlePath -Records (
        New-CodexFixtureSegmentRecords `
            -ThreadId $threadId `
            -Prompt 'middle prompt' `
            -TurnId 'middle-turn' `
            -Timestamp '2026-08-27T00:00:02Z' `
            -HistoryBase $middleHistory `
            -DiscardedPrompt 'discarded middle tail')

    $leafHistory = [ordered]@{
        thread_id            = $middleId
        end_ordinal_exclusive = 12
        end_byte_offset       = $middleWrite.Offsets[5]
    }
    $leafPath = Get-CodexFixtureRolloutPath `
        -CodexHome $codexHome -ThreadId $threadId -SegmentId $leafId `
        -Stamp '2026-08-27T00-00-03'
    [void](Write-CodexFixtureJsonl -Path $leafPath -Records (
            New-CodexFixtureSegmentRecords `
                -ThreadId $threadId `
                -Prompt 'leaf prompt' `
                -TurnId 'leaf-turn' `
                -Timestamp '2026-08-27T00:00:03Z' `
                -HistoryBase $leafHistory))

    $resolution = Resolve-CodexThreadPath `
        -ThreadId $threadId -CodexHome $codexHome
    Assert-Equal $resolution.CandidateCount 4 'fragmented fixture candidate count'
    Assert-Equal $resolution.SegmentCount 3 'fragmented fixture chain depth'
    Assert-Equal $resolution.SelectedSegmentId $leafId 'greatest ordinal selects canonical leaf'
    Assert-Equal $resolution.SelectionReason 'greatest-cumulative-ordinal' 'selection reason is explicit'
    Assert-Equal $resolution.EffectiveRecords 18 'canonical cumulative record count'
    Assert-True $resolution.Fragmented 'chain is marked fragmented'
    Assert-True $resolution.Segments[0].IsArchived 'archived root participates in active chain'
    Assert-Equal $resolution.Segments[0].DiscardedRecordCount 5 'root tail is discarded'
    Assert-Equal $resolution.Segments[1].DiscardedRecordCount 5 'middle tail is discarded'

    $result = Invoke-CodexThreadExport `
        -ThreadId $threadId `
        -CodexHome $codexHome `
        -WorkingDir (Join-Path $temporaryRoot 'fragmented-work') `
        -RunStamp '20260827_000000' `
        -MarkdownDir (Join-Path $temporaryRoot 'fragmented-output') `
        -OutputPrefix 'fixture' `
        -Exclude @() `
        -NormalizeWhitespace:$false
    Assert-Equal $result.Stats.SourceRecords 18 'runner snapshots canonical records only'
    Assert-Equal $result.Stats.ExchangeCount 3 'runner reconstructs all canonical exchanges'
    Assert-Equal $result.Stats.CandidateCount 4 'runner reports all candidate files'
    Assert-Equal $result.Stats.SegmentCount 3 'runner reports canonical chain depth'
    Assert-Equal $result.Stats.DiscardedRecords 10 'runner reports abandoned ancestor records'
    Assert-Equal $result.RolloutPaths.Count 3 'runner exposes all canonical source paths'
    Assert-True ([System.IO.File]::Exists($result.MarkdownPath)) 'fragmented export writes Markdown'
    Assert-True ([System.IO.File]::Exists($result.SnapshotPath)) 'fragmented export writes canonical snapshot'

    $snapshotText = [System.IO.File]::ReadAllText($result.SnapshotPath)
    Assert-True (-not $snapshotText.Contains('orphan bootstrap')) 'orphan bootstrap is excluded'
    Assert-True (-not $snapshotText.Contains('discarded root tail')) 'root discarded tail is excluded'
    Assert-True (-not $snapshotText.Contains('discarded middle tail')) 'middle discarded tail is excluded'
    Assert-True ($snapshotText.Contains('root prompt')) 'root retained prefix is included'
    Assert-True ($snapshotText.Contains('leaf prompt')) 'leaf records are included'

    # A single exact-name rollout preserves the legacy behavior while dropping
    # a concurrently appended incomplete JSON tail.
    $tailThreadId = 'bbbbbbbb-1111-4111-8111-bbbbbbbbbbbb'
    $tailHome = Join-Path $temporaryRoot 'tail-home'
    $tailPath = Get-CodexFixtureRolloutPath `
        -CodexHome $tailHome -ThreadId $tailThreadId `
        -Stamp '2026-08-27T01-00-00'
    [void](Write-CodexFixtureJsonl -Path $tailPath -Records (
            New-CodexFixtureSegmentRecords `
                -ThreadId $tailThreadId `
                -Prompt 'single prompt' `
                -TurnId 'single-turn' `
                -Timestamp '2026-08-27T01:00:00Z'))
    $tailBytes = [System.Text.UTF8Encoding]::new($false).GetBytes('{incomplete')
    $tailStream = [System.IO.FileStream]::new(
        $tailPath, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write)
    try { $tailStream.Write($tailBytes, 0, $tailBytes.Length) }
    finally { $tailStream.Dispose() }

    $single = Invoke-CodexThreadExport `
        -ThreadId $tailThreadId `
        -CodexHome $tailHome `
        -WorkingDir (Join-Path $temporaryRoot 'tail-work') `
        -RunStamp '20260827_010000' `
        -RunThrough Exchanges
    Assert-Equal $single.Stats.SourceRecords 6 'single rollout retains six complete records'
    Assert-Equal $single.Stats.ExchangeCount 1 'single rollout produces one exchange'
    Assert-Equal $single.Stats.SegmentCount 1 'single rollout remains one segment'
    Assert-True (-not $single.Stats.Fragmented) 'single rollout is not fragmented'
    Assert-True $single.Stats.TailDropped 'single rollout drops incomplete active tail'

    # Missing predecessors fail only after a leaf is selected; no unrelated
    # rollout is silently substituted.
    $missingThread = 'cccccccc-1111-4111-8111-cccccccccccc'
    $missingHome = Join-Path $temporaryRoot 'missing-home'
    $missingLeaf = '44444444-4444-4444-8444-444444444444'
    $missingHistory = [ordered]@{
        thread_id            = '99999999-9999-4999-8999-999999999999'
        end_ordinal_exclusive = 50
        end_byte_offset       = 0
    }
    [void](Write-CodexFixtureJsonl `
            -Path (Get-CodexFixtureRolloutPath `
                -CodexHome $missingHome -ThreadId $missingThread `
                -SegmentId $missingLeaf -Stamp '2026-08-27T02-00-00') `
            -Records (New-CodexFixtureSegmentRecords `
                -ThreadId $missingThread `
                -Prompt 'missing predecessor' `
                -TurnId 'missing-turn' `
                -Timestamp '2026-08-27T02:00:00Z' `
                -HistoryBase $missingHistory))
    Assert-ThrowsLike `
        -Action { Resolve-CodexThreadPath -ThreadId $missingThread -CodexHome $missingHome } `
        -Pattern 'missing predecessor' `
        -Label 'missing predecessor fails loudly'

    # A child cutoff must end immediately after LF and its cumulative ordinal
    # must equal the number of records reconstructed through that prefix.
    $boundaryThread = 'dddddddd-1111-4111-8111-dddddddddddd'
    $boundaryHome = Join-Path $temporaryRoot 'boundary-home'
    $boundaryRootId = '55555555-5555-4555-8555-555555555555'
    $boundaryLeafId = '66666666-6666-4666-8666-666666666666'
    $boundaryRootPath = Get-CodexFixtureRolloutPath `
        -CodexHome $boundaryHome -ThreadId $boundaryThread `
        -SegmentId $boundaryRootId -Stamp '2026-08-27T03-00-00'
    $boundaryRoot = Write-CodexFixtureJsonl `
        -Path $boundaryRootPath `
        -Records (New-CodexFixtureSegmentRecords `
            -ThreadId $boundaryThread `
            -Prompt 'boundary root' `
            -TurnId 'boundary-root-turn' `
            -Timestamp '2026-08-27T03:00:00Z')
    $badBoundaryHistory = [ordered]@{
        thread_id            = $boundaryRootId
        end_ordinal_exclusive = 6
        end_byte_offset       = $boundaryRoot.Offsets[5] - 1
    }
    [void](Write-CodexFixtureJsonl `
            -Path (Get-CodexFixtureRolloutPath `
                -CodexHome $boundaryHome -ThreadId $boundaryThread `
                -SegmentId $boundaryLeafId -Stamp '2026-08-27T03-00-01') `
            -Records (New-CodexFixtureSegmentRecords `
                -ThreadId $boundaryThread `
                -Prompt 'boundary leaf' `
                -TurnId 'boundary-leaf-turn' `
                -Timestamp '2026-08-27T03:00:01Z' `
                -HistoryBase $badBoundaryHistory))
    Assert-ThrowsLike `
        -Action { Resolve-CodexThreadPath -ThreadId $boundaryThread -CodexHome $boundaryHome } `
        -Pattern 'record boundary' `
        -Label 'mid-record history_base offset fails'

    $ordinalThread = 'eeeeeeee-1111-4111-8111-eeeeeeeeeeee'
    $ordinalHome = Join-Path $temporaryRoot 'ordinal-home'
    $ordinalRootId = '77777777-7777-4777-8777-777777777777'
    $ordinalLeafId = '88888888-8888-4888-8888-888888888888'
    $ordinalRoot = Write-CodexFixtureJsonl `
        -Path (Get-CodexFixtureRolloutPath `
            -CodexHome $ordinalHome -ThreadId $ordinalThread `
            -SegmentId $ordinalRootId -Stamp '2026-08-27T04-00-00') `
        -Records (New-CodexFixtureSegmentRecords `
            -ThreadId $ordinalThread `
            -Prompt 'ordinal root' `
            -TurnId 'ordinal-root-turn' `
            -Timestamp '2026-08-27T04:00:00Z')
    $badOrdinalHistory = [ordered]@{
        thread_id            = $ordinalRootId
        end_ordinal_exclusive = 7
        end_byte_offset       = $ordinalRoot.Offsets[5]
    }
    [void](Write-CodexFixtureJsonl `
            -Path (Get-CodexFixtureRolloutPath `
                -CodexHome $ordinalHome -ThreadId $ordinalThread `
                -SegmentId $ordinalLeafId -Stamp '2026-08-27T04-00-01') `
            -Records (New-CodexFixtureSegmentRecords `
                -ThreadId $ordinalThread `
                -Prompt 'ordinal leaf' `
                -TurnId 'ordinal-leaf-turn' `
                -Timestamp '2026-08-27T04:00:01Z' `
                -HistoryBase $badOrdinalHistory))
    Assert-ThrowsLike `
        -Action { Resolve-CodexThreadPath -ThreadId $ordinalThread -CodexHome $ordinalHome } `
        -Pattern 'ordinal mismatch' `
        -Label 'history_base ordinal mismatch fails'

    # Equal cumulative leaves are genuinely ambiguous unless the caller names
    # one physical leaf explicitly.
    $ambiguousThread = 'ffffffff-1111-4111-8111-ffffffffffff'
    $ambiguousHome = Join-Path $temporaryRoot 'ambiguous-home'
    $ambiguousA = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1'
    $ambiguousB = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb2'
    foreach ($fixture in @(
            [pscustomobject]@{ SegmentId = $ambiguousA; Stamp = '2026-08-27T05-00-00'; Prompt = 'branch a' },
            [pscustomobject]@{ SegmentId = $ambiguousB; Stamp = '2026-08-27T05-00-01'; Prompt = 'branch b' }))
    {
        [void](Write-CodexFixtureJsonl `
                -Path (Get-CodexFixtureRolloutPath `
                    -CodexHome $ambiguousHome -ThreadId $ambiguousThread `
                    -SegmentId $fixture.SegmentId -Stamp $fixture.Stamp) `
                -Records (New-CodexFixtureSegmentRecords `
                    -ThreadId $ambiguousThread `
                    -Prompt $fixture.Prompt `
                    -TurnId "$($fixture.SegmentId)-turn" `
                    -Timestamp '2026-08-27T05:00:00Z'))
    }
    Assert-ThrowsLike `
        -Action { Resolve-CodexThreadPath -ThreadId $ambiguousThread -CodexHome $ambiguousHome } `
        -Pattern 'Supply -LeafSegmentId' `
        -Label 'equal cumulative leaves fail as ambiguous'
    $explicit = Resolve-CodexThreadPath `
        -ThreadId $ambiguousThread `
        -CodexHome $ambiguousHome `
        -LeafSegmentId $ambiguousB
    Assert-Equal $explicit.SelectedSegmentId $ambiguousB 'explicit leaf resolves ambiguity'
    Assert-Equal $explicit.SelectionReason 'explicit-leaf-segment-id' 'explicit selection is reported'

    Assert-ThrowsLike `
        -Action { Resolve-CodexThreadPath -ThreadId 'not-a-uuid' -CodexHome $codexHome } `
        -Pattern 'Malformed Codex thread id' `
        -Label 'malformed logical thread id fails'

    Write-Host "PASS: $script:AssertionCount Codex export assertions" -ForegroundColor Green
}
finally
{
    if ([System.IO.Directory]::Exists($temporaryRoot))
    {
        $resolvedTemporaryRoot = [System.IO.Path]::GetFullPath($temporaryRoot)
        if (-not $resolvedTemporaryRoot.StartsWith(
                $temporaryBase, [StringComparison]::OrdinalIgnoreCase))
        {
            throw "Refusing to remove Codex test path outside the system temp directory: $resolvedTemporaryRoot"
        }
        Remove-Item -LiteralPath $resolvedTemporaryRoot -Recurse -Force
    }
}
