#Requires -Version 7.5
Set-StrictMode -Version Latest

<#
.SYNOPSIS
    rs.core.shards stage shell — New-ShardPlan: IR entries × resolved layout ×
    knobs → the ShardPlan (contracts/shards.contract.json out). Exercised
    against the REAL container layout (Resolve-Layout over container.spec.jsonc),
    so measurement and the plan=file preview run the shipping grammar.

.DESCRIPTION
    Sections:
      1. Boundaries — missing RelativePath throws; ByFileType without the
         carried Extension throws naming the tier; a non-layout object throws.
      2. Flat / PathAsc — membership, ordinals, keys, knob echo (ShardStem and
         MaxFilesPerShard included), per-shard and total byte identities, and
         PLAN = FILE by construction: Build-HeaderRow + Σ Build-Row bytes
         equals every shard's PlannedSizeBytes before serialize exists.
      3. ByFileType — carried Extension read (uppercase folded), '.noext',
         group containment, ordinal group order, key suffixes, group → plan
         roll-up.
      4. ByRootDirectory — '.root' first and unsuffixed.
      5. GroupSort PathHash — reading order matches the hash-derived
         expectation; deterministic.
      6. Oversized pass-through — Class/counts flow to plan level.
      7. gidx layout — IdxWidth echoed; GlobalIdx renders zero-padded through
         Build-Row; plan = file holds with the gidx column on.
      8. Key width — 1000 shards → width 4 (s0001…s1000), never a hardcoded D3.
      9. Empty entries — empty plan, empty IdxMap.
     10. Determinism — identical inputs → identical serialized plan.

.NOTES
    Run from any directory:
        & "$PSScriptRoot\shards-plan.tests.ps1"
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

Import-Module (Join-Path $v3 'rs.core.container.psm1') -Force
Import-Module (Join-Path $v3 'rs.core.numerics.psm1') -Force
Import-Module (Join-Path $v3 'rs.core.shards.psm1') -Force
$utf8 = [System.Text.UTF8Encoding]::new($false)

function New-Header ([int]$EntryCount)
{
    [pscustomobject]@{ EntryCount = $EntryCount; Elements = [pscustomobject]@{} }
}

function New-Entry ([string]$Rel, [string]$Ext, [string]$Content)
{
    [pscustomobject]@{ RelativePath = $Rel; Extension = $Ext; Content = $Content }
}

function Get-RenderedShardBytes ($Layout, [object[]]$Entries, $Shard, $IdxMap)
{
    # the plan = file preview: what serialize will write, byte-counted now
    $total = [long](Build-HeaderRow -Layout $Layout).Length
    foreach ($ei in $Shard.Entries)
    {
        $e = $Entries[$ei]
        $g = if ($Layout.IdxWidth -gt 0) { $IdxMap[[string]$e.RelativePath].GlobalIdx } else { $null }
        $total += (Build-Row -Layout $Layout -Entry $e -Cursor 0 -GlobalIdx $g).Bytes.Length
    }
    return $total
}

try
{
    $L0 = Resolve-Layout -Header (New-Header 4)   # required-only: path | content_bytes | content

    # -----------------------------------------------------------------------
    Enter-Section '1. Boundaries'
    # -----------------------------------------------------------------------
    $threw = $null; try { New-ShardPlan -Entries @([pscustomobject]@{ Content = 'x' }) -Layout $L0 | Out-Null } catch { $threw = $_.Exception.Message }
    Assert-True ($null -ne $threw -and $threw -like '*RelativePath*') 'entry without RelativePath throws' $threw
    $threw = $null; try { New-ShardPlan -Entries @([pscustomobject]@{ RelativePath = 'a.ps1'; Content = 'x' }) -Layout $L0 -Grouping ByFileType | Out-Null } catch { $threw = $_.Exception.Message }
    Assert-True ($null -ne $threw -and $threw -like '*carried*') 'ByFileType without Extension throws, naming the carried tier (never re-derived)' $threw
    $threw = $null; try { New-ShardPlan -Entries @() -Layout ([pscustomobject]@{ Foo = 1 }) | Out-Null } catch { $threw = $_.Exception.Message }
    Assert-True ($null -ne $threw -and $threw -like '*container.out.layout*') 'a non-layout object throws' $threw

    # -----------------------------------------------------------------------
    Enter-Section '2. Flat / PathAsc — identities and plan = file'
    # -----------------------------------------------------------------------
    $entries = @(
        (New-Entry 'a.txt' '.txt' 'hello world')
        (New-Entry 'b.txt' '.txt' 'hello earth')
        (New-Entry 'c.txt' '.txt' 'hello there')
        (New-Entry 'd.txt' '.txt' 'hello again')
    )
    $s = [long](Measure-Row -Layout $L0 -Entry $entries[0])
    $quota = [long]$L0.HeaderBytes + 2 * $s      # exactly two rows per shard
    $r = New-ShardPlan -Entries $entries -Layout $L0 -OrderStrict -ShardQuotaBytes $quota -ShardToleranceBytes 0 -ShardStem 'snap'

    Assert-True ($r.Plan.ShardCount -eq 2 -and ($r.Shards[0].Entries -join ',') -eq '0,1' -and ($r.Shards[1].Entries -join ',') -eq '2,3') 'two shards of two, membership by nominal order' (($r.Shards | ForEach-Object { $_.Entries -join ',' }) -join ' | ')
    Assert-True ($r.Shards[0].Ordinal -eq 1 -and $r.Shards[0].Key -eq 's001' -and $r.Shards[1].Key -eq 's002' -and $r.Shards[0].GroupKey -eq '') 'ordinals 1-based; keys s001/s002; Flat group key empty'
    Assert-True ($r.Shards[0].PlannedSizeBytes -eq ($L0.HeaderBytes + 2 * $s) -and $r.Plan.TotalPlannedSizeBytes -eq (2 * $L0.HeaderBytes + 4 * $s)) 'PlannedSizeBytes = header + Σ Measure-Row; total = Σ shards'
    Assert-True ($r.Plan.HeaderOverheadBytes -eq (2 * $L0.HeaderBytes)) 'HeaderOverheadBytes = ShardCount × HeaderBytes'
    Assert-True ($r.Plan.Grouping -eq 'Flat' -and $r.Plan.GroupSort -eq 'PathAsc' -and $r.Plan.OrderStrict -eq $true -and $r.Plan.PackObjective -eq 'FrontLoad') 'knob echo: grouping, sort, strictness, objective'
    Assert-True ($r.Plan.ShardStem -eq 'snap' -and $r.Plan.MaxFilesPerShard -eq 100000 -and $r.Plan.ShardQuotaBytes -eq $quota -and $r.Plan.ShardToleranceBytes -eq 0) 'knob echo: ShardStem rides the plan (serialize needs it), caps and budgets echoed'
    Assert-True ($r.Plan.HeaderBytes -eq $L0.HeaderBytes -and $r.Plan.IdxWidth -eq 0) 'layout echo: HeaderBytes, IdxWidth (gidx off)'

    $fileOk = $true
    foreach ($shard in $r.Shards)
    {
        if ((Get-RenderedShardBytes $L0 $entries $shard $r.IdxMap) -ne $shard.PlannedSizeBytes) { $fileOk = $false }
    }
    Assert-True $fileOk 'PLAN = FILE by construction: Build-HeaderRow + Σ Build-Row bytes == PlannedSizeBytes, every shard'

    $gm = $r.Groups[0]
    Assert-True ($gm.GroupKey -eq '' -and $gm.EntryCount -eq 4 -and $gm.ShardCount -eq 2 -and $gm.SumRowBytes -eq (4 * $s)) 'group record: key, counts, SumRowBytes'
    Assert-True ($r.IdxMap['a.txt'].GlobalIdx -eq 0 -and $r.IdxMap['d.txt'].GlobalIdx -eq 3 -and $r.IdxMap['c.txt'].ShardOrdinal -eq 2 -and $r.IdxMap['c.txt'].ShardIndex -eq 0 -and $r.IdxMap['b.txt'].ShardKey -eq 's001') 'IdxMap: gidx 0..N−1 in reading order; ordinal/key/index per placement'
    Assert-True ($r.Shards[0].Entries[0] -is [int] -and $null -ne $entries[0].PSObject.Properties['Content']) 'the plan holds entry REFERENCES (indices); the caller''s entries are untouched'

    # -----------------------------------------------------------------------
    Enter-Section '3. ByFileType — carried Extension, containment, roll-up'
    # -----------------------------------------------------------------------
    $entries = @(
        (New-Entry 'a.ps1' '.PS1' 'aaa')
        (New-Entry 'b.ps1' '.ps1' 'bbb')
        (New-Entry 'c.md' '.md' 'ccc')
        (New-Entry 'd' '' 'ddd')
    )
    $r = New-ShardPlan -Entries $entries -Layout $L0 -Grouping ByFileType -OrderStrict
    Assert-True (($r.Groups | ForEach-Object GroupKey) -join ',' -eq '.md,.noext,.ps1') 'group order: ordinal-sorted keys; empty extension → .noext' (($r.Groups | ForEach-Object GroupKey) -join ',')
    Assert-True ($r.Plan.ShardCount -eq 3 -and ($r.Shards | ForEach-Object Key) -join ',' -eq 's001_md,s002_noext,s003_ps1') 'keys carry the clean group suffix' (($r.Shards | ForEach-Object Key) -join ',')
    $ps1 = @($r.Shards | Where-Object GroupKey -eq '.ps1')[0]
    Assert-True ($ps1.EntryCount -eq 2 -and ($ps1.Entries -join ',') -eq '0,1') 'uppercase .PS1 folded into .ps1 — the carried value is read, lowercased, never re-derived'
    $mixed = $false
    foreach ($shard in $r.Shards)
    {
        $keys = @($shard.Entries | ForEach-Object {
                $ext = [string]$entries[$_].Extension
                if ([string]::IsNullOrEmpty($ext)) { '.noext' } else { $ext.ToLowerInvariant() }
            } | Sort-Object -Unique)
        if ($keys.Count -ne 1) { $mixed = $true }
    }
    Assert-True (-not $mixed) 'group containment: no shard mixes groups (structural, #43)'
    Assert-True ((($r.Groups | Measure-Object -Sum ShardCount).Sum) -eq $r.Plan.ShardCount) 'group ShardCounts roll up to the plan'
    Assert-True ($r.IdxMap['c.md'].GlobalIdx -eq 0 -and $r.IdxMap['d'].GlobalIdx -eq 1 -and $r.IdxMap['a.ps1'].GlobalIdx -eq 2 -and $r.IdxMap['b.ps1'].GlobalIdx -eq 3) 'reading order concatenates groups in group order'

    # -----------------------------------------------------------------------
    Enter-Section '4. ByRootDirectory — .root first, unsuffixed'
    # -----------------------------------------------------------------------
    $entries = @(
        (New-Entry 'README.md' '.md' 'read me')
        (New-Entry 'src/a.txt' '.txt' 'aaa')
        (New-Entry 'src/b.txt' '.txt' 'bbb')
        (New-Entry 'docs/c.txt' '.txt' 'ccc')
    )
    $r = New-ShardPlan -Entries $entries -Layout $L0 -Grouping ByRootDirectory -OrderStrict
    Assert-True (($r.Groups | ForEach-Object GroupKey) -join ',' -eq '.root,docs,src') '.root group first, then ordinal' (($r.Groups | ForEach-Object GroupKey) -join ',')
    Assert-True (($r.Shards | ForEach-Object Key) -join ',' -eq 's001,s002_docs,s003_src') '.root shard is unsuffixed; the rest carry their segment' (($r.Shards | ForEach-Object Key) -join ',')

    # -----------------------------------------------------------------------
    Enter-Section '5. GroupSort PathHash — a reading-order device (#43)'
    # -----------------------------------------------------------------------
    $entries = @(
        (New-Entry 'a.txt' '.txt' 'xx')
        (New-Entry 'b.txt' '.txt' 'yy')
        (New-Entry 'c.txt' '.txt' 'zz')
    )
    $expected = @($entries | ForEach-Object { [pscustomobject]@{ Rel = $_.RelativePath; H = (Get-PathHash -Path $_.RelativePath) } } |
            Sort-Object H | ForEach-Object Rel)
    $r = New-ShardPlan -Entries $entries -Layout $L0 -GroupSort PathHash -OrderStrict
    $got = @($r.IdxMap.Keys | Sort-Object { $r.IdxMap[$_].GlobalIdx })
    Assert-True (($got -join ',') -eq ($expected -join ',')) 'reading order inside the shard follows the path hash' "got $($got -join ','), expected $($expected -join ',')"
    $r2 = New-ShardPlan -Entries $entries -Layout $L0 -GroupSort PathHash -OrderStrict
    Assert-True (($r | ConvertTo-Json -Depth 8) -eq ($r2 | ConvertTo-Json -Depth 8)) 'PathHash order is deterministic across runs'

    # -----------------------------------------------------------------------
    Enter-Section '6. Oversized pass-through'
    # -----------------------------------------------------------------------
    $entries = @(
        (New-Entry 'a.txt' '.txt' 'aa')
        (New-Entry 'big.txt' '.txt' ('x' * 400))
        (New-Entry 'c.txt' '.txt' 'cc')
    )
    $r = New-ShardPlan -Entries $entries -Layout $L0 -OrderStrict -ShardQuotaBytes 100 -ShardToleranceBytes 20
    $ov = @($r.Shards | Where-Object IsOversized)
    Assert-True ($ov.Count -eq 1 -and $ov[0].Class -eq 'Oversized' -and $ov[0].EntryCount -eq 1 -and ($entries[$ov[0].Entries[0]].RelativePath) -eq 'big.txt') 'the oversized record rides whole into its own declared shard'
    Assert-True ($r.Plan.OversizedCount -eq 1 -and $r.Plan.MaxOvershootBytes -le 20) 'plan-level counts and tolerance-facing check exclude it'

    # -----------------------------------------------------------------------
    Enter-Section '7. gidx layout — fixed width through the wire'
    # -----------------------------------------------------------------------
    $Lg = Resolve-Layout -Header (New-Header 4) -Columns gidx
    $entries = @(
        (New-Entry 'a.txt' '.txt' 'hello world')
        (New-Entry 'b.txt' '.txt' 'hello earth')
        (New-Entry 'c.txt' '.txt' 'hello there')
        (New-Entry 'd.txt' '.txt' 'hello again')
    )
    $sg = [long](Measure-Row -Layout $Lg -Entry $entries[0])
    $r = New-ShardPlan -Entries $entries -Layout $Lg -OrderStrict -ShardQuotaBytes ([long]$Lg.HeaderBytes + 2 * $sg) -ShardToleranceBytes 0
    Assert-True ($r.Plan.IdxWidth -eq 1 -and $r.Plan.ShardCount -eq 2) 'IdxWidth echoed from the layout (digits(EntryCount) = 1)'
    $fileOk = $true
    foreach ($shard in $r.Shards)
    {
        if ((Get-RenderedShardBytes $Lg $entries $shard $r.IdxMap) -ne $shard.PlannedSizeBytes) { $fileOk = $false }
    }
    Assert-True $fileOk 'plan = file holds with gidx on — measure used a stand-in, the render uses the assigned value, same width'
    $first = $r.Shards[0].Entries[0]
    $row = $utf8.GetString((Build-Row -Layout $Lg -Entry $entries[$first] -Cursor 0 -GlobalIdx $r.IdxMap[[string]$entries[$first].RelativePath].GlobalIdx).Bytes)
    Assert-True ($row.StartsWith('0 | ')) 'the first reading-order row renders gidx 0' $row.Substring(0, [Math]::Min(20, $row.Length))

    # -----------------------------------------------------------------------
    Enter-Section '8. Key width from ShardCount (never a hardcoded D3)'
    # -----------------------------------------------------------------------
    $many = for ($i = 0; $i -lt 1000; $i++) { New-Entry ('f{0:D4}.txt' -f $i) '.txt' 'x' }
    $r = New-ShardPlan -Entries @($many) -Layout $L0 -OrderStrict -MaxFilesPerShard 1
    Assert-True ($r.Plan.ShardCount -eq 1000 -and $r.Shards[0].Key -eq 's0001' -and $r.Shards[-1].Key -eq 's1000') '1000 shards → width 4: s0001…s1000' "$($r.Shards[0].Key)…$($r.Shards[-1].Key)"
    Assert-True ($r.IdxMap['f0999.txt'].GlobalIdx -eq 999) 'gidx spans the full run'

    # -----------------------------------------------------------------------
    Enter-Section '9. Empty entries'
    # -----------------------------------------------------------------------
    $r = New-ShardPlan -Entries @() -Layout $L0
    Assert-True ($r.Plan.ShardCount -eq 0 -and $r.Plan.TotalEntries -eq 0 -and $r.Plan.TotalPlannedSizeBytes -eq 0 -and @($r.Shards).Count -eq 0 -and $r.IdxMap.Count -eq 0) 'empty in, empty plan out'

    # -----------------------------------------------------------------------
    Enter-Section '10. Determinism'
    # -----------------------------------------------------------------------
    $entries = @(
        (New-Entry 'a.ps1' '.ps1' 'aaa')
        (New-Entry 'src/b.md' '.md' 'bbb')
        (New-Entry 'src/c.ps1' '.ps1' 'cc')
        (New-Entry 'd' '' 'dd')
    )
    $a = New-ShardPlan -Entries $entries -Layout $L0 -Grouping ByFileType -PackObjective Even
    $b = New-ShardPlan -Entries $entries -Layout $L0 -Grouping ByFileType -PackObjective Even
    Assert-True (($a | ConvertTo-Json -Depth 8) -eq ($b | ConvertTo-Json -Depth 8)) 'identical inputs → identical serialized plan (grouped, flexible, Even)'
}
catch
{
    Assert-True $false "SUITE ABORTED: $($_.Exception.Message)" $_.ScriptStackTrace
}

# ---------------------------------------------------------------------------
Write-Host "`n═══ shards-plan.tests: $script:Passed passed, $script:Failed failed ═══" -ForegroundColor $(if ($script:Failed -eq 0) { 'Green' } else { 'Red' })
if ($script:Failed -gt 0) { exit 1 }
