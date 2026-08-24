<#
.SYNOPSIS
    RepoSnapshot V3 horizontal infrastructure — pipeline utilities.

.DESCRIPTION
    Shared utility module for DynamicParam reflection, parameter forwarding,
    and stage wrapper registration.

    Exports:
      New-ForwardedParamDictionary: Reflect a command's parameters into a DynamicParam dict.
      Split-ForwardedParams: Partition $PSBoundParameters for targeted splatting.
      Register-StageWrapper: Register a transparent wrapper function at runtime.

    See docs/horizontal-internals.md for parameter forwarding architecture.
#>

#region New-ForwardedParamDictionary
function New-ForwardedParamDictionary
{
    <#
    .SYNOPSIS
        Reflects a target command's parameter surface as a RuntimeDefinedParameterDictionary.
    #>
    [OutputType([System.Management.Automation.RuntimeDefinedParameterDictionary])]
    param(
        [Parameter(Mandatory)]
        [string] $TargetCommand,

        [string[]] $ExcludeParams = @()
    )

    $target = Get-Command $TargetCommand -ErrorAction Stop
    $dict = [System.Management.Automation.RuntimeDefinedParameterDictionary]::new()

    $skip = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($n in [System.Management.Automation.PSCmdlet]::CommonParameters) { [void]$skip.Add($n) }
    foreach ($n in [System.Management.Automation.PSCmdlet]::OptionalCommonParameters) { [void]$skip.Add($n) }
    foreach ($n in $ExcludeParams) { [void]$skip.Add($n) }

    foreach ($p in $target.Parameters.Values)
    {
        if ($skip.Contains($p.Name)) { continue }

        $attrs = [System.Collections.ObjectModel.Collection[System.Attribute]]::new()
        foreach ($a in $p.Attributes) { $attrs.Add($a) }

        $rp = [System.Management.Automation.RuntimeDefinedParameter]::new(
            $p.Name, $p.ParameterType, $attrs)

        $dict[$p.Name] = $rp
    }

    return $dict
}
#endregion

#region Split-ForwardedParams
function Split-ForwardedParams
{
    <#
    .SYNOPSIS
        Partitions $PSBoundParameters into a forwarding hashtable by excluding own parameter names.
    #>
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $BoundParameters,

        [Parameter(Mandatory)]
        [string[]] $OwnParams
    )

    $exclude = [System.Collections.Generic.HashSet[string]]::new(
        [string[]]$OwnParams, [StringComparer]::OrdinalIgnoreCase)

    $forward = @{}
    foreach ($key in $BoundParameters.Keys)
    {
        if (-not $exclude.Contains($key))
        {
            $forward[$key] = $BoundParameters[$key]
        }
    }
    return $forward
}
#endregion

#region Register-StageWrapper
function Register-StageWrapper
{
    <#
    .SYNOPSIS
        Registers a stage wrapper function that transparently reflects a target command.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $WrapperName,

        [Parameter(Mandatory)]
        [string] $TargetCommand,

        [string[]]    $OwnParams = @(),
        [hashtable]   $Defaults = @{},
        [scriptblock] $PreProcess = $null,
        [scriptblock] $PostProcess = $null
    )

    $capturedTarget = $TargetCommand
    $capturedOwn = $OwnParams
    $capturedDefaults = $Defaults
    $capturedPre = $PreProcess
    $capturedPost = $PostProcess

    $wrapperBody = {
        [CmdletBinding()]
        param()

        DynamicParam
        {
            New-ForwardedParamDictionary -TargetCommand $capturedTarget `
                -ExcludeParams $capturedOwn
        }

        process
        {
            $splat = Split-ForwardedParams -BoundParameters $PSBoundParameters `
                -OwnParams $capturedOwn

            foreach ($k in $capturedDefaults.Keys)
            {
                if (-not $splat.ContainsKey($k))
                {
                    $splat[$k] = $capturedDefaults[$k]
                }
            }

            if ($null -ne $capturedPre)
            {
                & $capturedPre $splat
            }

            $result = & $capturedTarget @splat

            if ($null -ne $capturedPost)
            {
                & $capturedPost $result
            }
            else
            {
                $result
            }
        }
    }.GetNewClosure()

    Set-Item -Path "Function:\$WrapperName" -Value $wrapperBody
    Write-Verbose "[Register-StageWrapper] Registered '$WrapperName' -> '$TargetCommand'"
}
#endregion

Export-ModuleMember -Function @(
    'New-ForwardedParamDictionary'
    'Split-ForwardedParams'
    'Register-StageWrapper'
)
