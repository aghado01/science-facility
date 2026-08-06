<#
.SYNOPSIS
    Export a Claude Code chat thread to markdown. The agent-facing entry point.

.DESCRIPTION
    Call this script directly with `&` — it dot-sources what it needs and takes
    bound parameters from the calling shell. Nothing to load first:

        & "D:\aghado01\utils\jso-jackson\claude-export\Export-ClaudeChat.ps1" `
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

.OUTPUTS
    PSCustomObject { MarkdownPath, SessionId, ProjectName, ThreadId }
    Report the path. Do not read the file back — it is the conversation you just
    had, and pulling it into context is what this tool exists to avoid.

#>
[CmdletBinding()]
param(
    [string]$SessionId = $env:CLAUDE_CODE_SESSION_ID,

    [string]$MarkdownDir,

    [ValidateSet('thinking', 'tool-calls', 'tool-results', 'subagents',
        'synthetic', 'timestamps', 'session-markers', 'exchange-markers')]
    [string[]]$Exclude = @('thinking', 'synthetic', 'timestamps', 'session-markers',
        'exchange-markers', 'tool-calls', 'tool-results', 'subagents'),

    [string]$OutputPrefix = 'Claude'
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
