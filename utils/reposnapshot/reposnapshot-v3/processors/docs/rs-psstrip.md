# rs-psstrip.ps1

```powershell
<#
.SYNOPSIS
    AST-based PowerShell comment-stripping post-processor.

.DESCRIPTION
    Parses PowerShell source text with the native PS parser, classifies every comment
    token into one of six kinds, and strips requested kinds based on Config.Operations.
    FrontMatter is a first-class named kind with no strip op — never strippable.

    Partition at the parse boundary (psdig ast-primitives lineage): semantic
    frontmatter (#Requires directives, line-1 shebang) lexes as Comment tokens but is
    promoted into Derived FrontMatter objects by _SplitCommentPopulation.

    ISS-load-safe: no #Requires, top-level param contract.
      - Item contract:  harmonized content mutator (consolidation 6d)
      - Position class: content mutator
      - Intended Colonel IssPreset floor: Core
      - Required IssModules: none

.COMMENT KINDS
    FrontMatter    #Requires directive, line-1 shebang — Derived kind     (NEVER strippable)
    BlockComment   angle-hash block  outside function/class body          (default: strip)
    DocString      angle-hash block  inside  function/class body          (default: strip)
    CommentBlock   Contiguous run of 2+ standalone # lines               (default: strip)
    LineComment    Standalone # line (no code preceding it on that line) (default: strip)
    InlineComment  # token with preceding code on the same line          (default: keep)

.PARAMETER Item
    String, hashtable, or pscustomobject. Content key: Content (preferred) or Text.

.PARAMETER Config
    Hashtable with optional keys:
      Operations  [string[]] opt-in strip list; default: all four structural kinds (inline kept)
                  Valid values: 'block-comments','doc-strings','comment-blocks','line-comments','inline-comments'
      IncludeMeta [bool] default $true — attach the `Processing` record.
      MaskHereStrings    [bool] default $true — fallback route: mask here-strings from regexes.
      ForceRegexFallback [bool] default $false — force pseudo-AST regex route.

.NOTES
    Processing element (harmonized mutator metadata, 6d):
      An ordered array on the bag; each mutator invocation APPENDS
        @{ Processor; Operations; ParseErrors?; FallbackMode? }
#>
```
