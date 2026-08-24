#Requires -Version 7.5
Set-StrictMode -Version Latest

<#
.SYNOPSIS
    The SELFIE fixture: the pipeline snapshots its own source. Root =
    reposnapshot-v3/, Selection semantics for *.ps1 / *.psm1 only, the real
    ingest chain (file-read → rs-whitespace → rs-psstrip → rs-content_meta),
    then the full export path to disk and back. PowerShell ingesting
    PowerShell — the standing conflation hotspot, exercised on purpose.

.DESCRIPTION
    A LIVING fixture, not a golden: the corpus is the module's own code and
    changes whenever the code does, so every assertion is an invariant or is
    checked against ground truth recomputed here (an independent directory
    walk), never an exact count.

    Sections:
      1. Crawl → membrane (Selection) — survivors equal the independent walk
         of *.ps1/*.psm1, exactly, as sets.
      2. Ingest → assemble — every survivor becomes an entry; ContentMeta at
         full presence; the carried Extension is on every entry.
      3. Layout + plan (working defaults; gidx + content_meta on;
         ByFileType) — coverage, containment, bounds, IdxMap totality,
         plan determinism from one IR.
      4. Serialize → disk — the seek contract verified for EVERY row of the
         real payload; no raw CR anywhere; totals match.
      5. The #48 four-cell harness on the selfie corpus — the first
         real-payload shape numbers, printed each battery run; ShardCount
         must be shape-invariant per strictness.

.NOTES
    Run from any directory:
        & "$PSScriptRoot\selfie.tests.ps1"
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

Import-Module (Join-Path $v3 'rs.core.crawler.psm1') -Force
Import-Module (Join-Path $v3 'rs.core.membrane.psm1') -Force
Import-Module (Join-Path $v3 'rs.core.colonel.v2.psm1') -Force
Import-Module (Join-Path $v3 'rs.core.ingest.psm1') -Force
Import-Module (Join-Path $v3 'rs.core.assemble.psm1') -Force
Import-Module (Join-Path $v3 'rs.core.container.psm1') -Force
Import-Module (Join-Path $v3 'rs.core.shards.psm1') -Force
Import-Module (Join-Path $v3 'rs.core.serialize.psm1') -Force
$utf8 = [System.Text.UTF8Encoding]::new($false)

$outRoot = Join-Path ([IO.Path]::GetTempPath()) "rs-selfie-$([guid]::NewGuid().ToString('N').Substring(0,8))"
New-Item -ItemType Directory -Path $outRoot | Out-Null

try
{
    # ground truth: an independent walk, no pipeline code involved
    $rootFull = (Resolve-Path $v3).Path
    $truth = @(Get-ChildItem -Path $rootFull -Recurse -File | Where-Object { $_.Extension -in '.ps1', '.psm1' } |
            ForEach-Object { $_.FullName.Substring($rootFull.Length).TrimStart('\', '/') -replace '\\', '/' } | Sort-Object)
    Assert-True ($truth.Count -ge 20) "the corpus is real: $($truth.Count) PowerShell files under reposnapshot-v3" "$($truth.Count)"

    # -----------------------------------------------------------------------
    Enter-Section '1. Crawl → membrane: Selection *.ps1 / *.psm1'
    # -----------------------------------------------------------------------
    $crawl = (New-FileSystemCrawler -RootPath $v3).Invoke()
    Assert-True ($crawl.FileCount -ge $truth.Count) 'crawler sees at least the PowerShell files (plus contracts, changelogs, …)'

    $compiled = New-GlobCompiler -CrawlerGraph $crawl.Graph -GlobSemantics Selection -SelectionPatterns @('*.ps1', '*.psm1')
    $filtered = Invoke-Membrane -CompiledNodes $compiled.CompiledNodes -CrawlerGraph $crawl.Graph
    $survivors = @($filtered.Graph.Values | ForEach-Object { $_.Files } | ForEach-Object { $_.RelativePath } | Sort-Object)
    Assert-True (($survivors -join "`n") -eq ($truth -join "`n")) 'survivors == the independent walk, exactly, as sets' "pipeline $($survivors.Count) vs truth $($truth.Count)"
    Assert-True (@($survivors | Where-Object { $_ -notmatch '\.(ps1|psm1)$' }).Count -eq 0) 'nothing but PowerShell passed the membrane'

    # -----------------------------------------------------------------------
    Enter-Section '2. Ingest → assemble: the real chain over the real source'
    # -----------------------------------------------------------------------
    $ingest = Invoke-Ingest -FilteredFsGraph $filtered `
        -Manifest @{
        'file-read'       = (Join-Path $v3 'processors\file-read.ps1')
        'rs-whitespace'   = (Join-Path $v3 'processors\rs-whitespace.ps1')
        'rs-psstrip'      = (Join-Path $v3 'processors\rs-psstrip.ps1')
        'rs-content_meta' = (Join-Path $v3 'processors\rs-content_meta.ps1')
    } `
        -Steps @(
        @{ Key = 'file-read'; Config = @{} }
        @{ Key = 'rs-whitespace'; Config = @{ Operations = @('lf', 'trim-trailing', 'trim-doc') } }
        @{ Key = 'rs-psstrip'; Config = @{ Operations = @('block-comments', 'doc-strings', 'comment-blocks', 'line-comments') } }
        @{ Key = 'rs-content_meta'; Config = @{} }
    ) `
        -ChainExecutorPath (Join-Path $v3 'processors\chain-executor.ps1') `
        -SharedHelperPath (Join-Path $v3 'processors\bag-helpers.ps1')
    Assert-True (@($ingest.Errors).Count -eq 0) 'no compile/dispatch errors over the whole corpus' ($ingest.Errors -join '; ')
    Assert-True (@($ingest.Results).Count -eq $truth.Count) 'every survivor dispatched' "got $(@($ingest.Results).Count)"

    $ir = Invoke-Assemble -DispatchOutput $ingest
    Assert-True ($ir.Header.EntryCount -eq $truth.Count) 'every survivor became an entry (PowerShell source reads clean — no binary halts, no empties)' "EntryCount $($ir.Header.EntryCount)"
    $cm = $ir.Header.Elements.PSObject.Properties['ContentMeta']
    Assert-True ($null -ne $cm -and $cm.Value.Count -eq $cm.Value.Total) 'ContentMeta at full presence — the chain ran end to end'
    $extOk = $true
    foreach ($e in $ir.Entries) { if ($e.Extension -notin '.ps1', '.psm1') { $extOk = $false } }
    Assert-True $extOk 'the carried Extension rides every entry (#50), and it is PowerShell'

    # -----------------------------------------------------------------------
    Enter-Section '3. Layout + plan: working defaults, gidx + content_meta, ByFileType'
    # -----------------------------------------------------------------------
    $L = Resolve-Layout -Header $ir.Header -Columns gidx, content_meta
    Assert-True ($L.IdxWidth -eq ([string]$ir.Header.EntryCount).Length) 'IdxWidth = digits(EntryCount), resolved from the real IR'

    $plan = New-ShardPlan -Entries $ir.Entries -Layout $L -Grouping ByFileType -ShardStem 'selfie'
    Assert-True ($plan.Plan.TotalEntries -eq $ir.Header.EntryCount) 'plan covers the IR'
    Assert-True ((($plan.Groups | ForEach-Object GroupKey) -join ',') -eq '.ps1,.psm1') 'two groups, from the carried Extension' (($plan.Groups | ForEach-Object GroupKey) -join ',')
    $ok = $true
    foreach ($sh in $plan.Shards)
    {
        foreach ($ei in $sh.Entries) { if ($ir.Entries[$ei].Extension.ToLowerInvariant() -ne $sh.GroupKey) { $ok = $false } }
    }
    Assert-True $ok 'group containment on real data — no shard mixes languages'
    Assert-True ($plan.Plan.MaxOvershootBytes -le $plan.Plan.ShardToleranceBytes) 'tolerance-facing bound holds at the working defaults'
    $gapOk = $true
    foreach ($g in $plan.Groups) { if ($g.Gap -lt 0) { $gapOk = $false } }
    Assert-True $gapOk 'Gap ≥ 0 in every group (the ceiling-anchored bound is a true bound on real sizes)'
    Assert-True (@($ir.Entries | Where-Object { -not $plan.IdxMap.Contains([string]$_.RelativePath) }).Count -eq 0) 'IdxMap is total over the corpus'
    $plan2 = New-ShardPlan -Entries $ir.Entries -Layout $L -Grouping ByFileType -ShardStem 'selfie'
    Assert-True (($plan | ConvertTo-Json -Depth 8 -Compress) -eq ($plan2 | ConvertTo-Json -Depth 8 -Compress)) 'the plan is deterministic from one IR'

    # -----------------------------------------------------------------------
    Enter-Section '4. Serialize → disk: the payload is real'
    # -----------------------------------------------------------------------
    $receipt = Invoke-Serialize -Plan $plan -Entries $ir.Entries -Layout $L -OutDir $outRoot
    Assert-True ($receipt.TotalBytes -eq $plan.Plan.TotalPlannedSizeBytes) "plan = file across the whole payload ($($receipt.TotalBytes) bytes, $($receipt.ShardCount) shards)"

    $byRel = @{}
    foreach ($e in $ir.Entries) { $byRel[[string]$e.RelativePath] = $e }
    $seekOk = $true; $crOk = $true; $why = ''
    $rowsChecked = 0
    foreach ($sr in $receipt.Shards)
    {
        $bytes = [IO.File]::ReadAllBytes($sr.Path)
        if ($bytes -contains 0x0D) { $crOk = $false }
        foreach ($row in $sr.Rows)
        {
            $span = $bytes[([int]$row.RowContentBegin)..([int]$row.RowContentEnd)]
            $want = ConvertTo-ContentSpan -Content $byRel[$row.RelativePath].Content
            if ($utf8.GetString([byte[]]$span) -ne $want) { $seekOk = $false; $why = $row.RelativePath }
            $rowsChecked++
        }
    }
    Assert-True $seekOk "the seek contract holds for every row of the real payload ($rowsChecked rows)" $why
    Assert-True $crOk 'no raw CR anywhere on disk — CRLF source normalized end to end'

    # -----------------------------------------------------------------------
    Enter-Section '5. The #48 harness on the selfie corpus (Flat, real sizes)'
    # -----------------------------------------------------------------------
    Write-Host ''
    Write-Host ('    {0,-18} {1,4} {2,4} {3,4} {4,7} {5,6} {6,7} {7,7}' -f 'cell', 'k', 'LB', 'Gap', 'TotO', 'MaxO', 'MaxF', 'MinF') -ForegroundColor DarkGray
    $cells = @{}
    foreach ($strict in $true, $false)
    {
        foreach ($shape in 'FrontLoad', 'Even')
        {
            $p = New-ShardPlan -Entries $ir.Entries -Layout $L -OrderStrict:$strict -PackObjective $shape
            $key = "$(if ($strict) { 'strict' } else { 'flex' })/$shape"
            $cells[$key] = $p.Plan
            Write-Host ('    {0,-18} {1,4} {2,4} {3,4} {4,7} {5,6} {6,7} {7,7}' -f $key, $p.Plan.ShardCount, ($p.Groups[0].LowerBound), ($p.Groups[0].Gap), $p.Plan.TotalOvershootBytes, $p.Plan.MaxOvershootBytes, $p.Plan.MaxFillBytes, $p.Plan.MinFillBytes) -ForegroundColor DarkGray
        }
    }
    Assert-True ($cells['strict/FrontLoad'].ShardCount -eq $cells['strict/Even'].ShardCount) 'ShardCount is shape-invariant under strict, on real data'
    Assert-True ($cells['flex/FrontLoad'].ShardCount -eq $cells['flex/Even'].ShardCount) 'ShardCount is shape-invariant under flexible, on real data'
    Assert-True ($cells['flex/FrontLoad'].ShardCount -le $cells['strict/FrontLoad'].ShardCount) 'flexible never worse than strict, on real data'
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
Write-Host "`n═══ selfie.tests: $script:Passed passed, $script:Failed failed ═══" -ForegroundColor $(if ($script:Failed -eq 0) { 'Green' } else { 'Red' })
if ($script:Failed -gt 0) { exit 1 }
