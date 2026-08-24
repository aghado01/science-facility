#Requires -Version 7.5

using namespace System.Collections.Generic

<#
.SYNOPSIS
    RepoSnapshot V3 shards — the packer core: deterministic bin assignment over
    one group's measured size vector. Pure integers; zero I/O, zero entries,
    zero layout.

.DESCRIPTION
    Brief: issues/reposnapshot/briefs/shards-brief.md (§Algorithm stages 4–7,
    §Objective, §Policy stack). Contract: contracts/shards.contract.json — this
    module is the packer under it; New-ShardPlan, the stage shell over real
    entries and the resolved layout, is still owed and will call
    New-BinAssignment once per group.

    Input is ONE GROUP's row sizes in NOMINAL ORDER — index i IS the nominal
    position (Measure-Row output, exact by #39/#49). Per-bin row capacity is
    quota − HeaderBytes; ceiling = quota + tolerance (#40/#41). Overflow
    outranks the objectives: HeaderBytes + row > ceiling → own pinned bin at
    any size (#42); atomicity, never split (#47). The lower bound is
    CEILING-anchored and count-capped (2026-08-23 correction — a quota-anchored
    bound exceeds the achievable count whenever tolerance does its job).
    Everything is deterministic: no randomness, explicit tie-breaks (#44).

    Objective per group, lexicographic (#40/#48): (1) fewest bins under the
    ceiling; (2) the PackObjective shape — FrontLoad | Even — over the settled
    count; (3) least overshoot as an invariant of both shapes, never a value.
    OrderStrict && Tolerance == 0 short-circuits at greedy-at-quota (brief
    stage 5: the shape engages under strict only with tolerance).

    THE STAGE SHELL — New-ShardPlan — wraps the core with stages 1–3 and the
    global half of 7–8: enumerate + group (ByFileType reads the CARRIED
    Extension, never re-derives — #50), sort per GroupSort into nominal order,
    measure every record once via Measure-Row (container; #39), call the core
    per group, then assign global Ordinals, Keys (width from ShardCount, floor
    3 — never a hardcoded D3), gidx 0..N−1 in final reading order (IdxMap),
    and emit plan/groups/shards/idxmap per contracts/shards.contract.json.
    The plan holds entry REFERENCES (indices into the caller's Entries) and
    echoes the resolved knobs including ShardStem, which serialize needs for
    filenames and has no other route to.

    Public: New-ShardPlan · New-BinAssignment.
#>

$script:MaxFilesDefault = 100000

# Nested dependencies: Measure-Row (rs.core.container — the one grammar site,
# #39) and Get-PathHash (rs.core.numerics — GroupSort's optional key, #4).
Import-Module (Join-Path $PSScriptRoot 'rs.core.container.psm1')
Import-Module (Join-Path $PSScriptRoot 'rs.core.numerics.psm1')

# =============================================================================
# Internals — arithmetic and greedy primitives
# =============================================================================

function Get-CeilDiv ([long]$A, [long]$B)
{
    # Integer ceiling division. Never via [long] casts of doubles — the cast
    # rounds half-to-even, so ceil(9/5) would come back 3 (via 2.6 → 3 is
    # right, but 2.5-family values corrupt silently). Pure integer instead.
    if ($A -le 0) { return 0L }
    $rem = $A % $B
    $quot = [long](($A - $rem) / $B)
    if ($rem -gt 0) { return $quot + 1 } else { return $quot }
}

function Get-GreedyBins ([long[]]$Sizes, [int[]]$Order, [long]$Cap, [int]$MaxFiles)
{
    # Contiguous greedy over $Order: close the bin when the next record would
    # breach Cap or the count cap. A record alone larger than Cap still gets a
    # bin (solo — the InBand case when Cap is the quota capacity); records
    # larger than the CEILING capacity never reach here (pinned at stage 4).
    $bins = [List[object]]::new()
    $cur = $null
    foreach ($i in $Order)
    {
        $z = $Sizes[$i]
        if ($null -ne $cur -and (($cur.Sum + $z -gt $Cap) -or ($cur.Idx.Count + 1 -gt $MaxFiles)))
        {
            $bins.Add($cur); $cur = $null
        }
        if ($null -eq $cur) { $cur = @{ Idx = [List[int]]::new(); Sum = [long]0 } }
        $cur.Idx.Add($i)
        $cur.Sum += $z
    }
    if ($null -ne $cur) { $bins.Add($cur) }
    return ,$bins
}

function Get-GreedyCount ([long[]]$Sizes, [int[]]$Order, [int]$From, [long]$Cap, [int]$MaxFiles)
{
    # Bin count greedy would produce over the suffix Order[$From..] — the
    # feasibility oracle for FrontLoad forcing. No allocation.
    $k = 0; $sum = [long]0; $cnt = 0
    for ($j = $From; $j -lt $Order.Count; $j++)
    {
        $z = $Sizes[$Order[$j]]
        if ($cnt -gt 0 -and (($sum + $z -gt $Cap) -or ($cnt + 1 -gt $MaxFiles))) { $sum = [long]0; $cnt = 0 }
        if ($cnt -eq 0) { $k++ }
        $sum += $z; $cnt++
    }
    return $k
}

function Test-EvenFeasible ([long[]]$Sizes, [int[]]$Order, [long]$Bound, [int]$MaxParts, [int]$MaxFiles)
{
    # Can the sequence split into ≤ MaxParts contiguous parts, every part ≤
    # Bound and ≤ MaxFiles records? Greedy is optimal for the contiguous case.
    $k = 0; $sum = [long]0; $cnt = 0
    foreach ($i in $Order)
    {
        $z = $Sizes[$i]
        if ($z -gt $Bound) { return $false }
        if ($cnt -gt 0 -and (($sum + $z -gt $Bound) -or ($cnt + 1 -gt $MaxFiles))) { $sum = [long]0; $cnt = 0 }
        if ($cnt -eq 0) { $k++; if ($k -gt $MaxParts) { return $false } }
        $sum += $z; $cnt++
    }
    return $true
}

# =============================================================================
# Internals — strict shapes (exact; ledger #48)
# =============================================================================

function Get-FrontLoadStrictBins ([long[]]$Sizes, [int[]]$Order, [int]$K, [long]$CapQ, [long]$CapC, [int]$MaxFiles)
{
    # Maximal quota prefixes, extended into the tolerance band ONLY while the
    # remaining records cannot fit the remaining bins at the ceiling — so
    # overshoot arises exactly where forced (clause 3 falls out).
    #
    # This is the forward form of the brief's sketch. The sketch's literal
    # procedure — greedy-at-quota then merging ADJACENT WHOLE BINS latest-first
    # — is not exact: on sizes (7,4,6,5) at capQ 10 / capC 13, quota-greedy
    # gives [7][4,6][5] and no adjacent pair fits under the ceiling, yet
    # k_min = 2 is achievable by moving the cut inside a bin → [7,4][6,5].
    # The forward construction computes that directly.
    $bins = [List[object]]::new()
    $j = 0
    for ($b = 0; $b -lt $K; $b++)
    {
        $cur = @{ Idx = [List[int]]::new(); Sum = [long]0 }
        $remaining = $K - $b - 1
        if ($remaining -eq 0)
        {
            while ($j -lt $Order.Count)
            {
                $i = $Order[$j]; $cur.Idx.Add($i); $cur.Sum += $Sizes[$i]; $j++
            }
        }
        else
        {
            # every bin takes at least one record
            $i = $Order[$j]; $cur.Idx.Add($i); $cur.Sum += $Sizes[$i]; $j++
            # fill to quota
            while ($j -lt $Order.Count -and $cur.Idx.Count -lt $MaxFiles -and ($cur.Sum + $Sizes[$Order[$j]] -le $CapQ))
            {
                $i = $Order[$j]; $cur.Idx.Add($i); $cur.Sum += $Sizes[$i]; $j++
            }
            # force into the tolerance band only while the suffix is infeasible
            while ((Get-GreedyCount $Sizes $Order $j $CapC $MaxFiles) -gt $remaining)
            {
                if ($j -ge $Order.Count -or $cur.Idx.Count -ge $MaxFiles -or ($cur.Sum + $Sizes[$Order[$j]] -gt $CapC))
                {
                    throw "rs.core.shards: FrontLoad forcing hit an infeasible state — k_min was not a valid bin count (internal invariant broken)."
                }
                $i = $Order[$j]; $cur.Idx.Add($i); $cur.Sum += $Sizes[$i]; $j++
            }
        }
        $bins.Add($cur)
    }
    if ($j -lt $Order.Count) { throw "rs.core.shards: FrontLoad left records unplaced (internal invariant broken)." }
    return ,$bins
}

function Compare-DescVec ([long[]]$A, [long[]]$B)
{
    # Lexicographic compare of sorted-descending part-size vectors.
    $n = [Math]::Min($A.Count, $B.Count)
    for ($i = 0; $i -lt $n; $i++)
    {
        if ($A[$i] -lt $B[$i]) { return -1 }
        if ($A[$i] -gt $B[$i]) { return 1 }
    }
    return $A.Count.CompareTo($B.Count)
}

function Add-SortedDesc ([long[]]$Vec, [long]$X)
{
    $out = [long[]]::new($Vec.Count + 1)
    $i = 0
    while ($i -lt $Vec.Count -and $Vec[$i] -ge $X) { $out[$i] = $Vec[$i]; $i++ }
    $out[$i] = $X
    while ($i -lt $Vec.Count) { $out[$i + 1] = $Vec[$i]; $i++ }
    return ,$out
}

function Get-EvenStrictBins ([long[]]$Sizes, [int[]]$Order, [int]$K, [long]$CapC, [int]$MaxFiles)
{
    # Lexicographic min-max linear partition (minimize the largest part, then
    # the next, and so on — #48): binary search for the minimal max B*, then
    # DP over cut points with sorted-desc vector values. Valid because
    # inserting the same part size into two sorted vectors preserves their
    # lexicographic order. Cost O(n²·K) worst case — Even+strict is the
    # analytical mode and groups are per-Grouping subsets; FrontLoad is the
    # working default.
    $n = $Order.Count
    $pre = [long[]]::new($n + 1)
    for ($j = 0; $j -lt $n; $j++) { $pre[$j + 1] = $pre[$j] + $Sizes[$Order[$j]] }

    # B* — minimal feasible bound
    $lo = [long]0
    foreach ($i in $Order) { if ($Sizes[$i] -gt $lo) { $lo = $Sizes[$i] } }
    $byMass = Get-CeilDiv $pre[$n] ([long]$K)
    if ($byMass -gt $lo) { $lo = $byMass }
    $hi = $CapC
    while ($lo -lt $hi)
    {
        $mid = [long](($lo + $hi) / 2)   # midpoint floor is safe: lo,hi ≥ 0
        if (($lo + $hi) % 2 -ne 0 -and $mid * 2 -gt ($lo + $hi)) { $mid-- }    # force floor against cast rounding
        if (Test-EvenFeasible $Sizes $Order $mid $K $MaxFiles) { $hi = $mid } else { $lo = $mid + 1 }
    }
    $bstar = $lo

    # DP: f[i,j] = lex-min sorted-desc vector partitioning suffix Order[i..]
    # into exactly j parts, every part ≤ B*. Ties → earliest cut.
    $fv = New-Object 'object[,]' ($n + 1), ($K + 1)
    $fc = New-Object 'int[,]' ($n + 1), ($K + 1)
    for ($j = 1; $j -le $K; $j++)
    {
        for ($i = $n - $j; $i -ge 0; $i--)
        {
            if ($j -eq 1)
            {
                $cnt = $n - $i
                $sum = $pre[$n] - $pre[$i]
                if ($cnt -le $MaxFiles -and $sum -le $bstar) { $fv[$i, 1] = [long[]]@($sum) }
                continue
            }
            $best = $null; $bestCut = -1
            $maxLen = [Math]::Min($MaxFiles, $n - $i - ($j - 1))
            for ($len = 1; $len -le $maxLen; $len++)
            {
                $c = $i + $len
                $part = $pre[$c] - $pre[$i]
                if ($part -gt $bstar) { break }
                $sub = $fv[$c, ($j - 1)]
                if ($null -eq $sub) { continue }
                $cand = Add-SortedDesc ([long[]]$sub) $part
                if ($null -eq $best -or (Compare-DescVec $cand ([long[]]$best)) -lt 0) { $best = $cand; $bestCut = $c }
            }
            if ($null -ne $best) { $fv[$i, $j] = $best; $fc[$i, $j] = $bestCut }
        }
    }
    if ($null -eq $fv[0, $K]) { throw "rs.core.shards: Even partition infeasible at k_min (internal invariant broken)." }

    # reconstruct
    $bins = [List[object]]::new()
    $i = 0
    for ($j = $K; $j -ge 2; $j--)
    {
        $c = $fc[$i, $j]
        $cur = @{ Idx = [List[int]]::new(); Sum = [long]0 }
        for ($p = $i; $p -lt $c; $p++) { $cur.Idx.Add($Order[$p]); $cur.Sum += $Sizes[$Order[$p]] }
        $bins.Add($cur)
        $i = $c
    }
    $last = @{ Idx = [List[int]]::new(); Sum = [long]0 }
    for ($p = $i; $p -lt $n; $p++) { $last.Idx.Add($Order[$p]); $last.Sum += $Sizes[$Order[$p]] }
    $bins.Add($last)
    return ,$bins
}

# =============================================================================
# Internals — flexible rearrangement (stage 6)
# =============================================================================

function Get-FfdBins ([long[]]$Sizes, [int[]]$Order, [long]$Cap, [int]$MaxFiles)
{
    # First-fit decreasing: records by size desc (ties → nominal asc), each
    # into the first bin with room; else a new bin.
    $dec = foreach ($i in $Order) { [pscustomobject]@{ I = $i; Z = $Sizes[$i] } }
    $sorted = @($dec | Sort-Object -Property @{ Expression = 'Z'; Descending = $true }, @{ Expression = 'I'; Descending = $false })
    $bins = [List[object]]::new()
    foreach ($d in $sorted)
    {
        $placed = $false
        foreach ($bin in $bins)
        {
            if (($bin.Sum + $d.Z -le $Cap) -and ($bin.Idx.Count -lt $MaxFiles))
            {
                $bin.Idx.Add($d.I); $bin.Sum += $d.Z; $placed = $true; break
            }
        }
        if (-not $placed)
        {
            $b = @{ Idx = [List[int]]::new(); Sum = [long]$d.Z }
            $b.Idx.Add($d.I)
            $bins.Add($b)
        }
    }
    return ,$bins
}

function Invoke-BinElimination ([List[object]]$Bins, [long[]]$Sizes, [long]$CapC, [int]$MaxFiles, [int]$TargetK)
{
    # Tolerance-bounded bin elimination: smallest bin first (ties → earlier
    # first nominal index), best-fit its records into the other bins with
    # capacity = ceiling; eliminated iff ALL place. Repeat until the target is
    # reached or a full pass changes nothing. Deterministic throughout.
    $ids = 0
    foreach ($b in $Bins) { $b.Id = $ids; $ids++ }
    while ($Bins.Count -gt $TargetK)
    {
        $dec = foreach ($b in $Bins) { [pscustomobject]@{ B = $b; Sum = [long]$b.Sum; First = ($b.Idx | Measure-Object -Minimum).Minimum } }
        $victims = @($dec | Sort-Object -Property Sum, First | ForEach-Object B)
        $eliminated = $false
        foreach ($victim in $victims)
        {
            $addSum = @{}; $addCnt = @{}
            foreach ($b in $Bins) { $addSum[$b.Id] = [long]0; $addCnt[$b.Id] = 0 }
            $moves = [List[object]]::new()
            $ok = $true
            $vdec = foreach ($i in $victim.Idx) { [pscustomobject]@{ I = $i; Z = $Sizes[$i] } }
            foreach ($d in @($vdec | Sort-Object -Property @{ Expression = 'Z'; Descending = $true }, @{ Expression = 'I'; Descending = $false }))
            {
                $best = $null; $bestRoom = [long]::MaxValue
                foreach ($bin in $Bins)
                {
                    if ($bin.Id -eq $victim.Id) { continue }
                    $effSum = $bin.Sum + $addSum[$bin.Id]
                    $effCnt = $bin.Idx.Count + $addCnt[$bin.Id]
                    if (($effSum + $d.Z -le $CapC) -and ($effCnt + 1 -le $MaxFiles))
                    {
                        $room = $CapC - $effSum - $d.Z
                        if ($room -lt $bestRoom) { $bestRoom = $room; $best = $bin }   # tightest fit; ties → first (lowest Id scan order)
                    }
                }
                if ($null -eq $best) { $ok = $false; break }
                $moves.Add(@{ I = $d.I; Z = $d.Z; Target = $best })
                $addSum[$best.Id] += $d.Z
                $addCnt[$best.Id] += 1
            }
            if ($ok)
            {
                foreach ($m in $moves) { $m.Target.Idx.Add($m.I); $m.Target.Sum += $m.Z }
                [void]$Bins.Remove($victim)
                $eliminated = $true
                break
            }
        }
        if (-not $eliminated) { break }
    }
}

function Invoke-EvenLptPass ([List[object]]$Bins, [long[]]$Sizes, [long]$CapC, [int]$MaxFiles)
{
    # Even shape under flexible membership: LPT redistribution over the SAME
    # bin count — records by size desc (ties → nominal asc) into the currently
    # least-filled bin with room (ties → lowest Id). Approximate by design
    # (the brief: flexible Even is LPT; strict Even is the exact mode).
    # Returns $false — leaving the bins untouched — if any record cannot
    # place, which the caller surfaces as ShapePassApplied.
    $ids = 0
    foreach ($b in $Bins) { $b.Id = $ids; $ids++ }
    $all = [List[int]]::new()
    foreach ($b in $Bins) { foreach ($i in $b.Idx) { $all.Add($i) } }
    $dec = foreach ($i in $all) { [pscustomobject]@{ I = $i; Z = $Sizes[$i] } }
    $sorted = @($dec | Sort-Object -Property @{ Expression = 'Z'; Descending = $true }, @{ Expression = 'I'; Descending = $false })

    $shadow = @{}
    foreach ($b in $Bins) { $shadow[$b.Id] = @{ Idx = [List[int]]::new(); Sum = [long]0 } }
    foreach ($d in $sorted)
    {
        $best = $null; $bestSum = [long]::MaxValue
        foreach ($b in $Bins)
        {
            $s = $shadow[$b.Id]
            if (($s.Sum + $d.Z -le $CapC) -and ($s.Idx.Count + 1 -le $MaxFiles))
            {
                if ($s.Sum -lt $bestSum) { $bestSum = $s.Sum; $best = $b }    # least-filled; ties → lowest Id scan order
            }
        }
        if ($null -eq $best) { return $false }
        $shadow[$best.Id].Idx.Add($d.I)
        $shadow[$best.Id].Sum += $d.Z
    }
    foreach ($b in $Bins)
    {
        $b.Idx = $shadow[$b.Id].Idx
        $b.Sum = $shadow[$b.Id].Sum
    }
    return $true
}

# =============================================================================
# PUBLIC — New-BinAssignment
# =============================================================================

function New-BinAssignment
{
    <#
    .SYNOPSIS
        Pack one group's size vector into bins: stages 4–7 of the shards
        cascade as a pure function. Deterministic; synthetic-vector testable.
    .PARAMETER Sizes
        The group's row byte sizes in NOMINAL ORDER (index = nominal
        position). Exact Measure-Row outputs; every element ≥ 1.
    .OUTPUTS
        [PSCustomObject] @{ Bins[] (final sequence: ordered by first nominal
        index, minimum-fill non-oversized bin moved to the tail; Indices
        ascending within each); ShardCount; LowerBound; Gap; SumRowBytes;
        OversizedCount; SingletonCount; InBandCount; TotalOvershootBytes;
        MaxOvershootBytes; TotalSlackBytes; MaxFillBytes; MinFillBytes;
        StrictShardCount; ShapePassApplied }.
        Aggregates cover non-oversized bins only (#42/#48); every bin's own
        DeviationBytes is true and signed, oversized included.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [long[]]$Sizes,
        [Parameter(Mandatory)] [long]$HeaderBytes,
        [Parameter(Mandatory)] [long]$ShardQuotaBytes,
        [long]$ShardToleranceBytes = 0,
        [switch]$OrderStrict,
        [ValidateSet('FrontLoad', 'Even')] [string]$PackObjective = 'FrontLoad',
        [ValidateRange(1, [int]::MaxValue)] [int]$MaxFilesPerShard = $script:MaxFilesDefault
    )

    if ($HeaderBytes -lt 0) { throw "New-BinAssignment: HeaderBytes must be ≥ 0." }
    if ($ShardToleranceBytes -lt 0) { throw "New-BinAssignment: ShardToleranceBytes must be ≥ 0." }
    if ($ShardQuotaBytes -le $HeaderBytes) { throw "New-BinAssignment: ShardQuotaBytes ($ShardQuotaBytes) must exceed HeaderBytes ($HeaderBytes) — a quota that cannot hold the header row packs nothing." }
    for ($i = 0; $i -lt $Sizes.Count; $i++)
    {
        if ($Sizes[$i] -le 0) { throw "New-BinAssignment: Sizes[$i] = $($Sizes[$i]) — row bytes are ≥ 1 by construction (a row is at least its terminator); a non-positive size is a defect signal upstream, not packable input." }
    }

    $ceiling = $ShardQuotaBytes + $ShardToleranceBytes
    $capQ = $ShardQuotaBytes - $HeaderBytes
    $capC = $ceiling - $HeaderBytes

    # ── Stage 4: classify — overflow pinned; ceiling-anchored lower bound ──
    $oversized = [List[int]]::new()
    $packable = [List[int]]::new()
    $sumAll = [long]0
    for ($i = 0; $i -lt $Sizes.Count; $i++)
    {
        $sumAll += $Sizes[$i]
        if ($Sizes[$i] -gt $capC) { $oversized.Add($i) } else { $packable.Add($i) }
    }
    $ordP = [int[]]$packable.ToArray()
    $sumP = [long]0
    foreach ($i in $ordP) { $sumP += $Sizes[$i] }

    $lbPackable = 0
    if ($ordP.Count -gt 0)
    {
        $byBytes = Get-CeilDiv $sumP $capC
        $byCount = Get-CeilDiv ([long]$ordP.Count) ([long]$MaxFilesPerShard)
        $lbPackable = [int][Math]::Max($byBytes, $byCount)
    }
    $lowerBound = $lbPackable + $oversized.Count

    # ── Stage 5: strict baseline (always — k₀ is the never-worse reference) ──
    $packBins = [List[object]]::new()
    $k0 = 0
    $shapeApplied = $true
    if ($ordP.Count -gt 0)
    {
        $strictBins = Get-GreedyBins $Sizes $ordP $capQ $MaxFilesPerShard
        $k0 = $strictBins.Count

        if ($OrderStrict)
        {
            if ($ShardToleranceBytes -eq 0)
            {
                # shape does not engage (brief stage 5: "OrderStrict && Tolerance == 0 → done")
                $packBins = $strictBins
            }
            else
            {
                $kmin = Get-GreedyCount $Sizes $ordP 0 $capC $MaxFilesPerShard
                if ($PackObjective -eq 'FrontLoad')
                {
                    $packBins = Get-FrontLoadStrictBins $Sizes $ordP $kmin $capQ $capC $MaxFilesPerShard
                }
                else
                {
                    $packBins = Get-EvenStrictBins $Sizes $ordP $kmin $capC $MaxFilesPerShard
                }
            }
        }
        else
        {
            # ── Stage 6: flexible rearrangement ──
            $ffd = Get-FfdBins $Sizes $ordP $capQ $MaxFilesPerShard
            if ($ffd.Count -lt $k0) { $packBins = $ffd } else { $packBins = $strictBins }   # min; tie → strict (order for free)
            if ($packBins.Count -gt $lbPackable -and $ShardToleranceBytes -gt 0)
            {
                Invoke-BinElimination $packBins $Sizes $capC $MaxFilesPerShard $lbPackable
            }
            if ($PackObjective -eq 'Even')
            {
                $shapeApplied = Invoke-EvenLptPass $packBins $Sizes $capC $MaxFilesPerShard
            }
        }
    }

    # ── Stage 7: sequence — bins by first nominal index; min-fill
    #    non-oversized bin to the tail (ties → later nominal position);
    #    indices restored to nominal order within each bin ──
    $seq = [List[object]]::new()
    foreach ($b in $packBins)
    {
        $idx = [int[]]@($b.Idx | Sort-Object)
        $seq.Add(@{ Indices = $idx; RowBytes = [long]$b.Sum; Pinned = $false })
    }
    foreach ($i in $oversized)
    {
        $seq.Add(@{ Indices = [int[]]@($i); RowBytes = [long]$Sizes[$i]; Pinned = $true })
    }
    $dec = foreach ($b in $seq) { [pscustomobject]@{ B = $b; First = $b.Indices[0] } }
    $ordered = [List[object]]::new()
    foreach ($d in @($dec | Sort-Object -Property First)) { $ordered.Add($d.B) }

    $nonPinned = @($ordered | Where-Object { -not $_.Pinned })
    if ($nonPinned.Count -gt 0)
    {
        $minSum = [long]::MaxValue
        foreach ($b in $nonPinned) { if ($b.RowBytes -lt $minSum) { $minSum = $b.RowBytes } }
        $tail = $null
        foreach ($b in $nonPinned)
        {
            # ties → later nominal position becomes the tail
            if ($b.RowBytes -eq $minSum -and ($null -eq $tail -or $b.Indices[0] -gt $tail.Indices[0])) { $tail = $b }
        }
        [void]$ordered.Remove($tail)
        $ordered.Add($tail)
    }

    # ── Classify + aggregates (aggregates exclude oversized, #42/#48) ──
    $bins = [List[object]]::new()
    foreach ($b in $ordered)
    {
        $planned = $HeaderBytes + $b.RowBytes
        $dev = $planned - $ShardQuotaBytes
        $class = if ($b.Pinned) { 'Oversized' }
        elseif ($b.Indices.Count -eq 1) { if ($dev -le 0) { 'Singleton' } else { 'InBand' } }
        else { 'Normal' }
        $bins.Add([pscustomobject]@{
                Indices          = $b.Indices
                EntryCount       = $b.Indices.Count
                RowBytes         = $b.RowBytes
                PlannedSizeBytes = $planned
                DeviationBytes   = $dev
                OvershootBytes   = [Math]::Max([long]0, $dev)
                SlackBytes       = [Math]::Max([long]0, -$dev)
                Class            = $class
                IsOversized      = [bool]$b.Pinned
            })
    }

    $totO = [long]0; $maxO = [long]0; $totS = [long]0
    $maxF = [long]0; $minF = [long]0
    $nSingleton = 0; $nInBand = 0
    $nonOv = @($bins | Where-Object { -not $_.IsOversized })
    if ($nonOv.Count -gt 0)
    {
        $minF = [long]::MaxValue
        foreach ($b in $nonOv)
        {
            $totO += $b.OvershootBytes
            $totS += $b.SlackBytes
            if ($b.OvershootBytes -gt $maxO) { $maxO = $b.OvershootBytes }
            if ($b.PlannedSizeBytes -gt $maxF) { $maxF = $b.PlannedSizeBytes }
            if ($b.PlannedSizeBytes -lt $minF) { $minF = $b.PlannedSizeBytes }
        }
    }
    foreach ($b in $bins)
    {
        if ($b.Class -eq 'Singleton') { $nSingleton++ }
        if ($b.Class -eq 'InBand') { $nInBand++ }
    }

    return [PSCustomObject]@{
        Bins                = $bins.ToArray()
        ShardCount          = $bins.Count
        LowerBound          = $lowerBound
        Gap                 = $bins.Count - $lowerBound
        SumRowBytes         = $sumAll
        OversizedCount      = $oversized.Count
        SingletonCount      = $nSingleton
        InBandCount         = $nInBand
        TotalOvershootBytes = $totO
        MaxOvershootBytes   = $maxO
        TotalSlackBytes     = $totS
        MaxFillBytes        = $maxF
        MinFillBytes        = $minF
        StrictShardCount    = $k0 + $oversized.Count
        ShapePassApplied    = $shapeApplied
    }
}

# =============================================================================
# Internals — stage shell (grouping, nominal order)
# =============================================================================

function Get-GroupKey ([object]$Entry, [string]$Grouping, [int]$Index)
{
    switch ($Grouping)
    {
        'Flat' { return '' }
        'ByFileType'
        {
            # READ from the carried tier, never re-derived from RelativePath —
            # two derivations of one fact is the defect class #50 closed.
            $p = $Entry.PSObject.Properties['Extension']
            if ($null -eq $p) { throw "New-ShardPlan: entry #$Index carries no Extension — ByFileType reads assemble.out.entry.carried (ledger #50); it never re-derives from RelativePath." }
            $ext = [string]$p.Value
            if ([string]::IsNullOrEmpty($ext)) { return '.noext' }
            return $ext.ToLowerInvariant()
        }
        'ByRootDirectory'
        {
            $rel = [string]$Entry.RelativePath
            $slash = $rel.IndexOf('/')
            if ($slash -lt 0) { return '.root' }
            return $rel.Substring(0, $slash)
        }
    }
}

function Get-CleanGroupName ([string]$GroupKey)
{
    # Key suffix fragment: leading '.' dropped ('.ps1' → 'ps1'); anything
    # outside [A-Za-z0-9_-] becomes '_' (crawler-derived names may carry
    # spaces and non-ASCII; filenames must not).
    $s = $GroupKey.TrimStart('.')
    if ($s.Length -eq 0) { $s = 'noext' }
    return ($s -replace '[^A-Za-z0-9_-]', '_')
}

function Get-NominalOrder ([object[]]$Entries, [List[int]]$Members, [string]$GroupSort)
{
    # Deterministic and ordinal (never culture-sensitive): composite sort key
    # with RelativePath as the ordinal tie-break, so even an unstable sort and
    # colliding primary keys cannot produce two orders.
    $n = $Members.Count
    $keys = [string[]]::new($n)
    $idx = [int[]]::new($n)
    for ($j = 0; $j -lt $n; $j++)
    {
        $rel = [string]$Entries[$Members[$j]].RelativePath
        $primary = if ($GroupSort -eq 'PathHash') { Get-PathHash -Path $rel } else { $rel }
        $keys[$j] = $primary + [char]0 + $rel
        $idx[$j] = $Members[$j]
    }
    [Array]::Sort($keys, $idx, [StringComparer]::Ordinal)
    return ,$idx
}

# =============================================================================
# PUBLIC — New-ShardPlan
# =============================================================================

function New-ShardPlan
{
    <#
    .SYNOPSIS
        Export phase 1, the stage entry point: IR entries × resolved layout ×
        knobs → the ShardPlan (contracts/shards.contract.json out). Pure
        planning — zero I/O, zero offsets; serialize consumes the plan and
        nothing flows back.
    .PARAMETER Entries
        assemble.out.result.Entries, canonical ingested order. The plan holds
        INDICES into this array — it never copies content.
    .PARAMETER Layout
        container.out.layout (Resolve-Layout), resolved before this stage.
        HeaderBytes and IdxWidth are read; the object rides whole into
        Measure-Row, uninterpreted here.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Entries,
        [Parameter(Mandatory)] [PSCustomObject]$Layout,
        [ValidateSet('Flat', 'ByFileType', 'ByRootDirectory')] [string]$Grouping = 'Flat',
        [ValidateSet('PathAsc', 'PathHash')] [string]$GroupSort = 'PathAsc',
        [switch]$OrderStrict,
        [ValidateSet('FrontLoad', 'Even')] [string]$PackObjective = 'FrontLoad',
        [long]$ShardQuotaBytes = 32768,          # working default (#40), not a final config-surface call
        [long]$ShardToleranceBytes = 4096,       # working default (#41)
        [ValidateRange(1, [int]::MaxValue)] [int]$MaxFilesPerShard = $script:MaxFilesDefault,
        [string]$ShardStem = ''
    )

    if ($null -eq $Layout.PSObject.Properties['HeaderBytes'] -or $null -eq $Layout.PSObject.Properties['IdxWidth'])
    {
        throw "New-ShardPlan: Layout lacks HeaderBytes/IdxWidth — pass container.out.layout (Resolve-Layout output), resolved before this stage."
    }
    $headerBytes = [long]$Layout.HeaderBytes
    $idxWidth = [int]$Layout.IdxWidth

    # ── Stage 1: enumerate + group ───────────────────────────────────────
    $byKey = [Dictionary[string, List[int]]]::new([StringComparer]::Ordinal)
    for ($i = 0; $i -lt $Entries.Count; $i++)
    {
        $p = $Entries[$i].PSObject.Properties['RelativePath']
        if ($null -eq $p -or [string]::IsNullOrEmpty([string]$p.Value))
        {
            throw "New-ShardPlan: entry #$i lacks RelativePath — assemble.out.entry.core is this stage's input contract."
        }
        $key = Get-GroupKey $Entries[$i] $Grouping $i
        if (-not $byKey.ContainsKey($key)) { $byKey[$key] = [List[int]]::new() }
        $byKey[$key].Add($i)
    }

    # group order: ordinal-sorted keys; ByRootDirectory puts '.root' first
    $groupKeys = [string[]]@($byKey.Keys)
    [Array]::Sort($groupKeys, [StringComparer]::Ordinal)
    if ($Grouping -eq 'ByRootDirectory' -and $groupKeys -contains '.root')
    {
        $groupKeys = @('.root') + @($groupKeys | Where-Object { $_ -ne '.root' })
    }

    # ── Stages 2–7 per group: sort, measure once, pack ───────────────────
    $groupOut = [List[object]]::new()
    $groupBins = [List[object]]::new()   # parallel: @{ Key; Bins (entry-index mapped, core order) }
    foreach ($gk in $groupKeys)
    {
        $ord = Get-NominalOrder $Entries $byKey[$gk] $GroupSort
        $sizes = [long[]]::new($ord.Count)
        for ($j = 0; $j -lt $ord.Count; $j++)
        {
            $sizes[$j] = [long](Measure-Row -Layout $Layout -Entry $Entries[$ord[$j]])
        }

        $asg = New-BinAssignment -Sizes $sizes -HeaderBytes $headerBytes -ShardQuotaBytes $ShardQuotaBytes `
            -ShardToleranceBytes $ShardToleranceBytes -OrderStrict:$OrderStrict -PackObjective $PackObjective `
            -MaxFilesPerShard $MaxFilesPerShard

        $mapped = [List[object]]::new()
        foreach ($b in $asg.Bins)
        {
            $entryIdx = [int[]]::new($b.Indices.Count)
            for ($j = 0; $j -lt $b.Indices.Count; $j++) { $entryIdx[$j] = $ord[$b.Indices[$j]] }
            $mapped.Add([pscustomobject]@{ Core = $b; Entries = $entryIdx })
        }
        $groupBins.Add(@{ Key = $gk; Bins = $mapped })

        $groupOut.Add([pscustomobject]@{
                GroupKey            = $gk
                EntryCount          = $ord.Count
                SumRowBytes         = $asg.SumRowBytes
                ShardCount          = $asg.ShardCount
                LowerBound          = $asg.LowerBound
                Gap                 = $asg.Gap
                OversizedCount      = $asg.OversizedCount
                SingletonCount      = $asg.SingletonCount
                InBandCount         = $asg.InBandCount
                TotalOvershootBytes = $asg.TotalOvershootBytes
                MaxOvershootBytes   = $asg.MaxOvershootBytes
                TotalSlackBytes     = $asg.TotalSlackBytes
                MaxFillBytes        = $asg.MaxFillBytes
                MinFillBytes        = $asg.MinFillBytes
            })
    }

    # ── Stage 7 (global) + 8: ordinals, keys, gidx, plan ─────────────────
    $totalShards = 0
    foreach ($g in $groupBins) { $totalShards += $g.Bins.Count }
    $keyWidth = [Math]::Max(3, $totalShards.ToString().Length)   # width from a bound known before any name is written (#46)

    $shards = [List[object]]::new()
    $idxMap = [ordered]@{}
    $ordinal = 0
    $gidx = 0
    foreach ($g in $groupBins)
    {
        $suffix = ''
        if ($Grouping -ne 'Flat' -and $g.Key -ne '.root') { $suffix = '_' + (Get-CleanGroupName $g.Key) }
        foreach ($m in $g.Bins)
        {
            $ordinal++
            $key = 's' + $ordinal.ToString('D' + $keyWidth) + $suffix
            $b = $m.Core
            $shards.Add([pscustomobject]@{
                    Ordinal          = $ordinal
                    Key              = $key
                    GroupKey         = $g.Key
                    Class            = $b.Class
                    IsOversized      = $b.IsOversized
                    PlannedSizeBytes = $b.PlannedSizeBytes
                    DeviationBytes   = $b.DeviationBytes
                    OvershootBytes   = $b.OvershootBytes
                    SlackBytes       = $b.SlackBytes
                    EntryCount       = $b.EntryCount
                    Entries          = $m.Entries
                })
            for ($j = 0; $j -lt $m.Entries.Count; $j++)
            {
                $idxMap[[string]$Entries[$m.Entries[$j]].RelativePath] = [pscustomobject]@{
                    GlobalIdx    = $gidx
                    ShardOrdinal = $ordinal
                    ShardKey     = $key
                    ShardIndex   = $j
                }
                $gidx++
            }
        }
    }

    # plan aggregates from the shard list directly (non-oversized scope, #48)
    $totalPlanned = [long]0
    $totO = [long]0; $maxO = [long]0; $totS = [long]0; $maxF = [long]0; $minF = [long]0
    $nOv = 0; $nSing = 0; $nBand = 0
    $anyNonOv = $false
    foreach ($s in $shards)
    {
        $totalPlanned += $s.PlannedSizeBytes
        if ($s.IsOversized) { $nOv++ }
        elseif ($s.Class -eq 'Singleton') { $nSing++ }
        elseif ($s.Class -eq 'InBand') { $nBand++ }
        if (-not $s.IsOversized)
        {
            if (-not $anyNonOv) { $minF = [long]::MaxValue; $anyNonOv = $true }
            $totO += $s.OvershootBytes; $totS += $s.SlackBytes
            if ($s.OvershootBytes -gt $maxO) { $maxO = $s.OvershootBytes }
            if ($s.PlannedSizeBytes -gt $maxF) { $maxF = $s.PlannedSizeBytes }
            if ($s.PlannedSizeBytes -lt $minF) { $minF = $s.PlannedSizeBytes }
        }
    }
    if (-not $anyNonOv) { $minF = [long]0 }

    $plan = [PSCustomObject]@{
        TotalEntries          = $Entries.Count
        TotalPlannedSizeBytes = $totalPlanned
        ShardCount            = $totalShards
        OversizedCount        = $nOv
        SingletonCount        = $nSing
        InBandCount           = $nBand
        TotalOvershootBytes   = $totO
        MaxOvershootBytes     = $maxO
        TotalSlackBytes       = $totS
        MaxFillBytes          = $maxF
        MinFillBytes          = $minF
        HeaderOverheadBytes   = [long]$totalShards * $headerBytes
        Grouping              = $Grouping
        GroupSort             = $GroupSort
        OrderStrict           = [bool]$OrderStrict
        PackObjective         = $PackObjective
        ShardQuotaBytes       = $ShardQuotaBytes
        ShardToleranceBytes   = $ShardToleranceBytes
        MaxFilesPerShard      = $MaxFilesPerShard
        ShardStem             = $ShardStem
        HeaderBytes           = $headerBytes
        IdxWidth              = $idxWidth
    }

    return [PSCustomObject]@{
        Plan   = $plan
        Groups = $groupOut.ToArray()
        Shards = $shards.ToArray()
        IdxMap = $idxMap
    }
}

Export-ModuleMember -Function @('New-ShardPlan', 'New-BinAssignment')
