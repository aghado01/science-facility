#Requires -Version 7.6
Set-StrictMode -Version Latest

<#
.SYNOPSIS
    Unit tests for processors/rs-indent.ps1.

.DESCRIPTION
    Tests the processor directly (dot-invoked, not via colonel).

    Coverage:
      1.  Item unpacking — string / hashtable / pscustomobject
      2.  Skip list — .md and other prose extensions pass through with Skipped = $true
      3.  Empty text — returns empty string
      4.  No ops — text passes through unchanged
      5.  IncludeMeta = $false — bare string returned
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

.NOTES
    Run from any directory:
        & "$PSScriptRoot\rs-indent.tests.ps1"
#>

$processorPath = Join-Path $PSScriptRoot '..\rs-indent.ps1'

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

$r = Invoke-Processor -Item $text -Config @{ Operations = @('strip-common') }
Assert-True ($r -is [pscustomobject]) 'string input returns pscustomobject'
Assert-Equal $r.Processor 'rs-indent' 'Processor field'
Assert-Equal $r.Text "hello`n  world" 'string input: strip-common applied'

$r = Invoke-Processor -Item @{ Text = $text; Id = 'id1'; Path = 'file.ps1' } -Config @{ Operations = @('strip-common') }
Assert-Equal $r.Id 'id1' 'hashtable input: Id unpacked'
Assert-Equal $r.Path 'file.ps1' 'hashtable input: Path unpacked'
Assert-Equal $r.Text "hello`n  world" 'hashtable input: strip-common applied'

$pso = [pscustomobject]@{ Text = $text; Id = 'id2'; Path = 'file.ps1' }
$r = Invoke-Processor -Item $pso -Config @{ Operations = @('strip-common') }
Assert-Equal $r.Id 'id2' 'pscustomobject input: Id unpacked'

# ============================================================
# 2. Skip list
# ============================================================
Enter-Section '2. Skip list'

$mdItem = [pscustomobject]@{ Text = "  hello`n    world"; Path = 'readme.md'; Id = 'md1' }
$r = Invoke-Processor -Item $mdItem -Config @{ Operations = @('strip-common', 'min-indent-2') }
Assert-True ($r.Skipped -eq $true) '.md extension: Skipped = $true'
Assert-Equal $r.Text "  hello`n    world" '.md extension: text unchanged'
Assert-Equal $r.Processor 'rs-indent' '.md extension: Processor field present'

foreach ($ext in @('.txt', '.json', '.yaml', '.xml', '.html'))
{
    $item = [pscustomobject]@{ Text = '  x'; Path = "file$ext"; Id = 'skip' }
    $r = Invoke-Processor -Item $item -Config @{ Operations = @('strip-common') }
    Assert-True ($r.Skipped -eq $true) "$ext extension skipped"
}

# ============================================================
# 3. Empty text
# ============================================================
Enter-Section '3. Empty text'

$r = Invoke-Processor -Item '' -Config @{ Operations = @('strip-common', 'detab') }
Assert-True ($r -is [pscustomobject]) 'empty string returns pscustomobject'
Assert-Equal $r.Text '' 'empty string: Text is empty'

# ============================================================
# 4. No ops — pass-through
# ============================================================
Enter-Section '4. No ops'

$input = "  hello`n    world"
$r = Invoke-Processor -Item $input -Config @{ Operations = @() }
Assert-Equal $r.Text $input 'empty ops: text unchanged'

$r = Invoke-Processor -Item $input -Config @{}
Assert-Equal $r.Text $input 'omitted ops: text unchanged'

# ============================================================
# 5. IncludeMeta = $false
# ============================================================
Enter-Section '5. IncludeMeta = $false'

$r = Invoke-Processor -Item "  hello`n    world" -Config @{ Operations = @('strip-common'); IncludeMeta = $false }
Assert-True ($r -is [string]) 'IncludeMeta=$false returns bare string'
Assert-Equal $r "hello`n  world" 'IncludeMeta=$false: strip-common applied'

# ============================================================
# 6. strip-common — removes common offset
# ============================================================
Enter-Section '6. strip-common'

# Common indent = 2
$r = Invoke-Processor -Item "  foo`n    bar`n  baz" -Config @{ Operations = @('strip-common') }
Assert-Equal $r.Text "foo`n  bar`nbaz" 'strip-common: 2-space common removed'

# Common indent = 4
$r = Invoke-Processor -Item "    foo`n        bar" -Config @{ Operations = @('strip-common') }
Assert-Equal $r.Text "foo`n    bar" 'strip-common: 4-space common removed'

# Blank lines do not affect common calc
$r = Invoke-Processor -Item "  foo`n`n  bar" -Config @{ Operations = @('strip-common') }
Assert-Equal $r.Text "foo`n`nbar" 'strip-common: blank lines ignored in common calc'

# ============================================================
# 7. strip-common — no-op when common = 0
# ============================================================
Enter-Section '7. strip-common no-op'

$input = "foo`n  bar`n    baz"
$r = Invoke-Processor -Item $input -Config @{ Operations = @('strip-common') }
Assert-Equal $r.Text $input 'strip-common: no common offset, text unchanged'

# ============================================================
# 8. detab — expands tabs
# ============================================================
Enter-Section '8. detab — tab expansion'

# Single tab → 2 spaces (TargetUnit default = 2)
$r = Invoke-Processor -Item "`tfoo`n`t`tbar" -Config @{ Operations = @('detab') }
Assert-Equal $r.Text "  foo`n    bar" 'detab: 1 tab → 2 spaces, 2 tabs → 4 spaces'

# ============================================================
# 9. detab — pure-space file: no character change
# ============================================================
Enter-Section '9. detab — pure-space no-op on characters'

$input = "  foo`n    bar"
$r = Invoke-Processor -Item $input -Config @{ Operations = @('detab') }
Assert-Equal $r.Text $input 'detab: pure-space file unchanged'

# ============================================================
# 10. detab — pure-tab file expanded
# ============================================================
Enter-Section '10. detab — pure-tab expansion'

$r = Invoke-Processor -Item "`tfoo`n`t`tbar`n`t`t`tbaz" -Config @{ Operations = @('detab') }
Assert-Equal $r.Text "  foo`n    bar`n      baz" 'detab: pure-tab 1/2/3 tabs → 2/4/6 spaces'

# ============================================================
# 11. detab — mixed tab/space lines
# ============================================================
Enter-Section '11. detab — mixed encoding'

# Tab then spaces — tabs expanded, spaces kept
$r = Invoke-Processor -Item "`t  foo" -Config @{ Operations = @('detab') }
Assert-Equal $r.Text "    foo" 'detab: tab(→2) + 2 spaces = 4 spaces leading'

# ============================================================
# 12. min-indent-2 — GCD collapse 4-space → 2-space
# ============================================================
Enter-Section '12. min-indent-2 — GCD collapse'

# 4-space indented file → collapsed to 2-space
$r = Invoke-Processor -Item "foo`n    bar`n        baz" -Config @{ Operations = @('detab', 'min-indent-2') }
Assert-Equal $r.Text "foo`n  bar`n    baz" 'min-indent-2: 4-space unit collapsed to 2'

# ============================================================
# 13. min-indent-2 — already at TargetUnit
# ============================================================
Enter-Section '13. min-indent-2 — already target unit'

$input = "foo`n  bar`n    baz"
$r = Invoke-Processor -Item $input -Config @{ Operations = @('detab', 'min-indent-2') }
Assert-Equal $r.Text $input 'min-indent-2: 2-space unit unchanged'

# ============================================================
# 14. min-indent-2 — absolute depths, no strip-common required
# ============================================================
Enter-Section '14. min-indent-2 — absolute depths'

# Common indent of 4, unit of 4: GCD([4,8,12]) = 4, scaled to 2 → [2,4,6]
$r = Invoke-Processor -Item "    foo`n        bar`n            baz" -Config @{ Operations = @('detab', 'min-indent-2') }
Assert-Equal $r.Text "  foo`n    bar`n      baz" 'min-indent-2: absolute depths scaled correctly'

# ============================================================
# 15. tabify — 2-space → tabs
# ============================================================
Enter-Section '15. tabify'

$r = Invoke-Processor -Item "foo`n  bar`n    baz" -Config @{ Operations = @('detab', 'tabify') }
Assert-Equal $r.Text "foo`n`tbar`n`t`tbaz" 'tabify: 2-space units → tabs'

# ============================================================
# 16. tabify — remainder spaces preserved
# ============================================================
Enter-Section '16. tabify — remainder'

# 3 spaces with TargetUnit=2: 1 tab + 1 remainder space
$r = Invoke-Processor -Item "   foo" -Config @{ Operations = @('detab', 'tabify') }
Assert-Equal $r.Text "`t foo" 'tabify: 3-space → 1 tab + 1 remainder space'

# ============================================================
# 17. tabify — independent of min-indent-2
# ============================================================
Enter-Section '17. tabify without min-indent-2'

# 4-space file, tabify only (no collapse) — unit stays 4, each 4 spaces → 1 tab
$r = Invoke-Processor -Item "foo`n    bar`n        baz" -Config @{ Operations = @('detab', 'tabify') }
Assert-Equal $r.Text "foo`n`t`tbar`n`t`t`t`tbaz" 'tabify: 4-space file tabified at TargetUnit=2'

# ============================================================
# 18. min-indent-2 + tabify — full chain
# ============================================================
Enter-Section '18. min-indent-2 + tabify'

$r = Invoke-Processor -Item "foo`n    bar`n        baz" -Config @{ Operations = @('detab', 'min-indent-2', 'tabify') }
Assert-Equal $r.Text "foo`n`tbar`n`t`tbaz" 'min-indent-2 + tabify: 4-space collapsed then tabified'

# ============================================================
# 19. All ops together
# ============================================================
Enter-Section '19. All ops'

# 4-space file with 4-space common offset
$r = Invoke-Processor -Item "    foo`n        bar`n            baz" -Config @{
    Operations = @('strip-common', 'detab', 'min-indent-2', 'tabify')
}
Assert-Equal $r.Text "foo`n`tbar`n`t`tbaz" 'all ops: strip-common + collapse + tabify'

# ============================================================
# 20. TargetUnit = 4
# ============================================================
Enter-Section '20. TargetUnit = 4'

# 2-space file rescaled to 4-space
$r = Invoke-Processor -Item "foo`n  bar`n    baz" -Config @{ Operations = @('detab', 'min-indent-2'); TargetUnit = 4 }
Assert-Equal $r.Text "foo`n    bar`n        baz" 'TargetUnit=4: 2-space unit rescaled to 4'

# tabify at TargetUnit=4
$r = Invoke-Processor -Item "foo`n    bar`n        baz" -Config @{ Operations = @('detab', 'tabify'); TargetUnit = 4 }
Assert-Equal $r.Text "foo`n`tbar`n`t`tbaz" 'TargetUnit=4: 4-space → tabs at unit 4'

# ============================================================
# Summary
# ============================================================
Write-Host "`n============================================================" -ForegroundColor Yellow
$total = $script:Passed + $script:Failed
Write-Host " Results: $($script:Passed)/$total passed" -ForegroundColor ($script:Failed -eq 0 ? 'Green' : 'Red')
Write-Host '============================================================' -ForegroundColor Yellow
