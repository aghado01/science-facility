#Requires -Version 7.5

using namespace System.Collections.Generic
using namespace System.Text

<#
.SYNOPSIS
    RepoSnapshot V3 manifest — export phase: renders table-of-contents manifest file.

.DESCRIPTION
    Builds the TOC model from the serializer receipt, sharding plan, layout, and
    RunContext, and renders the manifest markdown document via a lightweight template engine.

    See docs/serialize-and-manifest.md for manifest structure and declaration fields.
#>

$script:Utf8 = [UTF8Encoding]::new($false)

#region TreeTemplate
$script:TreeTemplate = @'
# Tree Manifest TOC for Snapshot: `{{Title}}`

{{SummaryLine}}

Payload:
{{#each PayloadLines}}{{this}}
{{/each}}
## Declarations

- Format: {{Format}}
- Offsets: {{OffsetUnit}}
- Encoding: {{Encoding}}
- Compaction: {{Compaction}}
- Header row (first line of every shard, byte-identical): `{{ColumnHeader}}`
{{#if Hazards}}
Hazards — these shards exceed quota + tolerance and must be read whole; every
other shard is within the ceiling:
{{#each Hazards}}- `{{Key}}` {{ByteLength}} bytes — {{Reason}}
{{/each}}{{/if}}
## Instructions

{{#each Instructions}}{{this}}
{{/each}}
## Tree for `{{TreeLabel}}`

```
{{TreeLegend}}
{{TocTree}}
```

## Provenance

{{#each ProvenanceLines}}{{this}}
{{/each}}
'@
#endregion

#region Engine
function Resolve-TemplateValue
{
    param(
        [Parameter(Mandatory)] $Model,
        [Parameter(Mandatory)] [string] $Path,
        $CurrentItem = $null
    )

    if ($Path -eq 'this') { return $CurrentItem }

    $target = if (
        $null -ne $CurrentItem -and
        $CurrentItem -is [psobject] -and
        $null -ne $CurrentItem.PSObject.Properties[$Path]
    )
    { $CurrentItem }
    else
    { $Model }

    $value = $target
    foreach ($part in ($Path -split '\.'))
    {
        if ($null -eq $value) { return $null }
        $prop = $value.PSObject.Properties[$part]
        if ($null -eq $prop) { return $null }
        $value = $prop.Value
    }
    return $value
}

function Expand-Template
{
    param(
        [Parameter(Mandatory)] [string] $Template,
        [Parameter(Mandatory)] $Model,
        $CurrentItem = $null
    )

    $result = $Template

    $eachRx = [System.Text.RegularExpressions.Regex]::new(
        '\{\{#each\s+([^\}]+)\}\}(.*?)\{\{/each\}\}',
        [System.Text.RegularExpressions.RegexOptions]::Singleline)
    while ($eachRx.IsMatch($result))
    {
        $result = $eachRx.Replace($result, {
                param($m)
                $name = $m.Groups[1].Value.Trim()
                $body = $m.Groups[2].Value
                $items = @(Resolve-TemplateValue -Model $Model -Path $name -CurrentItem $CurrentItem)
                ($items | ForEach-Object {
                    Expand-Template -Template $body -Model $Model -CurrentItem $_
                }) -join ''
            })
    }

    $ifRx = [System.Text.RegularExpressions.Regex]::new(
        '\{\{#if\s+([^\}]+)\}\}(.*?)\{\{/if\}\}',
        [System.Text.RegularExpressions.RegexOptions]::Singleline)
    while ($ifRx.IsMatch($result))
    {
        $result = $ifRx.Replace($result, {
                param($m)
                $name = $m.Groups[1].Value.Trim()
                $body = $m.Groups[2].Value
                $value = Resolve-TemplateValue -Model $Model -Path $name -CurrentItem $CurrentItem
                $empty = (
                    $null -eq $value -or
                    ($value -is [string] -and [string]::IsNullOrWhiteSpace($value)) -or
                    ($value -isnot [string] -and $value -is [System.Collections.IEnumerable] -and @($value).Count -eq 0)
                )
                if ($empty) { '' } else { Expand-Template -Template $body -Model $Model -CurrentItem $CurrentItem }
            })
    }

    $scalarRx = [System.Text.RegularExpressions.Regex]::new('\{\{\s*([A-Za-z0-9_.@]+)\s*\}\}')
    $result = $scalarRx.Replace($result, {
            param($m)
            $value = Resolve-TemplateValue -Model $Model -Path ($m.Groups[1].Value.Trim()) -CurrentItem $CurrentItem
            if ($null -eq $value) { '' } else { [string]$value }
        })

    return $result
}
#endregion

#region TreeRendering
function Build-TocTree
{
    param(
        [Parameter(Mandatory)] [string]$RootName,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Rows
    )

    $newDir = { @{ Dirs = [Dictionary[string, object]]::new([StringComparer]::Ordinal); Files = [List[object]]::new() } }
    $root = & $newDir
    foreach ($row in $Rows)
    {
        $segs = ([string]$row.RelativePath) -split '/'
        $node = $root
        for ($i = 0; $i -lt $segs.Count - 1; $i++)
        {
            if (-not $node.Dirs.ContainsKey($segs[$i])) { $node.Dirs[$segs[$i]] = & $newDir }
            $node = $node.Dirs[$segs[$i]]
        }
        $node.Files.Add([pscustomobject]@{ Name = $segs[-1]; Row = $row })
    }

    $sb = [StringBuilder]::new()
    [void]$sb.Append($RootName).Append("`n")
    $walk = $null
    $walk = {
        param($node, $depth)
        $indent = '    ' * $depth
        $dirNames = [string[]]@($node.Dirs.Keys)
        [Array]::Sort($dirNames, [StringComparer]::Ordinal)
        foreach ($d in $dirNames)
        {
            [void]$sb.Append($indent).Append($d).Append("`n")
            & $walk $node.Dirs[$d] ($depth + 1)
        }
        $files = @($node.Files | Sort-Object -Property Name)
        foreach ($f in $files)
        {
            $r = $f.Row
            [void]$sb.Append($indent).Append($f.Name).Append("`t").Append($r.ShardKey).
            Append("`t").Append($r.RowOffset).Append("`t").Append($r.RowMetaEnd).
            Append("`t").Append($r.RowContentBegin).Append("`t").Append($r.RowContentEnd).Append("`n")
        }
    }
    & $walk $root 1
    return $sb.ToString().TrimEnd("`n")
}
#endregion

#region New-Manifest
function New-Manifest
{
    <#
    .SYNOPSIS
        Builds and writes the tree manifest markdown artifact.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [PSCustomObject]$Receipt,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Shards,
        [Parameter(Mandatory)] [PSCustomObject]$Plan,
        [Parameter(Mandatory)] [PSCustomObject]$Layout,
        [Parameter(Mandatory)] [PSCustomObject]$RunContext,
        [Parameter(Mandatory)] [string]$TreePath,
        [string[]]$InstructionSet = $null
    )

    if ($null -eq $Receipt.PSObject.Properties['Shards']) { throw "New-Manifest: -Receipt lacks Shards — pass serialize.out.receipt." }
    if ($null -eq $Layout.PSObject.Properties['HeaderRowText']) { throw "New-Manifest: -Layout lacks HeaderRowText — pass container.out.layout." }

    $planByKey = @{}
    foreach ($s in $Shards) { $planByKey[[string]$s.Key] = $s }
    foreach ($sr in @($Receipt.Shards))
    {
        $ps = $planByKey[[string]$sr.Key]
        if ($null -eq $ps) { throw "New-Manifest: receipt shard '$($sr.Key)' has no counterpart in the plan." }
        if ([long]$ps.PlannedSizeBytes -ne [long]$sr.ByteLength)
        {
            throw "New-Manifest: shard '$($sr.Key)' — plan says $($ps.PlannedSizeBytes) bytes, the receipt measured $($sr.ByteLength). Disagreement here means the inputs are from different runs."
        }
    }

    $stem = [string]$Plan.ShardStem
    $title = if ([string]::IsNullOrEmpty($stem)) { 's*.txt' } else { "${stem}_s*.txt" }
    $treeLeaf = Split-Path $TreePath -Leaf

    $created = ''
    $p = $RunContext.PSObject.Properties['RunStamp']
    if ($null -ne $p) { $created = [string]$p.Value }
    $summary = "Grouping: $($Plan.Grouping) | GroupSort: $($Plan.GroupSort) | OrderStrict: $($Plan.OrderStrict) | ShardQuotaBytes: $($Plan.ShardQuotaBytes) | ShardToleranceBytes: $($Plan.ShardToleranceBytes) | Created: $created | Shards: $($Plan.ShardCount)"

    $payload = [List[string]]::new()
    $payload.Add("``./$treeLeaf``")
    foreach ($sr in @($Receipt.Shards))
    {
        $ps = $planByKey[[string]$sr.Key]
        $line = "``./$(Split-Path $sr.Path -Leaf)`` files:$($sr.EntryCount) bytes:$($sr.ByteLength)"
        if (-not [string]::IsNullOrEmpty([string]$ps.GroupKey)) { $line += " group:$($ps.GroupKey)" }
        $payload.Add($line)
    }

    $hazards = [List[object]]::new()
    foreach ($sr in @($Receipt.Shards))
    {
        if ($sr.IsOversized)
        {
            $hazards.Add([pscustomobject]@{
                    Key        = $sr.Key
                    ByteLength = $sr.ByteLength
                    Reason     = 'single record exceeds quota + tolerance; kept whole (atomicity)'
                })
        }
    }

    $instructions = if ($null -ne $InstructionSet) { @($InstructionSet) } else
    {
        @(
            'Treat this payload as a virtual database: scan selectively and seek by the byte offsets below for random access, instead of reading everything.'
            'Manage context by fetching segments of the shard files iteratively over multiple inference cycles.'
            'Do not grep the shard files — matches duplicate across rows and explode.'
            'To read one entry: seek to row_content_begin in its shard file and read through row_content_end (inclusive).'
            'The shard extension is .txt deliberately, so low-level file reads are used instead of format-specific tooling.'
        )
    }

    $rows = [List[object]]::new()
    foreach ($sr in @($Receipt.Shards))
    {
        foreach ($r in @($sr.Rows))
        {
            $rows.Add([pscustomobject]@{
                    RelativePath    = $r.RelativePath
                    ShardKey        = $sr.Key
                    RowOffset       = $r.RowOffset
                    RowMetaEnd      = $r.RowMetaEnd
                    RowContentBegin = $r.RowContentBegin
                    RowContentEnd   = $r.RowContentEnd
                })
        }
    }
    $rootName = 'root'
    $p = $RunContext.PSObject.Properties['Root']
    if ($null -ne $p -and -not [string]::IsNullOrEmpty([string]$p.Value))
    {
        $rootName = Split-Path (([string]$p.Value).TrimEnd('/', '\')) -Leaf
    }

    $provLines = [List[string]]::new()
    foreach ($prop in $RunContext.PSObject.Properties)
    {
        $v = $prop.Value
        $rendered = if ($v -is [string] -or $v -is [ValueType]) { [string]$v }
        else { ($v | ConvertTo-Json -Depth 5 -Compress) }
        $provLines.Add("- $($prop.Name): $rendered")
    }

    $model = [pscustomobject]@{
        Title           = $title
        Format          = 'psr — piped snapshot rows; shard files are .txt as a reader accommodation, not a format marker'
        SummaryLine     = $summary
        PayloadLines    = $payload.ToArray()
        Instructions    = $instructions
        ColumnHeader    = [string]$Layout.HeaderRowText
        OffsetUnit      = 'bytes, 0-based, end offsets inclusive'
        Encoding        = "$($Receipt.Encoding) — no BOM; LF record terminator"
        Compaction      = 'content spans are codec-encoded: every source line terminator appears as the two characters \n, remaining C0 controls and DEL are stripped, TAB stays literal; one physical line per row. A notice, not a cipher key — the payload is not byte-faithful to source.'
        Hazards         = $hazards.ToArray()
        TocTree         = (Build-TocTree -RootName $rootName -Rows $rows.ToArray())
        Provenance      = $RunContext
        TreeLabel       = $title
        TreeLegend      = 'file row metadata: name<TAB>sidx<TAB>row_offset<TAB>row_meta_end<TAB>row_content_begin<TAB>row_content_end'
        ProvenanceLines = $provLines.ToArray()
    }

    $text = (Expand-Template -Template $script:TreeTemplate -Model $model).TrimEnd() + "`n"
    $text = $text -replace "`r`n", "`n"
    [IO.File]::WriteAllBytes($TreePath, $script:Utf8.GetBytes($text))

    return [PSCustomObject]@{ Path = $TreePath; Model = $model }
}
#endregion

Export-ModuleMember -Function 'New-Manifest'
