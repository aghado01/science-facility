<#
.SYNOPSIS
    Language-agnostic text formatter (whitespace and encoding normalization).

.DESCRIPTION
    This file is loaded as a function body through SessionStateFunctionEntry.
    ISS-load-safe: no #Requires, top-level param contract (interior helpers
    permitted per colonel AST validation).

    Operations is a SET the caller subsets; the implementation applies
    selected ops in a fixed internal order (lf first … eof-eot last) because
    application order is a correctness invariant, not a preference. This
    processor is the named precedent for the operation-order doctrine
    ("config selects members, implementation owns sequence" —
    issues/v3/rs.core.assemble-design.md).

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
            Assemble collates it as an ordinary element (open element model —
            no per-element branches, declared in Header.Elements).

        Pipeline suitability per op:
            Op               TP-safe   RS opt-in   Notes
            lf               yes       yes         EOL -> LF; run first
            no-bom           yes       yes         Strip UTF-8 BOM
            nfc              yes       yes         Unicode NFC normalization
            strip-zwsp       yes       yes         Zero-width invisibles
            trim-trailing    yes       yes         Per-line trailing whitespace
            trim-inner       yes       yes         Inline multi-space collapse between words
            max-blank-2      yes       yes         Keep ≤2 blank lines; collapse 3+ blank lines to 2
            max-blank-1      caution   yes         Keep ≤1 blank line; collapse 2+ blank lines to 1; lossy for prose
            trim-doc         yes       yes         Strip leading/trailing blank lines from document
            eof-eot          no        yes         Append U+0004 sentinel; RS pipeline only
#>
# [CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [object]$Item,
    [Parameter(Position = 1)]
    [hashtable]$Config = @{}
)

$ops = if ($Config.ContainsKey('Operations')) { @($Config['Operations']) } else { @('lf', 'no-bom', 'nfc', 'strip-zwsp', 'trim-trailing', 'trim-inner', 'max-blank-2', 'trim-doc') }
$includeMeta = if ($null -ne $Config['IncludeMeta']) { [bool]$Config['IncludeMeta'] } else { $true }

# Content-key resolution — harmonized content-mutator contract (6d), shared by
# the whole fleet via processors/bag-helpers.ps1. $null means there is nothing
# to mutate, so the item passes through untouched.
$bc = Resolve-BagContent -Item $Item
if ($null -eq $bc) { return $Item }

$t = $bc.Text

if ('lf' -in $ops)
{
    $t = $t -replace "`r`n", "`n" -replace "`r", "`n"
}

if ('no-bom' -in $ops)
{
    $t = $t -replace '^\uFEFF', ''
}

if ('nfc' -in $ops)
{
    try { $t = $t.Normalize([System.Text.NormalizationForm]::FormC) } catch {}
}

if ('strip-zwsp' -in $ops)
{
    $t = $t -replace '[\u200B\u200C\u200D\u2060\uFEFF]', ''
}

if ('trim-trailing' -in $ops)
{
    # Index loop mutating in place — no pipeline, no per-item cmdlet dispatch.
    $lines = $t -split "`n"
    for ($i = 0; $i -lt $lines.Count; $i++) { $lines[$i] = $lines[$i].TrimEnd() }
    $t = $lines -join "`n"
}

if ('trim-inner' -in $ops)
{
    $t = $t -replace '(?<=\S) {2,}(?=\S)', ' '
}

if ('max-blank-2' -in $ops)
{
    $t = $t -replace "(`n){4,}", "`n`n`n"
}

if ('max-blank-1' -in $ops)
{
    $t = $t -replace "(`n){3,}", "`n`n"
}

if ('trim-doc' -in $ops)
{
    $t = $t -replace '^\n+', '' -replace '\n+$', ''
}

if ('eof-eot' -in $ops)
{
    $t = $t.TrimEnd("`r", "`n") + "`n`u{0004}"
}

# Copy-on-mutate return — shared Copy-Bag helper. Clones the bag, replaces the
# resolved content key, passes everything else through so identity fields (and
# any elements earlier chain steps attached) survive. Bare string in → bare
# string out. IncludeMeta = $false simply withholds the Processing record.
$record = if ($includeMeta) { [pscustomobject]@{ Processor = 'format'; Operations = @($ops) } } else { $null }
return Copy-Bag -Item $Item -Resolved $bc -Content $t -Record $record
