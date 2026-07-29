#Requires -Version 7.5
using namespace System.Collections.Generic
using namespace System.IO
using namespace System.Text
using namespace System.Text.RegularExpressions
<#
.SYNOPSIS
    RepoSnapshot V3 Ignore Compiler — Normalize / Coalesce / Walk / Reduce / Gather-Scatter pipeline.

.DESCRIPTION
    Transforms the flat node array from the crawler's projection into
    immutable per-node compiled ignore state for the filter stage.

    Five-stage pipeline + pruning:
      Stage 0: Normalize     — separator collapse, degenerate rejection
      Stage 1: Coalesce      — per-node source merge, annihilation, anchor-prefix
      Stage 2: Walk          — BFS inheritance with depth-annotated dictionaries
      Stage 3: Reduce        — depth precedence, subsumption heuristic
      Stage 4: Gather-Scatter — signature-keyed regex compilation + scatter

    Two modes (IngestMode — explicit run intent; both run the same five-stage
    machinery; cross-mode pattern params are inert, never errors):
      1. Ignore (default) — sentinel scan + virtual root ignore source
         (IgnoreDefaults + IgnorePatterns + IgnoreOverridePatterns-as-
         negations) merged through nested gitignore semantics; directory
         branch pruning runs. IgnorePatterns and IgnoreOverridePatterns are
         both virtual global ignore sources — containers for positives and
         negations BY CONVENTION (override entries are '!'-prefixed on
         merge; a '!'-prefixed override entry double-negates to a positive).
         Overrides follow canonical gitignore precedence: a file-only
         negation cannot re-include content under an excluded directory —
         negate the directory to rescue a branch.
      2. Selection — the run is expressly about ingesting what is wanted.
         Sentinels are NOT consulted (no scan, no I/O); SelectionPatterns
         compiles as a selection regime through the same five stages
         (negations = un-keep exceptions); match = KEEP at test time;
         directory pruning is skipped (file-targeted keep patterns never
         match directory paths); the post-filter empty-leaf prune cleans up.
         Empty/self-annihilated SelectionPatterns throws (fail-fast).

    Input contract (from crawler Graph — ItemDescriptor identity stamped at
    walk time by rs.core.crawler; this stage is a pure filter and enriches
    nothing):
      @( @{ NodePath = 'src/lib/'; AbsolutePath = 'C:/repo/src/lib/'; NodeDepth = 2;
             Files = @( @{ AbsolutePath = 'C:/repo/src/lib/.gitignore';
                           RelativePath = 'src/lib/.gitignore'; NodePath = 'src/lib/';
                           SizeBytes = 42; LastWriteUtc = [datetime] } ) } )
      IgnoreFiles is built internally from Files via sentinel scan (New-IgnoreCompiler).
      IngestMode and the pattern params are passed separately to New-IgnoreCompiler.

    Output contract (to filter stage):
      @( @{ NodePath = 'src/lib/'; AbsolutePath = 'C:/repo/src/lib/'; NodeDepth = 2;
             CompiledState = @{ Regime = 'Ignore'|'Selection'
                                Positives = [regex]; Exceptions = [regex] } } )  # regex slots may be $null
      Single regime-stamped state slot; TestPath is the sole semantic
      authority (dual truth table on Regime).
#>

# Hard extension blacklist — binary / non-text file types that are never useful
# in a source snapshot. Applied by Invoke-IgnoreFilter before ignore regex passes.
# Caller-supplied ExtensionBlacklist is additive (not replaceable).
$script:HardExtensionBlacklist = [HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
@(
    # Images
    '.png', '.jpg', '.jpeg', '.gif', '.bmp', '.ico', '.svg', '.webp', '.tiff', '.avif',
    # Video / audio
    '.mp4', '.mp3', '.wav', '.mov', '.avi', '.mkv', '.flac', '.ogg', '.webm',
    # Archives
    '.zip', '.gz', '.tar', '.7z', '.rar', '.br', '.zst',
    # Compiled / binary
    '.exe', '.dll', '.pdb', '.obj', '.lib', '.so', '.dylib', '.wasm',
    # Documents
    '.pdf', '.docx', '.xlsx', '.pptx', '.odt', '.ods',
    # Fonts / web assets
    '.woff', '.woff2', '.ttf', '.eot', '.otf',
    # Data / model blobs
    '.bin', '.dat', '.pkl', '.npy', '.npz', '.parquet', '.db', '.sqlite'
) | ForEach-Object { [void]$script:HardExtensionBlacklist.Add($_) }

#region Ignore Compiler — Normalize / Coalesce / Walk / Reduce / Gather-Scatter

class IgnoreCompiler
{

    # ── Retained state ────────────────────────────────────────────────────
    [object[]]$Nodes                           # the node array — mutated through pipeline stages
    [hashtable]$NodeLookup                     # NodePath → node — built once, used by Walk + Prune
    [hashtable]$RegexCache                     # signature → @{Positives=[regex]; Exceptions=[regex]}
    [string]$Regime                            # 'Ignore' | 'Selection' — stamped on every CompiledState
    [List[PSCustomObject]]$SentinelIgnoreFiles # flat aggregate of all sentinel entries found — @{ NodePath; Source; Globs }

    # ── Configuration (immutable after construction) ──────────────────────
    hidden [bool]$HasRun

    # ── Constructor (hidden — use New-IgnoreCompiler factory) ────────────
    # $rootPatterns: the virtual root-level pattern source — in Ignore mode
    # the merged IgnoreDefaults + IgnorePatterns + overrides-as-negations;
    # in Selection mode the SelectionPatterns. Same injection either way —
    # the compile machinery is semantics-neutral; Regime is interpretation.
    hidden IgnoreCompiler([object[]]$flatNodes, [string[]]$rootPatterns, [string]$regime)
    {
        $this.Nodes = $flatNodes
        $this.HasRun = $false
        $this.RegexCache = @{}
        $this.Regime = $regime

        # Build NodePath → node lookup once
        $this.NodeLookup = @{}
        foreach ($node in $this.Nodes)
        {
            $this.NodeLookup[$node.NodePath] = $node
        }

        # Inject virtual root-pattern entry at the front of the root node's IgnoreFiles
        if ($null -ne $rootPatterns -and $rootPatterns.Count -gt 0)
        {
            $virtualEntry = [PSCustomObject]@{ Source = 'RootPatterns'; Globs = $rootPatterns }
            $this.NodeLookup[''].IgnoreFiles.Insert(0, $virtualEntry)
        }
    }

    # ══════════════════════════════════════════════════════════════════════
    # PUBLIC — Run the pipeline and return output array
    # ══════════════════════════════════════════════════════════════════════

    [object[]] Invoke()
    {
        if ($this.HasRun)
        {
            throw [System.InvalidOperationException]::new(
                'IgnoreCompiler.Invoke() has already been called. Create a new instance for a new run.')
        }
        $this.HasRun = $true

        # ── Five-stage pipeline — both regimes, no mode branches inside stages ──
        $this.Normalize()
        $this.Coalesce()

        # Fail-fast (Selection): an empty or self-annihilated selection set is
        # a user error, never a valid request for nothing.
        if ($this.Regime -eq 'Selection')
        {
            $any = $false
            foreach ($node in $this.Nodes)
            {
                if ($node.LocalIgnore.Positives.Count -gt 0) { $any = $true; break }
            }
            if (-not $any)
            {
                throw [System.ArgumentException]::new(
                    'SelectionPatterns is empty or self-annihilated — Selection mode requires a logically non-empty selection set.')
            }
        }

        $this.Walk()
        $this.Reduce()
        $this.CompileRegex()

        # Prune only under Ignore regime: file-targeted keep patterns can never
        # match directory paths, so pruning under Selection would kill subtrees
        # before their files were evaluated. Greedy crawl makes prune a CPU
        # optimization only; the post-filter empty-leaf prune cleans up.
        if ($this.Regime -eq 'Ignore')
        {
            $this.Prune()
        }

        return $this.EmitOutput()
    }

    # ══════════════════════════════════════════════════════════════════════
    # STATIC — Filter-time path test (stateless, used externally)
    # ══════════════════════════════════════════════════════════════════════

    # The single semantic authority — dual truth table on CompiledState.Regime.
    # Returns $true when the path is EXCLUDED from results. Exceptions keep one
    # meaning in both regimes: undo the primary verdict (rescue under Ignore;
    # un-keep under Selection).
    static [bool] TestPath([string]$relativePath, [object]$nodeState)
    {
        $state = if ($null -ne $nodeState.PSObject.Properties['CompiledState']) { $nodeState.CompiledState } else { $null }

        if ($null -eq $state -or $null -eq $state.Positives)
        {
            # No compiled patterns: Ignore → keep all; Selection → exclude all
            # (unreachable under Selection: fail-fast guards the empty set).
            if ($null -ne $state -and $state.Regime -eq 'Selection') { return $true }
            return $false
        }

        if ($state.Regime -eq 'Selection')
        {
            if (-not $state.Positives.IsMatch($relativePath)) { return $true }    # unmatched → excluded
            if ($null -ne $state.Exceptions -and $state.Exceptions.IsMatch($relativePath)) { return $true }  # un-keep
            return $false                                                          # selected
        }

        # Ignore regime
        if (-not $state.Positives.IsMatch($relativePath)) { return $false }        # unmatched → kept
        if ($null -ne $state.Exceptions -and $state.Exceptions.IsMatch($relativePath)) { return $false }     # rescued
        return $true                                                               # ignored
    }

    # ══════════════════════════════════════════════════════════════════════
    # PIPELINE STAGES
    # ══════════════════════════════════════════════════════════════════════

    # ── Stage 0: Normalize all glob patterns across all nodes ─────────────
    hidden [void] Normalize()
    {
        foreach ($node in $this.Nodes)
        {
            if (-not $node.IgnoreFiles) { continue }
            foreach ($file in $node.IgnoreFiles)
            {
                $file.Globs = @($file.Globs | ForEach-Object {
                        $this.NormalizeGlob($_)
                    } | Where-Object { $null -ne $_ })
            }
        }
    }

    # ── Stage 1: Coalesce per-node sources + anchor-prefix injection ──────
    hidden [void] Coalesce()
    {
        foreach ($node in $this.Nodes)
        {
            $ignoreFiles = if ($node.IgnoreFiles) { $node.IgnoreFiles } else { @() }

            # Merge all sources into partitioned positives/exceptions
            $positives = [HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            $negations = [HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

            foreach ($file in $ignoreFiles)
            {
                foreach ($glob in $file.Globs)
                {
                    $trimmed = $glob.Trim()
                    if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }
                    if ($trimmed.StartsWith('#')) { continue }

                    if ($trimmed.StartsWith('!'))
                    {
                        [void]$negations.Add($trimmed.Substring(1))
                    }
                    else
                    {
                        [void]$positives.Add($trimmed)
                    }
                }
            }

            # Same-node exact-match annihilation
            $annihilated = [List[string]]::new()
            foreach ($neg in $negations)
            {
                if ($positives.Contains($neg))
                {
                    $annihilated.Add($neg)
                }
            }
            foreach ($a in $annihilated)
            {
                [void]$positives.Remove($a)
                [void]$negations.Remove($a)
            }

            $posArray = @($positives)
            $exArray = @($negations)

            # Anchor-prefix: prepend NodePath to anchored patterns from non-root nodes
            if ($node.NodePath -and $node.NodePath -ne '')
            {
                $posArray = @($posArray | ForEach-Object {
                        $p = $_
                        $hadLeadingSlash = $p.StartsWith('/')
                        if ($hadLeadingSlash) { $p = $p.Substring(1) }
                        $stripped = $p.TrimEnd('/')
                        if ($hadLeadingSlash -or $stripped.Contains('/'))
                        {
                            "$($node.NodePath)$p"
                        }
                        else { $p }
                    })
                $exArray = @($exArray | ForEach-Object {
                        $p = $_
                        $hadLeadingSlash = $p.StartsWith('/')
                        if ($hadLeadingSlash) { $p = $p.Substring(1) }
                        $stripped = $p.TrimEnd('/')
                        if ($hadLeadingSlash -or $stripped.Contains('/'))
                        {
                            "$($node.NodePath)$p"
                        }
                        else { $p }
                    })
            }

            $node | Add-Member -NotePropertyName 'LocalIgnore' -NotePropertyValue @{
                Positives  = $posArray
                Exceptions = $exArray
            } -Force
        }
    }

    # ── Stage 2: Walk — BFS inheritance with depth-annotated dictionaries ─
    hidden [void] Walk()
    {
        $sorted = $this.Nodes | Sort-Object -Property NodeDepth

        foreach ($node in $sorted)
        {
            $depth = $node.NodeDepth

            $parentPath = $this.GetParentPath($node.NodePath)
            $parent = if ($null -ne $parentPath -and $this.NodeLookup.ContainsKey($parentPath))
            {
                $this.NodeLookup[$parentPath]
            }
            else { $null }

            # Inherit from parent or start fresh
            if ($parent -and $parent.ActiveIgnores)
            {
                $node | Add-Member -NotePropertyName 'ActiveIgnores' -NotePropertyValue (
                    [Dictionary[string, int]]::new(
                        $parent.ActiveIgnores, [StringComparer]::OrdinalIgnoreCase)
                ) -Force
                $node | Add-Member -NotePropertyName 'ActiveExceptions' -NotePropertyValue (
                    [Dictionary[string, int]]::new(
                        $parent.ActiveExceptions, [StringComparer]::OrdinalIgnoreCase)
                ) -Force
            }
            else
            {
                $node | Add-Member -NotePropertyName 'ActiveIgnores' -NotePropertyValue (
                    [Dictionary[string, int]]::new([StringComparer]::OrdinalIgnoreCase)
                ) -Force
                $node | Add-Member -NotePropertyName 'ActiveExceptions' -NotePropertyValue (
                    [Dictionary[string, int]]::new([StringComparer]::OrdinalIgnoreCase)
                ) -Force
            }

            # Apply local positives
            if ($node.LocalIgnore.Positives)
            {
                foreach ($glob in $node.LocalIgnore.Positives)
                {
                    $node.ActiveIgnores[$glob] = $depth
                }
            }

            # Apply local exceptions with cross-depth annihilation
            if ($node.LocalIgnore.Exceptions)
            {
                foreach ($glob in $node.LocalIgnore.Exceptions)
                {
                    if ($node.ActiveIgnores.ContainsKey($glob))
                    {
                        [void]$node.ActiveIgnores.Remove($glob)
                    }
                    $node.ActiveExceptions[$glob] = $depth
                }
            }
        }
    }

    # ── Stage 3: Reduce — depth precedence ────────────────────────────────
    hidden [void] Reduce()
    {
        foreach ($node in $this.Nodes)
        {
            $survivingExceptions = [List[string]]::new()

            foreach ($exKvp in $node.ActiveExceptions.GetEnumerator())
            {
                $exGlob = $exKvp.Key
                $exDepth = $exKvp.Value
                $dominated = $false

                foreach ($igKvp in $node.ActiveIgnores.GetEnumerator())
                {
                    if ($igKvp.Value -gt $exDepth)
                    {
                        if ($this.GlobSubsumes($igKvp.Key, $exGlob))
                        {
                            $dominated = $true
                            break
                        }
                    }
                }

                if (-not $dominated)
                {
                    $survivingExceptions.Add($exGlob)
                }
            }

            $node | Add-Member -NotePropertyName 'EffectivePositives' -NotePropertyValue @($node.ActiveIgnores.Keys) -Force
            $node | Add-Member -NotePropertyName 'EffectiveExceptions' -NotePropertyValue @($survivingExceptions) -Force
        }
    }

    # ── Stage 4: Gather-scatter regex compilation ─────────────────────────
    hidden [void] CompileRegex()
    {
        foreach ($node in $this.Nodes)
        {
            # Signature = deterministic key for cache: sorted positives + separator + sorted exceptions
            $posSorted = ($node.EffectivePositives | Sort-Object) -join '|'
            $exSorted = ($node.EffectiveExceptions | Sort-Object) -join '|'
            $signature = "$posSorted||$exSorted"

            if (-not $this.RegexCache.ContainsKey($signature))
            {
                $this.RegexCache[$signature] = @{
                    Positives  = $this.CompileGlobs($node.EffectivePositives)
                    Exceptions = $this.CompileGlobs($node.EffectiveExceptions)
                }
            }

            # Single regime-stamped state slot — filter-time code needs no
            # out-of-band mode knowledge (TestPath reads Regime from here).
            $cached = $this.RegexCache[$signature]
            $node | Add-Member -NotePropertyName 'CompiledState' -NotePropertyValue (@{
                    Regime     = $this.Regime
                    Positives  = $cached.Positives
                    Exceptions = $cached.Exceptions
                }) -Force
        }
    }

    # ── Post-compile: Prune ignored directory branches ────────────────────
    hidden [void] Prune()
    {
        $pruned = [HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

        $sorted = $this.Nodes | Sort-Object -Property NodeDepth

        foreach ($node in $sorted)
        {
            if ($node.NodeDepth -eq 0) { continue }

            # Check if any ancestor is already pruned
            $ancestorPath = $this.GetParentPath($node.NodePath)
            while ($null -ne $ancestorPath)
            {
                if ($pruned.Contains($ancestorPath)) { break }
                $ancestorPath = $this.GetParentPath($ancestorPath)
            }
            if ($null -ne $ancestorPath -and $pruned.Contains($ancestorPath))
            {
                [void]$pruned.Add($node.NodePath)
                continue
            }

            # Test this directory against its direct parent's compiled state
            $directParent = $this.GetParentPath($node.NodePath)
            if ($null -ne $directParent -and $this.NodeLookup.ContainsKey($directParent))
            {
                $parentNode = $this.NodeLookup[$directParent]
                if ([IgnoreCompiler]::TestPath($node.NodePath, $parentNode))
                {
                    [void]$pruned.Add($node.NodePath)
                }
            }
        }

        # Remove pruned nodes from the array and refresh lookup
        $this.Nodes = @($this.Nodes | Where-Object { -not $pruned.Contains($_.NodePath) })
        $this.NodeLookup = @{}
        foreach ($node in $this.Nodes)
        {
            $this.NodeLookup[$node.NodePath] = $node
        }
    }

    # ── Emit clean output (strip working properties) ──────────────────────
    hidden [object[]] EmitOutput()
    {
        $results = foreach ($node in $this.Nodes)
        {
            [PSCustomObject]@{
                NodePath      = $node.NodePath
                AbsolutePath  = $node.AbsolutePath
                NodeDepth     = $node.NodeDepth
                CompiledState = $node.CompiledState
            }
        }
        return $results
    }

    # ══════════════════════════════════════════════════════════════════════
    # PURE UTILITIES (hidden)
    # ══════════════════════════════════════════════════════════════════════

    # ── Glob pattern normalizer ───────────────────────────────────────────
    hidden [string] NormalizeGlob([string]$raw)
    {
        $p = $raw.Trim()
        if ([string]::IsNullOrWhiteSpace($p)) { return $null }

        $prefix = ''
        if ($p.StartsWith('!'))
        {
            $prefix = '!'
            $p = $p.Substring(1)
        }
        elseif ($p.StartsWith('#'))
        {
            return $raw  # pass comments through unchanged
        }

        # Structural separator collapse
        $p = [regex]::Replace($p, '[/\\]+', '/')

        if ([string]::IsNullOrWhiteSpace($p) -or $p -eq '/')
        {
            Write-Warning "IgnoreCompiler: discarding degenerate pattern '$raw'"
            return $null
        }

        return "${prefix}${p}"
    }

    # ── Glob → regex translator (char-by-char) ───────────────────────────
    hidden [string] TranslateGlob([string]$glob, [bool]$anchored)
    {
        $dirOnly = $glob.EndsWith('/')
        if ($dirOnly) { $glob = $glob.TrimEnd('/') }

        if ($glob.StartsWith('/'))
        {
            $glob = $glob.TrimStart('/')
            $anchored = $true
        }

        $chars = $glob.ToCharArray()
        $len = $chars.Count
        $sb = [StringBuilder]::new($len * 2)
        $i = 0

        while ($i -lt $len)
        {
            $c = $chars[$i]
            switch ($c)
            {
                '*'
                {
                    if (($i + 1) -lt $len -and $chars[$i + 1] -eq '*')
                    {
                        $i += 2
                        if ($i -lt $len -and $chars[$i] -eq '/')
                        {
                            $i++
                            [void]$sb.Append('(.+/)?')
                        }
                        elseif ($i -eq $len)
                        {
                            [void]$sb.Append('.*')
                        }
                        else
                        {
                            [void]$sb.Append('.*')
                        }
                        continue
                    }
                    [void]$sb.Append('[^/]*')
                    $i++
                }
                '?'
                {
                    [void]$sb.Append('[^/]')
                    $i++
                }
                '['
                {
                    [void]$sb.Append('[')
                    $i++
                    if ($i -lt $len -and $chars[$i] -eq '!')
                    {
                        [void]$sb.Append('^')
                        $i++
                    }
                    while ($i -lt $len -and $chars[$i] -ne ']')
                    {
                        if ($chars[$i] -eq '\' -and ($i + 1) -lt $len)
                        {
                            [void]$sb.Append('\')
                            $i++
                            [void]$sb.Append($chars[$i])
                            $i++
                        }
                        else
                        {
                            [void]$sb.Append($chars[$i])
                            $i++
                        }
                    }
                    if ($i -lt $len)
                    {
                        [void]$sb.Append(']')
                        $i++
                    }
                }
                '\'
                {
                    $i++
                    if ($i -lt $len)
                    {
                        [void]$sb.Append([regex]::Escape([string]$chars[$i]))
                    }
                    $i++
                }
                '.' { [void]$sb.Append('\.'); $i++ }
                '+' { [void]$sb.Append('\+'); $i++ }
                '^' { [void]$sb.Append('\^'); $i++ }
                '$' { [void]$sb.Append('\$'); $i++ }
                '{' { [void]$sb.Append('\{'); $i++ }
                '}' { [void]$sb.Append('\}'); $i++ }
                '(' { [void]$sb.Append('\('); $i++ }
                ')' { [void]$sb.Append('\)'); $i++ }
                '|' { [void]$sb.Append('\|'); $i++ }
                '/' { [void]$sb.Append('/'); $i++ }
                default
                {
                    [void]$sb.Append($c)
                    $i++
                }
            }
        }

        $pattern = $sb.ToString()

        if ($anchored)
        {
            $pattern = "^$pattern"
        }
        else
        {
            $pattern = "(^|/)$pattern"
        }

        if ($dirOnly)
        {
            $pattern = "$pattern/"
        }
        else
        {
            $pattern = "$pattern$"
        }

        return $pattern
    }

    # ── Batch glob array → compiled [regex] ───────────────────────────────
    hidden [regex] CompileGlobs([string[]]$globs)
    {
        if (-not $globs -or $globs.Count -eq 0) { return $null }

        $fragments = foreach ($g in $globs)
        {
            $stripped = $g.TrimEnd('/')
            $anch = $stripped.Contains('/')
            $this.TranslateGlob($g, $anch)
        }

        $combined = '(' + ($fragments -join '|') + ')'
        return [regex]::new($combined,
            [RegexOptions]::Compiled -bor [RegexOptions]::IgnoreCase)
    }

    # ── Parent path derivation ────────────────────────────────────────────
    # Return type is [object], NOT [string]: the null-vs-'' distinction is
    # load-bearing ('' = parent is root; $null = root has no parent — the
    # ancestor-walk terminator in Walk/Prune). A [string] return coerces
    # $null to '', which made Prune's ancestor loop infinite. The C# lineage
    # (repo-audit GetParentPath) returns string? for exactly this reason.
    hidden [object] GetParentPath([string]$nodePath)
    {
        if ([string]::IsNullOrEmpty($nodePath) -or $nodePath -eq '/') { return $null }

        $trimmed = $nodePath.TrimEnd('/')
        $lastSlash = $trimmed.LastIndexOf('/')

        if ($lastSlash -lt 0)
        {
            return ''  # single segment like 'src/' → root ''
        }

        return $trimmed.Substring(0, $lastSlash + 1)
    }

    # ── Glob subsumption heuristic ────────────────────────────────────────
    hidden [bool] GlobSubsumes([string]$broad, [string]$narrow)
    {
        if ($broad -eq $narrow) { return $true }

        try
        {
            $broadAnchored = $broad.TrimEnd('/').Contains('/')
            $regexFragment = $this.TranslateGlob($broad, $broadAnchored)
            $regex = [regex]::new($regexFragment, [RegexOptions]::IgnoreCase)
            $narrowLiteral = $narrow.TrimEnd('/')
            return $regex.IsMatch($narrowLiteral)
        }
        catch
        {
            return $false
        }
    }
}

# ── Factory function ──────────────────────────────────────────────────────
function New-IgnoreCompiler
{
    <#
    .SYNOPSIS
        Factory: creates and invokes an IgnoreCompiler instance.

    .DESCRIPTION
        Accepts the crawler graph (Dictionary or flat array) plus IngestMode and
        the mode's pattern params. Cross-mode pattern params are INERT — never
        errors — so ergonomic defaults can stay populated while switching modes.

    .PARAMETER CrawlerGraph
        Crawler graph: either Dictionary[string, PSCustomObject] keyed by NodePath,
        or a flat object[] of node objects. Each node must carry NodePath, AbsolutePath,
        NodeDepth, and Files. IgnoreFiles is built internally by the sentinel scan.

    .PARAMETER IngestMode
        'Ignore' (default) — canonical ignore-file-driven ingestion.
        'Selection' — the run is expressly about ingesting what is wanted:
        sentinels are not consulted (no scan, no I/O); SelectionPatterns is the
        selection regime; IgnoreDefaults/IgnorePatterns/IgnoreOverridePatterns
        are not consulted.

    .PARAMETER SentinelFileNames
        Ignore mode only. Names of ignore files to detect in each node's Files
        list and parse into IgnoreFiles entries. Defaults to
        @('.gitignore', '.snapignore'). Pass @() to skip sentinel discovery.

    .PARAMETER IgnoreDefaults
        Ignore mode only. Default glob patterns prepended to IgnorePatterns.
        Defaults to @('.snapshot/', '.git/', 'node_modules/'). Pass @() to
        suppress. Treated identically to IgnorePatterns — visible, overridable.

    .PARAMETER IgnorePatterns
        Ignore mode only. Caller-supplied root-level ignore globs — a VIRTUAL
        ROOT IGNORE FILE merged with the sentinels and processed through the
        full nested semantics. Negations ('!x') are valid here, exactly as in
        a real ignore file.

    .PARAMETER IgnoreOverridePatterns
        Ignore mode only. Globs that countermand ignore materials — merged into
        the same virtual root source as NEGATIONS by convention (each entry is
        '!'-prefixed; an already-'!'-prefixed entry double-negates into a
        positive ignore — silly but admissible). Follows canonical gitignore
        precedence: a file-only negation cannot re-include content under an
        excluded directory; negate the directory (e.g. 'dist/') to rescue a
        branch and its contents.

    .PARAMETER SelectionPatterns
        Selection mode only. The selection criteria, in canonical glob
        semantics; negations are un-keep exceptions ("select *.ps1 except
        tests/"). An empty or self-annihilated set throws (fail-fast).

    .OUTPUTS
        [PSCustomObject] @{
            CompiledNodes     = object[]  — node array; pass to Invoke-IgnoreFilter -CompiledNodes
            SentinelIgnoreFiles = PSCustomObject[]  — @{ NodePath; Source; Globs } for all sentinel files found
        }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$CrawlerGraph,
        [ValidateSet('Ignore', 'Selection')]
        [string]$IngestMode = 'Ignore',
        [string[]]$IgnoreDefaults = @('.snapshot/', '.git/', 'node_modules/'),
        [string[]]$IgnorePatterns = $null,
        [string[]]$IgnoreOverridePatterns = $null,
        [string[]]$SelectionPatterns = $null,
        [string[]]$SentinelFileNames = @('.gitignore', '.snapignore')
    )

    if ($CrawlerGraph -is [System.Collections.IDictionary])
    {
        $flatNodes = @($CrawlerGraph.Values)
    }
    else
    {
        $flatNodes = @($CrawlerGraph)
    }

    # ── Assemble the virtual root pattern source per mode ─────────────────────
    # Ignore mode: IgnoreDefaults + IgnorePatterns + overrides-as-negations —
    # one virtual root ignore file; the engine's merge/inheritance/annihilation
    # machinery treats all three identically (containers by convention).
    # Selection mode: SelectionPatterns only; ignore-side params are inert.
    if ($IngestMode -eq 'Selection')
    {
        $combinedIgnorePatterns = @($SelectionPatterns) | Where-Object { $_ }
        $SentinelFileNames = @()   # sentinels are not consulted in Selection mode
    }
    else
    {
        $overridesAsNegations = @(foreach ($p in @($IgnoreOverridePatterns))
            {
                if ([string]::IsNullOrWhiteSpace($p)) { continue }
                $t = $p.Trim()
                if ($t.StartsWith('!')) { $t.Substring(1) }   # double negation → positive ignore (admissible)
                else { "!$t" }
            })
        $combinedIgnorePatterns = @($IgnoreDefaults) + @($IgnorePatterns) + $overridesAsNegations | Where-Object { $_ }
    }

    # ── Stamp IgnoreFiles on all nodes — always required by the constructor ──────
    foreach ($node in $flatNodes)
    {
        $node | Add-Member -NotePropertyName 'IgnoreFiles' -NotePropertyValue ([List[PSCustomObject]]::new()) -Force
    }

    # ── Sentinel scan — populate IgnoreFiles from Files list ──────────────────
    # Short-circuits entirely when SentinelFileNames is empty — no I/O, no Files
    # rebuild, Normalize/Coalesce skip the sentinel path (empty IgnoreFiles lists).
    # Sentinels are consumed as configuration and pruned from Files in the same pass.
    # Failures are non-fatal: logged as warnings, file is still pruned from Files.
    $sentinelAggregate = [List[PSCustomObject]]::new()
    if ($SentinelFileNames.Count -gt 0)
    {
        foreach ($node in $flatNodes)
        {
            $remainingFiles = [List[PSCustomObject]]::new()
            foreach ($f in $node.Files)
            {
                $fname = [Path]::GetFileName($f.AbsolutePath)
                if ($fname -notin $SentinelFileNames)
                {
                    $remainingFiles.Add($f)
                    continue
                }
                try
                {
                    $raw = [File]::ReadAllLines($f.AbsolutePath)
                    $globs = foreach ($line in $raw)
                    {
                        $t = $line.TrimEnd()
                        if ($t.Length -eq 0 -or $t[0] -eq '#') { continue }
                        $t
                    }
                    $entry = [PSCustomObject]@{
                        Source = $fname
                        Globs  = [string[]]$globs
                    }
                    $node.IgnoreFiles.Add($entry)
                    $sentinelAggregate.Add([PSCustomObject]@{
                            NodePath = $node.NodePath
                            Source   = $fname
                            Globs    = [string[]]$globs
                        })
                }
                catch
                {
                    Write-Warning "IgnoreCompiler: failed to read sentinel '$($f.AbsolutePath)' — $($_.Exception.GetType().Name)"
                }
            }
            $node.Files = $remainingFiles
        }
    }

    $compiler = [IgnoreCompiler]::new($flatNodes, $combinedIgnorePatterns, $IngestMode)
    $compiler.SentinelIgnoreFiles = $sentinelAggregate
    return [PSCustomObject]@{
        CompiledNodes       = $compiler.Invoke()
        SentinelIgnoreFiles = $sentinelAggregate
    }
}

# ── Standalone filter utility ────────────────────────────────────────────
function Test-PathIgnored
{
    <#
    .SYNOPSIS
        Tests whether a relative path is excluded based on compiled node state.
        Delegates to [IgnoreCompiler]::TestPath() — the dual truth table over
        the regime-stamped CompiledState (Ignore: match = excluded unless
        rescued; Selection: non-match = excluded, exception un-keeps).

    .PARAMETER RelativePath
        Forward-slash normalized relative path to test.

    .PARAMETER NodeState
        Node carrying CompiledState = @{ Regime; Positives; Exceptions }.

    .OUTPUTS
        [bool] — $true if the path should be EXCLUDED from the snapshot.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$RelativePath,

        [Parameter(Mandatory)]
        [object]$NodeState
    )

    return [IgnoreCompiler]::TestPath($RelativePath, $NodeState)
}

#endregion

# ══════════════════════════════════════════════════════════════════════════
# FILTERING — join + apply
# ══════════════════════════════════════════════════════════════════════════

function Invoke-IgnoreFilter
{
    <#
    .SYNOPSIS
        Joins compiled ignore nodes with the crawler graph, pre-filters by size
        and extension, and applies ignore rules in a single pass. Pure filter —
        consumes the crawler-stamped identity contract, enriches nothing.

    .DESCRIPTION
        Two-phase operation:
          1. Join + metadata pre-filter — for each surviving compiled node, look up
             the crawler's original node by NodePath and apply the optional
             MaxSizeBytes ceiling and extension blacklist. Both filters operate
             on crawler metadata (SizeBytes, file extension) — no I/O required.
             Rejected files are collected in Skipped with a typed Reason.
          2. Filter — walk the joined dictionary, apply compiled regex state
             to each file's RelativePath via .Where(). ExecutiveOverride has
             inverted semantics (match = KEEP); normal pipeline ignores on
             Positives match unless rescued by Exceptions match.

        RelativePath arrives on every file entry from the crawler (ItemDescriptor
        identity is stamped once, at walk time — see rs.core.crawler path
        doctrine); this stage fails fast if fed a pre-contract graph.
        Both metadata filters (size, extension) belong here because this stage
        already holds per-file metadata and operates before any I/O — eliminating
        unwanted files at the earliest possible point, before ignore regex passes
        and before pruning.

    .PARAMETER CompiledNodes
        Output from New-IgnoreCompiler:
          @( @{ NodePath; AbsolutePath; NodeDepth; CompiledState } )
        CompiledState = @{ Regime; Positives; Exceptions } — regime-stamped;
        TestPath interprets it (dual truth table).

    .PARAMETER CrawlerGraph
        The full crawler graph dictionary (NodePath → node), or flat array.
        Each node must carry a Files property of ItemDescriptor identity records:
        @{ AbsolutePath; RelativePath; NodePath; SizeBytes; LastWriteUtc }.

    .PARAMETER MaxSizeBytes
        Optional size ceiling in bytes. Files with SizeBytes exceeding this value
        are excluded and reported in the Skipped output. 0 = no ceiling (default).

    .PARAMETER ExtensionBlacklist
        Additional extensions to reject beyond the hard defaults (additive, not replaceable).
        Include the leading dot: @('.lock', '.min.js').
        Hard defaults cover images, video, audio, archives, compiled binaries, documents,
        fonts, and data blobs — see $script:HardExtensionBlacklist.

    .OUTPUTS
        [PSCustomObject] @{
            Graph   = [Dictionary[string, PSCustomObject]]  — surviving nodes keyed by NodePath
            Skipped = [PSCustomObject[]]  — @{ Path; Reason; ... } (FileTooLarge or ExtensionBlacklisted)
        }
        Graph values: @{ NodePath; AbsolutePath; NodeDepth; Files; CompiledState }
        Files arrays contain only surviving files (identity fields untouched).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]]$CompiledNodes,

        [Parameter(Mandatory)]
        [object]$CrawlerGraph,

        [long]$MaxSizeBytes = 0,
        [string[]]$ExtensionBlacklist = $null
    )

    # Normalize CrawlerGraph to a dictionary if passed as flat array
    if ($CrawlerGraph -is [System.Collections.IEnumerable] -and $CrawlerGraph -isnot [System.Collections.IDictionary])
    {
        $graphLookup = [Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
        foreach ($node in $CrawlerGraph)
        {
            $graphLookup[$node.NodePath] = $node
        }
    }
    else
    {
        $graphLookup = $CrawlerGraph
    }

    $result = [Dictionary[string, PSCustomObject]]::new([System.StringComparer]::Ordinal)
    $skipped = [List[PSCustomObject]]::new()

    # Build effective extension blacklist once — hard defaults + caller additions.
    $extBlacklist = [HashSet[string]]::new($script:HardExtensionBlacklist, [StringComparer]::OrdinalIgnoreCase)
    if ($ExtensionBlacklist)
    {
        foreach ($e in $ExtensionBlacklist) { [void]$extBlacklist.Add($e) }
    }

    #Region Filter file lists in joined nodes
    foreach ($compiled in $CompiledNodes)
    {
        $np = $compiled.NodePath
        $source = $graphLookup[$np]
        if ($null -eq $source) { continue }

        # Apply metadata pre-filters (size + extension) in one pass.
        # No I/O — all decisions are based on crawler-supplied metadata.
        # Identity (incl. RelativePath) is crawler-stamped; fail fast on a
        # pre-contract graph rather than silently matching against $null.
        $preFiltered = [List[object]]::new()
        foreach ($f in $source.Files)
        {
            if ($null -eq $f.PSObject.Properties['RelativePath'])
            {
                throw "Invoke-IgnoreFilter: file entry '$($f.AbsolutePath)' lacks RelativePath — input must be a crawler graph carrying the ItemDescriptor identity contract (rs.core.crawler stamps identity at walk time)."
            }
            if ($MaxSizeBytes -gt 0 -and $f.SizeBytes -gt $MaxSizeBytes)
            {
                $skipped.Add([PSCustomObject]@{ Path = $f.AbsolutePath; Reason = 'FileTooLarge'; SizeBytes = $f.SizeBytes })
                continue
            }
            $ext = [Path]::GetExtension($f.AbsolutePath)
            if ($ext -and $extBlacklist.Contains($ext))
            {
                $skipped.Add([PSCustomObject]@{ Path = $f.AbsolutePath; Reason = 'ExtensionBlacklisted'; Extension = $ext })
                continue
            }
            $preFiltered.Add($f)
        }

        $joined = [PSCustomObject]@{
            NodePath      = $source.NodePath
            AbsolutePath  = $source.AbsolutePath
            NodeDepth     = $source.NodeDepth
            Files         = $preFiltered.ToArray()
            CompiledState = $compiled.CompiledState
        }

        # ── Phase 2: Filter files in-place ──────────────────────────────
        # TestPath is the single semantic authority (dual truth table on the
        # regime-stamped state) — no inline semantics duplication here.
        $joined.Files = @($joined.Files.Where({
                    -not [IgnoreCompiler]::TestPath($_.RelativePath, $joined)
                }))

        $result[$np] = $joined
    }

    # ── Post-filter leaf prune: drop nodes with no surviving files ────
    # Directory-level pruning already removed ignored branches. This catches
    # leaves that survive structurally but lose all files to per-file rules.
    $emptyLeaves = @($result.Keys).Where({
            $n = $result[$_]
            $n.Files.Count -eq 0 -and
            -not @($result.Keys).Where({
                    $_ -ne $n.NodePath -and $_.StartsWith($n.NodePath, [System.StringComparison]::Ordinal)
                }, 'First').Count
        })
    # [void]: Dictionary.Remove returns bool — unsuppressed it leaks into the
    # pipeline and corrupts the function's return value into an array.
    foreach ($leaf in $emptyLeaves) { [void]$result.Remove($leaf) }

    return [PSCustomObject]@{
        Graph   = $result
        Skipped = $skipped.ToArray()
    }
}

# Please sort exports alphabetically within each section.
Export-ModuleMember -Function @(
    'Invoke-IgnoreFilter'
    'New-IgnoreCompiler'
    'Test-PathIgnored'
)
