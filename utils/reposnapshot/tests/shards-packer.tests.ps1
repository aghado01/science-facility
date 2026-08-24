#Requires -Version 7.5
Set-StrictMode -Version Latest

<#
.SYNOPSIS
    rs.core.shards packer core — New-BinAssignment over synthetic size
    vectors: no repo, no ingestion, no fixtures (shards-brief §Algorithm,
    exit gate; ledger #40–#48).

.DESCRIPTION
    Sections:
      1. Guards and degenerate inputs — bad knobs throw; empty group yields no
         bins; singleton group classifies by band (Singleton / InBand /
         Oversized).
      2. Strict baseline (tolerance 0) — all-fit-one; exact multiple; runt
         sequenced to the tail; count cap in the lower bound.
      3. Overflow — single oversized; oversized mid-sequence pinned, excluded
         from every aggregate, identical under both shapes.
      4. Lower bound — the ceiling-anchored formula on the roadmap
         counterexample (quota-anchored LB fails a correct optimal plan).
      5. Strict + tolerance shapes — FrontLoad prefix-maximality and Even
         lexicographic min-max, both checked against brute force over all
         contiguous partitions; the vector where the shapes visibly disagree;
         the adjacent-merge counterexample (7,4,6,5).
      6. Flexible — FFD beats strict; tolerance-bounded elimination; count cap
         binding without futile passes; Even LPT pass; determinism.
      7. Mini comparison harness — both shapes × both OrderStrict over one
         dataset; ShardCount equal across shapes; oversized identical planned
         size in every cell. Four rows, one table.

    Every assignment also passes Assert-Assignment: coverage + atomicity,
    ceiling carve-out, deviation identity per shard (oversized included),
    aggregates recomputed and scoped to non-oversized, mass conservation both
    sides non-oversized, Gap ≥ 0, never worse than strict, tail rule.

.NOTES
    Run from any directory:
        & "$PSScriptRoot\shards-packer.tests.ps1"
#>

$v3 = Join-Path $PSScriptRoot '..\reposnapshot-v3'

# ---------------------------------------------------------------------------
# Minimal assertion framework (house pattern)
# ---------------------------------------------------------------------------
$script:Passed = 0
$script:Failed = 0

function Enter-Section ([string]$Name)
{
    Write-Host "`n── $Name" -ForegroundColor Cyan
}

function Assert-True ([bool]$Condition, [string]$Label, [string]$Detail = '')
{
    if ($Condition)
    {
        $script:Passed++
        Write-Host "    PASS  $Label" -ForegroundColor Green
    }
    else
    {
        $script:Failed++
        $msg = "    FAIL  $Label"
        if ($Detail) { $msg += "  ($Detail)" }
        Write-Host $msg -ForegroundColor Red
    }
}

Import-Module (Join-Path $v3 'rs.core.shards.psm1') -Force

# ---------------------------------------------------------------------------
# Invariant battery — applied to every assignment produced in this suite
# ---------------------------------------------------------------------------
function Assert-Assignment ($R, [long[]]$Sizes, [long]$Header, [long]$Quota, [long]$Tol, [string]$Label)
{
    $ceiling = $Quota + $Tol
    $capC = $ceiling - $Header

    # coverage + atomicity
    $flat = @($R.Bins | ForEach-Object { $_.Indices } | ForEach-Object { $_ } | Sort-Object)
    Assert-True (($flat -join ',') -eq ((0..($Sizes.Count - 1)) -join ',')) "$Label — every record in exactly one bin, whole" ($flat -join ',')

    # per-bin identities: RowBytes, Planned, Overshoot − Slack == Deviation (ALL bins, oversized included)
    $idOk = $true; $why = ''
    foreach ($b in $R.Bins)
    {
        $row = [long]0; foreach ($i in $b.Indices) { $row += $Sizes[$i] }
        if ($b.RowBytes -ne $row) { $idOk = $false; $why = "RowBytes $($b.RowBytes) != $row" }
        if ($b.PlannedSizeBytes -ne ($Header + $row)) { $idOk = $false; $why = 'Planned != Header + rows' }
        if (($b.OvershootBytes - $b.SlackBytes) -ne $b.DeviationBytes) { $idOk = $false; $why = 'Overshoot − Slack != Deviation' }
        if ($b.DeviationBytes -ne ($b.PlannedSizeBytes - $Quota)) { $idOk = $false; $why = 'Deviation != Planned − quota' }
    }
    Assert-True $idOk "$Label — per-shard byte identities hold (deviation signed and true, oversized included)" $why

    # ceiling carve-out + class agreement
    $classOk = $true; $why = ''
    foreach ($b in $R.Bins)
    {
        if ($b.IsOversized)
        {
            if ($b.EntryCount -ne 1 -or $b.PlannedSizeBytes -le $ceiling -or $b.Class -ne 'Oversized') { $classOk = $false; $why = 'oversized shape wrong' }
        }
        else
        {
            if ($b.PlannedSizeBytes -gt $ceiling) { $classOk = $false; $why = "non-oversized $($b.PlannedSizeBytes) > ceiling $ceiling" }
            $expect = if ($b.EntryCount -eq 1) { if ($b.DeviationBytes -le 0) { 'Singleton' } else { 'InBand' } } else { 'Normal' }
            if ($b.Class -ne $expect) { $classOk = $false; $why = "class $($b.Class) != $expect" }
        }
    }
    Assert-True $classOk "$Label — ceiling carve-out and class bands agree" $why

    # aggregates recomputed, scoped to non-oversized
    $nonOv = @($R.Bins | Where-Object { -not $_.IsOversized })
    $totO = [long]0; $maxO = [long]0; $totS = [long]0; $maxF = [long]0; $minF = [long]0
    if ($nonOv.Count -gt 0)
    {
        $minF = [long]::MaxValue
        foreach ($b in $nonOv)
        {
            $totO += $b.OvershootBytes; $totS += $b.SlackBytes
            if ($b.OvershootBytes -gt $maxO) { $maxO = $b.OvershootBytes }
            if ($b.PlannedSizeBytes -gt $maxF) { $maxF = $b.PlannedSizeBytes }
            if ($b.PlannedSizeBytes -lt $minF) { $minF = $b.PlannedSizeBytes }
        }
    }
    Assert-True ($R.TotalOvershootBytes -eq $totO -and $R.MaxOvershootBytes -eq $maxO -and $R.TotalSlackBytes -eq $totS -and $R.MaxFillBytes -eq $maxF -and $R.MinFillBytes -eq $minF) "$Label — aggregates match recomputation and exclude oversized" "stored O=$($R.TotalOvershootBytes)/S=$($R.TotalSlackBytes) vs $totO/$totS"
    Assert-True ($R.MaxOvershootBytes -le $Tol) "$Label — MaxOvershoot ≤ tolerance (Tol 0 ⇒ 0)" "$($R.MaxOvershootBytes) vs $Tol"

    # mass conservation, both sides non-oversized
    $sumPlannedNonOv = [long]0
    foreach ($b in $nonOv) { $sumPlannedNonOv += $b.PlannedSizeBytes }
    Assert-True (($totS - $totO) -eq ($nonOv.Count * $Quota - $sumPlannedNonOv)) "$Label — mass conservation over non-oversized shards" "LHS $($totS-$totO) RHS $($nonOv.Count * $Quota - $sumPlannedNonOv)"

    # counts, bound, never worse than strict
    Assert-True ($R.ShardCount -eq @($R.Bins).Count -and $R.Gap -eq ($R.ShardCount - $R.LowerBound) -and $R.Gap -ge 0 -and $R.ShardCount -le $R.StrictShardCount) "$Label — ShardCount ≥ LowerBound (Gap ≥ 0), never worse than strict" "k=$($R.ShardCount) LB=$($R.LowerBound) strict=$($R.StrictShardCount)"

    # tail rule
    if ($nonOv.Count -gt 0)
    {
        $last = $R.Bins[-1]
        $minRow = ($nonOv | ForEach-Object { $_.RowBytes } | Measure-Object -Minimum).Minimum
        Assert-True ((-not $last.IsOversized) -and $last.RowBytes -eq $minRow) "$Label — minimum-fill non-oversized bin is last" "last=$($last.RowBytes) min=$minRow"
    }
}

# brute force: all ways to split 0..n−1 into k contiguous nonempty parts → arrays of cut positions (end-exclusive)
function Get-ContiguousCutSets ([int]$n, [int]$k)
{
    $out = [System.Collections.Generic.List[object]]::new()
    $walk = $null
    $walk = {
        param($start, $left, $acc)
        if ($left -eq 1) { $out.Add(@($acc + @($n))); return }
        for ($c = $start + 1; $c -le $n - $left + 1; $c++)
        {
            & $walk $c ($left - 1) ($acc + @($c))
        }
    }
    & $walk 0 $k @()
    return ,$out
}

try
{
    # -----------------------------------------------------------------------
    Enter-Section '1. Guards and degenerate inputs'
    # -----------------------------------------------------------------------
    $threw = $null; try { New-BinAssignment -Sizes @(5) -HeaderBytes 100 -ShardQuotaBytes 100 | Out-Null } catch { $threw = $_.Exception.Message }
    Assert-True ($null -ne $threw -and $threw -like '*must exceed HeaderBytes*') 'quota ≤ header throws' $threw
    $threw = $null; try { New-BinAssignment -Sizes @(5, 0) -HeaderBytes 2 -ShardQuotaBytes 12 | Out-Null } catch { $threw = $_.Exception.Message }
    Assert-True ($null -ne $threw -and $threw -like '*defect signal*') 'non-positive size throws (row bytes are ≥ 1 by construction)' $threw

    $r = New-BinAssignment -Sizes @() -HeaderBytes 100 -ShardQuotaBytes 1000
    Assert-True ($r.ShardCount -eq 0 -and $r.LowerBound -eq 0 -and $r.Gap -eq 0 -and @($r.Bins).Count -eq 0) 'empty group: no bins, LB 0, Gap 0 (empty ≠ singleton)'
    Assert-True ($r.MaxFillBytes -eq 0 -and $r.MinFillBytes -eq 0 -and $r.SumRowBytes -eq 0) 'empty group: aggregates zero'

    # singleton group, one per band (header 10, quota 100, tol 20 → capQ 90, capC 110)
    $r = New-BinAssignment -Sizes @(50) -HeaderBytes 10 -ShardQuotaBytes 100 -ShardToleranceBytes 20
    Assert-True ($r.ShardCount -eq 1 -and $r.Bins[0].Class -eq 'Singleton' -and $r.SingletonCount -eq 1) 'singleton band: planned ≤ quota → Singleton (not a runt, not a hazard)'
    Assert-Assignment $r @(50) 10 100 20 'singleton/Singleton'
    $r = New-BinAssignment -Sizes @(95) -HeaderBytes 10 -ShardQuotaBytes 100 -ShardToleranceBytes 20
    Assert-True ($r.Bins[0].Class -eq 'InBand' -and $r.InBandCount -eq 1 -and $r.Bins[0].DeviationBytes -eq 5) 'singleton band: (quota, ceiling] → InBand (the header pushed a row-under-quota over)'
    Assert-Assignment $r @(95) 10 100 20 'singleton/InBand'
    $r = New-BinAssignment -Sizes @(111) -HeaderBytes 10 -ShardQuotaBytes 100 -ShardToleranceBytes 20
    Assert-True ($r.Bins[0].Class -eq 'Oversized' -and $r.OversizedCount -eq 1 -and $r.LowerBound -eq 1 -and $r.MaxOvershootBytes -eq 0) 'singleton band: > ceiling → Oversized; excluded from overshoot aggregates'
    Assert-True ($r.Bins[0].DeviationBytes -eq 21 -and $r.Bins[0].OvershootBytes -eq 21) 'oversized shard keeps its true signed deviation — never zeroed'
    Assert-Assignment $r @(111) 10 100 20 'singleton/Oversized'

    # -----------------------------------------------------------------------
    Enter-Section '2. Strict baseline (tolerance 0) — header 2, quota 12 (capQ 10)'
    # -----------------------------------------------------------------------
    $r = New-BinAssignment -Sizes @(3, 3, 3) -HeaderBytes 2 -ShardQuotaBytes 12 -OrderStrict
    Assert-True ($r.ShardCount -eq 1 -and $r.LowerBound -eq 1 -and ($r.Bins[0].Indices -join ',') -eq '0,1,2') 'all fit one shard'
    Assert-Assignment $r @(3, 3, 3) 2 12 0 'all-fit-one'

    $r = New-BinAssignment -Sizes @(5, 5, 5, 5) -HeaderBytes 2 -ShardQuotaBytes 12 -OrderStrict
    Assert-True ($r.ShardCount -eq 2 -and $r.Gap -eq 0 -and $r.TotalOvershootBytes -eq 0 -and $r.TotalSlackBytes -eq 0) 'exact multiple: two full shards, zero deviation everywhere'
    Assert-Assignment $r @(5, 5, 5, 5) 2 12 0 'exact-multiple'

    $r = New-BinAssignment -Sizes @(2, 9, 9) -HeaderBytes 2 -ShardQuotaBytes 12 -OrderStrict
    Assert-True ($r.ShardCount -eq 3 -and ($r.Bins[-1].Indices -join ',') -eq '0' -and $r.Bins[-1].RowBytes -eq 2) 'a runt FIRST in nominal order is still sequenced to the group tail'
    Assert-True (($r.Bins[0].Indices -join ',') -eq '1' -and ($r.Bins[1].Indices -join ',') -eq '2') '…and the remaining bins keep nominal order'
    Assert-Assignment $r @(2, 9, 9) 2 12 0 'runt-first'

    $r = New-BinAssignment -Sizes @(1, 1, 1, 1, 1, 1, 1, 1) -HeaderBytes 2 -ShardQuotaBytes 12 -OrderStrict -MaxFilesPerShard 2
    Assert-True ($r.ShardCount -eq 4 -and $r.LowerBound -eq 4 -and $r.Gap -eq 0) 'count cap: LB carries the ⌈n/MaxFiles⌉ term — Gap 0, not a spurious 3'
    Assert-Assignment $r @(1, 1, 1, 1, 1, 1, 1, 1) 2 12 0 'count-cap-strict'

    # -----------------------------------------------------------------------
    Enter-Section '3. Overflow — header 2, quota 12, tol 2 (capC 12, ceiling 14)'
    # -----------------------------------------------------------------------
    foreach ($shape in 'FrontLoad', 'Even')
    {
        $r = New-BinAssignment -Sizes @(5, 20, 5) -HeaderBytes 2 -ShardQuotaBytes 12 -ShardToleranceBytes 2 -OrderStrict -PackObjective $shape
        $ov = @($r.Bins | Where-Object IsOversized)[0]
        Assert-True ($r.ShardCount -eq 2 -and $r.OversizedCount -eq 1 -and $ov.EntryCount -eq 1 -and $ov.PlannedSizeBytes -eq 22) "oversized mid-sequence pinned whole under $shape (atomicity outranks quota)"
        Assert-True ($r.MaxOvershootBytes -eq 0 -and $r.MaxFillBytes -eq 12 -and $r.LowerBound -eq 2) "…and excluded from every aggregate under $shape"
        Assert-Assignment $r @(5, 20, 5) 2 12 2 "overflow/$shape"
    }

    # -----------------------------------------------------------------------
    Enter-Section '4. Lower bound is ceiling-anchored (the roadmap counterexample)'
    # -----------------------------------------------------------------------
    # header 100, quota 1000, tol 500: rows 700,700,500. Quota-anchored LB said
    # 3; achievable (and achieved) is 2. The corrected bound must agree.
    $r = New-BinAssignment -Sizes @(700, 700, 500) -HeaderBytes 100 -ShardQuotaBytes 1000 -ShardToleranceBytes 500 -OrderStrict
    Assert-True ($r.LowerBound -eq 2 -and $r.ShardCount -eq 2 -and $r.Gap -eq 0) 'LB = ⌈Σ/(ceiling−header)⌉ = 2 on a correct optimal plan (quota-anchored said 3, Gap −1)'
    Assert-True ($r.MaxOvershootBytes -le 500) '…and the tolerance-facing check holds'
    Assert-Assignment $r @(700, 700, 500) 100 1000 500 'lb-roadmap'

    # -----------------------------------------------------------------------
    Enter-Section '5. Strict + tolerance shapes (exact; brute-forced)'
    # -----------------------------------------------------------------------
    # The disagreement vector — header 1, quota 11, tol 2 (capQ 10, capC 12):
    # 9,1,1,1,1,1. k = 2 under both; FrontLoad → full + runt, Even → near-even.
    $sizes = [long[]]@(9, 1, 1, 1, 1, 1)
    $fl = New-BinAssignment -Sizes $sizes -HeaderBytes 1 -ShardQuotaBytes 11 -ShardToleranceBytes 2 -OrderStrict -PackObjective FrontLoad
    $ev = New-BinAssignment -Sizes $sizes -HeaderBytes 1 -ShardQuotaBytes 11 -ShardToleranceBytes 2 -OrderStrict -PackObjective Even
    Assert-True ($fl.ShardCount -eq 2 -and $ev.ShardCount -eq 2) 'shape never changes ShardCount — clause 1 is lexicographically first'
    $flSets = @($fl.Bins | ForEach-Object { $_.Indices -join ',' } | Sort-Object) -join ' | '
    $evSets = @($ev.Bins | ForEach-Object { $_.Indices -join ',' } | Sort-Object) -join ' | '
    Assert-True ($flSets -eq '0,1 | 2,3,4,5') 'FrontLoad: fill to quota, remainder as the tail (full + runt)' $flSets
    Assert-True ($evSets -eq '0 | 1,2,3,4,5') 'Even: spread the remainder (near-even parts)' $evSets
    Assert-True ($flSets -ne $evSets) 'the two shapes visibly disagree on the same vector'
    Assert-Assignment $fl $sizes 1 11 2 'shape/FrontLoad'
    Assert-Assignment $ev $sizes 1 11 2 'shape/Even'

    # brute force both shape properties over all contiguous 2-partitions
    $cuts = Get-ContiguousCutSets $sizes.Count 2
    $feasible = [System.Collections.Generic.List[object]]::new()
    foreach ($cs in $cuts)
    {
        $parts = [System.Collections.Generic.List[long]]::new()
        $s = 0
        $bad = $false
        foreach ($c in $cs)
        {
            $sum = [long]0
            for ($p = $s; $p -lt $c; $p++) { $sum += $sizes[$p] }
            if ($sum -gt 12) { $bad = $true }   # capC
            $parts.Add($sum)
            $s = $c
        }
        if (-not $bad) { $feasible.Add(@($parts | Sort-Object -Descending)) }
    }
    $evVec = @($ev.Bins | ForEach-Object RowBytes | Sort-Object -Descending)
    $evIsLexMin = $true
    foreach ($v in $feasible)
    {
        for ($i = 0; $i -lt $evVec.Count; $i++)
        {
            if ($evVec[$i] -lt $v[$i]) { break }
            if ($evVec[$i] -gt $v[$i]) { $evIsLexMin = $false; break }
        }
    }
    Assert-True $evIsLexMin 'Even admits no contiguous rearrangement with lexicographically smaller max fill (brute force)' ("ours: " + ($evVec -join ','))
    # FrontLoad prefix-maximality: each non-tail bin could not take the next record within quota
    $ordered = @($fl.Bins | Sort-Object { $_.Indices[0] })
    $flOk = $true
    for ($b = 0; $b -lt $ordered.Count - 1; $b++)
    {
        $next = $ordered[$b + 1].Indices[0]
        if (($ordered[$b].RowBytes + $sizes[$next] -le 10) -and ($ordered[$b].RowBytes -le 10)) { $flOk = $false }
    }
    Assert-True $flOk 'FrontLoad: no earlier-in-order record could have joined a non-tail shard without breaching quota (brute force)'

    # The adjacent-merge counterexample — header 1, quota 11, tol 3 (capQ 10,
    # capC 13): 7,4,6,5. Whole-bin adjacent merge of quota-greedy [7][4,6][5]
    # cannot reach k_min = 2 (no adjacent pair fits under the ceiling); the
    # forward construction moves the cut inside a bin: [7,4][6,5].
    $r = New-BinAssignment -Sizes @(7, 4, 6, 5) -HeaderBytes 1 -ShardQuotaBytes 11 -ShardToleranceBytes 3 -OrderStrict -PackObjective FrontLoad
    $sets = @($r.Bins | ForEach-Object { $_.Indices -join ',' } | Sort-Object) -join ' | '
    Assert-True ($r.ShardCount -eq 2 -and $sets -eq '0,1 | 2,3') 'FrontLoad reaches k_min where whole-bin adjacent merge cannot (7,4,6,5 counterexample)' $sets
    Assert-Assignment $r @(7, 4, 6, 5) 1 11 3 'adjacent-merge-cx'

    # runt tail absorbed only with tolerance — header 2, quota 12 (capQ 10):
    # 9,9,9,3 → k 4 at tol 0; tol 4 (capC 14) → k_min 3
    $r0 = New-BinAssignment -Sizes @(9, 9, 9, 3) -HeaderBytes 2 -ShardQuotaBytes 12 -OrderStrict
    $r4 = New-BinAssignment -Sizes @(9, 9, 9, 3) -HeaderBytes 2 -ShardQuotaBytes 12 -ShardToleranceBytes 4 -OrderStrict
    Assert-True ($r0.ShardCount -eq 4 -and $r4.ShardCount -eq 3) 'the runt is absorbed only when tolerance permits (4 → 3 shards)'
    Assert-Assignment $r0 @(9, 9, 9, 3) 2 12 0 'runt/tol0'
    Assert-Assignment $r4 @(9, 9, 9, 3) 2 12 4 'runt/tol4'

    # -----------------------------------------------------------------------
    Enter-Section '6. Flexible rearrangement'
    # -----------------------------------------------------------------------
    # FFD beats strict — header 2, quota 12 (capQ 10): 5,6,4,5 → strict 3, FFD 2
    $r = New-BinAssignment -Sizes @(5, 6, 4, 5) -HeaderBytes 2 -ShardQuotaBytes 12
    Assert-True ($r.ShardCount -eq 2 -and $r.StrictShardCount -eq 3) 'FFD beats strict greedy (2 < 3); flexible membership is legitimate'
    Assert-Assignment $r @(5, 6, 4, 5) 2 12 0 'ffd-beats-strict'

    # elimination — header 1, quota 11, tol 3 (capQ 10, capC 13): 9,9,2 →
    # FFD/strict k 3, LB 2; the runt is eliminated into the tolerance band
    $r = New-BinAssignment -Sizes @(9, 9, 2) -HeaderBytes 1 -ShardQuotaBytes 11 -ShardToleranceBytes 3
    Assert-True ($r.ShardCount -eq 2 -and $r.Gap -eq 0 -and $r.MaxOvershootBytes -eq 1) 'bin elimination: tolerance is the feasibility bound for shard-eliminating moves'
    $sets = @($r.Bins | ForEach-Object { $_.Indices -join ',' } | Sort-Object) -join ' | '
    Assert-True ($sets -eq '0,2 | 1') 'best-fit into the deterministic first of tied targets' $sets
    Assert-Assignment $r @(9, 9, 2) 1 11 3 'elimination'

    # count cap binding, flexible: no futile elimination chasing an unreachable floor
    $r = New-BinAssignment -Sizes @(1, 1, 1, 1, 1, 1, 1, 1) -HeaderBytes 2 -ShardQuotaBytes 12 -ShardToleranceBytes 5 -MaxFilesPerShard 2
    Assert-True ($r.ShardCount -eq 4 -and $r.LowerBound -eq 4 -and $r.Gap -eq 0) 'count cap binds: LB 4, no elimination attempted below it'
    Assert-Assignment $r @(1, 1, 1, 1, 1, 1, 1, 1) 2 12 5 'count-cap-flex'

    # Even LPT pass — header 2, quota 12 (capQ 10): 8,5,5,2
    $r = New-BinAssignment -Sizes @(8, 5, 5, 2) -HeaderBytes 2 -ShardQuotaBytes 12 -PackObjective Even
    Assert-True ($r.ShardCount -eq 2 -and $r.ShapePassApplied) 'Even flexible: LPT redistribution applied at the settled k'
    Assert-True ($r.MaxFillBytes -eq 12 -and $r.MinFillBytes -eq 12) '…and the fills are even' "max=$($r.MaxFillBytes) min=$($r.MinFillBytes)"
    Assert-Assignment $r @(8, 5, 5, 2) 2 12 0 'even-lpt'

    # determinism: identical inputs → bit-identical assignment
    $a = New-BinAssignment -Sizes @(9, 1, 1, 1, 1, 1) -HeaderBytes 1 -ShardQuotaBytes 11 -ShardToleranceBytes 2 -PackObjective Even
    $b = New-BinAssignment -Sizes @(9, 1, 1, 1, 1, 1) -HeaderBytes 1 -ShardQuotaBytes 11 -ShardToleranceBytes 2 -PackObjective Even
    Assert-True (($a | ConvertTo-Json -Depth 8) -eq ($b | ConvertTo-Json -Depth 8)) 'deterministic: identical knobs and vector → identical plan, tie-breaks included'

    # -----------------------------------------------------------------------
    Enter-Section '7. Comparison mini-harness — both shapes × both OrderStrict, one dataset'
    # -----------------------------------------------------------------------
    # header 2, quota 12, tol 3 (capQ 10, capC 13, ceiling 15); one oversized (20)
    $ds = [long[]]@(9, 1, 1, 1, 1, 1, 20, 7, 4, 6, 5)
    $cells = @{}
    Write-Host ''
    Write-Host ('    {0,-22} {1,3} {2,3} {3,4} {4,5} {5,5} {6,5} {7,5} {8,6}' -f 'cell', 'k', 'LB', 'Gap', 'TotO', 'MaxO', 'MaxF', 'MinF', 'HdrOvh') -ForegroundColor DarkGray
    foreach ($strict in $true, $false)
    {
        foreach ($shape in 'FrontLoad', 'Even')
        {
            $r = New-BinAssignment -Sizes $ds -HeaderBytes 2 -ShardQuotaBytes 12 -ShardToleranceBytes 3 -OrderStrict:$strict -PackObjective $shape
            $key = "$(if ($strict) { 'strict' } else { 'flex' })/$shape"
            $cells[$key] = $r
            Write-Host ('    {0,-22} {1,3} {2,3} {3,4} {4,5} {5,5} {6,5} {7,5} {8,6}' -f $key, $r.ShardCount, $r.LowerBound, $r.Gap, $r.TotalOvershootBytes, $r.MaxOvershootBytes, $r.MaxFillBytes, $r.MinFillBytes, (2 * $r.ShardCount)) -ForegroundColor DarkGray
            Assert-Assignment $r $ds 2 12 3 "harness/$key"
        }
    }
    Assert-True ($cells['strict/FrontLoad'].ShardCount -eq $cells['strict/Even'].ShardCount) 'harness: ShardCount identical under both shapes (strict) — clause 1 first'
    Assert-True ($cells['flex/FrontLoad'].ShardCount -eq $cells['flex/Even'].ShardCount) 'harness: ShardCount identical under both shapes (flexible)'
    $ovSizes = foreach ($k in $cells.Keys) { @($cells[$k].Bins | Where-Object IsOversized)[0].PlannedSizeBytes }
    Assert-True ((@($ovSizes | Sort-Object -Unique)).Count -eq 1 -and @($ovSizes)[0] -eq 22) 'harness: the oversized shard is present under every cell with identical PlannedSizeBytes — untouched by any objective'
}
catch
{
    Assert-True $false "SUITE ABORTED: $($_.Exception.Message)" $_.ScriptStackTrace
}

# ---------------------------------------------------------------------------
Write-Host "`n═══ shards-packer.tests: $script:Passed passed, $script:Failed failed ═══" -ForegroundColor $(if ($script:Failed -eq 0) { 'Green' } else { 'Red' })
if ($script:Failed -gt 0) { exit 1 }
