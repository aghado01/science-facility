#Requires -Version 7.5
Set-StrictMode -Version Latest

<#
.SYNOPSIS
    rs.core.container — psr layout resolution, content codec, header/row
    measure + render. Exercised against schema/psr.header.json (the real
    declaration) and, for the value walk, a real rs-content_meta enrichment.

.DESCRIPTION
    Sections:
      1. Resolve-Layout — required-only default; optional columns; widths from
         EntryCount; admissibility; MetaFields order/default; presence warning;
         the two order invariants (content last, content_bytes before it).
      2. Codec — Encode-Content SPEC rules 1–4; Measure-Content == UTF-8 width
         of Encode-Content over a battery incl. multibyte, surrogate pairs, a
         lone surrogate, every terminator kind, controls, backslashes.
      3. Header row — Render-HeaderRow bytes == HeaderBytes; LF-terminated; no
         trailing delimiter; UTF-8 no BOM.
      4. Rows — Measure-Row == Render-Row Bytes.Length (plan = file, by
         construction); exact text; offsets (0-based, inclusive ends,
         content_bytes adjacency); gidx zero-pad and width overflow; float
         formatting; empty markers for absent sub-fields / absent block;
         one physical line per row.
      5. Value walk (contracts check #5) — every enabled column/sub-field
         source in the layout resolves on an entry enriched by the REAL
         rs-content_meta processor.

.NOTES
    Run from any directory:
        & "$PSScriptRoot\container.tests.ps1"
#>

$v3 = Join-Path $PSScriptRoot '..\reposnapshot-v3'
$procDir = Join-Path $v3 'processors'
$declPath = Join-Path $v3 'schema\psr.header.json'

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

# Render-/Encode- are the brief's vocabulary (shard-container-brief), not
# approved verbs — suppress the discoverability warning, keep the names.
Import-Module (Join-Path $v3 'rs.core.container.psm1') -Force -DisableNameChecking
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
    Assert-True ($L0.HeaderRowText -eq 'path<str> | content_bytes<int> | content<str>') 'required-only header text' $L0.HeaderRowText
    Assert-True ($L0.HeaderBytes -eq ($utf8.GetByteCount($L0.HeaderRowText) + 1)) 'HeaderBytes = utf8(text) + LF'
    Assert-True ($L0.IdxWidth -eq 0) 'IdxWidth 0 when gidx is off'
    Assert-True ($L0.Format -eq 'psr' -and $L0.FloatPrecision -eq 4) 'Format psr, FloatPrecision 4'
    Assert-True ($L0.Framing.FieldDelimiter -eq ' | ' -and $L0.Framing.RecordTerminator -eq "`n" -and $L0.Framing.EmptyMarker -eq '' -and $L0.Framing.Bom -eq $false -and $L0.Framing.Encoding -eq 'utf-8') 'Framing verbatim from the declaration'

    $L1 = Resolve-Layout -Header $h -Columns gidx, content_meta
    Assert-True ($L1.IdxWidth -eq 4) 'IdxWidth = digits(1234) = 4' "got $($L1.IdxWidth)"
    Assert-True ($L1.HeaderRowText -eq 'gidx<int:4> | path<str> | content_meta:{chars<int> words<int> ws_ratio<float> entropy<float>} | content_bytes<int> | content<str>') 'full header text with default_on meta fields' $L1.HeaderRowText
    Assert-True (@($L1.Columns)[0].Width -eq 4 -and @($L1.Columns)[0].Source -eq 'plan.GlobalIdx') 'gidx column: width 4, source plan.GlobalIdx'
    $meta = @($L1.Columns | Where-Object Name -eq 'content_meta')[0]
    Assert-True (@($meta.Fields | ForEach-Object Name) -join ',' -eq 'chars,words,ws_ratio,entropy') 'default_on sub-fields in declaration order'
    Assert-True (@($meta.Fields)[0].Source -eq 'entry.ContentMeta.CharCount') 'sub-field source is the entry.ContentMeta.* path'

    $L2 = Resolve-Layout -Header (New-Header 7) -Columns content_meta -MetaFields entropy, chars, line_max -WarningAction SilentlyContinue
    $m2 = @($L2.Columns | Where-Object Name -eq 'content_meta')[0]
    Assert-True (@($m2.Fields | ForEach-Object Name) -join ',' -eq 'chars,entropy,line_max') 'MetaFields rendered in declaration order regardless of request order' (@($m2.Fields | ForEach-Object Name) -join ',')
    Assert-True ($L2.IdxWidth -eq 0 -and $L2.HeaderRowText -notlike 'gidx*') 'gidx off unless requested'

    $Lw = Resolve-Layout -Header (New-Header 0) -Columns gidx
    Assert-True ($Lw.IdxWidth -eq 1) 'EntryCount 0 → gidx width 1 (never 0)'
    $Lw2 = Resolve-Layout -Header (New-Header 100000) -Columns gidx
    Assert-True ($Lw2.IdxWidth -eq 6) 'EntryCount 100000 → width 6'

    $Lreq = Resolve-Layout -Header $h -Columns path, content
    Assert-True ($Lreq.HeaderRowText -eq $L0.HeaderRowText) 'naming a required column is a no-op'

    $threw = $null; try { Resolve-Layout -Header $h -Columns nope | Out-Null } catch { $threw = $_.Exception.Message }
    Assert-True ($null -ne $threw -and $threw -like '*not admissible*') 'inadmissible column throws' $threw
    $threw = $null; try { Resolve-Layout -Header $h -Columns content_meta -MetaFields chars, bogus | Out-Null } catch { $threw = $_.Exception.Message }
    Assert-True ($null -ne $threw -and $threw -like '*not admissible*') 'inadmissible content_meta sub-field throws' $threw

    # presence warning — never decides the layout
    $warn = @()
    $Lp = Resolve-Layout -Header (New-Header 5) -Columns content_meta -WarningVariable warn -WarningAction SilentlyContinue
    Assert-True ($warn.Count -eq 1 -and $warn[0] -like '*no ContentMeta*') 'content_meta on, no ContentMeta in Elements → one warning' ($warn -join ' / ')
    Assert-True ($Lp.HeaderRowText -like '*content_meta:{*') '…and the block is still in the layout'
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
    Enter-Section '2. Codec — Encode-Content / Measure-Content'
    # -----------------------------------------------------------------------
    Assert-True ((Encode-Content "a`r`nb`rc`nd") -eq 'a\nb\nc\nd') 'CRLF, CR, LF → \n (two chars), kind not preserved' (Encode-Content "a`r`nb`rc`nd")
    Assert-True ((Encode-Content "x`u{0085}y`u{2028}z`u{2029}w`u{000B}v`u{000C}u") -eq 'x\ny\nz\nw\nv\nu') 'NEL, LS, PS, VT, FF → \n'
    Assert-True ((Encode-Content 'C:\Users\me\n') -eq 'C:\Users\me\n') 'backslash never doubled; literal \n in source passes verbatim'
    Assert-True ((Encode-Content "a`tb") -eq "a`tb") 'TAB stays literal'
    Assert-True ((Encode-Content "a`0b`u{0001}c`u{007F}d`u{001B}e") -eq 'abcde') 'NUL, SOH, DEL, ESC stripped'
    Assert-True ((Encode-Content '') -eq '' -and (Encode-Content $null) -eq '') 'empty / null → empty'
    Assert-True ((Measure-Content '') -eq 0 -and (Measure-Content $null) -eq 0) 'empty / null → 0 bytes'
    $enc = Encode-Content "line1`r`nline2`n"
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
        $m = Measure-Content $s
        $e = $utf8.GetByteCount((Encode-Content $s))
        if ($m -ne $e) { $allEqual = $false; $detail += "[$($s.Substring(0, [Math]::Min(20, $s.Length)))… measure=$m encode=$e] " }
    }
    Assert-True $allEqual 'Measure-Content == utf8(Encode-Content) across the battery (incl. surrogates, every terminator, controls)' $detail
    Assert-True ((Measure-Content "ab`ncd") -eq 6) 'LF: 1 byte → 2 (ab\ncd = 6)'
    Assert-True ((Measure-Content "ab`r`ncd") -eq 6) 'CRLF: 2 bytes → 2'
    Assert-True ((Measure-Content "ab`u{2028}cd") -eq 6) 'LS: 3 bytes → 2'
    Assert-True ((Measure-Content "ab`0cd") -eq 4) 'NUL: 1 byte → 0'
    Assert-True ((Measure-Content 'é') -eq 2 -and (Measure-Content '😀') -eq 4) 'multibyte counted in UTF-8'

    # -----------------------------------------------------------------------
    Enter-Section '3. Header row'
    # -----------------------------------------------------------------------
    $hb = Render-HeaderRow -Layout $L1
    Assert-True ($hb.Length -eq $L1.HeaderBytes -and (Measure-HeaderRow -Layout $L1) -eq $L1.HeaderBytes) 'Render-HeaderRow bytes == HeaderBytes == Measure-HeaderRow'
    Assert-True ($hb[-1] -eq 10 -and $hb[-2] -ne 13) 'LF-terminated, no CR'
    Assert-True (-not ($hb[0] -eq 0xEF -and $hb[1] -eq 0xBB)) 'no BOM'
    $ht = $utf8.GetString($hb)
    Assert-True (-not $ht.TrimEnd("`n").EndsWith('|') -and -not $ht.TrimEnd("`n").EndsWith(' ')) 'no trailing delimiter'

    # -----------------------------------------------------------------------
    Enter-Section '4. Rows — Format / Measure / Render'
    # -----------------------------------------------------------------------
    $entry = [pscustomobject]@{
        RelativePath = 'src/Foo.cs'
        NodePath     = 'src/'
        LastWriteUtc = [datetime]::UtcNow
        Content      = "line one`r`nline two`n`ttabbed é"
        ContentMeta  = [pscustomobject]@{ CharCount = 30; WordCount = 5; WhitespaceRatio = 0.4037; Entropy = 4.25164; LineStats = [pscustomobject]@{ Mean = 9.5; Median = 9; StdDev = 1.5; Max = 12 } }
    }
    $expectedContent = 'line one\nline two\n' + "`ttabbed é"
    $expectedBytes = $utf8.GetByteCount($expectedContent)

    $f = Format-Row -Layout $L1 -Entry $entry -GlobalIdx 42
    Assert-True ($f.Pieces.Count -eq 4) 'Format-Row: 4 prefix pieces (gidx, path, meta, content_bytes) — content excluded' "$($f.Pieces.Count)"
    Assert-True ($f.Pieces[0] -eq '0042') 'gidx zero-padded to width 4'
    Assert-True ($f.Pieces[1] -eq 'src/Foo.cs') 'path verbatim'
    Assert-True ($f.Pieces[2] -eq '{30 5 0.4037 4.2516}') 'content_meta block: int plain, float F4 invariant, declaration order' $f.Pieces[2]
    Assert-True ($f.Pieces[3] -eq "$expectedBytes" -and $f.ContentBytes -eq $expectedBytes) 'content_bytes = measured encoded width'

    $mr = Measure-Row -Layout $L1 -Entry $entry
    $rr = Render-Row -Layout $L1 -Entry $entry -Cursor 138 -GlobalIdx 42
    Assert-True ($mr -eq $rr.Bytes.Length) 'PLAN = FILE: Measure-Row == Render-Row Bytes.Length' "measure=$mr render=$($rr.Bytes.Length)"
    $rowText = $utf8.GetString($rr.Bytes)
    $expectedRow = "0042 | src/Foo.cs | {30 5 0.4037 4.2516} | $expectedBytes | $expectedContent`n"
    Assert-True ($rowText -eq $expectedRow) 'row text exact' $rowText
    Assert-True (($rowText.TrimEnd("`n")) -notmatch "[`r`n]") 'one physical line per row'
    Assert-True (-not $rowText.TrimEnd("`n").EndsWith('|')) 'no trailing delimiter on rows'

    # offsets — 0-based, inclusive ends, content_bytes adjacency
    $prefix = "0042 | src/Foo.cs | {30 5 0.4037 4.2516} | $expectedBytes"
    $prefixBytes = $utf8.GetByteCount($prefix)
    Assert-True ($rr.RowOffset -eq 138) 'RowOffset = cursor'
    Assert-True ($rr.RowMetaEnd -eq 138 + $prefixBytes - 1) 'RowMetaEnd = last byte of the prefix (inclusive)' "$($rr.RowMetaEnd)"
    Assert-True ($rr.RowContentBegin -eq 138 + $prefixBytes + 3) 'RowContentBegin = after " | "'
    Assert-True ($rr.RowContentEnd -eq $rr.RowContentBegin + $expectedBytes - 1) 'RowContentEnd inclusive = begin + content_bytes − 1'
    Assert-True ($rr.ContentBytes -eq $expectedBytes -and ($rr.RowContentEnd - $rr.RowContentBegin + 1) -eq $rr.ContentBytes) 'ContentBytes == end − begin + 1'
    Assert-True ($rr.NextCursor -eq 138 + $rr.Bytes.Length) 'NextCursor = cursor + row bytes'
    # seek contract round-trip on the bytes themselves
    $span = [byte[]]::new($rr.ContentBytes)
    [Array]::Copy($rr.Bytes, $rr.RowContentBegin - 138, $span, 0, $rr.ContentBytes)
    Assert-True ($utf8.GetString($span) -eq $expectedContent) 'seek contract: bytes at [RowContentBegin..RowContentEnd] are exactly the encoded content'

    # absent sub-field / absent block → empty markers; row still measures == renders
    $sparse = [pscustomobject]@{ RelativePath = 'a.txt'; Content = 'x'; ContentMeta = [pscustomobject]@{ CharCount = 1 } }
    $fs = Format-Row -Layout $L1 -Entry $sparse -GlobalIdx 0
    Assert-True ($fs.Pieces[2] -eq '{1   }') 'absent sub-fields render the empty marker, positions kept' "'$($fs.Pieces[2])'"
    $bare = [pscustomobject]@{ RelativePath = 'b.txt'; Content = 'y' }
    $fb = Format-Row -Layout $L1 -Entry $bare -GlobalIdx 0
    Assert-True ($fb.Pieces[2] -eq '{   }') 'absent block renders all empty markers' "'$($fb.Pieces[2])'"
    Assert-True ((Measure-Row -Layout $L1 -Entry $bare) -eq (Render-Row -Layout $L1 -Entry $bare -Cursor 0 -GlobalIdx 0).Bytes.Length) 'sparse row: measure == render'

    # empty content → LTS convention RowContentEnd == RowContentBegin, ContentBytes 0
    $empty = [pscustomobject]@{ RelativePath = 'e.txt'; Content = '' }
    $re = Render-Row -Layout $L0 -Entry $empty -Cursor 10
    Assert-True ($re.ContentBytes -eq 0 -and $re.RowContentEnd -eq $re.RowContentBegin) 'empty content: ContentBytes 0, RowContentEnd == RowContentBegin (LTS convention)'
    Assert-True ((Measure-Row -Layout $L0 -Entry $empty) -eq $re.Bytes.Length) 'empty content: measure == render'

    # gidx: required when enabled; width overflow is a plan-time error
    $threw = $null; try { Render-Row -Layout $L1 -Entry $entry -Cursor 0 | Out-Null } catch { $threw = $_.Exception.Message }
    Assert-True ($null -ne $threw -and $threw -like '*GlobalIdx is required*') 'Render-Row without GlobalIdx under gidx throws' $threw
    $threw = $null; try { Render-Row -Layout $L1 -Entry $entry -Cursor 0 -GlobalIdx 12345 | Out-Null } catch { $threw = $_.Exception.Message }
    Assert-True ($null -ne $threw -and $threw -like '*exceeds the fixed width*') 'gidx wider than IdxWidth throws (never widened silently)' $threw
    $rr0 = Render-Row -Layout $L0 -Entry $entry -Cursor 0
    Assert-True (($utf8.GetString($rr0.Bytes)) -like "src/Foo.cs | $expectedBytes | *") 'required-only layout: no gidx, no block'

    # measure is content-agnostic about gidx value (fixed width)
    Assert-True ((Measure-Row -Layout $L1 -Entry $entry) -eq (Render-Row -Layout $L1 -Entry $entry -Cursor 0 -GlobalIdx 9999).Bytes.Length) 'measure holds for any gidx value of the declared width'

    # -----------------------------------------------------------------------
    Enter-Section '5. Value walk — every layout source resolves on a real rs-content_meta entry'
    # -----------------------------------------------------------------------
    . (Join-Path $procDir 'tests\_helpers.ps1')
    $raw = [pscustomobject]@{ RelativePath = 'w/real.ps1'; NodePath = 'w/'; Content = "function f {`r`n  'x'`r`n}`r`n" }
    $enriched = & (Join-Path $procDir 'rs-content_meta.ps1') $raw @{}
    Assert-True ($null -ne $enriched.PSObject.Properties['ContentMeta']) 'rs-content_meta attached ContentMeta'

    $Lall = Resolve-Layout -Header (New-Header 1 @{ ContentMeta = @(1, 1) }) -Columns gidx, content_meta `
        -MetaFields chars, words, punct, uniq_chars, entropy, ws_ratio, line_mean, line_median, line_sd, line_max
    $unresolved = @()
    foreach ($col in $Lall.Columns)
    {
        $srcs = if ($col.Type -eq 'block') { @($col.Fields | ForEach-Object Source) } else { @($col.Source) }
        foreach ($s in $srcs)
        {
            if ($s -notlike 'entry.*') { continue }   # plan.* / codec.* are not entry paths
            $obj = $enriched
            foreach ($seg in ($s.Substring(6) -split '\.')) { $obj = if ($null -ne $obj) { $obj.PSObject.Properties[$seg].Value } else { $null } }
            if ($null -eq $obj) { $unresolved += $s }
        }
    }
    Assert-True ($unresolved.Count -eq 0) 'every entry.* source in the full layout resolves on the enriched entry' ($unresolved -join ', ')
    $fr = Format-Row -Layout $Lall -Entry $enriched -GlobalIdx 0
    Assert-True ($fr.Pieces[2] -notmatch '\{.*  .*\}' ) 'full block renders with no empty markers on a real entry' $fr.Pieces[2]
    Assert-True ((Measure-Row -Layout $Lall -Entry $enriched) -eq (Render-Row -Layout $Lall -Entry $enriched -Cursor 0 -GlobalIdx 0).Bytes.Length) 'real entry: measure == render'
}
catch
{
    Assert-True $false "SUITE ABORTED: $($_.Exception.Message)" $_.ScriptStackTrace
}

# ---------------------------------------------------------------------------
Write-Host "`n═══ container.tests: $script:Passed passed, $script:Failed failed ═══" -ForegroundColor $(if ($script:Failed -eq 0) { 'Green' } else { 'Red' })
if ($script:Failed -gt 0) { exit 1 }
