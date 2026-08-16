#Requires -Version 7.5
Set-StrictMode -Version Latest

<#
.SYNOPSIS
    Formal test harness for rs.core.assemble.psm1 — units + golden comparison
    against a live LTS monolith.

.DESCRIPTION
    Covers:
      1. Contract checks — missing Results throws; reserved RunContext names throw
      2. Adapt + route (LeanPayload) — exclusion list, routing reasons
         (read-failure kind / NullResult / NoContent / EmptyFile /
         EmptiedByProcessing), ingested order preserved
      3. Open element model — Elements declaration counts; unknown future
         element (WordCloud) declared with zero assemble knowledge
      4. Header stamping — RunContext verbatim + derived EntryCount/Elements
      5. KeepContentless routing — LTS-style content-less entries, ReadError
         retained in the bag
      6. Skipped/Errors/Warnings pass-through
      7. GOLDEN — full v3 pipeline (crawl → ignore → ingest[file-read,
         rs-attributes] → assemble) vs a live LTS Get-RepoSnapshot monolith
         over a normal-form fixture (LF-only, no trailing newline, no blank
         runs ≥2 — Normalize-FileContent is the identity on it, making
         byte-exact content comparison honest). Matching is by path KEY,
         never position (LTS monoliths are path-sorted views). Known deltas
         asserted as documented: compression_ratio (LTS defect emits 0),
         size_bytes vs SpanBytes (equal here because UTF-8 no-BOM on-disk
         bytes == content bytes), binary entries (LTS keeps content-less;
         v3 routes to Diagnostics).

.NOTES
    Run from any directory:
        & "$PSScriptRoot\assemble.tests.ps1"
#>

$v3 = Join-Path $PSScriptRoot '..\reposnapshot-v3'
$ltsPath = Join-Path $PSScriptRoot '..\RepoSnapshotLts.psm1'

# ---------------------------------------------------------------------------
# Minimal assertion framework (house pattern — see colonel-dispatch.tests.ps1)
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

Import-Module (Join-Path $v3 'rs.core.assemble.psm1') -Force

# ---------------------------------------------------------------------------
# Hand-built dispatch envelope for unit sections
# ---------------------------------------------------------------------------
function New-Result ([hashtable]$Props)
{
    $bag = [ordered]@{}
    foreach ($k in $Props.Keys) { $bag[$k] = $Props[$k] }
    [pscustomobject]$bag
}

$now = [datetime]::UtcNow
$unitEnvelope = [pscustomobject]@{
    Results  = @(
        (New-Result @{ AbsolutePath = 'C:/r/a.ps1'; RelativePath = 'a.ps1'; NodePath = ''; Extension = '.ps1'; SizeBytes = 10L; LastWriteUtc = $now; CreationUtc = $now; FsAttributes = [IO.FileAttributes]::Archive; Content = 'alpha'; Encoding = 'UTF-8'; Attributes = [pscustomobject]@{ SpanBytes = 5 } }),
        (New-Result @{ AbsolutePath = 'C:/r/bin.dat'; RelativePath = 'bin.dat'; NodePath = ''; SizeBytes = 4L; LastWriteUtc = $now; ReadError = 'BinaryOrNulContent'; _ChainHalt = $true }),
        $null,
        (New-Result @{ AbsolutePath = 'C:/r/empty.txt'; RelativePath = 'empty.txt'; NodePath = ''; SizeBytes = 0L; LastWriteUtc = $now; Content = ''; Encoding = 'UTF-8' }),
        (New-Result @{ AbsolutePath = 'C:/r/gutted.ps1'; RelativePath = 'gutted.ps1'; NodePath = ''; SizeBytes = 99L; LastWriteUtc = $now; Content = ''; Encoding = 'UTF-8' }),
        (New-Result @{ AbsolutePath = 'C:/r/sub/b.ps1'; RelativePath = 'sub/b.ps1'; NodePath = 'sub/'; SizeBytes = 20L; LastWriteUtc = $now; Content = 'beta'; Encoding = 'UTF-8'; Attributes = [pscustomobject]@{ SpanBytes = 4 }; WordCloud = @('beta') })
    )
    Skipped  = @([pscustomobject]@{ Path = 'C:/r/x.png'; Reason = 'ExtensionBlacklisted' })
    Errors   = @('one error')
    Warnings = @('one warning')
}

# ---------------------------------------------------------------------------
Enter-Section '1. Contract checks'
# ---------------------------------------------------------------------------
$threw = $false
try { Invoke-Assemble -DispatchOutput ([pscustomobject]@{ NotResults = 1 }) | Out-Null } catch { $threw = $true }
Assert-True $threw 'missing Results throws contract error'

$threw = $false
try { Invoke-Assemble -DispatchOutput $unitEnvelope -RunContext ([pscustomobject]@{ EntryCount = 5 }) | Out-Null } catch { $threw = $true }
Assert-True $threw 'reserved RunContext name (EntryCount) throws'

# ---------------------------------------------------------------------------
Enter-Section '2. Adapt + route (LeanPayload)'
# ---------------------------------------------------------------------------
$ir = Invoke-Assemble -DispatchOutput $unitEnvelope

Assert-True (@($ir.Entries).Count -eq 2) '2 entries from 6 results' "got $(@($ir.Entries).Count)"
Assert-True ($ir.Entries[0].RelativePath -eq 'a.ps1' -and $ir.Entries[1].RelativePath -eq 'sub/b.ps1') `
    'ingested order preserved (canonical store order)'
foreach ($dropped in @('AbsolutePath', 'SizeBytes', 'Extension', 'CreationUtc', 'FsAttributes', '_ChainHalt', 'ReadError'))
{
    Assert-True ($null -eq $ir.Entries[0].PSObject.Properties[$dropped]) "entry bag excludes $dropped"
}
# The exclusion and core sets are READ from the stage's own contract
# (schema/assemble.schema.json out.entry.exclude / out.entry.core), not hardcoded —
# prove the module's lists equal the contract's (drift in either direction fails).
$schemaPath = Join-Path $PSScriptRoot '..\reposnapshot-v3\schema\assemble.schema.json'
$contract = Get-Content -LiteralPath $schemaPath -Raw | ConvertFrom-Json -AsHashtable
$contractExclude = @($contract.out.entry.exclude) | Sort-Object
$moduleExclude = @(& (Get-Module rs.core.assemble) { $script:ExcludedFields }) | Sort-Object
Assert-True (($contractExclude -join ',') -eq ($moduleExclude -join ',')) 'assemble exclusion set = contract out.entry.exclude' "contract: $($contractExclude -join ','); module: $($moduleExclude -join ',')"
$contractCore = @($contract.out.entry.core.Keys) | Sort-Object
$moduleCore = @(& (Get-Module rs.core.assemble) { $script:CoreFields }) | Sort-Object
Assert-True (($contractCore -join ',') -eq ($moduleCore -join ',')) 'assemble core set = contract out.entry.core' "contract: $($contractCore -join ','); module: $($moduleCore -join ',')"
Assert-True ($null -eq $ir.Header.Elements.PSObject.Properties['Extension'] -and $null -eq $ir.Header.Elements.PSObject.Properties['FsAttributes']) 'excluded fields never reach Header.Elements'
foreach ($kept in @('RelativePath', 'NodePath', 'LastWriteUtc', 'Content', 'Encoding', 'Attributes'))
{
    Assert-True ($null -ne $ir.Entries[0].PSObject.Properties[$kept]) "entry bag keeps $kept"
}

$reasons = @{}
foreach ($r in $ir.Diagnostics.Routed) { $reasons[[string]$r.Reason] = $r }
Assert-True (@($ir.Diagnostics.Routed).Count -eq 4) '4 routed diagnostics'
Assert-True ($reasons.ContainsKey('BinaryOrNulContent') -and $reasons['BinaryOrNulContent'].RelativePath -eq 'bin.dat') `
    'read failure routed with its ReadError kind'
Assert-True ($reasons.ContainsKey('NullResult') -and $reasons['NullResult'].Index -eq 2) 'null result slot routed with index'
Assert-True ($reasons.ContainsKey('EmptyFile') -and $reasons['EmptyFile'].RelativePath -eq 'empty.txt') `
    'zero-byte file routed EmptyFile'
Assert-True ($reasons.ContainsKey('EmptiedByProcessing') -and $reasons['EmptiedByProcessing'].RelativePath -eq 'gutted.ps1') `
    'stripped-to-nothing routed EmptiedByProcessing (different fact than EmptyFile)'

# ---------------------------------------------------------------------------
Enter-Section '3. Open element model'
# ---------------------------------------------------------------------------
$el = $ir.Header.Elements
Assert-True ($el.Attributes.Count -eq 2 -and $el.Attributes.Total -eq 2) 'Attributes declared 2/2'
Assert-True ($el.Encoding.Count -eq 2) 'Encoding declared (an element like any other)'
Assert-True ($el.WordCloud.Count -eq 1 -and $el.WordCloud.Total -eq 2) `
    'unknown future element (WordCloud) declared 1/2 — zero assemble knowledge'
foreach ($core in @('RelativePath', 'NodePath', 'LastWriteUtc', 'Content'))
{
    Assert-True ($null -eq $el.PSObject.Properties[$core]) "core field $core not declared as element"
}

# ---------------------------------------------------------------------------
Enter-Section '4. Header stamping'
# ---------------------------------------------------------------------------
$ctx = [pscustomobject]@{
    RunStamp = $now; Root = 'C:/r'; GeneratorVersion = '3.0-test'
    ConfigEcho = [pscustomobject]@{ IngestMode = 'Ignore' }
}
$ir2 = Invoke-Assemble -DispatchOutput $unitEnvelope -RunContext $ctx
Assert-True ($ir2.Header.RunStamp -eq $now -and $ir2.Header.Root -eq 'C:/r') 'RunContext stamped verbatim'
Assert-True ($ir2.Header.GeneratorVersion -eq '3.0-test') 'GeneratorVersion stamped'
Assert-True ($ir2.Header.ConfigEcho.IngestMode -eq 'Ignore') 'nested ConfigEcho intact'
Assert-True ($ir2.Header.EntryCount -eq 2) 'EntryCount derived'
Assert-True ($null -ne $ir.Header.PSObject.Properties['EntryCount'] -and @($ir.Header.PSObject.Properties).Count -eq 2) `
    'no RunContext → Header carries only derived fields'

# ---------------------------------------------------------------------------
Enter-Section '5. KeepContentless routing'
# ---------------------------------------------------------------------------
$irK = Invoke-Assemble -DispatchOutput $unitEnvelope -EntryRouting 'KeepContentless'
Assert-True (@($irK.Entries).Count -eq 5) 'KeepContentless: 5 entries (all non-null results)'
$binEntry = @($irK.Entries | Where-Object { $_.RelativePath -eq 'bin.dat' })[0]
Assert-True ($binEntry.ReadError -eq 'BinaryOrNulContent') 'content-less entry retains ReadError (self-explanatory)'
Assert-True ($null -eq $binEntry.PSObject.Properties['_ChainHalt']) 'chain mechanics still excluded'
Assert-True (@($irK.Diagnostics.Routed).Count -eq 1 -and $irK.Diagnostics.Routed[0].Reason -eq 'NullResult') `
    'only null results route under KeepContentless'

# ---------------------------------------------------------------------------
Enter-Section '6. Pass-through streams'
# ---------------------------------------------------------------------------
Assert-True (@($ir.Skipped).Count -eq 1 -and $ir.Skipped[0].Reason -eq 'ExtensionBlacklisted') 'Skipped passed through'
Assert-True ($ir.Diagnostics.Errors[0] -eq 'one error' -and $ir.Diagnostics.Warnings[0] -eq 'one warning') `
    'Errors/Warnings echoed into Diagnostics'
$bare = Invoke-Assemble -DispatchOutput ([pscustomobject]@{ Results = @() })
Assert-True (@($bare.Entries).Count -eq 0 -and @($bare.Skipped).Count -eq 0 -and $bare.Header.EntryCount -eq 0) `
    'minimal envelope (Results only) assembles to empty IR'

# ---------------------------------------------------------------------------
Enter-Section '7. GOLDEN — v3 IR vs live LTS monolith (normal-form fixture)'
# ---------------------------------------------------------------------------
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) "rs-golden-$([guid]::NewGuid().ToString('N').Substring(0,8))"
New-Item -ItemType Directory -Path (Join-Path $fixtureRoot 'src') -Force | Out-Null

# Normal-form content: LF-only, no trailing newline, no blank runs >= 2, no
# NBSP, no region markers -> Normalize-FileContent is the identity.
$fileA = "function Get-Alpha {`n    param([int]`$n)`n    return `$n * 2`n}`n`nGet-Alpha -n 21" * 3
$fileB = "plain text body`nsecond line`nthird line with words to count"
$fileC = "`$config = @{`n    Name = 'golden'`n    Size = 42`n}"
[IO.File]::WriteAllText((Join-Path $fixtureRoot 'alpha.ps1'), $fileA)
[IO.File]::WriteAllText((Join-Path $fixtureRoot 'notes.txt'), $fileB)
[IO.File]::WriteAllText((Join-Path $fixtureRoot 'src/config.ps1'), $fileC)
[IO.File]::WriteAllBytes((Join-Path $fixtureRoot 'blob.bin2'), [byte[]](1, 0, 2, 0, 3))   # NUL content, ext not blacklisted

try
{
    # LTS side — monolith over the same fixture
    Import-Module $ltsPath -Force -WarningAction SilentlyContinue
    $ltsJson = Get-RepoSnapshot -Path $fixtureRoot -UseParallelism $false -RespectGitIgnore $false `
        -ExportTree $false -StripComments $false -IncludeFileContent $true -Confirm:$false
    $lts = Get-Content $ltsJson -Raw | ConvertFrom-Json
    $ltsByPath = @{}
    foreach ($f in $lts.files) { $ltsByPath[$f.path] = $f }

    # v3 side — full pipeline, harness-as-admiral
    Import-Module (Join-Path $v3 'rs.core.crawler.psm1') -Force
    Import-Module (Join-Path $v3 'rs.core.ignore.psm1') -Force
    Import-Module (Join-Path $v3 'rs.core.colonel.v2.psm1') -Force -WarningAction SilentlyContinue
    Import-Module (Join-Path $v3 'rs.core.ingest.psm1') -Force

    $crawl = (New-FileSystemCrawler -RootPath $fixtureRoot).Invoke()
    $compiled = New-IgnoreCompiler -CrawlerGraph $crawl.Graph
    $filtered = Invoke-IgnoreFilter -CompiledNodes $compiled.CompiledNodes -CrawlerGraph $crawl.Graph
    $ingest = Invoke-Ingest -FilteredFsGraph $filtered `
        -Manifest @{
            'file-read'     = (Join-Path $v3 'processors\file-read.ps1')
            'rs-attributes' = (Join-Path $v3 'processors\rs-attributes.ps1')
        } `
        -Steps @(@{ Key = 'file-read'; Config = @{} }, @{ Key = 'rs-attributes'; Config = @{} }) `
        -ChainExecutorPath (Join-Path $v3 'processors\chain-executor.ps1') `
        -SharedHelperPath (Join-Path $v3 'processors\bag-helpers.ps1')

    $golden = Invoke-Assemble -DispatchOutput $ingest -RunContext ([pscustomobject]@{
            Root = $fixtureRoot; GeneratorVersion = '3.0' })

    # Path-key matching, never positional (LTS files[] is a path-sorted VIEW)
    $v3Paths = @($golden.Entries | ForEach-Object { $_.RelativePath }) | Sort-Object
    $ltsPaths = @($lts.files | ForEach-Object { $_.path }) | Sort-Object
    Assert-True (@($golden.Entries).Count -eq 3) 'v3: 3 content entries' "got $(@($golden.Entries).Count)"
    Assert-True (@($lts.files).Count -eq 4) 'LTS: 4 entries (keeps the binary)' "got $(@($lts.files).Count)"
    $ltsOnly = @($ltsPaths | Where-Object { $_ -notin $v3Paths })
    Assert-True ($ltsOnly.Count -eq 1 -and $ltsOnly[0] -eq 'blob.bin2') `
        'set delta is exactly the binary (LTS content-less entry; v3 routes to Diagnostics)'
    Assert-True (@($golden.Diagnostics.Routed | Where-Object { $_.Reason -eq 'BinaryOrNulContent' }).Count -eq 1) `
        'v3: binary routed BinaryOrNulContent (lean payload)'

    $contentOk = $true; $charOk = $true; $wordOk = $true; $entOk = $true
    $wsOk = $true; $lsOk = $true; $spanOk = $true; $crDelta = $true; $lwOk = $true
    foreach ($entry in $golden.Entries)
    {
        $l = $ltsByPath[$entry.RelativePath]
        $a = $entry.Attributes
        if ($entry.Content -cne $l.content) { $contentOk = $false }
        if ($a.CharCount -ne $l.attributes.char_count) { $charOk = $false }
        if ($a.WordCount -ne $l.attributes.word_count) { $wordOk = $false }
        if ($a.Entropy -ne $l.attributes.entropy) { $entOk = $false }
        if ($a.WhitespaceRatio -ne $l.attributes.whitespace_ratio) { $wsOk = $false }
        if ($a.LineStats.Mean -ne $l.attributes.line_stats.mean -or
            $a.LineStats.Median -ne $l.attributes.line_stats.median -or
            $a.LineStats.StdDev -ne $l.attributes.line_stats.std_dev -or
            $a.LineStats.Max -ne $l.attributes.line_stats.max) { $lsOk = $false }
        if ($a.SpanBytes -ne $l.attributes.size_bytes) { $spanOk = $false }
        # Known delta: LTS compression_ratio defect (0 when >100 chars; 1 gated)
        $ltsCr = [double]$l.attributes.compression_ratio
        $okCr = if ($a.CharCount -gt 100) { ($ltsCr -eq 0) -and ($a.CompressionRatio -gt 0) -and ($a.CompressionRatio -lt 1) }
        else { ($ltsCr -eq 1) -and ($a.CompressionRatio -eq 1) }
        if (-not $okCr) { $crDelta = $false }
        # pwsh 7 ConvertFrom-Json auto-parses ISO strings into [datetime]
        # (Local-adjusted); handle both shapes without a lossy string cast.
        $ltsLw = if ($l.last_write -is [datetime]) { $l.last_write }
        else { [datetime]::Parse([string]$l.last_write, $null, [System.Globalization.DateTimeStyles]::RoundtripKind) }
        if ($ltsLw.ToUniversalTime().Ticks -ne $entry.LastWriteUtc.Ticks) { $lwOk = $false }
    }
    Assert-True $contentOk 'content byte-exact per path (Normalize identity on normal-form fixture)'
    Assert-True $charOk 'char_count == Attributes.CharCount'
    Assert-True $wordOk 'word_count == Attributes.WordCount'
    Assert-True $entOk 'entropy == Attributes.Entropy'
    Assert-True $wsOk 'whitespace_ratio == Attributes.WhitespaceRatio'
    Assert-True $lsOk 'line_stats == Attributes.LineStats (all four)'
    Assert-True $spanOk 'size_bytes == SpanBytes (UTF-8 no-BOM: disk bytes == content bytes)'
    Assert-True $crDelta 'compression_ratio: documented delta (LTS defect 0 vs v3 real; both 1 when gated)'
    Assert-True $lwOk 'last_write round-trips to LastWriteUtc (tick-equal)'

    Assert-True ($golden.Header.Elements.Attributes.Count -eq 3 -and $golden.Header.Elements.Attributes.Total -eq 3) `
        'Elements: Attributes 3/3 in golden IR'
    Assert-True ($golden.Header.EntryCount -eq 3 -and $golden.Header.Root -eq $fixtureRoot) `
        'Header: derived + stamped coexist'
}
catch
{
    # A terminating error inside the try block — a StrictMode property access, a
    # parameter-binding failure — would otherwise abort the suite SILENTLY:
    # finally runs, execution resumes after the block, and the summary prints a
    # PASSING count while the remaining asserts never ran. That mode is invisible
    # from outside (tests/run-all.ps1 cannot detect it — the counts are
    # self-consistent), so it has to be caught HERE.
    Assert-True $false "SUITE ABORTED: $($_.Exception.Message)" $_.ScriptStackTrace
}
finally
{
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
Write-Host "`n═══ assemble.tests: $script:Passed passed, $script:Failed failed ═══" -ForegroundColor $(if ($script:Failed -eq 0) { 'Green' } else { 'Red' })
if ($script:Failed -gt 0) { exit 1 }
