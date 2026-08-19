<#
.SYNOPSIS
    Export a Grok session to exchange-envelope JSONL and Markdown.

.DESCRIPTION
    Agent-facing entry point. In a Grok session, the current session id is
    supplied by $env:GROK_SESSION_ID, so the normal invocation needs no
    arguments:

        & "D:\aghado01\science-facility\utils\chat-export\grok-export\Export-GrokChat.ps1"

    The command above is the complete agent contract. Do not read or dot-source
    this script or its helper modules merely to learn how to export; inspect the
    implementation only when the user explicitly asks to debug or change it.

    Report the returned paths. Do not read the generated transcript back into
    the session context.

.PARAMETER SessionId
    Grok session UUID. Defaults to $env:GROK_SESSION_ID and fails loudly when
    neither is available.

.PARAMETER MarkdownDir
    Destination for the Markdown artifact. Defaults to $env:JSO_EXPORT_DIR,
    then D:\aghado01\.discussion.

.PARAMETER Exclude
    Components omitted from Markdown only. The exchanges IR always retains the
    normalized records. Pass @() to render everything.

.PARAMETER NormalizeWhitespace
    Controls the shared final-Markdown whitespace and Unicode postprocessor.
    Defaults to $true. Use -NormalizeWhitespace:$false for forensic comparison
    with the renderer's pre-postprocessor Markdown. Canonical JSONL is unaffected.

.PARAMETER OutputEncoding
    Markdown file encoding. Utf8 (default) preserves the existing BOM-less
    output. Utf16LE is an opt-in code-unit-preserving forensic format with an
    FF FE byte-order mark. Canonical JSONL remains UTF-8.
#>
[CmdletBinding()]
param(
    [string]$SessionId = $env:GROK_SESSION_ID,

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

    [string]$OutputPrefix = 'Grok',

    [string]$UserLabel = 'Aipithicus',

    [AllowNull()]
    [Nullable[int]]$MaxToolInputLength = 500,

    [bool]$NormalizeWhitespace = $true,

    [ValidateSet('Utf8', 'Utf16LE')]
    [string]$OutputEncoding = 'Utf8'
)

$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\grok-jso-run.ps1"

if ([string]::IsNullOrWhiteSpace($SessionId))
{
    throw ('No Grok session id. $env:GROK_SESSION_ID is empty and -SessionId ' +
        'was not supplied. Refusing to guess which session to export.')
}

if ([string]::IsNullOrWhiteSpace($MarkdownDir))
{
    $MarkdownDir = $env:JSO_EXPORT_DIR
}
if ([string]::IsNullOrWhiteSpace($MarkdownDir))
{
    $MarkdownDir = 'D:\aghado01\.discussion'
}

$result = Invoke-GrokThreadExport `
    -SessionId $SessionId `
    -WorkingDir $WorkingDir `
    -RunStamp $RunStamp `
    -MarkdownDir $MarkdownDir `
    -OutputPrefix $OutputPrefix `
    -Format $Format `
    -Exclude $Exclude `
    -UserLabel $UserLabel `
    -MaxToolInputLength $MaxToolInputLength `
    -NormalizeWhitespace $NormalizeWhitespace `
    -OutputEncoding $OutputEncoding

Write-Host "`nExported Markdown → $($result.MarkdownPath)" -ForegroundColor Green
Write-Host "Exchange IR      → $($result.ExchangesPath)" -ForegroundColor Green

return [pscustomobject]@{
    MarkdownPath  = $result.MarkdownPath
    ExchangesPath = $result.ExchangesPath
    SessionId     = $result.SessionId
    ThreadId      = $result.ThreadId
    HistoryPath   = $result.HistoryPath
    SessionDir    = $result.SessionDir
    WorkingDir    = $result.WorkingDir
    RunStamp      = $result.RunStamp
    RunDir        = $result.RunDir
    NormalizeWhitespace = $result.NormalizeWhitespace
    OutputEncoding = $result.OutputEncoding
    Stats         = $result.Stats
}
