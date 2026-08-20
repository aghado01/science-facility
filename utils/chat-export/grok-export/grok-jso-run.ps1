# grok-jso-run.ps1 — Grok session export pipeline
#
# Client-specific: resolve session, parse chat_history into exchange envelopes.
# Shared: live JSONL snapshot, exchange IR write, Markdown render, path/runstamp.

$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\grok-jso-jackson.ps1"
. "$PSScriptRoot\..\shared\markdown.ps1"

function Invoke-GrokThreadExport
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SessionId,

        [string]$GrokHome,
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

        [string]$OutputPrefix = 'thread'
    )

    $timer = [Diagnostics.Stopwatch]::StartNew()
    $resolved = Resolve-GrokSessionPath -SessionId $SessionId -GrokHome $GrokHome

    if ([string]::IsNullOrWhiteSpace($WorkingDir))
    {
        $WorkingDir = [System.IO.Path]::Combine(
            $resolved.GrokHome, 'chat-export')
    }

    $run = Resolve-ChatRunDir -WorkingDir $WorkingDir -RunStamp $RunStamp
    $snapshot = New-ChatJsonlSnapshot `
        -SourcePath $resolved.HistoryPath `
        -WorkingDir ([System.IO.Path]::Combine($run.RunDir, 'raw')) `
        -FileName "chat_history-$SessionId.jsonl"

    $exchanges = @(Get-GrokExchanges `
        -SnapshotPath $snapshot.SnapshotPath `
        -SessionId $SessionId `
        -UserLabel $UserLabel `
        -DefaultModel $resolved.Model `
        -DefaultEffort $resolved.Effort)
    $exchangeResult = Export-ChatExchanges `
        -Exchanges $exchanges `
        -WorkingDir $run.RunDir `
        -Identity $SessionId `
        -OutputPrefix $OutputPrefix

    $stats = [pscustomobject]@{
        SourceRecords = $snapshot.LineCount
        ExchangeCount = $exchangeResult.ExchangeCount
        TailDropped   = $snapshot.TailDropped
    }

    if ($RunThrough -eq 'Exchanges')
    {
        $timer.Stop()
        return [pscustomobject]@{
            SessionId     = $SessionId
            ThreadId      = $SessionId
            WorkingDir    = $run.WorkingDir
            RunStamp      = $run.RunStamp
            RunDir        = $run.RunDir
            HistoryPath   = $resolved.HistoryPath
            SessionDir    = $resolved.SessionDir
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
        -RunDir $run.RunDir `
        -OutputPrefix $OutputPrefix `
        -Identity $SessionId

    ConvertTo-ChatMarkdown `
        -ExchangesJsonlPath $exchangeResult.ExchangesPath `
        -OutputPath $resolvedMarkdownPath `
        -Provider grok `
        -AssistantLabel Grok `
        -Format $Format `
        -Exclude $Exclude `
        -MaxToolInputLength $MaxToolInputLength `
        -NormalizeWhitespace $NormalizeWhitespace `
        -OutputEncoding $OutputEncoding

    $timer.Stop()
    return [pscustomobject]@{
        SessionId     = $SessionId
        ThreadId      = $SessionId
        WorkingDir    = $run.WorkingDir
        RunStamp      = $run.RunStamp
        RunDir        = $run.RunDir
        HistoryPath   = $resolved.HistoryPath
        SessionDir    = $resolved.SessionDir
        SnapshotPath  = $snapshot.SnapshotPath
        ExchangesPath = $exchangeResult.ExchangesPath
        MarkdownPath  = $resolvedMarkdownPath
        NormalizeWhitespace = $NormalizeWhitespace
        OutputEncoding = $OutputEncoding
        Stats         = $stats
        Elapsed       = $timer.Elapsed
    }
}
