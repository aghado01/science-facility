#requires -Version 7.0
<#
  src/codex-membrane/headings.ps1 — typographic heading recovery on the node stream.

  Struct-tree exports routinely mis-type real headings as body text (and running
  heads as headings). Before collapse merges anything, this pass re-reads the nodes
  and promotes short, line-isolated text whose typography CONTRASTS with the body
  baseline to type='heading': a larger size (the title) or a heading face — bold /
  small-caps relative to the body's roman face (section heads). Typography is the
  ground truth here, not the export's tags. Re-typing the node (rather than patching
  the chunk) lets collapse's existing structural path keep each head as its own chunk,
  so the merge logic is untouched.

  Recovered nodes carry heading_source='geometric' + original_type for audit —
  nothing is re-typed silently.

    . ./headings.ps1
    Invoke-HeadingRecovery -NodesPath <nodes.jsonl> [-Ratio 1.15] [-MaxLen 180]
#>

. "$PSScriptRoot/../shared/jsonl.ps1"

# A heading face = a bold or small-caps font variant — the weights LaTeX/Word reserve
# for headings — detected by common font-name markers (Computer Modern bx/csc plus the
# mainstream bold/black/semibold/smallcaps/caps spellings). Size contrast is handled
# separately; this is the same-size-but-different-face signal.
function Test-HeadingFace([string]$font) {
    if ([string]::IsNullOrWhiteSpace($font)) { return $false }
    return [bool]($font -match '(?i)(bold|black|heavy|semib|bx\d|csc|small.?cap|[-_ ]sc\b|sc\d+\b|caps\b)')
}

# Length-weighted modal font + size over text records: the dominant body typography,
# weighted so a few large display lines can't outvote the mass of body text.
function Get-BodyTypography($Records) {
    $sizeW = @{}; $fontW = @{}
    foreach ($r in $Records) {
        # weight = amount of body text (glyph count), not UTF-16 code units — otherwise an SMP-heavy
        # display line is over-weighted 2x/glyph, working against the "few large lines can't outvote
        # the body mass" intent. Text-element count keeps the modal-typography vote glyph-fair.
        $len = [System.Globalization.StringInfo]::new([string]$r.content).LengthInTextElements
        if ($len -le 0) { continue }
        if ($null -ne $r.font_size) {
            $k = [math]::Round([double]$r.font_size, 1)
            $sizeW[$k] = [double]$sizeW[$k] + $len
        }
        if ($r.font) {
            $f = [string]$r.font
            $fontW[$f] = [double]$fontW[$f] + $len
        }
    }
    $bodySize = if ($sizeW.Count) { ($sizeW.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1).Key } else { $null }
    $bodyFont = if ($fontW.Count) { ($fontW.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1).Key } else { $null }
    return [pscustomobject]@{ Size = $bodySize; Font = $bodyFont }
}

function Invoke-HeadingRecovery {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $NodesPath,
        [double] $Ratio  = 1.15,
        [int]    $MaxLen = 180
    )

    $nodes = [System.Collections.Generic.List[object]]::new()
    foreach ($line in [System.IO.File]::ReadLines($NodesPath)) {
        if (-not [string]::IsNullOrWhiteSpace($line)) { $nodes.Add(($line | ConvertFrom-Json)) }
    }

    $textNodes = @($nodes | Where-Object { $_.type -eq 'paragraph' })
    $body = Get-BodyTypography $textNodes
    if ($null -eq $body.Size -and $null -eq $body.Font) {
        "no font metadata on nodes — heading recovery skipped ($($nodes.Count) nodes)"
        return
    }

    $promoted = 0
    foreach ($n in $nodes) {
        if ($n.type -ne 'paragraph') { continue }
        # No real font => this node came from the Docling backend unenriched: opendataloader's
        # DoclingSchemaTransformer stamps a hardcoded font=null / size=12.0 PLACEHOLDER on every
        # element the geometric enrichment couldn't bbox-match to a PDFBox TextChunk (see
        # HybridDocumentProcessor.enrichSingleTextNode). That 12.0 is not a measured size, so the
        # contrast test below misfires: 12.0 >= (real ~10pt body) * 1.15 fires $bigger on EVERY short
        # unenriched element (2066 phantom headings corpus-wide). Typography is the ground truth here;
        # a node with no font carries none, so defer to the converter's own paragraph classification.
        if (-not $n.font) { continue }
        $content = [string]$n.content
        # "short heading" = glyph count, not UTF-16 code units: a math-bearing heading (SMP glyphs =
        # 2 units each) would otherwise be wrongly rejected by the $MaxLen gate. Count text elements.
        $len = [System.Globalization.StringInfo]::new($content).LengthInTextElements
        if ($len -le 0 -or $len -gt $MaxLen) { continue }
        if ($content -notmatch '[A-Za-z]{2,}') { continue }   # a heading is a word, not "(1)" / a drop cap / a symbol run

        $bigger = ($null -ne $n.font_size -and $null -ne $body.Size -and
                   [double]$n.font_size -ge [double]$body.Size * $Ratio)
        $face   = ((Test-HeadingFace ([string]$n.font)) -and ([string]$n.font -ne [string]$body.Font))
        if (-not ($bigger -or $face)) { continue }

        $n | Add-Member -NotePropertyName original_type  -NotePropertyValue 'paragraph' -Force
        $n | Add-Member -NotePropertyName heading_source -NotePropertyValue 'geometric' -Force
        $n.type = 'heading'
        $promoted++
    }

    $manifest = Write-JsonlStage -Records $nodes.ToArray() -OutputPath $NodesPath -Stage 'headings'

    "heading recovery: body=$($body.Font)@$($body.Size)pt  promoted $promoted/$($textNodes.Count) text nodes -> heading -> $NodesPath"
    $nodes | Where-Object { $_.heading_source -eq 'geometric' } | Select-Object -First 8 |
        ForEach-Object { "  + {0,7} {1,-9} :: {2}" -f $_.font_size, $_.font, (([string]$_.content).Substring(0,[Math]::Min(50,([string]$_.content).Length))) }
    return $manifest
}
