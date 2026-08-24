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
    — the admissible column superset under `shard_container_schema.properties`,
    the join rule, types, and the `$ref` crosswalk that binds each column to
    its in-memory value. This module is the declaration's INTERPRETER: nothing
    about the wire is hardcoded here that the spec states.

    THE WIRE (spec §item_join, ledger #49): a row is a list of ITEMS joined by
    exactly one space. Items are values, keys (a key carries its trailing
    colon), and the marks `|` `[` `]` `,`. A sub-grammar with its own syntax —
    a type expression `int(4)`, the encoded content span — renders itself first
    and enters as ONE item. Hence `row bytes = Σ item bytes + (item count − 1)
    + terminator`, exact by construction with nothing hidden inside a
    concatenation, and hence there is no padding constant anywhere below.

    Export phase 0. `Resolve-Layout` is computed ONCE per run (admiral holds
    it) and consumed three times: shards sums `Measure-Row`; serialize writes
    `Build-Row`; manifest declares `HeaderRowText`. Plan and file cannot
    disagree because they were computed by the same function over the same
    items (`Format-Row`). Offsets are the WRITER's receipt — `Build-Row`
    returns them from its cursor; nothing derives an offset from a measure.

    Content codec (shard-format-notes §Content codec — SPEC): ONE rule table,
    two functions — `ConvertTo-ContentSpan` materializes, `Measure-ContentSpan` counts
    without materializing. Rules: every line terminator (LF, CRLF, CR, NEL,
    LS, PS, VT, FF) → the two-character mark `\n`, a PURE SUBSTITUTION — one
    symbol for one symbol, no spacing logic in the encoder (user, 2026-08-24).
    The wire's regular mark environment (` \n ` line break, ` \n\n ` blank
    line, no space after the document-final mark) is CONTENT preparation:
    rs-whitespace's `pad-breaks` op inserts one space between any solid
    character and an adjacent newline, both directions, upstream of encoding.
    Regularity is the criterion — the mark tokenizes identically in every
    context — and three stations never cross: rs-whitespace shapes content
    whitespace, this codec substitutes symbols, the row join spaces row items
    (#49). Backslash is never doubled (a source-literal `\n` stays unspaced —
    distinguishable from a real break); remaining C0 controls and DEL are
    stripped; TAB stays literal. The container owns the
    one-physical-line-per-row invariant and cannot assume a lane.

    Bytes are UTF-8 without BOM; the record terminator is LF alone (ledger #45).
    Header row = the schema; a record row is the header projected onto an
    entry — there is no row schema (ledger #34/#46).

    Public: Resolve-Layout · Measure-ContentSpan · ConvertTo-ContentSpan · Format-Row ·
    Measure-Row · Build-Row · Measure-HeaderRow · Build-HeaderRow.
#>

$script:DeclarationPath = Join-Path $PSScriptRoot 'contracts/container.spec.jsonc'
$script:Utf8 = [UTF8Encoding]::new($false)
$script:Invariant = [Globalization.CultureInfo]::InvariantCulture
$script:ContractCache = @{}   # $ref targets, parsed once per session

# =============================================================================
# Codec — one rule table, two functions
# =============================================================================
# Group t: line terminators (order matters — \r\n before \r). Group s: strip
# set = C0 minus TAB(09) and minus the terminators already in t (0A 0B 0C 0D),
# plus DEL. Everything else passes verbatim, backslash included.
#
# THE ENCODER IS A PURE SUBSTITUTION (station settled by the user,
# 2026-08-24): one terminator becomes the one two-character symbol '\n',
# nothing else — the mark is a single object to this operation, and no
# spacing logic lives here. The spacing that puts every mark in a regular
# space-flanked environment on the wire is CONTENT preparation, and content
# is rs-whitespace's job: its `pad-breaks` op (defaults, runs last) inserts
# one space between any solid character and an adjacent newline, both
# directions, before encoding ever happens. Three stations, never crossed:
# rs-whitespace shapes content whitespace · this codec substitutes symbols ·
# the row join spaces row items (#49).
$script:CodecRegex = [regex]::new(
    '(?<t>\r\n|\r|\n|\u0085|\u2028|\u2029|\x0B|\x0C)|(?<s>[\x00-\x08\x0E-\x1F\x7F])',
    [RegexOptions]::Compiled)
$script:CodecMark = '\n'       # two characters: one symbol, substituted verbatim
$script:CodecMarkBytes = 2

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
        if ($m.Groups['t'].Success) { $script:CodecMark } else { '' }
    })
}

function Measure-ContentSpan
{
    <#
    .SYNOPSIS
        UTF-8 byte width of ConvertTo-ContentSpan($Content) — counted, not materialized.
    .DESCRIPTION
        Whole-string byte count, then per match: a terminator becomes the
        2-byte mark (delta = 2 − its own width), a stripped control becomes 0
        (delta = −1). Every match is a BMP non-surrogate, so the remainder's
        byte count is untouched and the sum is exact against
        ConvertTo-ContentSpan.
    #>
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Content)
    if ([string]::IsNullOrEmpty($Content)) { return 0 }
    $bytes = $script:Utf8.GetByteCount($Content)
    foreach ($m in $script:CodecRegex.Matches($Content))
    {
        $own = $script:Utf8.GetByteCount($m.Value)
        if ($m.Groups['t'].Success) { $bytes += $script:CodecMarkBytes - $own } else { $bytes -= $own }
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
    # Types are the declaration's record_type / val_type vocabulary.
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
        'double' { return ([double]$Value).ToString('F' + $Layout.DoublePrecision, $script:Invariant) }
        'string' { return [string]$Value }
        default  { throw "rs.core.container: unknown type '$Type' for '$ColumnName' — container.spec.jsonc declares int, double, string." }
    }
}

# ── Declaration interpreter: scope resolution, template expansion, $ref crosswalk ──
function Resolve-ScopePath ([object]$Scope, [string]$Path, [string]$Where)
{
    # ${a.b} descends. Scope ascent is done by the CALLER, which passes a scope
    # already chained down from shard_container_schema (spec §conventions SCOPE).
    $cur = $Scope
    foreach ($k in ($Path -split '\.'))
    {
        $next = Get-Prop $cur $k
        if ($null -eq $next) { throw "rs.core.container: template reference '`${$Path}' does not resolve at $Where — container.spec.jsonc declares no '$k' in that scope." }
        $cur = $next
    }
    return $cur
}

function Expand-TemplateItems ([object[]]$Template, [object]$Scope, [string]$Where)
{
    # A *_template is an ARRAY of item expressions: each resolves to one item,
    # or SPLICES when it resolves to a list. Values are inserted VERBATIM. The
    # renderer joins later — templates never carry their own spacing.
    $out = [List[string]]::new()
    foreach ($e in $Template)
    {
        $s = [string]$e
        if ($s -match '^\$\{([^}]+)\}$')
        {
            $v = Resolve-ScopePath $Scope $Matches[1] $Where
            if ($v -is [System.Collections.IEnumerable] -and $v -isnot [string])
            {
                foreach ($i in $v) { $out.Add([string]$i) }
                continue
            }
            $out.Add([string]$v)
            continue
        }
        while ($s -match '\$\{([^}]+)\}')
        {
            $key = $Matches[1]
            $s = $s.Replace('${' + $key + '}', [string](Resolve-ScopePath $Scope $key $Where))
        }
        $out.Add($s)
    }
    return $out.ToArray()
}

function Resolve-RefAccessor ([string]$Ref, [string]$SpecDir, [string]$Where)
{
    # container.spec.jsonc §conventions: a $ref points at the source-of-truth
    # contract for the in-memory value; the accessor is DERIVED from the
    # pointer, and an unresolvable pointer is a load-time failure — the
    # declaration is not allowed to name a value no contract carries.
    $split = $Ref -split '#', 2
    if ($split.Count -ne 2) { throw "rs.core.container: '$Ref' at $Where is not a '<file>#/<pointer>' reference." }
    $file = $split[0]
    $segs = @(($split[1].TrimStart('/')) -split '/' | Where-Object { $_ -ne '' })

    $target = Join-Path $SpecDir $file
    if (-not (Test-Path -LiteralPath $target))
    {
        # processors/* refs are module-root relative; contract refs sit beside the spec.
        $target = Join-Path (Split-Path -Parent $SpecDir) $file
        if (-not (Test-Path -LiteralPath $target)) { throw "rs.core.container: '$Ref' at $Where names a contract that does not exist ($file)." }
    }
    if (-not $script:ContractCache.ContainsKey($target))
    {
        $script:ContractCache[$target] = Get-Content -LiteralPath $target -Raw | ConvertFrom-Json -AsHashtable
    }
    $node = $script:ContractCache[$target]
    foreach ($s in $segs)
    {
        $node = Get-Prop $node $s
        if ($null -eq $node) { throw "rs.core.container: '$Ref' at $Where does not resolve — $file has no /$($segs -join '/')." }
    }

    # Derivation table (spec §conventions): assemble → entry.<tail past the
    # bucket>; shards → plan.<leaf>; container → codec.<leaf>; processors/* →
    # entry.<tail past 'out'>.
    switch -Wildcard ($file)
    {
        'assemble.contract.json'  { return 'entry.' + (@($segs[3..($segs.Count - 1)]) -join '.') }
        'shards.contract.json'    { return 'plan.'  + $segs[-1] }
        'container.contract.json' { return 'codec.' + $segs[-1] }
        'processors/*'            { return 'entry.' + (@($segs[1..($segs.Count - 1)]) -join '.') }
        default { throw "rs.core.container: '$Ref' at $Where points at $file, which has no accessor derivation — container.spec.jsonc §conventions lists assemble, shards, container, processors/*." }
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
        content_meta sub-fields to enable, rendered in val_rank order.
        Default: the sub-fields marked `default: true`. Inadmissible name throws.

    .OUTPUTS
        [PSCustomObject] layout — Format, Columns[], HeaderRowText, HeaderBytes,
        IdxWidth, Framing, DoublePrecision (container.contract.json out.layout).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object]$Header,
        [string]$Declaration = $script:DeclarationPath,
        [string[]]$Columns = @(),
        [string[]]$MetaFields = $null
    )

    if (-not (Test-Path -LiteralPath $Declaration)) { throw "Resolve-Layout: declaration not found: $Declaration" }
    $specDir = Split-Path -Parent (Resolve-Path -LiteralPath $Declaration).Path
    $decl = Get-Content -LiteralPath $Declaration -Raw | ConvertFrom-Json -AsHashtable
    if ($decl.format -ne 'psr') { throw "Resolve-Layout: declaration '$Declaration' is not a psr header declaration (format = '$($decl.format)')." }
    $schema = $decl.shard_container_schema
    if ($null -eq $schema) { throw "Resolve-Layout: '$Declaration' declares no shard_container_schema — this module reads spec v0.3+ (top-level: format, properties, conventions, shard_container_schema, invariants)." }

    $entryCount = [long](Get-Prop $Header 'EntryCount')

    # ── Framing: the wire constants, verbatim from the declaration ───────
    # Under ledger #49 the marks are ITEMS, so there is no field delimiter and
    # no block open/close/delimiter here — only the separator character, the
    # join, and the record terminator.
    $framing = [PSCustomObject]@{
        Encoding        = [string]$decl.properties.encoding
        Bom             = [bool]$decl.properties.bom
        RecordDelimiter = [string]$schema.record_delimiter
        ColumnSeparator = [string]$schema.column_separator
        ItemJoin        = [string]$schema.item_join
        EmptyMarker     = [string]$schema.empty_marker
    }
    $doublePrecision = [int]$decl.properties.double_precision

    # ── Admissibility, in col_position order (the declared wire order) ───
    $register = $schema.properties
    $declaredNames = @($register.Keys | Where-Object { $_ -notlike '$*' } | Sort-Object { [int]$register[$_].col_position })
    foreach ($c in $Columns)
    {
        if ($c -notin $declaredNames) { throw "Resolve-Layout: column '$c' is not admissible — container.spec.jsonc declares: $($declaredNames -join ', ')" }
    }

    $cols = [List[object]]::new()
    $idxWidth = 0
    $metaOn = $false
    foreach ($name in $declaredNames)
    {
        $c = $register[$name]
        $on = ([bool]$c.required) -or ($Columns -contains $name)
        if (-not $on) { continue }

        # Computed forms resolve BEFORE anything interpolates them (spec §ORDER).
        $width = $null
        if ($c.ContainsKey('record_width'))
        {
            $w = [string]$c.record_width
            if ($w -eq 'digits(EntryCount)') { $width = Get-DigitWidth $entryCount }
            elseif ($w -match '^\d+$')      { $width = [int]$w }
            else { throw "Resolve-Layout: column '$name' declares an unknown width rule '$w'." }
        }
        if ($name -eq 'gidx') { $idxWidth = $width }

        $fields = $null; $enclosure = $null; $valSeparator = $null
        if ([string]$c.record_type -eq 'array')
        {
            $metaOn = $true
            $enclosure = [PSCustomObject]@{ Start = [string]$c.record_val_enclosure.start; End = [string]$c.record_val_enclosure.end }
            $valSeparator = [string]$c.val_separator
            $subReg = $c.properties
            $admissible = @($subReg.Keys | Where-Object { $_ -notlike '$*' } | Sort-Object { [int]$subReg[$_].val_rank })
            $wanted = if ($null -eq $MetaFields) { @($admissible | Where-Object { [bool]$subReg[$_]['default'] }) } else { @($MetaFields) }
            foreach ($mf in $wanted)
            {
                if ($mf -notin $admissible) { throw "Resolve-Layout: content_meta sub-field '$mf' is not admissible — container.spec.jsonc declares: $($admissible -join ', ')" }
            }
            $fl = [List[object]]::new()
            foreach ($fname in $admissible)   # val_rank order, not request order
            {
                if ($fname -notin $wanted) { continue }
                $fd = $subReg[$fname]
                $fl.Add([PSCustomObject]@{
                    Name   = $fname
                    Type   = [string]$fd.val_type
                    Width  = $null
                    Source = (Resolve-RefAccessor ([string]$fd.val.'$ref') $specDir "content_meta.$fname")
                    Fields = $null
                })
            }
            $fields = $fl.ToArray()
        }

        $cols.Add([PSCustomObject]@{
            Name         = $name
            Type         = [string]$c.record_type
            Width        = $width
            Source       = (Resolve-RefAccessor ([string]$c.record_value.'$ref') $specDir "column $name")
            Fields       = $fields
            Enclosure    = $enclosure
            ValSeparator = $valSeparator
        })
    }

    # ── Invariants the declaration promises (checked, not assumed) ───────
    $names = @($cols | ForEach-Object Name)
    if ($names.Count -eq 0) { throw "Resolve-Layout: the declaration resolved to zero columns — container.spec.jsonc marks none required." }
    if ($names[-1] -ne 'content') { throw "Resolve-Layout: 'content' must be the last column (got '$($names[-1])')." }
    if ($names.Count -lt 2 -or $names[-2] -ne 'content_bytes') { throw "Resolve-Layout: 'content_bytes' must immediately precede 'content'." }

    # ── Header row: items from the declared templates, joined once ───────
    $headerItems = [List[string]]::new()
    foreach ($col in $cols)
    {
        if ($headerItems.Count -gt 0) { $headerItems.Add($framing.ColumnSeparator) }

        # The templates live on shard_container_schema but resolve against the
        # COLUMN being rendered (spec §conventions SCOPE); ${item_join} and
        # friends ascend by being chained in behind it.
        $scope = @{ name = $col.Name; record_type = $col.Type }
        if ($null -ne $col.Width) { $scope['record_width'] = $col.Width }
        if ($col.Type -eq 'array')
        {
            $scope['record_val_enclosure'] = @{ start = $col.Enclosure.Start; end = $col.Enclosure.End }
            $cells = [List[string]]::new()
            foreach ($fld in $col.Fields)
            {
                if ($cells.Count -gt 0) { $cells.Add($col.ValSeparator) }
                $cells.Add("$($fld.Name):")
                $cells.Add($fld.Type)
            }
            $scope['cells'] = $cells.ToArray()
            $tpl = $schema.header_block_template
        }
        elseif ($null -ne $col.Width) { $tpl = $schema.header_cell_width_template }
        else                          { $tpl = $schema.header_cell_template }

        foreach ($i in (Expand-TemplateItems $tpl $scope "column $($col.Name)")) { $headerItems.Add($i) }
    }
    $headerText = @($headerItems) -join $framing.ItemJoin
    $headerBytes = $script:Utf8.GetByteCount($headerText) + $script:Utf8.GetByteCount($framing.RecordDelimiter)

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
        Format          = 'psr'
        Columns         = $cols.ToArray()
        HeaderRowText   = $headerText
        HeaderBytes     = $headerBytes
        IdxWidth        = $idxWidth
        Framing         = $framing
        DoublePrecision = $doublePrecision
    }
}

# =============================================================================
# PUBLIC — Format-Row (pieces) → Measure-Row (sum) / Build-Row (bytes + receipt)
# =============================================================================
function Format-Row
{
    <#
    .SYNOPSIS
        The one layout function: project the resolved header onto an entry as
        an ITEM LIST (ledger #49). Content is never materialized here.
    .DESCRIPTION
        Items run from the first column up to and INCLUDING content_bytes'
        value — the separator before content and the content span itself are
        Build-Row's, so `Items -join ItemJoin` is exactly the row prefix whose
        last byte is RowMetaEnd. Marks are items: `|` between columns, and
        `[` … `,` … `]` around and between a block's values.
    .OUTPUTS
        @{ Items = string[] (through content_bytes, in wire order);
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

    $items = [List[string]]::new()
    foreach ($col in $Layout.Columns)
    {
        if ($col.Source -eq 'codec.text') { continue }   # content — Build-Row's, separator included
        if ($items.Count -gt 0) { $items.Add($Layout.Framing.ColumnSeparator) }

        if ($col.Type -eq 'array')
        {
            $items.Add($col.Enclosure.Start)
            $first = $true
            foreach ($fld in $col.Fields)
            {
                if (-not $first) { $items.Add($col.ValSeparator) }
                $first = $false
                $v = Resolve-SourceValue -Source $fld.Source -Entry $Entry -GlobalIdx $GlobalIdx -ContentBytes $contentBytes
                $items.Add((Format-Value $v $fld.Type $null $Layout $fld.Name))
            }
            $items.Add($col.Enclosure.End)
            continue
        }

        $v = Resolve-SourceValue -Source $col.Source -Entry $Entry -GlobalIdx $GlobalIdx -ContentBytes $contentBytes
        $items.Add((Format-Value $v $col.Type $col.Width $Layout $col.Name))
    }
    return @{ Items = $items.ToArray(); ContentBytes = $contentBytes; Content = [string]$content }
}

function Resolve-SourceValue ([string]$Source, [object]$Entry, [object]$GlobalIdx, [int]$ContentBytes)
{
    # Accessors are DERIVED by Resolve-RefAccessor from the declaration's $ref
    # crosswalk; the four shapes below are the whole vocabulary it can emit.
    if ($Source -eq 'plan.GlobalIdx') { return $GlobalIdx }
    if ($Source -eq 'codec.bytes')    { return $ContentBytes }
    if ($Source -eq 'codec.text')     { throw "rs.core.container: codec.text is materialized only by Build-Row." }
    if ($Source -like 'entry.*')      { return Resolve-EntryPath $Entry ($Source.Substring(6) -split '\.') }
    throw "rs.core.container: unknown accessor '$Source' — the $ref derivation yields entry.<path>, plan.GlobalIdx, codec.bytes, codec.text."
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
    # Ledger #49: row bytes = Σ item bytes + (item count − 1) joins + terminator.
    # The full list is Items + the separator before content + content itself,
    # so there are Items.Count + 2 items and Items.Count + 1 joins.
    $join = $script:Utf8.GetByteCount($Layout.Framing.ItemJoin)
    $bytes = 0
    foreach ($p in $f.Items) { $bytes += $script:Utf8.GetByteCount($p) }
    $bytes += $script:Utf8.GetByteCount($Layout.Framing.ColumnSeparator)
    $bytes += $f.ContentBytes
    $bytes += $join * ($f.Items.Count + 1)
    $bytes += $script:Utf8.GetByteCount($Layout.Framing.RecordDelimiter)
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
    $J = $Layout.Framing.ItemJoin
    $prefix = @($f.Items) -join $J                       # … | content_bytes
    $encoded = ConvertTo-ContentSpan -Content $f.Content
    $text = $prefix + $J + $Layout.Framing.ColumnSeparator + $J + $encoded + $Layout.Framing.RecordDelimiter
    $bytes = $script:Utf8.GetBytes($text)

    $prefixBytes = $script:Utf8.GetByteCount($prefix)
    $leadBytes = (2 * $script:Utf8.GetByteCount($J)) + $script:Utf8.GetByteCount($Layout.Framing.ColumnSeparator)
    $contentBegin = $Cursor + $prefixBytes + $leadBytes
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
    return $script:Utf8.GetBytes($Layout.HeaderRowText + $Layout.Framing.RecordDelimiter)
}

Export-ModuleMember -Function @(
    'Resolve-Layout', 'Measure-ContentSpan', 'ConvertTo-ContentSpan', 'Format-Row',
    'Measure-Row', 'Build-Row', 'Measure-HeaderRow', 'Build-HeaderRow'
)
