# rs.js.strip.ps1

```powershell
<#
.SYNOPSIS
    Regex-based JavaScript comment-stripping post-processor.

.DESCRIPTION
    Classifies JS comment tokens into the shared ontology kinds and strips the
    requested kinds based on the Config.Operations array.

    Length-preserving mask lens: string / template / regex-literal interiors
    are overwritten with U+0001 (newlines kept) so the comment regexes cannot
    see them; spans are offsets into the original and reconstruction never
    emits mask tokens. Template interpolations are masked with the template
    (comments inside ${} are under-stripped). Unclosed quotes mask to EOL
    (templates to EOF) — under-strip, the safe direction.

    Shebang (`#!/usr/bin/env node`) is not `//` syntax and is left untouched.

    Behavior note: line endings are normalized CRLF/CR → LF as a side effect
    before span analysis (offsets require a stable newline basis).

    ISS-load-safe: no #Requires, top-level param contract.
      - Item contract:  harmonized content mutator (consolidation 6d)
      - Position class: content mutator
      - Intended Colonel IssPreset floor: Core
      - Required IssModules: none

.COMMENT KINDS
    BlockComment      /* ... */ on own line(s), not /**                        (default: strip)
    InteriorComment   /* ... */ between non-comment chars on a code line       (default: keep)
    DocString         /** ... */ JSDoc (not /**/)                              (default: strip)
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
    Known limitations: regex-vs-division heuristic (lookbehind on punct/space);
    JSX text nodes are not string literals; unclosed templates.
#>
```
