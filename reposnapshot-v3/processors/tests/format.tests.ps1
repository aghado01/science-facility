#Requires -Version 7.6
Set-StrictMode -Version Latest

<#
.SYNOPSIS
    Unit tests for processors/format.ps1.

.DESCRIPTION
    Tests the processor directly (dot-invoked, not via colonel).

    Coverage:
      1. Item unpacking — string / hashtable / pscustomobject
      2. Default ops applied when Operations omitted
      3. lf  — CRLF and CR normalized to LF
      4. no-bom — UTF-8 BOM stripped
      5. strip-zwsp — zero-width space characters removed
      6. trim-trailing — per-line trailing whitespace removed
      7. trim-inner — multi-space runs between words collapsed
      8. max-blank-2 — 3+ blank lines collapsed to 2
      9. max-blank-1 — 2+ blank lines collapsed to 1
     10. trim-doc — leading/trailing blank lines stripped from document
     11. eof-eot — U+0004 sentinel appended
     12. IncludeMeta = $false — bare string returned
     13. Empty Operations — no-op (text passes through unchanged)
     14. Empty text — returns empty string

.NOTES
    Run from any directory:
        & "$PSScriptRoot\format.tests.ps1"
#>

$processorPath = Join-Path $PSScriptRoot '..\format.ps1'

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
    Assert-True ($Actual -eq $Expected) $Label "expected $(([string]$Expected).Length -le 40 ? "'$Expected'" : "(value)"), got $(([string]$Actual).Length -le 40 ? "'$Actual'" : "(value)")"
}

function Invoke-Processor ([object]$Item, [hashtable]$Config = @{})
{
    & $processorPath $Item $Config
}

Write-Host '============================================================' -ForegroundColor Yellow
Write-Host ' tp-generic.tests.ps1' -ForegroundColor Yellow
Write-Host '============================================================' -ForegroundColor Yellow

# ============================================================
# 1. Item unpacking
# ============================================================
Enter-Section '1. Item unpacking'

$text = "hello`r`nworld`r`n"

$rStr = Invoke-Processor -Item $text -Config @{ Operations = @('lf') }
$rHash = Invoke-Processor -Item @{ Text = $text; Id = 'h1'; Path = 'x.txt' } -Config @{ Operations = @('lf') }
$rPsco = Invoke-Processor -Item ([pscustomobject]@{ Text = $text; Id = 'p1'; Path = 'y.txt' }) -Config @{ Operations = @('lf') }

Assert-True ($rStr -is [pscustomobject]) 'String item: returns pscustomobject'
Assert-True ($rHash -is [pscustomobject]) 'Hashtable item: returns pscustomobject'
Assert-True ($rPsco -is [pscustomobject]) 'PSCustomObject item: returns pscustomobject'
Assert-Equal $rPsco.Id 'p1' 'PSCustomObject item: Id propagated'
Assert-Equal $rPsco.Path 'y.txt' 'PSCustomObject item: Path propagated'
Assert-Equal $rPsco.Processor 'format' 'Processor field set'

# ============================================================
# 2. Default ops applied when Operations omitted
# ============================================================
Enter-Section '2. Default ops (no Operations key in Config)'

$rDefault = Invoke-Processor -Item "hello   world`r`n`r`n`r`n`r`nend"
Assert-True ($rDefault -is [pscustomobject]) 'No Operations: returns object'
Assert-True ($rDefault.Text -notmatch "`r") 'No Operations: lf applied (CRLF gone)'
Assert-True ($rDefault.Text -notmatch '   ') 'No Operations: trim-inner applied'
Assert-True ($rDefault.Text -notmatch "`n`n`n`n") 'No Operations: max-blank-2 applied'
Assert-True ($rDefault.Operations.Count -gt 0) 'No Operations: Operations field populated from defaults'

# ============================================================
# 3. lf
# ============================================================
Enter-Section '3. lf — line ending normalization'

$crlfText = "line1`r`nline2`r`nline3"
$crText = "line1`rline2`rline3"

$rLf1 = Invoke-Processor -Item $crlfText -Config @{ Operations = @('lf') }
$rLf2 = Invoke-Processor -Item $crText -Config @{ Operations = @('lf') }

Assert-True ($rLf1.Text -eq "line1`nline2`nline3") 'lf: CRLF → LF'
Assert-True ($rLf2.Text -eq "line1`nline2`nline3") 'lf: CR → LF'

# ============================================================
# 4. no-bom
# ============================================================
Enter-Section '4. no-bom — BOM strip'

$bomText = [char]0xFEFF + "hello"

$rBom = Invoke-Processor -Item $bomText -Config @{ Operations = @('no-bom') }
Assert-True ($rBom.Text -eq 'hello') 'no-bom: BOM removed'
Assert-True ($rBom.Text[0] -ne [char]0xFEFF) 'no-bom: first char is not BOM'

# ============================================================
# 5. strip-zwsp
# ============================================================
Enter-Section '5. strip-zwsp — zero-width space removal'

$zwspText = "hel`u{200B}lo wor`u{200C}ld"

$rZwsp = Invoke-Processor -Item $zwspText -Config @{ Operations = @('strip-zwsp') }
Assert-True ($rZwsp.Text -eq 'hello world') 'strip-zwsp: ZWSP and ZWNJ removed'

# ============================================================
# 6. trim-trailing
# ============================================================
Enter-Section '6. trim-trailing — per-line trailing whitespace'

$trailText = "line1   `nline2  `nline3"

$rTrail = Invoke-Processor -Item $trailText -Config @{ Operations = @('trim-trailing') }
Assert-True ($rTrail.Text -eq "line1`nline2`nline3") 'trim-trailing: trailing spaces removed per line'

# ============================================================
# 7. trim-inner
# ============================================================
Enter-Section '7. trim-inner — multi-space collapse between words'

$innerText = "hello   world  foo"

$rInner = Invoke-Processor -Item $innerText -Config @{ Operations = @('trim-inner') }
Assert-True ($rInner.Text -eq 'hello world foo') 'trim-inner: multi-space runs collapsed to single space'

# Leading indentation (non-S + S sequence) must NOT be touched
$indentText = "    indented line"
$rIndent = Invoke-Processor -Item $indentText -Config @{ Operations = @('trim-inner') }
Assert-True ($rIndent.Text -eq '    indented line') 'trim-inner: leading indentation preserved'

# ============================================================
# 8. max-blank-2
# ============================================================
Enter-Section '8. max-blank-2 — 3+ blank lines → 2'

$blank3 = "a`n`n`n`nb"   # 3 blank lines between a and b

$rBlank2 = Invoke-Processor -Item $blank3 -Config @{ Operations = @('max-blank-2') }
Assert-True ($rBlank2.Text -eq "a`n`n`nb") 'max-blank-2: 3 blank lines → 2'
Assert-True ($rBlank2.Text -notmatch "`n`n`n`n") 'max-blank-2: no 4+ consecutive newlines remain'

# ============================================================
# 9. max-blank-1
# ============================================================
Enter-Section '9. max-blank-1 — 2+ blank lines → 1'

$blank2 = "a`n`n`nb"   # 2 blank lines between a and b

$rBlank1 = Invoke-Processor -Item $blank2 -Config @{ Operations = @('max-blank-1') }
Assert-True ($rBlank1.Text -eq "a`n`nb") 'max-blank-1: 2 blank lines → 1'

# ============================================================
# 10. trim-doc
# ============================================================
Enter-Section '10. trim-doc — document-level leading/trailing blank line strip'

$docText = "`n`nhello world`n`n"

$rDoc = Invoke-Processor -Item $docText -Config @{ Operations = @('trim-doc') }
Assert-True ($rDoc.Text -eq 'hello world') 'trim-doc: leading and trailing blank lines stripped'

# ============================================================
# 11. eof-eot
# ============================================================
Enter-Section '11. eof-eot — U+0004 sentinel'

$eotText = "hello world"

$rEot = Invoke-Processor -Item $eotText -Config @{ Operations = @('eof-eot') }
Assert-True ($rEot.Text.EndsWith("`n`u{0004}")) 'eof-eot: sentinel appended after trailing newline'

# ============================================================
# 12. IncludeMeta = $false
# ============================================================
Enter-Section '12. IncludeMeta = $false'

$rBare = Invoke-Processor -Item "hello   world" -Config @{ Operations = @('trim-inner'); IncludeMeta = $false }
Assert-True ($rBare -is [string]) 'IncludeMeta=false: bare string returned'
Assert-True ($rBare -eq 'hello world') 'IncludeMeta=false: op still applied'

# ============================================================
# 13. Empty Operations — no-op
# ============================================================
Enter-Section '13. Empty Operations — pass-through'

$noopText = "hello   world`r`n"

$rNoop = Invoke-Processor -Item $noopText -Config @{ Operations = @() }
Assert-True ($rNoop.Text -eq $noopText) 'Empty ops: text passes through unchanged'

# ============================================================
# 14. Empty text
# ============================================================
Enter-Section '14. Empty text'

$rEmpty = Invoke-Processor -Item '' -Config @{ Operations = @('lf', 'trim-trailing') }
Assert-True ($rEmpty -is [pscustomobject]) 'Empty text: returns object'
Assert-Equal $rEmpty.Text '' 'Empty text: Text is empty string'

# ============================================================
# Summary
# ============================================================
Write-Host ''
Write-Host '============================================================' -ForegroundColor Yellow
$color = if ($script:Failed -eq 0) { 'Green' } else { 'Red' }
Write-Host "  Passed: $($script:Passed)   Failed: $($script:Failed)" -ForegroundColor $color
Write-Host '============================================================' -ForegroundColor Yellow
