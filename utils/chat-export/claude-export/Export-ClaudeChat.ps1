<#
.SYNOPSIS
    Export a Claude Code chat thread to markdown. The agent-facing entry point.

.DESCRIPTION
    Call this script directly with `&`. The command below is the complete agent
    contract: the wrapper resolves the current session, loads its implementation,
    and applies defaults. Do not read or dot-source this script or its helper
    modules merely to learn how to export; inspect implementation only when the
    user explicitly asks to debug or change the exporter.

        & "D:\aghado01\science-facility\utils\chat-export\claude-export\Export-ClaudeChat.ps1" `
            -SessionId $env:CLAUDE_CODE_SESSION_ID

    This script exposes arguments that can be adjusted from their defaults based on user request.

.PARAMETER SessionId
    The identifier that links the thread to export.
    By default, inferred automatically from $env:CLAUDE_CODE_SESSION_ID within Claude's native shell environment
    Throws if that is also empty rather
    than guessing. Note $env:CLAUDE_CODE_HOST_SESSION_ID is a different id and
    is NOT the transcript key.

.PARAMETER MarkdownDir
    Destination directory for the markdown. Defaults to $env:JSO_EXPORT_DIR when
    set, otherwise D:\aghado01\.discussion. Override when the user names a
    location.

.PARAMETER Exclude
    Exclusion list of chat log attributes for the export.

    Valid values: thinking, tool-calls, tool-results, subagents, synthetic,
    timestamps, session-markers, exchange-markers.

    1. The user may request specific override of default settings — e.g. `-Exclude thinking,synthetic` keeps tool calls and results,
    2. `-Exclude @()` keeps everything.

.PARAMETER OutputPrefix
    Output filename prefix - the file is {OutputPrefix}-{threadId}.md. Default value is'Claude'.

.PARAMETER NormalizeWhitespace
    Controls the shared final-Markdown whitespace and Unicode postprocessor.
    Defaults to $true. Use -NormalizeWhitespace:$false for forensic comparison
    with the renderer's pre-postprocessor Markdown. Canonical JSONL is unaffected.

.PARAMETER OutputEncoding
    Markdown file encoding. Utf8 (default) preserves the existing BOM-less
    output. Utf16LE is an opt-in code-unit-preserving forensic format with an
    FF FE byte-order mark. Canonical JSONL remains UTF-8.

.OUTPUTS
    PSCustomObject { MarkdownPath, SessionId, ProjectName, ThreadId,
    NormalizeWhitespace, OutputEncoding }
    Report the returned path. Do not read the generated transcript back into the
    conversation; avoiding that redundant context load is part of this command's
    contract.

#>
[CmdletBinding()]
param(
    [string]$SessionId = $env:CLAUDE_CODE_SESSION_ID,

    [string]$MarkdownDir,

    [ValidateSet('thinking', 'tool-calls', 'tool-results', 'subagents',
        'synthetic', 'timestamps', 'session-markers', 'exchange-markers')]
    [string[]]$Exclude = @('thinking', 'synthetic', 'timestamps', 'session-markers',
        'exchange-markers', 'tool-calls', 'tool-results', 'subagents'),

    [string]$OutputPrefix = 'Claude',

    [bool]$NormalizeWhitespace = $true,

    [ValidateSet('Utf8', 'Utf16LE')]
    [string]$OutputEncoding = 'Utf8'
)

$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\claude-jso-run.ps1"

if ([string]::IsNullOrWhiteSpace($SessionId))
{
    throw ('No session id. $env:CLAUDE_CODE_SESSION_ID is empty and -SessionId was not ' +
        'supplied. This is not a condition to work around: without it there is no way to know ' +
        'which thread to export, and guessing would export the wrong one.')
}

# Preference order: what the caller asked for, then a standing destination, then
# the everyday default. The literal belongs here — this script is where personal
# defaults live, unlike the library beneath it, which hard-codes no paths.
if ([string]::IsNullOrWhiteSpace($MarkdownDir)) { $MarkdownDir = $env:JSO_EXPORT_DIR }
if ([string]::IsNullOrWhiteSpace($MarkdownDir)) { $MarkdownDir = 'D:\aghado01\.discussion' }

$resolved = Resolve-ClaudeThreadPath -SessionId $SessionId

$result = Invoke-ClaudeThreadExport `
    -SessionId    $SessionId `
    -MarkdownDir  $MarkdownDir `
    -OutputPrefix $OutputPrefix `
    -Format       'Structural' `
    -Exclude      $Exclude `
    -NormalizeWhitespace $NormalizeWhitespace `
    -OutputEncoding $OutputEncoding

Write-Host "`nExported → $($result.MarkdownPath)" -ForegroundColor Green

return [PSCustomObject]@{
    MarkdownPath = $result.MarkdownPath
    SessionId    = $SessionId
    ProjectName  = $resolved.ProjectName
    ThreadId     = $result.ThreadId
    NormalizeWhitespace = $result.NormalizeWhitespace
    OutputEncoding = $result.OutputEncoding
}
