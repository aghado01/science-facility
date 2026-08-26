#requires -Version 7.0
<#
  src/enrichment.ps1 — Tier-1 enrichment surfacer (chunk substrate).

  Surfaces unwrapped ASCII-math candidates in faithful prose chunks (post-normalize content),
  buckets each safe-wrap vs lossy, and labels apply_tier (auto | review | escalate) for measurement.
  Does not apply edits — proposals flow through propose_edit → apply like repair.
#>

. "$PSScriptRoot/codex-membrane/normalize.ps1"

$script:RxEnrichmentWrapped = [regex]'\$\$[\s\S]*?\$\$|\$[^$\n]+\$'
$script:EnrichmentBreak      = '.;:'

function Test-EnrichmentValueAtom([string]$Token) {
    return ($Token -match '^[A-Za-z]$' -or $Token -match '^\d+$')
}

function Test-EnrichmentLossyRun([string[]]$Run) {
    for ($i = 1; $i -lt $Run.Count; $i++) {
        if ((Test-EnrichmentValueAtom $Run[$i]) -and (Test-EnrichmentValueAtom $Run[$i - 1])) { return $true }
    }
    return $false
}

function Test-EnrichmentStructuralCue([string[]]$Run) {
    $hasOp = $false; $hasFuncApp = $false
    for ($i = 0; $i -lt $Run.Count; $i++) {
        if (($script:MathFunc -contains $Run[$i]) -or ($Run[$i].Length -eq 1 -and '=<>^_/*+'.Contains($Run[$i]))) { $hasOp = $true }
        if ($i -gt 0 -and ($Run[$i] -eq '(') -and ($Run[$i - 1] -match '^[A-Za-z]$')) { $hasFuncApp = $true }
    }
    return ($hasOp -or $hasFuncApp)
}

function Test-EnrichmentAutoTier([string[]]$Run) {
    if ($Run.Count -lt 2) { return $false }
    $eqIdx = [array]::IndexOf($Run, '=')
    if ($eqIdx -gt 0 -and $eqIdx -lt ($Run.Count - 1)) { return $true }
    $caret = [array]::IndexOf($Run, '^')
    if ($caret -gt 0 -and $caret -lt ($Run.Count - 1)) { return $true }
    $funcHead = ($script:MathFunc -contains $Run[0]) -or ($Run[0] -match '^[A-Za-z]+$' -and $Run[1] -eq '(')
    if ($funcHead -and ($Run -contains '(') -and ($Run -contains ')')) {
        $depth = 0; $ok = $true
        foreach ($t in $Run) {
            if ($t -eq '(') { $depth++ }
            elseif ($t -eq ')') { $depth--; if ($depth -lt 0) { $ok = $false } }
        }
        if ($ok -and $depth -eq 0) { return $true }
    }
    return $false
}

function Get-EnrichmentApplyTier([string]$Bucket, [string[]]$Run) {
    if ($Bucket -eq 'lossy') { return 'escalate' }
    if (Test-EnrichmentAutoTier $Run) { return 'auto' }
    return 'review'
}

function Get-EnrichmentCandidatesFromText([string]$Text) {
    if (-not $Text) { return @() }
    $out   = [System.Collections.Generic.List[object]]::new()
    $prose = Get-MaskedText -Text $Text -Mask (New-Mask $Text $script:RxEnrichmentWrapped)
    foreach ($line in ($prose -split "`n")) {
        $toks = [regex]::Matches($line, '[A-Za-z]+|\d+|\S') | ForEach-Object { $_.Value }
        $run  = [System.Collections.Generic.List[string]]::new()
        $flush = {
            if ($run.Count -ge 2 -and (Test-EnrichmentStructuralCue $run)) {
                $lossy  = Test-EnrichmentLossyRun $run
                $bucket = if ($lossy) { 'lossy' } else { 'safe-wrap' }
                $out.Add([pscustomobject]@{
                    text       = ($run -join ' ')
                    bucket     = $bucket
                    apply_tier = (Get-EnrichmentApplyTier $bucket $run)
                })
            }
            $run.Clear()
        }
        foreach ($t in $toks) {
            if ((Test-MathGlyphToken $t) -and -not $script:EnrichmentBreak.Contains($t)) { $run.Add($t) }
            else { & $flush }
        }
        & $flush
    }
    return $out.ToArray()
}

function Test-EnrichmentChunkEligible($Chunk) {
    if ([string]$Chunk.type -ne 'prose') { return $false }
    if ($Chunk.is_reference) { return $false }
    if ($Chunk.is_furniture) { return $false }
    if ([string]$Chunk.fidelity -ne 'faithful') { return $false }
    if ([int]($Chunk.math_dirt ?? 0) -ge 2) { return $false }
    if (-not $Chunk.content) { return $false }
    return $true
}

function Get-EnrichablesFromChunks($Chunks) {
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($c in $Chunks) {
        if (-not (Test-EnrichmentChunkEligible $c)) { continue }
        foreach ($cand in (Get-EnrichmentCandidatesFromText $c.content)) {
            $out.Add([pscustomobject]@{
                id         = $c.id
                page       = $c.page
                text       = $cand.text
                bucket     = $cand.bucket
                apply_tier = $cand.apply_tier
            })
        }
    }
    return $out.ToArray()
}

function Get-EnrichmentCounts($Candidates) {
    $safe = @($Candidates | Where-Object { $_.bucket -eq 'safe-wrap' })
    $loss = @($Candidates | Where-Object { $_.bucket -eq 'lossy' })
    $auto = @($safe | Where-Object { $_.apply_tier -eq 'auto' })
    $rev  = @($safe | Where-Object { $_.apply_tier -eq 'review' })
    return [pscustomobject]@{
        enrichable      = $Candidates.Count
        safe_wrap       = $safe.Count
        lossy           = $loss.Count
        auto_tier       = $auto.Count
        review_tier     = $rev.Count
        escalate_tier   = $loss.Count
    }
}
