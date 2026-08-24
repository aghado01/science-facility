#Requires -Version 7.6
Set-StrictMode -Version Latest

<#
.SYNOPSIS
    Unit tests for processors/rs-csstrip.ps1.

.DESCRIPTION
    Tests the processor directly (dot-invoked) to isolate behavior from dispatcher mechanics.
    Covers:
      1. Item unpacking — string / hashtable / pscustomobject
      2. Default ops — block/doc/comment-block/line stripped; interior + inline kept
      3. Selective ops — each kind in isolation
      4. Standalone vs interior block comments
      5. CommentBlock reclassification (2+ contiguous // lines)
      6. DocString /// vs // discrimination
      7. CRLF normalization side effect
      8. Empty content / empty Operations
      9. IncludeMeta = $false
     10. Harmonized content-mutator contract (6d)
#>

$processorPath = Join-Path $PSScriptRoot '..\rs-csstrip.ps1'

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

function Assert-Equal ($Actual, $Expected, [string]$Label)
{
    Assert-True ($Actual -eq $Expected) $Label "expected $(([string]$Expected).Length -le 60 ? "'$Expected'" : "(value)"), got $(([string]$Actual).Length -le 60 ? "'$Actual'" : "(value)")"
}

function Invoke-Processor ([object]$Item, [hashtable]$Config = @{})
{
    if ($Item -is [string]) { $Item = [pscustomobject]@{ Content = $Item } }
    & $processorPath $Item $Config
}

function Invoke-ProcessorRaw ([object]$Item, [hashtable]$Config = @{})
{
    & $processorPath $Item $Config
}
#endregion

#region Fixture
$fixture = @'
/* standalone block
   second line */
/// <summary>doc string</summary>
public class Foo
{
    // block line one
    // block line two
    public int Bar { get; set; }

    // isolated single line
    public void Baz()
    {
        var x = 1; // trailing inline
        try { Qux(); } catch { /* intentionally empty */ }
    }
}
'@
#endregion

Write-Host '============================================================' -ForegroundColor Yellow
Write-Host ' rs-csstrip.tests.ps1' -ForegroundColor Yellow
Write-Host '============================================================' -ForegroundColor Yellow

#region Test1_ItemUnpacking
Enter-Section '1. Item unpacking'

$rStr = Invoke-ProcessorRaw -Item $fixture
$rHash = Invoke-Processor -Item @{ Content = $fixture; Id = 'h1'; Path = 'x.cs' }
$rPsco = Invoke-Processor -Item ([pscustomobject]@{ Content = $fixture; Id = 'p1'; Path = 'y.cs' })

Assert-True ($rStr -is [string]) 'String item: bare string in → bare string out'
Assert-True ($rStr -notmatch 'standalone block') 'String item: stripping applied to the returned string'
Assert-True ($rHash -is [pscustomobject]) 'Hashtable item: cloned to pscustomobject'
Assert-True ($rPsco -is [pscustomobject]) 'PSCustomObject item: returns pscustomobject'
Assert-Equal $rPsco.Id 'p1' 'PSCustomObject item: Id propagated'
Assert-Equal $rPsco.Path 'y.cs' 'PSCustomObject item: Path propagated'
Assert-Equal $rPsco.Processing[0].Processor 'rs-csstrip' 'Processing record names the processor'
#endregion

#region Test2_DefaultOps
Enter-Section '2. Default ops (block, doc, comment-block, line — interior + inline kept)'

$rDef = Invoke-Processor -Item $fixture
Assert-True ($rDef.Content -notmatch 'standalone block') 'Default: standalone BlockComment stripped'
Assert-True ($rDef.Content -notmatch 'doc string') 'Default: DocString stripped'
Assert-True ($rDef.Content -notmatch 'block line one') 'Default: CommentBlock stripped'
Assert-True ($rDef.Content -notmatch 'isolated single line') 'Default: LineComment stripped'
Assert-True ($rDef.Content -match 'trailing inline') 'Default: InlineComment kept'
Assert-True ($rDef.Content -match 'intentionally empty') 'Default: InteriorComment kept'
Assert-True ($rDef.Content -match 'public class Foo') 'Default: code preserved'
Assert-True ($rDef.Content -match 'var x = 1;') 'Default: code with trailing comment preserved'
#endregion

#region Test3_SelectiveOps
Enter-Section '3. Selective ops'

$rB = Invoke-Processor -Item $fixture -Config @{ Operations = @('block-comments') }
Assert-True ($rB.Content -notmatch 'standalone block') 'block-comments: standalone block stripped'
Assert-True ($rB.Content -match 'doc string') 'block-comments: DocString kept'
Assert-True ($rB.Content -match 'block line one') 'block-comments: CommentBlock kept'
Assert-True ($rB.Content -match 'intentionally empty') 'block-comments: InteriorComment kept'

$rD = Invoke-Processor -Item $fixture -Config @{ Operations = @('doc-strings') }
Assert-True ($rD.Content -notmatch 'doc string') 'doc-strings: DocString stripped'
Assert-True ($rD.Content -match 'standalone block') 'doc-strings: BlockComment kept'

$rCB = Invoke-Processor -Item $fixture -Config @{ Operations = @('comment-blocks') }
Assert-True ($rCB.Content -notmatch 'block line one') 'comment-blocks: run stripped'
Assert-True ($rCB.Content -match 'isolated single line') 'comment-blocks: isolated LineComment kept'

$rL = Invoke-Processor -Item $fixture -Config @{ Operations = @('line-comments') }
Assert-True ($rL.Content -notmatch 'isolated single line') 'line-comments: isolated line stripped'
Assert-True ($rL.Content -match 'block line one') 'line-comments: CommentBlock kept'

$rI = Invoke-Processor -Item $fixture -Config @{ Operations = @('inline-comments') }
Assert-True ($rI.Content -notmatch 'trailing inline') 'inline-comments: trailing comment stripped'
Assert-True ($rI.Content -match 'var x = 1;') 'inline-comments: code on that line preserved'

$rInt = Invoke-Processor -Item $fixture -Config @{ Operations = @('interior-comments') }
Assert-True ($rInt.Content -notmatch 'intentionally empty') 'interior-comments: interior block stripped'
Assert-True ($rInt.Content -match 'catch \{') 'interior-comments: surrounding code kept'
Assert-True ($rInt.Content -match 'standalone block') 'interior-comments: standalone block kept'
#endregion

#region Test4_BlockSpans
Enter-Section '4. Standalone vs interior block spans'

$spanSrc = "int a = 1;`n/* standalone */`nint b = 2;`nint c = /* interior */ 3;`n"
$rSpan = Invoke-Processor -Item $spanSrc -Config @{ Operations = @('block-comments', 'interior-comments') }
Assert-True ($rSpan.Content -notmatch 'standalone') 'standalone block removed'
Assert-True ($rSpan.Content -notmatch 'interior') 'interior block removed'
Assert-Equal $rSpan.Content "int a = 1;`nint b = 2;`nint c =  3;`n" `
    'standalone span consumes its whole line (no blank-line artifact); interior span covers only the token'
Assert-True ($rSpan.Content -match 'int c =\s+3;') 'interior block leaves surrounding code on its line'
#endregion

#region Test5_CommentBlockRuns
Enter-Section '5. CommentBlock reclassification'

$runSrc = "// one`n// two`n// three`nint x = 1;`n"
$rRun = Invoke-Processor -Item $runSrc -Config @{ Operations = @('comment-blocks') }
Assert-True ($rRun.Content -notmatch 'one|two|three') '3-line run stripped by comment-blocks'
Assert-True ($rRun.Content -match 'int x = 1;') 'code after run preserved'

$rRunLine = Invoke-Processor -Item $runSrc -Config @{ Operations = @('line-comments') }
Assert-True ($rRunLine.Content -match 'one') '3-line run NOT stripped by line-comments'
#endregion

#region Test6_DocStringDiscrimination
Enter-Section '6. /// vs // discrimination'

$docSrc = "/// doc`n// plain`nint x = 1;`n"
$rDoc2 = Invoke-Processor -Item $docSrc -Config @{ Operations = @('doc-strings') }
Assert-True ($rDoc2.Content -notmatch 'doc') 'doc-strings: /// stripped'
Assert-True ($rDoc2.Content -match 'plain') 'doc-strings: // untouched (guard holds)'

$rLine2 = Invoke-Processor -Item $docSrc -Config @{ Operations = @('line-comments') }
Assert-True ($rLine2.Content -match '/// doc') 'line-comments: /// untouched (negative lookahead)'
Assert-True ($rLine2.Content -notmatch 'plain') 'line-comments: // stripped'
#endregion

#region Test7_CrlfNormalization
Enter-Section '7. CRLF normalization (documented side effect)'

$rCrlf = Invoke-Processor -Item "int a = 1;`r`nint b = 2;`r`n" -Config @{ Operations = @() }
Assert-True ($rCrlf.Content -notmatch "`r") 'CRLF normalized to LF even with no ops'
Assert-Equal $rCrlf.Content "int a = 1;`nint b = 2;`n" 'content otherwise unchanged'
#endregion

#region Test8_EmptyContent
Enter-Section '8. Empty content and empty Operations'

$rEmpty = Invoke-Processor -Item ''
Assert-True ($rEmpty -is [pscustomobject]) 'empty content: returns bag'
Assert-Equal $rEmpty.Content '' 'empty content: Content is empty'

$rEmptyStr = Invoke-ProcessorRaw -Item ''
Assert-True ($rEmptyStr -is [string] -and $rEmptyStr -eq '') 'empty string in → empty string out'

$rNoop = Invoke-Processor -Item $fixture -Config @{ Operations = @() }
Assert-True ($rNoop.Content -match 'standalone block') 'empty ops: BlockComment preserved'
Assert-True ($rNoop.Content -match 'block line one') 'empty ops: CommentBlock preserved'
#endregion

#region Test9_IncludeMeta
Enter-Section '9. IncludeMeta = $false'

$rBare = Invoke-ProcessorRaw -Item $fixture -Config @{ IncludeMeta = $false }
Assert-True ($rBare -is [string]) 'IncludeMeta=false: bare string in still returns bare string'
Assert-True ($rBare -notmatch 'standalone block') 'IncludeMeta=false: stripping still applied'

$rBagNoMeta = Invoke-Processor -Item ([pscustomobject]@{ RelativePath = 'a.cs'; Content = $fixture }) -Config @{ IncludeMeta = $false }
Assert-True ($rBagNoMeta -is [pscustomobject]) 'IncludeMeta=false: bag stays a bag'
Assert-Equal $rBagNoMeta.RelativePath 'a.cs' 'IncludeMeta=false: identity survives'
Assert-True ($null -eq $rBagNoMeta.PSObject.Properties['Processing']) 'IncludeMeta=false: no Processing record'
#endregion

#region Test10_HarmonizedContract
Enter-Section '10. Harmonized content-mutator contract (6d)'

$descriptor = [pscustomobject]@{
    AbsolutePath = 'D:\repo\src\Foo.cs'
    RelativePath = 'src/Foo.cs'
    NodePath     = 'src/'
    SizeBytes    = 300
    LastWriteUtc = [datetime]'2026-07-29T12:00:00Z'
    Content      = $fixture
    Encoding     = 'UTF-8'
}
$rDesc = Invoke-Processor -Item $descriptor

Assert-Equal $rDesc.AbsolutePath 'D:\repo\src\Foo.cs' 'descriptor: AbsolutePath survives'
Assert-Equal $rDesc.RelativePath 'src/Foo.cs' 'descriptor: RelativePath survives'
Assert-Equal $rDesc.NodePath 'src/' 'descriptor: NodePath survives'
Assert-Equal $rDesc.SizeBytes 300 'descriptor: SizeBytes survives'
Assert-Equal $rDesc.LastWriteUtc ([datetime]'2026-07-29T12:00:00Z') 'descriptor: LastWriteUtc survives'
Assert-Equal $rDesc.Encoding 'UTF-8' 'descriptor: Encoding survives'
Assert-True ($rDesc.Content -notmatch 'standalone block') 'descriptor: Content mutated'
Assert-True ($null -eq $rDesc.PSObject.Properties['Text']) 'descriptor: no Text key invented'
Assert-Equal $descriptor.Content $fixture 'copy-on-mutate: input bag not mutated'

# tp-era Text key: read and written back under its own name
$tpBag = [pscustomobject]@{ Id = 'p1'; Path = 'y.cs'; Text = $fixture }
$rTp = Invoke-Processor -Item $tpBag
Assert-True ($rTp.Text -notmatch 'standalone block') 'Text-keyed bag: Text mutated in place'
Assert-True ($null -eq $rTp.PSObject.Properties['Content']) 'Text-keyed bag: no Content key invented'
Assert-Equal $rTp.Id 'p1' 'Text-keyed bag: Id passed through'

# No-content bag → returned untouched
$halted = [pscustomobject]@{ RelativePath = 'bin/x.dll'; SizeBytes = 9; ReadError = 'BinaryOrNulContent' }
$rHalt = Invoke-Processor -Item $halted
Assert-True ($null -eq $rHalt.PSObject.Properties['Content']) 'no-content bag: no phantom Content fabricated'
Assert-True ($null -eq $rHalt.PSObject.Properties['Processing']) 'no-content bag: no Processing record attached'
Assert-Equal $rHalt.ReadError 'BinaryOrNulContent' 'no-content bag: returned intact'

# Chained mutators
$fmt = Join-Path $PSScriptRoot '..\rs-whitespace.ps1'
$step1 = & $fmt $descriptor @{ Operations = @('lf') }
$step2 = Invoke-Processor -Item $step1
Assert-Equal $step2.Processing.Count 2 'chain: two records accumulated'
Assert-Equal $step2.Processing[0].Processor 'rs-whitespace' 'chain: order[0] = rs-whitespace'
Assert-Equal $step2.Processing[1].Processor 'rs-csstrip' 'chain: order[1] = rs-csstrip'
Assert-Equal $step2.RelativePath 'src/Foo.cs' 'chain: identity survives cross-processor chain'
Assert-True ($step2.Content -notmatch 'standalone block') 'chain: both mutations applied'
#endregion

Write-Host ''
Write-Host '============================================================' -ForegroundColor Yellow
$color = if ($script:Failed -eq 0) { 'Green' } else { 'Red' }
Write-Host "  Passed: $($script:Passed)   Failed: $($script:Failed)" -ForegroundColor $color
Write-Host '============================================================' -ForegroundColor Yellow
