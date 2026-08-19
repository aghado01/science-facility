# grok-jso-run.ps1 — Minimal single-session Grok export pipeline
#
# Pipeline:
#   Resolve session -> snapshot chat_history.jsonl -> exchange envelopes -> Markdown

$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\grok-jso-jackson.ps1"
. "$PSScriptRoot\grok-jso-markdown.ps1"

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
            $resolved.GrokHome, 'tmp', 'grok-jso-run')
    }
    $WorkingDir = [System.IO.Path]::GetFullPath($WorkingDir)

    if ([string]::IsNullOrWhiteSpace($RunStamp))
    {
        $RunStamp = Get-JobTimestamp
    }
    if ($RunStamp -notmatch '^[0-9]{8}_[0-9]{6}$')
    {
        throw "Malformed run stamp '$RunStamp'. Expected UTC yyyyMMdd_HHmmss."
    }

    $runDir = [System.IO.Path]::Combine($WorkingDir, $RunStamp)
    [void][System.IO.Directory]::CreateDirectory($runDir)

    $rawDir = [System.IO.Path]::Combine($runDir, 'raw')
    $snapshot = New-GrokJsonlSnapshot `
        -SourcePath $resolved.HistoryPath `
        -WorkingDir $rawDir `
        -FileName "chat_history-$SessionId.jsonl"

    $exchanges = @(Get-GrokExchanges `
        -SnapshotPath $snapshot.SnapshotPath `
        -SessionId $SessionId `
        -UserLabel $UserLabel `
        -DefaultModel $resolved.Model `
        -DefaultEffort $resolved.Effort)
    $exchangeResult = Export-GrokExchanges `
        -Exchanges $exchanges `
        -WorkingDir $runDir `
        -SessionId $SessionId `
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
            WorkingDir    = $WorkingDir
            RunStamp      = $RunStamp
            RunDir        = $runDir
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

    $resolvedMarkdownPath = if ($MarkdownPath)
    {
        $MarkdownPath
    }
    elseif ($MarkdownDir)
    {
        [System.IO.Path]::Combine(
            $MarkdownDir, "$OutputPrefix-$SessionId.md")
    }
    elseif ($env:JSO_EXPORT_DIR)
    {
        [System.IO.Path]::Combine(
            $env:JSO_EXPORT_DIR, "$OutputPrefix-$SessionId.md")
    }
    else
    {
        [System.IO.Path]::Combine(
            $runDir, 'output', "$OutputPrefix-$SessionId.md")
    }

    ConvertTo-GrokMarkdown `
        -ExchangesJsonlPath $exchangeResult.ExchangesPath `
        -OutputPath $resolvedMarkdownPath `
        -Format $Format `
        -Exclude $Exclude `
        -MaxToolInputLength $MaxToolInputLength `
        -NormalizeWhitespace $NormalizeWhitespace `
        -OutputEncoding $OutputEncoding

    $timer.Stop()
    return [pscustomobject]@{
        SessionId     = $SessionId
        ThreadId      = $SessionId
        WorkingDir    = $WorkingDir
        RunStamp      = $RunStamp
        RunDir        = $runDir
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
