#Requires -Version 7.6
Set-StrictMode -Version Latest

<#
.SYNOPSIS
    Unit tests for processors/rs-indent.ps1.

.DESCRIPTION
    Tests the processor directly (dot-invoked, not via colonel).

    Bare-string arguments to Invoke-Processor are wrapped into a minimal
    Content bag (see the helper) so the suite exercises the harmonized
    descriptor path — the shape the chain carries. Invoke-ProcessorRaw covers
    the bare-string convenience path.

    Coverage:
      1.  Item unpacking — string / hashtable / pscustomobject
      2.  Skip list — .md and other prose extensions pass through with
          Skipped = $true, resolved from RelativePath (descriptor) or Path
      3.  Empty text — returns empty string
      4.  No ops — text passes through unchanged
      5.  IncludeMeta = $false — suppresses the Processing record; a bag stays
          a bag (bare-string input still returns a bare string)
      6.  strip-common — removes common leading space offset
      7.  strip-common — no-op when common indent is 0
      8.  detab — expands tab indentation to spaces
      9.  detab — pure-space file: depths accumulated, no change to characters
     10.  detab — pure-tab file: 1 tab expanded to TargetUnit spaces
     11.  detab — mixed tab/space lines: tabs expanded uniformly
     12.  min-indent-2 — GCD collapse 4-space to 2-space
     13.  min-indent-2 — already at TargetUnit: no change
     14.  min-indent-2 — operates on absolute depths (no strip-common required)
     15.  tabify — converts 2-space indentation to tabs
     16.  tabify — remainder spaces preserved when depth not divisible by TargetUnit
     17.  tabify — does not require min-indent-2
     18.  min-indent-2 + tabify — full chain
     19.  strip-common + detab + min-indent-2 + tabify — all ops together
     20.  TargetUnit = 4 — custom target unit respected
     21.  Harmonized content-mutator contract (6d) — identity survival,
          copy-on-mutate, Text-key preservation, no-content pass-through,
          two-pass Processing trail

.NOTES
    Run from any directory:
        & "$PSScriptRoot\rs-indent.tests.ps1"
#>

$processorPath = Join-Path $PSScriptRoot '..\rs-indent.ps1'

# Shared ISS helpers (Resolve-BagContent / Copy-Bag) — colonel registers these
# into worker runspaces; dot-invocation here needs them loaded explicitly.
. (Join-Path $PSScriptRoot '_helpers.ps1')

# ---------------------------------------------------------------------------
# Assertion framework
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
    Assert-True ($Actual -eq $Expected) $Label "expected $(([string]$Expected).Length -le 60 ? "'$Expected'" : "(value)"), got $(([string]$Actual).Length -le 60 ? "'$Actual'" : "(value)")"
}

function Invoke-Processor ([object]$Item, [hashtable]$Config = @{})
{
    # The suite exercises the harmonized descriptor path (6d) — the shape the
    # chain actually carries. A bare string argument is wrapped into a minimal
    # Content bag, so transform asserts read $r.Content. The bare-string
    # convenience path (string in → string out) is covered by
    # Invoke-ProcessorRaw in sections 1, 5 and 21.
    if ($Item -is [string]) { $Item = [pscustomobject]@{ Content = $Item } }
    & $processorPath $Item $Config
}

function Invoke-ProcessorRaw ([object]$Item, [hashtable]$Config = @{})
{
    & $processorPath $Item $Config
}

Write-Host '============================================================' -ForegroundColor Yellow
Write-Host ' rs-indent.tests.ps1' -ForegroundColor Yellow
Write-Host '============================================================' -ForegroundColor Yellow

# ============================================================
# 1. Item unpacking
# ============================================================
Enter-Section '1. Item unpacking'

$text = "  hello`n    world"

$r = Invoke-ProcessorRaw -Item $text -Config @{ Operations = @('strip-common') }
Assert-True ($r -is [string]) 'string input: bare string in → bare string out'
Assert-Equal $r "hello`n  world" 'string input: strip-common applied to the returned string'

$r = Invoke-Processor -Item @{ Content = $text; Id = 'id1'; Path = 'file.ps1' } -Config @{ Operations = @('strip-common') }
Assert-True ($r -is [pscustomobject]) 'hashtable input: cloned to pscustomobject'
Assert-Equal $r.Id 'id1' 'hashtable input: Id passed through'
Assert-Equal $r.Path 'file.ps1' 'hashtable input: Path passed through'
Assert-Equal $r.Content "hello`n  world" 'hashtable input: strip-common applied'
Assert-Equal $r.Processing[0].Processor 'rs-indent' 'Processing record names the processor'

$pso = [pscustomobject]@{ Content = $text; Id = 'id2'; Path = 'file.ps1' }
$r = Invoke-Processor -Item $pso -Config @{ Operations = @('strip-common') }
Assert-Equal $r.Id 'id2' 'pscustomobject input: Id passed through'

# ============================================================
# 2. Skip list
# ============================================================
Enter-Section '2. Skip list'

$mdItem = [pscustomobject]@{ Content = "  hello`n    world"; Path = 'readme.md'; Id = 'md1' }
$r = Invoke-Processor -Item $mdItem -Config @{ Operations = @('strip-common', 'min-indent-2') }
Assert-True ($r.Processing[0].Skipped -eq $true) '.md extension: Skipped = $true on the Processing record'
Assert-Equal $r.Content "  hello`n    world" '.md extension: text unchanged'
Assert-Equal $r.Processing[0].Processor 'rs-indent' '.md extension: Processing record present'

foreach ($ext in @('.txt', '.json', '.yaml', '.xml', '.html'))
{
    $item = [pscustomobject]@{ Content = '  x'; Path = "file$ext"; Id = 'skip' }
    $r = Invoke-Processor -Item $item -Config @{ Operations = @('strip-common') }
    Assert-True ($r.Processing[0].Skipped -eq $true) "$ext extension skipped"
}

# Skip-list path resolution: descriptor bags carry RelativePath, not Path — a
# Path-only lookup would silently stop protecting Markdown in code-track chains.
$mdDesc = [pscustomobject]@{ RelativePath = 'docs/readme.md'; NodePath = 'docs/'; Content = "  hello`n    world" }
$r = Invoke-Processor -Item $mdDesc -Config @{ Operations = @('strip-common', 'min-indent-2') }
Assert-True ($r.Processing[0].Skipped -eq $true) 'descriptor bag: .md skipped via RelativePath'
Assert-Equal $r.Content "  hello`n    world" 'descriptor bag: markdown content untouched'

$psDesc = [pscustomobject]@{ RelativePath = 'src/a.ps1'; NodePath = 'src/'; Content = "  hello`n    world" }
$r = Invoke-Processor -Item $psDesc -Config @{ Operations = @('strip-common') }
Assert-True ($r.Processing[0].Skipped -eq $false) 'descriptor bag: .ps1 not skipped'
Assert-Equal $r.Content "hello`n  world" 'descriptor bag: .ps1 reindented'

# ============================================================
# 3. Empty text
# ============================================================
Enter-Section '3. Empty text'

$r = Invoke-Processor -Item '' -Config @{ Operations = @('strip-common', 'detab') }
Assert-True ($r -is [pscustomobject]) 'empty content: returns bag'
Assert-Equal $r.Content '' 'empty content: Content is empty'

# ============================================================
# 4. No ops — pass-through
# ============================================================
Enter-Section '4. No ops'

$input = "  hello`n    world"
$r = Invoke-Processor -Item $input -Config @{ Operations = @() }
Assert-Equal $r.Content $input 'empty ops: text unchanged'

$r = Invoke-Processor -Item $input -Config @{}
Assert-Equal $r.Content $input 'omitted ops: text unchanged'

# ============================================================
# 5. IncludeMeta = $false
# ============================================================
Enter-Section '5. IncludeMeta = $false'

$r = Invoke-ProcessorRaw -Item "  hello`n    world" -Config @{ Operations = @('strip-common'); IncludeMeta = $false }
Assert-True ($r -is [string]) 'IncludeMeta=$false: bare string in still returns bare string'
Assert-Equal $r "hello`n  world" 'IncludeMeta=$false: strip-common applied'

# Harmonized contract (6d): IncludeMeta suppresses the Processing record — it
# never collapses a bag to a bare string (that was the tp-era envelope behavior).
$r = Invoke-Processor -Item ([pscustomobject]@{ RelativePath = 'a.ps1'; Content = "  hello`n    world" }) -Config @{ Operations = @('strip-common'); IncludeMeta = $false }
Assert-True ($r -is [pscustomobject]) 'IncludeMeta=$false: bag stays a bag'
Assert-Equal $r.RelativePath 'a.ps1' 'IncludeMeta=$false: identity survives'
Assert-Equal $r.Content "hello`n  world" 'IncludeMeta=$false: op still applied to bag'
Assert-True ($null -eq $r.PSObject.Properties['Processing']) 'IncludeMeta=$false: no Processing record'

# ============================================================
# 6. strip-common — removes common offset
# ============================================================
Enter-Section '6. strip-common'

# Common indent = 2
$r = Invoke-Processor -Item "  foo`n    bar`n  baz" -Config @{ Operations = @('strip-common') }
Assert-Equal $r.Content "foo`n  bar`nbaz" 'strip-common: 2-space common removed'

# Common indent = 4
$r = Invoke-Processor -Item "    foo`n        bar" -Config @{ Operations = @('strip-common') }
Assert-Equal $r.Content "foo`n    bar" 'strip-common: 4-space common removed'

# Blank lines do not affect common calc
$r = Invoke-Processor -Item "  foo`n`n  bar" -Config @{ Operations = @('strip-common') }
Assert-Equal $r.Content "foo`n`nbar" 'strip-common: blank lines ignored in common calc'

# ============================================================
# 7. strip-common — no-op when common = 0
# ============================================================
Enter-Section '7. strip-common no-op'

$input = "foo`n  bar`n    baz"
$r = Invoke-Processor -Item $input -Config @{ Operations = @('strip-common') }
Assert-Equal $r.Content $input 'strip-common: no common offset, text unchanged'

# ============================================================
# 8. detab — expands tabs
# ============================================================
Enter-Section '8. detab — tab expansion'

# Single tab → 2 spaces (TargetUnit default = 2)
$r = Invoke-Processor -Item "`tfoo`n`t`tbar" -Config @{ Operations = @('detab') }
Assert-Equal $r.Content "  foo`n    bar" 'detab: 1 tab → 2 spaces, 2 tabs → 4 spaces'

# ============================================================
# 9. detab — pure-space file: no character change
# ============================================================
Enter-Section '9. detab — pure-space no-op on characters'

$input = "  foo`n    bar"
$r = Invoke-Processor -Item $input -Config @{ Operations = @('detab') }
Assert-Equal $r.Content $input 'detab: pure-space file unchanged'

# ============================================================
# 10. detab — pure-tab file expanded
# ============================================================
Enter-Section '10. detab — pure-tab expansion'

$r = Invoke-Processor -Item "`tfoo`n`t`tbar`n`t`t`tbaz" -Config @{ Operations = @('detab') }
Assert-Equal $r.Content "  foo`n    bar`n      baz" 'detab: pure-tab 1/2/3 tabs → 2/4/6 spaces'

# ============================================================
# 11. detab — mixed tab/space lines
# ============================================================
Enter-Section '11. detab — mixed encoding'

# Tab then spaces — tabs expanded, spaces kept
$r = Invoke-Processor -Item "`t  foo" -Config @{ Operations = @('detab') }
Assert-Equal $r.Content "    foo" 'detab: tab(→2) + 2 spaces = 4 spaces leading'

# ============================================================
# 12. min-indent-2 — GCD collapse 4-space → 2-space
# ============================================================
Enter-Section '12. min-indent-2 — GCD collapse'

# 4-space indented file → collapsed to 2-space
$r = Invoke-Processor -Item "foo`n    bar`n        baz" -Config @{ Operations = @('detab', 'min-indent-2') }
Assert-Equal $r.Content "foo`n  bar`n    baz" 'min-indent-2: 4-space unit collapsed to 2'

# ============================================================
# 13. min-indent-2 — already at TargetUnit
# ============================================================
Enter-Section '13. min-indent-2 — already target unit'

$input = "foo`n  bar`n    baz"
$r = Invoke-Processor -Item $input -Config @{ Operations = @('detab', 'min-indent-2') }
Assert-Equal $r.Content $input 'min-indent-2: 2-space unit unchanged'

# ============================================================
# 14. min-indent-2 — absolute depths, no strip-common required
# ============================================================
Enter-Section '14. min-indent-2 — absolute depths'

# Common indent of 4, unit of 4: GCD([4,8,12]) = 4, scaled to 2 → [2,4,6]
$r = Invoke-Processor -Item "    foo`n        bar`n            baz" -Config @{ Operations = @('detab', 'min-indent-2') }
Assert-Equal $r.Content "  foo`n    bar`n      baz" 'min-indent-2: absolute depths scaled correctly'

# ============================================================
# 15. tabify — 2-space → tabs
# ============================================================
Enter-Section '15. tabify'

$r = Invoke-Processor -Item "foo`n  bar`n    baz" -Config @{ Operations = @('detab', 'tabify') }
Assert-Equal $r.Content "foo`n`tbar`n`t`tbaz" 'tabify: 2-space units → tabs'

# ============================================================
# 16. tabify — remainder spaces preserved
# ============================================================
Enter-Section '16. tabify — remainder'

# 3 spaces with TargetUnit=2: 1 tab + 1 remainder space
$r = Invoke-Processor -Item "   foo" -Config @{ Operations = @('detab', 'tabify') }
Assert-Equal $r.Content "`t foo" 'tabify: 3-space → 1 tab + 1 remainder space'

# ============================================================
# 17. tabify — independent of min-indent-2
# ============================================================
Enter-Section '17. tabify without min-indent-2'

# 4-space file, tabify only (no collapse) — unit stays 4, each 4 spaces → 1 tab
$r = Invoke-Processor -Item "foo`n    bar`n        baz" -Config @{ Operations = @('detab', 'tabify') }
Assert-Equal $r.Content "foo`n`t`tbar`n`t`t`t`tbaz" 'tabify: 4-space file tabified at TargetUnit=2'

# ============================================================
# 18. min-indent-2 + tabify — full chain
# ============================================================
Enter-Section '18. min-indent-2 + tabify'

$r = Invoke-Processor -Item "foo`n    bar`n        baz" -Config @{ Operations = @('detab', 'min-indent-2', 'tabify') }
Assert-Equal $r.Content "foo`n`tbar`n`t`tbaz" 'min-indent-2 + tabify: 4-space collapsed then tabified'

# ============================================================
# 19. All ops together
# ============================================================
Enter-Section '19. All ops'

# 4-space file with 4-space common offset
$r = Invoke-Processor -Item "    foo`n        bar`n            baz" -Config @{
    Operations = @('strip-common', 'detab', 'min-indent-2', 'tabify')
}
Assert-Equal $r.Content "foo`n`tbar`n`t`tbaz" 'all ops: strip-common + collapse + tabify'

# ============================================================
# 20. TargetUnit = 4
# ============================================================
Enter-Section '20. TargetUnit = 4'

# 2-space file rescaled to 4-space
$r = Invoke-Processor -Item "foo`n  bar`n    baz" -Config @{ Operations = @('detab', 'min-indent-2'); TargetUnit = 4 }
Assert-Equal $r.Content "foo`n    bar`n        baz" 'TargetUnit=4: 2-space unit rescaled to 4'

# tabify at TargetUnit=4
$r = Invoke-Processor -Item "foo`n    bar`n        baz" -Config @{ Operations = @('detab', 'tabify'); TargetUnit = 4 }
Assert-Equal $r.Content "foo`n`tbar`n`t`tbaz" 'TargetUnit=4: 4-space → tabs at unit 4'

# ============================================================
# 21. Harmonized content-mutator contract (consolidation 6d)
# ============================================================
Enter-Section '21. Harmonized content-mutator contract (6d)'

$descriptor = [pscustomobject]@{
    AbsolutePath = 'D:\repo\src\a.ps1'
    RelativePath = 'src/a.ps1'
    NodePath     = 'src/'
    SizeBytes    = 20
    LastWriteUtc = [datetime]'2026-07-29T12:00:00Z'
    Content      = "  hello`n    world"
    Encoding     = 'UTF-8'
}
$rDesc = Invoke-Processor -Item $descriptor -Config @{ Operations = @('strip-common') }

Assert-Equal $rDesc.AbsolutePath 'D:\repo\src\a.ps1' 'descriptor: AbsolutePath survives'
Assert-Equal $rDesc.RelativePath 'src/a.ps1' 'descriptor: RelativePath survives'
Assert-Equal $rDesc.NodePath 'src/' 'descriptor: NodePath survives'
Assert-Equal $rDesc.SizeBytes 20 'descriptor: SizeBytes survives'
Assert-Equal $rDesc.LastWriteUtc ([datetime]'2026-07-29T12:00:00Z') 'descriptor: LastWriteUtc survives'
Assert-Equal $rDesc.Encoding 'UTF-8' 'descriptor: Encoding survives'
Assert-Equal $rDesc.Content "hello`n  world" 'descriptor: Content mutated'
Assert-True ($null -eq $rDesc.PSObject.Properties['Text']) 'descriptor: no Text key invented'
Assert-Equal $descriptor.Content "  hello`n    world" 'copy-on-mutate: input bag not mutated'

# tp-era Text key: read and written back under its own name (track-agnostic).
$tpBag = [pscustomobject]@{ Id = 'p1'; Path = 'file.ps1'; Text = "  hello`n    world" }
$rTp = Invoke-Processor -Item $tpBag -Config @{ Operations = @('strip-common') }
Assert-Equal $rTp.Text "hello`n  world" 'Text-keyed bag: Text mutated in place'
Assert-True ($null -eq $rTp.PSObject.Properties['Content']) 'Text-keyed bag: no Content key invented'
Assert-Equal $rTp.Id 'p1' 'Text-keyed bag: Id passed through'

# No-content bag → returned untouched (mirrors rs-content_meta's no-Content rule).
$halted = [pscustomobject]@{ RelativePath = 'bin/x.dll'; SizeBytes = 9; ReadError = 'BinaryOrNulContent' }
$rHalt = Invoke-Processor -Item $halted -Config @{ Operations = @('strip-common') }
Assert-True ($null -eq $rHalt.PSObject.Properties['Content']) 'no-content bag: no phantom Content fabricated'
Assert-True ($null -eq $rHalt.PSObject.Properties['Processing']) 'no-content bag: no Processing record attached'
Assert-Equal $rHalt.ReadError 'BinaryOrNulContent' 'no-content bag: returned intact'

# The documented two-pass stack: detab, then strip-common + min-indent-2.
# Both passes record separately — the concrete reason the trail is a list.
$stack = [pscustomobject]@{ RelativePath = 'src/a.ps1'; Content = "foo`n`tbar`n`t`tbaz" }
$p1 = Invoke-Processor -Item $stack -Config @{ Operations = @('detab') }
$p2 = Invoke-Processor -Item $p1 -Config @{ Operations = @('strip-common', 'min-indent-2') }
Assert-Equal $p2.Processing.Count 2 'two-pass stack: both rs-indent passes recorded'
Assert-Equal $p2.Processing[0].Operations[0] 'detab' 'two-pass stack: first record keeps its own ops'
Assert-Equal @($p2.Processing[1].Operations).Count 2 'two-pass stack: second record keeps its own ops'
Assert-Equal $p2.RelativePath 'src/a.ps1' 'two-pass stack: identity survives both passes'

# ============================================================
# Summary
# ============================================================
Write-Host "`n============================================================" -ForegroundColor Yellow
$total = $script:Passed + $script:Failed
Write-Host " Results: $($script:Passed)/$total passed" -ForegroundColor ($script:Failed -eq 0 ? 'Green' : 'Red')
Write-Host '============================================================' -ForegroundColor Yellow
