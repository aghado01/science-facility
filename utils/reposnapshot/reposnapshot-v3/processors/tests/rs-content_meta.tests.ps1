#Requires -Version 7.5
Set-StrictMode -Version Latest

<#
.SYNOPSIS
    Formal test harness for processors/rs-content_meta.ps1.

.DESCRIPTION
    Covers:
      1. Direct-invocation metric parity (LTS formulas: counts, entropy,
         whitespace ratio, line stats incl. the upper-median quirk,
         compression gate at >100 chars)
      2. No-Content contract — pass-through unenriched (envelope-shaped item)
      3. Empty-content behavior — ContentMeta attached with zeroed metrics
      4. Copy-on-enrich — identity fields cloned, Content unmutated, caller's
         object untouched
      5. Colonel dispatch — file-read → rs-content_meta chain in real runspaces
         (also proves GZipStream resolves in worker runspaces)

.NOTES
    Run from any directory:
        & "$PSScriptRoot\rs-content_meta.tests.ps1"
#>

$procDir = Split-Path $PSScriptRoot -Parent
$v3 = Split-Path $procDir -Parent
$attrPath = Join-Path $procDir 'rs-content_meta.ps1'

# Shared ISS helpers (Resolve-BagContent / Copy-Bag) — colonel registers these
# into worker runspaces; dot-invocation here needs them loaded explicitly.
. (Join-Path $PSScriptRoot '_helpers.ps1')

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

function Invoke-Attr ([object]$Item, [hashtable]$Config = @{})
{
    & $attrPath $Item $Config
}

# ---------------------------------------------------------------------------
Enter-Section '1. Metric parity (LTS formulas)'
# ---------------------------------------------------------------------------
# Content "aaaa`nbb": 7 chars (a×4, LF, b×2), 2 words, 3 unique chars,
# entropy = -(4/7·log2(4/7) + 1/7·log2(1/7) + 2/7·log2(2/7)) ≈ 1.3788,
# ws ratio 1/7 ≈ 0.1429, lines 'aaaa'(4) 'bb'(2): mean 3, upper-median 4,
# stddev 1, max 4; ≤100 chars → compression gate closed (1.0).
$r = Invoke-Attr ([pscustomobject]@{ RelativePath = 'x.txt'; Content = "aaaa`nbb" })
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

$r2 = Invoke-Attr ([pscustomobject]@{ Content = 'aabb' })
Assert-True ($r2.ContentMeta.Entropy -eq 1.0) 'Entropy("aabb") = 1.0 exactly'

$r3 = Invoke-Attr ([pscustomobject]@{ Content = 'a,b.' })
Assert-True ($r3.ContentMeta.PunctuationCount -eq 2) 'PunctuationCount("a,b.") = 2'

$rm = Invoke-Attr ([pscustomobject]@{ Content = 'héllo' })
Assert-True ($rm.ContentMeta.CharCount -eq 5 -and $rm.ContentMeta.SpanBytes -eq 6) `
    'multibyte: CharCount 5 vs SpanBytes 6 (UTF-8 é)' "chars=$($rm.ContentMeta.CharCount) span=$($rm.ContentMeta.SpanBytes)"

$big = 'a' * 300
$r4 = Invoke-Attr ([pscustomobject]@{ Content = $big })
Assert-True ($r4.ContentMeta.CompressionRatio -lt 1.0 -and $r4.ContentMeta.CompressionRatio -gt 0) `
    'CompressionRatio < 1 for repetitive >100-char content' "got $($r4.ContentMeta.CompressionRatio)"

# ---------------------------------------------------------------------------
Enter-Section '2. No-Content contract'
# ---------------------------------------------------------------------------
$envelope = [pscustomobject]@{ Id = 'thread-1'; Path = 't.md'; Exchanges = @(1, 2, 3) }
$re = Invoke-Attr $envelope
Assert-True ($null -eq $re.PSObject.Properties['ContentMeta']) 'envelope passes through unenriched'
Assert-True ($re.Id -eq 'thread-1' -and $re.Exchanges.Count -eq 3) 'envelope properties preserved'

# ---------------------------------------------------------------------------
Enter-Section '3. Empty content'
# ---------------------------------------------------------------------------
$rz = Invoke-Attr ([pscustomobject]@{ RelativePath = 'empty.txt'; Content = '' })
$az = $rz.ContentMeta
Assert-True ($null -ne $az) 'empty string still gets ContentMeta'
Assert-True ($az.SpanBytes -eq 0 -and $az.CharCount -eq 0 -and $az.WordCount -eq 0 -and $az.Entropy -eq 0) 'zeroed count metrics (incl. SpanBytes)'
Assert-True ($az.CompressionRatio -eq 1.0 -and $az.WhitespaceRatio -eq 0) 'zeroed ratio metrics'
Assert-True ($az.LineStats.Mean -eq 0 -and $az.LineStats.Max -eq 0) 'zeroed line stats'

# ---------------------------------------------------------------------------
Enter-Section '4. Copy-on-enrich'
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
Enter-Section '5. Colonel dispatch (file-read → rs-content_meta)'
# ---------------------------------------------------------------------------
Import-Module (Join-Path $v3 'rs.core.colonel.v2.psm1') -Force -WarningAction SilentlyContinue

$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) "rs-attr-test-$([guid]::NewGuid().ToString('N').Substring(0,8))"
New-Item -ItemType Directory -Path $fixtureRoot | Out-Null
$fixtureFile = Join-Path $fixtureRoot 'sample.ps1'
Set-Content -Path $fixtureFile -Value ("# sample`n" + ('Write-Host "line" # trailing' + "`n") * 20)

try
{
    $compiled = Compile-Plan `
        -Manifest @{ 'file-read' = (Join-Path $procDir 'file-read.ps1'); 'rs-content_meta' = $attrPath } `
        -Steps @(@{ Key = 'file-read'; Config = @{} }, @{ Key = 'rs-content_meta'; Config = @{} }) `
        -ChainExecutorPath (Join-Path $procDir 'chain-executor.ps1') `
            -SharedHelperPath (Join-Path $procDir 'bag-helpers.ps1')
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
Write-Host "`n═══ rs-content_meta.tests: $script:Passed passed, $script:Failed failed ═══" -ForegroundColor $(if ($script:Failed -eq 0) { 'Green' } else { 'Red' })
if ($script:Failed -gt 0) { exit 1 }
