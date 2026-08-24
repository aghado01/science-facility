<#
.SYNOPSIS
    RS-scoped indentation normalizer.

.DESCRIPTION
    Normalizes leading-whitespace indentation in source code files via a small
    set of independently selectable ops applied in a fixed internal order.

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
          the `Processing` element (see .NOTES).
        - Position class: content mutator
        - Intended Colonel IssPreset floor: Core
        - Required IssModules: none

.NOTES
        Config shape:
                    Operations: string[]  no defaults; processor is wholesale opt-in
                    IncludeMeta: bool     default true — attach the `Processing`
                                          record. $false returns the mutated bag
                                          WITHOUT the record; it never collapses a
                                          bag to a bare string (that was the tp-era
                                          envelope behavior 6d removed).
                    TargetUnit:  int      spaces per indent level; default 2

        Processing element (harmonized mutator metadata, 6d):
            An ordered array on the bag; each mutator invocation APPENDS
                @{ Processor; Operations; Skipped (this processor's extra) }
            Chain order = array order, so the documented two-pass rs-indent
            stack records BOTH passes instead of the second overwriting the
            first — the concrete reason the trail is a list, not a key.

        Skip-list path resolution: the contraindication gate reads
            RelativePath (descriptor contract) else Path (tp-era)
        — descriptor bags carry no `Path`, so a Path-only lookup would silently
        stop protecting Markdown the moment this processor joined a code-track
        chain.

        Op surface:

            Op              Auto-requires   Description
            ────────────────────────────────────────────────────────────────────
            strip-common    —               Subtract minimum leading-space depth
                                            from all non-blank lines (frame shift).
                                            Operates on raw text before detab;
                                            effective primarily on space-indented
                                            files. See FUTURE note below.

            detab           —               Single O(n) sweep: extract leading \s+
                                            per line, expand any tab characters to
                                            (TargetUnit spaces per tab), accumulate
                                            per-line space-depth. Required internal
                                            precondition for min-indent-2 and tabify;
                                            auto-activated when either is present.

            min-indent-2    detab           GCD-infer the file's minimum indent step
                                            from accumulated depths, then rescale all
                                            depths uniformly to TargetUnit. Parallel
                                            opt-in with tabify — neither depends on
                                            the other.

            tabify          detab           Convert leading space runs to tabs at
                                            TargetUnit width. Parallel opt-in with
                                            min-indent-2.

        Internal execution order (fixed regardless of which ops are requested):

            strip-common → detab → min-indent-2 → tabify

        Each stage gates on whether its op is present or required by a
        downstream op. Specifying only 'tabify' auto-activates detab.

        Pure-tab input:
            detab treats 1 tab = 1 indent level = TargetUnit spaces. Original
            tab-stop rendering width is not recoverable and not preserved by design.
            tabify on a pure-tab file is an idempotent round-trip.

        Contraindications:
            Do not use on Markdown or other prose/markup formats. Indentation
            is semantically load-bearing in Markdown (4-space indented blocks
            are code block syntax, not stylistic choice). Files with extensions
            in the skip list are returned unchanged with Skipped = $true.
            Skip list: .md .txt .rst .html .htm .xml .json .yaml .yml .toml .csv

        # FUTURE: strip-common on mixed or pure-tab files requires detab to have
        # run first for accurate common-indent measurement. Currently strip-common
        # measures leading spaces only; the common-tab case is a no-op.
        # Colonel chaining IS available (v2, plan-driven); the cleaner stack —
        #   rs-whitespace(lf) → rs-indent(detab) → rs-indent(strip-common, min-indent-2)
        # — now works in code-track descriptor chains as well: 6d harmonized all
        # four content mutators onto copy-on-mutate, so identity fields survive
        # and each pass appends its own Processing record.
        # For now, specifying detab + strip-common in one call is safe but
        # strip-common will only see already-expanded depths from lines ending
        # in non-tab leading whitespace (the tab expansion from detab within
        # the same call happens after strip-common).

        # FUTURE: Markdown fenced code block support — apply detab/min-indent-2
        # only inside ``` fences, leaving prose lines untouched. This would
        # allow strip-common to be safely omitted for indented-code-block compat.

        Physical-line splitting (2026-08-24, user): this processor finds line
        boundaries itself — CRLF, CR, LF, NEL U+0085, LS U+2028, PS U+2029, VT
        U+000B, FF U+000C — the same terminator vocabulary rs-whitespace's `lf`
        op recognizes, borrowed rather than reinvented. It does NOT fold them:
        each line's ORIGINAL terminator bytes are preserved and reattached
        verbatim on reassembly — folding to `\n` stays rs-whitespace's job.
        This is what lets rs-indent run BEFORE rs-whitespace in a chain: it no
        longer assumes lf has already normalized the text, only that its own
        leading-whitespace reshaping is correct regardless of which terminator
        kind separates two physical lines.
#>
# [CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [object]$Item,

    [Parameter(Position = 1)]
    [hashtable]$Config = @{}
)

# ---------------------------------------------------------------------------
# Config resolution
# ---------------------------------------------------------------------------
$ops = @($Config['Operations'])
# No default ops — processor is wholesale opt-in.
$includeMeta = if ($null -ne $Config['IncludeMeta']) { [bool]$Config['IncludeMeta'] } else { $true }
$targetUnit = if ($null -ne $Config['TargetUnit'] -and [int]$Config['TargetUnit'] -gt 0) { [int]$Config['TargetUnit'] } else { 2 }

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

# Skip-list path: RelativePath (descriptor) else Path (tp-era). A Path-only
# lookup silently stops protecting Markdown in code-track chains.
$path = $null
if ('RelativePath' -in $bc.Keys) { $path = [string]$Item.RelativePath }
elseif ('Path' -in $bc.Keys) { $path = [string]$Item.Path }

# ---------------------------------------------------------------------------
# Skip list — indentation normalization not appropriate for prose/markup.
# Skipped items still return through the normal copy-on-mutate tail (content
# unchanged, Skipped = $true on the Processing record) — every gate below is
# forced off rather than returning early, so there is exactly one emit site.
# ---------------------------------------------------------------------------
$ext = if ($path) { [IO.Path]::GetExtension($path).ToLowerInvariant() } else { '' }
$skipExts = @('.md', '.txt', '.rst', '.html', '.htm', '.xml', '.json', '.yaml', '.yml', '.toml', '.csv')
$skipped = $ext -in $skipExts

# ---------------------------------------------------------------------------
# Gate resolution
# ---------------------------------------------------------------------------
$doStripCommon = (-not $skipped) -and ('strip-common' -in $ops)
$doDetab = (-not $skipped) -and ('detab' -in $ops -or 'min-indent-2' -in $ops -or 'tabify' -in $ops)
$doMinIndent = (-not $skipped) -and ('min-indent-2' -in $ops)
$doTabify = (-not $skipped) -and ('tabify' -in $ops)

# Physical-line split — CRLF before lone CR (alternation order, same reason
# rs-whitespace's lf op states: as a character class CRLF would count as two
# breaks), then the remaining single-character terminator kinds. A capturing
# group in the split pattern makes [regex]::Split return content and
# terminator ALTERNATING — content, term, content, term, …, content — one
# more content element than terminator elements, exactly the shape
# `-split "`n"` produced before (including the trailing empty-string element
# when the text ends on a terminator), so $depths sizing below is unchanged.
# Terminators are NOT folded here — each is carried in $terms and reattached
# verbatim at the end; folding to `\n` stays rs-whitespace's job.
$termPattern = '\r\n|\r|\n|\u0085|\u2028|\u2029|\x0B|\x0C'
$parts = [regex]::Split($text, "($termPattern)")
$lines = [string[]]::new(($parts.Count + 1) / 2)
$terms = [string[]]::new($lines.Count - 1)
for ($i = 0; $i -lt $parts.Count; $i++)
{
    if ($i % 2 -eq 0) { $lines[$i / 2] = $parts[$i] } else { $terms[($i - 1) / 2] = $parts[$i] }
}
$depths = [int[]]::new($lines.Count)

# ---------------------------------------------------------------------------
# Stage 1 — strip-common
# Measures the minimum leading-space depth across all non-blank lines and
# subtracts it uniformly (frame shift). Operates on raw pre-detab text;
# effective on space-indented files. On pure-tab or mixed files the common
# leading-space count is typically 0, making this stage a no-op until detab
# has run (see FUTURE note in .NOTES).
# ---------------------------------------------------------------------------
if ($doStripCommon)
{
    $spaceLeads = [System.Collections.Generic.List[int]]::new()
    foreach ($line in $lines)
    {
        if ($line -match '\S')
        {
            $m = [regex]::Match($line, '^ +')
            $depth = if ($m.Success) { $m.Length } else { 0 }
            $spaceLeads.Add($depth)
        }
    }

    if ($spaceLeads.Count -gt 0)
    {
        # Manual minimum — Measure-Object's empty-input tolerance is not needed
        # here because the Count guard above already established non-empty.
        $common = $spaceLeads[0]
        foreach ($d in $spaceLeads) { if ($d -lt $common) { $common = $d } }
        if ($common -gt 0)
        {
            for ($i = 0; $i -lt $lines.Count; $i++)
            {
                if ($lines[$i] -match '\S')
                {
                    $m = [regex]::Match($lines[$i], '^ +')
                    $leadSpaces = if ($m.Success) { $m.Length } else { 0 }
                    $strip = [math]::Min($common, $leadSpaces)
                    if ($strip -gt 0) { $lines[$i] = $lines[$i].Substring($strip) }
                }
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Stage 2 — detab (single O(n) sweep)
# Extracts leading \s+ per line, expands tabs to (TargetUnit spaces per tab),
# and accumulates the resulting space-depth. $depths is shared state consumed
# by stages 3 and 4.
# ---------------------------------------------------------------------------
if ($doDetab)
{
    for ($i = 0; $i -lt $lines.Count; $i++)
    {
        $seg = [regex]::Match($lines[$i], '^\s+').Value
        if (-not $seg) { $depths[$i] = 0; continue }

        if ($seg -match '\t')
        {
            $expanded = $seg -replace '\t', (' ' * $targetUnit)
            $lines[$i] = $expanded + $lines[$i].Substring($seg.Length)
            $seg = $expanded
        }

        $depths[$i] = $seg.Length
    }
}

# ---------------------------------------------------------------------------
# Stage 3 — min-indent-2
# GCD-infers the file's current indent unit from non-zero depths, then
# rescales all depths uniformly to TargetUnit. Does not assume strip-common
# was run — operates correctly on absolute depths.
# ---------------------------------------------------------------------------
if ($doMinIndent)
{
    $nonZero = [System.Collections.Generic.List[int]]::new()
    foreach ($d in $depths) { if ($d -gt 0) { $nonZero.Add($d) } }
    if ($nonZero.Count -gt 0)
    {
        $gcd = $nonZero[0]
        for ($i = 1; $i -lt $nonZero.Count; $i++)
        {
            $a = $gcd; $b = $nonZero[$i]
            while ($b -ne 0) { $tmp = $a % $b; $a = $b; $b = $tmp }
            $gcd = $a
        }

        if ($gcd -gt 0 -and $gcd -ne $targetUnit)
        {
            for ($i = 0; $i -lt $lines.Count; $i++)
            {
                if ($depths[$i] -gt 0)
                {
                    $newDepth = [int]($depths[$i] * $targetUnit / $gcd)
                    $rest = $lines[$i].Substring($depths[$i])
                    $lines[$i] = (' ' * $newDepth) + $rest
                    $depths[$i] = $newDepth
                }
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Stage 4 — tabify
# Converts leading space runs to tabs at TargetUnit width. Parallel opt-in
# with min-indent-2 — both require detab but neither depends on the other.
# Remainder spaces (depth not divisible by TargetUnit) are preserved as-is.
# ---------------------------------------------------------------------------
if ($doTabify)
{
    for ($i = 0; $i -lt $lines.Count; $i++)
    {
        if ($depths[$i] -gt 0)
        {
            $tabs = [math]::Floor($depths[$i] / $targetUnit)
            $remainder = $depths[$i] % $targetUnit
            $rest = $lines[$i].Substring($depths[$i])
            $lines[$i] = ("`t" * $tabs) + (' ' * $remainder) + $rest
        }
    }
}

# Reassemble with EACH line's ORIGINAL terminator (never a hardcoded "`n"),
# so a file whose terminators were never folded (rs-indent ran before
# rs-whitespace's lf) round-trips its terminator bytes exactly, untouched.
$sb = [System.Text.StringBuilder]::new()
for ($i = 0; $i -lt $lines.Count; $i++)
{
    [void]$sb.Append($lines[$i])
    if ($i -lt $terms.Count) { [void]$sb.Append($terms[$i]) }
}
$t = $sb.ToString()

# ---------------------------------------------------------------------------
# Copy-on-mutate return — harmonized content-mutator contract (6d)
# Clone the bag, replace the content key, pass everything else through so
# identity fields (and any elements earlier chain steps attached) survive.
# ---------------------------------------------------------------------------
$record = if ($includeMeta)
{
    [pscustomobject]@{ Processor = 'rs-indent'; Operations = @($ops); Skipped = $skipped }
}
else { $null }

return Copy-Bag -Item $Item -Resolved $bc -Content $t -Record $record
