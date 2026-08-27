# rs.py.strip.ps1

```powershell
<#
.SYNOPSIS
    Regex-based Python comment-stripping post-processor.

.DESCRIPTION
    Classifies Python comments and statement-position triple-quoted strings
    into the shared ontology kinds and strips the requested kinds based on
    the Config.Operations array.

    Length-preserving mask lens: '...', "...", '''...''', and """..."""
    (including r/f/b/u prefixes) are overwritten with U+0001 (newlines kept)
    so `#` regexes cannot see them. Statement-position triples (only indent
    before on the line) are classified as DocString from the original, then
    masked so `#` inside the docstring does not fire. Spans apply to the
    original; the payload never contains mask tokens.

    FrontMatter, never stripped:
      - line-1 shebang `#!`
      - PEP 263 encoding cookies on lines 1–2 (`coding[:=]`)

    Python has no interior block-comment token. `interior-comments` is a no-op.
    Standalone triple-quoted statements (orphans not attached to def/class)
    classify as DocString, not a separate BlockComment — `block-comments` is
    accepted as an alias so the default op list is not a dead letter.

    Behavior note: line endings are normalized CRLF/CR → LF as a side effect
    before span analysis (offsets require a stable newline basis).

    ISS-load-safe: no #Requires, top-level param contract.
      - Item contract:  harmonized content mutator (consolidation 6d)
      - Position class: content mutator
      - Intended Colonel IssPreset floor: Core
      - Required IssModules: none

.COMMENT KINDS
    FrontMatter       shebang; PEP 263 coding cookie                           (never strip)
    DocString         statement-position """...""" / '''...'''                 (default: strip)
    CommentBlock      Contiguous run of 2+ standalone # lines                  (default: strip)
    LineComment       Standalone # line                                        (default: strip)
    InlineComment     # trailing on a code line                                (default: keep)

.PARAMETER Item
    String, hashtable, or pscustomobject. Recognised keys: Text, Path, Id.

.PARAMETER Config
    Hashtable with optional keys:
      Operations  [string[]] opt-in strip list; default: all four structural kinds (inline kept)
                  Valid values: 'block-comments','doc-strings','comment-blocks','line-comments','inline-comments'
      IncludeMeta [bool] default $true — attach the `Processing` record.

.NOTES
    Processing element (harmonized mutator metadata, 6d):
      An ordered array on the bag; each mutator invocation APPENDS @{ Processor; Implementation; Operations }.
    Known limitations: unclosed triples left in place (under-strip); PEP 498
    nested quotes in f-expressions (3.12+) may confuse the string alternative.
#>
```
