# rs.ts.strip.ps1

```powershell
<#
.SYNOPSIS
    Regex-based TypeScript comment-stripping post-processor.

.DESCRIPTION
    Same length-preserving mask lens as rs.js.strip.ps1, plus FrontMatter
    protection for triple-slash compiler directives:

        /// <reference ... />
        /// <amd-module ... />
        /// <amd-dependency ... />
        /// <ts-... />

    Those lines are language-recognized (the TS compiler reads them) and are
    never stripped. Other `///` lines classify as ordinary line comments.
    `.d.ts` files stamp Extension `.ts` at crawl; they take this route.

    ISS-load-safe: no #Requires, top-level param contract.
      - Item contract:  harmonized content mutator (consolidation 6d)
      - Position class: content mutator
      - Intended Colonel IssPreset floor: Core
      - Required IssModules: none

.COMMENT KINDS
    FrontMatter       /// <reference|amd-|ts-...> compiler directives          (never strip)
    BlockComment      /* ... */ on own line(s), not /**                        (default: strip)
    InteriorComment   /* ... */ between non-comment chars on a code line       (default: keep)
    DocString         /** ... */ TSDoc/JSDoc (not /**/)                        (default: strip)
    CommentBlock      Contiguous run of 2+ standalone // lines                 (default: strip)
    LineComment       Standalone // line (no code preceding it on that line)   (default: strip)
    InlineComment     // trailing on a code line                               (default: keep)

.PARAMETER Item
    String, hashtable, or pscustomobject. Recognised keys: Text, Path, Id.

.PARAMETER Config
    Hashtable with optional keys:
      Operations  [string[]] opt-in strip list; default: all four structural kinds (interior + inline kept)
                  Valid values: 'block-comments','interior-comments','doc-strings','comment-blocks','line-comments','inline-comments'
      IncludeMeta [bool] default $true — attach the `Processing` record.

.NOTES
    Processing element (harmonized mutator metadata, 6d):
      An ordered array on the bag; each mutator invocation APPENDS @{ Processor; Implementation; Operations }.
    Same scan limitations as rs.js.strip (regex-vs-division, JSX/TSX text, unclosed templates).
#>
```
