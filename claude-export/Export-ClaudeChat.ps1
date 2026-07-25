<#
.SYNOPSIS
    Export a Claude Code chat thread to markdown. The agent-facing entry point.

.DESCRIPTION
    Call this script directly with `&` — it dot-sources what it needs and takes
    bound parameters from the calling shell. Nothing to load first:

        & "D:\aghado01\utils\jso-jackson\claude-export\Export-ClaudeChat.ps1" `
            -SessionId $env:CLAUDE_CODE_SESSION_ID

    Everything has an everyday default, and every default can be overridden when
    the user asks for something different. What is NOT a parameter is the
    transcript's location: a session id resolves to its own `.jsonl` path, and
    the project directory is a component of that path, so neither the source
    directory nor the project slug is ever something the caller supplies.

    For anything outside the three knobs below — a different `-Format`, an exact
    output filename, stopping at an intermediate pipeline stage — use
    `Invoke-ClaudeThreadExport` from claude-jso-run.ps1, which exposes the lot.
    See README.md.

    LIMITATION — a conversation can span several session files. A thread that is
    continued leaves a `.jsonl.idx` sentinel and gets reassembled automatically.
    But switching to another chat and back within a running Claude app mints a
    new session id with no sentinel and no back-link, so the earlier portion is
    a separate file this export will not include. If an export appears to begin
    mid-conversation, that is why. See issues/brief-redundant-session-ids.md §8.

.PARAMETER SessionId
    The thread to export. Defaults to $env:CLAUDE_CODE_SESSION_ID — the session
    the calling agent is running inside. Throws if that is also empty rather
    than guessing. Note $env:CLAUDE_CODE_HOST_SESSION_ID is a different id and
    is NOT the transcript key.

.PARAMETER MarkdownDir
    Destination directory for the markdown. Defaults to $env:JSO_EXPORT_DIR when
    set, otherwise D:\aghado01\.discussion. Override when the user names a
    location.

.PARAMETER Exclude
    Record classes to leave out. Defaults to the everyday reading profile: the
    prose conversation and nothing else. Override when the user asks to keep
    something — e.g. `-Exclude thinking,synthetic` keeps tool calls and results,
    and `-Exclude @()` keeps everything.

    Valid values: thinking, tool-calls, tool-results, subagents, synthetic,
    timestamps, session-markers, exchange-markers.

.PARAMETER OutputPrefix
    Filename stem; the file is {OutputPrefix}-{threadId}.md. Default 'chat'.

.OUTPUTS
    PSCustomObject { MarkdownPath, SessionId, ProjectName, ThreadId }
    Report the path. Do not read the file back — it is the conversation you just
    had, and pulling it into context is what this tool exists to avoid.

.EXAMPLE
    & .\Export-ClaudeChat.ps1 -SessionId $env:CLAUDE_CODE_SESSION_ID
    # everyday defaults

.EXAMPLE
    & .\Export-ClaudeChat.ps1 -SessionId $id -MarkdownDir 'D:\aghado01\notes'
    # user named a destination

.EXAMPLE
    & .\Export-ClaudeChat.ps1 -SessionId $id -Exclude thinking,synthetic
    # user asked to keep tool calls and results
#>
[CmdletBinding()]
param(
    [string]$SessionId = $env:CLAUDE_CODE_SESSION_ID,

    [string]$MarkdownDir,

    [ValidateSet('thinking', 'tool-calls', 'tool-results', 'subagents',
        'synthetic', 'timestamps', 'session-markers', 'exchange-markers')]
    [string[]]$Exclude = @('thinking', 'synthetic', 'timestamps', 'session-markers',
        'exchange-markers', 'tool-calls', 'tool-results', 'subagents'),

    [string]$OutputPrefix = 'chat'
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
    -Exclude      $Exclude

Write-Host "`nExported → $($result.MarkdownPath)" -ForegroundColor Green

return [PSCustomObject]@{
    MarkdownPath = $result.MarkdownPath
    SessionId    = $SessionId
    ProjectName  = $resolved.ProjectName
    ThreadId     = $result.ThreadId
}
