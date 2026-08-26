# rs-indent.ps1

```powershell
<#
.SYNOPSIS
    RS-scoped indentation normalizer.

.DESCRIPTION
    Normalizes leading-whitespace indentation in source code files via a small
    set of independently selectable ops applied in a fixed internal order.

    ISS-load-safe: no #Requires, top-level param contract.
      - Item contract:  harmonized content mutator (consolidation 6d)
      - Position class: content mutator
      - Intended Colonel IssPreset floor: Core
      - Required IssModules: none

.NOTES
    Config shape:
      Operations: string[]  no defaults; processor is wholesale opt-in
      IncludeMeta: bool     default true — attach the `Processing` record
      TargetUnit:  int      spaces per indent level; default 2

    Processing element (harmonized mutator metadata, 6d):
      An ordered array on the bag; each mutator invocation APPENDS
        @{ Processor; Operations; Skipped }

    Op surface:
      strip-common    Subtract minimum leading-space depth from all non-blank lines
      detab           Single O(n) sweep: extract leading \s+, expand tabs to TargetUnit spaces
      min-indent      GCD-infer file's indent unit, rescale uniformly to TargetUnit (auto-requires detab)
      tabify          Convert leading space runs to tabs at TargetUnit width (auto-requires detab)

    Internal execution order (fixed):
      strip-common → detab → min-indent → tabify

    Contraindications:
      Prose/markup formats are skipped (.md, .txt, .rst, .html, .xml, .json, .yaml, .toml, .csv).
#>
```
