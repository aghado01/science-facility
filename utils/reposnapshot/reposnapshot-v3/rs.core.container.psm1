#Requires -Version 7.5

using namespace System.Text
using namespace System.Text.RegularExpressions
using namespace System.Collections.Generic

<#
.SYNOPSIS
    RepoSnapshot V3 container — the psr (piped snapshot rows) layout interpreter.

.DESCRIPTION
    Interprets contracts/container.spec.jsonc to format, measure, and serialize
    header and record rows in the psr wire format.

    Key functions:
      Resolve-Layout: Resolves the run's layout and column schema once per run.
      ConvertTo-ContentSpan / Measure-ContentSpan: Encodes and measures content spans.
      Format-Row / Measure-Row / Build-Row: Formats, measures, and builds record rows.
      Measure-HeaderRow / Build-HeaderRow: Measures and builds the header row.

    See docs/container-and-wire.md for layout and codec specifications.
#>

$script:DeclarationPath = Join-Path $PSScriptRoot 'contracts/container.spec.jsonc'
$script:Utf8 = [UTF8Encoding]::new($false)
$script:Invariant = [Globalization.CultureInfo]::InvariantCulture
$script:ContractCache = @{}   # $ref targets, parsed once per session

#region Codec
# Pure symbol substitution: replaces line breaks with '\n' and strips unprintable controls.
$script:CodecRegex = [regex]::new(
    '(?<t>\r\n|\r|\n|\u0085|\u2028|\u2029|\x0B|\x0C)|(?<s>[\x00-\x08\x0E-\x1F\x7F])',
    [RegexOptions]::Compiled)
$script:CodecMark = '\n'
$script:CodecMarkBytes = 2

function ConvertTo-ContentSpan
{
    <#
    .SYNOPSIS
        Materialize the encoded content span.
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
        Count UTF-8 byte width of ConvertTo-ContentSpan($Content) without materializing.
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
#endregion

#region Internals
function Get-Prop ([object]$Object, [string]$Name)
{
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
                if ($s.Length -gt [int]$Width) { throw "rs.core.container: value '$s' exceeds fixed width $Width declared for column '$ColumnName'." }
                return $s.PadLeft([int]$Width, '0')
            }
            return $s
        }
        'double' { return ([double]$Value).ToString('F' + $Layout.DoublePrecision, $script:Invariant) }
        'string' { return [string]$Value }
        default  { throw "rs.core.container: unknown type '$Type' for '$ColumnName'." }
    }
}

function Resolve-ScopePath ([object]$Scope, [string]$Path, [string]$Where)
{
    $cur = $Scope
    foreach ($k in ($Path -split '\.'))
    {
        $next = Get-Prop $cur $k
        if ($null -eq $next) { throw "rs.core.container: template reference '`${$Path}' does not resolve at $Where." }
        $cur = $next
    }
    return $cur
}

function Expand-TemplateItems ([object[]]$Template, [object]$Scope, [string]$Where)
{
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
    $split = $Ref -split '#', 2
    if ($split.Count -ne 2) { throw "rs.core.container: '$Ref' at $Where is not a '<file>#/<pointer>' reference." }
    $file = $split[0]
    $segs = @(($split[1].TrimStart('/')) -split '/' | Where-Object { $_ -ne '' })

    $target = Join-Path $SpecDir $file
    if (-not (Test-Path -LiteralPath $target))
    {
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

    switch -Wildcard ($file)
    {
        'assemble.contract.json'  { return 'entry.' + (@($segs[3..($segs.Count - 1)]) -join '.') }
        'shards.contract.json'    { return 'plan.'  + $segs[-1] }
        'container.contract.json' { return 'codec.' + $segs[-1] }
        'rs-*.contract.json'      { return 'entry.' + (@($segs[1..($segs.Count - 1)]) -join '.') }
        default { throw "rs.core.container: '$Ref' at $Where points at $file, which has no accessor derivation." }
    }
}
#endregion

#region Resolve-Layout
function Resolve-Layout
{
    <#
    .SYNOPSIS
        Resolves the run's psr layout from specification and parameters.

    .PARAMETER Header
        The assembled IR header (EntryCount and Elements).

    .PARAMETER Declaration
        Path to container.spec.jsonc.

    .PARAMETER Columns
        Optional columns to enable (e.g. gidx, content_meta).

    .PARAMETER MetaFields
        content_meta sub-fields to enable.

    .OUTPUTS
        [PSCustomObject] layout description.
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
    if ($null -eq $schema) { throw "Resolve-Layout: '$Declaration' declares no shard_container_schema." }

    $entryCount = [long](Get-Prop $Header 'EntryCount')

    $framing = [PSCustomObject]@{
        Encoding        = [string]$decl.properties.encoding
        Bom             = [bool]$decl.properties.bom
        RecordDelimiter = [string]$schema.record_delimiter
        ColumnSeparator = [string]$schema.column_separator
        ItemJoin        = [string]$schema.item_join
        EmptyMarker     = [string]$schema.empty_marker
    }
    $doublePrecision = [int]$decl.properties.double_precision

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
            foreach ($fname in $admissible)
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

    $names = @($cols | ForEach-Object Name)
    if ($names.Count -eq 0) { throw "Resolve-Layout: resolved to zero columns." }
    if ($names[-1] -ne 'content') { throw "Resolve-Layout: 'content' must be the last column (got '$($names[-1])')." }
    if ($names.Count -lt 2 -or $names[-2] -ne 'content_bytes') { throw "Resolve-Layout: 'content_bytes' must immediately precede 'content'." }

    $headerItems = [List[string]]::new()
    foreach ($col in $cols)
    {
        if ($headerItems.Count -gt 0) { $headerItems.Add($framing.ColumnSeparator) }

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

    if ($metaOn)
    {
        $el = Get-Prop $Header 'Elements'
        $cm = Get-Prop $el 'ContentMeta'
        if ($null -eq $cm)
        {
            Write-Warning "Resolve-Layout: content_meta is enabled but Header.Elements declares no ContentMeta."
        }
        else
        {
            $count = [long](Get-Prop $cm 'Count'); $total = [long](Get-Prop $cm 'Total')
            if ($count -lt $total) { Write-Warning "Resolve-Layout: ContentMeta present on $count of $total entries." }
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
#endregion

#region Format-Row
function Format-Row
{
    <#
    .SYNOPSIS
        Projects resolved layout onto an entry as an item list.
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
        if ($col.Source -eq 'codec.text') { continue }
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
    if ($Source -eq 'plan.GlobalIdx') { return $GlobalIdx }
    if ($Source -eq 'codec.bytes')    { return $ContentBytes }
    if ($Source -eq 'codec.text')     { throw "rs.core.container: codec.text is materialized only by Build-Row." }
    if ($Source -like 'entry.*')      { return Resolve-EntryPath $Entry ($Source.Substring(6) -split '\.') }
    throw "rs.core.container: unknown accessor '$Source'."
}
#endregion

#region Measure-Row
function Measure-Row
{
    <#
    .SYNOPSIS
        Calculates exact serialized byte width of an entry's row under the layout.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [PSCustomObject]$Layout,
        [Parameter(Mandatory)] [object]$Entry
    )
    $f = Format-Row -Layout $Layout -Entry $Entry -GlobalIdx 0
    $join = $script:Utf8.GetByteCount($Layout.Framing.ItemJoin)
    $bytes = 0
    foreach ($p in $f.Items) { $bytes += $script:Utf8.GetByteCount($p) }
    $bytes += $script:Utf8.GetByteCount($Layout.Framing.ColumnSeparator)
    $bytes += $f.ContentBytes
    $bytes += $join * ($f.Items.Count + 1)
    $bytes += $script:Utf8.GetByteCount($Layout.Framing.RecordDelimiter)
    return $bytes
}
#endregion

#region Build-Row
function Build-Row
{
    <#
    .SYNOPSIS
        Builds serialized bytes and cursor offsets for an entry's row.
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
    $prefix = @($f.Items) -join $J
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
#endregion

#region HeaderRowPair
function Measure-HeaderRow
{
    <#
    .SYNOPSIS
        Returns header row byte count.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [PSCustomObject]$Layout)
    return $Layout.HeaderBytes
}

function Build-HeaderRow
{
    <#
    .SYNOPSIS
        Returns UTF-8 bytes for the formatted header row.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [PSCustomObject]$Layout)
    return $script:Utf8.GetBytes($Layout.HeaderRowText + $Layout.Framing.RecordDelimiter)
}
#endregion

Export-ModuleMember -Function @(
    'Resolve-Layout', 'Measure-ContentSpan', 'ConvertTo-ContentSpan', 'Format-Row',
    'Measure-Row', 'Build-Row', 'Measure-HeaderRow', 'Build-HeaderRow'
)
