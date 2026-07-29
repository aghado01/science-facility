<#
.SYNOPSIS
    RS-scoped indentation normalizer.

.DESCRIPTION
    Normalizes leading-whitespace indentation in source code files via a small
    set of independently selectable ops applied in a fixed internal order.

    ISS-load-safe: no #Requires, top-level param contract (interior helpers
    permitted per colonel AST validation).

    Processor self-documentation (no runtime enforcement in this file):
        - Item contract:  tp-era Text envelope (unpacks Id/Path/Text and
          REPLACES the bag with its own envelope). Incompatible with
          code-track descriptor chains — consolidation item 6d. Chains fine
          with other tp-era processors.
        - Position class: content mutator
        - Intended Colonel IssPreset floor: Core
        - Required IssModules: none

.NOTES
        Config shape:
                    Operations: string[]  no defaults; processor is wholesale opt-in
                    IncludeMeta: bool     default true
                    TargetUnit:  int      spaces per indent level; default 2

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
        #   format-ws(lf) → rs-indent(detab) → rs-indent(strip-common, min-indent-2)
        # — works today as a tp-era chain (same Text-envelope contract on all
        # three); its use inside code-track descriptor chains is gated by the
        # contract harmonization (consolidation item 6d).
        # For now, specifying detab + strip-common in one call is safe but
        # strip-common will only see already-expanded depths from lines ending
        # in non-tab leading whitespace (the tab expansion from detab within
        # the same call happens after strip-common).

        # FUTURE: Markdown fenced code block support — apply detab/min-indent-2
        # only inside ``` fences, leaving prose lines untouched. This would
        # allow strip-common to be safely omitted for indented-code-block compat.
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
# Item unpacking
# ---------------------------------------------------------------------------
$text = $null
$path = $null
$id = $null

if ($Item -is [string])
{
    $text = $Item
}
elseif ($Item -is [hashtable])
{
    if ($Item.ContainsKey('Text')) { $text = [string]$Item['Text'] }
    if ($Item.ContainsKey('Path')) { $path = [string]$Item['Path'] }
    if ($Item.ContainsKey('Id')) { $id = [string]$Item['Id'] }
}
elseif ($Item -is [pscustomobject])
{
    if ($null -ne $Item.PSObject.Properties['Text']) { $text = [string]$Item.Text }
    if ($null -ne $Item.PSObject.Properties['Path']) { $path = [string]$Item.Path }
    if ($null -ne $Item.PSObject.Properties['Id']) { $id = [string]$Item.Id }
}

if ([string]::IsNullOrEmpty($text)) { $text = '' }

# ---------------------------------------------------------------------------
# Skip list — indentation normalization not appropriate for prose/markup
# ---------------------------------------------------------------------------
$ext = if ($path) { [IO.Path]::GetExtension($path).ToLowerInvariant() } else { '' }
$skipExts = @('.md', '.txt', '.rst', '.html', '.htm', '.xml', '.json', '.yaml', '.yml', '.toml', '.csv')

if ($ext -in $skipExts)
{
    if (-not $includeMeta) { return $text }
    return [pscustomobject]@{
        Id         = $id
        Path       = $path
        Text       = $text
        Operations = @($ops)
        Skipped    = $true
        Processor  = 'rs-indent'
    }
}

# Empty text early-return
if ($text -eq '')
{
    if (-not $includeMeta) { return '' }
    return [pscustomobject]@{
        Id         = $id
        Path       = $path
        Text       = ''
        Operations = @($ops)
        Processor  = 'rs-indent'
    }
}

# ---------------------------------------------------------------------------
# Gate resolution
# ---------------------------------------------------------------------------
$doStripCommon = 'strip-common' -in $ops
$doDetab = 'detab' -in $ops -or 'min-indent-2' -in $ops -or 'tabify' -in $ops
$doMinIndent = 'min-indent-2' -in $ops
$doTabify = 'tabify' -in $ops

$lines = $text -split "`n"
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
        $common = ($spaceLeads | Measure-Object -Minimum).Minimum
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
    $nonZero = @($depths | Where-Object { $_ -gt 0 })
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

$t = $lines -join "`n"

if (-not $includeMeta) { return $t }

return [pscustomobject]@{
    Id         = $id
    Path       = $path
    Text       = $t
    Operations = @($ops)
    Processor  = 'rs-indent'
}
