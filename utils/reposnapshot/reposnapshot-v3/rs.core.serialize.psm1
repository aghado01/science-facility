#Requires -Version 7.5

using namespace System.Collections.Generic
using namespace System.IO

<#
.SYNOPSIS
    RepoSnapshot V3 serialize — export phase: writes shard files to disk.

.DESCRIPTION
    Renders shard files via Build-HeaderRow and Build-Row from rs.core.container.
    Enforces the plan = file byte-length invariant and returns the writer receipt
    with observed row offsets.

    See docs/serialize-and-manifest.md for serializer specifications.
#>

Import-Module (Join-Path $PSScriptRoot 'rs.core.container.psm1')

#region Invoke-Serialize
function Invoke-Serialize
{
    <#
    .SYNOPSIS
        Writes planned shard files to disk and returns serialization receipts.

    .PARAMETER Plan
        The New-ShardPlan result envelope (Plan, Shards, IdxMap).

    .PARAMETER Entries
        The ordered array of IR entry objects.

    .PARAMETER Layout
        The resolved container layout from Resolve-Layout.

    .PARAMETER OutDir
        Target output directory.

    .PARAMETER Buffering
        'PerShard' (default) buffers shard bytes in memory before writing.
        'Stream' writes directly to file stream.

    .OUTPUTS
        [PSCustomObject] @{ Shards; ShardCount; TotalBytes; Encoding }
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
        if ($null -eq $Plan.PSObject.Properties[$m]) { throw "Invoke-Serialize: -Plan lacks '$m' — pass the New-ShardPlan result envelope." }
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
            $cursor = [long]$headerRow.Length
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
                    if ($null -eq $placement) { throw "Invoke-Serialize: IdxMap has no placement for '$rel'." }
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
            throw "Invoke-Serialize: plan = file violated at $name (written: $len, planned: $($shard.PlannedSizeBytes))."
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
        throw "Invoke-Serialize: Total ByteLength ($total) ≠ TotalPlannedSizeBytes ($($Plan.Plan.TotalPlannedSizeBytes))."
    }

    return [PSCustomObject]@{
        Shards     = $receipts.ToArray()
        ShardCount = $Plan.Plan.ShardCount
        TotalBytes = $total
        Encoding   = 'utf-8'
    }
}
#endregion

Export-ModuleMember -Function 'Invoke-Serialize'
