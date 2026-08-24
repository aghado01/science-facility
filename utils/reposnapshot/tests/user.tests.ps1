#Requires -Version 7.5
Set-StrictMode -Version Latest

<#
.SYNOPSIS
    rs.core.user — the convenience entry point, end to end: point at a
    directory, get a runstamped snapshot directory with shards + tree.

.DESCRIPTION
    Sections:
      1. One call, complete payload — runstamped dir under -OutRoot, shard
         files named <leaf>_sNNN.txt, tree present, sizes match the summary.
      2. The output convention — default OutRoot is <grandparent>/<leaf>
         (sibling of the project, named after the root); output inside the
         root is refused; same-second reruns get suffixed run dirs.
      3. Selection + PsStrip — only matching files ingest; comments are gone
         from the payload (verified by seeking the written bytes).
#>

$v3 = Join-Path $PSScriptRoot '..\reposnapshot-v3'
$userScript = Join-Path $v3 'rs.core.user.ps1'

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

# fixture: <tmp>/wrap/proj — 'wrap' exists so the DEFAULT OutRoot rule
# (<grandparent>/<leaf>) resolves inside the sandbox, not beside it
$tmp = Join-Path ([IO.Path]::GetTempPath()) "rs-user-test-$([guid]::NewGuid().ToString('N').Substring(0,8))"
$proj = Join-Path $tmp 'wrap\proj'
New-Item -ItemType Directory -Path (Join-Path $proj 'sub') -Force | Out-Null
Set-Content -Path (Join-Path $proj 'a.ps1') -Value "# strip me`nWrite-Host 'alpha'"
Set-Content -Path (Join-Path $proj 'sub\b.ps1') -Value '$x = 42'
Set-Content -Path (Join-Path $proj 'c.md') -Value 'prose file'
Set-Content -Path (Join-Path $proj '.gitignore') -Value '*.log'
Set-Content -Path (Join-Path $proj 'noise.log') -Value 'ignored'

try
{
    # -----------------------------------------------------------------------
    Enter-Section '1. One call, complete payload'
    # -----------------------------------------------------------------------
    $out1 = Join-Path $tmp 'out'
    $r = & $userScript -Root $proj -OutRoot $out1 -ShardQuotaBytes 4096 -ShardToleranceBytes 512 6>$null
    Assert-True ($r.EntryCount -eq 3 -and $r.ShardCount -ge 1) 'a.ps1, sub/b.ps1, c.md ingest; noise.log gitignored' "entries $($r.EntryCount)"
    Assert-True ((Split-Path $r.OutDir -Parent) -eq $out1 -and (Split-Path $r.OutDir -Leaf) -match '^\d{8}_\d{6}') 'output lands in <OutRoot>/<runstamp>/'
    $shardFiles = @(Get-ChildItem $r.OutDir -Filter 'proj_s*.txt')
    Assert-True ($shardFiles.Count -eq $r.ShardCount) 'shard files named <leaf>_sNNN.txt' "$($shardFiles.Count) vs $($r.ShardCount)"
    Assert-True ((Test-Path $r.TreePath) -and (Split-Path $r.TreePath -Leaf) -eq 'proj_tree.md') 'tree manifest beside the shards'
    $sum = ($shardFiles | Measure-Object -Sum Length).Sum
    Assert-True ($sum -eq $r.TotalBytes) 'summary TotalBytes == bytes on disk'
    $tree = Get-Content -Raw $r.TreePath
    Assert-True ($tree.Contains('a.ps1') -and $tree.Contains('b.ps1') -and $tree.Contains('- RunStamp: ' + $r.RunStamp)) 'tree declares the rows and this run''s stamp'

    # -----------------------------------------------------------------------
    Enter-Section '2. The output convention — .snapshot/ under the tree'
    # -----------------------------------------------------------------------
    $rd = & $userScript -Root $proj -ShardQuotaBytes 4096 6>$null
    Assert-True ((Split-Path $rd.OutDir -Parent) -eq (Join-Path $proj '.snapshot')) 'default OutRoot = <Root>/.snapshot — the house convention' $rd.OutDir
    Assert-True ((Split-Path $rd.OutDir -Leaf) -match '^\d{8}_\d{6}') '…runstamped'

    # the convention is safe by MEMBRANE, not by writer guard: a second run
    # over the same root must not ingest the first run's payload
    $rd2 = & $userScript -Root $proj -ShardQuotaBytes 4096 6>$null
    Assert-True ($rd2.EntryCount -eq $rd.EntryCount -and $rd2.EntryCount -eq 3) 'rerun ingests the same 3 entries — .snapshot/ is membrane-ignored by default (IgnoreDefaults)' "first $($rd.EntryCount), rerun $($rd2.EntryCount)"

    # same-second rerun → suffixed run dir, no clobber
    $rB = & $userScript -Root $proj -OutRoot $out1 -ShardQuotaBytes 4096 6>$null
    $rC = & $userScript -Root $proj -OutRoot $out1 -ShardQuotaBytes 4096 6>$null
    Assert-True ($rB.OutDir -ne $rC.OutDir -and (Test-Path $rB.TreePath) -and (Test-Path $rC.TreePath)) 'every run gets its own directory, collisions suffixed' "$($rB.RunStamp) / $($rC.RunStamp)"

    # -----------------------------------------------------------------------
    Enter-Section '3. Selection + PsStrip'
    # -----------------------------------------------------------------------
    $r2 = & $userScript -Root $proj -OutRoot (Join-Path $tmp 'out2') -SelectionPatterns '*.ps1' -PsStrip -PassThru 6>$null
    Assert-True ($r2.EntryCount -eq 2) 'Selection *.ps1: only the two scripts ingest' "entries $($r2.EntryCount)"
    $row = $null; $shardPath = $null
    foreach ($sr in $r2.Receipt.Shards)
    {
        foreach ($rr in $sr.Rows) { if ($rr.RelativePath -eq 'a.ps1') { $row = $rr; $shardPath = $sr.Path } }
    }
    $bytes = [IO.File]::ReadAllBytes($shardPath)
    $span = [System.Text.Encoding]::UTF8.GetString([byte[]]$bytes[([int]$row.RowContentBegin)..([int]$row.RowContentEnd)])
    Assert-True (-not $span.Contains('strip me') -and $span.Contains('alpha')) 'the comment is gone from the payload; the code is not (seeked from the written bytes)' $span
}
catch
{
    Assert-True $false "SUITE ABORTED: $($_.Exception.Message)" $_.ScriptStackTrace
}
finally
{
    Remove-Item -Path $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
Write-Host "`n═══ user.tests: $script:Passed passed, $script:Failed failed ═══" -ForegroundColor $(if ($script:Failed -eq 0) { 'Green' } else { 'Red' })
if ($script:Failed -gt 0) { exit 1 }
