#Requires -Version 7.6
Set-StrictMode -Version Latest

<#
.SYNOPSIS
    Unit tests for processors/rs-psstrip.ps1.

.DESCRIPTION
    Tests the processor directly (dot-invoked, not via colonel) to isolate
    behavior from dispatcher mechanics.

    Bare-string arguments to Invoke-Processor are wrapped into a minimal
    Content bag (see the helper) so the suite exercises the harmonized
    descriptor path — the shape the chain carries. Invoke-ProcessorRaw covers
    the bare-string convenience path.

    Coverage:
      1. Item unpacking — string / hashtable / pscustomobject
      2. Empty content — mutated in place, no bag invented for bare strings
      3. Parse error — tolerant token path (ParseErrors on the Processing
         record, no fallback gate)
      4. Default ops — all four structural kinds stripped, inline kept
      5. Selective ops — each kind in isolation
      6. BlockComment vs DocString distinction (AST extent classification)
      7. CommentBlock reclassification (2+ contiguous LineComment lines)
      8. Single LineComment stays LineComment (not reclassified)
      9. IncludeMeta = $false — suppresses the Processing record; a bag stays
         a bag (bare-string input still returns a bare string)
     10. No-op run — empty Operations strips nothing
     11. FrontMatter — #Requires preserved on both routes; line-1 shebang
     12. Here-strings — interiors never comment-stripped; broken here-string
         auto-routes to masked pseudo-AST fallback; MaskHereStrings override
     13. FrontMatter partition — named kind, run-splitting, discriminators
     14. Harmonized content-mutator contract (6d) — identity survival,
         copy-on-mutate, Text-key preservation, no-content pass-through,
         cross-processor Processing trail

.NOTES
    Run from any directory:
        & "$PSScriptRoot\rs-psstrip.tests.ps1"

    Processor is dot-invoked by passing -Item and -Config via $args / positional
    params using the & operator.
#>

$processorPath = Join-Path $PSScriptRoot '..\rs-psstrip.ps1'

# Shared ISS helpers (Resolve-BagContent / Copy-Bag) — colonel registers these
# into worker runspaces; dot-invocation here needs them loaded explicitly.
. (Join-Path $PSScriptRoot '_helpers.ps1')

# ---------------------------------------------------------------------------
# Assertion framework (shared pattern with colonel-dispatch.tests.ps1)
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

function Assert-Equal ($Actual, $Expected, [string]$Label)
{
    Assert-True ($Actual -eq $Expected) $Label "expected '$Expected', got '$Actual'"
}

function Invoke-Processor ([object]$Item, [hashtable]$Config = @{})
{
    # The suite exercises the harmonized descriptor path (6d) — the shape the
    # chain actually carries. A bare string argument is wrapped into a minimal
    # Content bag, so transform asserts read $r.Content. The bare-string
    # convenience path (string in → string out) is covered by
    # Invoke-ProcessorRaw in sections 1, 2, 9 and 14.
    if ($Item -is [string]) { $Item = [pscustomobject]@{ Content = $Item } }
    & $processorPath $Item $Config
}

function Invoke-ProcessorRaw ([object]$Item, [hashtable]$Config = @{})
{
    & $processorPath $Item $Config
}

# ---------------------------------------------------------------------------
# Fixture — one each of all five comment kinds
# ---------------------------------------------------------------------------
$fixture = @'
<#
.SYNOPSIS
    File-level block comment. Kind: BlockComment
#>

function Invoke-Demo {
    <#
    .SYNOPSIS
        Inside function body. Kind: DocString
    #>
    param([string]$Value)

    # CommentBlock line 1
    # CommentBlock line 2

    # Single standalone line (Kind: LineComment — not reclassified because isolated)
    $len = $Value.Length  # inline comment (Kind: InlineComment)
    return $len
}
'@

Write-Host '============================================================' -ForegroundColor Yellow
Write-Host ' rs-psstrip.tests.ps1' -ForegroundColor Yellow
Write-Host '============================================================' -ForegroundColor Yellow

# ============================================================
# 1. Item unpacking
# ============================================================
Enter-Section '1. Item unpacking'

$rStr = Invoke-ProcessorRaw -Item $fixture
$rHash = Invoke-Processor -Item @{ Content = $fixture; Id = 'h1'; Path = 'x.ps1' }
$rPsco = Invoke-Processor -Item ([pscustomobject]@{ Content = $fixture; Id = 'p1'; Path = 'y.ps1' })

Assert-True ($rStr -is [string]) 'String item: bare string in → bare string out'
Assert-True ($rStr -notmatch '(?s)<#.*?#>') 'String item: stripping applied to the returned string'
Assert-True ($rHash -is [pscustomobject]) 'Hashtable item: returns pscustomobject'
Assert-True ($rPsco -is [pscustomobject]) 'PSCustomObject item: returns pscustomobject'
Assert-Equal $rPsco.Id 'p1' 'PSCustomObject item: Id propagated'
Assert-Equal $rPsco.Path 'y.ps1' 'PSCustomObject item: Path propagated'
Assert-Equal $rPsco.Processing[0].Processor 'rs-psstrip' 'Processing record names the processor'

# ============================================================
# 2. Empty text early return
# ============================================================
Enter-Section '2. Empty text early return'

$rEmpty = Invoke-Processor -Item ''
Assert-True ($rEmpty -is [pscustomobject]) 'Empty content: returns bag'
Assert-Equal $rEmpty.Content '' 'Empty content: Content is empty string'
Assert-True ($rEmpty.Processing[0].Operations.Count -gt 0) 'Empty content: Processing record carries resolved ops'
Assert-Equal $rEmpty.Processing[0].Processor 'rs-psstrip' 'Empty content: Processing record names the processor'

$rEmptyBare = Invoke-ProcessorRaw -Item '' -Config @{ IncludeMeta = $false }
Assert-Equal $rEmptyBare '' 'Empty string, IncludeMeta=false: bare empty string'

$rEmptyStr = Invoke-ProcessorRaw -Item ''
Assert-True ($rEmptyStr -is [string] -and $rEmptyStr -eq '') 'Empty string in → empty string out (no bag invented)'

# ============================================================
# 3. Parse error — tolerant token path
# ============================================================
Enter-Section '3. Parse error — tolerant token path'

# Unclosed paren guarantees parse error; the tokenizer is error-recovering, so
# the token walk still runs: ParseErrors reported, FallbackMode absent.
$broken = '$x = (' + "`n" + '<# block comment #>' + "`n" + '# line comment' + "`n"

$rBroken = Invoke-Processor -Item $broken
$brokenRec = $rBroken.Processing[0]
Assert-True ($rBroken -is [pscustomobject]) 'Broken PS: returns bag'
Assert-True ($null -ne $brokenRec.PSObject.Properties['ParseErrors']) 'Broken PS: ParseErrors on the Processing record'
Assert-True ($brokenRec.ParseErrors.Count -gt 0) 'Broken PS: ParseErrors non-empty'
Assert-True ($null -eq $brokenRec.PSObject.Properties['FallbackMode']) 'Broken PS: token path used (no FallbackMode)'
Assert-True ($rBroken.Content -notmatch '(?s)<#.*?#>') 'Broken PS: block comment stripped via tokens'
Assert-True ($rBroken.Content -notmatch '# line comment') 'Broken PS: line comment stripped via tokens'
Assert-True ($rBroken.Content -match '\$x') 'Broken PS: code preserved'

# Forced fallback still available and still strips
$rForced = Invoke-Processor -Item $broken -Config @{ ForceRegexFallback = $true }
Assert-Equal $rForced.Processing[0].FallbackMode 'regex' 'ForceRegexFallback: regex route active'
Assert-True ($rForced.Content -notmatch '# line comment') 'ForceRegexFallback: comment stripped'

# ============================================================
# 4. Default ops
# ============================================================
Enter-Section '4. Default ops (block-comments, doc-strings, comment-blocks, line-comments — inline kept)'

$rDefault = Invoke-Processor -Item $fixture

Assert-True ($rDefault.Content -notmatch '(?s)<#.*?#>') 'Default: BlockComment stripped'
Assert-True ($rDefault.Content -notmatch '# CommentBlock line') 'Default: CommentBlock stripped'
Assert-True ($rDefault.Content -notmatch '# Single standalone') 'Default: LineComment stripped'
Assert-True ($rDefault.Content -match '# inline comment') 'Default: InlineComment kept'
Assert-True ($rDefault.Content -match 'function Invoke-Demo') 'Default: code preserved'

# ============================================================
# 5. Selective ops — each kind in isolation
# ============================================================
Enter-Section '5. Selective ops'

$rBcOnly = Invoke-Processor -Item $fixture -Config @{ Operations = @('block-comments') }
Assert-True ($rBcOnly.Content -notmatch '(?s)\.SYNOPSIS\s+File-level') 'block-comments: BlockComment stripped'
Assert-True ($rBcOnly.Content -match '\.SYNOPSIS\s+Inside function') 'block-comments: DocString kept'
Assert-True ($rBcOnly.Content -match '# CommentBlock line') 'block-comments: CommentBlock kept'

$rDsOnly = Invoke-Processor -Item $fixture -Config @{ Operations = @('doc-strings') }
Assert-True ($rDsOnly.Content -match '(?s)\.SYNOPSIS\s+File-level') 'doc-strings: BlockComment kept'
Assert-True ($rDsOnly.Content -notmatch '\.SYNOPSIS\s+Inside function') 'doc-strings: DocString stripped'

$rCbOnly = Invoke-Processor -Item $fixture -Config @{ Operations = @('comment-blocks') }
Assert-True ($rCbOnly.Content -notmatch '# CommentBlock line') 'comment-blocks: CommentBlock stripped'
Assert-True ($rCbOnly.Content -match '# Single standalone') 'comment-blocks: LineComment kept'

$rLcOnly = Invoke-Processor -Item $fixture -Config @{ Operations = @('line-comments') }
Assert-True ($rLcOnly.Content -notmatch '# Single standalone') 'line-comments: LineComment stripped'
Assert-True ($rLcOnly.Content -match '# CommentBlock line') 'line-comments: CommentBlock kept'

$rIcOnly = Invoke-Processor -Item $fixture -Config @{ Operations = @('inline-comments') }
Assert-True ($rIcOnly.Content -notmatch '# inline comment') 'inline-comments: InlineComment stripped'
Assert-True ($rIcOnly.Content -match '# Single standalone') 'inline-comments: LineComment kept'

# ============================================================
# 6. BlockComment vs DocString distinction
# ============================================================
Enter-Section '6. BlockComment vs DocString classification'

# A <# #> at file level should be BlockComment; one inside a function should be DocString
# Stripping block-comments only must leave the inner DocString intact
$rBcStripped = Invoke-Processor -Item $fixture -Config @{ Operations = @('block-comments') }
Assert-True ($rBcStripped.Content -match '\.SYNOPSIS\s+Inside function') 'Extent-based: DocString survives block-comments-only strip'

# Stripping doc-strings only must leave the outer BlockComment intact
$rDsStripped = Invoke-Processor -Item $fixture -Config @{ Operations = @('doc-strings') }
Assert-True ($rDsStripped.Content -match '\.SYNOPSIS\s+File-level') 'Extent-based: BlockComment survives doc-strings-only strip'

# ============================================================
# 7. CommentBlock reclassification (2+ contiguous lines)
# ============================================================
Enter-Section '7. CommentBlock reclassification'

$cbFixture = @'
function Test-Cb {
    # block line 1
    # block line 2
    # block line 3
    $x = 1
}
'@

$rCbRun = Invoke-Processor -Item $cbFixture -Config @{ Operations = @('comment-blocks') }
Assert-True ($rCbRun.Content -notmatch '# block line') 'CommentBlock: 3-line run stripped by comment-blocks op'

# Confirm same run is NOT stripped by line-comments op
$rCbLcRun = Invoke-Processor -Item $cbFixture -Config @{ Operations = @('line-comments') }
Assert-True ($rCbLcRun.Content -match '# block line') 'CommentBlock: 3-line run kept when only line-comments op active'

# ============================================================
# 8. Single LineComment stays LineComment (no reclassification)
# ============================================================
Enter-Section '8. Single isolated LineComment'

$lcFixture = @'
function Test-Lc {
    $x = 1

    # isolated single line comment

    $y = 2
}
'@

# line-comments strips it; comment-blocks must not
$rLcIso = Invoke-Processor -Item $lcFixture -Config @{ Operations = @('line-comments') }
Assert-True ($rLcIso.Content -notmatch '# isolated single line comment') 'Isolated LineComment: stripped by line-comments'

$rCbIso = Invoke-Processor -Item $lcFixture -Config @{ Operations = @('comment-blocks') }
Assert-True ($rCbIso.Content -match '# isolated single line comment') 'Isolated LineComment: kept by comment-blocks op'

# ============================================================
# 9. IncludeMeta = $false
# ============================================================
Enter-Section '9. IncludeMeta = $false'

$rBare = Invoke-ProcessorRaw -Item $fixture -Config @{ IncludeMeta = $false }
Assert-True ($rBare -is [string]) 'IncludeMeta=false: bare string in still returns bare string'
Assert-True ($rBare -notmatch '(?s)<#.*#>') 'IncludeMeta=false: BlockComment still stripped'

# Harmonized contract (6d): IncludeMeta suppresses the Processing record — it
# never collapses a bag to a bare string (that was the tp-era envelope behavior).
$rBagNoMeta = Invoke-Processor -Item ([pscustomobject]@{ RelativePath = 'a.ps1'; Content = $fixture }) -Config @{ IncludeMeta = $false }
Assert-True ($rBagNoMeta -is [pscustomobject]) 'IncludeMeta=false: bag stays a bag'
Assert-Equal $rBagNoMeta.RelativePath 'a.ps1' 'IncludeMeta=false: identity survives'
Assert-True ($rBagNoMeta.Content -notmatch '(?s)<#.*#>') 'IncludeMeta=false: BlockComment stripped in bag'
Assert-True ($null -eq $rBagNoMeta.PSObject.Properties['Processing']) 'IncludeMeta=false: no Processing record'

# ============================================================
# 10. Empty Operations — no-op
# ============================================================
Enter-Section '10. Empty Operations = no stripping'

$rNoop = Invoke-Processor -Item $fixture -Config @{ Operations = @() }
Assert-True ($rNoop.Content -match '(?s)<#.*?#>') 'Empty ops: BlockComment preserved'
Assert-True ($rNoop.Content -match '# CommentBlock') 'Empty ops: CommentBlock preserved'

# ============================================================
# 11. FrontMatter — #Requires never stripped (either path)
# ============================================================
Enter-Section '11. FrontMatter: #Requires preservation'

$fmFixture = @'
#Requires -Version 7.0
# leading comment above code
function Test-Fm {
    $x = 1
}
'@

# AST path, default ops (all four structural kinds active)
$rFm = Invoke-Processor -Item $fmFixture
Assert-True ($rFm.Content -match '(?m)^#Requires -Version 7\.0') 'AST path: #Requires survives default ops'
Assert-True ($rFm.Content -notmatch 'leading comment') 'AST path: neighboring comment still stripped'

# Lowercase form is equally protected
$rFmLc = Invoke-Processor -Item ($fmFixture -replace '#Requires', '#requires')
Assert-True ($rFmLc.Content -match '(?m)^#requires -Version 7\.0') 'AST path: lowercase #requires survives'

# Sandwich: #Requires between comment lines — exclusion splits the run,
# but with comment-blocks + line-comments both active the neighbors go either way
$fmSandwich = @'
# above
#Requires -Version 7.0
# below
function Test-FmS { $x = 1 }
'@
$rFmS = Invoke-Processor -Item $fmSandwich -Config @{ Operations = @('comment-blocks', 'line-comments') }
Assert-True ($rFmS.Content -match '(?m)^#Requires -Version 7\.0') 'Sandwich: #Requires survives'
Assert-True ($rFmS.Content -notmatch '# above' -and $rFmS.Content -notmatch '# below') 'Sandwich: neighbors stripped'

# Broken file (unclosed brace): token path now handles it — tolerant routing.
# Forced fallback covers the (?i:requires) case-guard regression separately.
$fmBroken = @'
#Requires -Version 7.0
# fallback comment
function Broken {
    $x = 1
'@
$rFmFb = Invoke-Processor -Item $fmBroken
Assert-True ($null -eq $rFmFb.Processing[0].PSObject.Properties['FallbackMode']) 'Broken file: token path (no fallback)'
Assert-True ($rFmFb.Content -match '(?m)^#Requires -Version 7\.0') 'Broken file: #Requires survives token path'
Assert-True ($rFmFb.Content -notmatch '# fallback comment') 'Broken file: ordinary comment still stripped'

$rFmForced = Invoke-Processor -Item $fmBroken -Config @{ ForceRegexFallback = $true }
Assert-Equal $rFmForced.Processing[0].FallbackMode 'regex' 'Forced fallback: regex route active'
Assert-True ($rFmForced.Content -match '(?m)^#Requires -Version 7\.0') 'Forced fallback: capitalized #Requires survives'

# Line-1 shebang is frontmatter on the token path
$rShebang = Invoke-Processor -Item ("#!/usr/bin/env pwsh`n# c`n`$x = 1`n")
Assert-True ($rShebang.Content -match '^#!/usr/bin/env pwsh') 'Shebang: line-1 #! survives token path'
Assert-True ($rShebang.Content -notmatch '# c') 'Shebang: following comment stripped'

# ============================================================
# 12. Here-strings — code payload, never comment-stripped
# ============================================================
Enter-Section '12. Here-strings'

# Clean parse: the token walk sees one string token; interior # lines untouched
$hsClean = @'
$doc = @"
# not a comment
<# also not a comment #>
"@
# real comment
$y = 2
'@
$rHsClean = Invoke-Processor -Item $hsClean
Assert-True ($rHsClean.Content -match '# not a comment') 'Token path: here-string interior # survives'
Assert-True ($rHsClean.Content -match 'also not a comment') 'Token path: here-string interior block-form survives'
Assert-True ($rHsClean.Content -notmatch '# real comment') 'Token path: comment outside here-string stripped'

# Broken here-string (indented closer = invalid): tokenizer swallows the tail,
# so the processor auto-routes to the masked pseudo-AST fallback, which masks
# through the lenient closer and recovers stripping beyond the breakage.
$hsBroken = @'
# leading comment
$h = @"
# inside broken here-string
  "@
# after breakage
$z = 3
'@
$rHsBroken = Invoke-Processor -Item $hsBroken
Assert-Equal $rHsBroken.Processing[0].FallbackMode 'regex' 'Broken here-string: auto-routed to pseudo-AST fallback'
Assert-True ($rHsBroken.Content -match '# inside broken here-string') 'Broken here-string: interior survives (masked)'
Assert-True ($rHsBroken.Content -notmatch '# leading comment') 'Broken here-string: comment before opener stripped'
Assert-True ($rHsBroken.Content -notmatch '# after breakage') 'Broken here-string: comment after lenient closer stripped (recovery)'
Assert-True ($rHsBroken.Content -match '\$z = 3') 'Broken here-string: code after breakage preserved'

# MaskHereStrings override: forced fallback with masking off processes interiors
$hsTerm = @'
$doc = @"
# masked line
"@
# outer comment
'@
$rHsMaskOn = Invoke-Processor -Item $hsTerm -Config @{ ForceRegexFallback = $true }
Assert-True ($rHsMaskOn.Content -match '# masked line') 'Forced fallback default: terminated here-string masked+restored'
Assert-True ($rHsMaskOn.Content -notmatch '# outer comment') 'Forced fallback: outer comment stripped'

$rHsMaskOff = Invoke-Processor -Item $hsTerm -Config @{ ForceRegexFallback = $true; MaskHereStrings = $false }
Assert-True ($rHsMaskOff.Content -notmatch '# masked line') 'MaskHereStrings=$false: interior processed by fallback regexes'

# ============================================================
# 13. FrontMatter as named kind — partition semantics (6c)
# ============================================================
Enter-Section '13. FrontMatter partition: named kind, run-splitting, discriminators'

# Clean-parse preservation under MAXIMAL ops — every strip op active, both
# frontmatter species survive (no op can select the FrontMatter kind)
$fmMax = @'
#Requires -Version 7.0
# doomed line comment
$a = 1  # doomed inline
'@
$rFmMax = Invoke-Processor -Item $fmMax -Config @{ Operations = @('block-comments', 'doc-strings', 'comment-blocks', 'line-comments', 'inline-comments') }
Assert-True ($rFmMax.Content -match '(?m)^#Requires -Version 7\.0') 'Maximal ops: #Requires survives'
Assert-True ($rFmMax.Content -notmatch 'doomed') 'Maximal ops: every ordinary comment stripped'

$rShMax = Invoke-Processor -Item ("#!/usr/bin/env pwsh`n# doomed`n`$x = 1  # doomed too`n") `
    -Config @{ Operations = @('block-comments', 'doc-strings', 'comment-blocks', 'line-comments', 'inline-comments') }
Assert-True ($rShMax.Content -match '^#!/usr/bin/env pwsh') 'Maximal ops: shebang survives'
Assert-True ($rShMax.Content -notmatch 'doomed') 'Maximal ops: ordinary comments around shebang stripped'

# Discriminators — the byte after # decides (space/no-space, word boundary)
$rSpaced = Invoke-Processor -Item ("# Requires manual setup of the corpus`n`$x = 1`n")
Assert-True ($rSpaced.Content -notmatch 'Requires manual setup') 'Spaced "# Requires ..." is an ordinary comment — stripped'

$rNoWb = Invoke-Processor -Item ("#requiresXYZ not a directive`n`$x = 1`n")
Assert-True ($rNoWb.Content -notmatch 'requiresXYZ') 'No word boundary: #requiresXYZ is an ordinary comment — stripped'

$rShLate = Invoke-Processor -Item ("`$a = 1`n#!/not/line-one`n`$b = 2`n")
Assert-True ($rShLate.Content -notmatch '/not/line-one') 'Shebang form off line 1 is an ordinary comment — stripped'

# Run-splitting as STATED policy: sandwich with ONLY comment-blocks active.
# FrontMatter splits the would-be run — each neighbor is a 1-line run,
# classifies LineComment, and is therefore NOT stripped by comment-blocks.
$fmSplit = @'
# above
#Requires -Version 7.0
# below
function Test-Split { $x = 1 }
'@
$rSplit = Invoke-Processor -Item $fmSplit -Config @{ Operations = @('comment-blocks') }
Assert-True ($rSplit.Content -match '(?m)^#Requires -Version 7\.0') 'Run-split: #Requires survives'
Assert-True ($rSplit.Content -match '# above' -and $rSplit.Content -match '# below') `
    'Run-split: neighbors stay LineComment (1-line runs) — NOT folded into a CommentBlock across the directive'

# Control: without the directive the same two lines ARE a CommentBlock run
$rNoSplit = Invoke-Processor -Item ($fmSplit -replace '(?m)^#Requires -Version 7\.0\r?\n', '') -Config @{ Operations = @('comment-blocks') }
Assert-True ($rNoSplit.Content -notmatch '# above' -and $rNoSplit.Content -notmatch '# below') `
    'Control: adjacent pair without directive folds to CommentBlock and strips'

# Output contract unchanged by the partition — FrontMatter is an internal kind,
# never a surfaced field (on the bag or on the Processing record).
$rEnv = Invoke-Processor -Item $fmMax
Assert-True ($null -eq $rEnv.PSObject.Properties['FrontMatter']) 'Bag shape unchanged (no FrontMatter field)'
Assert-True ($null -eq $rEnv.Processing[0].PSObject.Properties['FrontMatter']) 'Processing record carries no FrontMatter field'

# ============================================================
# 14. Harmonized content-mutator contract (consolidation 6d)
# ============================================================
Enter-Section '14. Harmonized content-mutator contract (6d)'

$descriptor = [pscustomobject]@{
    AbsolutePath = 'D:\repo\src\a.ps1'
    RelativePath = 'src/a.ps1'
    NodePath     = 'src/'
    SizeBytes    = 120
    LastWriteUtc = [datetime]'2026-07-29T12:00:00Z'
    Content      = $fixture
    Encoding     = 'UTF-8'
}
$rDesc = Invoke-Processor -Item $descriptor

Assert-Equal $rDesc.AbsolutePath 'D:\repo\src\a.ps1' 'descriptor: AbsolutePath survives'
Assert-Equal $rDesc.RelativePath 'src/a.ps1' 'descriptor: RelativePath survives'
Assert-Equal $rDesc.NodePath 'src/' 'descriptor: NodePath survives'
Assert-Equal $rDesc.SizeBytes 120 'descriptor: SizeBytes survives'
Assert-Equal $rDesc.LastWriteUtc ([datetime]'2026-07-29T12:00:00Z') 'descriptor: LastWriteUtc survives'
Assert-Equal $rDesc.Encoding 'UTF-8' 'descriptor: Encoding survives'
Assert-True ($rDesc.Content -notmatch '(?s)<#.*?#>') 'descriptor: Content mutated (block comment stripped)'
Assert-True ($null -eq $rDesc.PSObject.Properties['Text']) 'descriptor: no Text key invented'
Assert-Equal $descriptor.Content $fixture 'copy-on-mutate: input bag not mutated'

# tp-era Text key: read and written back under its own name (track-agnostic).
$tpBag = [pscustomobject]@{ Id = 'p1'; Path = 'y.ps1'; Text = $fixture }
$rTp = Invoke-Processor -Item $tpBag
Assert-True ($rTp.Text -notmatch '(?s)<#.*?#>') 'Text-keyed bag: Text mutated in place'
Assert-True ($null -eq $rTp.PSObject.Properties['Content']) 'Text-keyed bag: no Content key invented'
Assert-Equal $rTp.Id 'p1' 'Text-keyed bag: Id passed through'

# No-content bag → returned untouched (mirrors rs-content_meta's no-Content rule).
# A mutator must not fabricate an empty payload: assemble splits EmptyFile from
# EmptiedByProcessing and routes empty content to Diagnostics.
$halted = [pscustomobject]@{ RelativePath = 'bin/x.dll'; SizeBytes = 9; ReadError = 'BinaryOrNulContent' }
$rHalt = Invoke-Processor -Item $halted
Assert-True ($null -eq $rHalt.PSObject.Properties['Content']) 'no-content bag: no phantom Content fabricated'
Assert-True ($null -eq $rHalt.PSObject.Properties['Processing']) 'no-content bag: no Processing record attached'
Assert-Equal $rHalt.ReadError 'BinaryOrNulContent' 'no-content bag: returned intact'

# Chained mutators: the trail accumulates in chain order and identity survives.
$fmt = Join-Path $PSScriptRoot '..\rs-whitespace.ps1'
$step1 = & $fmt $descriptor @{ Operations = @('lf') }
$step2 = Invoke-Processor -Item $step1
Assert-Equal $step2.Processing.Count 2 'chain: two records accumulated'
Assert-Equal $step2.Processing[0].Processor 'rs-whitespace' 'chain: order[0] = rs-whitespace'
Assert-Equal $step2.Processing[1].Processor 'rs-psstrip' 'chain: order[1] = rs-psstrip'
Assert-Equal $step2.RelativePath 'src/a.ps1' 'chain: identity survives cross-processor chain'
Assert-Equal $step2.SizeBytes 120 'chain: SizeBytes survives cross-processor chain'
Assert-True ($step2.Content -notmatch '(?s)<#.*?#>') 'chain: both mutations applied'

# ============================================================
# Summary
# ============================================================
Write-Host ''
Write-Host '============================================================' -ForegroundColor Yellow
$color = if ($script:Failed -eq 0) { 'Green' } else { 'Red' }
Write-Host "  Passed: $($script:Passed)   Failed: $($script:Failed)" -ForegroundColor $color
Write-Host '============================================================' -ForegroundColor Yellow
