#Requires -Version 7.5
Set-StrictMode -Version Latest

<#
.SYNOPSIS
    rs.core.serialize — Invoke-Serialize writes what shards planned, measures
    the receipt, and enforces plan = file on real files. Runs the real chain:
    Resolve-Layout → New-ShardPlan → Invoke-Serialize → read the bytes back.

.DESCRIPTION
    Sections:
      1. Boundaries — bad envelope, bad layout throw.
      2. Flat e2e — files exist and are named <stem>_<Key>.txt; ByteLength ==
         PlannedSizeBytes; TotalBytes == plan total; no BOM; no raw CR (CRLF
         source content arrives codec-encoded); header row occupies
         [0, HeaderBytes); offsets chain seamlessly to the file length.
      3. THE SEEK CONTRACT ON DISK — bytes at [RowContentBegin..RowContentEnd]
         of the written file are exactly ConvertTo-ContentSpan(Content), for
         every row of every shard.
      4. gidx — rows carry the assigned zero-padded GlobalIdx on disk.
      5. Buffering — PerShard and Stream produce byte-identical files.
      6. Oversized — written whole, receipt carries IsOversized.
      7. The gate fires — a tampered PlannedSizeBytes makes the stage throw.
      8. Empty plan — no files, empty receipt.

.NOTES
    Run from any directory:
        & "$PSScriptRoot\serialize.tests.ps1"
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
Import-Module (Join-Path $v3 'rs.core.shards.psm1') -Force
Import-Module (Join-Path $v3 'rs.core.serialize.psm1') -Force
$utf8 = [System.Text.UTF8Encoding]::new($false)

$outRoot = Join-Path ([IO.Path]::GetTempPath()) "rs-serialize-test-$([guid]::NewGuid().ToString('N').Substring(0,8))"
New-Item -ItemType Directory -Path $outRoot | Out-Null

function New-Header ([int]$EntryCount)
{
    [pscustomobject]@{ EntryCount = $EntryCount; Elements = [pscustomobject]@{} }
}

function New-Entry ([string]$Rel, [string]$Content)
{
    [pscustomobject]@{ RelativePath = $Rel; Extension = '.txt'; Content = $Content }
}

try
{
    $L0 = Resolve-Layout -Header (New-Header 4)

    # -----------------------------------------------------------------------
    Enter-Section '1. Boundaries'
    # -----------------------------------------------------------------------
    $threw = $null; try { Invoke-Serialize -Plan ([pscustomobject]@{ Foo = 1 }) -Entries @() -Layout $L0 -OutDir $outRoot | Out-Null } catch { $threw = $_.Exception.Message }
    Assert-True ($null -ne $threw -and $threw -like '*New-ShardPlan result envelope*') 'a non-envelope -Plan throws' $threw
    $entries = @((New-Entry 'a.txt' 'aa'))
    $plan = New-ShardPlan -Entries $entries -Layout $L0
    $threw = $null; try { Invoke-Serialize -Plan $plan -Entries $entries -Layout ([pscustomobject]@{ Bar = 2 }) -OutDir $outRoot | Out-Null } catch { $threw = $_.Exception.Message }
    Assert-True ($null -ne $threw -and $threw -like '*container.out.layout*') 'a non-layout -Layout throws' $threw

    # -----------------------------------------------------------------------
    Enter-Section '2. Flat e2e — files, lengths, encoding, offset chain'
    # -----------------------------------------------------------------------
    $entries = @(
        (New-Entry 'a.txt' "line one`r`nline two")     # CRLF source — must not survive to disk
        (New-Entry 'b.txt' 'hello é 日本')
        (New-Entry 'c.txt' 'plain')
        (New-Entry 'd.txt' ('x' * 40))
    )
    $s0 = [long](Measure-Row -Layout $L0 -Entry $entries[0])
    $s1 = [long](Measure-Row -Layout $L0 -Entry $entries[1])
    $quota = [long]$L0.HeaderBytes + $s0 + $s1          # first two rows fill shard one
    $plan = New-ShardPlan -Entries $entries -Layout $L0 -OrderStrict -ShardQuotaBytes $quota -ShardToleranceBytes 0 -ShardStem 'snap'
    $dir = Join-Path $outRoot 'flat'
    $receipt = Invoke-Serialize -Plan $plan -Entries $entries -Layout $L0 -OutDir $dir

    Assert-True ($receipt.ShardCount -eq $plan.Plan.ShardCount -and @($receipt.Shards).Count -eq $plan.Plan.ShardCount) 'receipt covers every planned shard'
    Assert-True ($receipt.Encoding -eq 'utf-8') 'emission encoding declared for the manifest (ledger #17)'
    $ok = $true
    foreach ($sr in $receipt.Shards)
    {
        if (-not (Test-Path $sr.Path)) { $ok = $false }
        if ([IO.Path]::GetFileName($sr.Path) -ne "snap_$($sr.Key).txt") { $ok = $false }
    }
    Assert-True $ok 'files exist, named <ShardStem>_<Key>.txt'
    $planned = @{}; foreach ($sh in $plan.Shards) { $planned[$sh.Key] = $sh.PlannedSizeBytes }
    $ok = $true
    foreach ($sr in $receipt.Shards) { if ($sr.ByteLength -ne $planned[$sr.Key]) { $ok = $false } }
    Assert-True $ok 'PLAN = FILE on disk: measured ByteLength == PlannedSizeBytes, every shard'
    Assert-True ($receipt.TotalBytes -eq $plan.Plan.TotalPlannedSizeBytes) 'TotalBytes == plan.TotalPlannedSizeBytes'

    $ok = $true; $why = ''
    foreach ($sr in $receipt.Shards)
    {
        $bytes = [IO.File]::ReadAllBytes($sr.Path)
        if ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB) { $ok = $false; $why = 'BOM' }
        if ($bytes -contains 0x0D) { $ok = $false; $why = 'raw CR on disk' }
        $hdr = $utf8.GetString($bytes[0..([int]$L0.HeaderBytes - 1)])
        if ($hdr -ne ($L0.HeaderRowText + "`n")) { $ok = $false; $why = 'header row mismatch' }
        # offsets chain: first row starts at HeaderBytes; rows abut; last ends at EOF
        $expect = [long]$L0.HeaderBytes
        foreach ($row in $sr.Rows)
        {
            if ($row.RowOffset -ne $expect) { $ok = $false; $why = "row offset $($row.RowOffset) != $expect" }
            $expect = $row.RowContentEnd + 2      # content end (inclusive) + LF → next row
        }
        if ($expect -ne $sr.ByteLength) { $ok = $false; $why = "chain end $expect != length $($sr.ByteLength)" }
    }
    Assert-True $ok 'no BOM; no raw CR; header occupies [0, HeaderBytes); offsets chain to EOF' $why

    # -----------------------------------------------------------------------
    Enter-Section '3. The seek contract, on disk'
    # -----------------------------------------------------------------------
    $ok = $true; $why = ''
    foreach ($sr in $receipt.Shards)
    {
        $bytes = [IO.File]::ReadAllBytes($sr.Path)
        foreach ($row in $sr.Rows)
        {
            $span = $bytes[([int]$row.RowContentBegin)..([int]$row.RowContentEnd)]
            $got = $utf8.GetString([byte[]]$span)
            $entry = @($entries | Where-Object RelativePath -eq $row.RelativePath)[0]
            $want = ConvertTo-ContentSpan -Content $entry.Content
            if ($got -ne $want) { $ok = $false; $why = "$($row.RelativePath): '$got' != '$want'" }
            if ($row.ContentBytes -ne ($row.RowContentEnd - $row.RowContentBegin + 1)) { $ok = $false; $why = 'ContentBytes != end − begin + 1' }
        }
    }
    Assert-True $ok 'bytes at [RowContentBegin..RowContentEnd] are exactly the encoded span — every row, every shard' $why

    # -----------------------------------------------------------------------
    Enter-Section '4. gidx on disk'
    # -----------------------------------------------------------------------
    $Lg = Resolve-Layout -Header (New-Header 4) -Columns gidx
    $sg = [long](Measure-Row -Layout $Lg -Entry $entries[0])
    $sg1 = [long](Measure-Row -Layout $Lg -Entry $entries[1])
    $plang = New-ShardPlan -Entries $entries -Layout $Lg -OrderStrict -ShardQuotaBytes ([long]$Lg.HeaderBytes + $sg + $sg1) -ShardToleranceBytes 0
    $dirg = Join-Path $outRoot 'gidx'
    $receiptg = Invoke-Serialize -Plan $plang -Entries $entries -Layout $Lg -OutDir $dirg
    $ok = $true; $why = ''
    foreach ($sr in $receiptg.Shards)
    {
        $bytes = [IO.File]::ReadAllBytes($sr.Path)
        foreach ($row in $sr.Rows)
        {
            $text = $utf8.GetString($bytes[([int]$row.RowOffset)..([int]$row.RowMetaEnd)])
            $g = $plang.IdxMap[$row.RelativePath].GlobalIdx
            if (-not $text.StartsWith("$g | ")) { $ok = $false; $why = "row '$text' does not start with '$g | '" }
        }
    }
    Assert-True $ok 'every row on disk opens with its assigned GlobalIdx at the declared width' $why

    # -----------------------------------------------------------------------
    Enter-Section '5. Buffering — PerShard and Stream are byte-identical'
    # -----------------------------------------------------------------------
    $dirA = Join-Path $outRoot 'bufA'; $dirB = Join-Path $outRoot 'bufB'
    $rA = Invoke-Serialize -Plan $plan -Entries $entries -Layout $L0 -OutDir $dirA -Buffering PerShard
    $rB = Invoke-Serialize -Plan $plan -Entries $entries -Layout $L0 -OutDir $dirB -Buffering Stream
    $ok = $true
    for ($i = 0; $i -lt @($rA.Shards).Count; $i++)
    {
        $a = [IO.File]::ReadAllBytes($rA.Shards[$i].Path)
        $b = [IO.File]::ReadAllBytes($rB.Shards[$i].Path)
        if (-not [System.Linq.Enumerable]::SequenceEqual($a, $b)) { $ok = $false }
    }
    Assert-True $ok 'same bytes either way'

    # -----------------------------------------------------------------------
    Enter-Section '6. Oversized written whole'
    # -----------------------------------------------------------------------
    $entriesOv = @((New-Entry 'small.txt' 'aa'), (New-Entry 'big.txt' ('y' * 400)))
    $planOv = New-ShardPlan -Entries $entriesOv -Layout $L0 -OrderStrict -ShardQuotaBytes 100 -ShardToleranceBytes 20
    $dirOv = Join-Path $outRoot 'oversized'
    $rOv = Invoke-Serialize -Plan $planOv -Entries $entriesOv -Layout $L0 -OutDir $dirOv
    $ovr = @($rOv.Shards | Where-Object IsOversized)
    Assert-True ($ovr.Count -eq 1 -and $ovr[0].ByteLength -gt 120 -and $ovr[0].EntryCount -eq 1) 'the oversized shard is on disk, whole, flagged in the receipt' "len=$($ovr[0].ByteLength)"

    # -----------------------------------------------------------------------
    Enter-Section '7. The gate fires'
    # -----------------------------------------------------------------------
    $tampered = [pscustomobject]@{
        Plan   = $plan.Plan
        Groups = $plan.Groups
        Shards = @($plan.Shards | ForEach-Object {
                $c = [pscustomobject]@{}
                foreach ($p in $_.PSObject.Properties) { $c | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value }
                $c
            })
        IdxMap = $plan.IdxMap
    }
    $tampered.Shards[0].PlannedSizeBytes = $tampered.Shards[0].PlannedSizeBytes + 1
    $threw = $null; try { Invoke-Serialize -Plan $tampered -Entries $entries -Layout $L0 -OutDir (Join-Path $outRoot 'tampered') | Out-Null } catch { $threw = $_.Exception.Message }
    Assert-True ($null -ne $threw -and $threw -like '*plan = file VIOLATED*') 'a plan that disagrees with the bytes is an error, never a silent shrug' $threw

    # -----------------------------------------------------------------------
    Enter-Section '8. Empty plan'
    # -----------------------------------------------------------------------
    $planE = New-ShardPlan -Entries @() -Layout $L0
    $dirE = Join-Path $outRoot 'empty'
    $rE = Invoke-Serialize -Plan $planE -Entries @() -Layout $L0 -OutDir $dirE
    Assert-True ($rE.ShardCount -eq 0 -and $rE.TotalBytes -eq 0 -and @(Get-ChildItem $dirE -File).Count -eq 0) 'empty plan: no files, empty receipt'
}
catch
{
    Assert-True $false "SUITE ABORTED: $($_.Exception.Message)" $_.ScriptStackTrace
}
finally
{
    Remove-Item -Path $outRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
Write-Host "`n═══ serialize.tests: $script:Passed passed, $script:Failed failed ═══" -ForegroundColor $(if ($script:Failed -eq 0) { 'Green' } else { 'Red' })
if ($script:Failed -gt 0) { exit 1 }
