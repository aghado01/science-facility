# codex-jso-run.ps1 — Minimal single-thread Codex export pipeline
#
# Pipeline:
#   Resolve rollout chain -> canonical snapshot -> exchange envelopes -> Markdown

$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\codex-jso-jackson.ps1"
. "$PSScriptRoot\codex-jso-markdown.ps1"

function Invoke-CodexThreadExport
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ThreadId,

        [string]$CodexHome,
        [string]$WorkingDir,
        [string]$RunStamp,

        [ValidateSet('Exchanges', 'Markdown')]
        [string]$RunThrough = 'Markdown',

        [string]$MarkdownPath,
        [string]$MarkdownDir,
        [string]$UserLabel = 'Aipithicus',

        [ValidateSet('Diarized', 'Dialogue', 'Structural', 'House')]
        [string]$Format = 'Structural',

        [ValidateSet('thinking', 'commentary', 'tool-calls', 'tool-results',
            'subagents', 'synthetic', 'timestamps', 'session-markers',
            'exchange-markers')]
        [string[]]$Exclude = @(
            'thinking', 'commentary', 'tool-calls', 'tool-results',
            'subagents', 'synthetic', 'timestamps', 'session-markers',
            'exchange-markers'),

        [AllowNull()]
        [Nullable[int]]$MaxToolInputLength = 500,

        [bool]$NormalizeWhitespace = $true,

        [ValidateSet('Utf8', 'Utf16LE')]
        [string]$OutputEncoding = 'Utf8',

        [string]$OutputPrefix = 'thread',

        [string]$LeafSegmentId
    )

    $timer = [Diagnostics.Stopwatch]::StartNew()
    $resolved = Resolve-CodexThreadPath `
        -ThreadId $ThreadId `
        -CodexHome $CodexHome `
        -LeafSegmentId $LeafSegmentId

    if ([string]::IsNullOrWhiteSpace($WorkingDir))
    {
        $WorkingDir = [System.IO.Path]::Combine(
            $resolved.CodexHome, 'tmp', 'codex-jso-run')
    }
    $run = Resolve-ChatRunDir -WorkingDir $WorkingDir -RunStamp $RunStamp
    $WorkingDir = $run.WorkingDir
    $RunStamp = $run.RunStamp
    $runDir = $run.RunDir

    $rawDir = [System.IO.Path]::Combine($runDir, 'raw')
    $snapshot = New-CodexThreadSnapshot `
        -Resolution $resolved `
        -WorkingDir $rawDir `
        -FileName "rollout-$ThreadId.jsonl"

    $exchanges = @(Get-CodexExchanges `
        -SnapshotPath $snapshot.SnapshotPath `
        -ThreadId $ThreadId `
        -UserLabel $UserLabel)
    $exchangeResult = Export-CodexExchanges `
        -Exchanges $exchanges `
        -WorkingDir $runDir `
        -ThreadId $ThreadId `
        -OutputPrefix $OutputPrefix

    $stats = [pscustomobject]@{
        SourceRecords    = $snapshot.LineCount
        ExchangeCount    = $exchangeResult.ExchangeCount
        TailDropped      = $snapshot.TailDropped
        CandidateCount   = $snapshot.CandidateCount
        SegmentCount     = $snapshot.SegmentCount
        Fragmented       = $snapshot.Fragmented
        SelectedSegmentId = $snapshot.SelectedSegmentId
        SelectionReason  = $snapshot.SelectionReason
        DiscardedRecords = $snapshot.DiscardedRecords
        DiscardedBytes   = $snapshot.DiscardedBytes
    }

    if ($RunThrough -eq 'Exchanges')
    {
        $timer.Stop()
        return [pscustomobject]@{
            ThreadId      = $ThreadId
            WorkingDir    = $WorkingDir
            RunStamp      = $RunStamp
            RunDir        = $runDir
            RolloutPath   = $resolved.RolloutPath
            RolloutPaths  = $resolved.RolloutPaths
            SelectedSegmentId = $resolved.SelectedSegmentId
            SegmentManifest = $snapshot.Segments
            FrozenSource   = $snapshot
            SnapshotPath  = $snapshot.SnapshotPath
            ExchangesPath = $exchangeResult.ExchangesPath
            MarkdownPath  = $null
            NormalizeWhitespace = $NormalizeWhitespace
            OutputEncoding = $OutputEncoding
            Stats         = $stats
            Elapsed       = $timer.Elapsed
        }
    }

    $resolvedMarkdownPath = Resolve-ChatMarkdownPath `
        -MarkdownPath $MarkdownPath `
        -MarkdownDir $MarkdownDir `
        -RunDir $runDir `
        -OutputPrefix $OutputPrefix `
        -Identity $ThreadId

    ConvertTo-CodexMarkdown `
        -ExchangesJsonlPath $exchangeResult.ExchangesPath `
        -OutputPath $resolvedMarkdownPath `
        -Format $Format `
        -Exclude $Exclude `
        -MaxToolInputLength $MaxToolInputLength `
        -NormalizeWhitespace $NormalizeWhitespace `
        -OutputEncoding $OutputEncoding

    $timer.Stop()
    return [pscustomobject]@{
        ThreadId      = $ThreadId
        WorkingDir    = $WorkingDir
        RunStamp      = $RunStamp
        RunDir        = $runDir
        RolloutPath   = $resolved.RolloutPath
        RolloutPaths  = $resolved.RolloutPaths
        SelectedSegmentId = $resolved.SelectedSegmentId
        SegmentManifest = $snapshot.Segments
        FrozenSource   = $snapshot
        SnapshotPath  = $snapshot.SnapshotPath
        ExchangesPath = $exchangeResult.ExchangesPath
        MarkdownPath  = $resolvedMarkdownPath
        NormalizeWhitespace = $NormalizeWhitespace
        OutputEncoding = $OutputEncoding
        Stats         = $stats
        Elapsed       = $timer.Elapsed
    }
}
