# rs.content_meta.ps1

```powershell
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
      This processor gzips with CompressionLevel.Fastest, leaveOpen, and emits
      compressed Length / UTF-8 length (Kolmogorov proxy; not a pinned ratio).

    IMPLEMENTATION:
      Counts, entropy, whitespace, and line stats are one C# pass compiled once
      per AppDomain via Roslyn APIs (type-exists guard; never per file; no
      Add-Type cmdlet, so Bare ISS can compile). UTF-8 GetBytes is computed once
      and reused for SpanBytes and the gzip proxy.

    ISS-load-safe: no #Requires, no Set-StrictMode, top-level param contract.
      - Item contract:  descriptor (Content; open-bag copy-on-enrich)
      - Position class: enrich-only tail (after ALL content mutators)
      - Intended Colonel IssPreset floor: Bare
      - Required IssModules: none

.PARAMETER Item
    String, hashtable, or pscustomobject descriptor carrying Content.
    CONFIG:
      Fields: string[]  in-memory metric names to compute and attach.
        Default (processors/configs/rs.content_meta.json): CharCount, WordCount,
        WhitespaceRatio, Entropy, LineStats — the admitted default-on wire set.
        SpanBytes is always attached when ContentMeta is (not a Fields toggle;
        not a wire sub-field). Empty Fields: no ContentMeta (downstream omits
        the wire block). Unknown name throws.
        Known: CharCount, WordCount, PunctuationCount, UniqueChars, Entropy,
        CompressionRatio, WhitespaceRatio, LineStats.

    WIRE:
      The content_meta column is written only when this processor ran
      (Header.Elements.ContentMeta present). Sub-fields on the wire are
      Fields ∩ the admitted set in container.spec.jsonc. Columns naming
      content_meta without this processor is omitted, not rendered empty.

.PARAMETER Config
    Hashtable. Fields: string[] of in-memory metric names (see CONFIG).
#>
```
