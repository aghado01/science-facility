#Requires -Version 7.5

using namespace System.Collections.Generic

Import-Module "$PSScriptRoot/rs.core.internals.psm1" -Force

<#
.SYNOPSIS
    RepoSnapshot V3 ingest mediation — colonel plan compilation + dispatch.
    PROTO-ADMIRAL TISSUE, not a pipeline stage (ingest reframe, 2026-07-28
    — issues/reposnapshot/design/admiral-orchestration.md): "ingest" conceptually is the
    file reading, which is colonel's FIRST PROCESSOR (file-read.ps1);
    everything this module does — descriptor hand-off, plan compilation,
    dispatch, envelope merge — is the implicit admiral's purview.
    Disposition open: absorbed into admiral vs kept as a named submodule.

.DESCRIPTION
    Sits between Invoke-Membrane and colonel (Compile-Plan / Invoke-Plan).
    Metadata-based eligibility filtering (size ceiling, extension blacklist) is
    owned by Invoke-Membrane — it already holds per-file metadata and runs
    before any I/O. Binary (NUL byte) detection is handled opportunistically
    inside file-read.ps1 after ReadAllBytes.

    Ingest owns two concerns:

      1. Plan compilation — calls colonel's Compile-Plan with the caller's
         Profiles and Manifest; surfaces compilation errors before dispatch.

      2. Dispatch         — calls colonel's Invoke-Plan with the eligible item
         list and compiled plan; aggregates skipped + result diagnostics.
         Skipped entries from Invoke-Membrane (FileTooLarge,
         ExtensionBlacklisted) are merged into ingest's Skipped output.

    Colonel's parameter surface is reflected via New-ForwardedParamDictionary
    (rs.core.internals.psm1) — Invoke-Ingest only declares the one param it
    uniquely owns. All Compile-Plan and Invoke-Plan params are surfaced through
    DynamicParam and routed at call time via Split-ForwardedParams.

    Input contract (from Invoke-Membrane):
      FilteredFsGraph — [PSCustomObject] @{ Graph; Skipped } or plain
      Dictionary[NodePath, PSCustomObject] / flat array for back-compat.
      Each node in Graph carries a Files array of ItemDescriptor identity
      records (crawler-stamped): @{ AbsolutePath; RelativePath; NodePath;
      SizeBytes; LastWriteUtc }. The descriptors are dispatched to colonel
      as Items verbatim — processors receive them as $Item.

    Output contract (to admiral / caller):
      @{ Results; Skipped; Errors; Warnings; Streams; Budget; Timing }
      Results  — [object[]] ordered by original eligible-file index (from colonel)
      Skipped  — [PSCustomObject[]] @{ Path; Reason; ... } merged from all stages
      Errors   — string[] from Compile-Plan + Invoke-Plan
      Warnings — string[] aggregated across all stages
      Streams  — structured worker output from colonel, passed through intact
                 (@{ Stream; Worker; Message; ErrorId; Category; Target;
                 StackTrace }). Collating streams in colonel is only useful if
                 they reach the caller, so ingest forwards rather than flattens.

.NOTES
    Module load order (admiral's responsibility):
      1. rs.core.colonel.v2.psm1  — Compile-Plan, Invoke-Plan, IssPreset

    rs.core.internals.psm1 is a horizontal utility imported directly by this
    module — admiral does not need to load it separately.
#>

# =============================================================================
# PUBLIC — Invoke-Ingest
# =============================================================================

function Invoke-Ingest
{
    <#
    .SYNOPSIS
        Runs the ingest pipeline: plan compilation and colonel dispatch.

    .PARAMETER FilteredFsGraph
        Output from Invoke-Membrane — [PSCustomObject] @{ Graph; Skipped } or a plain
        Dictionary[NodePath, PSCustomObject] / flat array for back-compat.
        Each node in Graph must carry a Files property of ItemDescriptor identity
        records: @{ AbsolutePath; RelativePath; NodePath; SizeBytes; LastWriteUtc }.
        Descriptors are dispatched to colonel as Items verbatim.
        Skipped entries from the membrane stage (FileTooLarge, ExtensionBlacklisted) are merged into
        ingest's Skipped output.

    All remaining parameters (Manifest, Profiles/Steps, ChainExecutorPath, IssPreset,
    IssModules, DefaultSteps, InitThreads, MaxWorkers, ReservedCores, MinItemsPerWorker,
    WaitTimeoutMs) are reflected from Compile-Plan and Invoke-Plan and forwarded
    automatically. See colonel documentation for their descriptions.

    .OUTPUTS
        [PSCustomObject] @{
            Results  — [object[]] ordered by eligible-file index
            Skipped  — [PSCustomObject[]] ineligible files with Reason
            Errors   — string[]
            Warnings — string[]
            Streams  — structured worker streams from Invoke-Plan
            Budget   — from Invoke-Plan
            Timing   — from Invoke-Plan
        }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$FilteredFsGraph
    )

    DynamicParam
    {
        $ingestOwn = @('FilteredFsGraph')

        $dict = New-ForwardedParamDictionary -TargetCommand 'Compile-Plan' `
            -ExcludeParams $ingestOwn

        $invokeDict = New-ForwardedParamDictionary -TargetCommand 'Invoke-Plan' `
            -ExcludeParams ($ingestOwn + @('Items', 'Plan'))

        # Merge — Compile-Plan wins on any name collision
        foreach ($key in $invokeDict.Keys)
        {
            if (-not $dict.ContainsKey($key)) { $dict[$key] = $invokeDict[$key] }
        }

        return $dict
    }

    process
    {
        $skipped = [List[PSCustomObject]]::new()
        $warnings = [List[string]]::new()
        $errors = [List[string]]::new()

        # ── Normalise graph input ─────────────────────────────────────────────
        $graphData = $FilteredFsGraph
        if ($FilteredFsGraph -is [PSCustomObject] -and
            $null -ne $FilteredFsGraph.PSObject.Properties['Graph'])
        {
            $graphData = $FilteredFsGraph.Graph
            if ($FilteredFsGraph.Skipped)
            {
                foreach ($s in $FilteredFsGraph.Skipped) { $skipped.Add($s) }
            }
        }
        $graphNodes = if ($graphData -is [System.Collections.IDictionary])
        { $graphData.Values } else { $graphData }

        # ── Collect eligible file descriptors ────────────────────────────────
        # Items are the full ItemDescriptor objects — NOT bare path strings.
        # Processors receive the descriptor as $Item and copy-on-enrich; the
        # node context is gone after this flattening, so the descriptor is the
        # item's whole world (identity contract: rs.core.assemble-design.md).
        $eligible = [List[object]]::new()
        foreach ($node in $graphNodes)
        {
            if (-not $node.Files) { continue }
            foreach ($f in $node.Files) { $eligible.Add($f) }
        }

        if ($eligible.Count -eq 0)
        {
            return [PSCustomObject]@{
                Results  = @()
                Skipped  = $skipped.ToArray()
                Errors   = $errors.ToArray()
                Warnings = $warnings.ToArray()
                Streams  = @()
                Budget   = $null
                Timing   = $null
            }
        }

        # ── Route bound params to the correct colonel function ────────────────
        # BOTH splats withhold the sibling command's surface by REFLECTION —
        # never a hardcoded name list. Collision policy matches the DynamicParam
        # merge above (Compile-Plan wins), so only DISPATCH-ONLY names are
        # withheld from the compile splat; a name declared by both would ride
        # the compile side.
        #
        # Latent bug fixed here: the compile splat used to withhold a hardcoded
        # @('Items','Plan'), so every OTHER Invoke-Plan-only param (MaxWorkers,
        # ReservedCores, MinItemsPerWorker, WaitTimeoutMs) fell through into
        # Compile-Plan, which rejects unknown names — "A parameter cannot be
        # found that matches parameter name 'MaxWorkers'", raised from inside
        # the body, not by ingest's own binder. It hid behind the count-0 early
        # return (an empty graph never reaches this line), so it only surfaced
        # when a caller tuned dispatch on a graph that actually had files.
        $compileParams = @((Get-Command 'Compile-Plan').Parameters.Keys)
        $dispatchOnly = @((Get-Command 'Invoke-Plan').Parameters.Keys |
                Where-Object { $_ -notin $compileParams })

        $compileSplat = Split-ForwardedParams -BoundParameters $PSBoundParameters `
            -OwnParams (@('FilteredFsGraph') + $dispatchOnly)

        $dispatchSplat = Split-ForwardedParams -BoundParameters $PSBoundParameters `
            -OwnParams (@('FilteredFsGraph') + $compileParams)

        # ── Stage 1: Compile colonel plan ─────────────────────────────────────
        $compiled = Compile-Plan @compileSplat

        foreach ($w in $compiled.Warnings) { $warnings.Add($w) }

        if ($compiled.Errors.Count -gt 0)
        {
            foreach ($e in $compiled.Errors) { $errors.Add($e) }
            return [PSCustomObject]@{
                Results  = @()
                Skipped  = $skipped.ToArray()
                Errors   = $errors.ToArray()
                Warnings = $warnings.ToArray()
                Streams  = @()
                Budget   = $null
                Timing   = $null
            }
        }

        # ── Stage 2: Dispatch via colonel ─────────────────────────────────────
        $dispatchSplat['Items'] = $eligible.ToArray()
        $dispatchSplat['Plan'] = $compiled.Plan

        $result = Invoke-Plan @dispatchSplat

        foreach ($w in $result.Warnings) { $warnings.Add($w) }
        foreach ($e in $result.Errors) { $errors.Add($e) }

        return [PSCustomObject]@{
            Results  = $result.Results
            Skipped  = $skipped.ToArray()
            Errors   = $errors.ToArray()
            Warnings = $warnings.ToArray()
            Streams  = @($result.Streams)
            Budget   = $result.Budget
            Timing   = $result.Timing
        }
    }
}

Export-ModuleMember -Function 'Invoke-Ingest'
