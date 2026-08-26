# rs-whitespace.ps1

```powershell
<#
.SYNOPSIS
    Code-lane whitespace normalizer (line endings, trailing whitespace, blank runs).

.DESCRIPTION
    Runs EARLY in the code-lane chain; its `lf` op provides LF-only content for
    downstream stages (strippers, rs-indent, rs-content_meta, container codec).

    ISS-load-safe: no #Requires, top-level param contract.
      - Item contract:  harmonized content mutator (consolidation 6d)
      - Position class: content mutator
      - Intended Colonel IssPreset floor: Core
      - Required IssModules: none

    Operations is a set the caller subsets; implementation owns application sequence:
      lf → nfc → strip-zwsp → strip-wj → strip-zwnbsp → trim-trailing →
      trim-inner → max-blank-1 → trim-doc → ensure-final-lf → pad-breaks

.PARAMETER Item
    String, hashtable, or pscustomobject.
.PARAMETER Config
    Hashtable with optional keys:
      Operations  [string[]] opt-in operation list; default: all except trim-inner
      IncludeMeta [bool] default $true — attach the `Processing` record.

.NOTES
    Processing element (harmonized mutator metadata, 6d):
      An ordered array on the bag; each mutator invocation APPENDS
        @{ Processor; Operations; Skipped? }
#>
```
