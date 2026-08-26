#requires -Version 7.0
<#
  src/codex-membrane/collapse.ps1 — collapse node-JSONL (fragmented IR shards) into chunk-JSONL.

  Walks the IR-ordered nodes and agglomerates consecutive prose shards into
  coherent chunks by bounding-box continuity, repairing inline as it goes. Figure
  debris (shards inside an image's padded bbox) is routed to a discards sidecar —
  nothing is dropped silently; kept chunks + discards = every input node.

  Emits chunks.jsonl and discards.jsonl, each with coordinated .jidx + .sig.

    . ./collapse.ps1
    Invoke-Collapse -NodesPath <nodes.jsonl> -OutputPath <chunks.jsonl>

  Merge model (bbox = [x0,y0,x1,y1], PDF points, y-up; top = y1), vs the previous shard:
    same line  (|Δtop| < 0.5·lh):  concatenate; space iff the x-gap is a word gap
    next line  (0.5·lh ≤ Δtop ≤ 1.8·lh): join with a space (trailing hyphen joins tight)
    otherwise  (bigger gap / page change): close the chunk
  Structural nodes (heading/formula/image/…) flush the open prose chunk and emit their own.
#>

. "$PSScriptRoot/../shared/jsonl.ps1"

$script:Ligatures = @{ 'ﬁ' = 'fi'; 'ﬂ' = 'fl'; 'ﬃ' = 'ffi'; 'ﬀ' = 'ff'; 'ﬄ' = 'ffl' }

function Remove-Ligatures([string]$s) {
    foreach ($k in $script:Ligatures.Keys) {
        if ($s.Contains($k)) { $s = $s.Replace($k, $script:Ligatures[$k]) }
    }
    return $s
}

function Merge-Bbox($a, $b) {
    return @([Math]::Min($a[0], $b[0]), [Math]::Min($a[1], $b[1]),
             [Math]::Max($a[2], $b[2]), [Math]::Max($a[3], $b[3]))
}

function Get-ImageBoxesByPage($Nodes, [double]$Margin) {
    $boxes = @{}
    foreach ($n in $Nodes) {
        if ($n.type -ne 'image') { continue }
        $b = $n.bbox
        if (-not $b -or $b.Count -ne 4) { continue }
        $x0 = [double]$b[0]; $y0 = [double]$b[1]; $x1 = [double]$b[2]; $y1 = [double]$b[3]
        if (-not $boxes.ContainsKey($n.page)) { $boxes[$n.page] = [System.Collections.Generic.List[object]]::new() }
        $boxes[$n.page].Add(@(($x0 - $Margin), ($y0 - $Margin), ($x1 + $Margin), ($y1 + $Margin)))
    }
    return $boxes
}

function Test-InsideAny($Bbox, $Boxes) {
    if (-not $Boxes) { return $false }
    $cx = ($Bbox[0] + $Bbox[2]) / 2.0
    $cy = ($Bbox[1] + $Bbox[3]) / 2.0
    foreach ($bx in $Boxes) {
        if ($bx[0] -le $cx -and $cx -le $bx[2] -and $bx[1] -le $cy -and $cy -le $bx[3]) { return $true }
    }
    return $false
}

function Invoke-Collapse {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $NodesPath,
        [Parameter(Mandatory)] [string] $OutputPath
    )

    $nodes = [System.Collections.Generic.List[object]]::new()
    foreach ($line in [System.IO.File]::ReadLines($NodesPath)) {
        if (-not [string]::IsNullOrWhiteSpace($line)) { $nodes.Add(($line | ConvertFrom-Json)) }
    }

    $heights = [System.Collections.Generic.List[double]]::new()
    foreach ($n in $nodes) {
        if ($n.bbox -and $n.bbox.Count -eq 4 -and $n.bbox[3] -gt $n.bbox[1]) { $heights.Add($n.bbox[3] - $n.bbox[1]) }
    }
    $lh = if ($heights.Count) { ($heights | Sort-Object)[[int][math]::Floor($heights.Count / 2)] } else { 10.0 }

    $imageBoxes = Get-ImageBoxesByPage $nodes (1.5 * $lh)

    $chunks   = [System.Collections.Generic.List[object]]::new()
    $discards = [System.Collections.Generic.List[object]]::new()
    $cur = $null
    $lastTop = 0.0
    $lastX1 = 0.0

    foreach ($nd in $nodes) {
        $t = $nd.type
        $bbox = $nd.bbox
        $content = Remove-Ligatures ([string]$nd.content)
        $hasBbox = ($bbox -and $bbox.Count -eq 4)

        if ($t -eq 'paragraph' -and $hasBbox -and (Test-InsideAny $bbox $imageBoxes[$nd.page])) {
            if ($cur) { $chunks.Add($cur); $cur = $null }
            $discards.Add([pscustomobject][ordered]@{
                id = $nd.id; type = $t; page = $nd.page; bbox = $bbox; content = $content
                discard_reason = 'figure_debris'; discard_pass = 'collapse'
            })
            continue
        }

        if ($t -eq 'paragraph' -and $hasBbox) {
            $ntop = $bbox[3]; $nx0 = $bbox[0]; $nx1 = $bbox[2]
            if ($cur -and $nd.page -eq $cur.page) {
                $dtop = $lastTop - $ntop
                if ([math]::Abs($ntop - $lastTop) -lt 0.5 * $lh) {
                    $sep = if (($nx0 - $lastX1) -gt 0.25 * $lh) { ' ' } else { '' }
                    $cur.content += $sep + $content
                    $cur.bbox = Merge-Bbox $cur.bbox $bbox
                    $cur.n_shards++
                    $lastTop = $ntop; $lastX1 = $nx1
                    continue
                }
                if ($dtop -ge 0.5 * $lh -and $dtop -le 1.8 * $lh) {
                    # line-break join. A trailing hyphen before a lowercase continuation is a
                    # word-wrap soft hyphen (Clas-/sical) → strip it. BUT a genuine compound can wrap
                    # at its own hyphen (delta-/homology); we can't tell without a lexicon, so we
                    # dehyphenate best-effort and FLAG the chunk for the enrichment tier to verify.
                    if ($cur.content.EndsWith('-') -and $content -match '^[a-z]') {
                        $cur.content = $cur.content.Substring(0, $cur.content.Length - 1) + $content
                        $cur | Add-Member -NotePropertyName dehyphenated -NotePropertyValue $true -Force
                    }
                    elseif ($cur.content.EndsWith('-')) { $cur.content += $content }   # uppercase/other continuation: keep the hyphen
                    else { $cur.content += ' ' + $content }
                    $cur.bbox = Merge-Bbox $cur.bbox $bbox
                    $cur.n_shards++
                    $lastTop = $ntop; $lastX1 = $nx1
                    continue
                }
            }
            if ($cur) { $chunks.Add($cur) }
            $cur = [pscustomobject][ordered]@{
                type = 'prose'; page = $nd.page; bbox = @($bbox[0], $bbox[1], $bbox[2], $bbox[3])
                font = $nd.font; font_size = $nd.font_size; n_shards = 1; content = $content
            }
            $lastTop = $ntop; $lastX1 = $nx1
        }
        else {
            if ($cur) { $chunks.Add($cur); $cur = $null }
            $chunk = [ordered]@{ type = $t; page = $nd.page; bbox = $bbox; n_shards = 1; content = $content }
            if ($null -ne $nd.level) { $chunk['level'] = $nd.level }
            if ($null -ne $nd.heading_level) { $chunk['heading_level'] = $nd.heading_level }   # pig lane: outline/tier depth
            if ($null -ne $nd.font) { $chunk['font'] = $nd.font }
            if ($null -ne $nd.font_size) { $chunk['font_size'] = $nd.font_size }
            if ($nd.heading_source) { $chunk['heading_source'] = $nd.heading_source }
            # pig converter's self-reported residue (unbalanced_delimiters, needs_2d_assembly, …) —
            # the dispatchable "isolation" signal for the membrane's gated math-repair loop
            if ($nd.flags -and @($nd.flags).Count -gt 0) { $chunk['flags'] = @($nd.flags) }
            if ($t -eq 'header' -or $t -eq 'footer') { $chunk['is_furniture'] = $true }
            if ($t -eq 'caption') {
                # pig-lane BORN-TYPED caption (pdfdig-adapter: figures.jsonl caption block ids) — land it
                # exactly where normalize's shape classifier would: a prose chunk carrying caption
                # furniture. Standing alone here is the point: agglomeration can never weld it into the
                # neighboring paragraph, and finalize's caption relocation + figure weave anchor on it.
                $chunk['type'] = 'prose'
                $chunk['is_furniture'] = 'caption'
            }
            $chunks.Add([pscustomobject]$chunk)
        }
    }
    if ($cur) { $chunks.Add($cur) }

    for ($i = 0; $i -lt $chunks.Count; $i++) {
        $chunks[$i] | Add-Member -NotePropertyName id -NotePropertyValue $i -Force
    }

    $chunkManifest = Write-JsonlStage -Records $chunks.ToArray() -OutputPath $OutputPath `
                                      -SourcePath $NodesPath -Stage 'collapse'
    $discPath = $OutputPath -replace '\.chunks\.jsonl$', '.discards.jsonl'
    if ($discPath -eq $OutputPath) { $discPath = "$OutputPath.discards.jsonl" }
    $discManifest = Write-JsonlStage -Records $discards.ToArray() -OutputPath $discPath `
                                     -SourcePath $NodesPath -Stage 'collapse-discards'

    "$($nodes.Count) nodes -> $($chunks.Count) chunks  +$($discards.Count) discarded  (lh=$([math]::Round($lh,1)))"
    "  chunks   -> $($chunkManifest.Jsonl)  (+ .jidx, .sig)"
    "  discards -> $($discManifest.Jsonl)   (audit)"
    ($chunks | Group-Object type | Sort-Object Name | ForEach-Object { "  {0,-10} {1}" -f $_.Name, $_.Count }) -join "`n"
    return $chunkManifest
}
