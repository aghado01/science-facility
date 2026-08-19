#Requires -Version 7.5

using namespace System.Text
using namespace System.Text.RegularExpressions
using namespace System.Collections.Generic

<#
.SYNOPSIS
    RepoSnapshot V3 container — the psr layout (piped snapshot rows): resolve
    the run's header-row layout once, then measure and render header row and
    record rows from that one object. One grammar site, three callers.

.DESCRIPTION
    Brief: issues/reposnapshot/briefs/shard-container-brief.md. Contract:
    contracts/container.contract.json. Declaration (READ HERE): contracts/container.spec.jsonc
    — the admissible column superset, framing constants, types, and the
    wire-name map (`source`, per its source_grammar).

    Export phase 0. `Resolve-Layout` is computed ONCE per run (admiral holds
    it) and consumed three times: shards sums `Measure-Row`; serialize writes
    `Build-Row`; manifest declares `HeaderRowText`. Plan and file cannot
    disagree because they were computed by the same function over the same
    pieces (`Format-Row`). Offsets are the WRITER's receipt — `Build-Row`
    returns them from its cursor; nothing derives an offset from a measure.

    Content codec (shard-format-notes §Content codec — SPEC): ONE rule table,
    two functions — `ConvertTo-ContentSpan` materializes, `Measure-ContentSpan` counts
    without materializing. Rules: every line terminator (LF, CRLF, CR, NEL,
    LS, PS, VT, FF) → the two characters `\n`; backslash is never doubled;
    remaining C0 controls and DEL are stripped; TAB stays literal. Under
    rs-whitespace `lf` upstream, rule 1 is a no-op in the code lane — it stays
    because the container owns the one-physical-line-per-row invariant and
    cannot assume a lane.

    Bytes are UTF-8 without BOM; the record terminator is LF alone (ledger #45).
    Header row = the schema; a record row is the header projected onto an
    entry — there is no row schema (ledger #34/#46).

    Public: Resolve-Layout · Measure-ContentSpan · ConvertTo-ContentSpan · Format-Row ·
    Measure-Row · Build-Row · Measure-HeaderRow · Build-HeaderRow.
#>

$script:DeclarationPath = Join-Path $PSScriptRoot 'contracts/container.spec.jsonc'
$script:Utf8 = [UTF8Encoding]::new($false)
$script:Invariant = [Globalization.CultureInfo]::InvariantCulture

# =============================================================================
# Codec — one rule table, two functions
# =============================================================================
# Group t: line terminators (order matters — \r\n before \r). Group s: strip
# set = C0 minus TAB(09) and minus the terminators already in t (0A 0B 0C 0D),
# plus DEL. Everything else passes verbatim, backslash included.
$script:CodecRegex = [regex]::new(
    '(?<t>\r\n|\r|\n|\u0085|\u2028|\u2029|\x0B|\x0C)|(?<s>[\x00-\x08\x0E-\x1F\x7F])',
    [RegexOptions]::Compiled)
$script:CodecBreak = '\n'      # two characters: backslash, n
$script:CodecBreakBytes = 2

function ConvertTo-ContentSpan
{
    <#
    .SYNOPSIS
        Materialize the encoded content span (codec SPEC rules 1–4).
    #>
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Content)
    if ([string]::IsNullOrEmpty($Content)) { return '' }
    return $script:CodecRegex.Replace($Content, [MatchEvaluator]{
        param($m)
        if ($m.Groups['t'].Success) { $script:CodecBreak } else { '' }
    })
}

function Measure-ContentSpan
{
    <#
    .SYNOPSIS
        UTF-8 byte width of ConvertTo-ContentSpan($Content) — counted, not materialized.
    .DESCRIPTION
        Whole-string byte count, then per match: a terminator becomes 2 bytes
        (delta = 2 − its own width), a stripped control becomes 0 (delta = −1).
        Every match is a BMP non-surrogate, so the remainder's byte count is
        untouched and the sum is exact against ConvertTo-ContentSpan.
    #>
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Content)
    if ([string]::IsNullOrEmpty($Content)) { return 0 }
    $bytes = $script:Utf8.GetByteCount($Content)
    foreach ($m in $script:CodecRegex.Matches($Content))
    {
        $own = $script:Utf8.GetByteCount($m.Value)
        if ($m.Groups['t'].Success) { $bytes += $script:CodecBreakBytes - $own } else { $bytes -= $own }
    }
    return $bytes
}

# =============================================================================
# Internals
# =============================================================================
function Get-Prop ([object]$Object, [string]$Name)
{
    # Null-safe property read over PSCustomObject / hashtable / anything with
    # a property. Returns $null when absent.
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary])
    {
        if ($Object.Contains($Name)) { return $Object[$Name] } else { return $null }
    }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -ne $p) { return $p.Value }
    return $null
}

function Resolve-EntryPath ([object]$Entry, [string[]]$Segments)
{
    $obj = $Entry
    foreach ($seg in $Segments)
    {
        $obj = Get-Prop $obj $seg
        if ($null -eq $obj) { return $null }
    }
    return $obj
}

function Get-DigitWidth ([long]$N)
{
    if ($N -le 0) { return 1 }
    return ([string]$N).Length
}

function Format-Value ([object]$Value, [string]$Type, [object]$Width, [PSCustomObject]$Layout, [string]$ColumnName)
{
    if ($null -eq $Value) { return $Layout.Framing.EmptyMarker }
    switch ($Type)
    {
        'int'
        {
            $s = ([long]$Value).ToString($script:Invariant)
            if ($null -ne $Width)
            {
                if ($s.Length -gt [int]$Width) { throw "rs.core.container: value '$s' exceeds the fixed width $Width declared for column '$ColumnName' — widths are plan-time bounds, never widened silently." }
                return $s.PadLeft([int]$Width, '0')
            }
            return $s
        }
        'float' { return ([double]$Value).ToString('F' + $Layout.FloatPrecision, $script:Invariant) }
        'str'   { return [string]$Value }
        default { throw "rs.core.container: unknown column type '$Type' for '$ColumnName'." }
    }
}

# =============================================================================
# PUBLIC — Resolve-Layout
# =============================================================================
function Resolve-Layout
{
    <#
    .SYNOPSIS
        Resolve the run's psr layout: admissible superset (container.spec.jsonc) ×
        run configuration (which optional columns / sub-fields are on) × the IR
        header (EntryCount → gidx width). Computed once; consumed by shards,
        serialize, manifest.

    .PARAMETER Header
        assemble.out.header — EntryCount and Elements are read.
    .PARAMETER Declaration
        Path to container.spec.jsonc (default: beside this module).
    .PARAMETER Columns
        Optional columns to enable (gidx, content_meta). Required columns
        cannot be disabled; naming one is a no-op; an inadmissible name throws.
    .PARAMETER MetaFields
        content_meta sub-fields to enable, rendered in declaration order.
        Default: the declaration's $default_on set. Inadmissible name throws.

    .OUTPUTS
        [PSCustomObject] layout — Format, Columns[], HeaderRowText, HeaderBytes,
        IdxWidth, Framing, FloatPrecision (container.contract.json out.layout).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object]$Header,
        [string]$Declaration = $script:DeclarationPath,
        [string[]]$Columns = @(),
        [string[]]$MetaFields = $null
    )

    if (-not (Test-Path -LiteralPath $Declaration)) { throw "Resolve-Layout: declaration not found: $Declaration" }
    $decl = Get-Content -LiteralPath $Declaration -Raw | ConvertFrom-Json -AsHashtable
    if ($decl.format -ne 'psr') { throw "Resolve-Layout: declaration '$Declaration' is not a psr header declaration (format = '$($decl.format)')." }

    $entryCount = [long](Get-Prop $Header 'EntryCount')

    # ── Framing (verbatim from the declaration) ──────────────────────────
    $f = $decl.framing
    $framing = [PSCustomObject]@{
        Encoding         = [string]$f.encoding
        Bom              = [bool]$f.bom
        RecordTerminator = [string]$f.record_terminator
        FieldDelimiter   = [string]$f.field_delimiter
        BlockOpen        = [string]$f.block.open
        BlockClose       = [string]$f.block.close
        BlockDelimiter   = [string]$f.block.field_delimiter
        EmptyMarker      = [string]$f.empty_marker
    }
    $floatPrecision = 4

    # ── Admissibility ────────────────────────────────────────────────────
    $declaredNames = @($decl.columns.Keys | Where-Object { $_ -notlike '$*' })
    foreach ($c in $Columns)
    {
        if ($c -notin $declaredNames) { throw "Resolve-Layout: column '$c' is not admissible — container.spec.jsonc declares: $($declaredNames -join ', ')" }
    }

    # ── Columns, in wire (declaration) order ─────────────────────────────
    $cols = [List[object]]::new()
    $idxWidth = 0
    $metaOn = $false
    foreach ($name in $declaredNames)
    {
        $c = $decl.columns[$name]
        $on = ([string]$c.presence -eq 'required') -or ($Columns -contains $name)
        if (-not $on) { continue }

        $width = $null
        if ($c.ContainsKey('width'))
        {
            $w = [string]$c.width
            if ($w -eq 'digits(EntryCount)') { $width = Get-DigitWidth $entryCount }
            elseif ($w -match '^\d+$')      { $width = [int]$w }
            else { throw "Resolve-Layout: column '$name' declares an unknown width rule '$w'." }
        }
        if ($name -eq 'gidx') { $idxWidth = $width }

        $fields = $null
        if ([string]$c.type -eq 'block')
        {
            $metaOn = $true
            $admissible = @($c.fields.Keys | Where-Object { $_ -notlike '$*' })
            $wanted = if ($null -eq $MetaFields) { @($c.'$default_on') } else { @($MetaFields) }
            foreach ($mf in $wanted)
            {
                if ($mf -notin $admissible) { throw "Resolve-Layout: content_meta sub-field '$mf' is not admissible — container.spec.jsonc declares: $($admissible -join ', ')" }
            }
            $fl = [List[object]]::new()
            foreach ($fname in $admissible)   # declaration order, not request order
            {
                if ($fname -notin $wanted) { continue }
                $fd = $c.fields[$fname]
                $fl.Add([PSCustomObject]@{ Name = $fname; Type = [string]$fd.type; Width = $null; Role = 'content'; Source = [string]$fd.source; Fields = $null })
            }
            $fields = $fl.ToArray()
        }

        $cols.Add([PSCustomObject]@{
            Name   = $name
            Type   = [string]$c.type
            Width  = $width
            Role   = [string]$c.role
            Source = [string]$c.source
            Fields = $fields
        })
    }

    # ── Invariants the declaration promises (checked, not assumed) ───────
    $names = @($cols | ForEach-Object Name)
    if ($names[-1] -ne 'content') { throw "Resolve-Layout: 'content' must be the last column (got '$($names[-1])')." }
    if ($names.Count -lt 2 -or $names[-2] -ne 'content_bytes') { throw "Resolve-Layout: 'content_bytes' must immediately precede 'content'." }

    # ── Header row text + bytes ──────────────────────────────────────────
    $pieces = foreach ($col in $cols)
    {
        if ($col.Type -eq 'block')
        {
            $sub = @($col.Fields | ForEach-Object { "$($_.Name)<$($_.Type)>" }) -join $framing.BlockDelimiter
            "$($col.Name):$($framing.BlockOpen)$sub$($framing.BlockClose)"
        }
        else
        {
            $ann = if ($null -ne $col.Width) { "$($col.Type):$($col.Width)" } else { $col.Type }
            "$($col.Name)<$ann>"
        }
    }
    $headerText = @($pieces) -join $framing.FieldDelimiter
    $headerBytes = $script:Utf8.GetByteCount($headerText) + $script:Utf8.GetByteCount($framing.RecordTerminator)

    # ── Presence warning (never decides the layout) ──────────────────────
    if ($metaOn)
    {
        $el = Get-Prop $Header 'Elements'
        $cm = Get-Prop $el 'ContentMeta'
        if ($null -eq $cm)
        {
            Write-Warning "Resolve-Layout: content_meta is enabled but Header.Elements declares no ContentMeta — every row will render the block with empty markers (is rs-content_meta in the profile?)."
        }
        else
        {
            $count = [long](Get-Prop $cm 'Count'); $total = [long](Get-Prop $cm 'Total')
            if ($count -lt $total) { Write-Warning "Resolve-Layout: ContentMeta present on $count of $total entries — rows lacking it render the block with empty markers." }
        }
    }

    return [PSCustomObject]@{
        Format         = 'psr'
        Columns        = $cols.ToArray()
        HeaderRowText  = $headerText
        HeaderBytes    = $headerBytes
        IdxWidth       = $idxWidth
        Framing        = $framing
        FloatPrecision = $floatPrecision
    }
}

# =============================================================================
# PUBLIC — Format-Row (pieces) → Measure-Row (sum) / Build-Row (bytes + receipt)
# =============================================================================
function Format-Row
{
    <#
    .SYNOPSIS
        The one layout function: project the resolved header onto an entry.
        Returns every column's rendered text EXCEPT content (which is never
        materialized here), plus the measured content byte width.
    .OUTPUTS
        @{ Pieces = string[] (all columns but content, wire order);
           ContentBytes = int; Content = the raw content string }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [PSCustomObject]$Layout,
        [Parameter(Mandatory)] [object]$Entry,
        [AllowNull()] [object]$GlobalIdx = $null
    )
    $content = Get-Prop $Entry 'Content'
    if ($null -eq $content) { $content = '' }
    $contentBytes = Measure-ContentSpan -Content ([string]$content)

    $pieces = [List[string]]::new()
    foreach ($col in $Layout.Columns)
    {
        if ($col.Source -eq 'codec.text') { continue }   # content — rendered by Build-Row only

        if ($col.Type -eq 'block')
        {
            $subs = foreach ($fld in $col.Fields)
            {
                $v = Resolve-SourceValue -Source $fld.Source -Entry $Entry -GlobalIdx $GlobalIdx -ContentBytes $contentBytes
                Format-Value $v $fld.Type $null $Layout $fld.Name
            }
            $pieces.Add("$($Layout.Framing.BlockOpen)$(@($subs) -join $Layout.Framing.BlockDelimiter)$($Layout.Framing.BlockClose)")
            continue
        }

        $v = Resolve-SourceValue -Source $col.Source -Entry $Entry -GlobalIdx $GlobalIdx -ContentBytes $contentBytes
        $pieces.Add((Format-Value $v $col.Type $col.Width $Layout $col.Name))
    }
    return @{ Pieces = $pieces.ToArray(); ContentBytes = $contentBytes; Content = [string]$content }
}

function Resolve-SourceValue ([string]$Source, [object]$Entry, [object]$GlobalIdx, [int]$ContentBytes)
{
    # container.spec.jsonc source_grammar — exactly four forms.
    if ($Source -eq 'plan.GlobalIdx') { return $GlobalIdx }
    if ($Source -eq 'codec.bytes')    { return $ContentBytes }
    if ($Source -eq 'codec.text')     { throw "rs.core.container: codec.text is materialized only by Build-Row." }
    if ($Source -like 'entry.*')      { return Resolve-EntryPath $Entry ($Source.Substring(6) -split '\.') }
    throw "rs.core.container: unknown source '$Source' — container.spec.jsonc source_grammar allows entry.<path>, plan.GlobalIdx, codec.bytes, codec.text."
}

function Measure-Row
{
    <#
    .SYNOPSIS
        Exact serialized byte width of an entry's row under this layout —
        without rendering content. Shards' packing input.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [PSCustomObject]$Layout,
        [Parameter(Mandatory)] [object]$Entry
    )
    # gidx is fixed-width, so its value is irrelevant to the measure — 0 is a
    # valid stand-in of the same width.
    $f = Format-Row -Layout $Layout -Entry $Entry -GlobalIdx 0
    $d = $script:Utf8.GetByteCount($Layout.Framing.FieldDelimiter)
    $bytes = 0
    foreach ($p in $f.Pieces) { $bytes += $script:Utf8.GetByteCount($p) }
    $bytes += $d * $f.Pieces.Count            # one delimiter after every prefix piece (the last precedes content)
    $bytes += $f.ContentBytes
    $bytes += $script:Utf8.GetByteCount($Layout.Framing.RecordTerminator)
    return $bytes
}

function Build-Row
{
    <#
    .SYNOPSIS
        Build an entry's row — the bytes at a cursor plus the writer's
        receipt (serialize writes the bytes; nothing here touches a stream): the bytes and the offsets they occupy (LTS semantics: 0-based,
        end offsets INCLUSIVE; RowContentEnd == RowContentBegin when empty).
    .OUTPUTS
        @{ Bytes; RowOffset; RowMetaEnd; RowContentBegin; RowContentEnd;
           ContentBytes; NextCursor }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [PSCustomObject]$Layout,
        [Parameter(Mandatory)] [object]$Entry,
        [Parameter(Mandatory)] [long]$Cursor,
        [AllowNull()] [object]$GlobalIdx = $null
    )
    if ($Layout.IdxWidth -gt 0 -and $null -eq $GlobalIdx) { throw "Build-Row: layout has gidx enabled — GlobalIdx is required." }
    $f = Format-Row -Layout $Layout -Entry $Entry -GlobalIdx $GlobalIdx
    $D = $Layout.Framing.FieldDelimiter
    $prefix = @($f.Pieces) -join $D
    $encoded = ConvertTo-ContentSpan -Content $f.Content
    $text = $prefix + $D + $encoded + $Layout.Framing.RecordTerminator
    $bytes = $script:Utf8.GetBytes($text)

    $prefixBytes = $script:Utf8.GetByteCount($prefix)
    $dBytes = $script:Utf8.GetByteCount($D)
    $contentBegin = $Cursor + $prefixBytes + $dBytes
    $contentEnd = if ($f.ContentBytes -gt 0) { $contentBegin + $f.ContentBytes - 1 } else { $contentBegin }
    return @{
        Bytes           = $bytes
        RowOffset       = $Cursor
        RowMetaEnd      = $Cursor + $prefixBytes - 1
        RowContentBegin = $contentBegin
        RowContentEnd   = $contentEnd
        ContentBytes    = $f.ContentBytes
        NextCursor      = $Cursor + $bytes.Length
    }
}

# =============================================================================
# PUBLIC — header row pair
# =============================================================================
function Measure-HeaderRow
{
    [CmdletBinding()]
    param([Parameter(Mandatory)] [PSCustomObject]$Layout)
    return $Layout.HeaderBytes
}

function Build-HeaderRow
{
    [CmdletBinding()]
    param([Parameter(Mandatory)] [PSCustomObject]$Layout)
    return $script:Utf8.GetBytes($Layout.HeaderRowText + $Layout.Framing.RecordTerminator)
}

Export-ModuleMember -Function @(
    'Resolve-Layout', 'Measure-ContentSpan', 'ConvertTo-ContentSpan', 'Format-Row',
    'Measure-Row', 'Build-Row', 'Measure-HeaderRow', 'Build-HeaderRow'
)
