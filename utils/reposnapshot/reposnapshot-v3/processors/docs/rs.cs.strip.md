# rs.cs.strip.ps1

```powershell
<#
.SYNOPSIS
    Regex-based C# comment-stripping post-processor.

.DESCRIPTION
    Classifies C# comment tokens into six kinds and strips the requested kinds
    based on the Config.Operations array.

    Unlike rs.ps.strip.ps1, this processor is regex-only — no native C# AST is
    available from PowerShell. Known limitation: // and /* tokens that appear
    inside string literals (including verbatim @"..." strings) may be incorrectly
    treated as comments.

    Behavior note: line endings are normalized CRLF/CR → LF as a side effect
    before span analysis (offsets require a stable newline basis).

    ISS-load-safe: no #Requires, top-level param contract.
      - Item contract:  harmonized content mutator (consolidation 6d)
      - Position class: content mutator
      - Intended Colonel IssPreset floor: Core
      - Required IssModules: none

.COMMENT KINDS
    BlockComment      /* ... */ on own line(s), no surrounding code            (default: strip)
    InteriorComment   /* ... */ between non-comment chars on a code line       (default: keep)
    DocString         /// triple-slash XML doc comment line                    (default: strip)
    CommentBlock      Contiguous run of 2+ standalone // lines                (default: strip)
    LineComment       Standalone // line (no code preceding it on that line)  (default: strip)
    InlineComment     // trailing on a code line (code precedes on same line) (default: keep)

.PARAMETER Item
    String, hashtable, or pscustomobject. Recognised keys: Text, Path, Id.

.PARAMETER Config
    Hashtable with optional keys:
      Operations  [string[]] opt-in strip list; default: all four structural kinds (interior + inline kept)
                  Valid values: 'block-comments','interior-comments','doc-strings','comment-blocks','line-comments','inline-comments'
      IncludeMeta [bool] default $true — attach the `Processing` record.

.NOTES
    Processing element (harmonized mutator metadata, 6d):
      An ordered array on the bag; each mutator invocation APPENDS @{ Processor; Operations }.
#>
```
