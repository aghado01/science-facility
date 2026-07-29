#region INFRASTRUCTURE — param forwarding + stage wrapper registration

<#
.SYNOPSIS
    RepoSnapshot V3 horizontal infrastructure — pure pipeline utilities.

.DESCRIPTION
    rs.core.internals.psm1 is a shared utility module expressly designed to be
    imported by any member of the V3 pipeline, not just the top-level orchestrator.
    It contains no domain logic and carries no dependencies on other rs.core modules.

    Any pipeline stage that needs DynamicParam reflection, parameter forwarding,
    or stage wrapper registration should import this module directly.
    Callers outside the pipeline (e.g. admiral scripts, test harnesses) may also
    import it freely.

    The reflection-forwarding mechanism is deliberately unconventional
    (signatures change in stage functions without rippling into wrappers) and
    carries a documentation requirement: flag every use site (admiral brief,
    issues/v3/admiral-orchestration.md — wrapper mechanism section, incl.
    accepted implications: load-order dependency, collision policy,
    best-effort DefaultValue reflection). Current use site: rs.core.ingest.

    Exports:
      New-ForwardedParamDictionary — reflect a command's params into a DynamicParam dict
      Split-ForwardedParams        — partition $PSBoundParameters by a command's declared params
      Register-StageWrapper        — register a transparent wrapper function at runtime
#>

<#
.SYNOPSIS
    Reflects a target command's parameter surface as a RuntimeDefinedParameterDictionary
    for use in DynamicParam blocks.
.DESCRIPTION
    Copies all parameters from the target command (excluding common params and any
    explicitly excluded names) into a dictionary that DynamicParam can return directly.
    Preserves all parameter attributes (mandatory, position, validation, etc.).
.NOTES
    DefaultValue reflection is best-effort — PowerShell does not always populate
    ParameterMetadata.DefaultValue through reflection. Canonical defaults should
    be declared in the wrapper's own param() block and injected after Split-ForwardedParams.
#>
function New-ForwardedParamDictionary
{
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

        if ($null -ne $p.DefaultValue) { $rp.Value = $p.DefaultValue }

        $dict[$p.Name] = $rp
    }

    return $dict
}

<#
.SYNOPSIS
    Partitions $PSBoundParameters into a forwarding hashtable by excluding
    the wrapper's own parameter names.
.DESCRIPTION
    Given the wrapper's $PSBoundParameters and the list of param names the wrapper
    owns (i.e. should NOT forward), returns a hashtable of everything else —
    ready to splat to the target command.
.EXAMPLE
    $crawlerSplat = Split-ForwardedParams $PSBoundParameters -OwnParams @('StoreRoot','Append')
    Invoke-RsCrawler @crawlerSplat
#>
function Split-ForwardedParams
{
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

<#
.SYNOPSIS
    Registers a stage wrapper function that transparently reflects a target command's
    parameter surface, injects defaults, and optionally runs pre/post hooks.
.DESCRIPTION
    The functional equivalent of a decorator — wraps a target command with:
      - Full DynamicParam reflection of the target's parameter surface
      - Caller-specified default values (applied only when param not bound by caller)
      - Optional PreProcess scriptblock: receives the final splat hashtable, can mutate it
      - Optional PostProcess scriptblock: receives the result, can transform or log it

    The wrapper is registered as a real function in the Function: drive under $WrapperName,
    making it available immediately in the current session and importable via module.

.PARAMETER WrapperName
    The name of the function to register (e.g. 'Invoke-TpCrawler').

.PARAMETER TargetCommand
    The name of the command being wrapped (e.g. 'Invoke-RsCrawler').

.PARAMETER OwnParams
    Parameter names declared in the wrapper's own param() block that should NOT
    be forwarded to the target. Also excluded from DynamicParam injection.

.PARAMETER Defaults
    Hashtable of default values to apply for target params not bound by the caller.
    These are applied AFTER Split-ForwardedParams, so a caller-supplied value always wins.

.PARAMETER PreProcess
    Scriptblock invoked before the target command. Receives one argument: the final
    splat hashtable (by reference — mutations are reflected in the call).
    Signature: param([hashtable] $Splat)

.PARAMETER PostProcess
    Scriptblock invoked after the target command. Receives one argument: the result.
    Must return the (optionally transformed) result.
    Signature: param([object] $Result)

.EXAMPLE
    Register-StageWrapper -WrapperName 'Invoke-TpCrawler' `
        -TargetCommand 'Invoke-RsCrawler' `
        -OwnParams     @() `
        -Defaults      @{ Root = '.'; Extensions = @('.md','.txt'); Recurse = $true } `
        -PostProcess   { param($r) Write-Verbose "Crawled $($r.Files.Count) files"; $r }
#>
function Register-StageWrapper
{
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

    # Capture all config into closure variables
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
            # Partition bound params — exclude wrapper's own params
            $splat = Split-ForwardedParams -BoundParameters $PSBoundParameters `
                -OwnParams $capturedOwn

            # Apply defaults for anything the caller didn't supply
            foreach ($k in $capturedDefaults.Keys)
            {
                if (-not $splat.ContainsKey($k))
                {
                    $splat[$k] = $capturedDefaults[$k]
                }
            }

            # Pre-process hook — can mutate $splat before the call
            if ($null -ne $capturedPre)
            {
                & $capturedPre $splat
            }

            # Call the target
            $result = & $capturedTarget @splat

            # Post-process hook — must return the (optionally transformed) result
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

    # Register as a real named function in the Function: drive
    Set-Item -Path "Function:\$WrapperName" -Value $wrapperBody

    Write-Verbose "[Register-StageWrapper] Registered '$WrapperName' -> '$TargetCommand'"
}




#region Exported functions
Export-ModuleMember -Function @(
    'New-ForwardedParamDictionary'
    'Split-ForwardedParams'
    'Register-StageWrapper'
)

#endregion INFRASTRUCTURE
