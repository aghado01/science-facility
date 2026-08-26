<#
.LINK
    docs/rs-content_meta.md
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
