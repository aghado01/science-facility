#Requires -Version 7.6
Set-StrictMode -Version Latest

<#
.SYNOPSIS
    Unit tests for processors/format-ws.ps1.
    (PowerShellCore-era name: format.ps1 / tp-generic — renamed in the v3
    copy-over; the processor still self-identifies as Processor = 'format'.)

.DESCRIPTION
    Tests the processor directly (dot-invoked, not via colonel).

    Bare-string arguments to Invoke-Processor are wrapped into a minimal
    Content bag (see the helper) so the suite exercises the harmonized
    descriptor path — the shape the chain carries. Invoke-ProcessorRaw covers
    the bare-string convenience path.

    Coverage:
      1. Item unpacking — string / hashtable / pscustomobject
      2. Default ops applied when Operations omitted
      3. lf  — every line terminator normalized to LF (CRLF, CR, VT, FF,
         NEL, LS, PS), so downstream can treat LF as the only break
      4. strip-zwnbsp — U+FEFF removed anywhere, BOM included
      5. strip-zwsp / strip-wj — inert invisibles removed, and ZWJ/ZWNJ
         PRESERVED: they carry meaning, so no op strips them at all
      6. trim-trailing — per-line trailing whitespace removed
      7. trim-inner — multi-space runs between words collapsed
      8. max-blank-1 — 2+ blank lines collapsed to 1
      9. trim-doc — leading/trailing blank lines stripped from document
     10. ensure-final-lf — final LF appended when absent; runs last, and
         paired with trim-doc makes the document ending deterministic
     11. IncludeMeta = $false — suppresses the Processing record; a bag stays
         a bag (bare-string input still returns a bare string)
     12. Empty Operations — no-op (text passes through unchanged)
     13. Empty text — returns empty string
     15. nfc receipt honesty — Operations lists what RAN, not what was asked
         for; a declining nfc leaves the list and states why under Skipped
     14. Harmonized content-mutator contract (6d) — identity survival,
         copy-on-mutate, no-content pass-through, Processing trail order

.NOTES
    Run from any directory:
        & "$PSScriptRoot\format.tests.ps1"
#>

$processorPath = Join-Path $PSScriptRoot '..\format-ws.ps1'

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
    Assert-True ($Actual -eq $Expected) $Label "expected $(([string]$Expected).Length -le 40 ? "'$Expected'" : "(value)"), got $(([string]$Actual).Length -le 40 ? "'$Actual'" : "(value)")"
}

function Invoke-Processor ([object]$Item, [hashtable]$Config = @{})
{
    # The suite exercises the harmonized descriptor path (6d) — the shape the
    # chain actually carries. A bare string argument is wrapped into a minimal
    # Content bag, so transform asserts read $r.Content. The bare-string
    # convenience path (string in → string out) is covered by
    # Invoke-ProcessorRaw in sections 1, 12 and 15.
    if ($Item -is [string]) { $Item = [pscustomobject]@{ Content = $Item } }
    & $processorPath $Item $Config
}

function Invoke-ProcessorRaw ([object]$Item, [hashtable]$Config = @{})
{
    & $processorPath $Item $Config
}

Write-Host '============================================================' -ForegroundColor Yellow
Write-Host ' format.tests.ps1 (format-ws)' -ForegroundColor Yellow
Write-Host '============================================================' -ForegroundColor Yellow

# ============================================================
# 1. Item unpacking
# ============================================================
Enter-Section '1. Item unpacking'

$text = "hello`r`nworld`r`n"

$rStr = Invoke-ProcessorRaw -Item $text -Config @{ Operations = @('lf') }
$rHash = Invoke-Processor -Item @{ Text = $text; Id = 'h1'; Path = 'x.txt' } -Config @{ Operations = @('lf') }
$rPsco = Invoke-Processor -Item ([pscustomobject]@{ Text = $text; Id = 'p1'; Path = 'y.txt' }) -Config @{ Operations = @('lf') }

Assert-True ($rStr -is [string]) 'String item: bare string in → bare string out'
Assert-Equal $rStr "hello`nworld`n" 'String item: op applied to the returned string'
Assert-True ($rHash -is [pscustomobject]) 'Hashtable item: returns pscustomobject'
Assert-True ($rPsco -is [pscustomobject]) 'PSCustomObject item: returns pscustomobject'
Assert-Equal $rPsco.Id 'p1' 'PSCustomObject item: Id propagated'
Assert-Equal $rPsco.Path 'y.txt' 'PSCustomObject item: Path propagated'
Assert-Equal $rPsco.Text "hello`nworld`n" 'Text-keyed bag: Text mutated in place (key preserved)'
Assert-True ($null -eq $rPsco.PSObject.Properties['Content']) 'Text-keyed bag: no Content key invented'
Assert-Equal $rPsco.Processing[0].Processor 'format' 'Processing record names the processor'

# ============================================================
# 2. Default ops applied when Operations omitted
# ============================================================
Enter-Section '2. Default ops (no Operations key in Config)'

$rDefault = Invoke-Processor -Item "hello   world`r`n`r`n`r`n`r`nend"
Assert-True ($rDefault -is [pscustomobject]) 'No Operations: returns object'
Assert-True ($rDefault.Content -notmatch "`r") 'No Operations: lf applied (CRLF gone)'
Assert-True ($rDefault.Content -match 'hello   world') 'No Operations: trim-inner NOT applied (opt-in — it rewrites data inside literals)'
Assert-True ($rDefault.Content -notmatch "`n`n`n") 'No Operations: max-blank-1 applied (at most one blank line survives)'
Assert-True ($rDefault.Processing[0].Operations.Count -gt 0) 'No Operations: Processing record carries the resolved defaults'

# ============================================================
# 3. lf
# ============================================================
Enter-Section '3. lf — line ending normalization'

$crlfText = "line1`r`nline2`r`nline3"
$crText = "line1`rline2`rline3"

$rLf1 = Invoke-Processor -Item $crlfText -Config @{ Operations = @('lf') }
$rLf2 = Invoke-Processor -Item $crText -Config @{ Operations = @('lf') }

Assert-True ($rLf1.Content -eq "line1`nline2`nline3") 'lf: CRLF → LF'
Assert-True ($rLf2.Content -eq "line1`nline2`nline3") 'lf: CR → LF'

# Exotic terminators — sterilized so downstream can trust LF as the only break.
# NEL/LS/PS are the load-bearing cases: they are NOT C0, so nothing downstream
# catches them and they would reach the payload able to split a row.
foreach ($term in @(
        @{ Name = 'VT  U+000B'; Char = "`u{000B}" }
        @{ Name = 'FF  U+000C'; Char = "`u{000C}" }
        @{ Name = 'NEL U+0085'; Char = "`u{0085}" }
        @{ Name = 'LS  U+2028'; Char = "`u{2028}" }
        @{ Name = 'PS  U+2029'; Char = "`u{2029}" }
    ))
{
    $r = Invoke-Processor -Item "line1$($term.Char)line2" -Config @{ Operations = @('lf') }
    Assert-True ($r.Content -eq "line1`nline2") "lf: $($term.Name) → LF"
}

# CRLF must fold as a UNIT — a bare character class would emit two breaks.
$rPair = Invoke-Processor -Item "a`r`nb" -Config @{ Operations = @('lf') }
Assert-True ($rPair.Content -eq "a`nb") 'lf: CRLF folds to ONE break, not two'

# An unfolded terminator would also defeat blank-run detection downstream.
$rRun = Invoke-Processor -Item "a`n`u{2028}`nb" -Config @{ Operations = @('lf', 'max-blank-1') }
Assert-True ($rRun.Content -eq "a`n`nb") 'lf + max-blank-1: folded terminator participates in run collapse'

# ============================================================
# 4. strip-zwnbsp
# ============================================================
Enter-Section '4. strip-zwnbsp — U+FEFF anywhere, BOM included'

$bomText = [char]0xFEFF + "hello"

$rBom = Invoke-Processor -Item $bomText -Config @{ Operations = @('strip-zwnbsp') }
Assert-True ($rBom.Content -eq 'hello') 'strip-zwnbsp: leading BOM removed'
Assert-True ($rBom.Content[0] -ne [char]0xFEFF) 'strip-zwnbsp: first char is not BOM'

$rMid = Invoke-Processor -Item "a$([char]0xFEFF)b" -Config @{ Operations = @('strip-zwnbsp') }
Assert-True ($rMid.Content -eq 'ab') 'strip-zwnbsp: unanchored — mid-file ZWNBSP removed too'

# ============================================================
# 5. strip-zwsp / strip-wj  +  ZWJ/ZWNJ preservation
# ============================================================
Enter-Section '5. invisibles — one op per code point; ZWJ/ZWNJ preserved'

$rZwsp = Invoke-Processor -Item "hel`u{200B}lo" -Config @{ Operations = @('strip-zwsp') }
Assert-True ($rZwsp.Content -eq 'hello') 'strip-zwsp: U+200B removed'

$rWj = Invoke-Processor -Item "hel`u{2060}lo" -Config @{ Operations = @('strip-wj') }
Assert-True ($rWj.Content -eq 'hello') 'strip-wj: U+2060 removed'

# Each op is scoped to ONE code point — no cross-stripping.
$rScope = Invoke-Processor -Item "a`u{200B}b`u{2060}c" -Config @{ Operations = @('strip-zwsp') }
Assert-True ($rScope.Content -eq "ab`u{2060}c") 'strip-zwsp: leaves WJ alone (one op per code point)'

# ── The load-bearing pins: ZWJ and ZWNJ carry meaning and must survive. ──
# A ZWJ emoji sequence (man·ZWJ·woman·ZWJ·girl) and a Persian-style ZWNJ.
$zwjSeq = "$([char]::ConvertFromUtf32(0x1F468))`u{200D}$([char]::ConvertFromUtf32(0x1F469))`u{200D}$([char]::ConvertFromUtf32(0x1F467))"
$zwnjText = "mi`u{200C}khaham"

# TrimEnd the final LF: the default chain ends with ensure-final-lf, and this
# assert is about sequence integrity, not about that op.
$rDefaultsZwj = Invoke-Processor -Item $zwjSeq
Assert-True ($rDefaultsZwj.Content.TrimEnd("`n") -eq $zwjSeq) 'DEFAULT chain: ZWJ emoji sequence survives intact'

$rDefaultsZwnj = Invoke-Processor -Item $zwnjText
Assert-True ($rDefaultsZwnj.Content.TrimEnd("`n") -eq $zwnjText) 'DEFAULT chain: ZWNJ survives intact'

# Not merely absent from the defaults — no op strips them, so selecting the
# entire surface still leaves them intact.
$rAllOps = Invoke-Processor -Item "$zwjSeq|$zwnjText" -Config @{
    Operations = @('lf', 'nfc', 'strip-zwsp', 'strip-wj', 'strip-zwnbsp', 'trim-trailing',
        'trim-inner', 'max-blank-1', 'trim-doc', 'ensure-final-lf')
}
Assert-True ($rAllOps.Content -eq "$zwjSeq|$zwnjText`n") 'every op selected: ZWJ and ZWNJ still survive'

# ============================================================
# 6. trim-trailing
# ============================================================
Enter-Section '6. trim-trailing — per-line trailing whitespace'

$trailText = "line1   `nline2  `nline3"

$rTrail = Invoke-Processor -Item $trailText -Config @{ Operations = @('trim-trailing') }
Assert-True ($rTrail.Content -eq "line1`nline2`nline3") 'trim-trailing: trailing spaces removed per line'

# ============================================================
# 7. trim-inner
# ============================================================
Enter-Section '7. trim-inner — multi-space collapse between words'

$innerText = "hello   world  foo"

$rInner = Invoke-Processor -Item $innerText -Config @{ Operations = @('trim-inner') }
Assert-True ($rInner.Content -eq 'hello world foo') 'trim-inner: multi-space runs collapsed to single space'

# Leading indentation (non-S + S sequence) must NOT be touched
$indentText = "    indented line"
$rIndent = Invoke-Processor -Item $indentText -Config @{ Operations = @('trim-inner') }
Assert-True ($rIndent.Content -eq '    indented line') 'trim-inner: leading indentation preserved'

# ============================================================
# 8. max-blank-1
# ============================================================
Enter-Section '8. max-blank-1 — 2+ blank lines → 1'

$blank2 = "a`n`n`nb"   # 2 blank lines between a and b

$rBlank1 = Invoke-Processor -Item $blank2 -Config @{ Operations = @('max-blank-1') }
Assert-True ($rBlank1.Content -eq "a`n`nb") 'max-blank-1: 2 blank lines → 1'

# ============================================================
# 9. trim-doc
# ============================================================
Enter-Section '9. trim-doc — document-level leading/trailing blank line strip'

$docText = "`n`nhello world`n`n"

$rDoc = Invoke-Processor -Item $docText -Config @{ Operations = @('trim-doc') }
Assert-True ($rDoc.Content -eq 'hello world') 'trim-doc: leading and trailing blank lines stripped'

# ============================================================
# 10. ensure-final-lf
# ============================================================
Enter-Section '10. ensure-final-lf — final LF, runs last'

$rEnsure = Invoke-Processor -Item 'no trailing newline' -Config @{ Operations = @('ensure-final-lf') }
Assert-True ($rEnsure.Content -eq "no trailing newline`n") 'ensure-final-lf: LF appended when absent'

$rIdem = Invoke-Processor -Item "already there`n" -Config @{ Operations = @('ensure-final-lf') }
Assert-True ($rIdem.Content -eq "already there`n") 'ensure-final-lf: idempotent when already present'

$rRun = Invoke-Processor -Item "trailing run`n`n`n" -Config @{ Operations = @('ensure-final-lf') }
Assert-True ($rRun.Content -eq "trailing run`n`n`n") 'ensure-final-lf: additive only — existing run untouched (collapsing is max-blank-*''s job)'

$rEmpty = Invoke-Processor -Item '' -Config @{ Operations = @('ensure-final-lf') }
Assert-True ($rEmpty.Content -eq '') 'ensure-final-lf: empty content does not acquire a line'

# The pairing that makes the document ending deterministic: trim-doc strips the
# trailing run, ensure-final-lf puts exactly one back — in that fixed order.
$rPair = Invoke-Processor -Item "body text`n`n`n`n" -Config @{ Operations = @('trim-doc', 'ensure-final-lf') }
Assert-True ($rPair.Content -eq "body text`n") 'trim-doc + ensure-final-lf: exactly one final LF regardless of input run'

$rPairOrder = Invoke-Processor -Item "body text`n`n`n`n" -Config @{ Operations = @('ensure-final-lf', 'trim-doc') }
Assert-True ($rPairOrder.Content -eq "body text`n") 'implementation owns sequence: caller order does not change the result'

# ============================================================
# 11. IncludeMeta = $false
# ============================================================
Enter-Section '11. IncludeMeta = $false'

$rBare = Invoke-ProcessorRaw -Item "hello   world" -Config @{ Operations = @('trim-inner'); IncludeMeta = $false }
Assert-True ($rBare -is [string]) 'IncludeMeta=false: bare string in still returns bare string'
Assert-True ($rBare -eq 'hello world') 'IncludeMeta=false: op still applied'

# Harmonized contract (6d): IncludeMeta suppresses the Processing record — it
# never collapses a bag to a bare string (that was the tp-era envelope behavior).
$rBagNoMeta = Invoke-Processor -Item ([pscustomobject]@{ RelativePath = 'a.txt'; Content = "hello   world" }) -Config @{ Operations = @('trim-inner'); IncludeMeta = $false }
Assert-True ($rBagNoMeta -is [pscustomobject]) 'IncludeMeta=false: bag stays a bag'
Assert-Equal $rBagNoMeta.RelativePath 'a.txt' 'IncludeMeta=false: identity survives'
Assert-Equal $rBagNoMeta.Content 'hello world' 'IncludeMeta=false: op still applied to bag'
Assert-True ($null -eq $rBagNoMeta.PSObject.Properties['Processing']) 'IncludeMeta=false: no Processing record'

# ============================================================
# 12. Empty Operations — no-op
# ============================================================
Enter-Section '12. Empty Operations — pass-through'

$noopText = "hello   world`r`n"

$rNoop = Invoke-Processor -Item $noopText -Config @{ Operations = @() }
Assert-True ($rNoop.Content -eq $noopText) 'Empty ops: text passes through unchanged'

# ============================================================
# 13. Empty text
# ============================================================
Enter-Section '13. Empty text'

$rEmpty = Invoke-Processor -Item '' -Config @{ Operations = @('lf', 'trim-trailing') }
Assert-True ($rEmpty -is [pscustomobject]) 'Empty text: returns object'
Assert-Equal $rEmpty.Content '' 'Empty text: Content is empty string'

# ============================================================
# 14. Harmonized content-mutator contract (consolidation 6d)
# ============================================================
Enter-Section '14. Harmonized content-mutator contract (6d)'

$descriptor = [pscustomobject]@{
    AbsolutePath = 'D:\repo\src\a.txt'
    RelativePath = 'src/a.txt'
    NodePath     = 'src/'
    SizeBytes    = 41
    LastWriteUtc = [datetime]'2026-07-29T12:00:00Z'
    Content      = "hello   world`r`n`r`n`r`n`r`nend"
    Encoding     = 'UTF-8'
}
$rDesc = Invoke-Processor -Item $descriptor

# Identity survival — the whole point of 6d: the tp-era envelope dropped these.
Assert-Equal $rDesc.AbsolutePath 'D:\repo\src\a.txt' 'descriptor: AbsolutePath survives'
Assert-Equal $rDesc.RelativePath 'src/a.txt' 'descriptor: RelativePath survives'
Assert-Equal $rDesc.NodePath 'src/' 'descriptor: NodePath survives'
Assert-Equal $rDesc.SizeBytes 41 'descriptor: SizeBytes survives'
Assert-Equal $rDesc.LastWriteUtc ([datetime]'2026-07-29T12:00:00Z') 'descriptor: LastWriteUtc survives'
Assert-Equal $rDesc.Encoding 'UTF-8' 'descriptor: Encoding (chain enrichment) survives'
Assert-True ($rDesc.Content -notmatch "`r") 'descriptor: Content mutated (lf applied)'
Assert-True ($null -eq $rDesc.PSObject.Properties['Text']) 'descriptor: no Text key invented'

# Copy-on-mutate: the caller's reference is never touched.
Assert-True ($descriptor.Content -match "`r") 'copy-on-mutate: input bag not mutated'

# No-content bag → returned untouched. A mutator must not fabricate an empty
# payload: assemble splits EmptyFile from EmptiedByProcessing and routes empty
# content to Diagnostics, so a phantom '' would forge an entry.
$halted = [pscustomobject]@{ RelativePath = 'bin/x.dll'; SizeBytes = 9; ReadError = 'BinaryOrNulContent' }
$rHalt = Invoke-Processor -Item $halted
Assert-True ($null -eq $rHalt.PSObject.Properties['Content']) 'no-content bag: no phantom Content fabricated'
Assert-True ($null -eq $rHalt.PSObject.Properties['Processing']) 'no-content bag: no Processing record attached'
Assert-Equal $rHalt.ReadError 'BinaryOrNulContent' 'no-content bag: returned intact'

# Processing trail accumulates in chain order across mutator invocations.
$pass1 = Invoke-Processor -Item $descriptor -Config @{ Operations = @('lf') }
$pass2 = Invoke-Processor -Item $pass1 -Config @{ Operations = @('trim-inner') }
Assert-Equal $pass2.Processing.Count 2 'Processing: two passes recorded (no overwrite)'
Assert-Equal $pass2.Processing[0].Operations[0] 'lf' 'Processing: first record keeps its own ops'
Assert-Equal $pass2.Processing[1].Operations[0] 'trim-inner' 'Processing: second record appended in chain order'
Assert-Equal $pass2.RelativePath 'src/a.txt' 'Processing: identity survives a two-step chain'

# ============================================================
# 15. nfc receipt honesty
# ============================================================
Enter-Section '15. nfc receipt honesty — Operations reports what RAN'

# Decomposed e + combining acute; NFC composes it to a single U+00E9.
$decomposed = "cafe`u{0301}"
$rNfcOk = Invoke-Processor -Item $decomposed -Config @{ Operations = @('nfc') }
Assert-True ($rNfcOk.Content -eq "caf`u{00E9}") 'nfc: decomposed sequence composed'
Assert-True ($rNfcOk.Processing[0].Operations -contains 'nfc') 'nfc succeeded: listed in Operations'
Assert-True ($null -eq $rNfcOk.Processing[0].PSObject.Properties['Skipped']) 'nfc succeeded: no Skipped field — its absence means everything listed ran'

# A lone high surrogate is ill-formed UTF-16; String.Normalize refuses it.
$illFormed = "a$([char]0xD800)b"
$rNfcBad = Invoke-Processor -Item $illFormed -Config @{ Operations = @('nfc') }

Assert-True ($rNfcBad.Content -eq $illFormed) 'nfc declined: content passes through untouched (never-fail ingest)'
Assert-True ($rNfcBad.Processing[0].Operations -notcontains 'nfc') 'nfc declined: NOT listed in Operations — the receipt does not claim a fold that did not happen'
Assert-True ($null -ne $rNfcBad.Processing[0].PSObject.Properties['Skipped']) 'nfc declined: Skipped field present'
Assert-Equal $rNfcBad.Processing[0].Skipped[0].Op 'nfc' 'nfc declined: Skipped names the op'
Assert-Equal $rNfcBad.Processing[0].Skipped[0].Reason 'InvalidUnicode' 'nfc declined: Skipped states the reason'

# The other ops still run and are still reported — one op declining does not
# silence the receipt for the rest.
$rMixed = Invoke-Processor -Item "a$([char]0xD800)b   c`r`n" -Config @{ Operations = @('lf', 'nfc', 'trim-inner') }
Assert-True ($rMixed.Processing[0].Operations -contains 'lf') 'mixed: lf still reported'
Assert-True ($rMixed.Processing[0].Operations -contains 'trim-inner') 'mixed: trim-inner still reported'
Assert-True ($rMixed.Processing[0].Operations -notcontains 'nfc') 'mixed: only the declining op leaves the list'
Assert-True ($rMixed.Content -eq "a$([char]0xD800)b c`n") 'mixed: surviving ops actually applied'

# Operations must stay an ARRAY at every count. A single-element result reached
# through an if-expression collapses to a scalar string, making Operations[0]
# the first CHARACTER — the unroll trap assemble already hit once.
$rOne = Invoke-Processor -Item 'x' -Config @{ Operations = @('lf') }
Assert-True ($rOne.Processing[0].Operations -is [array]) 'single op: Operations is an array, not a collapsed scalar'
Assert-Equal $rOne.Processing[0].Operations[0] 'lf' 'single op: Operations[0] is the op, not its first character'

$rOneSkip = Invoke-Processor -Item $illFormed -Config @{ Operations = @('nfc', 'lf') }
Assert-True ($rOneSkip.Processing[0].Operations -is [array]) 'single op after nfc declines: still an array'
Assert-Equal $rOneSkip.Processing[0].Operations[0] 'lf' 'single op after nfc declines: survivor intact'

# ── Unknown op names: the same lie in a different costume. A typo matches no
# block, so it silently transforms nothing — echoing it would claim otherwise.
$rTypo = Invoke-Processor -Item "a   b`r`n" -Config @{ Operations = @('lf', 'trim-trailng') }
Assert-True ($rTypo.Processing[0].Operations -contains 'lf') 'typo: the real op still ran and is reported'
Assert-True ($rTypo.Processing[0].Operations -notcontains 'trim-trailng') 'typo: unknown name NOT reported as applied'
Assert-Equal $rTypo.Processing[0].Skipped[0].Op 'trim-trailng' 'typo: Skipped names the unrecognized op'
Assert-Equal $rTypo.Processing[0].Skipped[0].Reason 'UnknownOp' 'typo: Skipped distinguishes UnknownOp from a decline'
Assert-True ($rTypo.Content -eq "a   b`n") 'typo: ingest is not failed by a config mistake'

# Both skip reasons can coexist, and stay distinguishable.
$rBoth = Invoke-Processor -Item $illFormed -Config @{ Operations = @('nfc', 'bogus-op') }
$reasons = @($rBoth.Processing[0].Skipped | ForEach-Object { "$($_.Op)=$($_.Reason)" })
Assert-True ($reasons -contains 'nfc=InvalidUnicode') 'both: nfc decline keeps its own reason'
Assert-True ($reasons -contains 'bogus-op=UnknownOp') 'both: unknown name keeps its own reason'
Assert-True ($rBoth.Processing[0].Operations.Count -eq 0) 'both: nothing ran, so Operations is empty rather than echoing the request'

# A duplicate name must not produce duplicate skip records.
$rDup = Invoke-Processor -Item 'x' -Config @{ Operations = @('nope', 'nope') }
Assert-True (@($rDup.Processing[0].Skipped).Count -eq 1) 'duplicate unknown name: recorded once, not per occurrence'

# ============================================================
# Summary
# ============================================================
Write-Host ''
Write-Host '============================================================' -ForegroundColor Yellow
$color = if ($script:Failed -eq 0) { 'Green' } else { 'Red' }
Write-Host "  Passed: $($script:Passed)   Failed: $($script:Failed)" -ForegroundColor $color
Write-Host '============================================================' -ForegroundColor Yellow
