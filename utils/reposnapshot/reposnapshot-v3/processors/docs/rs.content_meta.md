# rs-content_meta.ps1

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
```
