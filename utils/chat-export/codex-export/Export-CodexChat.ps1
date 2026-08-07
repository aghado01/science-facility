<#
.SYNOPSIS
    Export a Codex task to exchange-envelope JSONL and Markdown.

.DESCRIPTION
    Agent-facing entry point. In a Codex task, the current thread id is supplied
    by $env:CODEX_THREAD_ID, so the normal invocation needs no arguments:

        & "D:\aghado01\science-facility\utils\chat-export\codex-export\Export-CodexChat.ps1"

    Report the returned paths. Do not read the generated transcript back into
    the task context.

.PARAMETER ThreadId
    Codex thread UUID. Defaults to $env:CODEX_THREAD_ID and fails loudly when
    neither is available.

.PARAMETER MarkdownDir
    Destination for the Markdown artifact. Defaults to $env:JSO_EXPORT_DIR,
    then D:\aghado01\.discussion.

.PARAMETER Exclude
    Components omitted from Markdown only. The exchanges IR always retains the
    normalized records. Pass @() to render everything.
#>
[CmdletBinding()]
param(
    [string]$ThreadId = $env:CODEX_THREAD_ID,

    [string]$MarkdownDir,

    [string]$WorkingDir,

    [string]$RunStamp,

    [ValidateSet('thinking', 'commentary', 'tool-calls', 'tool-results',
        'subagents', 'synthetic', 'timestamps', 'session-markers',
        'exchange-markers')]
    [string[]]$Exclude = @(
        'thinking', 'commentary', 'tool-calls', 'tool-results',
        'subagents', 'synthetic', 'timestamps', 'session-markers',
        'exchange-markers'),

    [ValidateSet('Diarized', 'Dialogue', 'Structural', 'House')]
    [string]$Format = 'Structural',

    [string]$OutputPrefix = 'Codex',

    [string]$UserLabel = 'Aipithicus',

    [AllowNull()]
    [Nullable[int]]$MaxToolInputLength = 500
)

$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\codex-jso-run.ps1"

if ([string]::IsNullOrWhiteSpace($ThreadId))
{
    throw ('No Codex thread id. $env:CODEX_THREAD_ID is empty and -ThreadId ' +
        'was not supplied. Refusing to guess which rollout to export.')
}

if ([string]::IsNullOrWhiteSpace($MarkdownDir))
{
    $MarkdownDir = $env:JSO_EXPORT_DIR
}
if ([string]::IsNullOrWhiteSpace($MarkdownDir))
{
    $MarkdownDir = 'D:\aghado01\.discussion'
}

$result = Invoke-CodexThreadExport `
    -ThreadId $ThreadId `
    -WorkingDir $WorkingDir `
    -RunStamp $RunStamp `
    -MarkdownDir $MarkdownDir `
    -OutputPrefix $OutputPrefix `
    -Format $Format `
    -Exclude $Exclude `
    -UserLabel $UserLabel `
    -MaxToolInputLength $MaxToolInputLength

Write-Host "`nExported Markdown → $($result.MarkdownPath)" -ForegroundColor Green
Write-Host "Exchange IR      → $($result.ExchangesPath)" -ForegroundColor Green

return [pscustomobject]@{
    MarkdownPath  = $result.MarkdownPath
    ExchangesPath = $result.ExchangesPath
    ThreadId      = $result.ThreadId
    RolloutPath   = $result.RolloutPath
    WorkingDir    = $result.WorkingDir
    RunStamp      = $result.RunStamp
    RunDir        = $result.RunDir
    Stats         = $result.Stats
}
