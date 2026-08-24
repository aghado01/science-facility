#Requires -Version 7.5

using namespace System.Collections.Generic
using namespace System.IO

<#
.SYNOPSIS
    RepoSnapshot V3 serialize — export phase 2: the ONLY stage that writes
    shard files. Renders via the container's Build-HeaderRow / Build-Row, so
    plan and file cannot disagree; offsets are the writer's receipt.

.DESCRIPTION
    Contract: contracts/serialize.contract.json. Consumes the ShardPlan
    envelope (membership + order), the resolved layout, and the entries;
    writes <ShardStem>_<Key>.txt per shard (no stem → <Key>.txt). Bytes come
    pre-encoded from the container — UTF-8 no BOM, LF only, no encoding layer
    here. The plan = file gate LIVES HERE: every written file's length must
    equal its shard's PlannedSizeBytes or the stage throws. Offsets are
    measured at the cursor during the write — never derived from Measure-Row,
    never recovered from written bytes. Nothing flows back into the plan.

    Public: Invoke-Serialize.
#>

Import-Module (Join-Path $PSScriptRoot 'rs.core.container.psm1')

function Invoke-Serialize
{
    <#
    .SYNOPSIS
        Write every planned shard file and return the receipt: per shard the
        path and measured length, per row the offsets the writer observed.
    .PARAMETER Plan
        The New-ShardPlan result envelope (shards.out.result): Plan, Shards,
        IdxMap. Read, never mutated.
    .PARAMETER Buffering
        PerShard (default): render one shard in memory, write once. Stream:
        write rows as rendered. Same bytes either way.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [PSCustomObject]$Plan,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Entries,
        [Parameter(Mandatory)] [PSCustomObject]$Layout,
        [Parameter(Mandatory)] [string]$OutDir,
        [ValidateSet('PerShard', 'Stream')] [string]$Buffering = 'PerShard'
    )

    foreach ($m in 'Plan', 'Shards', 'IdxMap')
    {
        if ($null -eq $Plan.PSObject.Properties[$m]) { throw "Invoke-Serialize: -Plan lacks '$m' — pass the New-ShardPlan result envelope (shards.out.result)." }
    }
    if ($null -eq $Layout.PSObject.Properties['HeaderBytes'] -or $null -eq $Layout.PSObject.Properties['IdxWidth'])
    {
        throw "Invoke-Serialize: Layout lacks HeaderBytes/IdxWidth — pass container.out.layout."
    }

    $stem = [string]$Plan.Plan.ShardStem
    $idxOn = ([int]$Layout.IdxWidth -gt 0)
    $null = [Directory]::CreateDirectory($OutDir)

    $headerRow = Build-HeaderRow -Layout $Layout
    $receipts = [List[object]]::new()
    $total = [long]0

    foreach ($shard in @($Plan.Shards))
    {
        $name = if ([string]::IsNullOrEmpty($stem)) { "$($shard.Key).txt" } else { "${stem}_$($shard.Key).txt" }
        $path = Join-Path $OutDir $name

        $rows = [List[object]]::new()
        $sink = if ($Buffering -eq 'PerShard') { [MemoryStream]::new() }
        else { [FileStream]::new($path, [FileMode]::Create, [FileAccess]::Write) }
        try
        {
            $sink.Write($headerRow, 0, $headerRow.Length)
            $cursor = [long]$headerRow.Length            # == Layout.HeaderBytes; the first row's RowOffset
            foreach ($ei in @($shard.Entries))
            {
                $i = [int]$ei
                if ($i -lt 0 -or $i -ge $Entries.Count) { throw "Invoke-Serialize: shard $($shard.Key) references entry index $i outside 0..$($Entries.Count - 1)." }
                $entry = $Entries[$i]
                $rel = [string]$entry.RelativePath
                $g = $null
                if ($idxOn)
                {
                    $placement = $Plan.IdxMap[$rel]
                    if ($null -eq $placement) { throw "Invoke-Serialize: IdxMap has no placement for '$rel' — gidx is enabled and every row needs its assigned value." }
                    $g = $placement.GlobalIdx
                }
                $rr = Build-Row -Layout $Layout -Entry $entry -Cursor $cursor -GlobalIdx $g
                $sink.Write($rr.Bytes, 0, $rr.Bytes.Length)
                $rows.Add([pscustomobject]@{
                        RelativePath    = $rel
                        RowOffset       = $rr.RowOffset
                        RowMetaEnd      = $rr.RowMetaEnd
                        RowContentBegin = $rr.RowContentBegin
                        RowContentEnd   = $rr.RowContentEnd
                        ContentBytes    = $rr.ContentBytes
                    })
                $cursor = $rr.NextCursor
            }
            if ($Buffering -eq 'PerShard') { [File]::WriteAllBytes($path, $sink.ToArray()) }
        }
        finally { $sink.Dispose() }

        $len = [FileInfo]::new($path).Length
        if ($len -ne [long]$shard.PlannedSizeBytes)
        {
            throw "Invoke-Serialize: plan = file VIOLATED at $name — written $len bytes, planned $($shard.PlannedSizeBytes). Plan and writer read one grammar; an input changed between planning and writing."
        }
        $total += $len
        $receipts.Add([pscustomobject]@{
                Key         = $shard.Key
                Path        = $path
                ByteLength  = $len
                EntryCount  = $shard.EntryCount
                IsOversized = $shard.IsOversized
                Rows        = $rows.ToArray()
            })
    }

    if ($total -ne [long]$Plan.Plan.TotalPlannedSizeBytes)
    {
        throw "Invoke-Serialize: Σ ByteLength ($total) ≠ plan.TotalPlannedSizeBytes ($($Plan.Plan.TotalPlannedSizeBytes))."
    }

    return [PSCustomObject]@{
        Shards     = $receipts.ToArray()
        ShardCount = $Plan.Plan.ShardCount
        TotalBytes = $total
        Encoding   = 'utf-8'
    }
}

Export-ModuleMember -Function 'Invoke-Serialize'
