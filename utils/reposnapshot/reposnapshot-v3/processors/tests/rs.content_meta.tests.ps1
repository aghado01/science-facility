#Requires -Version 7.5
Set-StrictMode -Version Latest

<#
.SYNOPSIS
    Formal test harness for processors/rs.content_meta.ps1.

.DESCRIPTION
    Covers:
      1. Bare ISS colonel dispatch — Roslyn compile with no Add-Type cmdlet
         (must run before parent Invoke-Attr, which would otherwise load the type)
      2. Direct-invocation metric parity (LTS formulas: counts, entropy,
         whitespace ratio, line stats incl. upper-median quirk, compression gate)
      3. No-Content contract — pass-through unenriched (envelope-shaped item)
      4. Empty-content behavior — ContentMeta attached with zeroed metrics
      5. Copy-on-enrich — identity fields cloned, Content unmutated, caller's object untouched
      6. Core colonel dispatch — file_read → rs.content_meta chain in real runspaces
#>

$procDir = Split-Path $PSScriptRoot -Parent
$v3 = Split-Path $procDir -Parent
$attrPath = Join-Path $procDir 'rs.content_meta.ps1'

# Shared ISS helpers
. (Join-Path $PSScriptRoot '_helpers.ps1')

#region Assertions
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

function Invoke-Attr ([object]$Item, [hashtable]$Config = @{})
{
    & $attrPath $Item $Config
}

$allFields = @(
    'CharCount', 'WordCount', 'PunctuationCount', 'UniqueChars',
    'Entropy', 'CompressionRatio', 'WhitespaceRatio', 'LineStats'
)
function Invoke-AttrAll ([object]$Item)
{
    Invoke-Attr $Item @{ Fields = $allFields; Digits = 4 }
}
#endregion

#region Test0_BareCompile
Enter-Section '1. Bare ISS compile (no Add-Type)'
# Must run before any parent-runspace Invoke-Attr: that would load the type
# into the AppDomain and mask a Bare-only compile failure.
Import-Module (Join-Path $v3 'rs.core.colonel.v2.psm1') -Force -WarningAction SilentlyContinue
try
{
    $barePlan = Compile-Plan `
        -Manifest @{ 'rs.content_meta' = $attrPath } `
        -Steps @(@{ Key = 'rs.content_meta'; Config = @{ Digits = 4 } }) `
        -ChainExecutorPath (Join-Path $procDir 'chain_executor.ps1') `
        -SharedHelperPath (Join-Path $procDir 'bag_helpers.ps1') `
        -IssPreset Bare
    Assert-True (@($barePlan.Errors).Count -eq 0) 'Bare chain compiles' ($barePlan.Errors -join '; ')
    $bareRun = Invoke-Plan -Items @(
        [pscustomobject]@{ RelativePath = 'x.txt'; Content = "aaaa`nbb" }
    ) -Plan $barePlan.Plan -MaxWorkers 1
    Assert-True (@($bareRun.Errors).Count -eq 0) 'Bare dispatch clean' ($bareRun.Errors -join '; ')
    $ba = $bareRun.Results[0].ContentMeta
    Assert-True ($ba.WordCount -eq 2 -and $ba.Entropy -eq 1.3788 -and $ba.LineStats.Median -eq 4) `
        'Bare worker matches LTS formulas' "words=$($ba.WordCount) H=$($ba.Entropy) med=$($ba.LineStats.Median)"
}
catch
{
    Assert-True $false "SUITE ABORTED: $($_.Exception.Message)" $_.ScriptStackTrace
}
#endregion

#region Test1_MetricParity
Enter-Section '2. Metric parity (LTS formulas)'
# Content "aaaa`nbb": 7 chars (a×4, LF, b×2), 2 words, 3 unique chars,
# entropy ≈ 1.3788, ws ratio ≈ 0.1429, lines 'aaaa'(4) 'bb'(2): mean 3, median 4
$r = Invoke-AttrAll ([pscustomobject]@{ RelativePath = 'x.txt'; Content = "aaaa`nbb" })
$a = $r.ContentMeta
Assert-True ($a.SpanBytes -eq 7) 'SpanBytes = 7 (ASCII: bytes == chars)' "got $($a.SpanBytes)"
Assert-True ($a.CharCount -eq 7) 'CharCount = 7' "got $($a.CharCount)"
Assert-True ($a.WordCount -eq 2) 'WordCount = 2' "got $($a.WordCount)"
Assert-True ($a.PunctuationCount -eq 0) 'PunctuationCount = 0'
Assert-True ($a.UniqueChars -eq 3) 'UniqueChars = 3' "got $($a.UniqueChars)"
Assert-True ($a.Entropy -eq 1.3788) 'Entropy = 1.3788 (rounded 4)' "got $($a.Entropy)"
Assert-True ($a.WhitespaceRatio -eq 0.1429) 'WhitespaceRatio = 0.1429' "got $($a.WhitespaceRatio)"
Assert-True ($a.CompressionRatio -eq 1.0) 'CompressionRatio gated at ≤100 chars (1.0)'
Assert-True ($a.LineStats.Mean -eq 3) 'LineStats.Mean = 3' "got $($a.LineStats.Mean)"
Assert-True ($a.LineStats.Median -eq 4) 'LineStats.Median = 4 (LTS upper-median quirk)' "got $($a.LineStats.Median)"
Assert-True ($a.LineStats.StdDev -eq 1) 'LineStats.StdDev = 1' "got $($a.LineStats.StdDev)"
Assert-True ($a.LineStats.Max -eq 4) 'LineStats.Max = 4'

$r2 = Invoke-AttrAll ([pscustomobject]@{ Content = 'aabb' })
Assert-True ($r2.ContentMeta.Entropy -eq 1.0) 'Entropy("aabb") = 1.0 exactly'

$r3 = Invoke-AttrAll ([pscustomobject]@{ Content = 'a,b.' })
Assert-True ($r3.ContentMeta.PunctuationCount -eq 2) 'PunctuationCount("a,b.") = 2'

$rm = Invoke-AttrAll ([pscustomobject]@{ Content = 'héllo' })
Assert-True ($rm.ContentMeta.CharCount -eq 5 -and $rm.ContentMeta.SpanBytes -eq 6) `
    'multibyte: CharCount 5 vs SpanBytes 6 (UTF-8 é)' "chars=$($rm.ContentMeta.CharCount) span=$($rm.ContentMeta.SpanBytes)"

$big = 'a' * 300
$r4 = Invoke-AttrAll ([pscustomobject]@{ Content = $big })
Assert-True ($r4.ContentMeta.CompressionRatio -lt 1.0 -and $r4.ContentMeta.CompressionRatio -gt 0) `
    'CompressionRatio < 1 for repetitive >100-char content' "got $($r4.ContentMeta.CompressionRatio)"

# WordCount must keep -split '\s+' (leading/trailing empties). The native pass
# is a rewrite, not a new formula.
foreach ($sample in @('x y z', '  a  b  ', "a`n", '   '))
{
    $got = (Invoke-AttrAll ([pscustomobject]@{ Content = $sample })).ContentMeta.WordCount
    $expect = @($sample -split '\s+').Count
    Assert-True ($got -eq $expect) `
        "WordCount split-parity '$($sample -replace "`n", '\n')'" "got $got expect $expect"
}
Assert-True ((Invoke-AttrAll ([pscustomobject]@{ Content = 'x y z' })).ContentMeta.WhitespaceRatio -eq 0.4) `
    'WhitespaceRatio("x y z") = 0.4 (2 spaces / 5)'
#endregion

#region Test2_NoContent
Enter-Section '3. No-Content contract'
$envelope = [pscustomobject]@{ Id = 'thread-1'; Path = 't.md'; Exchanges = @(1, 2, 3) }
$re = Invoke-Attr $envelope
Assert-True ($null -eq $re.PSObject.Properties['ContentMeta']) 'envelope passes through unenriched'
Assert-True ($re.Id -eq 'thread-1' -and $re.Exchanges.Count -eq 3) 'envelope properties preserved'
#endregion

#region Test3_EmptyContent
Enter-Section '4. Empty content'
$rz = Invoke-AttrAll ([pscustomobject]@{ RelativePath = 'empty.txt'; Content = '' })
$az = $rz.ContentMeta
Assert-True ($null -ne $az) 'empty string still gets ContentMeta'
Assert-True ($az.SpanBytes -eq 0 -and $az.CharCount -eq 0 -and $az.WordCount -eq 0 -and $az.Entropy -eq 0) 'zeroed count metrics (incl. SpanBytes)'
Assert-True ($az.CompressionRatio -eq 1.0 -and $az.WhitespaceRatio -eq 0) 'zeroed ratio metrics'
Assert-True ($az.LineStats.Mean -eq 0 -and $az.LineStats.Max -eq 0) 'zeroed line stats'
#endregion

#region Test4_CopyOnEnrich
Enter-Section '5. Copy-on-enrich'
$src = [pscustomobject]@{
    AbsolutePath = 'C:/repo/a.ps1'; RelativePath = 'a.ps1'; NodePath = ''
    SizeBytes = 999; LastWriteUtc = [datetime]::UtcNow; Content = 'x y z'
}
$rc = Invoke-Attr $src
foreach ($field in @('AbsolutePath', 'RelativePath', 'NodePath', 'SizeBytes', 'LastWriteUtc'))
{
    Assert-True ($null -ne $rc.PSObject.Properties[$field]) "identity cloned: $field"
}
Assert-True ($rc.Content -eq 'x y z') 'Content unmutated'
Assert-True ($null -eq $src.PSObject.Properties['ContentMeta']) "caller's object untouched"
Assert-True ($rc.SizeBytes -eq 999 -and $rc.ContentMeta.CharCount -eq 5) `
    'provenance split: SizeBytes (on-disk) vs ContentMeta.CharCount (processed)'
#endregion

#region Test4b_FieldsGating
Enter-Section '5b. Fields config gates what is computed'
$def = Invoke-Attr ([pscustomobject]@{ Content = 'a,b.' * 40 })
Assert-True ($null -ne $def.ContentMeta.CharCount) 'default Fields includes CharCount'
Assert-True ($null -eq $def.ContentMeta.PSObject.Properties['PunctuationCount']) `
    'default Fields omits PunctuationCount'
Assert-True ($null -eq $def.ContentMeta.PSObject.Properties['CompressionRatio']) `
    'default Fields omits CompressionRatio (no gzip)'
Assert-True ($null -ne $def.ContentMeta.SpanBytes) 'SpanBytes is always attached'

$only = Invoke-Attr ([pscustomobject]@{ Content = 'aaaa' }) @{ Fields = @('CharCount') }
Assert-True ($only.ContentMeta.CharCount -eq 4) 'Fields=CharCount computes CharCount'
Assert-True ($null -eq $only.ContentMeta.PSObject.Properties['WordCount']) '…and does not attach WordCount'
Assert-True ($null -eq $only.ContentMeta.PSObject.Properties['LineStats']) '…nor LineStats'
Assert-True ($null -ne $only.ContentMeta.SpanBytes) '…SpanBytes still present'

$none = Invoke-Attr ([pscustomobject]@{ Content = 'aaaa' }) @{ Fields = @() }
Assert-True ($null -eq $none.PSObject.Properties['ContentMeta']) 'empty Fields: no ContentMeta attached'

$threw = $null
try { Invoke-Attr ([pscustomobject]@{ Content = 'x' }) @{ Fields = @('Nope') } | Out-Null } catch { $threw = $_.Exception.Message }
Assert-True ($null -ne $threw -and $threw -like '*unknown Fields*') 'unknown Fields name throws' $threw

$d2 = Invoke-Attr ([pscustomobject]@{ Content = "aaaa`nbb" })
Assert-True ($d2.ContentMeta.Entropy -eq 1.38) 'default Digits=2 rounds Entropy to 1.38' "got $($d2.ContentMeta.Entropy)"
Assert-True ($d2.ContentMeta.WhitespaceRatio -eq 0.14) 'default Digits=2 rounds WhitespaceRatio to 0.14' "got $($d2.ContentMeta.WhitespaceRatio)"
$threw = $null
try { Invoke-Attr ([pscustomobject]@{ Content = 'x' }) @{ Fields = @('CharCount'); Digits = -1 } | Out-Null } catch { $threw = $_.Exception.Message }
Assert-True ($null -ne $threw -and $threw -like '*Digits must be*') 'Digits out of range throws' $threw
#endregion

#region Test5_ColonelDispatch
Enter-Section '6. Colonel dispatch (file_read → rs.content_meta)'
Import-Module (Join-Path $v3 'rs.core.colonel.v2.psm1') -Force -WarningAction SilentlyContinue

$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) "rs-attr-test-$([guid]::NewGuid().ToString('N').Substring(0,8))"
New-Item -ItemType Directory -Path $fixtureRoot | Out-Null
$fixtureFile = Join-Path $fixtureRoot 'sample.ps1'
Set-Content -Path $fixtureFile -Value ("# sample`n" + ('Write-Host "line" # trailing' + "`n") * 20)

try
{
    $compiled = Compile-Plan `
        -Manifest @{ 'file_read' = (Join-Path $procDir 'file_read.ps1'); 'rs.content_meta' = $attrPath } `
        -Steps @(@{ Key = 'file_read'; Config = @{} }, @{ Key = 'rs.content_meta'; Config = @{ Fields = $allFields; Digits = 4 } }) `
        -ChainExecutorPath (Join-Path $procDir 'chain_executor.ps1') `
            -SharedHelperPath (Join-Path $procDir 'bag_helpers.ps1')
    Assert-True (@($compiled.Errors).Count -eq 0) 'chain compiles' ($compiled.Errors -join '; ')

    $items = @([pscustomobject]@{
            AbsolutePath = ($fixtureFile -replace '\\', '/')
            RelativePath = 'sample.ps1'; NodePath = ''; SizeBytes = (Get-Item $fixtureFile).Length
            LastWriteUtc = [datetime]::UtcNow
        })
    $run = Invoke-Plan -Items $items -Plan $compiled.Plan
    Assert-True (@($run.Errors).Count -eq 0) 'dispatch clean' ($run.Errors -join '; ')
    $out = $run.Results[0]
    Assert-True ($null -ne $out.ContentMeta) 'ContentMeta attached in worker runspace'
    Assert-True ($out.ContentMeta.CharCount -gt 100) 'metrics computed on read content'
    Assert-True ($out.ContentMeta.CompressionRatio -lt 1.0) 'GZipStream resolves in worker runspace'
    Assert-True ($out.RelativePath -eq 'sample.ps1' -and $null -ne $out.PSObject.Properties['LastWriteUtc']) `
        'identity survives two-step chain'
}
catch
{
    Assert-True $false "SUITE ABORTED: $($_.Exception.Message)" $_.ScriptStackTrace
}
finally
{
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}
#endregion

Write-Host "`n═══ rs.content_meta.tests: $script:Passed passed, $script:Failed failed ═══" -ForegroundColor $(if ($script:Failed -eq 0) { 'Green' } else { 'Red' })
if ($script:Failed -gt 0) { exit 1 }
