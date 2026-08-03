<#
.SYNOPSIS
    Regex-based C# comment-stripping post-processor.

.DESCRIPTION
    Classifies C# comment tokens into six kinds and strips the requested kinds
    based on the Config.Operations array.

    Unlike rs-psstrip.ps1, this processor is regex-only — no native C# AST is
    available from PowerShell.  Known limitation: // and /* tokens that appear
    inside string literals (including verbatim @"..." strings) may be incorrectly
    treated as comments.  This is acceptable for token-reduction use cases where
    output is consumed by an LLM rather than compiled.
    Pending evaluation (lts-v3-transfer-audit inventory): adopt LTS
    Normalize-FileContent's combined string-or-comment alternation scan, which
    closes the string-literal false-positive class in one pattern.

    Behavior note: line endings are normalized CRLF/CR → LF as a side effect
    before span analysis (offsets require a stable newline basis).

    ISS-load-safe: no #Requires, top-level param contract (interior helpers
    permitted per colonel AST validation).

    Processor self-documentation (no runtime enforcement in this file):
        - Item contract:  harmonized content mutator (consolidation 6d) —
          reads Content (descriptor contract) else Text (tp-era), mutates it,
          and writes the SAME key back on a CLONE of the incoming bag; every
          other property passes through untouched. Copy-on-mutate: the mutator
          sibling of file-read's copy-on-enrich. Track-agnostic — the
          processor never renames, invents, or edits a key it did not read.
          Bare string in → bare string out. Bag carrying neither key →
          returned untouched. Per-invocation metadata appends one record to
          the `Processing` element.
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
    String, hashtable, or pscustomobject.  Recognised keys: Text, Path, Id.

.PARAMETER Config
    Hashtable with optional keys:
      Operations  [string[]] opt-in strip list; default: all four structural kinds (interior + inline kept)
                  Valid values: 'block-comments','interior-comments','doc-strings','comment-blocks','line-comments','inline-comments'
      IncludeMeta [bool] default $true  — attach the `Processing` record. $false
                  returns the mutated bag WITHOUT the record; it never collapses a
                  bag to a bare string (that was the tp-era envelope behavior 6d
                  removed). Bare-string input is unaffected either way.

.NOTES
        Processing element (harmonized mutator metadata, 6d):
            An ordered array on the bag; each mutator invocation APPENDS
                @{ Processor; Operations }
            Chain order = array order. Assemble collates it as an ordinary
            element (open element model — no per-element branches).
#>
param(
    [Parameter(Position = 0)]
    [object]$Item,

    [Parameter(Position = 1)]
    [hashtable]$Config = @{}
)

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
# A bag carrying NEITHER key is returned untouched (mirrors rs-attributes'
# no-Content contract): a mutator with nothing to mutate must not fabricate an
# empty payload — assemble routes empty content to Diagnostics and splits
# EmptyFile from EmptiedByProcessing, so a phantom '' would forge an entry.
# Content wins when both keys exist; Text is then left exactly as found (never
# edit a key you did not read) — no current producer emits both.
# ---------------------------------------------------------------------------
$keys = @()
$contentKey = $null
$text = $null

if ($Item -is [string])
{
    $text = $Item
}
elseif ($Item -is [hashtable] -or $Item -is [pscustomobject])
{
    $keys = if ($Item -is [hashtable]) { @($Item.Keys) } else { @($Item.PSObject.Properties.Name) }
    $contentKey = if ('Content' -in $keys) { 'Content' } elseif ('Text' -in $keys) { 'Text' } else { $null }
    if ($null -eq $contentKey) { return $Item }
    $text = [string]$Item.$contentKey
}
else
{
    return $Item
}

if ([string]::IsNullOrEmpty($text))
{
    $text = ''
}

# ---------------------------------------------------------------------------
# Normalize line endings (CRLF/CR -> LF)
# ---------------------------------------------------------------------------
$text = $text -replace "`r`n", "`n" -replace "`r", "`n"

# ---------------------------------------------------------------------------
# Build strip spans via regex
# ---------------------------------------------------------------------------
$spansToStrip = [System.Collections.Generic.List[pscustomobject]]::new()

$stripBlock    = 'block-comments'    -in $ops
$stripInterior = 'interior-comments' -in $ops
$stripDoc         = 'doc-strings'           -in $ops
$stripCB          = 'comment-blocks'        -in $ops
$stripLine        = 'line-comments'         -in $ops
$stripInline      = 'inline-comments'       -in $ops

# ---------------------------------------------------------------------------
# Block comments  /* ... */
# One regex pass classifies each match as standalone or inline-block, then
# routes to the appropriate op.
#
#   Standalone     — only whitespace precedes /* on its first line AND
#                    only whitespace follows */ on its last line.
#                    Span expanded to consume leading indent + trailing newline.
#   InlineBlock    — code precedes /* OR code follows */ on the same line.
#                    Short, informative placeholders (e.g. empty catch bodies).
#                    Span covers the /* */ token only; surrounding code is kept.
# ---------------------------------------------------------------------------
if ($stripBlock -or $stripInterior)
{
    $rx = [regex]::new('(?s)/\*.*?\*/', 'None')
    foreach ($m in $rx.Matches($text))
    {
        $s = $m.Index
        $e = $m.Index + $m.Length

        # Code-before check: walk back from /* over whitespace
        $ls = $s
        while ($ls -gt 0 -and ($text[$ls - 1] -eq ' ' -or $text[$ls - 1] -eq "`t")) { $ls-- }
        $standaloneStart = ($ls -eq 0 -or $text[$ls - 1] -eq "`n")

        # Code-after check: scan from */ to end of line
        $lineEnd = $text.IndexOf("`n", $e)
        if ($lineEnd -eq -1) { $lineEnd = $text.Length }
        $standaloneEnd = ($text.Substring($e, $lineEnd - $e) -notmatch '\S')

        if ($standaloneStart -and $standaloneEnd)
        {
            if (-not $stripBlock) { continue }
            # Expand span: consume leading indent and trailing newline
            $s = $ls
            if ($e -lt $text.Length -and $text[$e] -eq "`n") { $e++ }
        }
        else
        {
            if (-not $stripInterior) { continue }
            # Strip only the /* */ token; surrounding code is kept intact
        }

        $spansToStrip.Add([pscustomobject]@{ Start = $s; End = $e })
    }
}

# ---------------------------------------------------------------------------
# Doc strings  ///  (triple-slash XML doc comments)
# Matched before the generic // pass; (?!/) guard on // patterns below ensures
# no double-matching regardless of operation combination.
# ---------------------------------------------------------------------------
if ($stripDoc)
{
    $rxDoc = [regex]::new('(?m)^([^\S\n]*)///[^\n]*(\n)?', 'None')
    foreach ($m in $rxDoc.Matches($text))
    {
        $spansToStrip.Add([pscustomobject]@{ Start = $m.Index; End = $m.Index + $m.Length })
    }
}

# ---------------------------------------------------------------------------
# Standalone // lines — collect, then classify into LineComment / CommentBlock
# (?!/) guard prevents matching /// lines (doc-string or not).
# ---------------------------------------------------------------------------
if ($stripCB -or $stripLine)
{
    $rxLine = [regex]::new('(?m)^([^\S\n]*)//(?!/)[^\n]*(\n)?', 'None')

    $standaloneMatches = [System.Collections.Generic.List[pscustomobject]]::new()

    foreach ($m in $rxLine.Matches($text))
    {
        # Verify no code precedes // on this line
        $slashIdx = $m.Index + $m.Groups[1].Length
        $before = $text.Substring($m.Index, $slashIdx - $m.Index)
        if ($before -match '\S') { continue }   # code before // → InlineComment, handled below

        $lineNum = ($text.Substring(0, $m.Index) -split "`n").Count

        $standaloneMatches.Add([pscustomobject]@{
                LineNum = $lineNum
                Start   = $m.Index
                End     = $m.Index + $m.Length
            })
    }

    # Reclassify runs of 2+ consecutive lines as CommentBlock
    $runStartI = -1
    $runEndI = -1
    $cbFlags = @($false) * $standaloneMatches.Count

    for ($i = 0; $i -lt $standaloneMatches.Count; $i++)
    {
        $cur = $standaloneMatches[$i]
        if ($runStartI -eq -1)
        {
            $runStartI = $i; $runEndI = $i
        }
        elseif ($cur.LineNum -eq $standaloneMatches[$runEndI].LineNum + 1)
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
        $shouldStrip = if ($cbFlags[$i]) { $stripCB } else { $stripLine }
        if (-not $shouldStrip) { continue }
        $sm = $standaloneMatches[$i]
        $ls2 = $sm.Start
        while ($ls2 -gt 0 -and ($text[$ls2 - 1] -eq ' ' -or $text[$ls2 - 1] -eq "`t")) { $ls2-- }
        $s2 = if ($ls2 -eq 0 -or $text[$ls2 - 1] -eq "`n") { $ls2 } else { $sm.Start }
        $spansToStrip.Add([pscustomobject]@{ Start = $s2; End = $sm.End })
    }
}

# ---------------------------------------------------------------------------
# Inline comments — // after code on the same line
# (?!/) guard avoids matching /// (rare mid-line case, but consistent).
# ---------------------------------------------------------------------------
if ($stripInline)
{
    $rxInline = [regex]::new('[ \t]*//(?!/)[^\n]*', 'None')
    foreach ($m in $rxInline.Matches($text))
    {
        $lineStart = $text.LastIndexOf("`n", $m.Index)
        $lineStart = if ($lineStart -eq -1) { 0 } else { $lineStart + 1 }
        $before = $text.Substring($lineStart, $m.Index - $lineStart)
        if ($before -notmatch '\S') { continue }
        $spansToStrip.Add([pscustomobject]@{ Start = $m.Index; End = $m.Index + $m.Length })
    }
}

# ---------------------------------------------------------------------------
# Merge overlapping / adjacent spans
# ---------------------------------------------------------------------------
$merged = [System.Collections.Generic.List[pscustomobject]]::new()

if ($spansToStrip.Count -gt 0)
{
    $sorted = @($spansToStrip | Sort-Object { $_.Start })
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

# ---------------------------------------------------------------------------
# Copy-on-mutate return — harmonized content-mutator contract (6d)
# Clone the bag, replace the content key, pass everything else through so
# identity fields (and any elements earlier chain steps attached) survive.
# ---------------------------------------------------------------------------
if ($null -eq $contentKey) { return $stripped }

$result = [pscustomobject]@{}
foreach ($name in $keys)
{
    $value = if ($name -eq $contentKey) { $stripped } else { $Item.$name }
    $result | Add-Member -NotePropertyName $name -NotePropertyValue $value
}

if ($includeMeta)
{
    $record = [pscustomobject]@{ Processor = 'rs-csstrip'; Operations = @($ops) }
    if ('Processing' -in $keys) { $result.Processing = @($Item.Processing) + $record }
    else { $result | Add-Member -NotePropertyName Processing -NotePropertyValue @($record) }
}

return $result
