<#
.SYNOPSIS
    Code-lane whitespace normalizer (line endings, trailing whitespace, blank
    runs, encoding residue). Renamed from format-ws 2026-08-17 to say its lane:
    code ingestion, not markdown/document ingestion (ledger #21 lane split).

.DESCRIPTION
    Runs EARLY in the code-lane chain and its `lf` op is what lets every later
    stage — strippers, rs-indent, rs-content_meta, and the container's codec —
    count on LF-only content. Whitespace normalization is a requirement of the
    lane, not a nicety.

    This file is loaded as a function body through SessionStateFunctionEntry.
    ISS-load-safe: no #Requires, top-level param contract (interior helpers
    permitted per colonel AST validation).

    Operations is a SET the caller subsets; the implementation applies
    selected ops in a fixed internal order (lf first … ensure-final-lf last) because
    application order is a correctness invariant, not a preference. This
    processor is the named precedent for the operation-order doctrine
    ("config selects members, implementation owns sequence" —
    issues/reposnapshot/design/rs.core.assemble-design.md).

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
            Operations: string[] (opt-in operation list)
            IncludeMeta: bool (default true) — attach the `Processing` record.
                $false returns the mutated bag WITHOUT the record; it never
                collapses a bag to a bare string (that was the tp-era envelope
                behavior 6d removed). Bare-string input is unaffected either
                way — a string has no bag to carry metadata.

        Processing element (harmonized mutator metadata, 6d):
            An ordered array on the bag; each mutator invocation APPENDS
                @{ Processor; Operations; <processor-specific extras> }
            Chain order = array order, so a profile that runs the same
            processor twice records both passes instead of overwriting.

            This processor's extra: `Skipped` — present ONLY when a requested
            op did not run, as @{ Op; Reason }. Two reasons exist:
                InvalidUnicode  nfc declined (ill-formed UTF-16). The only op
                                that can fail; the rest are unconditional
                                text transforms.
                UnknownOp       the name matches no op — a typo such as
                                'trim-trailng' silently transforms nothing.
            Operations therefore lists ONLY what actually ran, and Skipped's
            absence means everything listed did run. Note `Operations` is built
            by the op blocks themselves as they execute; there is no separate
            roster of valid names to drift out of sync with them.
            Assemble collates it as an ordinary element (open element model —
            no per-element branches, declared in Header.Elements).

        Pipeline suitability per op:
            Op               TP-safe   RS opt-in   Notes
            lf               yes       yes         ALL line terminators -> LF; run first
            nfc              yes       yes         Unicode NFC normalization
            strip-zwsp       yes       yes         U+200B ZERO WIDTH SPACE
            strip-wj         yes       yes         U+2060 WORD JOINER
            strip-zwnbsp     yes       yes         U+FEFF anywhere, BOM included
            trim-trailing    yes       yes         Per-line trailing whitespace
            ensure-trailing-space yes  yes         One trailing space on NON-EMPTY lines; pairs with trim-trailing
            trim-inner       yes       yes         Inline multi-space collapse between words; NOT DEFAULT
            max-blank-1      caution   yes         Keep ≤1 blank line; collapse 2+ blank lines to 1; lossy for prose
            trim-doc         yes       yes         Strip leading/trailing blank lines from document
            ensure-final-lf  yes       yes         Append a final LF if absent; runs LAST

        INVISIBLES: one op per code point, and two are deliberately absent
        (2026-08-15). The old single `strip-zwsp` removed five characters as
        though they were one class. Three are inert presentation hints and are
        stripped; the other two are CONTENT and are no longer touched at all:

            U+200D ZWJ  — composes emoji sequences (the family emoji is
                          man + ZWJ + woman + ZWJ + girl; strip the joiners
                          and it becomes three separate people) and forces
                          Indic conjunct forms. Spelled out rather than shown:
                          a literal example would be a raw invisible sitting
                          in the file that warns about raw invisibles.
            U+200C ZWNJ — separates morphemes in Persian/Arabic/Urdu/Hindi;
                          removing it changes the word.

        Both are the only thing distinguishing one string from another, so
        deleting them is data corruption, not sanitization. They are not
        offered as ops — a caller cannot opt into breaking this. Note the
        self-referential hazard that settles it: any library that PROCESSES
        emoji sequences or Indic text carries these characters in its fixtures
        by necessity, and this tool exists to carry such code intact.

        `strip-zwnbsp` is unanchored, so it catches a leading BOM plus any
        deprecated mid-file ZWNBSP. Consequence worth knowing: stripping ONLY
        a leading BOM is not expressible.

        Deliberately NOT here: the bidi controls U+202A-U+202E / U+2066-U+2069
        (Trojan Source). Bidi is a PRESENTATION algorithm — files store logical
        order and only a renderer reorders, so a model reading the byte
        sequence sees what the compiler sees. Where they do occur it is i18n
        resources and mixed-RTL literals, making them load-bearing content like
        ZWJ/ZWNJ above. Detection is a read-only-tail diagnostic step's job, not
        a whitespace op's; decisions ledger #11/#11b.

        Default set (what you get with no Operations key):
            lf · nfc · strip-zwsp · strip-wj · strip-zwnbsp · trim-trailing ·
            max-blank-1 · trim-doc · ensure-final-lf · pad-breaks

        `pad-breaks` succeeded `ensure-trailing-space` (#20, 2026-08-24, the
        station settled by the user): content-block whitespace is THIS
        processor's job, and the downstream encoder is a pure symbol
        substitution with no spacing logic. pad-breaks inserts one space
        between any solid character and an adjacent newline, both directions
        — runs stay adjacent (blank lines encode as the canonical '\n\n'),
        the document-final newline takes no trailing space, and indented
        lines keep indentation as their own separation. It runs LAST, after
        ensure-final-lf.

        `trim-inner` is deliberately OUT of it. Every other default touches
        whitespace at line boundaries and margins, where shape is formatting
        rather than data; trim-inner reaches INSIDE a line and rewrites spacing
        that may be content — embedded SQL, fixed-width format templates,
        aligned output strings, ASCII art. The processor is lexically blind
        (unlike rs-psstrip/rs-csstrip it has no string masking), so it cannot
        tell a literal from code. Available on request, not by default.
#>
# [CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [object]$Item,
    [Parameter(Position = 1)]
    [hashtable]$Config = @{}
)

$ops = if ($Config.ContainsKey('Operations')) { @($Config['Operations']) } else { @('lf', 'nfc', 'strip-zwsp', 'strip-wj', 'strip-zwnbsp', 'trim-trailing', 'max-blank-1', 'trim-doc', 'ensure-final-lf', 'pad-breaks') }
$includeMeta = if ($null -ne $Config['IncludeMeta']) { [bool]$Config['IncludeMeta'] } else { $true }

# Content-key resolution — harmonized content-mutator contract (6d), shared by
# the whole fleet via processors/bag-helpers.ps1. $null means there is nothing
# to mutate, so the item passes through untouched.
$bc = Resolve-BagContent -Item $Item
if ($null -eq $bc) { return $Item }

$t = $bc.Text

# Receipt state. $ran is built BY THE OPS THEMSELVES as they execute — there is
# deliberately no separate list of "known ops" to consult, because a second list
# is a second thing to maintain and the two drift. Anything requested that does
# not appear in $ran did not run, and the reason is either recorded explicitly
# (nfc declining) or is simply that no op answers to that name.
$ran = @()
$skipped = @()

if ('lf' -in $ops)
{
    $ran += 'lf'

    # STERILIZES EVERY LINE TERMINATOR, not just CRLF/CR, so everything
    # downstream can treat LF as the only break character and mean it.
    # CRLF is folded first — as a character class it would become two breaks.
    #
    # Beyond CR: VT U+000B and FF U+000C (C0 layout controls, FF is a page
    # break in older C sources), NEL U+0085, and LS/PS U+2028/U+2029. The last
    # three matter most: they are line terminators to a JavaScript reader but
    # are NOT C0, so nothing downstream would catch them — they would reach the
    # payload as raw break-capable characters and split a row. The blank-line
    # ops only match "`n", so an unfolded terminator also defeats run
    # detection ("`n`u{2028}`n" is not seen as a run).
    $t = $t -replace "`r`n", "`n" -replace '[\r\u000B\u000C\u0085\u2028\u2029]', "`n"
}

if ('nfc' -in $ops)
{
    # String.Normalize throws on ill-formed UTF-16 (a lone surrogate). Skipping
    # is the correct degradation under never-fail-ingest — conservative, never
    # refusing — but the receipt must then SAY so. Recording 'nfc' as applied
    # when it declined is a lie the reader cannot detect, and a fold nobody can
    # audit is the inverse of this project's receipts posture.
    try
    {
        $t = $t.Normalize([System.Text.NormalizationForm]::FormC)
        $ran += 'nfc'
    }
    catch { $skipped += [pscustomobject]@{ Op = 'nfc'; Reason = 'InvalidUnicode' } }
}

# One op per code point. ZWJ U+200D and ZWNJ U+200C are absent by design \u2014
# they carry meaning (see .NOTES INVISIBLES). Order among the three is
# irrelevant: none is produced or consumed by NFC or by the others.
if ('strip-zwsp' -in $ops)
{
    $ran += 'strip-zwsp'
    $t = $t -replace '\u200B', ''
}

if ('strip-wj' -in $ops)
{
    $ran += 'strip-wj'
    $t = $t -replace '\u2060', ''
}

# Unanchored, so this covers a leading BOM as well as any mid-file ZWNBSP.
if ('strip-zwnbsp' -in $ops)
{
    $ran += 'strip-zwnbsp'
    $t = $t -replace '\uFEFF', ''
}

if ('trim-trailing' -in $ops)
{
    $ran += 'trim-trailing'

    # Index loop mutating in place — no pipeline, no per-item cmdlet dispatch.
    $lines = $t -split "`n"
    for ($i = 0; $i -lt $lines.Count; $i++) { $lines[$i] = $lines[$i].TrimEnd() }
    $t = $lines -join "`n"
}

if ('trim-inner' -in $ops)
{
    $ran += 'trim-inner'
    $t = $t -replace '(?<=\S) {2,}(?=\S)', ' '
}

if ('max-blank-1' -in $ops)
{
    $ran += 'max-blank-1'
    $t = $t -replace "(`n){3,}", "`n`n"
}

if ('trim-doc' -in $ops)
{
    $ran += 'trim-doc'
    $t = $t -replace '^\n+', '' -replace '\n+$', ''
}

# LAST by contract. Paired with trim-doc (which strips the trailing run) this
# makes the document ending deterministic: exactly one final LF. Alone it is
# only additive — an existing trailing run is left as-is, since collapsing runs
# is max-blank-*'s job, not this op's. Empty content stays empty: a file with
# no content does not acquire a line.
if ('ensure-final-lf' -in $ops)
{
    $ran += 'ensure-final-lf'
    if ($t.Length -gt 0 -and -not $t.EndsWith("`n")) { $t += "`n" }
}

# LAST of all — after ensure-final-lf, so the final LF exists to take its
# before-space. Successor of ensure-trailing-space (#20, 2026-08-24), and the
# content half of the wire's mark-spacing story: one space between any SOLID
# character and an adjacent newline, BOTH directions, so the downstream
# encoder — a pure symbol substitution — lands every mark in a regular
# space-flanked environment. Two symmetric zero-width insertions:
#
#   (?<=\S)(?=\n)  a space before a break that touches a solid char
#   (?<=\n)(?=\S)  a space after a break that touches a solid char
#
# Everything the design needs falls out of the lookarounds, uncoded: interior
# newlines of a blank-line run touch only newlines → runs stay ADJACENT and
# encode as the canonical '\n\n'; the document-final newline has no follower
# → no trailing space (the end of a content block separates from nothing);
# an indented continuation line starts with its own whitespace → the
# indentation already separates, and no extra space is inserted. Idempotent
# by the same token — an already-spaced break touches no solid char.
if ('pad-breaks' -in $ops)
{
    $ran += 'pad-breaks'
    $t = $t -replace '(?<=\S)(?=\n)', ' ' -replace '(?<=\n)(?=\S)', ' '
}

# Copy-on-mutate return — shared Copy-Bag helper. Clones the bag, replaces the
# resolved content key, passes everything else through so identity fields (and
# any elements earlier chain steps attached) survive. Bare string in → bare
# string out. IncludeMeta = $false simply withholds the Processing record.
# Operations reports what RAN. Anything requested but absent from $ran either
# declined (already in $skipped, with a reason) or names no op at all — a typo
# like 'trim-trailng' silently matches nothing, and echoing it would claim a
# transform that never happened. Recorded rather than thrown: a config mistake
# should not cost the ingest, but it must not be invisible either.
foreach ($requested in ($ops | Select-Object -Unique))
{
    if ($requested -in $ran) { continue }

    # Scan the records rather than reaching for $skipped.Op: member access on an
    # EMPTY array writes to the error stream, and colonel clears $Error before
    # every processor call and attributes what it finds per item — so the common
    # case (nothing skipped) would hang a spurious error on every single item.
    $alreadyRecorded = $false
    foreach ($s in $skipped) { if ($s.Op -eq $requested) { $alreadyRecorded = $true; break } }
    if (-not $alreadyRecorded) { $skipped += [pscustomobject]@{ Op = $requested; Reason = 'UnknownOp' } }
}

# $ran is built by @() += so it is already an array at every count — no
# if-expression in the assignment path. An if-expression ENUMERATES its output,
# collapsing a one-element array to a scalar: @('lf') would arrive as the string
# 'lf' and Operations[0] would be 'l'. Same trap assemble hit.
$record = if ($includeMeta)
{
    $fields = [ordered]@{ Processor = 'rs-whitespace'; Operations = @($ran) }
    if ($skipped.Count) { $fields['Skipped'] = @($skipped) }
    [pscustomobject]$fields
}
else { $null }
return Copy-Bag -Item $Item -Resolved $bc -Content $t -Record $record
