#Requires -Version 7.6
Set-StrictMode -Version Latest

<#
.SYNOPSIS
    Unit tests for processors/rs-psstrip.ps1.

.DESCRIPTION
    Tests the processor directly (dot-invoked, not via colonel) to isolate
    behavior from dispatcher mechanics.

    Coverage:
      1. Item unpacking — string / hashtable / pscustomobject
      2. Empty text early return
      3. Parse error — tolerant token path (ParseErrors reported, no fallback gate)
      4. Default ops — all four structural kinds stripped, inline kept
      5. Selective ops — each kind in isolation
      6. BlockComment vs DocString distinction (AST extent classification)
      7. CommentBlock reclassification (2+ contiguous LineComment lines)
      8. Single LineComment stays LineComment (not reclassified)
      9. IncludeMeta = $false — bare string returned
     10. No-op run — empty Operations strips nothing
     11. FrontMatter — #Requires preserved on both routes; line-1 shebang
     12. Here-strings — interiors never comment-stripped; broken here-string
         auto-routes to masked pseudo-AST fallback; MaskHereStrings override

.NOTES
    Run from any directory:
        & "$PSScriptRoot\rs-psstrip.tests.ps1"

    Processor is dot-invoked by passing -Item and -Config via $args / positional
    params using the & operator.
#>

$processorPath = Join-Path $PSScriptRoot '..\rs-psstrip.ps1'

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

$rStr = Invoke-Processor -Item $fixture
$rHash = Invoke-Processor -Item @{ Text = $fixture; Id = 'h1'; Path = 'x.ps1' }
$rPsco = Invoke-Processor -Item ([pscustomobject]@{ Text = $fixture; Id = 'p1'; Path = 'y.ps1' })

Assert-True ($rStr -is [pscustomobject]) 'String item: returns pscustomobject'
Assert-True ($rHash -is [pscustomobject]) 'Hashtable item: returns pscustomobject'
Assert-True ($rPsco -is [pscustomobject]) 'PSCustomObject item: returns pscustomobject'
Assert-Equal $rPsco.Id 'p1' 'PSCustomObject item: Id propagated'
Assert-Equal $rPsco.Path 'y.ps1' 'PSCustomObject item: Path propagated'

# ============================================================
# 2. Empty text early return
# ============================================================
Enter-Section '2. Empty text early return'

$rEmpty = Invoke-Processor -Item ''
Assert-True ($rEmpty -is [pscustomobject]) 'Empty string: returns object'
Assert-Equal $rEmpty.Text '' 'Empty string: Text is empty string'
Assert-True ($rEmpty.Operations.Count -gt 0) 'Empty string: Operations field present'
Assert-Equal $rEmpty.Processor 'rs-psstrip' 'Empty string: Processor field set'

$rEmptyBare = Invoke-Processor -Item '' -Config @{ IncludeMeta = $false }
Assert-Equal $rEmptyBare '' 'Empty string, IncludeMeta=false: bare empty string'

# ============================================================
# 3. Parse error — tolerant token path
# ============================================================
Enter-Section '3. Parse error — tolerant token path'

# Unclosed paren guarantees parse error; the tokenizer is error-recovering, so
# the token walk still runs: ParseErrors reported, FallbackMode absent.
$broken = '$x = (' + "`n" + '<# block comment #>' + "`n" + '# line comment' + "`n"

$rBroken = Invoke-Processor -Item $broken
Assert-True ($rBroken -is [pscustomobject]) 'Broken PS: returns object'
Assert-True ($null -ne $rBroken.PSObject.Properties['ParseErrors']) 'Broken PS: ParseErrors field present'
Assert-True ($rBroken.ParseErrors.Count -gt 0) 'Broken PS: ParseErrors non-empty'
Assert-True ($null -eq $rBroken.PSObject.Properties['FallbackMode']) 'Broken PS: token path used (no FallbackMode)'
Assert-True ($rBroken.Text -notmatch '(?s)<#.*?#>') 'Broken PS: block comment stripped via tokens'
Assert-True ($rBroken.Text -notmatch '# line comment') 'Broken PS: line comment stripped via tokens'
Assert-True ($rBroken.Text -match '\$x') 'Broken PS: code preserved'

# Forced fallback still available and still strips
$rForced = Invoke-Processor -Item $broken -Config @{ ForceRegexFallback = $true }
Assert-Equal $rForced.FallbackMode 'regex' 'ForceRegexFallback: regex route active'
Assert-True ($rForced.Text -notmatch '# line comment') 'ForceRegexFallback: comment stripped'

# ============================================================
# 4. Default ops
# ============================================================
Enter-Section '4. Default ops (block-comments, doc-strings, comment-blocks, line-comments — inline kept)'

$rDefault = Invoke-Processor -Item $fixture

Assert-True ($rDefault.Text -notmatch '(?s)<#.*?#>') 'Default: BlockComment stripped'
Assert-True ($rDefault.Text -notmatch '# CommentBlock line') 'Default: CommentBlock stripped'
Assert-True ($rDefault.Text -notmatch '# Single standalone') 'Default: LineComment stripped'
Assert-True ($rDefault.Text -match '# inline comment') 'Default: InlineComment kept'
Assert-True ($rDefault.Text -match 'function Invoke-Demo') 'Default: code preserved'

# ============================================================
# 5. Selective ops — each kind in isolation
# ============================================================
Enter-Section '5. Selective ops'

$rBcOnly = Invoke-Processor -Item $fixture -Config @{ Operations = @('block-comments') }
Assert-True ($rBcOnly.Text -notmatch '(?s)\.SYNOPSIS\s+File-level') 'block-comments: BlockComment stripped'
Assert-True ($rBcOnly.Text -match '\.SYNOPSIS\s+Inside function') 'block-comments: DocString kept'
Assert-True ($rBcOnly.Text -match '# CommentBlock line') 'block-comments: CommentBlock kept'

$rDsOnly = Invoke-Processor -Item $fixture -Config @{ Operations = @('doc-strings') }
Assert-True ($rDsOnly.Text -match '(?s)\.SYNOPSIS\s+File-level') 'doc-strings: BlockComment kept'
Assert-True ($rDsOnly.Text -notmatch '\.SYNOPSIS\s+Inside function') 'doc-strings: DocString stripped'

$rCbOnly = Invoke-Processor -Item $fixture -Config @{ Operations = @('comment-blocks') }
Assert-True ($rCbOnly.Text -notmatch '# CommentBlock line') 'comment-blocks: CommentBlock stripped'
Assert-True ($rCbOnly.Text -match '# Single standalone') 'comment-blocks: LineComment kept'

$rLcOnly = Invoke-Processor -Item $fixture -Config @{ Operations = @('line-comments') }
Assert-True ($rLcOnly.Text -notmatch '# Single standalone') 'line-comments: LineComment stripped'
Assert-True ($rLcOnly.Text -match '# CommentBlock line') 'line-comments: CommentBlock kept'

$rIcOnly = Invoke-Processor -Item $fixture -Config @{ Operations = @('inline-comments') }
Assert-True ($rIcOnly.Text -notmatch '# inline comment') 'inline-comments: InlineComment stripped'
Assert-True ($rIcOnly.Text -match '# Single standalone') 'inline-comments: LineComment kept'

# ============================================================
# 6. BlockComment vs DocString distinction
# ============================================================
Enter-Section '6. BlockComment vs DocString classification'

# A <# #> at file level should be BlockComment; one inside a function should be DocString
# Stripping block-comments only must leave the inner DocString intact
$rBcStripped = Invoke-Processor -Item $fixture -Config @{ Operations = @('block-comments') }
Assert-True ($rBcStripped.Text -match '\.SYNOPSIS\s+Inside function') 'Extent-based: DocString survives block-comments-only strip'

# Stripping doc-strings only must leave the outer BlockComment intact
$rDsStripped = Invoke-Processor -Item $fixture -Config @{ Operations = @('doc-strings') }
Assert-True ($rDsStripped.Text -match '\.SYNOPSIS\s+File-level') 'Extent-based: BlockComment survives doc-strings-only strip'

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
Assert-True ($rCbRun.Text -notmatch '# block line') 'CommentBlock: 3-line run stripped by comment-blocks op'

# Confirm same run is NOT stripped by line-comments op
$rCbLcRun = Invoke-Processor -Item $cbFixture -Config @{ Operations = @('line-comments') }
Assert-True ($rCbLcRun.Text -match '# block line') 'CommentBlock: 3-line run kept when only line-comments op active'

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
Assert-True ($rLcIso.Text -notmatch '# isolated single line comment') 'Isolated LineComment: stripped by line-comments'

$rCbIso = Invoke-Processor -Item $lcFixture -Config @{ Operations = @('comment-blocks') }
Assert-True ($rCbIso.Text -match '# isolated single line comment') 'Isolated LineComment: kept by comment-blocks op'

# ============================================================
# 9. IncludeMeta = $false
# ============================================================
Enter-Section '9. IncludeMeta = $false'

$rBare = Invoke-Processor -Item $fixture -Config @{ IncludeMeta = $false }
Assert-True ($rBare -is [string]) 'IncludeMeta=false: bare string returned'
Assert-True ($rBare -notmatch '(?s)<#.*#>') 'IncludeMeta=false: BlockComment still stripped'

# ============================================================
# 10. Empty Operations — no-op
# ============================================================
Enter-Section '10. Empty Operations = no stripping'

$rNoop = Invoke-Processor -Item $fixture -Config @{ Operations = @() }
Assert-True ($rNoop.Text -match '(?s)<#.*?#>') 'Empty ops: BlockComment preserved'
Assert-True ($rNoop.Text -match '# CommentBlock') 'Empty ops: CommentBlock preserved'

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
Assert-True ($rFm.Text -match '(?m)^#Requires -Version 7\.0') 'AST path: #Requires survives default ops'
Assert-True ($rFm.Text -notmatch 'leading comment') 'AST path: neighboring comment still stripped'

# Lowercase form is equally protected
$rFmLc = Invoke-Processor -Item ($fmFixture -replace '#Requires', '#requires')
Assert-True ($rFmLc.Text -match '(?m)^#requires -Version 7\.0') 'AST path: lowercase #requires survives'

# Sandwich: #Requires between comment lines — exclusion splits the run,
# but with comment-blocks + line-comments both active the neighbors go either way
$fmSandwich = @'
# above
#Requires -Version 7.0
# below
function Test-FmS { $x = 1 }
'@
$rFmS = Invoke-Processor -Item $fmSandwich -Config @{ Operations = @('comment-blocks', 'line-comments') }
Assert-True ($rFmS.Text -match '(?m)^#Requires -Version 7\.0') 'Sandwich: #Requires survives'
Assert-True ($rFmS.Text -notmatch '# above' -and $rFmS.Text -notmatch '# below') 'Sandwich: neighbors stripped'

# Broken file (unclosed brace): token path now handles it — tolerant routing.
# Forced fallback covers the (?i:requires) case-guard regression separately.
$fmBroken = @'
#Requires -Version 7.0
# fallback comment
function Broken {
    $x = 1
'@
$rFmFb = Invoke-Processor -Item $fmBroken
Assert-True ($null -eq $rFmFb.PSObject.Properties['FallbackMode']) 'Broken file: token path (no fallback)'
Assert-True ($rFmFb.Text -match '(?m)^#Requires -Version 7\.0') 'Broken file: #Requires survives token path'
Assert-True ($rFmFb.Text -notmatch '# fallback comment') 'Broken file: ordinary comment still stripped'

$rFmForced = Invoke-Processor -Item $fmBroken -Config @{ ForceRegexFallback = $true }
Assert-Equal $rFmForced.FallbackMode 'regex' 'Forced fallback: regex route active'
Assert-True ($rFmForced.Text -match '(?m)^#Requires -Version 7\.0') 'Forced fallback: capitalized #Requires survives'

# Line-1 shebang is frontmatter on the token path
$rShebang = Invoke-Processor -Item ("#!/usr/bin/env pwsh`n# c`n`$x = 1`n")
Assert-True ($rShebang.Text -match '^#!/usr/bin/env pwsh') 'Shebang: line-1 #! survives token path'
Assert-True ($rShebang.Text -notmatch '# c') 'Shebang: following comment stripped'

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
Assert-True ($rHsClean.Text -match '# not a comment') 'Token path: here-string interior # survives'
Assert-True ($rHsClean.Text -match 'also not a comment') 'Token path: here-string interior block-form survives'
Assert-True ($rHsClean.Text -notmatch '# real comment') 'Token path: comment outside here-string stripped'

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
Assert-Equal $rHsBroken.FallbackMode 'regex' 'Broken here-string: auto-routed to pseudo-AST fallback'
Assert-True ($rHsBroken.Text -match '# inside broken here-string') 'Broken here-string: interior survives (masked)'
Assert-True ($rHsBroken.Text -notmatch '# leading comment') 'Broken here-string: comment before opener stripped'
Assert-True ($rHsBroken.Text -notmatch '# after breakage') 'Broken here-string: comment after lenient closer stripped (recovery)'
Assert-True ($rHsBroken.Text -match '\$z = 3') 'Broken here-string: code after breakage preserved'

# MaskHereStrings override: forced fallback with masking off processes interiors
$hsTerm = @'
$doc = @"
# masked line
"@
# outer comment
'@
$rHsMaskOn = Invoke-Processor -Item $hsTerm -Config @{ ForceRegexFallback = $true }
Assert-True ($rHsMaskOn.Text -match '# masked line') 'Forced fallback default: terminated here-string masked+restored'
Assert-True ($rHsMaskOn.Text -notmatch '# outer comment') 'Forced fallback: outer comment stripped'

$rHsMaskOff = Invoke-Processor -Item $hsTerm -Config @{ ForceRegexFallback = $true; MaskHereStrings = $false }
Assert-True ($rHsMaskOff.Text -notmatch '# masked line') 'MaskHereStrings=$false: interior processed by fallback regexes'

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
Assert-True ($rFmMax.Text -match '(?m)^#Requires -Version 7\.0') 'Maximal ops: #Requires survives'
Assert-True ($rFmMax.Text -notmatch 'doomed') 'Maximal ops: every ordinary comment stripped'

$rShMax = Invoke-Processor -Item ("#!/usr/bin/env pwsh`n# doomed`n`$x = 1  # doomed too`n") `
    -Config @{ Operations = @('block-comments', 'doc-strings', 'comment-blocks', 'line-comments', 'inline-comments') }
Assert-True ($rShMax.Text -match '^#!/usr/bin/env pwsh') 'Maximal ops: shebang survives'
Assert-True ($rShMax.Text -notmatch 'doomed') 'Maximal ops: ordinary comments around shebang stripped'

# Discriminators — the byte after # decides (space/no-space, word boundary)
$rSpaced = Invoke-Processor -Item ("# Requires manual setup of the corpus`n`$x = 1`n")
Assert-True ($rSpaced.Text -notmatch 'Requires manual setup') 'Spaced "# Requires ..." is an ordinary comment — stripped'

$rNoWb = Invoke-Processor -Item ("#requiresXYZ not a directive`n`$x = 1`n")
Assert-True ($rNoWb.Text -notmatch 'requiresXYZ') 'No word boundary: #requiresXYZ is an ordinary comment — stripped'

$rShLate = Invoke-Processor -Item ("`$a = 1`n#!/not/line-one`n`$b = 2`n")
Assert-True ($rShLate.Text -notmatch '/not/line-one') 'Shebang form off line 1 is an ordinary comment — stripped'

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
Assert-True ($rSplit.Text -match '(?m)^#Requires -Version 7\.0') 'Run-split: #Requires survives'
Assert-True ($rSplit.Text -match '# above' -and $rSplit.Text -match '# below') `
    'Run-split: neighbors stay LineComment (1-line runs) — NOT folded into a CommentBlock across the directive'

# Control: without the directive the same two lines ARE a CommentBlock run
$rNoSplit = Invoke-Processor -Item ($fmSplit -replace '(?m)^#Requires -Version 7\.0\r?\n', '') -Config @{ Operations = @('comment-blocks') }
Assert-True ($rNoSplit.Text -notmatch '# above' -and $rNoSplit.Text -notmatch '# below') `
    'Control: adjacent pair without directive folds to CommentBlock and strips'

# Envelope contract unchanged — no new fields from the partition
$rEnv = Invoke-Processor -Item $fmMax
Assert-True ($null -eq $rEnv.PSObject.Properties['FrontMatter']) 'Envelope shape unchanged (no FrontMatter field)'

# ============================================================
# Summary
# ============================================================
Write-Host ''
Write-Host '============================================================' -ForegroundColor Yellow
$color = if ($script:Failed -eq 0) { 'Green' } else { 'Red' }
Write-Host "  Passed: $($script:Passed)   Failed: $($script:Failed)" -ForegroundColor $color
Write-Host '============================================================' -ForegroundColor Yellow
