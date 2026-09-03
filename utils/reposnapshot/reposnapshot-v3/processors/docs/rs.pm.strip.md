# rs.pm.strip.ps1

```powershell
<#
.SYNOPSIS
    Regex-based Perl comment- and POD-stripping post-processor.

.DESCRIPTION
    Classifies Perl comments and POD (Plain Old Documentation) blocks into the
    shared ontology kinds and strips the requested kinds based on the
    Config.Operations array.

    Length-preserving mask lens: strings ('...', "...", `...`), quote-like
    operators (qw, qq, q, qr, qx), regex and substitution literals, heredoc
    bodies, __DATA__ sections, and $# array-length sigils are overwritten with
    U+0001 (newlines kept) so `#` and POD regexes cannot see them. Spans apply to
    the original text; the output payload never contains mask tokens.

    FrontMatter, never stripped:
      - Line 1 shebang `#!`

    POD Documentation:
      - Multi-line POD blocks starting with `=[a-zA-Z]` at column 0 and ending with
        `=cut` (or EOF if unclosed) are classified under both `doc-strings` and
        `block-comments`, matching Python's docstring alias convention.

    Behavior note: line endings are normalized CRLF/CR → LF as a side effect
    before span analysis (offsets require a stable newline basis).

    ISS-load-safe: no #Requires, top-level param contract.
      - Item contract:  harmonized content mutator (consolidation 6d)
      - Position class: content mutator
      - Intended Colonel IssPreset floor: Core
      - Required IssModules: none

.COMMENT KINDS
    FrontMatter       Line 1 shebang `#!...`                                   (never strip)
    DocString / Block POD block `=head1 ... =cut`                              (default: strip)
    CommentBlock      Contiguous run of 2+ standalone # lines                  (default: strip)
    LineComment       Standalone # line (no code preceding it on that line)    (default: strip)
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
#>
```
