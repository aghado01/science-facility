# rs.tex.strip.ps1

```powershell
<#
.SYNOPSIS
    Regex-based TeX and LaTeX comment-stripping post-processor.

.DESCRIPTION
    Classifies TeX and LaTeX comments into the shared ontology kinds and strips
    the requested kinds based on the Config.Operations array.

    Length-preserving mask lens: escaped \% tokens, verbatim environments
    (\begin{verbatim}, lstlisting, minted, filecontents), inline verbatim (\verb,
    \lstinline), and URL commands (\url, \path, \nolinkurl) are masked with U+0001
    (newlines kept) so % regexes cannot see them. Spans apply to the original
    text; the output payload never contains mask tokens.

    FrontMatter, never stripped:
      - Line 1 shebang `#!`
      - Header magic comments on lines 1..5:
        `% !TeX ...`, `% !TEX ...`, `% !BIB ...`, `% -*- mode: ... -*-`, `%&<format>`

    Whitespace Suppression Policy:
      - Trailing `%` at end of line (e.g. `\foo{%`) suppresses space tokens created by
        newlines in TeX. When Config.PreserveWhitespaceSuppression is true (default),
        pure trailing `%` is preserved. When inline comments with explanatory text are
        attached directly to code (`\foo{% comment`), only the comment text is stripped,
        leaving the `%` token intact to preserve whitespace suppression.

    Behavior note: line endings are normalized CRLF/CR → LF as a side effect
    before span analysis (offsets require a stable newline basis).

    ISS-load-safe: no #Requires, top-level param contract.
      - Item contract:  harmonized content mutator (consolidation 6d)
      - Position class: content mutator
      - Intended Colonel IssPreset floor: Core
      - Required IssModules: none

.COMMENT KINDS
    FrontMatter       Line 1 shebang `#!` or lines 1..5 magic comments         (never strip)
    BlockComment      \begin{comment} ... \end{comment}                        (default: strip)
    CommentBlock      Contiguous run of 2+ standalone % lines                  (default: strip)
    LineComment       Standalone % line (no code preceding it on that line)    (default: strip)
    InlineComment     % trailing on a code line                                (default: keep)

.PARAMETER Item
    String, hashtable, or pscustomobject. Recognised keys: Text, Path, Id.

.PARAMETER Config
    Hashtable with optional keys:
      Operations                    [string[]] opt-in strip list; default: all four structural kinds (inline kept)
                                    Valid values: 'block-comments','doc-strings','comment-blocks','line-comments','inline-comments'
      PreserveWhitespaceSuppression [bool] default $true — preserve trailing `%` whitespace suppression tokens.
      IncludeMeta                   [bool] default $true — attach the `Processing` record.

.NOTES
    Processing element (harmonized mutator metadata, 6d):
      An ordered array on the bag; each mutator invocation APPENDS @{ Processor; Implementation; Operations }.
#>
```
