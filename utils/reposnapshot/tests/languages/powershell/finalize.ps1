#requires -Version 7.0
<#
  src/codex-membrane/finalize.ps1 — serialize the repaired chunk stream into the corpus deliverable.

  Walks the enriched chunks in reading order and emits codex-scientiae markdown per
  STANDARDS.md: an H1 title, a `## Contents` block, body sections at H2/H3/H4 by depth, prose
  paragraphs, block math fenced in $$, and running-head furniture dropped. The back-matter
  (References) is split into a sidecar references/{slug}.md, linked from Contents. First pass
  writes into the document's own run dir (.runs/{stamp}/) — get the SHAPE right;
  the move to compendia/{topic}/ is a later concern. Logs the 'finalized' milestone.

    . ./finalize.ps1
    Invoke-Finalize -ChunksPath <chunks.jsonl> [-OutputDir <dir>]
#>

. "$PSScriptRoot/serving.ps1"
. "$PSScriptRoot/../shared/runs.ps1"          # Get-PigRunDirs (newest-wins) — the figure weave reads the pig lane
. "$PSScriptRoot/../audits/md-register.ps1"   # the ONE markdown figure register, shared with the LaTeX oracle lane
. "$PSScriptRoot/../shared/md-anchor.ps1"            # the ONE heading-slug engine (Get-MdAnchor)

# caption furniture -> italic, heading -> #*(level+1), block formula -> $$ fence, else content as-is
function Format-Chunk($c) {
    if ([string]$c.is_furniture -eq 'caption') { return '*' + ([string]$c.content) + '*' }
    switch ([string]$c.type) {
        'heading' { $lvl = if ($c.section_level) { [Math]::Min(6, [int]$c.section_level + 1) } else { 2 }; ('#' * $lvl) + ' ' + ([string]$c.content) }
        'formula' { '$$' + "`n" + ([string]$c.content) + "`n" + '$$' }
        default   { [string]$c.content }
    }
}

# ── caption relocation — reunite a shattered caption with its figure's in-text anchor ──────────────
# The caption's own figure/table handle: the leading "Fig. 1" / "Table 3" a caption furniture chunk
# opens with (the SAME shape normalize's Get-FurnitureKind gates on). Returns { kind; num } — kind
# normalized to 'figure'/'table' so a "Fig." caption anchors to a "Figure 1" reference — or $null when
# the chunk is not a caption / carries no leading numbered label (leave it exactly where it is).
function Get-CaptionLabel($c) {
    if ([string]$c.is_furniture -ne 'caption') { return $null }
    $m = [regex]::Match(([string]$c.content).Trim(), '^(Figure|Fig\.?|Table|Tab\.?)\s*(\d+)', 'IgnoreCase')
    if (-not $m.Success) { return $null }
    $kind = if ($m.Groups[1].Value -match '^(?i:fig)') { 'figure' } else { 'table' }
    return [pscustomobject]@{ kind = $kind; num = $m.Groups[2].Value }
}

# Does a body chunk carry an in-text mention of (kind num) — "Figure 1", "Fig. 1", "(Figure 1 ,",
# "see Fig. 6", "shown in Table 3"? CASE-SENSITIVE (real references are capitalized) so a lowercase
# "table"/"figure" prose word is never a false anchor; word-anchored + digit-bounded so "Figure 1"
# never matches "Figure 10"/"Figure 12".
function Test-FigureReference($c, $Label) {
    $verb = if ($Label.kind -eq 'figure') { '(?:Figure|Fig\.?)' } else { '(?:Table|Tab\.?)' }
    $rx = '(?<![A-Za-z])' + $verb + '\s*' + [regex]::Escape($Label.num) + '(?![0-9])'
    return [regex]::IsMatch([string]$c.content, $rx)
}

# Docling frequently shatters a FIGURE caption away from its figure and drops it mid-prose; normalize.ps1
# CLASSIFIES the stray as is_furniture='caption' but leaves it in place, so it interrupts the body flow.
# Here — at EMISSION only, never touching the persisted chunk stream or its id==line-number seek
# invariant — relocate each figure caption to sit immediately after the FIRST body chunk that references
# its figure number in-text (the anchor the paper's own prose gives, and the exact spot the publish/splice
# tier later weaves the figure pixels into — preprocess strips images, so the caption is what's orphaned).
# A caption whose number is nowhere referenced in the body stays exactly where it was — never lost, never
# mis-placed. Pure list transform over an unchanging input: recomputes the same order every run, so a
# second pass is a no-op (idempotent).
#
# FIGURE captions only — deliberately NOT tables. The image-stripping "reunite the orphan with its splice
# point" rationale is figure-specific (a table's own cells are not stripped, so its caption is not orphaned
# the same way), and a table's "Tab. N"/"Table N" cue collides with bibliographic citations of OTHER works'
# tables ("Vinh et al , 2010 , Tab. 2") — anchoring on those would mis-place the caption. Table captions
# stay in reading order rather than ride a reference signal that can't tell a cross-cite from a real anchor.
function Move-CaptionsToAnchors($BodyChunks) {
    $items = @($BodyChunks)
    # capIndex -> anchor chunk id it should trail (only figure captions with a resolvable in-text reference)
    $anchorId = @{}
    for ($i = 0; $i -lt $items.Count; $i++) {
        $label = Get-CaptionLabel $items[$i]
        if (-not $label -or $label.kind -ne 'figure') { continue }   # figure captions only (see note above)
        for ($j = 0; $j -lt $items.Count; $j++) {
            if ($j -eq $i -or [string]$items[$j].is_furniture -eq 'caption') { continue }   # anchors are real body prose, never another caption
            if (Test-FigureReference $items[$j] $label) { $anchorId[$i] = [int]$items[$j].id; break }
        }
    }
    if ($anchorId.Count -eq 0) { return $items }
    # captions to inject after each anchor id, keyed by anchor id, in stable original-body order
    $trailing = @{}
    foreach ($ci in ($anchorId.Keys | Sort-Object)) {
        $aid = $anchorId[$ci]
        if (-not $trailing.ContainsKey($aid)) { $trailing[$aid] = [System.Collections.Generic.List[object]]::new() }
        $trailing[$aid].Add($items[$ci])
    }
    $out = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $items.Count; $i++) {
        if ($anchorId.ContainsKey($i)) { continue }                    # a relocated caption — emitted after its anchor below
        $out.Add($items[$i])
        if ($trailing.ContainsKey([int]$items[$i].id)) {
            foreach ($cap in $trailing[[int]$items[$i].id]) { $out.Add($cap) }
        }
    }
    return $out.ToArray()
}

# ── figure weave — the finalized markdown drinks the pig figure lane ────────────────────────────────
# The measurement marginal: every kind=figure region of the paper's NEWEST pig run enters the emitted
# body as an image line through the SAME register the LaTeX oracle emits (md-register.ps1) — best-effort
# BY DESIGN. Rendering is deliberately indifferent to detection quality: if the figure lane is wrong,
# the markdown shows it, and that visibility is the instrument. Placement: a CAPTIONED region rides its
# caption chunk (wherever Move-CaptionsToAnchors put it — the caption is the placement token this
# architecture reserved for exactly this weave); an UNCAPTIONED region (inline diagrams + residue)
# flushes when the reading order leaves its page. A region whose crop failed emits the flagged marker —
# nothing silent. Crop PNGs copy into {OutputDir}/{slug}-membrane/ (lane-infixed: never collides with
# the oracle's {slug}/ image dir; the paper-root mirror's links resolve once publish carries the dir up).
# Returns $null when the paper has no pig run / figure lane (e.g. pure docling papers).
function Get-FigureWeave([string]$PaperRoot, [string]$Slug, [string]$OutputDir) {
    $pigDirs = @(Get-PigRunDirs $PaperRoot $Slug)
    if (-not $pigDirs.Count) { return $null }
    $pig = $pigDirs[0]
    $figuresJsonl = Join-Path $pig "$Slug.figures.jsonl"
    $manifestPath = Join-Path $pig 'images.jsonl'
    if (-not (Test-Path -LiteralPath $figuresJsonl) -or -not (Test-Path -LiteralPath $manifestPath)) { return $null }

    $crop = @{}
    foreach ($line in [System.IO.File]::ReadLines($manifestPath)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $r = $line | ConvertFrom-Json
        $crop[[int]$r.figure_id] = $r
    }

    $imgDirName = "$Slug-membrane"
    $imgDir = Join-Path $OutputDir $imgDirName
    $byNum = @{}    # figure number -> @{ image; caption } (captioned regions: the image rides the caption chunk)
    $byPage = @{}   # page -> List[string] image/marker lines (uncaptioned + table-cued: flushed at page end)
    $markers = 0; $copied = 0
    foreach ($line in [System.IO.File]::ReadLines($figuresJsonl)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $f = $line | ConvertFrom-Json
        if ($f.kind -ne 'figure') { continue }
        $capText = if ($f.caption) { [string]$f.caption.text } else { $null }
        $m = [regex]::Match(($capText ?? ''), '^(Figure|Fig\.?|Table|Tab\.?)\s*(\d+)', 'IgnoreCase')
        $isFigCaption = ($m.Success -and $m.Groups[1].Value -match '^(?i:fig)')
        $name = if ($isFigCaption) { "Figure $($m.Groups[2].Value)" } else { "p$($f.page) region $($f.id)" }
        $kindLabel = if ($f.caption) { 'figure' } else { 'diagram' }

        $rec = $crop[[int]$f.id]
        if ($rec -and [string]$rec.status -eq 'ok' -and $rec.png) {
            $srcPng = Join-Path $pig ([string]$rec.png)
            $leaf = Split-Path -Leaf ([string]$rec.png)
            if (Test-Path -LiteralPath $srcPng) {
                if (-not (Test-Path -LiteralPath $imgDir)) { New-Item -ItemType Directory -Force -Path $imgDir | Out-Null }
                Copy-Item -LiteralPath $srcPng -Destination (Join-Path $imgDir $leaf) -Force
                $copied++
                $imgLine = Format-MdFigureImage $kindLabel $name "$imgDirName/$leaf"
            }
            else { $imgLine = Format-MdFigureMarker $kindLabel $name 'crop PNG missing from the pig run'; $markers++ }
        }
        else { $imgLine = Format-MdFigureMarker $kindLabel $name 'crop render failed'; $markers++ }

        if ($isFigCaption) {
            $num = $m.Groups[2].Value
            if (-not $byNum.ContainsKey($num)) { $byNum[$num] = @{ image = $imgLine; caption = $capText } }
            else { $p = [int]$f.page; if (-not $byPage.ContainsKey($p)) { $byPage[$p] = [System.Collections.Generic.List[string]]::new() }; $byPage[$p].Add($imgLine) }
        }
        else {
            $p = [int]$f.page
            if (-not $byPage.ContainsKey($p)) { $byPage[$p] = [System.Collections.Generic.List[string]]::new() }
            $byPage[$p].Add($imgLine)
        }
    }
    if ($byNum.Count -eq 0 -and $byPage.Count -eq 0) { return $null }
    @{ ByNum = $byNum; ByPage = $byPage; Markers = $markers; Copied = $copied; PigRun = $pig }
}

function Invoke-Finalize {
    [CmdletBinding()] param(
        [Parameter(Mandatory)][string]$ChunksPath,
        [string]$OutputDir
    )
    $chunks = @(Read-Chunks $ChunksPath)
    $slug = (Split-Path -Leaf $ChunksPath) -replace '\.chunks\.jsonl$', ''
    if (-not $OutputDir) { $OutputDir = Split-Path -Parent $ChunksPath }   # the run dir, first pass
    $live  = @($chunks | Where-Object { $_.is_furniture -notin 'running_head', 'figure_label', 'crumb' })
    $title = ($live | Where-Object { $_.title_candidate } | Select-Object -First 1).content

    # ── single ordered pass: split front-matter / body / bibliography ─────
    # The sidecar is the bibliography REGION only (References heading → next heading),
    # not the whole back-matter zone — appendices are part of the paper and stay in the body.
    $front = [System.Collections.Generic.List[object]]::new()
    $bodyC = [System.Collections.Generic.List[object]]::new()
    $bibC  = [System.Collections.Generic.List[object]]::new()
    $toc   = [System.Collections.Generic.List[string]]::new()
    $inBib = $false; $refLinkAdded = $false
    foreach ($c in $live) {
        # citation-run references (refs-in-lists, no "References" heading) route to the sidecar
        # regardless of zone — they were marked is_reference by the structural citation detector.
        if ($c.is_reference) {
            if (-not $refLinkAdded) { $toc.Add("- [References](references/$slug.md)"); $refLinkAdded = $true }
            $bibC.Add($c); continue
        }
        $isHeading = ([string]$c.type -eq 'heading')
        if ($isHeading) {
            if ($c.section_role -eq 'references' -or ([string]$c.content -match '^\s*references\s*$')) {
                $inBib = $true
                if (-not $refLinkAdded) { $toc.Add("- [References](references/$slug.md)"); $refLinkAdded = $true }
                continue                                          # heading becomes the sidecar's own title
            }
            $inBib = $false                                       # any other heading closes the bibliography
        }
        if ($c.zone -eq 'frontmatter') { if (-not $c.title_candidate) { $front.Add($c) }; continue }
        if ($inBib) { $bibC.Add($c); continue }
        $bodyC.Add($c)
        if ($isHeading -and $c.section_level) {
            $indent = '  ' * ([Math]::Max(0, [int]$c.section_level - 1))
            $toc.Add("$indent- [$([string]$c.content)](#$(Get-MdAnchor ([string]$c.content)))")
        }
    }

    # ── body ──────────────────────────────────────────────────────────────
    $body = [System.Collections.Generic.List[string]]::new()
    if ($title) { $body.Add("# $title"); $body.Add('') }
    foreach ($c in $front) { $body.Add([string]$c.content); $body.Add('') }   # authors / affiliation / abstract, plain
    $body.Add('## Contents'); $body.Add('')
    foreach ($line in $toc) { $body.Add($line) }
    $body.Add('')
    # reunite shattered captions with their in-text figure/table anchor before serializing (emission-order
    # only; the persisted chunk stream + its id==line seek invariant are untouched). TOC is already built.
    $bodyC = Move-CaptionsToAnchors $bodyC

    # figure weave (see Get-FigureWeave): captioned crops ride their caption chunks; uncaptioned crops
    # flush when reading order leaves their page; leftovers land in a flagged tail. Best-effort, visible.
    $paperRoot = $OutputDir -replace '[\\/]\.(?:runs[\\/][^\\/]+|scratch)$', ''
    $weave = Get-FigureWeave $paperRoot $slug $OutputDir
    $wovenCaptioned = 0
    $paged = @{ n = 0 }   # hashtable holder: a scriptblock increment must MUTATE, not shadow (dynamic scope)
    $flushPagesThrough = {
        param($upto)
        foreach ($p in @($weave.ByPage.Keys | Where-Object { [int]$_ -le $upto } | Sort-Object)) {
            foreach ($imgLine in $weave.ByPage[$p]) { $body.Add($imgLine); $body.Add(''); $paged.n++ }
            $weave.ByPage.Remove($p)
        }
    }
    $lastPage = $null
    foreach ($c in $bodyC) {
        if ($null -ne $weave -and $null -ne $c.page) {
            $cp = [int]$c.page
            if ($null -ne $lastPage -and $cp -gt $lastPage) { & $flushPagesThrough ($cp - 1) }
            $lastPage = $cp
        }
        if ($null -ne $weave) {
            $label = Get-CaptionLabel $c
            if ($label -and $label.kind -eq 'figure' -and $weave.ByNum.ContainsKey($label.num)) {
                $body.Add($weave.ByNum[$label.num].image); $body.Add('')
                $weave.ByNum.Remove($label.num)
                $wovenCaptioned++
            }
        }
        $body.Add((Format-Chunk $c)); $body.Add('')
    }
    if ($null -ne $weave) {
        # tail: pages the body never reached + captioned crops whose caption chunk never surfaced —
        # emitted with their pig-lane caption so nothing is silently lost
        & $flushPagesThrough ([int]::MaxValue)
        foreach ($num in @($weave.ByNum.Keys | Sort-Object { [int]$_ })) {
            $body.Add($weave.ByNum[$num].image); $body.Add('')
            $cap = Format-MdFigureCaption $weave.ByNum[$num].caption
            if ($cap) { $body.Add($cap); $body.Add('') }
            $paged.n++
        }
    }

    # ── references sidecar ────────────────────────────────────────────────
    $refs = [System.Collections.Generic.List[string]]::new()
    $refs.Add("# References — $slug"); $refs.Add('')
    foreach ($c in $bibC) { $refs.Add((Format-Chunk $c)); $refs.Add('') }

    # ── write ─────────────────────────────────────────────────────────────
    $bodyPath = Join-Path $OutputDir "$slug.md"
    $refDir   = Join-Path $OutputDir 'references'
    if (-not (Test-Path -LiteralPath $refDir)) { New-Item -ItemType Directory -Force -Path $refDir | Out-Null }
    $refPath  = Join-Path $refDir "$slug.md"
    $utf8 = [System.Text.UTF8Encoding]::new($false)   # explicit no-BOM, LF-only — no Set-Content CRLF/formatter side-effects
    [System.IO.File]::WriteAllText($bodyPath, (($body -join "`n") + "`n"), $utf8)
    [System.IO.File]::WriteAllText($refPath,  (($refs -join "`n") + "`n"), $utf8)

    # lane mirror (STANDARDS §9): copy the finalized body up to the paper's slug root as
    # {slug}-membrane.md so the latex/membrane/docling lanes sit side-by-side for cross-examination.
    # The run-dir copy above stays authoritative; only mirror when OutputDir is a real run dir. The
    # woven figure crops ({slug}-membrane/*.png) ride UP with the mirror so its image links resolve at
    # the paper root the same as at the run dir (both use the {slug}-membrane/ relative prefix — the
    # lane-infixed dir never collides with the oracle's {slug}/).
    if ($paperRoot -ne $OutputDir) {
        [System.IO.File]::WriteAllText((Join-Path $paperRoot "$slug-membrane.md"), (($body -join "`n") + "`n"), $utf8)
        $runImgDir = Join-Path $OutputDir "$slug-membrane"
        if (Test-Path -LiteralPath $runImgDir) {
            $mirrorImgDir = Join-Path $paperRoot "$slug-membrane"
            if (-not (Test-Path -LiteralPath $mirrorImgDir)) { New-Item -ItemType Directory -Force -Path $mirrorImgDir | Out-Null }
            # -Path (not -LiteralPath): the trailing * must glob; -LiteralPath treats it as a literal filename
            Copy-Item -Path (Join-Path $runImgDir '*') -Destination $mirrorImgDir -Force
        }
    }

    $sections = @($bodyC | Where-Object { [string]$_.type -eq 'heading' -and $_.section_level }).Count
    $pending  = @($live | Where-Object { $_.fidelity -in 'needs_review', 'needs_repair', 'suspect' }).Count
    $weaveStats = [ordered]@{
        figures_woven = $wovenCaptioned; figures_paged = $paged.n
        weave_markers = $(if ($weave) { $weave.Markers } else { 0 })
        images_copied = $(if ($weave) { $weave.Copied } else { 0 })
        pig_run = $(if ($weave) { Split-Path -Leaf (Split-Path -Parent $weave.PigRun) } else { $null })
    }
    Add-LedgerEntry $ChunksPath 'finalized' @{ body = "$slug.md"; references = "references/$slug.md"; sections = $sections; bib = $bibC.Count; pending = $pending; weave = $weaveStats }
    [pscustomobject]@{ ok = $true; paper = $slug; body = $bodyPath; references = $refPath; sections = $sections; bib = $bibC.Count; pending = $pending; weave = [pscustomobject]$weaveStats }
}

# The one sanctioned holistic read. The membrane is body-blind by construction — the per-unit
# loop works through scoped slices so the agent never re-reads the whole paper. At the very end,
# a single full pass over the ASSEMBLED deliverable catches what per-chunk review can't: flow
# across sections, a heading that reads wrong in context, a caption cut loose from its figure.
# Assembles fresh, then returns the body + references in full (content IS the point here) plus the
# still-flagged chunks with ids and reasons, so the spot-check is targeted rather than a blind reread.
function Get-FinalReview([string]$ChunksPath) {
    $fin    = Invoke-Finalize -ChunksPath $ChunksPath
    $chunks = @(Read-Chunks $ChunksPath)
    $flagged = @($chunks |
        Where-Object { $_.fidelity -in 'needs_review', 'needs_repair', 'suspect' } |
        ForEach-Object {
            $t = [string]$_.content
            [pscustomobject]@{
                id       = $_.id
                fidelity = $_.fidelity
                reason   = if ($_.review_reason) { $_.review_reason } elseif ($_.corruption_type) { $_.corruption_type } else { $null }
                preview  = $t.Substring(0, [Math]::Min(80, $t.Length))
            }
        })
    [pscustomobject]@{
        paper      = $fin.paper
        sections   = $fin.sections
        bib        = $fin.bib
        pending    = $fin.pending
        flagged    = $flagged
        body       = [System.IO.File]::ReadAllText($fin.body,       [System.Text.UTF8Encoding]::new($false))
        references = [System.IO.File]::ReadAllText($fin.references, [System.Text.UTF8Encoding]::new($false))
    }
}
