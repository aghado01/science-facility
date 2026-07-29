# rs-attributes.ps1 — ISS-loadable processor body
# Contract: param($Item, $Config)  →  enriched $Item
#
# Entry-metrics processor: attaches an Attributes object of pure string
# statistics over $Item.Content. Language-agnostic BY POSITION, not by
# cleverness — the metrics are content-form statistics with zero language
# knowledge; what makes them meaningful is where this step sits.
#
# POSITIONAL CONTRACT (profile invariant — enforced by profile construction,
# not by this processor, which is position-ignorant):
#   - Enrich-only TAIL step: place after ALL content-mutating steps of any
#     kind (language-specific strippers AND generic transforms like
#     format-ws). Nothing needs to run after it; order relative to other
#     enrich-only tail steps is immaterial.
#   - Attributes describe the PROCESSED content — the payload as it moves
#     forward in the pipeline — deliberately NOT the on-disk original.
#     Provenance split on the descriptor: SizeBytes (crawler identity) is
#     the on-disk stat; Attributes.* are processed-content stats.
#
# NO-CONTENT CONTRACT: items without a usable Content property pass through
# unchanged (no Attributes attached). Attributes are optional on IR entries
# (rs.core.assemble-design.md), so absence is legal — this is what makes the
# step safely appendable to profiles whose items are not file-content-shaped
# (e.g. thread envelopes carrying Exchanges[] instead of Content).
#
# Compute-vs-emit doctrine: metrics are computed by default in the chain;
# omission from serialized outputs is a WRITER knob applied end-to-end
# (schema row and data rows agree). If a run's output config never emits
# attributes anywhere, admiral compiles the profile without this step —
# that mapping is admiral's, never this processor's.
#
# Formula parity: metric formulas replicate RepoSnapshotLts.psm1 (including
# its guards and 4-decimal rounding) so the assemble-stage golden comparison
# against a fresh LTS monolith holds. Known LTS quirks kept deliberately:
# line lengths include a trailing CR on CRLF content (split on LF only);
# word split is naive \s+ (Unicode-simple). These are triage signals, not
# linguistics.
#
# DELIBERATE NON-PARITY — CompressionRatio: LTS's implementation is defective
# (reads MemoryStream.Length after GZipStream.Close() disposed the stream →
# $null → coerced 0; every >100-char LTS entry emits compression_ratio = 0 —
# verified against the 20260723 selfie monolith). This processor reads
# $ms.ToArray() (documented-valid after close) and emits the real ratio.
# Golden comparison must treat compression_ratio as a known delta.
#
# ISS-load-safe: no #Requires, no Set-StrictMode, no outer function wrapper,
# param contract positional (Item, Config).
#
# Processor self-documentation (no runtime enforcement in this file):
#     - Intended Colonel IssPreset floor: Core
#     - Supported RunMode usage: ApplyAll, KeyMatch
#     - Required IssModules: none
#
# Config: reserved; no keys honored yet. Candidates (unimplemented): metric
# group selection, honest-CR line lengths.
param($Item, $Config)

# Copy-on-enrich: clone ALL input properties (identity contract — never
# mutate the caller's reference object).
$result = [PSCustomObject]@{}
foreach ($p in $Item.PSObject.Properties)
{
    $result | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value
}

# No-Content contract: pass through unenriched.
if ($null -eq $result.PSObject.Properties['Content'] -or $result.Content -isnot [string])
{
    return $result
}

$content = [string]$result.Content

# ── Counts ───────────────────────────────────────────────────────────────
$charCount = if ($content) { $content.Length } else { 0 }
$wordCount = if ($content) { ($content -split '\s+').Count } else { 0 }
$punctCount = if ($content) { [regex]::Matches($content, '\p{P}').Count } else { 0 }

# ── Shannon entropy (per character) + unique chars ───────────────────────
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

# ── Compression ratio (Kolmogorov complexity proxy; >100 chars only) ─────
$compressionRatio = 1.0
if ($content -and $charCount -gt 100)
{
    try
    {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($content)
        $ms = [System.IO.MemoryStream]::new()
        $gz = [System.IO.Compression.GZipStream]::new($ms, [System.IO.Compression.CompressionMode]::Compress)
        $gz.Write($bytes, 0, $bytes.Length)
        $gz.Close()   # flushes AND disposes $ms — Length is unreadable after this
        $compressionRatio = [Math]::Round($ms.ToArray().Length / $bytes.Length, 4)
    }
    catch { }
}

# ── Whitespace ratio ──────────────────────────────────────────────────────
$whitespaceRatio = 0.0
if ($content -and $charCount -gt 0)
{
    $whitespaceCount = [regex]::Matches($content, '\s').Count
    $whitespaceRatio = [Math]::Round($whitespaceCount / $charCount, 4)
}

# ── Line length statistics ────────────────────────────────────────────────
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

$result | Add-Member -NotePropertyName Attributes -NotePropertyValue ([PSCustomObject]@{
        CharCount        = $charCount
        WordCount        = $wordCount
        PunctuationCount = $punctCount
        UniqueChars      = $uniqueChars
        Entropy          = [Math]::Round($entropy, 4)
        CompressionRatio = $compressionRatio
        WhitespaceRatio  = $whitespaceRatio
        LineStats        = $lineStats
    })

return $result
