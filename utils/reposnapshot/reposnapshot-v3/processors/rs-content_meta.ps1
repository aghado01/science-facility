# rs-content_meta.ps1 — ISS-loadable processor body   (né rs-attributes, 2026-08-17)
# Contract: param($Item, $Config)  →  enriched $Item
#
# Per-document metadata processor: attaches a ContentMeta object of pure
# string statistics over $Item.Content — the in-memory source of the psr
# `content_meta` block (contracts/container.spec.jsonc maps ContentMeta.* → wire
# sub-fields; which are emitted is run configuration). One concept, three
# spellings by convention: wire `content_meta` (snake), in-memory `ContentMeta`
# (Pascal), processor `rs-content_meta` (after the wire block). Element renamed
# from `Attributes` 2026-08-17. Language-agnostic BY POSITION, not by cleverness — the
# metrics are content-form statistics with zero language knowledge; what
# makes them meaningful is where this step sits.
#
# POSITIONAL CONTRACT (profile invariant — enforced by profile construction,
# not by this processor, which is position-ignorant):
#   - Enrich-only TAIL step: place after ALL content-mutating steps of any
#     kind (language-specific strippers AND generic transforms like
#     rs-whitespace). Nothing needs to run after it; order relative to other
#     enrich-only tail steps is immaterial.
#   - ContentMeta describes the PROCESSED content — the payload as it moves
#     forward in the pipeline — deliberately NOT the on-disk original.
#     Provenance split on the descriptor: SizeBytes (crawler identity) is
#     the on-disk stat; ContentMeta.* are processed-content stats.
#   - BYTE SEMANTICS (user, 2026-07-28): the metrics deal in SpanBytes — the
#     UTF-8 byte span of the processed content — never SizeBytes. The
#     enrichment describes payload contents for strategic reader navigation;
#     on-disk size is filesystem bookkeeping, irrelevant to the reader (its
#     one consumer is pre-read eligibility in the ignore stage). Same
#     semantics family as the tree manifest's byte spans and the precise-
#     span read tooling. (LTS conflated these: its attributes.size_bytes was
#     the on-disk size.) The rendered row 'length' field is a third value —
#     the writer-side span of the ENCODED content — computed at render time.
#   - CANONICAL UTF-8 (user, 2026-08-09): encoding and codec are SERIALIZER
#     declarations (assemble-design §Payload doctrine; ledger #16/#17). This
#     processor runs three stages upstream of that decision, and content in
#     memory is a UTF-16 .NET string with no byte span until an encoding is
#     picked — so every byte figure here (SpanBytes, and the CompressionRatio
#     input) is measured in UTF-8 BY CONVENTION, deliberately invariant to
#     whatever the serializer later emits. That invariance is the point:
#     attributes exist for ranking and cross-run comparison, and a metric
#     that moves when a writer knob moves cannot do that job. SpanBytes is
#     NOT a statement about the artifact's encoding, and no downstream
#     consumer may publish it where a reader will spend it as an offset or an
#     exact encoded length. It IS the right input for ranking and skip
#     decisions. (It is NOT the shard-packing input any more — superseded
#     2026-08-15/16, ledger #39: packing measures rows exactly via the
#     container's Measure-Row; the wire `content_bytes` is that measured span.
#     SpanBytes is not a content_meta sub-field for the same reason: one fact,
#     one column.)
#
# NO-CONTENT CONTRACT: items without a usable Content property pass through
# unchanged (no ContentMeta attached). ContentMeta is optional on IR entries
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
# ISS-load-safe: no #Requires, no Set-StrictMode, top-level param contract
# (interior helpers permitted per colonel AST validation).
#
# Processor self-documentation (no runtime enforcement in this file):
#     - Item contract:  descriptor (Content; open-bag copy-on-enrich)
#     - Position class: enrich-only tail (after ALL content mutators)
#     - Intended Colonel IssPreset floor: Core
#     - Required IssModules: none
#
# Config: reserved; no keys honored yet. Candidates (unimplemented): metric
# group selection, honest-CR line lengths.
param($Item, $Config)

# No-Content contract: pass through unenriched. Checked on the INPUT, before any
# clone — a bag with nothing to measure comes back exactly as it arrived.
if ($null -eq $Item.PSObject.Properties['Content'] -or $Item.Content -isnot [string])
{
    return $Item
}

$content = [string]$Item.Content

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

# Copy-on-enrich via the shared Copy-Bag helper (processors/bag-helpers.ps1):
# clone ALL input properties, then attach. Never mutates the caller's reference.
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
