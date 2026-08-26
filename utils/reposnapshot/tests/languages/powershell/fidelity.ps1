#requires -Version 7.0
<#
  src/codex-membrane/fidelity.ps1 — corruption signatures -> per-chunk hotspot tags.

  Tags each chunk `fidelity` (faithful | suspect) and, when suspect, the
  `corruption_type` that fired. Faithful chunks pass untouched; the suspect set is
  the bounded work-list the serving layer hands to the model.

  Signatures are cheap and high-precision, drawn from corruption we've actually seen
  in the corpus:
    intertext         - `\intertext` sludge bolted onto real math (locator, not oracle)
    replacement_char  - the U+FFFD sentinel
    gibberish         - space-shattered single-char runs ("a o f i n t o o t")
    ligature_residue  - OCR ligatures that survived collapse
    unbalanced_delimiters - {} / [] / () / \left..\right mismatch in math content
    alignment_outside_env - & alignment tab in a formula with no \begin{...} (KaTeX parse error)
    prose_in_formula  - a formula chunk that reads as natural language (mislabeled / leaked prose)

  The last two are cross-derivation converges: the assembled closure scanner (Find-MathClosureIssues)
  already flags them, but chunk-fidelity didn't — so the two derivations of "renderable math" could
  disagree (a file the scanner later called broken passed fidelity clean). Checking here closes that.

    . ./fidelity.ps1
    Invoke-Fidelity -ChunksPath <chunks.jsonl> [-NodesPath <nodes.jsonl>]
#>

. "$PSScriptRoot/../shared/jsonl.ps1"
. "$PSScriptRoot/../latex-ingest/latex.ps1"   # shared math predicates + (transitively) the mask algebra / SpanLevel

$script:RxInlineMath = [regex]'\$\$[\s\S]*?\$\$|\$[^$\n]+\$'   # wrapped math is NOT shatter — mask it first

# gibberish — space-shattered text ("a o f i n t o o t"). The math overlay is masked out (so wrapped
# variables / flattened subscripts inside $...$ aren't mistaken for shatter), then per Line the longest
# run of CONSECUTIVE single-ALPHABETIC tokens is the signal. Two construction fixes over the old
# whole-content '(?:\b\w\s+){6,}' run:
#   * ALPHABETIC singles only — "1 2 3 4 5 6 7" is tabular data, not shatter (the old \w counted digits);
#   * the run, not a 7-long minimum — a shorter shatter trips it ("A l p h a", "r a n k" the old missed),
#     while the run length is exactly what separates true shatter (4-5+) from flattened index variables
#     ("b k i and d k i", broken every 3 by a real word).
# MinRun is tunable; the default is calibrated against the corpus A/B (match-or-reduce false flags).
function Get-GibberishSpans([string]$content, [int]$MinRun = 4) {
    $spans = [System.Collections.Generic.List[object]]::new()
    $prose = Get-MaskedText -Text $content -Mask (New-Mask $content $script:RxInlineMath)
    foreach ($unit in (Split-AtLevel -Text $prose -Level Line)) {
        $run = 0; $runStart = -1
        foreach ($tm in [regex]::Matches($unit.Text, '\S+')) {
            if ($tm.Value -match '^[A-Za-z]$') {
                if ($run -eq 0) { $runStart = $tm.Index }
                $run++
                if ($run -ge $MinRun) {
                    $spans.Add([pscustomobject]@{ start = $unit.Start + $runStart; end = $unit.Start + $tm.Index + $tm.Length })
                    return $spans.ToArray()   # same first-hit semantics as the bool test
                }
            }
            else { $run = 0; $runStart = -1 }
        }
    }
    return @()
}

function Test-IsGibberish([string]$content, [int]$MinRun = 4) {
    return @(Get-GibberishSpans $content $MinRun).Count -gt 0
}

# Difference-localization for Get-ChunkIssues — reuses the SAME geometry as each signature's Test predicate.
function Get-IssueSpans([string]$IssueType, [string]$ChunkType, [string]$Content) {
    if (-not $Content) { return @() }
    switch ($IssueType) {
        'intertext'               { return @(Get-IntertextSpans $Content) }
        'replacement_char'        { return @(Get-ReplacementCharSpans $Content) }
        'gibberish'               { return @(Get-GibberishSpans $Content) }
        'ligature_residue'        { return @(Get-LigatureSpans $Content) }
        'alignment_outside_env'     { if ($ChunkType -eq 'formula') { return @(Get-AlignmentOutsideEnvSpans $Content) }; return @() }
        'prose_in_formula'        { if ($ChunkType -eq 'formula') { return @(Get-ProseInFormulaSpans $Content) }; return @() }
        'unbalanced_delimiters'   { return @(Get-UnbalancedDelimiterSpans $Content) }
        'unclosed_environment'    { return @(Get-UnclosedEnvironmentSpans $Content) }
        'glyph_name_leak'         { return @(Get-GlyphNameLeakSpans $Content) }
        'degenerate_structure'    { if ($ChunkType -eq 'formula') { return @(Get-DegenerateStructureSpans $Content) }; return @() }
        'hallucinated_subexpr'    { if ($ChunkType -eq 'formula') { return @(Get-HallucinatedSubexprSpans $Content) }; return @() }
        'dangling_operator'       { if ($ChunkType -eq 'formula') { return @(Get-DanglingOperatorSpans $Content) }; return @() }
        'text_sentence_in_math'   { if ($ChunkType -eq 'formula') { return @(Get-TextSentenceInMathSpans $Content) }; return @() }
        'bare_number_row'         { if ($ChunkType -eq 'formula') { return @(Get-BareNumberRowSpans $Content) }; return @() }
        'heading_level_unknown'   { return @([pscustomobject]@{ start = 0; end = $Content.Length }) }
        'unwrapped_math' {
            if (-not $script:NormalizeSpanLoaded) {
                . "$PSScriptRoot/normalize.ps1"
                $script:NormalizeSpanLoaded = $true
            }
            return @(Get-UnwrappedMathSpans $Content)
        }
        default { return @() }
    }
}

# ── corruption signatures — ONE definition per signature, the single home both derivations read ──────
# The frozen single-type gate (Get-CorruptionType, first-match → accept/reject) and the multi-issue
# inventory (Get-ChunkIssues, all-match → dispatch enrichment) are two derivations of "what is wrong with
# this chunk." They MUST NOT drift, so they read this ONE ordered table instead of each carrying its own
# copy of the per-signature predicate — the same cross-derivation discipline the mask-algebra substrate
# enforced. Order is the gate's historical precedence: do NOT reorder — the gate returns the FIRST type
# that fires and the corpus A/B pins that verdict. Each signature carries:
#   type  — the corruption_type label
#   Test  — predicate over ($type, $content) → bool   (the SAME check both derivations run)
#   Diag  — the worker-facing diagnostic (the delimiter seam for unbalanced; '' where the name suffices)
# The alignment / prose-in-formula pair are the cross-derivation converges the assembled closure scanner
# (Find-MathClosureIssues) also checks, lifted to chunk level via the shared latex.ps1 predicates so the
# two derivations of "renderable math" can't disagree. Delimiter balance via the context-aware scanner
# (skips escaped \{ \(, pairs \left..\right): full balance for a pure formula; braces only for inline math
# in prose, where prose parens/brackets would otherwise false-positive.
#   severity — 'hard' (the frozen gate; corpus A/B pins it) or 'soft' (the needs_review lane). The gate
#     Get-CorruptionType reads ONLY hard rows, so the soft band is invisible to it and the differential is
#     untouched; Get-SoftReviewType reads the soft band, and Get-ChunkIssues reads BOTH (the inventory).
$script:CorruptionSignatures = @(
    [pscustomobject]@{ type = 'intertext'; severity = 'hard'
        Test = { param($type, $content) $content.Contains('\intertext') }
        Diag = { param($type, $content) '' } }
    [pscustomobject]@{ type = 'replacement_char'; severity = 'hard'
        Test = { param($type, $content) $content.Contains([char]0xFFFD) }
        Diag = { param($type, $content) '' } }
    [pscustomobject]@{ type = 'gibberish'; severity = 'hard'
        Test = { param($type, $content) Test-IsGibberish $content }
        Diag = { param($type, $content) '' } }
    [pscustomobject]@{ type = 'ligature_residue'; severity = 'hard'
        Test = { param($type, $content) [bool]($content -match '[ﬀ-ﬄ]') }
        Diag = { param($type, $content) '' } }
    [pscustomobject]@{ type = 'alignment_outside_env'; severity = 'hard'
        Test = { param($type, $content) $type -eq 'formula' -and (Test-AlignmentOutsideEnv $content) }
        Diag = { param($type, $content) '' } }
    [pscustomobject]@{ type = 'prose_in_formula'; severity = 'hard'
        Test = { param($type, $content) $type -eq 'formula' -and -not (Test-IsMath $content) }
        Diag = { param($type, $content) '' } }
    [pscustomobject]@{ type = 'unbalanced_delimiters'; severity = 'hard'
        Test = { param($type, $content)
            if ($type -eq 'formula')         { -not (Get-LatexBalance $content).full }
            elseif ($content.Contains('$'))  { -not (Get-LatexBalance $content).braceBalanced }
            else                             { $false } }
        Diag = { param($type, $content) $b = Get-LatexBalance $content; "brace=$($b.brace) brack=$($b.brack) paren=$($b.paren) lr=$($b.lr)" } }
    # APPENDED — never reordered (precedence note above). The \begin{...}/\end{...} closure invariant
    # Get-LatexBalance can't see: an \end carried off with a degenerate tail leaves an open environment
    # that is brace-balanced (so unbalanced_delimiters passes) yet breaks the math parser. Last in
    # precedence, so it only wins the gate when nothing above fires; Get-ChunkIssues still surfaces it
    # alongside any earlier match.
    [pscustomobject]@{ type = 'unclosed_environment'; severity = 'hard'
        Test = { param($type, $content) -not (Get-EnvironmentBalance $content).balanced }
        Diag = { param($type, $content) $f = (Get-EnvironmentBalance $content).fault; if ($f) { '{0} {1} @ {2}' -f $f.kind, $f.name, $f.index } else { '' } } }

    # ── SOFT band — valid-but-wrong TELLS (severity='soft'). Structurally valid LaTeX that is semantically
    # wrong: balance / is-math both pass, so the hard gate is blind. NEVER seen by Get-CorruptionType (it
    # filters to 'hard'), so corpus A/B is untouched; they route to needs_review via Get-SoftReviewType and
    # surface in the work-order inventory (Get-ChunkIssues reads the whole table). Order within the band is
    # the soft-gate precedence (the needs_review headline); the inventory still lists every soft match.
    [pscustomobject]@{ type = 'glyph_name_leak'; severity = 'soft'
        Test = { param($type, $content) Test-GlyphNameLeak $content }
        Diag = { param($type, $content) (($script:RxGlyphLeak.Matches($content) | ForEach-Object { $_.Value }) | Select-Object -Unique) -join ',' } }
    [pscustomobject]@{ type = 'degenerate_structure'; severity = 'soft'
        Test = { param($type, $content) $type -eq 'formula' -and (Test-DegenerateStructure $content) }
        Diag = { param($type, $content) '' } }
    [pscustomobject]@{ type = 'hallucinated_subexpr'; severity = 'soft'
        Test = { param($type, $content) $type -eq 'formula' -and (Test-HallucinatedSubexpr $content) }
        Diag = { param($type, $content) '' } }
    [pscustomobject]@{ type = 'dangling_operator'; severity = 'soft'
        Test = { param($type, $content) $type -eq 'formula' -and (Test-DanglingOperator $content) }
        Diag = { param($type, $content) '' } }
    [pscustomobject]@{ type = 'text_sentence_in_math'; severity = 'soft'
        Test = { param($type, $content) $type -eq 'formula' -and (Test-TextSentenceInMath $content) }
        Diag = { param($type, $content) "text_prose_words=$(Get-TextProseWordCount $content)" } }
    [pscustomobject]@{ type = 'bare_number_row'; severity = 'soft'
        Test = { param($type, $content) $type -eq 'formula' -and (Test-BareNumberRow $content) }
        Diag = { param($type, $content) '' } }
)

# The frozen merge-gate: the FIRST signature that fires (historical precedence), else $null (clean). This
# stays the sole driver of fidelity grading and the apply gate; the inventory below never moves it. Reads
# the shared table, so it cannot drift from Get-ChunkIssues.
function Get-CorruptionType($Chunk) {
    $content = [string]$Chunk.content
    if (-not $content) { return $null }
    $type = [string]$Chunk.type
    foreach ($sig in $script:CorruptionSignatures) {
        if ($sig.severity -ne 'hard') { continue }   # the frozen gate sees ONLY hard signals (corpus A/B pinned)
        if (& $sig.Test $type $content) { return $sig.type }
    }
    return $null
}

# The SOFT counterpart of the gate: the first soft signal that fires, else $null. Drives the needs_review
# lane in Invoke-Fidelity — actionable + surfaced, but never moves the hard accept/reject. Reads the SAME
# shared table (soft rows only), so it cannot drift from Get-ChunkIssues or the gate.
function Get-SoftReviewType($Chunk) {
    $content = [string]$Chunk.content
    if (-not $content) { return $null }
    $type = [string]$Chunk.type
    foreach ($sig in $script:CorruptionSignatures) {
        if ($sig.severity -ne 'soft') { continue }
        if (& $sig.Test $type $content) { return $sig.type }
    }
    return $null
}

# Multi-issue inventory (the DISPATCH derivation) — EVERY signature that fires, as {type, spans, diagnostic},
# not the gate's first-match. Additive and SEPARATE from Get-CorruptionType: it never touches accept/
# reject; it only enriches what the worker is dispatched to do, so a chunk carrying e.g. ligature_residue
# AND unbalanced_delimiters surfaces both for one composed work-order instead of N re-dispatches. Folds in
# the two needs_review kinds Invoke-Fidelity routes on (content the gate calls clean but the stage still
# flags): heading_level_unknown (level_uncertain) and unwrapped_math (math_dirt ≥ 2) — the SAME booleans
# Invoke-Fidelity uses, so those don't drift either. Computed on demand (at dispatch / slice time), never
# stored: the work-order is assembled lazily, so there is no sidecar to go stale under id renumbering.
# `spans` are half-open [start,end) UTF-16 offsets into the chunk — repair hints, not sub work-units;
# localized via Get-IssueSpans (same geometry as each signature's Test predicate).
# Returns @() for a clean chunk.
function Get-ChunkIssues($Chunk) {
    $content = [string]$Chunk.content
    $type    = [string]$Chunk.type
    $issues  = [System.Collections.Generic.List[object]]::new()
    if ($content) {
        foreach ($sig in $script:CorruptionSignatures) {
            if (& $sig.Test $type $content) {
                $issues.Add([pscustomobject]@{
                    type       = $sig.type
                    spans      = @(Get-IssueSpans $sig.type $type $content)
                    diagnostic = [string](& $sig.Diag $type $content)
                })
            }
        }
    }
    # the needs_review kinds — faithful content the fidelity stage still hands the agent (the gate is
    # clean, so these are NOT in the shared table). Mirror Invoke-Fidelity's two branches exactly.
    if ($Chunk.level_uncertain) {
        $issues.Add([pscustomobject]@{
            type       = 'heading_level_unknown'
            spans      = @(Get-IssueSpans 'heading_level_unknown' $type $content)
            diagnostic = ''
        })
    }
    if ([int]($Chunk.math_dirt) -ge 2) {
        $issues.Add([pscustomobject]@{
            type       = 'unwrapped_math'
            spans      = @(Get-IssueSpans 'unwrapped_math' $type $content)
            diagnostic = "math_dirt=$([int]$Chunk.math_dirt)"
        })
    }
    # the cross-chunk seam merge — its span is stored on the chunk (Set-SeamMergeFlags has the neighbours;
    # Get-IssueSpans is per-chunk and cannot recompute it), so read it directly here.
    if ($Chunk.seam_merge) {
        $issues.Add([pscustomobject]@{
            type       = 'prose_seam_merge'
            spans      = @($Chunk.seam_merge)
            diagnostic = ''
        })
    }
    # pig converter's 2-D residue: a flattened fraction/matrix/stacked-script the geometry assembler
    # could not resolve. Flag-based (the CONTENT often renders — a fraction as "a/b" is valid LaTeX —
    # so the content signatures are blind; only the converter's self-report reveals it). The slice
    # enriches this with math_evidence so the agent reconstructs from geometry (see playbook).
    if ($Chunk.flags -and (@($Chunk.flags) -contains 'needs_2d_assembly')) {
        $issues.Add([pscustomobject]@{
            type       = 'needs_2d_assembly'
            spans      = @()
            diagnostic = 'converter flattened 2-D structure; geometry in math_evidence'
        })
    }
    return $issues.ToArray()
}

# Structural impossibilities (Part B) — mis-*geometry* only: a chunk cannot land when its type/label is
# structurally wrong (alignment outside env, prose mislabeled as formula). unbalanced_delimiters is
# fixable corruption (merge-then-fix, propose_edit) — NOT a global structural impossibility; it gets
# op-specific guards instead (split orphaning; merge only when the join WORSENS balance vs the parts).
# Content-only signatures (ligature, gibberish, …) stay on the content-repair path. ONE table, no fork.
$script:StructuralImpossibilityTypes = @('alignment_outside_env', 'prose_in_formula')

function Get-StructuralImpossibility($Chunk) {
    $content = [string]$Chunk.content
    if (-not $content) { return $null }
    $type = [string]$Chunk.type
    foreach ($sig in $script:CorruptionSignatures) {
        if ($sig.type -notin $script:StructuralImpossibilityTypes) { continue }
        if (& $sig.Test $type $content) {
            return [pscustomobject]@{ reason = $sig.type; diagnostic = [string](& $sig.Diag $type $content) }
        }
    }
    return $null
}

# Delimiter imbalance via the shared table's unbalanced_delimiters row — for op-specific gates (split
# orphaning) that must reuse the SAME predicate/diagnostic, not a forked copy.
function Test-ChunkUnbalanced($Chunk) {
    $content = [string]$Chunk.content
    if (-not $content) { return $false }
    $sig = $script:CorruptionSignatures | Where-Object { $_.type -eq 'unbalanced_delimiters' } | Select-Object -First 1
    return [bool](& $sig.Test ([string]$Chunk.type) $content)
}

function Get-UnbalancedDiagnostic($Chunk) {
    $sig = $script:CorruptionSignatures | Where-Object { $_.type -eq 'unbalanced_delimiters' } | Select-Object -First 1
    return [string](& $sig.Diag ([string]$Chunk.type) ([string]$Chunk.content))
}

function Get-BalanceResidual([string]$Content) {
    $b = Get-LatexBalance $Content
    return [Math]::Abs($b.brace) + [Math]::Abs($b.brack) + [Math]::Abs($b.paren) + [Math]::Abs($b.lr)
}

# ── agreement — structural-ambiguity score for dispatch RANKING (Part A; ranks, never gates) ───────
# agreement ∈ [0,1] is the mask IoU (Jaccard) of >=2 INDEPENDENT derivations of the same property, each
# rendered as a Mask: coverage(A∩B)/coverage(A∪B), defined 1 when the union is empty (both derivations
# agree there is nothing). The score is the MIN over the applicable pairs (the most-disputed derivation
# dominates), so dispatch can spend the agent's scarcest resource — budget — on genuinely uncertain
# regions first, not on single-detector noise. Pure composition of the EXISTING set-ops + already-ported
# detectors: adds NO mask primitive, NO new detection heuristic. It only RE-ORDERS the work-list; the
# work-SET (the fidelity gate) and every accept/reject are untouched.
#
# Cardinality is Get-MaskCoverage (covered UTF-16 units) — the set size Jaccard needs; Get-MaskDensity
# counts register tokens, a different thing. The derivation pairs, applied where the chunk type fits:
#   math    — math-by-content (the RxMathStructure overlay, via Get-MathStructureMask) vs math-by-label
#             (type=='formula' ⇒ the whole chunk is claimed math). GRADED: for a formula this is the
#             fraction that is actual math structure, so prose leaked into a formula drives it down.
#   heading — typography-derived (docling laid it out as a heading: type=='heading') vs markup-derived
#             (the font/number leveler placed it: section_level present AND not level_uncertain). The
#             heading the leveler could not place — the existing level_uncertain dispute — scores 0.
#   closure — the pincer top-down==bottom-up coincidence (the substrate's tested law): the whole-chunk
#             math-structure mask vs the per-line masks lifted back. <1 when a formula's structure spans
#             a line boundary the per-line view can't see. Balance (Get-LatexBalance) already gates the
#             SET as unbalanced_delimiters; it is NOT folded into the score (rank and gate stay distinct).
function Get-MaskIoU($A, $B) {
    $inter = Get-MaskCoverage (Intersect-Mask $A $B)
    $union = Get-MaskCoverage (Union-Mask $A $B)
    if ($union -le 0) { return 1.0 }     # empty union: both derivations agree there is nothing
    return [double]$inter / [double]$union
}

function Get-AgreementScore($Chunk) {
    $content = [string]$Chunk.content
    if (-not $content) { return 1.0 }    # nothing to dispute
    $type = [string]$Chunk.type
    $len  = $content.Length
    $full  = New-Mask -Spans @([pscustomobject]@{ Start = 0; End = $len }) -Length $len
    $empty = New-Mask -Spans @() -Length $len
    $scores = [System.Collections.Generic.List[double]]::new()

    # math pair — any math signal: a formula label, or content the math-structure overlay matches.
    # Prose: subtract already-wrapped inline $...$ before IoU so legit inline-math prose scores 1, not 0;
    # unwrapped math outside $...$ still disputes (pairs with Get-InlineMathMask / localized spans).
    $byContent = Get-MathStructureMask $content
    $isFormula = ($type -eq 'formula')
    if ($isFormula -or -not (Test-MaskEmpty $byContent)) {
        if (-not $isFormula) { $byContent = Sub-Mask $byContent (Get-InlineMathMask $content) }
        $byLabel = if ($isFormula) { $full } else { $empty }
        $scores.Add((Get-MaskIoU $byContent $byLabel))
    }

    # heading pair — docling laid this out as a heading (typography); did the leveler place it (markup)?
    if ($type -eq 'heading') {
        $placed = ($null -ne $Chunk.section_level) -and (-not $Chunk.level_uncertain)
        $markup = if ($placed) { $full } else { $empty }
        $scores.Add((Get-MaskIoU $full $markup))
    }

    # closure pair (formula) — the pincer: whole-chunk structure mask (top-down) vs per-line lifted union
    if ($isFormula) {
        $bottomUp = $empty
        foreach ($u in (Split-AtLevel -Text $content -Level Line)) {
            $bottomUp = Union-Mask $bottomUp (Move-Mask (Get-MathStructureMask $u.Text) $u.Start $len)
        }
        $scores.Add((Get-MaskIoU $byContent $bottomUp))
    }

    if ($scores.Count -eq 0) { return 1.0 }   # no applicable pair: nothing disputed
    return ($scores | Measure-Object -Minimum).Minimum
}

# Recompute + store agreement on a chunk EXACTLY like math_dirt: a per-chunk field (never a sidecar, so
# split/merge id renumbering can't strand it), written only when there is dispute to record (<1.0) and
# CLEARED when a re-grade returns it to 1.0, so a stale low score never lingers. Absent ⇒ 1.0 downstream.
function Set-ChunkAgreement($Chunk) {
    $a = Get-AgreementScore $Chunk
    if ($a -lt 1.0) { $Chunk | Add-Member -NotePropertyName agreement -NotePropertyValue ([double]$a) -Force }
    elseif ($Chunk.PSObject.Properties['agreement']) { $Chunk.PSObject.Properties.Remove('agreement') }
    return $a
}

# ── prose_seam_merge — the CROSS-CHUNK tell ───────────────────────────────────────────────────────────
# The per-chunk signature table can grade a chunk only from its own content; this one needs its NEIGHBOURS.
# A formula whose \text{} prose duplicates the adjacent paragraph verbatim is a converter merge: the next
# line's prose was pulled into the equation tail (forward), or the previous line's tail into a lead-in row
# (backward). A pass over the ORDERED chunk list (sibling to Group-MathHotspots) sets a stored `seam_merge`
# field {start,end} the grader and the inventory read — exactly like level_uncertain / math_dirt, so a
# cross-chunk signal flows through the body-blind per-chunk serving layer. Recomputed every grade and CLEARED
# when absent, so a fixed seam never lingers. High precision by construction: a >=12-char verbatim run shared
# between a formula's \text{} and a NON-formula neighbour's seam edge is a merge, not chance; legitimate short
# annotations (\text{if}, \text{for all}) are below the length floor.
$script:SeamMergeMinChars = 12
$script:SeamMergeWindow    = 250
function Get-SeamMergeSpan($Chunks, [int]$Index) {
    $c = $Chunks[$Index]
    if ([string]$c.type -ne 'formula') { return $null }
    $content = [string]$c.content
    $texts = @([regex]::Matches($content, '\\text\s*\{([^{}]*)\}') |
        Where-Object { (Get-NormalizedProse $_.Groups[1].Value).Length -ge $script:SeamMergeMinChars })
    if ($texts.Count -eq 0) { return $null }
    # the seam edges of the NON-formula neighbours (the prose the merge came from)
    $nHead = ''; $pTail = ''
    if ($Index + 1 -lt $Chunks.Count -and [string]$Chunks[$Index + 1].type -ne 'formula') {
        $nx = [string]$Chunks[$Index + 1].content
        $nHead = Get-NormalizedProse $nx.Substring(0, [Math]::Min($script:SeamMergeWindow, $nx.Length))
    }
    if ($Index - 1 -ge 0 -and [string]$Chunks[$Index - 1].type -ne 'formula') {
        $pv = [string]$Chunks[$Index - 1].content
        $pTail = Get-NormalizedProse $(if ($pv.Length -gt $script:SeamMergeWindow) { $pv.Substring($pv.Length - $script:SeamMergeWindow) } else { $pv })
    }
    if (-not $nHead -and -not $pTail) { return $null }
    foreach ($m in $texts) {
        $norm = Get-NormalizedProse $m.Groups[1].Value
        if (($nHead -and $nHead.Contains($norm)) -or ($pTail -and $pTail.Contains($norm))) {
            return [pscustomobject]@{ start = [int]$m.Index; end = [int]($m.Index + $m.Length) }
        }
    }
    return $null
}
function Set-SeamMergeFlags($Chunks) {
    for ($i = 0; $i -lt $Chunks.Count; $i++) {
        $span = Get-SeamMergeSpan $Chunks $i
        if ($span) { $Chunks[$i] | Add-Member -NotePropertyName seam_merge -NotePropertyValue $span -Force }
        elseif ($Chunks[$i].PSObject.Properties['seam_merge']) { $Chunks[$i].PSObject.Properties.Remove('seam_merge') }
    }
}

function Invoke-Fidelity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ChunksPath,
        [string] $NodesPath
    )

    $chunks = [System.Collections.Generic.List[object]]::new()
    foreach ($line in [System.IO.File]::ReadLines($ChunksPath)) {
        if (-not [string]::IsNullOrWhiteSpace($line)) { $chunks.Add(($line | ConvertFrom-Json)) }
    }

    Set-SeamMergeFlags $chunks   # cross-chunk pass: set the stored seam_merge field BEFORE per-chunk grading

    foreach ($c in $chunks) {
        Set-ChunkAgreement $c | Out-Null   # recompute the ranking score every re-grade (ranks, never gates)
        $ct = Get-CorruptionType $c
        if ($ct) {
            $c | Add-Member -NotePropertyName fidelity        -NotePropertyValue 'suspect' -Force
            $c | Add-Member -NotePropertyName corruption_type -NotePropertyValue $ct       -Force
        }
        elseif ($c.level_uncertain) {
            # faithful content, but a heading we couldn't level deterministically — structural,
            # not corruption, yet still a call the model must make. Surface it as actionable.
            $c | Add-Member -NotePropertyName fidelity      -NotePropertyValue 'needs_review'          -Force
            $c | Add-Member -NotePropertyName review_reason -NotePropertyValue 'heading_level_unknown' -Force
        }
        elseif ($srt = Get-SoftReviewType $c) {
            # the hard gate is clean, but a SOFT tell fired — structurally valid yet semantically wrong
            # math (a destroyed equation, prose smuggled in \text{}, a dangling operator, a glyph-name
            # leak). Surface it as needs_review: actionable + read by review_document, never a hard reject.
            $c | Add-Member -NotePropertyName fidelity      -NotePropertyValue 'needs_review' -Force
            $c | Add-Member -NotePropertyName review_reason -NotePropertyValue $srt           -Force
        }
        elseif ($c.seam_merge) {
            # the cross-chunk soft tell: this formula's \text{} prose duplicates the adjacent paragraph
            # (Set-SeamMergeFlags set the stored span above). Same needs_review lane as the per-chunk soft band.
            $c | Add-Member -NotePropertyName fidelity      -NotePropertyValue 'needs_review'     -Force
            $c | Add-Member -NotePropertyName review_reason -NotePropertyValue 'prose_seam_merge' -Force
        }
        elseif ([int]($c.math_dirt) -ge 2) {
            # faithful prose carrying un-wrapped inline math (the normalize density∧¬mask signal) — the
            # deterministic wrapper conservatively skipped it; the agent wraps it with judgment. The
            # count rides along as math_dirt for dispatch prioritisation (denser = worse).
            $c | Add-Member -NotePropertyName fidelity      -NotePropertyValue 'needs_review'   -Force
            $c | Add-Member -NotePropertyName review_reason -NotePropertyValue 'unwrapped_math' -Force
        }
        else {
            $c | Add-Member -NotePropertyName fidelity -NotePropertyValue 'faithful' -Force
        }
    }

    $manifest = Write-JsonlStage -Records $chunks.ToArray() -OutputPath $ChunksPath -SourcePath $NodesPath -Stage 'fidelity'

    $suspect = @($chunks | Where-Object { $_.fidelity -eq 'suspect' })
    "fidelity tagged on $($chunks.Count) chunks  ($($suspect.Count) suspect) -> $ChunksPath"
    "--- hotspots by type ---"
    $suspect | Group-Object corruption_type | Sort-Object Count -Descending | ForEach-Object { "  {0,-18} {1}" -f $_.Name, $_.Count }
    return $manifest
}
