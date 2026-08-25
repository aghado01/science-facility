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
      4. Config file — -ConfigPath drives a bare invocation; an explicit CLI
         arg still beats it; a bad enum value or a missing explicit path
         fails fast with a clear message; a Root absent from both fails fast.
      5. Inline -Config — a hashtable and a PSCustomObject both drive a bare
         invocation with no file at all; -Config and -ConfigPath together
         (both explicit) is refused rather than silently picking one.
      6. -Processors — a mixed bare-string/object chain runs rs-psstrip with
         its own Config, independent of -PsStrip; an unknown key or a
         Key-less entry fails fast; omitting rs-whitespace prints a caution.

.NOTES
    rs.core.user.ps1 auto-discovers reposnapshot-v3/user-config.json by
    default (no -ConfigPath needed), so sections 1-3 pass an explicit,
    deliberately-empty -ConfigPath — they assert what pure CLI args do, and
    must not be at the mercy of whatever the real, live config happens to
    hold on any given day. Sections 4-6 test the config/processor mechanism
    itself, via their own throwaway fixture files/objects.
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

# neutral config fixture — rs.core.user.ps1 auto-discovers the real, live
# reposnapshot-v3/user-config.json by default; sections 1-3 pin an explicit,
# empty one so their assertions describe pure CLI-arg behavior only.
$emptyConfig = Join-Path $tmp 'empty-config.json'
Set-Content -Path $emptyConfig -Value '{}'

try
{
    # -----------------------------------------------------------------------
    Enter-Section '1. One call, complete payload'
    # -----------------------------------------------------------------------
    $out1 = Join-Path $tmp 'out'
    $r = & $userScript -Root $proj -OutRoot $out1 -ShardQuotaBytes 4096 -ShardToleranceBytes 512 -ConfigPath $emptyConfig 6>$null
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
    $rd = & $userScript -Root $proj -ShardQuotaBytes 4096 -ConfigPath $emptyConfig 6>$null
    Assert-True ((Split-Path $rd.OutDir -Parent) -eq (Join-Path $proj '.snapshot')) 'default OutRoot = <Root>/.snapshot — the house convention' $rd.OutDir
    Assert-True ((Split-Path $rd.OutDir -Leaf) -match '^\d{8}_\d{6}') '…runstamped'

    # the convention is safe by MEMBRANE, not by writer guard: a second run
    # over the same root must not ingest the first run's payload
    $rd2 = & $userScript -Root $proj -ShardQuotaBytes 4096 -ConfigPath $emptyConfig 6>$null
    Assert-True ($rd2.EntryCount -eq $rd.EntryCount -and $rd2.EntryCount -eq 3) 'rerun ingests the same 3 entries — .snapshot/ is membrane-ignored by default (IgnoreDefaults)' "first $($rd.EntryCount), rerun $($rd2.EntryCount)"

    # same-second rerun → suffixed run dir, no clobber
    $rB = & $userScript -Root $proj -OutRoot $out1 -ShardQuotaBytes 4096 -ConfigPath $emptyConfig 6>$null
    $rC = & $userScript -Root $proj -OutRoot $out1 -ShardQuotaBytes 4096 -ConfigPath $emptyConfig 6>$null
    Assert-True ($rB.OutDir -ne $rC.OutDir -and (Test-Path $rB.TreePath) -and (Test-Path $rC.TreePath)) 'every run gets its own directory, collisions suffixed' "$($rB.RunStamp) / $($rC.RunStamp)"

    # -----------------------------------------------------------------------
    Enter-Section '3. Selection + PsStrip'
    # -----------------------------------------------------------------------
    $r2 = & $userScript -Root $proj -OutRoot (Join-Path $tmp 'out2') -SelectionPatterns '*.ps1' -PsStrip -PassThru -ConfigPath $emptyConfig 6>$null
    Assert-True ($r2.EntryCount -eq 2) 'Selection *.ps1: only the two scripts ingest' "entries $($r2.EntryCount)"
    $row = $null; $shardPath = $null
    foreach ($sr in $r2.Receipt.Shards)
    {
        foreach ($rr in $sr.Rows) { if ($rr.RelativePath -eq 'a.ps1') { $row = $rr; $shardPath = $sr.Path } }
    }
    $bytes = [IO.File]::ReadAllBytes($shardPath)
    $span = [System.Text.Encoding]::UTF8.GetString([byte[]]$bytes[([int]$row.RowContentBegin)..([int]$row.RowContentEnd)])
    Assert-True (-not $span.Contains('strip me') -and $span.Contains('alpha')) 'the comment is gone from the payload; the code is not (seeked from the written bytes)' $span

    # -----------------------------------------------------------------------
    Enter-Section '4. Config file'
    # -----------------------------------------------------------------------
    # Own fixture, not $proj — by this point $proj/.snapshot/ already holds
    # tree.md files from section 2's default-OutRoot reruns, which a *.md
    # selection below would otherwise sweep up as false extra entries.
    $proj4 = Join-Path $tmp 'proj4'
    New-Item -ItemType Directory -Path (Join-Path $proj4 'sub') -Force | Out-Null
    Set-Content -Path (Join-Path $proj4 'a.ps1') "# strip me`nWrite-Host 'alpha'"
    Set-Content -Path (Join-Path $proj4 'sub\b.ps1') '$x = 42'
    Set-Content -Path (Join-Path $proj4 'c.md') 'prose file'

    $out4 = Join-Path $tmp 'out4'
    $cfgPath = Join-Path $tmp 'config.json'
    @{ Root = $proj4; OutRoot = $out4; SelectionPatterns = @('*.ps1'); PsStrip = $true } | ConvertTo-Json | Set-Content -Path $cfgPath

    $r4 = & $userScript -ConfigPath $cfgPath 6>$null
    Assert-True ($r4.EntryCount -eq 2) 'bare invocation, config only: Selection *.ps1 from the config ingests a.ps1 + sub/b.ps1' "entries $($r4.EntryCount)"
    Assert-True ((Split-Path $r4.OutDir -Parent) -eq $out4) 'OutRoot came from the config' $r4.OutDir

    $r5 = & $userScript -ConfigPath $cfgPath -SelectionPatterns '*.md' 6>$null
    Assert-True ($r5.EntryCount -eq 1) 'explicit CLI -SelectionPatterns overrides the config''s' "entries $($r5.EntryCount)"

    $threw = $null; try { & $userScript -Root $proj4 -ConfigPath (Join-Path $tmp 'does-not-exist.json') 6>$null } catch { $threw = $_.Exception.Message }
    Assert-True ($null -ne $threw -and $threw -like '*does not exist*') 'explicit -ConfigPath naming a missing file throws' $threw

    # Grouping keeps its param-block [ValidateSet] working for free: PowerShell
    # re-validates a variable against its own attribute on every reassignment
    # in-scope, not just at initial binding — so the config-merge line itself
    # throws PowerShell's own error, deliberately not a custom message.
    $badCfgPath = Join-Path $tmp 'config-bad.json'
    @{ Root = $proj4; Grouping = 'Sideways' } | ConvertTo-Json | Set-Content -Path $badCfgPath
    $threw = $null; try { & $userScript -ConfigPath $badCfgPath 6>$null } catch { $threw = $_.Exception.Message }
    Assert-True ($null -ne $threw -and $threw -like '*Sideways*Grouping*') 'a bad enum value in the config fails fast, not deep in the pipeline' $threw

    $threw = $null; try { & $userScript -ConfigPath $emptyConfig 6>$null } catch { $threw = $_.Exception.Message }
    Assert-True ($null -ne $threw -and $threw -like '*-Root is required*') 'Root absent from both CLI and config throws, no interactive prompt' $threw

    # -----------------------------------------------------------------------
    Enter-Section '5. Inline -Config'
    # -----------------------------------------------------------------------
    $r6 = & $userScript -Config @{ Root = $proj4; OutRoot = $out4; SelectionPatterns = @('*.ps1'); PsStrip = $true } 6>$null
    Assert-True ($r6.EntryCount -eq 2) 'a hashtable passed to -Config drives a bare invocation, no file at all' "entries $($r6.EntryCount)"

    # a PSCustomObject (e.g. a ConvertFrom-Json result without -AsHashtable)
    # must work too — ConvertTo-ConfigHashtable normalizes either shape
    $asObject = [pscustomobject]@{ Root = $proj4; OutRoot = $out4; SelectionPatterns = @('*.md') }
    $r7 = & $userScript -Config $asObject 6>$null
    Assert-True ($r7.EntryCount -eq 1) 'a PSCustomObject passed to -Config works the same as a hashtable' "entries $($r7.EntryCount)"

    $threw = $null; try { & $userScript -Config @{ Root = $proj4 } -ConfigPath $cfgPath 6>$null } catch { $threw = $_.Exception.Message }
    Assert-True ($null -ne $threw -and $threw -like '*-Config or -ConfigPath, not both*') '-Config and -ConfigPath both explicit: refused, not silently resolved' $threw

    # -----------------------------------------------------------------------
    Enter-Section '6. -Processors'
    # -----------------------------------------------------------------------
    $out6 = Join-Path $tmp 'out6'
    $r8 = & $userScript -Root $proj4 -OutRoot $out6 -SelectionPatterns '*.ps1' `
        -Processors 'rs-whitespace', @{ Key = 'rs-psstrip'; Config = @{ Operations = @('line-comments') } } `
        -PassThru -ConfigPath $emptyConfig 6>$null
    Assert-True ($r8.EntryCount -eq 2) 'mixed bare-string + object chain: Selection still applies' "entries $($r8.EntryCount)"
    $row = $null; $shardPath = $null
    foreach ($sr in $r8.Receipt.Shards)
    {
        foreach ($rr in $sr.Rows) { if ($rr.RelativePath -eq 'a.ps1') { $row = $rr; $shardPath = $sr.Path } }
    }
    $bytes = [IO.File]::ReadAllBytes($shardPath)
    $span = [System.Text.Encoding]::UTF8.GetString([byte[]]$bytes[([int]$row.RowContentBegin)..([int]$row.RowContentEnd)])
    Assert-True (-not $span.Contains('strip me') -and $span.Contains('alpha')) 'the object entry''s own Config (Operations) took effect, with no -PsStrip passed at all' $span

    $threw = $null; try { & $userScript -Root $proj4 -Processors 'rs-nonexistent' -ConfigPath $emptyConfig 6>$null } catch { $threw = $_.Exception.Message }
    Assert-True ($null -ne $threw -and $threw -like "*'rs-nonexistent'*Known:*") 'an unknown processor key fails fast, names the file it looked for' $threw

    $threw = $null; try { & $userScript -Root $proj4 -Processors @{ Config = @{} } -ConfigPath $emptyConfig 6>$null } catch { $threw = $_.Exception.Message }
    Assert-True ($null -ne $threw -and $threw -like "*missing 'Key'*") 'a -Processors entry with no Key fails fast' $threw

    # rs-whitespace omitted deliberately — capture stream 6 (Write-Host) instead
    # of discarding it, to prove the caution is the mechanism actually printing
    # and not just source that never runs.
    $combined = & $userScript -Root $proj4 -Processors 'rs-content_meta' -ConfigPath $emptyConfig 6>&1
    $infoText = (@($combined | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { $_.MessageData.Message }) -join "`n")
    Assert-True ($infoText -like '*omits rs-whitespace*') 'a chain missing rs-whitespace prints a caution, not an error' $infoText
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
