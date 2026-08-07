# codex-jso-run.ps1 — Minimal single-thread Codex export pipeline
#
# Pipeline:
#   Resolve rollout -> snapshot -> exchange envelopes -> Markdown

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

        [string]$OutputPrefix = 'thread'
    )

    $timer = [Diagnostics.Stopwatch]::StartNew()
    $resolved = Resolve-CodexThreadPath -ThreadId $ThreadId -CodexHome $CodexHome

    if ([string]::IsNullOrWhiteSpace($WorkingDir))
    {
        $WorkingDir = [System.IO.Path]::Combine(
            $resolved.CodexHome, 'tmp', 'codex-jso-run')
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
    $snapshot = New-CodexJsonlSnapshot `
        -SourcePath $resolved.RolloutPath `
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
        SourceRecords = $snapshot.LineCount
        ExchangeCount = $exchangeResult.ExchangeCount
        TailDropped   = $snapshot.TailDropped
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
            SnapshotPath  = $snapshot.SnapshotPath
            ExchangesPath = $exchangeResult.ExchangesPath
            MarkdownPath  = $null
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
            $MarkdownDir, "$OutputPrefix-$ThreadId.md")
    }
    elseif ($env:JSO_EXPORT_DIR)
    {
        [System.IO.Path]::Combine(
            $env:JSO_EXPORT_DIR, "$OutputPrefix-$ThreadId.md")
    }
    else
    {
        [System.IO.Path]::Combine(
            $runDir, 'output', "$OutputPrefix-$ThreadId.md")
    }

    ConvertTo-CodexMarkdown `
        -ExchangesJsonlPath $exchangeResult.ExchangesPath `
        -OutputPath $resolvedMarkdownPath `
        -Format $Format `
        -Exclude $Exclude `
        -MaxToolInputLength $MaxToolInputLength

    $timer.Stop()
    return [pscustomobject]@{
        ThreadId      = $ThreadId
        WorkingDir    = $WorkingDir
        RunStamp      = $RunStamp
        RunDir        = $runDir
        RolloutPath   = $resolved.RolloutPath
        SnapshotPath  = $snapshot.SnapshotPath
        ExchangesPath = $exchangeResult.ExchangesPath
        MarkdownPath  = $resolvedMarkdownPath
        Stats         = $stats
        Elapsed       = $timer.Elapsed
    }
}
