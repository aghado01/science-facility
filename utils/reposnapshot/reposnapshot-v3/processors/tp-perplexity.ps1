<#
.SYNOPSIS
    Perplexity thread → exchange envelopes.

.DESCRIPTION
    Parses a Perplexity-style markdown thread export and returns one envelope
    per exchange:  { Index, Prompt, Reply, Citations[] }.

    Pipeline runs as a sequence of regex masking passes followed by a
    context-disambiguated split on the `---` terminus that Perplexity emits
    after each citation footer block.

    The two cite-related concerns are deliberately asymmetric:
      - Footer lines `[^id]: ...` are *metadata* — lifted into Citations[]
        and removed from Reply text.
      - Inline cite clusters `[^id][^id]...` are *content* (cross-reference
        anchors that locate which claim a citation supports) — masked for
        parsing safety, then restored unconditionally into Reply unless
        StripInlineCites is set.

        1. Strip HTML boilerplate    (display:none spans, decorative div wrappers)
        2. Mask code blocks          (sentinel tokens; restored on emit)
        3. Mask + extract citation footer blocks (lifted into Citations[];
           text removed from Reply)
        4. Mask inline cite clusters [^d][^d]...  (sentinel tokens; restored
           on emit by default; controlled by StripInlineCites)
        5. Split on `---` terminus, accepting only those preceded by a
           footer-block sentinel OR followed by an H1 — inline `---` rules
           are preserved
        6. Per chunk: extract H1 prompt; remainder is reply body
        7. Restore code blocks and (by default) inline cite clusters; emit
           envelopes

    ISS-load-safe: no #Requires, no Set-StrictMode, top-level param contract.
    Carries the interior helper _MaskByRegex — permitted per colonel's AST
    validation (top-level param block is the contract; interior helpers are
    legitimate).

    Processor self-documentation (no runtime enforcement in this file):
        - Item contract:  dual-key input (Text | Content accepted) →
          ENVELOPE OUTPUT by design ({ Id; Path; Exchanges[]; Processor }) —
          the thread track's 1 → N adapter input (assemble's Thread adapter
          explodes Exchanges into entries). Not a code-track enricher.
        - Position class: segmenting parser (thread track)
        - Intended Colonel IssPreset floor: Core
        - Required IssModules: none

.NOTES
    Config shape:
        IncludeMeta        bool   default true; bare-return is the Exchanges array
        StripInlineCites   bool   default false. When false (default), inline
                                  cite-cluster sentinels are restored back to
                                  their original [^d][^d]... text on emit so
                                  that Reply prose retains its citation anchors
                                  to the lifted Citations[] entries. Set true
                                  for clean-prose pipelines (summarization,
                                  content analysis) where the cite syntax is
                                  noise rather than signal.

    Returns (with meta):
        [pscustomobject]@{
            Id         = string
            Path       = string
            Exchanges  = [pscustomobject[]]    each: @{ Index, Prompt, Reply, Citations }
            Processor  = 'threadparser-perplexity'
        }

        Each Citation is [pscustomobject]@{ Id, Content }.

    Edge cases (v1 behaviour):
        - Exports without any `---` terminus are returned as a single exchange
          covering the whole text.
        - Chunks with no H1 anchor are emitted with empty Prompt and the entire
          chunk as Reply (orphan content, e.g. clipped export).
        - HTML and decorative wrappers around ⁂ asterisms are discarded; ⁂
          is not used as a terminus signal in this parser (— `---` is).

.PARAMETER Item
    String, hashtable, or pscustomobject.  Recognised keys: Text, Content,
    Path, Id.  String input is interpreted directly as the thread text.

.PARAMETER Config
    Hashtable with optional keys IncludeMeta, StripInlineCites (see above).
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
$includeMeta = if ($null -ne $Config['IncludeMeta']) { [bool]$Config['IncludeMeta'] } else { $true }
# Default $false = restore inline cite clusters so Reply prose keeps the
# `[^id]` anchors that point into Citations[].  Set $true only for
# clean-prose use cases (summarization, content analysis).
$stripInlineCites = if ($null -ne $Config['StripInlineCites']) { [bool]$Config['StripInlineCites'] } else { $false }

# ---------------------------------------------------------------------------
# Item unpacking
# ---------------------------------------------------------------------------
$text = $null
$path = $null
$id = $null

if ($Item -is [string])
{
    $text = $Item
}
elseif ($Item -is [hashtable] -or $Item -is [pscustomobject])
{
    if ($null -ne $Item.PSObject.Properties['Text']) { $text = [string]$Item.Text }
    elseif ($null -ne $Item.PSObject.Properties['Content']) { $text = [string]$Item.Content }
    if ($null -ne $Item.PSObject.Properties['Path']) { $path = [string]$Item.Path }
    if ($null -ne $Item.PSObject.Properties['Id']) { $id = [string]$Item.Id }
}

if ([string]::IsNullOrEmpty($text))
{
    if (-not $includeMeta) { return @() }
    return [pscustomobject]@{
        Id        = $id
        Path      = $path
        Exchanges = @()
        Processor = 'threadparser-perplexity'
    }
}

# ---------------------------------------------------------------------------
# Normalize line endings to LF.  Every line-anchored regex below uses `^...$`
# under Multiline; in .NET regex `$` matches the position before `\n` only,
# so a stray `\r` before `\n` breaks `[ \t]*$` style end-of-line clauses.
# Normalizing once up front avoids having to litter `\r?` across every
# pattern, and the emitted Prompt / Reply text uses LF consistently.
# ---------------------------------------------------------------------------
$text = $text -replace "`r`n", "`n" -replace "`r", "`n"

# ---------------------------------------------------------------------------
# Defensive repair: scrub trailing `---` lines and surrounding whitespace.
# A trailing `---` is the manual truncation marker users leave when clipping
# exchanges from a longer export.  It would otherwise cause the last `---` to
# fire as a terminus and emit an empty trailing exchange.  Strip-and-trim
# cleans the input rather than carrying the case as a downstream flag.
# Repeats to handle multiple trailing `---` lines (e.g. `---\n\n---\n`).
# ---------------------------------------------------------------------------
$text = $text.TrimEnd()
while ($text -match '\n[ \t]*-{3,}[ \t]*$')
{
    $text = ($text -replace '\n[ \t]*-{3,}[ \t]*$', '').TrimEnd()
}

# ---------------------------------------------------------------------------
# Sentinel tokens — Private Use Area, never appears in normal markdown.
# Both characters are consumed downstream by _MaskByRegex (open/close wrap
# of `<TAG>:<index>`) and by the per-chunk restore loops in Stage 6/7.
# ---------------------------------------------------------------------------
$SENT_OPEN = [char]0xE000
$SENT_CLOSE = [char]0xE001
$RX_NB = [System.Text.RegularExpressions.RegexOptions]::NonBacktracking
$RX_NB_M = $RX_NB -bor [System.Text.RegularExpressions.RegexOptions]::Multiline

# ---------------------------------------------------------------------------
# Helper: replace via Matches + StringBuilder (avoids MatchEvaluator quirks)
# Returns the rewritten text and appends preserved match values to $store.
# ---------------------------------------------------------------------------
function _MaskByRegex
{
    param(
        [string]$InputText,
        [System.Text.RegularExpressions.Regex]$Rx,
        [string]$Tag,
        [System.Collections.Generic.List[object]]$Store
    )

    $matches = $Rx.Matches($InputText)
    if ($matches.Count -eq 0) { return $InputText }

    $sb = [System.Text.StringBuilder]::new($InputText.Length)
    $pos = 0
    foreach ($m in $matches)
    {
        if ($m.Index -gt $pos) { [void]$sb.Append($InputText.Substring($pos, $m.Index - $pos)) }
        $i = $Store.Count
        $Store.Add($m.Value)
        [void]$sb.Append("$SENT_OPEN$Tag`:$i$SENT_CLOSE")
        $pos = $m.Index + $m.Length
    }
    if ($pos -lt $InputText.Length) { [void]$sb.Append($InputText.Substring($pos)) }
    return $sb.ToString()
}

# ---------------------------------------------------------------------------
# Stage 1 — Strip HTML boilerplate
# Both patterns are conservative: only the specific decorative shapes Perplexity
# emits.  No general HTML stripping; semantic `<...>` content in code or prose
# is preserved.
# ---------------------------------------------------------------------------
$text = [regex]::Replace(
    $text,
    '(?is)<span\s+style\s*=\s*"display:\s*none[^"]*"[^>]*>.*?</span>',
    ''
)
$text = [regex]::Replace(
    $text,
    '(?is)<div\s+align\s*=\s*"center"[^>]*>.*?</div>',
    ''
)

# ---------------------------------------------------------------------------
# Stage 2 — Mask code blocks
# NonBacktracking handles the `until next fence` interior safely.
# ---------------------------------------------------------------------------
$codeBlocks = [System.Collections.Generic.List[object]]::new()
$rxCode = [regex]::new(
    '(?ms)^[ \t]*`{3,}[^\n]*\n.*?\n[ \t]*`{3,}[ \t]*$',
    $RX_NB_M
)
$text = _MaskByRegex -InputText $text -Rx $rxCode -Tag 'CODE' -Store $codeBlocks

# ---------------------------------------------------------------------------
# Stage 3 — Mask + extract citation footer blocks
# Must run BEFORE inline cite masking — otherwise the inline pattern would
# consume the `[^id]` at the start of footer lines, blocking the footer match.
# Multi-line: a contiguous run of `^[^id]: content` lines collapses to a
# single sentinel; the run's entries are parsed into pscustomobjects and
# stashed by index for retrieval after split.
#
# Assumption: Stage 2 already masked all fenced code blocks.  A literal
# `[^id]: ...` line that survives inside an unmasked fence (e.g. a code
# block that uses an indented or non-standard fence shape Stage 2's regex
# didn't recognise) would be incorrectly captured here as a citation.
# In practice Perplexity emits only standard ``` fences, so this is a
# theoretical hazard not yet observed in real exports.
# ---------------------------------------------------------------------------
$footerBlocks = [System.Collections.Generic.List[object]]::new()
$rxFooter = [regex]::new(
    '(?m)(?:^\[\^[\w]+\]:[^\n]*\n?)+',
    $RX_NB_M
)
$rxFooterEntry = [regex]::new('(?m)^\[\^([\w]+)\]:\s*(.+?)\s*$')

$footerMatches = $rxFooter.Matches($text)
if ($footerMatches.Count -gt 0)
{
    $sb = [System.Text.StringBuilder]::new($text.Length)
    $pos = 0
    foreach ($m in $footerMatches)
    {
        if ($m.Index -gt $pos) { [void]$sb.Append($text.Substring($pos, $m.Index - $pos)) }

        $entries = [System.Collections.Generic.List[object]]::new()
        foreach ($em in $rxFooterEntry.Matches($m.Value))
        {
            $entries.Add([pscustomobject]@{
                    Id      = $em.Groups[1].Value
                    Content = $em.Groups[2].Value
                })
        }
        $i = $footerBlocks.Count
        $footerBlocks.Add($entries.ToArray())
        [void]$sb.Append("$SENT_OPEN`FOOTER:$i$SENT_CLOSE")
        $pos = $m.Index + $m.Length
    }
    if ($pos -lt $text.Length) { [void]$sb.Append($text.Substring($pos)) }
    $text = $sb.ToString()
}

# ---------------------------------------------------------------------------
# Stage 4 — Mask inline citation pointer clusters
# Runs after footer masking so the line-anchored footer pattern was not
# blocked by inline-cluster greedy consumption of `[^id]`.
# Matches one or more [^id] markers, possibly separated by whitespace or
# the word " and ".
# ---------------------------------------------------------------------------
$inlineCites = [System.Collections.Generic.List[object]]::new()
$rxInlineCite = [regex]::new(
    '\[\^[\w]+\](?:\s*(?:and\s+)?\[\^[\w]+\])*',
    [System.Text.RegularExpressions.RegexOptions]::None
)
$text = _MaskByRegex -InputText $text -Rx $rxInlineCite -Tag 'CITE' -Store $inlineCites

# ---------------------------------------------------------------------------
# Stage 5 — Split on `---` terminus, disambiguated by context
# A `---` line is a true terminus iff EITHER:
#   - The preceding non-whitespace content is a footer-block sentinel, OR
#   - The next non-whitespace content is an H1 line (`# ...`)
# The first rule catches the typical case (exchange ends with citations); the
# second catches exchanges that have no citations and end on reply prose.
# Inline horizontal rules in replies are typically followed by H2 or prose,
# not H1, and are not preceded by a footer sentinel — so they're correctly
# excluded.
# ---------------------------------------------------------------------------
$rxFooterSent = [regex]::new("$SENT_OPEN`FOOTER:\d+$SENT_CLOSE")
$rxHr = [regex]::new('(?m)^[ \t]*-{3,}[ \t]*$')
$rxNextH1 = [regex]::new('\A[\r\n \t]*#[ \t]+\S')

$splitSpans = [System.Collections.Generic.List[object]]::new()
foreach ($m in $rxHr.Matches($text))
{
    $isTerminus = $false

    # Rule 1: preceding context is a footer-block sentinel
    $back = $m.Index - 1
    while ($back -ge 0)
    {
        $ch = $text[$back]
        if ($ch -ne ' ' -and $ch -ne "`t" -and $ch -ne "`n" -and $ch -ne "`r") { break }
        $back--
    }
    if ($back -ge 0)
    {
        $scanStart = [math]::Max(0, $back - 32)
        $window = $text.Substring($scanStart, $back - $scanStart + 1)
        if ($rxFooterSent.IsMatch($window)) { $isTerminus = $true }
    }

    # Rule 2: next non-whitespace content is an H1 line
    if (-not $isTerminus)
    {
        $forwardStart = $m.Index + $m.Length
        if ($forwardStart -lt $text.Length)
        {
            $forward = $text.Substring($forwardStart, [math]::Min(256, $text.Length - $forwardStart))
            if ($rxNextH1.IsMatch($forward)) { $isTerminus = $true }
        }
    }

    if ($isTerminus)
    {
        $splitSpans.Add([pscustomobject]@{
                Start = $m.Index
                End   = $m.Index + $m.Length
            })
    }
}

# Slice
$chunks = [System.Collections.Generic.List[string]]::new()
$prev = 0
foreach ($s in $splitSpans)
{
    if ($s.Start -gt $prev)
    {
        $chunks.Add($text.Substring($prev, $s.Start - $prev))
    }
    $prev = $s.End
}
if ($prev -lt $text.Length)
{
    $chunks.Add($text.Substring($prev))
}

# Empty chunks (e.g. consecutive terminators) drop out
$kept = [System.Collections.Generic.List[string]]::new()
foreach ($c in $chunks) { if (-not [string]::IsNullOrWhiteSpace($c)) { $kept.Add($c) } }
$chunks = @($kept)

# ---------------------------------------------------------------------------
# Stage 6/7 — Per chunk: extract prompt / reply / citations; restore code blocks
# ---------------------------------------------------------------------------
$rxH1 = [regex]::new('(?m)^[ \t]*#[ \t]+(.*?)[ \t]*$')
$rxCodeSent = [regex]::new("$SENT_OPEN`CODE:(\d+)$SENT_CLOSE")
$rxCiteSent = [regex]::new("$SENT_OPEN`CITE:(\d+)$SENT_CLOSE")

$exchanges = [System.Collections.Generic.List[object]]::new()
$exchangeIdx = 0

foreach ($chunk in $chunks)
{
    $body = $chunk.Trim()
    if ([string]::IsNullOrEmpty($body)) { continue }

    # Pull citations off the footer sentinel (if present)
    $citations = @()
    $fm = $rxFooterSent.Match($body)
    if ($fm.Success)
    {
        $idxMatch = [regex]::Match($fm.Value, 'FOOTER:(\d+)')
        if ($idxMatch.Success)
        {
            $bi = [int]$idxMatch.Groups[1].Value
            if ($bi -ge 0 -and $bi -lt $footerBlocks.Count)
            {
                $citations = $footerBlocks[$bi]
            }
        }
        # Strip the sentinel from the body so it doesn't pollute Reply
        $body = $rxFooterSent.Replace($body, '').TrimEnd()
    }

    # Locate first H1 — the prompt anchor
    $h1Match = $rxH1.Match($body)
    $prompt = ''
    $reply = ''

    if ($h1Match.Success)
    {
        # Perplexity convention: the H1 line IS the prompt (the user's
        # message is stored as a single H1 in the export, regardless of
        # its length).  Everything after the H1 is reply.
        $prompt = $h1Match.Groups[1].Value
        $afterH1 = $body.Substring($h1Match.Index + $h1Match.Length)
        $reply = ($afterH1 -replace '^[\r\n \t]+', '').TrimEnd()
    }
    else
    {
        # No H1 — chunk is orphan content; treat the whole thing as reply
        $reply = $body
    }

    # Restore code-block sentinels
    if ($prompt -and $rxCodeSent.IsMatch($prompt))
    {
        $sb = [System.Text.StringBuilder]::new($prompt.Length)
        $pos = 0
        foreach ($m in $rxCodeSent.Matches($prompt))
        {
            if ($m.Index -gt $pos) { [void]$sb.Append($prompt.Substring($pos, $m.Index - $pos)) }
            [void]$sb.Append([string]$codeBlocks[[int]$m.Groups[1].Value])
            $pos = $m.Index + $m.Length
        }
        if ($pos -lt $prompt.Length) { [void]$sb.Append($prompt.Substring($pos)) }
        $prompt = $sb.ToString()
    }
    if ($reply -and $rxCodeSent.IsMatch($reply))
    {
        $sb = [System.Text.StringBuilder]::new($reply.Length)
        $pos = 0
        foreach ($m in $rxCodeSent.Matches($reply))
        {
            if ($m.Index -gt $pos) { [void]$sb.Append($reply.Substring($pos, $m.Index - $pos)) }
            [void]$sb.Append([string]$codeBlocks[[int]$m.Groups[1].Value])
            $pos = $m.Index + $m.Length
        }
        if ($pos -lt $reply.Length) { [void]$sb.Append($reply.Substring($pos)) }
        $reply = $sb.ToString()
    }

    # Inline cite-cluster sentinel handling.  Default (StripInlineCites=$false)
    # restores them so Reply prose retains its anchors into Citations[].
    # When StripInlineCites=$true we actively REMOVE the sentinels (not just
    # skip the restore) so clean-prose consumers don't see PUA artefacts.
    if ($stripInlineCites)
    {
        if ($prompt) { $prompt = $rxCiteSent.Replace($prompt, '') }
        if ($reply) { $reply = $rxCiteSent.Replace($reply, '') }
    }
    else
    {
        if ($prompt -and $rxCiteSent.IsMatch($prompt))
        {
            $sb = [System.Text.StringBuilder]::new($prompt.Length)
            $pos = 0
            foreach ($m in $rxCiteSent.Matches($prompt))
            {
                if ($m.Index -gt $pos) { [void]$sb.Append($prompt.Substring($pos, $m.Index - $pos)) }
                [void]$sb.Append([string]$inlineCites[[int]$m.Groups[1].Value])
                $pos = $m.Index + $m.Length
            }
            if ($pos -lt $prompt.Length) { [void]$sb.Append($prompt.Substring($pos)) }
            $prompt = $sb.ToString()
        }
        if ($reply -and $rxCiteSent.IsMatch($reply))
        {
            $sb = [System.Text.StringBuilder]::new($reply.Length)
            $pos = 0
            foreach ($m in $rxCiteSent.Matches($reply))
            {
                if ($m.Index -gt $pos) { [void]$sb.Append($reply.Substring($pos, $m.Index - $pos)) }
                [void]$sb.Append([string]$inlineCites[[int]$m.Groups[1].Value])
                $pos = $m.Index + $m.Length
            }
            if ($pos -lt $reply.Length) { [void]$sb.Append($reply.Substring($pos)) }
            $reply = $sb.ToString()
        }
    }

    $exchanges.Add([pscustomobject]@{
            Index     = $exchangeIdx
            Prompt    = $prompt
            Reply     = $reply
            Citations = $citations
        })
    $exchangeIdx++
}

# ---------------------------------------------------------------------------
# Return
# ---------------------------------------------------------------------------
if (-not $includeMeta) { return $exchanges.ToArray() }

return [pscustomobject]@{
    Id        = $id
    Path      = $path
    Exchanges = $exchanges.ToArray()
    Processor = 'threadparser-perplexity'
}
