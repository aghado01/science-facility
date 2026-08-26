#Requires -Version 7.5

using namespace System.Collections.Generic
using namespace System.Text

<#
.SYNOPSIS
    RepoSnapshot V3 manifest — export phase: renders table-of-contents manifest file.

.DESCRIPTION
    Poor-man's template engine for the tree TOC. The document pattern lives in
    templates/tree.template.md; canned reader notices live in
    templates/tree.notices.json. New-Manifest interpolates run facts (receipt,
    packing plan, layout header, RunContext scalars, optional colonel family)
    into that pattern. Shards carry only the header row and records; packing
    settings and internment are tree-global metadata.

    See docs/serialize-and-manifest.md for manifest structure and declaration fields.
#>

$script:Utf8 = [UTF8Encoding]::new($false)
$script:TreeTemplatePath = Join-Path $PSScriptRoot 'templates/tree.template.md'
$script:TreeNoticesPath = Join-Path $PSScriptRoot 'templates/tree.notices.json'

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

#region TreeData
function Get-TreeNotices
{
    if (-not [IO.File]::Exists($script:TreeNoticesPath))
    {
        throw "New-Manifest: notices file not found: $script:TreeNoticesPath"
    }
    $raw = [IO.File]::ReadAllText($script:TreeNoticesPath)
    $n = ConvertFrom-Json -InputObject $raw -AsHashtable
    if ($null -eq $n) { throw "New-Manifest: '$script:TreeNoticesPath' is empty." }
    return $n
}

function Get-TreeTemplate
{
    if (-not [IO.File]::Exists($script:TreeTemplatePath))
    {
        throw "New-Manifest: tree template not found: $script:TreeTemplatePath"
    }
    return [IO.File]::ReadAllText($script:TreeTemplatePath)
}

function Get-ContextText ([object]$RunContext, [string]$Name)
{
    $p = $RunContext.PSObject.Properties[$Name]
    if ($null -eq $p)
    {
        $echo = $RunContext.PSObject.Properties['ConfigEcho']
        if ($null -ne $echo -and $null -ne $echo.Value)
        {
            $p = $echo.Value.PSObject.Properties[$Name]
        }
    }
    if ($null -eq $p -or $null -eq $p.Value) { return '' }
    $v = $p.Value
    if ($v -is [System.Collections.IEnumerable] -and $v -isnot [string])
    {
        return (@($v | ForEach-Object { [string]$_ } | Where-Object { $_ }) -join ', ')
    }
    return [string]$v
}

# Reader-facing chain lines from the colonel family. Unused pass-through (compiled
# spare, no corpus extension interned onto it) is omitted — that is plan
# bookkeeping, not something a tree reader needs. Occupancy is the Routing map;
# this only groups extensions that actually took a chain.
function Format-FamilyChains
{
    param([Parameter(Mandatory)] [pscustomobject]$Family)

    $variants = @{}
    $vProp = $Family.PSObject.Properties['Variants']
    if ($vProp -and $vProp.Value -is [System.Collections.IDictionary]) { $variants = $vProp.Value }
    if ($variants.Count -eq 0) { return @() }

    $routing = @{}
    foreach ($name in @('Routing', 'ExtensionMap'))
    {
        $rProp = $Family.PSObject.Properties[$name]
        if ($rProp -and $rProp.Value -is [System.Collections.IDictionary] -and $rProp.Value.Count -gt 0)
        {
            $routing = $rProp.Value
            break
        }
    }

    $defaultId = ''
    $dProp = $Family.PSObject.Properties['DefaultVariant']
    if ($dProp -and $null -ne $dProp.Value) { $defaultId = [string]$dProp.Value }

    $byId = @{}
    foreach ($ext in @($routing.Keys))
    {
        $id = [string]$routing[$ext]
        if (-not $byId.ContainsKey($id)) { $byId[$id] = [List[string]]::new() }
        $byId[$id].Add([string]$ext)
    }

    $lines = [List[object]]::new()
    foreach ($id in (@($variants.Keys) | Sort-Object))
    {
        $sid = [string]$id
        $exts = @()
        if ($byId.ContainsKey($sid)) { $exts = @($byId[$sid] | Sort-Object) }

        if ($exts.Count -eq 0 -and $routing.Count -gt 0 -and $sid -eq $defaultId) { continue }

        $steps = @(
            foreach ($step in @($variants[$id]))
            {
                $key = [string]$step.Key
                $slot = ''
                if ($step.PSObject.Properties['Slot']) { $slot = [string]$step.Slot }
                if ($slot -and $slot -ne $key) { "$slot ($key)" } else { $key }
            }
        )

        $head = if ($exts.Count -gt 0)
        { (@($exts | ForEach-Object { "``$_``" }) -join ' ') }
        else { 'all files' }

        $lines.Add([pscustomobject]@{ Line = "${head}: $($steps -join ' → ')" })
    }
    return $lines.ToArray()
}
#endregion

#region New-Manifest
function New-Manifest
{
    <#
    .SYNOPSIS
        Builds and writes the tree manifest markdown artifact. Template and
        notices are data; this function interpolates receipt, packing plan,
        layout, RunContext, and optional colonel family.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [PSCustomObject]$Receipt,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Shards,
        [Parameter(Mandatory)] [PSCustomObject]$Plan,
        [Parameter(Mandatory)] [PSCustomObject]$Layout,
        [Parameter(Mandatory)] [PSCustomObject]$RunContext,
        [Parameter(Mandatory)] [string]$TreePath,
        [object]$Family = $null,
        [string[]]$InstructionSet = $null
    )

    if ($null -eq $Receipt.PSObject.Properties['Shards']) { throw "New-Manifest: -Receipt lacks Shards — pass serialize.out.receipt." }
    if ($null -eq $Layout.PSObject.Properties['HeaderRowText']) { throw "New-Manifest: -Layout lacks HeaderRowText — pass container.out.layout." }

    $notices = Get-TreeNotices
    $instructions = if ($null -ne $InstructionSet) { @($InstructionSet) } else { @($notices['Instructions']) }
    $oversizedReason = [string]$notices['OversizedReason']

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
                    Reason     = $oversizedReason
                })
        }
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

    $chains = @()
    if ($null -ne $Family) { $chains = @(Format-FamilyChains -Family $Family) }

    $model = [pscustomobject]@{
        Title            = $title
        Format           = [string]$notices['Format']
        SummaryLine      = $summary
        PayloadLines     = $payload.ToArray()
        Instructions     = $instructions
        ColumnHeader     = [string]$Layout.HeaderRowText
        OffsetUnit       = [string]$notices['OffsetUnit']
        Encoding         = [string]$Receipt.Encoding
        Compaction       = [string]$notices['Compaction']
        Hazards          = $hazards.ToArray()
        TocTree          = (Build-TocTree -RootName $rootName -Rows $rows.ToArray())
        Provenance       = $RunContext
        TreeLabel        = $title
        TreeLegend       = [string]$notices['TreeLegend']
        RunStamp         = (Get-ContextText $RunContext 'RunStamp')
        Root             = (Get-ContextText $RunContext 'Root')
        GeneratorVersion = (Get-ContextText $RunContext 'GeneratorVersion')
        GlobSemantics    = (Get-ContextText $RunContext 'GlobSemantics')
        PatternsLine     = (Get-ContextText $RunContext 'Patterns')
        Mode             = (Get-ContextText $RunContext 'Mode')
        RequestedLine    = (Get-ContextText $RunContext 'Requested')
        ColumnsLine      = (Get-ContextText $RunContext 'Columns')
        ConfigSource     = (Get-ContextText $RunContext 'ConfigSource')
        Chains           = $chains
    }

    $text = (Expand-Template -Template (Get-TreeTemplate) -Model $model).TrimEnd() + "`n"
    $text = $text -replace "`r`n", "`n"
    [IO.File]::WriteAllBytes($TreePath, $script:Utf8.GetBytes($text))

    return [PSCustomObject]@{ Path = $TreePath; Model = $model }
}
#endregion

Export-ModuleMember -Function 'New-Manifest'
