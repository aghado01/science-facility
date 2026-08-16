#Requires -Version 7.5

using namespace System.Collections.Generic

<#
.SYNOPSIS
    RepoSnapshot V3 assemble stage — collates colonel dispatch results into
    the in-memory IR (the successor of the LTS JSON monolith as a data
    structure, never as an artifact).

.DESCRIPTION
    Design: issues/reposnapshot/design/rs.core.assemble-design.md (ownership map, monolith
    inventory, open element model, operation-order doctrine, payload
    doctrine). Assemble is a STAGE, not a chain processor: collation is
    cross-item. It relates to the stage sequence as rs-attributes relates to
    the chain — a read-only tail that mutates nothing and adds no row-level
    information.

    Fixed internal phase sequence (config selects members, implementation
    owns sequence — format-ws doctrine):

      adapt   track adapter: results → entry candidates (Code: 1 → 1)
      route   entry vs diagnostics (lean-payload policy by default)
      derive  Elements declaration + counts (post-route, so skips don't
              pollute coverage)
      stamp   Header last (EntryCount/Elements need final entries)

    Ownership (what this module contains vs what it consumes):
      - Macro-structure (Header/Entries/Skipped/Diagnostics; phase order) —
        convention-in-code, HERE.
      - Derived facts (EntryCount, Elements) — computed HERE; observational
        only.
      - Row-level truth (bag contents, content form, row order) — the
        chain's; inherited, never re-decided. IR order = CANONICAL INGESTED
        ORDER (store order); all sorting/subsorting/grouping is the
        emission-side arrangement layer.
      - Run-level truth (RunStamp, Root, GeneratorVersion, ConfigEcho, …) —
        RunContext, stamped verbatim, never computed.
      - Policy — the two parameter slots (Adapter, EntryRouting).
      - View concerns (artifact layout, wire naming, arrangement, idx) —
        absent from the IR.

    Open element model: entries are self-describing property bags — the
    guaranteed core (RelativePath, NodePath, LastWriteUtc, Content) plus
    whatever the chain attached. Assemble has NO per-element code branches
    and never projects to a fixed column set; Header.Elements declares
    observed per-element presence counts (payload self-description +
    coverage diagnostics). A new enrichment processor's element flows
    through with zero changes here.

    Stage contract: schema/assemble.schema.json (in = what is read from the
    envelope and each bag; out = what an entry IS). Read at import:
      out.entry.core    → guaranteed on every entry; not counted in Elements.
      out.entry.exclude → stripped from entry bags.
      anything else     → element (open element model; unlisted = element).
      ReadError — routed to Diagnostics under LeanPayload; retained in the
        bag under KeepContentless (a content-less entry must say why).

    NOT excluded, under review — `Encoding` (open item, 2026-08-09): file-read
      stamps it on every descriptor, nothing excludes it, so it rides into
      every entry bag and is counted as a fully-present element. But it is
      currently a CONSTANT decode policy, not a per-file measurement (see
      processors/file-read.ps1) — a run-level fact repeated once per entry.
      Header, not entry, is its home while that stays true; per-entry becomes
      correct only if source-encoding detection lands and files genuinely
      differ. Deliberately NOT fixed here: the exclusion list is a
      macro-convention with a golden test behind it, and the disposition is
      entangled with the serializer's emission-encoding declaration (ledger
      #17). Filed in the consolidation plan §B.

    Input contract (from the absent admiral / interim harness —
    build-against-absent-admiral rule):
      DispatchOutput — @{ Results; Skipped; Errors; Warnings; Budget; Timing }
        (the envelope produced by Invoke-Ingest; Results index-stable in
        ingested order).
      RunContext — optional run-level header material (RunStamp, Root,
        GeneratorVersion, ConfigEcho, Timing, Environment, GitHistory, …).
        Stamped into Header verbatim. EntryCount and Elements are RESERVED
        (assemble-derived); a RunContext carrying either throws.

    Output contract (the IR):
      [PSCustomObject] @{
          Header      — RunContext fields + EntryCount + Elements
          Entries     — open property bags, canonical ingested order
          Skipped     — DispatchOutput.Skipped pass-through (pre-chain skips)
          Diagnostics — @{ Routed; Errors; Warnings } (lean-payload routing
                        records + dispatch streams). Feed for the diagnostic
                        sidecar (payload doctrine) — never rendered into
                        payloads.
      }
#>

# =============================================================================
# Stage contract — schema/assemble.schema.json. This module reads its OWN
# contract once at import: out.entry.core (guaranteed fields, not counted in
# Elements) and out.entry.exclude (dropped from bags). Missing/unparseable file
# fails the import loudly rather than silently emptying the exclusion set.
# =============================================================================
$script:Contract = Get-Content -LiteralPath "$PSScriptRoot/schema/assemble.schema.json" -Raw |
    ConvertFrom-Json -AsHashtable
$script:CoreFields = @($script:Contract.out.entry.core.Keys)
$script:ExcludedFields = @($script:Contract.out.entry.exclude)

# =============================================================================
# PUBLIC — Invoke-Assemble
# =============================================================================

function Invoke-Assemble
{
    <#
    .SYNOPSIS
        Collates a colonel dispatch envelope into the snapshot IR.

    .PARAMETER DispatchOutput
        The dispatch envelope (Invoke-Ingest output shape). Results must be
        present; Skipped/Errors/Warnings default to empty when absent.

    .PARAMETER RunContext
        Optional run-level header material, stamped verbatim into Header.
        EntryCount and Elements are reserved names (assemble-derived).

    .PARAMETER Adapter
        Track adapter. 'Code' (default): one result → one entry. ('Thread'
        — envelope → N exchange entries — lands with the thread-corpus
        milestone and is added to the ValidateSet then.)

    .PARAMETER EntryRouting
        'LeanPayload' (default): failed reads (_ChainHalt/ReadError), null
        results, and empty content route to Diagnostics.Routed with typed
        reasons (read-failure kind · NoContent · EmptyFile ·
        EmptiedByProcessing) and never become entries — payload doctrine.
        'KeepContentless': LTS-style — every non-null result becomes an
        entry (ReadError retained in the bag); only null results route.

    .OUTPUTS
        [PSCustomObject] @{ Header; Entries; Skipped; Diagnostics } — see
        module docstring for the full IR contract.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$DispatchOutput,

        [object]$RunContext = $null,

        [ValidateSet('Code')]
        [string]$Adapter = 'Code',

        [ValidateSet('LeanPayload', 'KeepContentless')]
        [string]$EntryRouting = 'LeanPayload'
    )

    # ── Contract check ────────────────────────────────────────────────────
    if ($null -eq $DispatchOutput.PSObject.Properties['Results'])
    {
        throw "Invoke-Assemble: DispatchOutput lacks a Results property — expected the dispatch envelope @{ Results; Skipped; Errors; Warnings; ... } (rs.core.ingest output contract)."
    }

    $results = @($DispatchOutput.Results)

    # Entry-bag exclusions — schema/assemble.schema.json out.entry.exclude
    $alwaysExcluded = $script:ExcludedFields

    $entries = [List[PSCustomObject]]::new()
    $routed = [List[PSCustomObject]]::new()

    # ── Phases: adapt + route (one pass, ingested order preserved) ────────
    for ($i = 0; $i -lt $results.Count; $i++)
    {
        $item = $results[$i]

        if ($null -eq $item)
        {
            $routed.Add([PSCustomObject]@{ Index = $i; RelativePath = $null; Reason = 'NullResult' })
            continue
        }

        $rel = if ($null -ne $item.PSObject.Properties['RelativePath']) { $item.RelativePath } else { $null }

        if ($EntryRouting -eq 'LeanPayload')
        {
            $readError = if ($null -ne $item.PSObject.Properties['ReadError']) { [string]$item.ReadError } else { $null }
            $halted = ($null -ne $item.PSObject.Properties['_ChainHalt'])

            if ($halted -or $null -ne $readError)
            {
                $reason = if ($null -ne $readError) { $readError } else { 'ChainHalt' }
                $routed.Add([PSCustomObject]@{ Index = $i; RelativePath = $rel; Reason = $reason })
                continue
            }

            $contentProp = $item.PSObject.Properties['Content']
            if ($null -eq $contentProp -or $contentProp.Value -isnot [string])
            {
                $routed.Add([PSCustomObject]@{ Index = $i; RelativePath = $rel; Reason = 'NoContent' })
                continue
            }

            if ($contentProp.Value.Length -eq 0)
            {
                # Empty on disk vs emptied by processing are different facts
                # for the auditor (payload doctrine).
                $sizeProp = $item.PSObject.Properties['SizeBytes']
                $reason = if ($null -eq $sizeProp) { 'EmptyContent' }
                elseif ([long]$sizeProp.Value -eq 0) { 'EmptyFile' }
                else { 'EmptiedByProcessing' }
                $routed.Add([PSCustomObject]@{ Index = $i; RelativePath = $rel; Reason = $reason })
                continue
            }
        }

        # adapt (Code: 1 → 1) — open bag: every property except exclusions,
        # arrival order preserved. ReadError is additionally excluded under
        # LeanPayload (unreachable here) and RETAINED under KeepContentless.
        $bag = [ordered]@{}
        foreach ($p in $item.PSObject.Properties)
        {
            if ($p.Name -in $alwaysExcluded) { continue }
            $bag[$p.Name] = $p.Value
        }
        $entries.Add([PSCustomObject]$bag)
    }

    # ── Phase: derive (Elements declaration — post-route coverage) ────────
    $coreFields = $script:CoreFields   # schema/assemble.schema.json out.entry.core
    $elementCounts = [ordered]@{}
    foreach ($entry in $entries)
    {
        foreach ($p in $entry.PSObject.Properties)
        {
            if ($p.Name -in $coreFields) { continue }
            if ($elementCounts.Contains($p.Name)) { $elementCounts[$p.Name]++ }
            else { $elementCounts[$p.Name] = 1 }
        }
    }
    $elements = [ordered]@{}
    foreach ($name in $elementCounts.Keys)
    {
        $elements[$name] = [PSCustomObject]@{ Count = $elementCounts[$name]; Total = $entries.Count }
    }

    # ── Phase: stamp (Header last — RunContext verbatim + derived facts) ──
    $header = [ordered]@{}
    if ($null -ne $RunContext)
    {
        foreach ($p in $RunContext.PSObject.Properties)
        {
            if ($p.Name -in @('EntryCount', 'Elements'))
            {
                throw "Invoke-Assemble: RunContext carries reserved header field '$($p.Name)' — EntryCount and Elements are assemble-derived (ownership map)."
            }
            $header[$p.Name] = $p.Value
        }
    }
    $header['EntryCount'] = $entries.Count
    $header['Elements'] = [PSCustomObject]$elements

    # ── Diagnostics + Skipped pass-through ────────────────────────────────
    # @() at construction, not at assignment: an if-expression enumerates its
    # output, collapsing a one-element array to a scalar — re-wrapping here
    # keeps the stream shape stable regardless of count.
    $skipped = if ($null -ne $DispatchOutput.PSObject.Properties['Skipped']) { $DispatchOutput.Skipped } else { $null }
    $errors = if ($null -ne $DispatchOutput.PSObject.Properties['Errors']) { $DispatchOutput.Errors } else { $null }
    $warnings = if ($null -ne $DispatchOutput.PSObject.Properties['Warnings']) { $DispatchOutput.Warnings } else { $null }

    return [PSCustomObject]@{
        Header      = [PSCustomObject]$header
        Entries     = $entries.ToArray()
        Skipped     = @($skipped | Where-Object { $null -ne $_ })
        Diagnostics = [PSCustomObject]@{
            Routed   = $routed.ToArray()
            Errors   = @($errors | Where-Object { $null -ne $_ })
            Warnings = @($warnings | Where-Object { $null -ne $_ })
        }
    }
}

Export-ModuleMember -Function 'Invoke-Assemble'
