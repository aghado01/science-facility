<#
.SYNOPSIS
    Export a forensic pre-normalization/normalized Markdown pair from one freeze.

.DESCRIPTION
    Agent-facing research wrapper for Claude Code and Codex transcripts. It
    freezes the live source once through the exchanges stage, renders Markdown
    exactly once with normalization disabled, and derives the normalized sibling
    directly from that frozen in-memory Markdown master.

    This avoids a second renderer invocation, so dynamic frontmatter such as
    exported_at cannot drift between the files. Both siblings are written with
    the same encoding. Their only content transformation is therefore the call:

        normalized = Format-ChatExportMarkdown(pre-normalization)

    The special forensic defaults retain all supported content and do not
    truncate tool input. Canonical snapshot, merged, and exchange JSONL remain
    UTF-8 and are never normalized.

.EXAMPLE
    & "D:\aghado01\science-facility\utils\chat-export\Export-ChatWhitespacePair.ps1" `
        -Provider Codex

.EXAMPLE
    & "D:\aghado01\science-facility\utils\chat-export\Export-ChatWhitespacePair.ps1" `
        -Provider Claude `
        -OutputEncoding Utf16LE

.PARAMETER Provider
    Transcript provider: Codex or Claude.

.PARAMETER OutputEncoding
    Encoding shared by both Markdown siblings. Utf8 (default) is BOM-less.
    Utf16LE writes FF FE plus each rendered .NET UTF-16 code unit verbatim.

.OUTPUTS
    PSCustomObject containing frozen-source provenance, sibling paths, byte
    lengths, SHA-256 hashes, encoding, and the enforced pair invariant.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Codex', 'Claude')]
    [string]$Provider,

    [string]$ThreadId = $env:CODEX_THREAD_ID,

    [string]$SessionId = $env:CLAUDE_CODE_SESSION_ID,

    [string]$OutputDir,

    [string]$WorkingDir,

    [string]$RunStamp,

    [string]$OutputPrefix,

    [ValidateSet('Diarized', 'Dialogue', 'Structural', 'House')]
    [string]$Format = 'Structural',

    [ValidateSet('thinking', 'commentary', 'tool-calls', 'tool-results',
        'subagents', 'synthetic', 'timestamps', 'session-markers',
        'exchange-markers')]
    [string[]]$Exclude = @(),

    [string]$UserLabel = 'Aipithicus',

    [AllowNull()]
    [Nullable[int]]$MaxToolInputLength = $null,

    [ValidateSet('Utf8', 'Utf16LE')]
    [string]$OutputEncoding = 'Utf8',

    [switch]$Force
)

$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\chat-export-output.ps1"

if ([string]::IsNullOrWhiteSpace($OutputDir))
{
    $OutputDir = $env:JSO_EXPORT_DIR
}
if ([string]::IsNullOrWhiteSpace($OutputDir))
{
    $OutputDir = 'D:\aghado01\.discussion'
}
$OutputDir = [System.IO.Path]::GetFullPath($OutputDir)

if ([string]::IsNullOrWhiteSpace($WorkingDir))
{
    $WorkingDir = [System.IO.Path]::Combine(
        (Get-Location).Path, '.codex', 'chat-export')
}
$WorkingDir = [System.IO.Path]::GetFullPath($WorkingDir)

if ([string]::IsNullOrWhiteSpace($RunStamp))
{
    $RunStamp = [datetime]::UtcNow.ToString('yyyyMMdd_HHmmss')
}
if ($RunStamp -notmatch '^[0-9]{8}_[0-9]{6}$')
{
    throw "Malformed run stamp '$RunStamp'. Expected UTC yyyyMMdd_HHmmss."
}

$providerKey = $Provider.ToLowerInvariant()
$providerWorkingDir = [System.IO.Path]::Combine($WorkingDir, "forensic-$providerKey")
$caseWorkingDir = [System.IO.Path]::Combine($providerWorkingDir, $RunStamp)
if ([System.IO.Directory]::Exists($caseWorkingDir))
{
    throw "Forensic working directory already exists: $caseWorkingDir"
}

if ([string]::IsNullOrWhiteSpace($OutputPrefix))
{
    $OutputPrefix = "$Provider-forensic-$RunStamp"
}

$freezeResult = $null
$masterMarkdown = $null
$frozenSourcePath = $null
$resolvedIdentity = $null

if ($Provider -eq 'Codex')
{
    if ([string]::IsNullOrWhiteSpace($ThreadId))
    {
        throw ('No Codex thread id. $env:CODEX_THREAD_ID is empty and ' +
            '-ThreadId was not supplied.')
    }

    . "$PSScriptRoot\codex-export\codex-jso-run.ps1"
    $freezeResult = Invoke-CodexThreadExport `
        -ThreadId $ThreadId `
        -WorkingDir $providerWorkingDir `
        -RunStamp $RunStamp `
        -RunThrough Exchanges `
        -OutputPrefix $OutputPrefix `
        -UserLabel $UserLabel `
        -OutputEncoding $OutputEncoding

    [string]$masterMarkdown = ConvertTo-CodexMarkdown `
        -ExchangesJsonlPath $freezeResult.ExchangesPath `
        -Format $Format `
        -Exclude $Exclude `
        -MaxToolInputLength $MaxToolInputLength `
        -NormalizeWhitespace:$false

    $resolvedIdentity = $freezeResult.ThreadId
    $frozenSourcePath = $freezeResult.SnapshotPath
}
else
{
    if ([string]::IsNullOrWhiteSpace($SessionId))
    {
        throw ('No Claude session id. $env:CLAUDE_CODE_SESSION_ID is empty and ' +
            '-SessionId was not supplied.')
    }
    if ($Exclude -contains 'commentary')
    {
        throw "Claude exports do not support the 'commentary' exclusion token."
    }

    . "$PSScriptRoot\claude-export\claude-jso-run.ps1"
    $freezeResult = Invoke-ClaudeThreadExport `
        -SessionId $SessionId `
        -WorkingDir $caseWorkingDir `
        -RunThrough Exchanges `
        -OutputPrefix $OutputPrefix `
        -UserLabel $UserLabel `
        -OutputEncoding $OutputEncoding

    [string]$masterMarkdown = ConvertTo-ClaudeMarkdownV2 `
        -ExchangesJsonlPath $freezeResult.ExchangesPath `
        -Format $Format `
        -Exclude $Exclude `
        -MaxToolInputLength $MaxToolInputLength `
        -NormalizeWhitespace:$false

    $resolvedIdentity = $freezeResult.ThreadId
    $frozenSourcePath = $freezeResult.MergedPath
}

$outputStem = "$OutputPrefix-$resolvedIdentity"
$preNormalizationPath = [System.IO.Path]::Combine(
    $OutputDir, "$outputStem.pre-normalization.md")
$normalizedPath = [System.IO.Path]::Combine(
    $OutputDir, "$outputStem.normalized.md")

if (-not $Force)
{
    $existingPaths = @($preNormalizationPath, $normalizedPath) |
        Where-Object { [System.IO.File]::Exists($_) }
    if ($existingPaths.Count -gt 0)
    {
        throw ('Refusing to replace existing forensic output without -Force: ' +
            ($existingPaths -join ', '))
    }
}

$pair = Export-ChatExportMarkdownPair `
    -MasterMarkdown $masterMarkdown `
    -PreNormalizationPath $preNormalizationPath `
    -NormalizedPath $normalizedPath `
    -OutputEncoding $OutputEncoding

$frozenSourceSha256 = (Get-FileHash `
        -LiteralPath $frozenSourcePath `
        -Algorithm SHA256).Hash
$exchangesSha256 = (Get-FileHash `
        -LiteralPath $freezeResult.ExchangesPath `
        -Algorithm SHA256).Hash

Write-Host "`nFrozen source     → $frozenSourcePath" -ForegroundColor Green
Write-Host "Pre-normalization → $($pair.PreNormalizationPath)" -ForegroundColor Green
Write-Host "Normalized        → $($pair.NormalizedPath)" -ForegroundColor Green

return [PSCustomObject]@{
    Provider                  = $Provider
    ThreadId                  = $resolvedIdentity
    SessionId                 = if ($Provider -eq 'Claude') { $SessionId } else { $null }
    WorkingDir                = $freezeResult.WorkingDir
    RunStamp                  = $RunStamp
    FrozenSourcePath          = $frozenSourcePath
    FrozenSourceSha256        = $frozenSourceSha256
    ExchangesPath             = $freezeResult.ExchangesPath
    ExchangesSha256           = $exchangesSha256
    PreNormalizationPath      = $pair.PreNormalizationPath
    NormalizedPath            = $pair.NormalizedPath
    OutputEncoding            = $pair.OutputEncoding
    ByteOrderMark             = $pair.ByteOrderMark
    PreNormalizationBytes     = $pair.PreNormalizationBytes
    NormalizedBytes           = $pair.NormalizedBytes
    PreNormalizationSha256    = $pair.PreNormalizationSha256
    NormalizedSha256          = $pair.NormalizedSha256
    NormalizationChanged      = $pair.NormalizationChanged
    PairInvariant             = $pair.PairInvariant
    RenderCount               = 1
    Stats                     = $freezeResult.Stats
}
