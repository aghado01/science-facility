#Requires -Version 7.5
Set-StrictMode -Version Latest

<#
.SYNOPSIS
    rs.core.container — psr layout resolution, content codec, header/row
    measure + render. Exercised against contracts/container.spec.jsonc (the real
    declaration) and, for the value walk, a real rs-content_meta enrichment.

.DESCRIPTION
    The wire is the item model (ledger #49): a row is a list of items joined by
    exactly one space, marks included. Expectations here are written as literal
    strings on purpose — byte-exact planning is the property under test, so a
    computed expectation would be tautological.

    Sections:
      1. Resolve-Layout — required-only default; optional columns; widths from
         EntryCount; admissibility; MetaFields val_rank order/default; presence
         warning; the two order invariants (content last, content_bytes before
         it); the $ref crosswalk yielding accessors.
      2. Codec — ConvertTo-ContentSpan SPEC rules 1–4; Measure-ContentSpan == UTF-8 width
         of ConvertTo-ContentSpan over a battery incl. multibyte, surrogate pairs, a
         lone surrogate, every terminator kind, controls, backslashes.
      3. Header row — Build-HeaderRow bytes == HeaderBytes; LF-terminated; no
         trailing mark; UTF-8 no BOM.
      4. Rows — Measure-Row == Build-Row Bytes.Length (plan = file, by
         construction); exact text; the item byte identity; offsets (0-based,
         inclusive ends, content_bytes adjacency); gidx zero-pad and width
         overflow; double formatting; empty markers; one physical line per row.
      5. Value walk (contracts check #5) — every enabled column/sub-field
         accessor in the layout resolves on an entry enriched by the REAL
         rs-content_meta processor.

.NOTES
    Run from any directory:
        & "$PSScriptRoot\container.tests.ps1"
#>

$v3 = Join-Path $PSScriptRoot '..\reposnapshot-v3'
$procDir = Join-Path $v3 'processors'

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

Import-Module (Join-Path $v3 'rs.core.container.psm1') -Force
$utf8 = [System.Text.UTF8Encoding]::new($false)

function New-Header ([int]$EntryCount, [hashtable]$Elements = @{})
{
    $el = [ordered]@{}
    foreach ($k in $Elements.Keys) { $el[$k] = [pscustomobject]@{ Count = $Elements[$k][0]; Total = $Elements[$k][1] } }
    [pscustomobject]@{ EntryCount = $EntryCount; Elements = [pscustomobject]$el }
}

try
{
    # -----------------------------------------------------------------------
    Enter-Section '1. Resolve-Layout'
    # -----------------------------------------------------------------------
    $h = New-Header 1234 @{ ContentMeta = @(1234, 1234) }

    $L0 = Resolve-Layout -Header $h
    Assert-True (@($L0.Columns | ForEach-Object Name) -join ',' -eq 'path,content_bytes,content') 'required-only: path, content_bytes, content' (@($L0.Columns | ForEach-Object Name) -join ',')
    Assert-True ($L0.HeaderRowText -eq 'path: string | content_bytes: int | content: string') 'required-only header text (key item, value item, marks as items)' $L0.HeaderRowText
    Assert-True ($L0.HeaderBytes -eq ($utf8.GetByteCount($L0.HeaderRowText) + 1)) 'HeaderBytes = utf8(text) + LF'
    Assert-True ($L0.IdxWidth -eq 0) 'IdxWidth 0 when gidx is off'
    Assert-True ($L0.Format -eq 'psr' -and $L0.DoublePrecision -eq 4) 'Format psr, DoublePrecision 4 (from properties.double_precision)'
    Assert-True ($L0.Framing.ColumnSeparator -eq '|' -and $L0.Framing.ItemJoin -eq ' ' -and $L0.Framing.RecordDelimiter -eq "`n" -and $L0.Framing.EmptyMarker -eq '' -and $L0.Framing.Bom -eq $false -and $L0.Framing.Encoding -eq 'utf-8') 'Framing verbatim from the declaration — separator is a CHARACTER, spacing is the join'
    Assert-True ($null -eq $L0.Framing.PSObject.Properties['FieldDelimiter'] -and $null -eq $L0.Framing.PSObject.Properties['BlockOpen']) 'no padded-delimiter or block-open constants survive (#49: marks are items)'

    $L1 = Resolve-Layout -Header $h -Columns gidx, content_meta
    Assert-True ($L1.IdxWidth -eq 4) 'IdxWidth = digits(1234) = 4' "got $($L1.IdxWidth)"
    Assert-True ($L1.HeaderRowText -eq 'gidx: int(4) | path: string | content_meta: [ line_mean: double , num_chars: int , num_words: int , ws_ratio: double , entropy: double ] | content_bytes: int | content: string') 'full header text: type expression is ONE item; block is a key whose value is bracketed' $L1.HeaderRowText
    Assert-True (@($L1.Columns)[0].Width -eq 4 -and @($L1.Columns)[0].Source -eq 'plan.GlobalIdx') 'gidx column: width 4, accessor plan.GlobalIdx derived from the shards $ref'
    $meta = @($L1.Columns | Where-Object Name -eq 'content_meta')[0]
    Assert-True (@($meta.Fields | ForEach-Object Name) -join ',' -eq 'line_mean,num_chars,num_words,ws_ratio,entropy') 'default sub-fields in val_rank order' (@($meta.Fields | ForEach-Object Name) -join ',')
    Assert-True (@($meta.Fields)[0].Source -eq 'entry.ContentMeta.LineStats.Mean') 'sub-field accessor derived from the processor $ref (nested pointer)' (@($meta.Fields)[0].Source)
    Assert-True ($meta.Enclosure.Start -eq '[' -and $meta.Enclosure.End -eq ']' -and $meta.ValSeparator -eq ',') 'block enclosure and val separator come from the column, not a global framing constant'
    $cb = @($L1.Columns | Where-Object Name -eq 'content_bytes')[0]
    Assert-True ($cb.Source -eq 'codec.bytes') 'content_bytes accessor derived from the container $ref'

    $L2 = Resolve-Layout -Header (New-Header 7) -Columns content_meta -MetaFields entropy, num_chars, line_mean -WarningAction SilentlyContinue
    $m2 = @($L2.Columns | Where-Object Name -eq 'content_meta')[0]
    Assert-True (@($m2.Fields | ForEach-Object Name) -join ',' -eq 'line_mean,num_chars,entropy') 'MetaFields rendered in val_rank order regardless of request order' (@($m2.Fields | ForEach-Object Name) -join ',')
    Assert-True ($L2.IdxWidth -eq 0 -and $L2.HeaderRowText -notlike 'gidx*') 'gidx off unless requested'

    $Lw = Resolve-Layout -Header (New-Header 0) -Columns gidx
    Assert-True ($Lw.IdxWidth -eq 1) 'EntryCount 0 → gidx width 1 (never 0)'
    Assert-True ($Lw.HeaderRowText -like 'gidx: int(1)*') 'resolved width reaches the header BEFORE interpolation (never the literal digits(EntryCount))' $Lw.HeaderRowText
    $Lw2 = Resolve-Layout -Header (New-Header 100000) -Columns gidx
    Assert-True ($Lw2.IdxWidth -eq 6 -and $Lw2.HeaderRowText -like 'gidx: int(6)*') 'EntryCount 100000 → width 6, in the layout and on the wire'

    $Lreq = Resolve-Layout -Header $h -Columns path, content
    Assert-True ($Lreq.HeaderRowText -eq $L0.HeaderRowText) 'naming a required column is a no-op'

    $threw = $null; try { Resolve-Layout -Header $h -Columns nope | Out-Null } catch { $threw = $_.Exception.Message }
    Assert-True ($null -ne $threw -and $threw -like '*not admissible*') 'inadmissible column throws' $threw
    $threw = $null; try { Resolve-Layout -Header $h -Columns content_meta -MetaFields num_chars, bogus | Out-Null } catch { $threw = $_.Exception.Message }
    Assert-True ($null -ne $threw -and $threw -like '*not admissible*') 'inadmissible content_meta sub-field throws' $threw

    # presence warning — never decides the layout
    $warn = @()
    $Lp = Resolve-Layout -Header (New-Header 5) -Columns content_meta -WarningVariable warn -WarningAction SilentlyContinue
    Assert-True ($warn.Count -eq 1 -and $warn[0] -like '*no ContentMeta*') 'content_meta on, no ContentMeta in Elements → one warning' ($warn -join ' / ')
    Assert-True ($Lp.HeaderRowText.Contains('content_meta: [')) '…and the block is still in the layout'
    $warn = @()
    Resolve-Layout -Header (New-Header 5 @{ ContentMeta = @(3, 5) }) -Columns content_meta -WarningVariable warn -WarningAction SilentlyContinue | Out-Null
    Assert-True ($warn.Count -eq 1 -and $warn[0] -like '*3 of 5*') 'partial presence → one warning naming the counts' ($warn -join ' / ')
    $warn = @()
    Resolve-Layout -Header $h -Columns content_meta -WarningVariable warn -WarningAction SilentlyContinue | Out-Null
    Assert-True ($warn.Count -eq 0) 'full presence → no warning'

    # order invariants (from the columns list, not the text)
    $names = @($L1.Columns | ForEach-Object Name)
    Assert-True ($names[-1] -eq 'content' -and $names[-2] -eq 'content_bytes') 'content last; content_bytes immediately before it'

    # -----------------------------------------------------------------------
    Enter-Section '2. Codec — ConvertTo-ContentSpan / Measure-ContentSpan'
    # -----------------------------------------------------------------------
    Assert-True ((ConvertTo-ContentSpan "a`r`nb`rc`nd") -eq 'a\nb\nc\nd') 'CRLF, CR, LF → the two-char mark, PURE substitution — no spacing logic in the encoder' (ConvertTo-ContentSpan "a`r`nb`rc`nd")
    Assert-True ((ConvertTo-ContentSpan "x`u{0085}y`u{2028}z`u{2029}w`u{000B}v`u{000C}u") -eq 'x\ny\nz\nw\nv\nu') 'NEL, LS, PS, VT, FF → the same mark'
    Assert-True ((ConvertTo-ContentSpan "a`n`nb") -eq 'a\n\nb') 'consecutive terminators → adjacent marks, verbatim (spacing is rs-whitespace pad-breaks, upstream)' (ConvertTo-ContentSpan "a`n`nb")
    Assert-True ((ConvertTo-ContentSpan "a `n b") -eq 'a \n b') 'pad-breaks-prepared content encodes to the space-flanked wire — one symbol per terminator, nothing added'
    Assert-True ((Measure-ContentSpan "a `n`n b") -eq $utf8.GetByteCount('a \n\n b')) 'measure matches render on prepared content'
    Assert-True ((ConvertTo-ContentSpan 'C:\Users\me\n') -eq 'C:\Users\me\n') 'backslash never doubled; literal \n in source passes verbatim'
    Assert-True ((ConvertTo-ContentSpan "a`tb") -eq "a`tb") 'TAB stays literal'
    Assert-True ((ConvertTo-ContentSpan "a`0b`u{0001}c`u{007F}d`u{001B}e") -eq 'abcde') 'NUL, SOH, DEL, ESC stripped'
    Assert-True ((ConvertTo-ContentSpan '') -eq '' -and (ConvertTo-ContentSpan $null) -eq '') 'empty / null → empty'
    Assert-True ((Measure-ContentSpan '') -eq 0 -and (Measure-ContentSpan $null) -eq 0) 'empty / null → 0 bytes'
    $enc = ConvertTo-ContentSpan "line1`r`nline2`n"
    Assert-True ($enc -notmatch "[`r`n]") 'encoded content contains no raw line terminators (one physical line per row)'

    $battery = @(
        'plain ascii',
        "crlf`r`nlf`ncr`rend",
        "tabs`tand`tspaces  ",
        'back\slash\n literal',
        "ctl`0`u{0001}`u{0002}`u{001F}`u{007F}x",
        "nel`u{0085}ls`u{2028}ps`u{2029}vt`u{000B}ff`u{000C}",
        'multibyte é ü ñ 日本語 – —',
        "emoji 😀🎉 pair`nnext",
        ("lone high surrogate " + [string][char]0xD83D + " x"),
        ("lone low surrogate " + [string][char]0xDE00 + "`r`n"),
        ('long ' + ('x' * 5000) + "`n" + ('y' * 5000)),
        "`r`n`r`n`n`r",
        "trailing newline`n"
    )
    $allEqual = $true; $detail = ''
    foreach ($s in $battery)
    {
        $m = Measure-ContentSpan $s
        $e = $utf8.GetByteCount((ConvertTo-ContentSpan $s))
        if ($m -ne $e) { $allEqual = $false; $detail += "[$($s.Substring(0, [Math]::Min(20, $s.Length)))… measure=$m encode=$e] " }
    }
    Assert-True $allEqual 'Measure-ContentSpan == utf8(ConvertTo-ContentSpan) across the battery (incl. surrogates, every terminator, controls)' $detail
    Assert-True ((Measure-ContentSpan "ab`ncd") -eq 6) 'LF: 1 byte → 2 (ab\ncd = 6)'
    Assert-True ((Measure-ContentSpan "ab`r`ncd") -eq 6) 'CRLF: 2 bytes → 2'
    Assert-True ((Measure-ContentSpan "ab`u{2028}cd") -eq 6) 'LS: 3 bytes → 2'
    Assert-True ((Measure-ContentSpan "ab`0cd") -eq 4) 'NUL: 1 byte → 0'
    Assert-True ((Measure-ContentSpan 'é') -eq 2 -and (Measure-ContentSpan '😀') -eq 4) 'multibyte counted in UTF-8'

    # -----------------------------------------------------------------------
    Enter-Section '3. Header row'
    # -----------------------------------------------------------------------
    $hb = Build-HeaderRow -Layout $L1
    Assert-True ($hb.Length -eq $L1.HeaderBytes -and (Measure-HeaderRow -Layout $L1) -eq $L1.HeaderBytes) 'Build-HeaderRow bytes == HeaderBytes == Measure-HeaderRow'
    Assert-True ($hb[-1] -eq 10 -and $hb[-2] -ne 13) 'LF-terminated, no CR'
    Assert-True (-not ($hb[0] -eq 0xEF -and $hb[1] -eq 0xBB)) 'no BOM'
    $ht = $utf8.GetString($hb)
    Assert-True (-not $ht.TrimEnd("`n").EndsWith('|') -and -not $ht.TrimEnd("`n").EndsWith(' ')) 'no trailing mark and no trailing join'
    Assert-True ($ht -notmatch '  ') 'no doubled space in the header (every item non-empty)'

    # -----------------------------------------------------------------------
    Enter-Section '4. Rows — Format / Measure / Build'
    # -----------------------------------------------------------------------
    $entry = [pscustomobject]@{
        RelativePath = 'src/Foo.cs'
        NodePath     = 'src/'
        LastWriteUtc = [datetime]::UtcNow
        Content      = "line one`r`nline two`n`ttabbed é"
        ContentMeta  = [pscustomobject]@{ CharCount = 30; WordCount = 5; PunctuationCount = 2; WhitespaceRatio = 0.4037; Entropy = 4.25164; LineStats = [pscustomobject]@{ Mean = 9.5; Median = 9; StdDev = 1.5; Max = 12 } }
    }
    $expectedContent = 'line one\nline two\n' + "`ttabbed é"
    $expectedBytes = $utf8.GetByteCount($expectedContent)

    $f = Format-Row -Layout $L1 -Entry $entry -GlobalIdx 42
    Assert-True ($f.Items.Count -eq 17) 'Format-Row: 17 items through content_bytes (4 values + 3 | + [ ] + 5 values + 4 ,)' "$($f.Items.Count)"
    Assert-True ($f.Items[0] -eq '0042') 'gidx zero-padded to width 4'
    Assert-True ($f.Items[1] -eq '|' -and $f.Items[3] -eq '|') 'separators are items in their own right'
    Assert-True ($f.Items[2] -eq 'src/Foo.cs') 'path verbatim'
    Assert-True ($f.Items[4] -eq '[' -and $f.Items[14] -eq ']' -and $f.Items[6] -eq ',') 'enclosure and val separator are items'
    Assert-True ($f.Items[5] -eq '9.5000' -and $f.Items[7] -eq '30') 'double F4 invariant, int plain, val_rank order'
    Assert-True ($f.Items[16] -eq "$expectedBytes" -and $f.ContentBytes -eq $expectedBytes) 'content_bytes = measured encoded width, and is the last item'

    $mr = Measure-Row -Layout $L1 -Entry $entry
    $rr = Build-Row -Layout $L1 -Entry $entry -Cursor 138 -GlobalIdx 42
    Assert-True ($mr -eq $rr.Bytes.Length) 'PLAN = FILE: Measure-Row == Build-Row Bytes.Length' "measure=$mr render=$($rr.Bytes.Length)"

    # the #49 byte identity, stated independently of the implementation
    $itemBytes = 0; foreach ($i in $f.Items) { $itemBytes += $utf8.GetByteCount($i) }
    $itemBytes += $utf8.GetByteCount('|') + $expectedBytes          # + the separator before content, + content
    $identity = $itemBytes + ($f.Items.Count + 2 - 1) + 1           # + (n−1) joins + LF
    Assert-True ($mr -eq $identity) 'row bytes == Σ item bytes + (item count − 1) + terminator' "measure=$mr identity=$identity"

    $rowText = $utf8.GetString($rr.Bytes)
    $expectedRow = "0042 | src/Foo.cs | [ 9.5000 , 30 , 5 , 0.4037 , 4.2516 ] | $expectedBytes | $expectedContent`n"
    Assert-True ($rowText -eq $expectedRow) 'row text exact' $rowText
    Assert-True (($rowText.TrimEnd("`n")) -notmatch "[`r`n]") 'one physical line per row'
    Assert-True (-not $rowText.TrimEnd("`n").EndsWith('|')) 'no trailing mark on rows'

    # offsets — 0-based, inclusive ends, content_bytes adjacency
    $prefix = "0042 | src/Foo.cs | [ 9.5000 , 30 , 5 , 0.4037 , 4.2516 ] | $expectedBytes"
    $prefixBytes = $utf8.GetByteCount($prefix)
    Assert-True ($rr.RowOffset -eq 138) 'RowOffset = cursor'
    Assert-True ($rr.RowMetaEnd -eq 138 + $prefixBytes - 1) 'RowMetaEnd = last byte of content_bytes (inclusive), not of the separator' "$($rr.RowMetaEnd)"
    Assert-True ($rr.RowContentBegin -eq 138 + $prefixBytes + 3) 'RowContentBegin = after join + | + join' "$($rr.RowContentBegin)"
    Assert-True ($rr.RowContentEnd -eq $rr.RowContentBegin + $expectedBytes - 1) 'RowContentEnd inclusive = begin + content_bytes − 1'
    Assert-True ($rr.ContentBytes -eq $expectedBytes -and ($rr.RowContentEnd - $rr.RowContentBegin + 1) -eq $rr.ContentBytes) 'ContentBytes == end − begin + 1'
    Assert-True ($rr.NextCursor -eq 138 + $rr.Bytes.Length) 'NextCursor = cursor + row bytes'
    # seek contract round-trip on the bytes themselves
    $span = [byte[]]::new($rr.ContentBytes)
    [Array]::Copy($rr.Bytes, $rr.RowContentBegin - 138, $span, 0, $rr.ContentBytes)
    Assert-True ($utf8.GetString($span) -eq $expectedContent) 'seek contract: bytes at [RowContentBegin..RowContentEnd] are exactly the encoded content'

    # absent sub-field / absent block → empty markers; row still measures == renders
    $sparse = [pscustomobject]@{ RelativePath = 'a.txt'; Content = 'x'; ContentMeta = [pscustomobject]@{ CharCount = 1 } }
    $sparseRow = $utf8.GetString((Build-Row -Layout $L1 -Entry $sparse -Cursor 0 -GlobalIdx 0).Bytes)
    Assert-True ($sparseRow.Contains('[  , 1 ,  ,  ,  ]')) 'absent sub-fields render the empty marker — a zero-length ITEM, visible as a doubled space' $sparseRow
    $bare = [pscustomobject]@{ RelativePath = 'b.txt'; Content = 'y' }
    $bareRow = $utf8.GetString((Build-Row -Layout $L1 -Entry $bare -Cursor 0 -GlobalIdx 0).Bytes)
    Assert-True ($bareRow.Contains('[  ,  ,  ,  ,  ]')) 'absent block renders all empty markers, positions kept' $bareRow
    Assert-True ((Measure-Row -Layout $L1 -Entry $bare) -eq (Build-Row -Layout $L1 -Entry $bare -Cursor 0 -GlobalIdx 0).Bytes.Length) 'sparse row: measure == render'

    # empty content → LTS convention RowContentEnd == RowContentBegin, ContentBytes 0
    $empty = [pscustomobject]@{ RelativePath = 'e.txt'; Content = '' }
    $re = Build-Row -Layout $L0 -Entry $empty -Cursor 10
    Assert-True ($re.ContentBytes -eq 0 -and $re.RowContentEnd -eq $re.RowContentBegin) 'empty content: ContentBytes 0, RowContentEnd == RowContentBegin (LTS convention)'
    Assert-True ((Measure-Row -Layout $L0 -Entry $empty) -eq $re.Bytes.Length) 'empty content: measure == render'

    # gidx: required when enabled; width overflow is a plan-time error
    $threw = $null; try { Build-Row -Layout $L1 -Entry $entry -Cursor 0 | Out-Null } catch { $threw = $_.Exception.Message }
    Assert-True ($null -ne $threw -and $threw -like '*GlobalIdx is required*') 'Build-Row without GlobalIdx under gidx throws' $threw
    $threw = $null; try { Build-Row -Layout $L1 -Entry $entry -Cursor 0 -GlobalIdx 12345 | Out-Null } catch { $threw = $_.Exception.Message }
    Assert-True ($null -ne $threw -and $threw -like '*exceeds the fixed width*') 'gidx wider than IdxWidth throws (never widened silently)' $threw
    $rr0 = Build-Row -Layout $L0 -Entry $entry -Cursor 0
    Assert-True (($utf8.GetString($rr0.Bytes)) -like "src/Foo.cs | $expectedBytes | *") 'required-only layout: no gidx, no block'

    # measure is content-agnostic about gidx value (fixed width)
    Assert-True ((Measure-Row -Layout $L1 -Entry $entry) -eq (Build-Row -Layout $L1 -Entry $entry -Cursor 0 -GlobalIdx 9999).Bytes.Length) 'measure holds for any gidx value of the declared width'

    # -----------------------------------------------------------------------
    Enter-Section '5. Value walk — every layout accessor resolves on a real rs-content_meta entry'
    # -----------------------------------------------------------------------
    . (Join-Path $procDir 'tests\_helpers.ps1')
    $raw = [pscustomobject]@{ RelativePath = 'w/real.ps1'; NodePath = 'w/'; Content = "function f {`r`n  'x'`r`n}`r`n" }
    $enriched = & (Join-Path $procDir 'rs-content_meta.ps1') $raw @{}
    Assert-True ($null -ne $enriched.PSObject.Properties['ContentMeta']) 'rs-content_meta attached ContentMeta'

    $Lall = Resolve-Layout -Header (New-Header 1 @{ ContentMeta = @(1, 1) }) -Columns gidx, content_meta `
        -MetaFields line_mean, num_chars, num_words, num_punct, ws_ratio, entropy
    $unresolved = @()
    foreach ($col in $Lall.Columns)
    {
        $srcs = if ($col.Type -eq 'array') { @($col.Fields | ForEach-Object Source) } else { @($col.Source) }
        foreach ($s in $srcs)
        {
            if ($s -notlike 'entry.*') { continue }   # plan.* / codec.* are not entry paths
            $obj = $enriched
            foreach ($seg in ($s.Substring(6) -split '\.')) { $obj = if ($null -ne $obj) { $obj.PSObject.Properties[$seg].Value } else { $null } }
            if ($null -eq $obj) { $unresolved += $s }
        }
    }
    Assert-True ($unresolved.Count -eq 0) 'every entry.* accessor in the full layout resolves on the enriched entry' ($unresolved -join ', ')
    $fullRow = $utf8.GetString((Build-Row -Layout $Lall -Entry $enriched -Cursor 0 -GlobalIdx 0).Bytes)
    $block = $fullRow.Substring($fullRow.IndexOf('['), $fullRow.IndexOf(']') - $fullRow.IndexOf('[') + 1)
    Assert-True ($block -notmatch '  ') 'full block renders with no empty markers on a real entry (no doubled space)' $block
    Assert-True ((Measure-Row -Layout $Lall -Entry $enriched) -eq (Build-Row -Layout $Lall -Entry $enriched -Cursor 0 -GlobalIdx 0).Bytes.Length) 'real entry: measure == render'
}
catch
{
    Assert-True $false "SUITE ABORTED: $($_.Exception.Message)" $_.ScriptStackTrace
}

# ---------------------------------------------------------------------------
Write-Host "`n═══ container.tests: $script:Passed passed, $script:Failed failed ═══" -ForegroundColor $(if ($script:Failed -eq 0) { 'Green' } else { 'Red' })
if ($script:Failed -gt 0) { exit 1 }
