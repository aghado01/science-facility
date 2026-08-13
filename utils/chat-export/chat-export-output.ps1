# chat-export-output.ps1 — Shared Markdown byte encoding and forensic pair writer

. "$PSScriptRoot\chat-export-format-ws.ps1"

function ConvertTo-ChatExportBytes
{
    <#
    .SYNOPSIS
        Encode rendered chat-export text using a supported output encoding.
    .DESCRIPTION
        Utf8 preserves the existing exporter contract: UTF-8 without a BOM.
        Utf16LE writes an FF FE BOM followed by every .NET UTF-16 code unit
        verbatim. The latter deliberately preserves isolated surrogate code
        units for forensic work instead of replacing or rejecting them.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Text,

        [ValidateSet('Utf8', 'Utf16LE')]
        [string]$OutputEncoding = 'Utf8'
    )

    if ($null -eq $Text) { $Text = '' }

    if ($OutputEncoding -eq 'Utf8')
    {
        $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($Text)
        return ,$bytes
    }

    # UnicodeEncoding replaces or rejects isolated surrogates. Writing the
    # little-endian code units directly retains the exact PowerShell/.NET
    # string representation requested by the forensic UTF-16 mode.
    if ($Text.Length -gt [int](([int]::MaxValue - 2) / 2))
    {
        throw 'Rendered Markdown is too large to encode as one UTF-16LE byte array.'
    }

    $bytes = [byte[]]::new(2 + (2 * $Text.Length))
    $bytes[0] = 0xFF
    $bytes[1] = 0xFE
    for ($index = 0; $index -lt $Text.Length; $index++)
    {
        $codeUnit = [int][char]$Text[$index]
        $offset = 2 + (2 * $index)
        $bytes[$offset] = [byte]($codeUnit -band 0xFF)
        $bytes[$offset + 1] = [byte](($codeUnit -shr 8) -band 0xFF)
    }
    return ,$bytes
}

function Write-ChatExportText
{
    <#
    .SYNOPSIS
        Write rendered chat-export text with the shared encoding contract.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$Text,

        [ValidateSet('Utf8', 'Utf16LE')]
        [string]$OutputEncoding = 'Utf8'
    )

    $resolvedPath = [System.IO.Path]::GetFullPath($Path)
    $outputDir = [System.IO.Path]::GetDirectoryName($resolvedPath)
    if ($outputDir -and -not [System.IO.Directory]::Exists($outputDir))
    {
        [void][System.IO.Directory]::CreateDirectory($outputDir)
    }

    $bytes = ConvertTo-ChatExportBytes `
        -Text $Text `
        -OutputEncoding $OutputEncoding
    [System.IO.File]::WriteAllBytes($resolvedPath, $bytes)
}

function script:Get-ChatExportFileSha256
{
    param([Parameter(Mandatory)][string]$Path)

    $stream = [System.IO.File]::OpenRead($Path)
    $sha = [Security.Cryptography.SHA256]::Create()
    try
    {
        return [Convert]::ToHexString($sha.ComputeHash($stream))
    }
    finally
    {
        $sha.Dispose()
        $stream.Dispose()
    }
}

function Export-ChatExportMarkdownPair
{
    <#
    .SYNOPSIS
        Write pre-normalization and normalized Markdown from one frozen string.
    .DESCRIPTION
        The normalized sibling is calculated exactly once as
        Format-ChatExportMarkdown(MasterMarkdown). Both strings are then encoded
        through the same writer, so no second render, clock read, or source read
        can introduce an unrelated difference.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$MasterMarkdown,

        [Parameter(Mandatory)]
        [string]$PreNormalizationPath,

        [Parameter(Mandatory)]
        [string]$NormalizedPath,

        [ValidateSet('Utf8', 'Utf16LE')]
        [string]$OutputEncoding = 'Utf8'
    )

    $resolvedPrePath = [System.IO.Path]::GetFullPath($PreNormalizationPath)
    $resolvedNormalizedPath = [System.IO.Path]::GetFullPath($NormalizedPath)
    if ([string]::Equals(
            $resolvedPrePath,
            $resolvedNormalizedPath,
            [StringComparison]::OrdinalIgnoreCase))
    {
        throw 'Pre-normalization and normalized output paths must be distinct.'
    }

    $normalizedMarkdown = Format-ChatExportMarkdown -Markdown $MasterMarkdown
    Write-ChatExportText `
        -Path $resolvedPrePath `
        -Text $MasterMarkdown `
        -OutputEncoding $OutputEncoding
    Write-ChatExportText `
        -Path $resolvedNormalizedPath `
        -Text $normalizedMarkdown `
        -OutputEncoding $OutputEncoding

    $preInfo = [System.IO.FileInfo]::new($resolvedPrePath)
    $normalizedInfo = [System.IO.FileInfo]::new($resolvedNormalizedPath)
    return [PSCustomObject]@{
        PreNormalizationPath   = $resolvedPrePath
        NormalizedPath         = $resolvedNormalizedPath
        OutputEncoding        = $OutputEncoding
        ByteOrderMark          = if ($OutputEncoding -eq 'Utf16LE') { 'FF FE' } else { $null }
        PreNormalizationBytes  = $preInfo.Length
        NormalizedBytes        = $normalizedInfo.Length
        PreNormalizationSha256 = script:Get-ChatExportFileSha256 -Path $resolvedPrePath
        NormalizedSha256       = script:Get-ChatExportFileSha256 -Path $resolvedNormalizedPath
        NormalizationChanged   = -not [string]::Equals(
            $MasterMarkdown,
            $normalizedMarkdown,
            [StringComparison]::Ordinal)
        PairInvariant          = 'normalized = Format-ChatExportMarkdown(pre-normalization)'
    }
}
