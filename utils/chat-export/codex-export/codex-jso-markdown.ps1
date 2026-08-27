# codex-jso-markdown.ps1 — Codex compatibility adapter for shared Markdown

$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\..\shared\markdown.ps1"

function ConvertTo-CodexMarkdown
{
    <#
    .SYNOPSIS
        Render Codex exchange-envelope JSONL through the shared renderer.
    .DESCRIPTION
        Compatibility entry point retained for callers of the original Codex
        renderer. Provider labeling, assistant naming, and thread-first
        frontmatter policy are bound here; rendering is client-agnostic.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ExchangesJsonlPath,

        [string]$OutputPath,

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
        [string]$OutputEncoding = 'Utf8'
    )

    if (-not [System.IO.File]::Exists($ExchangesJsonlPath))
    {
        throw "Codex exchanges JSONL not found: $ExchangesJsonlPath"
    }

    return ConvertTo-ChatMarkdown `
        -ExchangesJsonlPath $ExchangesJsonlPath `
        -OutputPath $OutputPath `
        -Provider codex `
        -AssistantLabel Codex `
        -IdentityKind Thread `
        -Format $Format `
        -Exclude $Exclude `
        -MaxToolInputLength $MaxToolInputLength `
        -NormalizeWhitespace $NormalizeWhitespace `
        -OutputEncoding $OutputEncoding
}
