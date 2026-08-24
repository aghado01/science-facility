<#
.SYNOPSIS
    Per-document metadata processor (ContentMeta statistics).

.DESCRIPTION
    Attaches a ContentMeta object of pure string statistics over $Item.Content —
    the in-memory source of the psr content_meta wire block. Language-agnostic
    by position (metrics are content-form statistics with zero language knowledge).

    POSITIONAL CONTRACT:
      - Enrich-only TAIL step: place after ALL content-mutating steps of any kind.
      - ContentMeta describes PROCESSED content, deliberately not the on-disk original.
      - BYTE SEMANTICS: Metrics deal in SpanBytes (UTF-8 byte span of processed content).
      - CANONICAL UTF-8: Measured in UTF-8 by convention, invariant to serializer emission.

    NO-CONTENT CONTRACT:
      Items without a usable Content property pass through unchanged (no ContentMeta).

    DELIBERATE NON-PARITY — CompressionRatio:
      LTS emitted compression_ratio = 0 due to disposing the stream before reading length.
      This processor reads $ms.ToArray() and emits the real ratio.

    ISS-load-safe: no #Requires, no Set-StrictMode, top-level param contract.
      - Item contract:  descriptor (Content; open-bag copy-on-enrich)
      - Position class: enrich-only tail (after ALL content mutators)
      - Intended Colonel IssPreset floor: Core
      - Required IssModules: none

.PARAMETER Item
    String, hashtable, or pscustomobject descriptor carrying Content.
.PARAMETER Config
    Hashtable for per-step configuration (reserved).
#>
param($Item, $Config)

#region NoContentGuard
# Pass through unenriched if no usable Content string is present.
if ($null -eq $Item.PSObject.Properties['Content'] -or $Item.Content -isnot [string])
{
    return $Item
}

$content = [string]$Item.Content
#endregion

#region Counts
$charCount = if ($content) { $content.Length } else { 0 }
$wordCount = if ($content) { ($content -split '\s+').Count } else { 0 }
$punctCount = if ($content) { [regex]::Matches($content, '\p{P}').Count } else { 0 }
#endregion

#region ShannonEntropy
$entropy = 0.0
$uniqueChars = 0
if ($content -and $charCount -gt 0)
{
    $freqs = [System.Collections.Generic.Dictionary[char, int]]::new()
    foreach ($c in $content.ToCharArray())
    {
        $n = 0
        if ($freqs.TryGetValue($c, [ref]$n)) { $freqs[$c] = $n + 1 } else { $freqs[$c] = 1 }
    }
    $uniqueChars = $freqs.Count
    foreach ($v in $freqs.Values)
    {
        $p = $v / $charCount
        if ($p -gt 0) { $entropy += -1 * $p * [Math]::Log($p, 2) }
    }
}
#endregion

#region CompressionRatio
# Kolmogorov complexity proxy (>100 chars only)
$compressionRatio = 1.0
if ($content -and $charCount -gt 100)
{
    try
    {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($content)
        $ms = [System.IO.MemoryStream]::new()
        $gz = [System.IO.Compression.GZipStream]::new($ms, [System.IO.Compression.CompressionMode]::Compress)
        $gz.Write($bytes, 0, $bytes.Length)
        $gz.Close()   # flushes AND disposes $ms
        $compressionRatio = [Math]::Round($ms.ToArray().Length / $bytes.Length, 4)
    }
    catch { }
}
#endregion

#region WhitespaceRatio
$whitespaceRatio = 0.0
if ($content -and $charCount -gt 0)
{
    $whitespaceCount = [regex]::Matches($content, '\s').Count
    $whitespaceRatio = [Math]::Round($whitespaceCount / $charCount, 4)
}
#endregion

#region LineStats
$lineStats = [PSCustomObject]@{ Mean = 0; Median = 0; StdDev = 0; Max = 0 }
if ($content -and $charCount -gt 0)
{
    $lengths = foreach ($line in ($content -split "`n")) { $line.Length }
    $lengths = @($lengths)
    if ($lengths.Count -gt 0)
    {
        $sum = 0; foreach ($l in $lengths) { $sum += $l }
        $mean = $sum / $lengths.Count
        $sorted = [int[]]$lengths
        [Array]::Sort($sorted)
        $median = $sorted[[Math]::Floor($sorted.Count / 2)]
        $varSum = 0.0; foreach ($l in $lengths) { $varSum += [Math]::Pow($l - $mean, 2) }
        $lineStats = [PSCustomObject]@{
            Mean   = [Math]::Round($mean, 2)
            Median = $median
            StdDev = [Math]::Round([Math]::Sqrt($varSum / $lengths.Count), 2)
            Max    = $sorted[$sorted.Count - 1]
        }
    }
}
#endregion

#region Emit
# Copy-on-enrich via shared Copy-Bag helper: clone all input properties, then attach.
return Copy-Bag -Item $Item -Add ([ordered]@{
        ContentMeta = [PSCustomObject]@{
            SpanBytes        = if ($content) { [System.Text.Encoding]::UTF8.GetByteCount($content) } else { 0 }
            CharCount        = $charCount
            WordCount        = $wordCount
            PunctuationCount = $punctCount
            UniqueChars      = $uniqueChars
            Entropy          = [Math]::Round($entropy, 4)
            CompressionRatio = $compressionRatio
            WhitespaceRatio  = $whitespaceRatio
            LineStats        = $lineStats
        }
    })
#endregion
