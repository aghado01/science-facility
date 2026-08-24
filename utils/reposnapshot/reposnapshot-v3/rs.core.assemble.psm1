#Requires -Version 7.5

using namespace System.Collections.Generic

<#
.SYNOPSIS
    RepoSnapshot V3 assemble stage — collates dispatch results into in-memory IR.

.DESCRIPTION
    Assemble is a collation stage that organizes worker dispatch results into
    the Intermediate Representation (IR).

    Phase Sequence:
      1. Adapt: Adapt track results to entry candidates (Code track: 1 → 1).
      2. Route: Partition entries between payload Entries and Diagnostics.
      3. Derive: Calculate observed element counts in Header.Elements.
      4. Stamp: Construct Header with RunContext, EntryCount, and Elements.

    See docs/assemble-and-ir.md for architecture and routing policies.
#>

#region ContractInit
$script:Contract = Get-Content -LiteralPath "$PSScriptRoot/contracts/assemble.contract.json" -Raw -ErrorAction Stop |
    ConvertFrom-Json -AsHashtable
$script:CoreFields = @($script:Contract.out.entry.core.Keys)
$script:ExcludedFields = @($script:Contract.out.entry.exclude)
$script:CarriedFields = @($script:Contract.out.entry.carried)
#endregion

#region Invoke-Assemble
function Invoke-Assemble
{
    <#
    .SYNOPSIS
        Collates a colonel dispatch envelope into the snapshot IR.

    .PARAMETER DispatchOutput
        The dispatch envelope (@{ Results; Skipped; Errors; Warnings }).

    .PARAMETER RunContext
        Optional run-level header properties stamped verbatim into Header.
        EntryCount and Elements are reserved names.

    .PARAMETER Adapter
        Track adapter ('Code' default).

    .PARAMETER EntryRouting
        'LeanPayload' (default): routes failed reads and empty files to Diagnostics.Routed.
        'KeepContentless': retains contentless entries with ReadError in payload.

    .OUTPUTS
        [PSCustomObject] @{ Header; Entries; Skipped; Diagnostics }
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

    if ($null -eq $DispatchOutput.PSObject.Properties['Results'])
    {
        throw "Invoke-Assemble: DispatchOutput lacks a Results property."
    }

    $results = @($DispatchOutput.Results)
    $alwaysExcluded = $script:ExcludedFields

    $entries = [List[PSCustomObject]]::new()
    $routed = [List[PSCustomObject]]::new()

    # Adapt + Route phase
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
                $sizeProp = $item.PSObject.Properties['SizeBytes']
                $reason = if ($null -eq $sizeProp) { 'EmptyContent' }
                elseif ([long]$sizeProp.Value -eq 0) { 'EmptyFile' }
                else { 'EmptiedByProcessing' }
                $routed.Add([PSCustomObject]@{ Index = $i; RelativePath = $rel; Reason = $reason })
                continue
            }
        }

        $bag = [ordered]@{}
        foreach ($p in $item.PSObject.Properties)
        {
            if ($p.Name -in $alwaysExcluded) { continue }
            $bag[$p.Name] = $p.Value
        }
        $entries.Add([PSCustomObject]$bag)
    }

    # Derive Elements phase
    $coreFields = $script:CoreFields
    $elementCounts = [ordered]@{}
    foreach ($entry in $entries)
    {
        foreach ($p in $entry.PSObject.Properties)
        {
            if ($p.Name -in $coreFields) { continue }
            if ($p.Name -in $script:CarriedFields) { continue }
            if ($elementCounts.Contains($p.Name)) { $elementCounts[$p.Name]++ }
            else { $elementCounts[$p.Name] = 1 }
        }
    }
    $elements = [ordered]@{}
    foreach ($name in $elementCounts.Keys)
    {
        $elements[$name] = [PSCustomObject]@{ Count = $elementCounts[$name]; Total = $entries.Count }
    }

    # Stamp Header phase
    $header = [ordered]@{}
    if ($null -ne $RunContext)
    {
        foreach ($p in $RunContext.PSObject.Properties)
        {
            if ($p.Name -in @('EntryCount', 'Elements'))
            {
                throw "Invoke-Assemble: RunContext carries reserved header field '$($p.Name)'."
            }
            $header[$p.Name] = $p.Value
        }
    }
    $header['EntryCount'] = $entries.Count
    $header['Elements'] = [PSCustomObject]$elements

    # Diagnostics + Skipped pass-through
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
#endregion

Export-ModuleMember -Function 'Invoke-Assemble'
