#Requires -Version 7.5

using namespace System.Collections.Generic

Import-Module "$PSScriptRoot/rs.core.internals.psm1" -Force

<#
.SYNOPSIS
    RepoSnapshot V3 ingest mediation — bridges membrane output to colonel dispatch.

.DESCRIPTION
    Extracts eligible file descriptors from the filtered filesystem graph, compiles
    the processing plan via Compile-Plan, and dispatches items across the worker pool
    via Invoke-Plan.

    See docs/stage-architecture.md and docs/colonel-and-iss.md for architecture details.
#>

#region Invoke-Ingest
function Invoke-Ingest
{
    <#
    .SYNOPSIS
        Compiles the processing plan and dispatches eligible items.

    .PARAMETER FilteredFsGraph
        Output from Invoke-Membrane containing Graph and Skipped entries.

    .OUTPUTS
        [PSCustomObject] @{ Results; Skipped; Errors; Warnings; Streams; Budget; Timing }
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

        # Normalize graph input
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

        # Collect eligible file descriptors
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

        # Partition forwarded parameters
        $compileParams = @((Get-Command 'Compile-Plan').Parameters.Keys)
        $dispatchOnly = @((Get-Command 'Invoke-Plan').Parameters.Keys |
                Where-Object { $_ -notin $compileParams })

        $compileSplat = Split-ForwardedParams -BoundParameters $PSBoundParameters `
            -OwnParams (@('FilteredFsGraph') + $dispatchOnly)

        $dispatchSplat = Split-ForwardedParams -BoundParameters $PSBoundParameters `
            -OwnParams (@('FilteredFsGraph') + $compileParams)

        # Stage 1: Compile colonel plan
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

        # Stage 2: Dispatch via colonel
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
#endregion

Export-ModuleMember -Function 'Invoke-Ingest'
