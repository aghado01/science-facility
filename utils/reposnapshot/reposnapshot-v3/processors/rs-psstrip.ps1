<#
.SYNOPSIS
    AST-based PowerShell comment-stripping post-processor.

.DESCRIPTION
    Parses PowerShell source text with the native PS parser, classifies every comment
    token into one of six kinds, and strips the requested kinds based on the Config.Operations array.
    FrontMatter is a first-class named kind with no strip op — never strippable.

    Partition at the parse boundary (psdig ast-primitives lineage): semantic
    frontmatter (#Requires directives, line-1 shebang) lexes as Comment tokens but is
    promoted OUT of the native comment population into Derived FrontMatter objects by
    _SplitCommentPopulation — the ONE site where language knowledge converts a text
    pattern into a type. Downstream classification consumes the native population
    with zero frontmatter text predicates; FrontMatter joins the classified list as a
    named kind (reportable, run-splitting, never stripped).

    ISS-load-safe: no #Requires, top-level param contract. Carries the
    interior helper _SplitCommentPopulation — permitted per colonel's AST
    validation (top-level param block is the contract; interior helpers are
    legitimate).

    Processor self-documentation (no runtime enforcement in this file):
        - Item contract:  harmonized content mutator (consolidation 6d) —
          reads Content (descriptor contract) else Text (tp-era), mutates it,
          and writes the SAME key back on a CLONE of the incoming bag; every
          other property passes through untouched. Copy-on-mutate: the mutator
          sibling of file-read's copy-on-enrich. Track-agnostic — the
          processor never renames, invents, or edits a key it did not read.
          Bare string in → bare string out. Bag carrying neither key →
          returned untouched. Per-invocation metadata appends one record to
          the `Processing` element (see .NOTES).
        - Position class: content mutator
        - Intended Colonel IssPreset floor: Core (uses pipeline cmdlets;
          Bare is insufficient)
        - Required IssModules: none

.NOTES
        Config shape:
            Operations: string[] (opt-in strip list; default strips all structural kinds, keeps inline)
            IncludeMeta: bool (default true)

        Processing element (harmonized mutator metadata, 6d):
            An ordered array on the bag; each mutator invocation APPENDS
                @{ Processor; Operations; ParseErrors?; FallbackMode? }
            ParseErrors / FallbackMode appear only when they occurred — the
            same conditional-emission rule the tp-era envelope used, now on the
            record instead of on a replacement bag. Chain order = array order.

.COMMENT KINDS
    FrontMatter    #Requires directive, line-1 shebang — Derived kind     (NEVER strippable; no op exists)
    BlockComment   angle-hash block  outside function/class body          (default: strip)
    DocString      angle-hash block  inside  function/class body          (default: strip)
    CommentBlock   Contiguous run of 2+ standalone # lines               (default: strip)
    LineComment    Standalone # line (no code preceding it on that line) (default: strip)
    InlineComment  # token with preceding code on the same line          (default: keep)

    FrontMatter splits LineComment runs as stated policy: a #Requires between
    comment lines closes the run on each side (each neighbor classifies on its
    own — a lone neighbor stays LineComment, never folds into a CommentBlock
    across the directive).

.PARAMETER Item
    String, hashtable, or pscustomobject.  Content key: Content (preferred) or Text.

.PARAMETER Config
    Hashtable with optional keys:
      Operations  [string[]] opt-in strip list; default: all four structural kinds (inline kept)
                  Valid values: 'block-comments','doc-strings','comment-blocks','line-comments','inline-comments'
      IncludeMeta [bool] default $true  — attach the `Processing` record. $false
                  returns the mutated bag WITHOUT the record; it never collapses a
                  bag to a bare string (that was the tp-era envelope behavior 6d
                  removed). Bare-string input is unaffected either way.
      MaskHereStrings    [bool] default $true — fallback route only: here-strings are code
                  payload, not comments; they are sentinel-masked before the pseudo-AST
                  regexes run and restored afterward. A broken opener masks through a
                  lenient (indented) closer, else to EOF. Set $false to override and let
                  the fallback regexes process here-string interiors.
      ForceRegexFallback [bool] default $false — force the pseudo-AST regex route.

.ROUTING
    Tolerance-first: the token walk runs even when parse errors exist (the PS tokenizer
    is error-recovering; ParseErrors are reported on the envelope either way). The regex
    pseudo-AST fallback engages only on missing-string-terminator breakage (broken /
    unterminated here-string swallowing the tail) or via ForceRegexFallback.
    FallbackMode='regex' appears on the envelope only when the fallback actually ran.
#>
param(
    [Parameter(Position = 0)]
    [object]$Item,

    [Parameter(Position = 1)]
    [hashtable]$Config = @{}
)

# ---------------------------------------------------------------------------
# Helper: partition the comment-token population at the parse boundary.
# Pure function (closure rule: parameters only — runs inside ISS runspaces).
# Interior helper functions are permitted by colonel's AST validation.
#
# This is the ONE site where language knowledge converts a text pattern into
# a TYPE (psdig ast-primitives lineage — partition, not guard): #Requires
# directives and a line-1 shebang lex as TokenKind.Comment with zero semantic
# discrimination; here they are promoted into Derived FrontMatter objects
# (Token retained; ScriptRequirements metadata spliced from the AST) and are
# structurally absent from the Native population that classification
# consumes. No downstream pass carries a frontmatter text predicate.
# ---------------------------------------------------------------------------
function _SplitCommentPopulation
{
    param(
        [object[]]$Tokens,
        [System.Management.Automation.Language.Ast]$Ast
    )

    $native = [System.Collections.Generic.List[object]]::new()
    $derived = [System.Collections.Generic.List[pscustomobject]]::new()
    $ck = [System.Management.Automation.Language.TokenKind]::Comment
    $reqs = $Ast.ScriptRequirements

    foreach ($tok in $Tokens)
    {
        if ($tok.Kind -ne $ck) { continue }

        if ($tok.Text -match '^#requires\b')
        {
            $derived.Add([pscustomobject]@{
                    Kind                = 'FrontMatter'
                    SubKind             = 'ScriptRequirements'
                    Token               = $tok
                    RequiredPSVersion   = if ($null -ne $reqs) { $reqs.RequiredPSVersion } else { $null }
                    RequiredModules     = if ($null -ne $reqs) { $reqs.RequiredModules } else { $null }
                    RequiredPSEditions  = if ($null -ne $reqs) { $reqs.RequiredPSEditions } else { $null }
                    IsElevationRequired = if ($null -ne $reqs) { [bool]$reqs.IsElevationRequired } else { $false }
                })
        }
        elseif ($tok.Extent.StartOffset -eq 0 -and $tok.Text.StartsWith('#!'))
        {
            $derived.Add([pscustomobject]@{
                    Kind    = 'FrontMatter'
                    SubKind = 'Shebang'
                    Token   = $tok
                })
        }
        else
        {
            $native.Add($tok)
        }
    }

    return [pscustomobject]@{ Native = $native; Derived = $derived }
}

# ---------------------------------------------------------------------------
# Config resolution
# ---------------------------------------------------------------------------
$ops = if ($Config.ContainsKey('Operations')) { @($Config['Operations']) } else { @('block-comments', 'doc-strings', 'comment-blocks', 'line-comments') }
$includeMeta = if ($null -ne $Config['IncludeMeta']) { [bool]$Config['IncludeMeta'] } else { $true }

# ---------------------------------------------------------------------------
# Content-key resolution — harmonized content-mutator contract (6d)
#
# Read Content (descriptor contract) else Text (tp-era); the key that was read
# is the key written back, which is what keeps this processor track-agnostic.
# A bag carrying NEITHER key is returned untouched (mirrors rs-content_meta'
# no-Content contract): a mutator with nothing to mutate must not fabricate an
# empty payload — assemble routes empty content to Diagnostics and splits
# EmptyFile from EmptiedByProcessing, so a phantom '' would forge an entry.
# Content wins when both keys exist; Text is then left exactly as found (never
# edit a key you did not read) — no current producer emits both.
# ---------------------------------------------------------------------------
$bc = Resolve-BagContent -Item $Item
if ($null -eq $bc) { return $Item }

$text = $bc.Text

# ---------------------------------------------------------------------------
# Parse
# ---------------------------------------------------------------------------
$tokensRef = [ref]$null
$errorsRef = [ref]$null
$ast = [System.Management.Automation.Language.Parser]::ParseInput($text, $tokensRef, $errorsRef)
$tokens = @($tokensRef.Value)
$errors = @($errorsRef.Value)

$parseErrors = $null
if ($errors.Count -gt 0)
{
    $msgs = [System.Collections.Generic.List[string]]::new()
    foreach ($e in $errors) { $msgs.Add($e.Message) }
    $parseErrors = @($msgs)
}

# ---------------------------------------------------------------------------
# Route selection — tolerance-first: the tokenizer is error-recovering, so the
# token walk runs even when parse errors exist (broken code must still strip;
# ParseErrors are reported either way). The regex pseudo-AST fallback engages
# only when:
#   - a missing string terminator broke tokenization (a broken/unterminated
#     here-string swallows the file tail as one string token; the pseudo-AST
#     route can recover stripping beyond the breakage), or
#   - Config.ForceRegexFallback is set (explicit override / testing).
# ---------------------------------------------------------------------------
$useFallback = $false
if ([bool]$Config['ForceRegexFallback']) { $useFallback = $true }
elseif ($errors.Count -gt 0)
{
    # TerminatorExpectedAtEndOfString  — unterminated string/here-string (no closer)
    # WhitespaceBeforeHereStringFooter — broken here-string (indented closer)
    # Both swallow the file tail into one string token; the masked pseudo-AST
    # route recovers stripping beyond the breakage.
    foreach ($e in $errors)
    {
        if ($e.ErrorId -in @('TerminatorExpectedAtEndOfString', 'WhitespaceBeforeHereStringFooter'))
        {
            $useFallback = $true
            break
        }
    }
}

$hsStore = [System.Collections.Generic.List[string]]::new()
$HS_OPEN = [char]0xE000
$HS_CLOSE = [char]0xE001

if ($useFallback)
{
    # ---------------------------------------------------------------------------
    # Regex pseudo-AST fallback — structural regex identifies comment spans
    # directly.  DocStrings cannot be distinguished from BlockComments without
    # scope extents, so both are treated as BlockComment (stripped when
    # 'block-comments' OR 'doc-strings' op is active).
    # CommentBlock heuristic: 2+ consecutive standalone-# lines.
    # InlineComment heuristic: # preceded by non-whitespace on the same line.
    # ---------------------------------------------------------------------------

    # Here-string masking (Config.MaskHereStrings, default $true): here-strings
    # are code payload, not comments — interiors must pass through the fallback
    # regexes untouched. Terminated here-strings mask exactly; a broken opener
    # masks through a lenient (indented) closer when one exists, else to EOF —
    # recovering the file's intent rather than its accidental tokenization.
    $maskHereStrings = if ($null -ne $Config['MaskHereStrings']) { [bool]$Config['MaskHereStrings'] } else { $true }
    if ($maskHereStrings)
    {
        $rxHs = [regex]::new('(?s)@([''"])[ \t]*\r?\n.*?\n\1@')
        $text = $rxHs.Replace($text, {
                param($m)
                $hsIdx = $hsStore.Count
                $hsStore.Add($m.Value)
                "$HS_OPEN$hsIdx$HS_CLOSE"
            })

        $hsGuard = 0
        while ($hsGuard++ -lt 100)
        {
            $mOpen = [regex]::Match($text, '@([''"])[ \t]*\r?\n')
            if (-not $mOpen.Success) { break }
            $q = $mOpen.Groups[1].Value
            $rest = $text.Substring($mOpen.Index)
            $mClose = [regex]::Match($rest, ('(?m)^[ \t]*' + $q + '@'))
            $hsEnd = if ($mClose.Success) { $mOpen.Index + $mClose.Index + $mClose.Length } else { $text.Length }
            $hsIdx = $hsStore.Count
            $hsStore.Add($text.Substring($mOpen.Index, $hsEnd - $mOpen.Index))
            $text = $text.Substring(0, $mOpen.Index) + "$HS_OPEN$hsIdx$HS_CLOSE" + $text.Substring($hsEnd)
        }
    }

    $spansToStrip = [System.Collections.Generic.List[pscustomobject]]::new()
    $stripBlock = ('block-comments' -in $ops) -or ('doc-strings' -in $ops)
    $stripCB = 'comment-blocks' -in $ops
    $stripLine = 'line-comments' -in $ops
    $stripInline = 'inline-comments' -in $ops

    # Block comments <# ... #>  (DocString / BlockComment unified)
    if ($stripBlock)
    {
        $rx = [regex]::new('(?s)<#.*?#>', 'None')
        foreach ($m in $rx.Matches($text))
        {
            $s = $m.Index
            $e = $m.Index + $m.Length
            # consume leading indent and trailing newline (same as AST path)
            $ls = $s
            while ($ls -gt 0 -and ($text[$ls - 1] -eq ' ' -or $text[$ls - 1] -eq "`t")) { $ls-- }
            if ($ls -eq 0 -or $text[$ls - 1] -eq "`n" -or $text[$ls - 1] -eq "`r") { $s = $ls }
            if ($e -lt $text.Length)
            {
                if ($text[$e] -eq "`r") { $e++; if ($e -lt $text.Length -and $text[$e] -eq "`n") { $e++ } }
                elseif ($text[$e] -eq "`n") { $e++ }
            }
            $spansToStrip.Add([pscustomobject]@{ Start = $s; End = $e })
        }
    }

    # Standalone # lines — collect all, then apply CommentBlock / LineComment logic
    if ($stripCB -or $stripLine)
    {
        # Match: optional leading whitespace, # not followed by requires, rest of line + newline
        $rxLine = [regex]::new('(?m)^([^\S\r\n]*)#(?!(?i:requires)\b)[^\r\n]*(\r?\n)?', 'None')
        # Exclude matches that are part of a <# #> block already captured above
        # (they won't overlap in well-structured PS; regex is heuristic anyway)

        # Build list of: (lineNum 1-indexed, matchIndex, matchEnd, hasCodeBefore)
        $standaloneMatches = [System.Collections.Generic.List[pscustomobject]]::new()
        $textLines = $text -split "`n"
        foreach ($m in $rxLine.Matches($text))
        {
            # Determine if there is code before the # on this line
            $lineStart = $m.Index
            $hashIdx = $m.Index + $m.Groups[1].Length   # position of the # character
            $before = $text.Substring($lineStart, $hashIdx - $lineStart)
            if ($before -match '\S') { continue }   # has code before # → InlineComment, handled below
            if ($m.Index -eq 0 -and $m.Value.StartsWith('#!')) { continue }   # line-1 shebang frontmatter

            # Compute 1-indexed line number
            $lineNum = ($text.Substring(0, $m.Index) -split "`n").Count

            $standaloneMatches.Add([pscustomobject]@{
                    LineNum = $lineNum
                    Start   = $m.Index
                    End     = $m.Index + $m.Length
                })
        }

        # Reclassify runs of 2+ consecutive lines as CommentBlock (same logic as AST path)
        $runStartI = -1
        $runEndI = -1
        $cbFlags = @($false) * $standaloneMatches.Count

        for ($i = 0; $i -lt $standaloneMatches.Count; $i++)
        {
            $cur2 = $standaloneMatches[$i]
            if ($runStartI -eq -1)
            {
                $runStartI = $i; $runEndI = $i
            }
            elseif ($cur2.LineNum -eq $standaloneMatches[$runEndI].LineNum + 1)
            {
                $runEndI = $i
            }
            else
            {
                if ($runEndI -gt $runStartI) { for ($j = $runStartI; $j -le $runEndI; $j++) { $cbFlags[$j] = $true } }
                $runStartI = $i; $runEndI = $i
            }
        }
        if ($runStartI -ne -1 -and $runEndI -gt $runStartI) { for ($j = $runStartI; $j -le $runEndI; $j++) { $cbFlags[$j] = $true } }

        for ($i = 0; $i -lt $standaloneMatches.Count; $i++)
        {
            $shouldStrip2 = if ($cbFlags[$i]) { $stripCB } else { $stripLine }
            if (-not $shouldStrip2) { continue }
            $sm = $standaloneMatches[$i]
            $ls2 = $sm.Start
            while ($ls2 -gt 0 -and ($text[$ls2 - 1] -eq ' ' -or $text[$ls2 - 1] -eq "`t")) { $ls2-- }
            $s2 = if ($ls2 -eq 0 -or $text[$ls2 - 1] -eq "`n" -or $text[$ls2 - 1] -eq "`r") { $ls2 } else { $sm.Start }
            $spansToStrip.Add([pscustomobject]@{ Start = $s2; End = $sm.End })
        }
    }

    # Inline comments — # preceded by code on the same line
    if ($stripInline)
    {
        $rxInline = [regex]::new('(?m)[ \t]*#(?!(?i:requires)\b)[^\r\n]*', 'None')
        foreach ($m in $rxInline.Matches($text))
        {
            # Verify there is non-whitespace before this match on the same line
            $lineStart = $text.LastIndexOf("`n", $m.Index)
            $lineStart = if ($lineStart -eq -1) { 0 } else { $lineStart + 1 }
            $before2 = $text.Substring($lineStart, $m.Index - $lineStart)
            if ($before2 -notmatch '\S') { continue }
            $spansToStrip.Add([pscustomobject]@{ Start = $m.Index; End = $m.Index + $m.Length })
        }
    }
}
else
{
    # ---------------------------------------------------------------------------
    # Collect function / class body extents for DocString detection
    # A BlockComment is a DocString when its character span falls inside the
    # extent of any FunctionDefinitionAst or TypeDefinitionAst.
    # ---------------------------------------------------------------------------
    $bodyExtents = [System.Collections.Generic.List[System.Management.Automation.Language.IScriptExtent]]::new()

    $bodyNodes = $ast.FindAll(
        {
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -or
            $node -is [System.Management.Automation.Language.TypeDefinitionAst]
        },
        $true
    )
    foreach ($node in $bodyNodes) { $bodyExtents.Add($node.Extent) }

    # ---------------------------------------------------------------------------
    # Select and first-pass classify comment tokens
    # ---------------------------------------------------------------------------
    # LF-split for inline detection; token line/col numbers are 1-indexed
    $lines = $text -split "`n"

    # Partition at the parse boundary (see _SplitCommentPopulation): the native
    # population feeds classification; Derived FrontMatter joins the classified
    # list below as a named kind. Zero frontmatter text predicates from here on.
    $population = _SplitCommentPopulation -Tokens $tokens -Ast $ast
    # In-place sort by start offset. Token offsets are unique, so there are no
    # ties for a stable sort to preserve.
    $population.Native.Sort(
        [System.Comparison[object]] { param($a, $b) $a.Extent.StartOffset.CompareTo($b.Extent.StartOffset) })
    $commentTokens = $population.Native

    $classified = [System.Collections.Generic.List[pscustomobject]]::new()

    foreach ($tok in $commentTokens)
    {
        $so = $tok.Extent.StartOffset
        $eo = $tok.Extent.EndOffset
        $line = $tok.Extent.StartLineNumber    # 1-indexed
        $col = $tok.Extent.StartColumnNumber  # 1-indexed

        if ($tok.Text -match '^<#')
        {
            # BlockComment or DocString — inlined extent check (no nested function: ISS-load-safe contract)
            $isInBody = $false
            foreach ($ext in $bodyExtents)
            {
                if ($so -ge $ext.StartOffset -and $eo -le $ext.EndOffset) { $isInBody = $true; break }
            }
            $kind = if ($isInBody) { 'DocString' } else { 'BlockComment' }
        }
        else
        {
            # LineComment or InlineComment — check for preceding code on the same line
            $kind = 'LineComment'
            $lineIdx = $line - 1
            if ($lineIdx -ge 0 -and $lineIdx -lt $lines.Count)
            {
                $lineText = $lines[$lineIdx]
                $beforeLen = [Math]::Min($col - 1, $lineText.Length)
                if ($beforeLen -gt 0 -and $lineText.Substring(0, $beforeLen) -match '\S')
                {
                    $kind = 'InlineComment'
                }
            }
        }

        $classified.Add([pscustomobject]@{
                Token    = $tok
                Kind     = $kind
                StartOff = $so
                EndOff   = $eo
                LineNum  = $line
            })
    }

    # ---------------------------------------------------------------------------
    # FrontMatter joins the classified list as a NAMED kind — reportable and
    # filterable by name like every other kind, never selected by any strip op
    # (see the ops switch below). Re-sorted so run-folding sees positional order.
    # ---------------------------------------------------------------------------
    if ($population.Derived.Count -gt 0)
    {
        foreach ($fm in $population.Derived)
        {
            $classified.Add([pscustomobject]@{
                    Token    = $fm.Token
                    Kind     = 'FrontMatter'
                    StartOff = $fm.Token.Extent.StartOffset
                    EndOff   = $fm.Token.Extent.EndOffset
                    LineNum  = $fm.Token.Extent.StartLineNumber
                })
        }
        # Re-sort so run-folding below sees positional order. Offsets are unique
        # per token, so no ties — stability is moot.
        $classified.Sort([System.Comparison[object]] { param($a, $b) $a.StartOff.CompareTo($b.StartOff) })
    }

    # ---------------------------------------------------------------------------
    # Second pass: reclassify contiguous LineComment runs (2+ adjacent lines)
    # as CommentBlock.  Single isolated LineComment tokens are left as-is.
    # Any non-LineComment kind — FrontMatter above all — closes an open run:
    # stated run-splitter policy, not an emergent side effect (line-number
    # adjacency would split anyway since these kinds occupy their own lines).
    # ---------------------------------------------------------------------------
    $runStartI = -1
    $runEndI = -1

    for ($i = 0; $i -lt $classified.Count; $i++)
    {
        $c = $classified[$i]
        if ($c.Kind -ne 'LineComment')
        {
            if ($runStartI -ne -1 -and $runEndI -gt $runStartI)
            {
                for ($j = $runStartI; $j -le $runEndI; $j++) { $classified[$j].Kind = 'CommentBlock' }
            }
            $runStartI = -1
            $runEndI = -1
            continue
        }

        if ($runStartI -eq -1)
        {
            $runStartI = $i
            $runEndI = $i
        }
        elseif ($c.LineNum -eq $classified[$runEndI].LineNum + 1)
        {
            $runEndI = $i
        }
        else
        {
            if ($runEndI -gt $runStartI)
            {
                for ($j = $runStartI; $j -le $runEndI; $j++) { $classified[$j].Kind = 'CommentBlock' }
            }
            $runStartI = $i
            $runEndI = $i
        }
    }
    # Flush the final run
    if ($runStartI -ne -1 -and $runEndI -gt $runStartI)
    {
        for ($j = $runStartI; $j -le $runEndI; $j++) { $classified[$j].Kind = 'CommentBlock' }
    }

    # ---------------------------------------------------------------------------
    # Build character-offset strip spans
    # ---------------------------------------------------------------------------
    $spansToStrip = [System.Collections.Generic.List[pscustomobject]]::new()

    foreach ($c in $classified)
    {
        $shouldStrip = switch ($c.Kind)
        {
            'FrontMatter' { $false }   # ontology: never strip — no op can select it
            'BlockComment' { 'block-comments' -in $ops }
            'DocString' { 'doc-strings' -in $ops }
            'CommentBlock' { 'comment-blocks' -in $ops }
            'LineComment' { 'line-comments' -in $ops }
            'InlineComment' { 'inline-comments' -in $ops }
            default { $false }
        }
        if (-not $shouldStrip) { continue }

        $spanStart = $c.StartOff
        $spanEnd = $c.EndOff

        if ($c.Kind -eq 'InlineComment')
        {
            # Pull the span start back past any whitespace between code and comment
            $ws = $spanStart
            while ($ws -gt 0 -and ($text[$ws - 1] -eq ' ' -or $text[$ws - 1] -eq "`t")) { $ws-- }
            $spanStart = $ws
        }
        else
        {
            # Pull span start back to the beginning of the line, consuming leading
            # whitespace/indentation, so that stripping does not leave an orphaned
            # blank line fragment when the comment is indented inside a function body.
            $ls = $spanStart
            while ($ls -gt 0 -and ($text[$ls - 1] -eq ' ' -or $text[$ls - 1] -eq "`t")) { $ls-- }
            if ($ls -eq 0 -or $text[$ls - 1] -eq "`n" -or $text[$ls - 1] -eq "`r")
            {
                $spanStart = $ls
            }

            # Consume the trailing newline so the stripped line does not leave a blank gap
            if ($spanEnd -lt $text.Length)
            {
                if ($text[$spanEnd] -eq "`r")
                {
                    $spanEnd++
                    if ($spanEnd -lt $text.Length -and $text[$spanEnd] -eq "`n") { $spanEnd++ }
                }
                elseif ($text[$spanEnd] -eq "`n")
                {
                    $spanEnd++
                }
            }
        }

        $spansToStrip.Add([pscustomobject]@{ Start = $spanStart; End = $spanEnd })
    }

} # end else (AST path)

# ---------------------------------------------------------------------------
# Merge overlapping / adjacent spans
# ---------------------------------------------------------------------------
$merged = [System.Collections.Generic.List[pscustomobject]]::new()

if ($spansToStrip.Count -gt 0)
{
    # In-place sort; the merge below takes max(End) over overlapping spans, so
    # equal-Start ties produce the same union regardless of order.
    $spansToStrip.Sort([System.Comparison[object]] { param($a, $b) $a.Start.CompareTo($b.Start) })
    $sorted = $spansToStrip
    $cur = [pscustomobject]@{ Start = $sorted[0].Start; End = $sorted[0].End }

    for ($i = 1; $i -lt $sorted.Count; $i++)
    {
        $nxt = $sorted[$i]
        if ($nxt.Start -le $cur.End)
        {
            if ($nxt.End -gt $cur.End) { $cur = [pscustomobject]@{ Start = $cur.Start; End = $nxt.End } }
        }
        else
        {
            $merged.Add($cur)
            $cur = [pscustomobject]@{ Start = $nxt.Start; End = $nxt.End }
        }
    }
    $merged.Add($cur)
}

# ---------------------------------------------------------------------------
# Reconstruct text from the non-stripped spans
# ---------------------------------------------------------------------------
$sb = [System.Text.StringBuilder]::new($text.Length)
$pos = 0

foreach ($span in $merged)
{
    if ($span.Start -gt $pos)
    {
        $null = $sb.Append($text.Substring($pos, $span.Start - $pos))
    }
    $pos = $span.End
}
if ($pos -lt $text.Length)
{
    $null = $sb.Append($text.Substring($pos))
}

$stripped = $sb.ToString()

# Restore masked here-strings (fallback route only)
if ($hsStore.Count -gt 0)
{
    $stripped = [regex]::Replace($stripped, "$HS_OPEN(\d+)$HS_CLOSE", { param($m) $hsStore[[int]$m.Groups[1].Value] })
}

# ---------------------------------------------------------------------------
# Copy-on-mutate return — harmonized content-mutator contract (6d)
# Clone the bag, replace the content key, pass everything else through so
# identity fields (and any elements earlier chain steps attached) survive.
# ---------------------------------------------------------------------------
$recordObj = $null
if ($includeMeta)
{
    # ParseErrors / FallbackMode appear only when they occurred — conditional
    # emission on the record, [ordered] so field order is stable.
    $record = [ordered]@{
        Processor  = 'rs-psstrip'
        Operations = @($ops)
    }
    if ($null -ne $parseErrors) { $record['ParseErrors'] = $parseErrors }
    if ($useFallback) { $record['FallbackMode'] = 'regex' }
    $recordObj = [pscustomobject]$record
}

return Copy-Bag -Item $Item -Resolved $bc -Content $stripped -Record $recordObj
