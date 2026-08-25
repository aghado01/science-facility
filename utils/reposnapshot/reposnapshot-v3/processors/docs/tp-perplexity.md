# tp-perplexity.ps1

```powershell
<#
.SYNOPSIS
    Perplexity thread → exchange envelopes.

.DESCRIPTION
    Parses a Perplexity-style markdown thread export and returns one envelope
    per exchange: { Index, Prompt, Reply, Citations[] }.

    Pipeline runs as a sequence of regex masking passes followed by a
    context-disambiguated split on the `---` terminus that Perplexity emits
    after each citation footer block.

    ISS-load-safe: no #Requires, no Set-StrictMode, top-level param contract.
      - Item contract:  dual-key input (Text | Content) → envelope output
      - Position class: segmenting parser (thread track)
      - Intended Colonel IssPreset floor: Core
      - Required IssModules: none

.PARAMETER Item
    String, hashtable, or pscustomobject. Recognised keys: Text, Content, Path, Id.
.PARAMETER Config
    Hashtable with optional keys:
      IncludeMeta      [bool] default true; bare-return is the Exchanges array
      StripInlineCites [bool] default false; true removes [^d] clusters from Reply prose
#>
```
