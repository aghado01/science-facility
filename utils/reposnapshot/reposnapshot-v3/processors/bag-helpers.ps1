# See [bag-helpers.md](docs/bag-helpers.md) for docstring

#region Resolve-BagContent
function Resolve-BagContent
{
    <#
    .SYNOPSIS
        Content-key resolution — the harmonized content-mutator contract (6d).

    .DESCRIPTION
        Reads Content (descriptor contract) else Text (tp-era). The key that was
        read is the key the caller writes back, which is what keeps a mutator
        track-agnostic. Content wins when both exist; Text is then left exactly as
        found (never edit a key you did not read) — no current producer emits both.

        Returns $null when there is nothing to mutate:
          - a bag carrying NEITHER key
          - anything that is not a string, hashtable or pscustomobject

        Otherwise returns @{ Kind; Keys; ContentKey; Text }:
          Kind 'String' — bare string in; ContentKey is $null and caller returns bare string out
          Kind 'Bag'    — Keys in declaration order, ContentKey, Text
    #>
    param([object] $Item)

    if ($Item -is [string])
    {
        return [pscustomobject]@{ Kind = 'String'; Keys = @(); ContentKey = $null; Text = $Item }
    }

    if ($Item -is [hashtable] -or $Item -is [pscustomobject])
    {
        $keys = if ($Item -is [hashtable]) { @($Item.Keys) } else { @($Item.PSObject.Properties.Name) }
        $contentKey = if ('Content' -in $keys) { 'Content' } elseif ('Text' -in $keys) { 'Text' } else { $null }
        if ($null -eq $contentKey) { return $null }

        return [pscustomobject]@{
            Kind       = 'Bag'
            Keys       = $keys
            ContentKey = $contentKey
            Text       = [string]$Item.$contentKey
        }
    }

    return $null
}
#endregion

#region Copy-Bag
function Copy-Bag
{
    <#
    .SYNOPSIS
        Copy-on-enrich / copy-on-mutate helper for processor items.

    .DESCRIPTION
        Clones the incoming bag and returns a NEW pscustomobject; the caller's
        reference is never mutated. Built by a single [ordered] cast rather than N
        Add-Member calls: same property order, one allocation, works under Bare ISS.

    .PARAMETER Item
        The incoming bag or string.
    .PARAMETER Resolved
        A Resolve-BagContent result. When Kind is 'String', Content is returned directly.
    .PARAMETER Content
        Replacement content for the resolved key.
    .PARAMETER Add
        Extra properties to set after cloning (System.Collections.IDictionary).
    .PARAMETER Record
        A Processing record to APPEND to the bag's trail.
    #>
    param(
        [object]                        $Item,
        [object]                        $Resolved = $null,
        [object]                        $Content = $null,
        [System.Collections.IDictionary] $Add = $null,
        [object]                        $Record = $null
    )

    # Bare string in → bare string out; there is no bag to carry metadata.
    if ($null -ne $Resolved -and $Resolved.Kind -eq 'String') { return $Content }

    $keys = if ($null -ne $Resolved) { $Resolved.Keys }
    elseif ($Item -is [hashtable]) { @($Item.Keys) }
    else { @($Item.PSObject.Properties.Name) }

    $contentKey = if ($null -ne $Resolved) { $Resolved.ContentKey } else { $null }

    $ord = [ordered]@{}
    foreach ($name in $keys)
    {
        $ord[$name] = if ($null -ne $contentKey -and $name -eq $contentKey) { $Content } else { $Item.$name }
    }

    if ($null -ne $Add)
    {
        foreach ($k in $Add.Keys) { $ord[$k] = $Add[$k] }
    }

    if ($null -ne $Record)
    {
        $ord['Processing'] = if ('Processing' -in $keys) { @($Item.Processing) + $Record } else { @($Record) }
    }

    return [pscustomobject]$ord
}
#endregion

#region Resolve-ProcessorConfig
function Resolve-ProcessorConfig
{
    <#
    .SYNOPSIS
        Resolves processor configuration by merging caller overrides on top of external JSON defaults.
    #>
    param(
        [Parameter(Mandatory)] [string]$ProcessorName,
        [hashtable]$CallerConfig = @{}
    )

    $effective = @{}
    $configsDir = Join-Path $PSScriptRoot 'configs'
    $cfgPath = Join-Path $configsDir "$ProcessorName.json"
    if ([System.IO.File]::Exists($cfgPath))
    {
        try
        {
            $json = [System.IO.File]::ReadAllText($cfgPath)
            $parsed = $json | ConvertFrom-Json -AsHashtable
            if ($null -ne $parsed)
            {
                foreach ($k in $parsed.Keys) { $effective[$k] = $parsed[$k] }
            }
        }
        catch {}
    }

    if ($null -ne $CallerConfig)
    {
        foreach ($k in $CallerConfig.Keys) { $effective[$k] = $CallerConfig[$k] }
    }

    return $effective
}
#endregion
