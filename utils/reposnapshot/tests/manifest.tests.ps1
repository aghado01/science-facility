#Requires -Version 7.5
Set-StrictMode -Version Latest

<#
.SYNOPSIS
    rs.core.manifest — New-Manifest formats what upstream computed: receipt
    offsets, plan classes, layout header row, RunContext provenance. Nothing
    measured post hoc. Runs the real chain and parses the written tree back.

.DESCRIPTION
    Sections:
      1. Boundaries — bad receipt / layout throw; a receipt from a different
         run (size mismatch vs plan) throws the belt-and-braces check.
      2. The tree file — exists, LF-only, no BOM; declarations present:
         header row verbatim, offset unit, encoding, compaction notice.
      3. TocTree — every receipt row appears with its exact offsets and shard
         key; directories indent; root name from RunContext.Root.
      4. Payload block — tree leaf first, then every shard with files:N
         bytes:N (group tag when grouped).
      5. Hazards — an oversized shard is declared; absent section when none.
      6. Provenance — RunContext verbatim; determinism — identical inputs →
         identical bytes.
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
Import-Module (Join-Path $v3 'rs.core.manifest.psm1') -Force
$utf8 = [System.Text.UTF8Encoding]::new($false)

$outRoot = Join-Path ([IO.Path]::GetTempPath()) "rs-manifest-test-$([guid]::NewGuid().ToString('N').Substring(0,8))"
New-Item -ItemType Directory -Path $outRoot | Out-Null

function New-Header ([int]$EntryCount)
{
    [pscustomobject]@{ EntryCount = $EntryCount; Elements = [pscustomobject]@{} }
}

function New-Entry ([string]$Rel, [string]$Content)
{
    [pscustomobject]@{ RelativePath = $Rel; Extension = [IO.Path]::GetExtension($Rel); Content = $Content }
}

try
{
    # the real chain: layout → plan → serialize
    $L = Resolve-Layout -Header (New-Header 5)
    $entries = @(
        (New-Entry 'README.md' 'read me first')
        (New-Entry 'src/alpha.ps1' "function A { 'a' }")
        (New-Entry 'src/beta.ps1' "function B { 'b' }")
        (New-Entry 'src/lib/gamma.ps1' "function C { 'c' }")
        (New-Entry 'big.txt' ('z' * 400))                      # oversized at the chosen quota
    )
    $plan = New-ShardPlan -Entries $entries -Layout $L -OrderStrict -ShardQuotaBytes 160 -ShardToleranceBytes 40 -ShardStem 'fix'
    $receipt = Invoke-Serialize -Plan $plan -Entries $entries -Layout $L -OutDir $outRoot
    $runCtx = [pscustomobject]@{
        RunStamp         = '20260824_120000'
        Root             = 'X:/work/myproj'
        GeneratorVersion = 'reposnapshot-v3'
        ConfigEcho       = [pscustomobject]@{ Grouping = 'Flat'; Chain = @('file-read') }
    }
    $treePath = Join-Path $outRoot 'fix_tree.md'

    # -----------------------------------------------------------------------
    Enter-Section '1. Boundaries'
    # -----------------------------------------------------------------------
    $threw = $null; try { New-Manifest -Receipt ([pscustomobject]@{ X = 1 }) -Shards $plan.Shards -Plan $plan.Plan -Layout $L -RunContext $runCtx -TreePath $treePath | Out-Null } catch { $threw = $_.Exception.Message }
    Assert-True ($null -ne $threw -and $threw -like '*serialize.out.receipt*') 'a non-receipt throws' $threw
    $threw = $null; try { New-Manifest -Receipt $receipt -Shards $plan.Shards -Plan $plan.Plan -Layout ([pscustomobject]@{ Y = 2 }) -RunContext $runCtx -TreePath $treePath | Out-Null } catch { $threw = $_.Exception.Message }
    Assert-True ($null -ne $threw -and $threw -like '*container.out.layout*') 'a non-layout throws' $threw

    # a receipt from a different run: tamper one ByteLength
    $badShards = @($receipt.Shards | ForEach-Object {
            $c = [pscustomobject]@{}
            foreach ($p in $_.PSObject.Properties) { $c | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value }
            $c
        })
    $badShards[0].ByteLength = $badShards[0].ByteLength + 1
    $badReceipt = [pscustomobject]@{ Shards = $badShards; ShardCount = $receipt.ShardCount; TotalBytes = $receipt.TotalBytes; Encoding = $receipt.Encoding }
    $threw = $null; try { New-Manifest -Receipt $badReceipt -Shards $plan.Shards -Plan $plan.Plan -Layout $L -RunContext $runCtx -TreePath $treePath | Out-Null } catch { $threw = $_.Exception.Message }
    Assert-True ($null -ne $threw -and $threw -like '*different runs*') 'plan/receipt disagreement throws (belt and braces over serialize''s gate)' $threw

    # -----------------------------------------------------------------------
    Enter-Section '2. The tree file and its declarations'
    # -----------------------------------------------------------------------
    $m = New-Manifest -Receipt $receipt -Shards $plan.Shards -Plan $plan.Plan -Layout $L -RunContext $runCtx -TreePath $treePath
    Assert-True ((Test-Path $treePath) -and $m.Path -eq $treePath -and $null -ne $m.Model) 'writes exactly one file and returns @{ Path; Model }'
    $bytes = [IO.File]::ReadAllBytes($treePath)
    Assert-True (-not ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB) -and -not ($bytes -contains 0x0D)) 'tree file is UTF-8 no BOM, LF only'
    $text = $utf8.GetString($bytes)
    Assert-True ($text.Contains($L.HeaderRowText)) 'the psr header row is declared VERBATIM — one declaration, third sink' $L.HeaderRowText
    Assert-True ($text.Contains('bytes, 0-based, end offsets inclusive')) 'offsets carry their unit (payload-manifest #8)'
    Assert-True ($text.Contains('utf-8') -and $text.Contains('no BOM')) 'emission encoding declared (payload-manifest #17)'
    Assert-True ($text.Contains('not a cipher key')) 'compaction is a notice, not a cipher key (payload-manifest #16, #10)'
    Assert-True ($text.Contains("Grouping: Flat") -and $text.Contains("Created: 20260824_120000") -and $text.Contains("Shards: $($plan.Plan.ShardCount)")) 'summary line composed from plan + RunContext, never preformatted upstream'
    Assert-True ($m.Model.ColumnHeader -eq $L.HeaderRowText -and $m.Model.OffsetUnit -like 'bytes*') 'model fields are checkable, not prose'

    # -----------------------------------------------------------------------
    Enter-Section '3. TocTree — receipt offsets verbatim, tree shape'
    # -----------------------------------------------------------------------
    $ok = $true; $why = ''
    foreach ($sr in $receipt.Shards)
    {
        foreach ($row in $sr.Rows)
        {
            $leaf = ([string]$row.RelativePath -split '/')[-1]
            $expect = "$leaf`t$($sr.Key)`t$($row.RowOffset)`t$($row.RowMetaEnd)`t$($row.RowContentBegin)`t$($row.RowContentEnd)"
            if (-not $text.Contains($expect)) { $ok = $false; $why = $expect }
        }
    }
    Assert-True $ok 'every receipt row appears with its exact offsets and shard key — values verbatim, never recomputed' $why
    Assert-True ($text.Contains("`nmyproj`n")) 'tree root is RunContext.Root''s leaf name'
    Assert-True ($text -match "(?m)^    src`n") 'directories indent (src under root)'
    Assert-True ($text -match "(?m)^        lib`n") 'nested directories indent deeper (src/lib)'

    # -----------------------------------------------------------------------
    Enter-Section '4. Payload block'
    # -----------------------------------------------------------------------
    Assert-True ($text.Contains('`./fix_tree.md`')) 'the tree file leads the payload list'
    $ok = $true
    foreach ($sr in $receipt.Shards)
    {
        if (-not $text.Contains("``./$(Split-Path $sr.Path -Leaf)`` files:$($sr.EntryCount) bytes:$($sr.ByteLength)")) { $ok = $false }
    }
    Assert-True $ok 'one payload line per shard: leaf, files:N, bytes:N'

    # -----------------------------------------------------------------------
    Enter-Section '5. Hazards'
    # -----------------------------------------------------------------------
    $ovKey = @($receipt.Shards | Where-Object IsOversized)[0].Key
    Assert-True (@($m.Model.Hazards).Count -eq 1 -and $m.Model.Hazards[0].Key -eq $ovKey) 'the oversized shard is a declared hazard'
    Assert-True ($text.Contains("``$ovKey``") -and $text.Contains('kept whole (atomicity)')) '…and the reader is told to read it whole'

    # no oversized → no hazards section
    $plan2 = New-ShardPlan -Entries $entries[0..3] -Layout $L -OrderStrict -ShardQuotaBytes 400 -ShardToleranceBytes 0 -ShardStem 'fix2'
    $receipt2 = Invoke-Serialize -Plan $plan2 -Entries $entries[0..3] -Layout $L -OutDir (Join-Path $outRoot 'two')
    $m2 = New-Manifest -Receipt $receipt2 -Shards $plan2.Shards -Plan $plan2.Plan -Layout $L -RunContext $runCtx -TreePath (Join-Path $outRoot 'two\fix2_tree.md')
    $text2 = [IO.File]::ReadAllText($m2.Path)
    Assert-True (@($m2.Model.Hazards).Count -eq 0 -and -not $text2.Contains('Hazards')) 'no oversized shards → no hazards section at all'

    # -----------------------------------------------------------------------
    Enter-Section '6. Provenance and determinism'
    # -----------------------------------------------------------------------
    Assert-True ($text.Contains('- Root: X:/work/myproj') -and $text.Contains('- GeneratorVersion: reposnapshot-v3')) 'RunContext rendered verbatim — provenance is input, never hardcoded'
    Assert-True ($text.Contains('"Grouping":"Flat"')) 'ConfigEcho survives as compact JSON'
    # same LEAF name (the tree names itself in its payload list), different dir
    New-Item -ItemType Directory -Path (Join-Path $outRoot 'again') | Out-Null
    $treeB = Join-Path $outRoot 'again\fix_tree.md'
    $null = New-Manifest -Receipt $receipt -Shards $plan.Shards -Plan $plan.Plan -Layout $L -RunContext $runCtx -TreePath $treeB
    Assert-True ([System.Linq.Enumerable]::SequenceEqual([IO.File]::ReadAllBytes($treePath), [IO.File]::ReadAllBytes($treeB))) 'identical inputs → byte-identical tree'
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
Write-Host "`n═══ manifest.tests: $script:Passed passed, $script:Failed failed ═══" -ForegroundColor $(if ($script:Failed -eq 0) { 'Green' } else { 'Red' })
if ($script:Failed -gt 0) { exit 1 }
