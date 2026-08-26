using namespace System
using namespace System.Collections.Concurrent
using namespace System.Management.Automation
using namespace System.Management.Automation.Runspaces
using namespace System.Threading

#Requires -Version 7.6
Set-StrictMode -Version Latest

<#
.SYNOPSIS
    RepoSnapshot V3 colonel — processor-chain compilation and runspace-pool dispatch.

.DESCRIPTION
    Two-call API surface:
      Compile-Plan: Validates processor scripts via AST, registers bodies and
                    chain-executor into an InitialSessionState, returns a frozen Plan.
      Invoke-Plan:  Slices items across a worker pool, executes chains via
                    Invoke-ChainExecutor, returns an index-stable envelope.

    See docs/colonel-and-iss.md for architecture and closure rules.
#>

#region Enums
enum IssPreset
{
    Bare  # Empty engine (0 cmdlets)
    Core  # PS core cmdlets (default)
    Full  # Full module + provider set
}
#endregion

#region ReadProcessorScript
# Module-scoped scriptblock for validating and reading a processor script file.
$script:ReadProcessorScript = {
    param([string]$Key, [string]$Path)
    $result = @{ Key = $Key; Fn = "Invoke-$Key"; Body = $null; Error = $null }
    try
    {
        if ([string]::IsNullOrWhiteSpace($Key)) { $result.Error = 'Processor key cannot be empty.'; return $result }
        if ([string]::IsNullOrWhiteSpace($Path)) { $result.Error = 'Processor path cannot be empty.'; return $result }
        if (-not (Test-Path -LiteralPath $Path)) { $result.Error = "Script not found: $Path"; return $result }

        $body = Get-Content -LiteralPath $Path -Raw

        # AST validation of the body-only contract
        $parseErrors = $null
        $astTokens = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput(
            $body, [ref]$astTokens, [ref]$parseErrors)
        if ($parseErrors.Count -gt 0)
        {
            $result.Error = "Processor script does not parse: $($parseErrors[0].Message)"
            return $result
        }

        # #Requires is inert inside ISS-registered function bodies
        if ($null -ne $ast.ScriptRequirements)
        {
            $result.Error = 'Processor scripts must not declare #Requires (ISS-load contract).'
            return $result
        }

        if ($null -eq $ast.ParamBlock)
        {
            $result.Error = 'Processor scripts must declare a top-level param($Item, $Config) block.'
            return $result
        }

        # Engine-state modifications belong to Build-Iss, not processor bodies
        $banned = @('Set-StrictMode', 'Set-PSDebug')
        $cmdAsts = $ast.FindAll(
            { param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)
        foreach ($c in $cmdAsts)
        {
            $name = $c.GetCommandName()
            if ($null -ne $name -and $banned -contains $name)
            {
                $result.Error = "Processor scripts must not call $name (engine state belongs to Build-Iss)."
                return $result
            }
        }

        $result.Body = $body
    }
    catch { $result.Error = $_.Exception.Message }
    return $result
}
#endregion

#region Build-Iss
function Build-Iss
{
    <#
    .SYNOPSIS
        Constructs an InitialSessionState from a preset and module list.
    #>
    param(
        [IssPreset] $Preset = [IssPreset]::Core,
        [string[]]  $Modules = @()
    )

    $iss = switch ($Preset)
    {
        ([IssPreset]::Bare)
        {
            $bare = [InitialSessionState]::Create()
            $bare.LanguageMode = [System.Management.Automation.PSLanguageMode]::FullLanguage
            $bare
        }
        ([IssPreset]::Core) { [InitialSessionState]::CreateDefault2() }
        ([IssPreset]::Full) { [InitialSessionState]::CreateDefault() }
        default { [InitialSessionState]::CreateDefault2() }
    }

    if ($null -eq $iss)
    {
        throw "Build-Iss: InitialSessionState construction returned null for preset '$Preset'."
    }

    foreach ($mod in $Modules)
    {
        if (-not [string]::IsNullOrWhiteSpace($mod)) { $iss.ImportPSModule($mod) }
    }

    return $iss
}
#endregion

#region Sequencing
# Sequence-manifest resolution: enable -> route -> sort. The compiler is the only
# component that reads this file; nothing below plan compilation branches on file
# type. All four functions are pure over hashtables except the single read in
# Import-SequenceManifest.

function Import-SequenceManifest
{
    <#
    .SYNOPSIS
        Loads and validates the sequence manifest into a normalized structure.

    .DESCRIPTION
        Every declared convention is enforced here and every failure is terminating:
        a malformed manifest is a stop, not a degraded run.

    .OUTPUTS
        [PSCustomObject] @{ Path; Processors; Routing; ExtensionMap }
    #>
    param(
        [Parameter(Mandatory)] [string]    $Path,
        [Parameter(Mandatory)] [hashtable] $Manifest
    )

    if (-not [System.IO.File]::Exists($Path))
    {
        throw "Import-SequenceManifest: sequence manifest not found: $Path"
    }

    try { $raw = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($Path)) -AsHashtable }
    catch { throw "Import-SequenceManifest: '$Path' is not valid JSON — $($_.Exception.Message)" }

    if ($null -eq $raw -or -not $raw.Contains('Processors') -or $raw['Processors'].Count -eq 0)
    {
        throw "Import-SequenceManifest: '$Path' declares no Processors."
    }
    $rawProcs = $raw['Processors']
    $rawRouting = if ($raw.Contains('Routing') -and $null -ne $raw['Routing']) { $raw['Routing'] } else { @{} }

    # Normalize entries; Group and Rank are ordinals, so they must parse as integers.
    $procs = @{}
    foreach ($key in $rawProcs.Keys)
    {
        $e = $rawProcs[$key]
        if ($e -isnot [System.Collections.IDictionary])
        {
            throw "Import-SequenceManifest: entry '$key' is not an object."
        }

        $group = 0
        $rank = 0
        $gTxt = if ($e.Contains('Group')) { [string]$e['Group'] } else { '' }
        $rTxt = if ($e.Contains('Rank')) { [string]$e['Rank'] } else { '' }
        if (-not [int]::TryParse($gTxt, [ref]$group))
        {
            throw "Import-SequenceManifest: '$key' has a missing or non-integer Group ('$gTxt')."
        }
        if (-not [int]::TryParse($rTxt, [ref]$rank))
        {
            throw "Import-SequenceManifest: '$key' has a missing or non-integer Rank ('$rTxt')."
        }

        # Direct assignment, not an if-expression: a branch yielding an empty array
        # emits nothing, and the variable would land as $null instead of @().
        $requires = @()
        if ($e.Contains('Requires') -and $null -ne $e['Requires']) { $requires = @([string[]]$e['Requires']) }

        $procs[$key] = @{
            Key      = $key
            Group    = $group
            Rank     = $rank
            Default  = if ($e.Contains('Default')) { [bool]$e['Default'] } else { $false }
            Requires = $requires
            IsToken  = $key.StartsWith('$')
        }
    }

    # A fixed key names its own processor file; a token names none and routes instead.
    foreach ($key in $procs.Keys)
    {
        if ($procs[$key].IsToken)
        {
            if (-not $rawRouting.Contains($key))
            {
                throw "Import-SequenceManifest: token '$key' has no Routing table."
            }
        }
        elseif (-not $Manifest.ContainsKey($key))
        {
            throw "Import-SequenceManifest: '$key' has no processors\$key.ps1 (known: $($Manifest.Keys -join ', '))."
        }
    }
    foreach ($token in $rawRouting.Keys)
    {
        if (-not $procs.ContainsKey($token))
        {
            throw "Import-SequenceManifest: Routing declares '$token', which has no Processors entry."
        }
        if (-not $procs[$token].IsToken)
        {
            throw "Import-SequenceManifest: Routing declares '$token', which is not a token."
        }
    }

    # Routes bind to real processor files; extensions normalize to the crawler's
    # leading-dot form and must name at most one class across the whole manifest.
    $routing = @{}
    $extMap = @{}
    foreach ($token in $rawRouting.Keys)
    {
        $langs = @{}
        foreach ($lang in $rawRouting[$token].Keys)
        {
            $route = $rawRouting[$token][$lang]
            if ($route -isnot [System.Collections.IDictionary] -or
                -not $route.Contains('processor') -or
                [string]::IsNullOrWhiteSpace([string]$route['processor']))
            {
                throw "Import-SequenceManifest: route $token/$lang names no processor."
            }

            # A route names a processor key, never a filename: the manifest derives
            # its keys from the same on-disk stubs, so a correctly named processor
            # cannot miss, and there is no second spelling to keep in agreement.
            $rKey = [string]$route['processor']
            if (-not $Manifest.ContainsKey($rKey))
            {
                throw "Import-SequenceManifest: route $token/$lang names '$rKey', which is not a processor key (known: $($Manifest.Keys -join ', '))."
            }

            $exts = @()
            if ($route.Contains('extensions') -and $null -ne $route['extensions']) { $exts = @($route['extensions']) }
            if ($exts.Count -eq 0)
            {
                throw "Import-SequenceManifest: route $token/$lang declares no extensions."
            }

            $norm = [System.Collections.Generic.List[string]]::new()
            foreach ($x in $exts)
            {
                $ext = '.' + ([string]$x).TrimStart('.').ToLowerInvariant()
                if ($extMap.ContainsKey($ext) -and $extMap[$ext] -ne $lang)
                {
                    throw "Import-SequenceManifest: extension '$ext' maps to both '$($extMap[$ext])' and '$lang'; a file class must be unambiguous."
                }
                $extMap[$ext] = $lang
                $norm.Add($ext)
            }

            $langs[$lang] = @{ Language = $lang; Extensions = $norm.ToArray(); Key = $rKey }
        }
        $routing[$token] = $langs
    }

    # Rank 0 reserves a group for a single member; otherwise ranks separate co-applying members.
    $byGroup = @{}
    foreach ($key in $procs.Keys)
    {
        $g = $procs[$key].Group
        if (-not $byGroup.ContainsKey($g)) { $byGroup[$g] = [System.Collections.Generic.List[string]]::new() }
        $byGroup[$g].Add($key)
    }
    foreach ($g in $byGroup.Keys)
    {
        $members = @($byGroup[$g])
        $solo = @($members | Where-Object { $procs[$_].Rank -eq 0 })
        if ($solo.Count -gt 0 -and $members.Count -gt 1)
        {
            throw "Import-SequenceManifest: group $g holds $($members.Count) members ($($members -join ', ')) but '$($solo[0])' is Rank 0, which reserves the group for one member."
        }
        $ranks = @($members | ForEach-Object { $procs[$_].Rank })
        if (@($ranks | Select-Object -Unique).Count -ne $ranks.Count)
        {
            throw "Import-SequenceManifest: group $g has duplicate Ranks among $($members -join ', ')."
        }
    }

    # Requires drives enablement, not ordering — so every edge must point backward
    # through the canon, or a dependency would be enabled and then run too late.
    foreach ($key in $procs.Keys)
    {
        foreach ($req in $procs[$key].Requires)
        {
            if (-not $procs.ContainsKey($req))
            {
                throw "Import-SequenceManifest: '$key' requires '$req', which has no Processors entry."
            }
            $dep = $procs[$req]
            $self = $procs[$key]
            if ($dep.Group -gt $self.Group -or ($dep.Group -eq $self.Group -and $dep.Rank -ge $self.Rank))
            {
                throw "Import-SequenceManifest: '$key' (Group $($self.Group), Rank $($self.Rank)) requires '$req' (Group $($dep.Group), Rank $($dep.Rank)), which does not sort earlier."
            }
        }
    }

    return [pscustomobject]@{
        Path         = $Path
        Processors   = $procs
        Routing      = $routing
        ExtensionMap = $extMap
    }
}

function Resolve-EnabledSet
{
    <#
    .SYNOPSIS
        Closes a requested processor set over Default entries and Requires edges.

    .DESCRIPTION
        IncludeProcessors is a set: array position carries no meaning, and ordering
        is settled later by Group and Rank.

    .OUTPUTS
        [string[]] enabled sequence-manifest keys
    #>
    param(
        [Parameter(Mandatory)] [pscustomobject]              $Sequence,
        [AllowEmptyCollection()] [AllowNull()] [string[]]    $IncludeProcessors = @()
    )

    $procs = $Sequence.Processors
    $wanted = [System.Collections.Generic.HashSet[string]]::new()

    foreach ($k in @($IncludeProcessors))
    {
        if ([string]::IsNullOrWhiteSpace($k)) { continue }
        if (-not $procs.ContainsKey($k))
        {
            throw "Resolve-EnabledSet: '$k' has no sequence-manifest entry. Add one, or supply the chain literally with -RunVerbatim."
        }
        [void]$wanted.Add($k)
    }

    foreach ($k in $procs.Keys)
    {
        if ($procs[$k].Default) { [void]$wanted.Add($k) }
    }

    do
    {
        $before = $wanted.Count
        foreach ($k in @($wanted))
        {
            foreach ($r in $procs[$k].Requires) { [void]$wanted.Add($r) }
        }
    } while ($wanted.Count -gt $before)

    return @($wanted)
}

function Resolve-Classes
{
    <#
    .SYNOPSIS
        Determines which file classes the corpus actually contains.

    .DESCRIPTION
        A class is a language named by an enabled token's routes whose extensions
        appear in the corpus. 'default' joins the list only when some present
        extension goes unclaimed, so an all-PowerShell run compiles no unused variant.

    .OUTPUTS
        [string[]] class names
    #>
    param(
        [Parameter(Mandatory)] [pscustomobject]           $Sequence,
        [Parameter(Mandatory)] [string[]]                 $Enabled,
        [AllowEmptyCollection()] [AllowNull()] [string[]] $Extensions = @()
    )

    $present = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($x in @($Extensions))
    {
        if ([string]::IsNullOrWhiteSpace($x)) { continue }
        [void]$present.Add('.' + ([string]$x).TrimStart('.').ToLowerInvariant())
    }

    $classes = [System.Collections.Generic.List[string]]::new()
    $claimed = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($token in $Sequence.Routing.Keys)
    {
        if (@($Enabled) -notcontains $token) { continue }
        foreach ($lang in $Sequence.Routing[$token].Keys)
        {
            $hit = $false
            foreach ($ext in $Sequence.Routing[$token][$lang].Extensions)
            {
                if ($present.Contains($ext)) { $hit = $true; [void]$claimed.Add($ext) }
            }
            if ($hit -and -not $classes.Contains($lang)) { $classes.Add($lang) }
        }
    }

    $unclaimed = $false
    foreach ($ext in $present)
    {
        if (-not $claimed.Contains($ext)) { $unclaimed = $true; break }
    }
    if ($unclaimed -or $present.Count -eq 0) { $classes.Insert(0, 'default') }

    return @($classes)
}

function Resolve-Variants
{
    <#
    .SYNOPSIS
        Compiles one dense step list per file class.

    .DESCRIPTION
        Each class walks the enabled set, resolves routed tokens against its own
        routes, and splices out any token that does not resolve — variants differ
        in length and carry no holes. Sorting is by (Group, Rank).

    .OUTPUTS
        [hashtable] class -> [PSCustomObject[]] @{ Key; Slot; Config }
    #>
    param(
        [Parameter(Mandatory)] [pscustomobject] $Sequence,
        [Parameter(Mandatory)] [string[]]       $Enabled,
        [Parameter(Mandatory)] [string[]]       $Classes
    )

    $procs = $Sequence.Processors
    $variants = @{}

    foreach ($class in @($Classes))
    {
        $steps = [System.Collections.Generic.List[object]]::new()
        foreach ($key in @($Enabled))
        {
            $meta = $procs[$key]
            $resolved = $key

            if ($meta.IsToken)
            {
                $table = $Sequence.Routing[$key]
                if ($class -eq 'default' -or -not $table.ContainsKey($class)) { continue }
                $resolved = $table[$class].Key
            }

            $steps.Add([pscustomobject]@{
                    Key   = $resolved
                    Slot  = $key
                    Group = $meta.Group
                    Rank  = $meta.Rank
                })
        }

        $variants[$class] = @(
            $steps | Sort-Object Group, Rank | ForEach-Object {
                [pscustomobject]@{ Key = $_.Key; Slot = $_.Slot; Config = @{} }
            }
        )
    }

    return $variants
}
#endregion

#region Compile-Plan
function Compile-Plan
{
    <#
    .SYNOPSIS
        Reads and validates processor scripts, builds ISS, and returns a frozen Plan.
    #>
    param(
        [Parameter(Mandatory)] [hashtable]  $Manifest,
        [Parameter(Mandatory)] [object[]]   $Steps,
        [Parameter(Mandatory)] [string]     $ChainExecutorPath,
        [string[]]                          $SharedHelperPath = @(),
        [IssPreset]                         $IssPreset = [IssPreset]::Core,
        [string[]]                          $IssModules = @(),
        [int]                               $InitThreads = 4
    )

    $errors = [System.Collections.Generic.List[string]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()

    if ($null -eq $Manifest -or $Manifest.Count -eq 0)
    {
        $errors.Add('Manifest is empty — no processors to load.')
        return [pscustomobject]@{ Plan = $null; Errors = $errors.ToArray(); Warnings = $warnings.ToArray() }
    }
    if ($null -eq $Steps -or $Steps.Count -eq 0)
    {
        $errors.Add('Steps array is empty — nothing to execute.')
        return [pscustomobject]@{ Plan = $null; Errors = $errors.ToArray(); Warnings = $warnings.ToArray() }
    }
    if (-not (Test-Path -LiteralPath $ChainExecutorPath))
    {
        $errors.Add("chain-executor script not found: $ChainExecutorPath")
        return [pscustomobject]@{ Plan = $null; Errors = $errors.ToArray(); Warnings = $warnings.ToArray() }
    }

    $referencedKeys = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($step in $Steps)
    {
        if ([string]::IsNullOrWhiteSpace($step.Key))
        {
            $errors.Add('A step has an empty or missing Key.')
            continue
        }
        [void]$referencedKeys.Add($step.Key)
    }

    foreach ($key in $referencedKeys)
    {
        if (-not $Manifest.ContainsKey($key))
        {
            $errors.Add("Step references processor key '$key' which is absent from the manifest.")
        }
    }

    if ($errors.Count -gt 0)
    {
        return [pscustomobject]@{ Plan = $null; Errors = $errors.ToArray(); Warnings = $warnings.ToArray() }
    }

    # Parallel bootstrap read + validate
    $entriesToRead = @($Manifest.GetEnumerator() | Where-Object { $referencedKeys.Contains($_.Key) })

    $batches = [System.Collections.Generic.List[object[]]]::new()
    for ($i = 0; $i -lt $entriesToRead.Count; $i += $InitThreads)
    {
        $end = [Math]::Min($i + $InitThreads, $entriesToRead.Count) - 1
        $batches.Add($entriesToRead[$i..$end])
    }

    $loadedBodies = [System.Collections.Generic.List[hashtable]]::new($entriesToRead.Count)
    $readScript = $script:ReadProcessorScript

    foreach ($batch in $batches)
    {
        $wave = [System.Collections.Generic.List[hashtable]]::new($batch.Count)
        foreach ($entry in $batch)
        {
            $ps = [PowerShell]::Create()
            $null = $ps.AddScript($readScript).AddArgument([string]$entry.Key).AddArgument([string]$entry.Value)
            $async = $ps.BeginInvoke()
            $wave.Add(@{ PS = $ps; Async = $async })
        }
        foreach ($reader in $wave)
        {
            try
            {
                $res = $reader.PS.EndInvoke($reader.Async)
                if ($res -and $res.Count -gt 0) { $loadedBodies.Add($res[0]) }
            }
            catch { $warnings.Add("Bootstrap reader threw: $($_.Exception.Message)") }
            finally { $reader.PS.Dispose() }
        }
    }

    # Validate loaded bodies
    $validBodies = @{}
    foreach ($loaded in $loadedBodies)
    {
        if ($loaded.Error) { $errors.Add("Processor '$($loaded.Key)': $($loaded.Error)"); continue }
        $validBodies[$loaded.Key] = $loaded
    }

    if ($errors.Count -gt 0)
    {
        return [pscustomobject]@{ Plan = $null; Errors = $errors.ToArray(); Warnings = $warnings.ToArray() }
    }

    # Serial ISS construction
    $iss = Build-Iss -Preset $IssPreset -Modules $IssModules

    foreach ($key in $referencedKeys)
    {
        $entry = $validBodies[$key]
        $iss.Commands.Add(
            [System.Management.Automation.Runspaces.SessionStateFunctionEntry]::new($entry.Fn, $entry.Body)
        )
    }

    # Register Invoke-ChainExecutor
    $chainBody = Get-Content -LiteralPath $ChainExecutorPath -Raw
    $iss.Commands.Add(
        [System.Management.Automation.Runspaces.SessionStateFunctionEntry]::new('Invoke-ChainExecutor', $chainBody)
    )

    # Register shared helper libraries
    foreach ($helperPath in $SharedHelperPath)
    {
        $helperSrc = Get-Content -LiteralPath $helperPath -Raw
        $helperAst = [System.Management.Automation.Language.Parser]::ParseInput($helperSrc, [ref]$null, [ref]$null)
        foreach ($fn in $helperAst.FindAll(
                { param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false))
        {
            $bodyText = $fn.Body.Extent.Text
            $iss.Commands.Add(
                [System.Management.Automation.Runspaces.SessionStateFunctionEntry]::new(
                    $fn.Name, $bodyText.Substring(1, $bodyText.Length - 2))
            )
        }
    }

    # Bind steps to resolved Fn names and load external JSON configs
    $boundSteps = foreach ($step in $Steps)
    {
        $key = [string]$step.Key
        $procPath = [string]$Manifest[$key]
        $procDir = if ($procPath) { [System.IO.Path]::GetDirectoryName($procPath) } else { '' }
        $cfgPath = if ($procDir) { Join-Path $procDir "configs\$key.json" } else { '' }

        $effectiveConfig = @{}
        if ($cfgPath -and [System.IO.File]::Exists($cfgPath))
        {
            try
            {
                $json = [System.IO.File]::ReadAllText($cfgPath)
                $fileDefaults = $json | ConvertFrom-Json -AsHashtable
                if ($null -ne $fileDefaults)
                {
                    foreach ($k in $fileDefaults.Keys) { $effectiveConfig[$k] = $fileDefaults[$k] }
                }
            }
            catch
            {
                $warnings.Add("Compile-Plan: failed to parse config file '$cfgPath': $($_.Exception.Message)")
            }
        }

        if ($null -ne $step.Config)
        {
            if ($step.Config -is [System.Collections.IDictionary])
            {
                foreach ($k in $step.Config.Keys) { $effectiveConfig[$k] = $step.Config[$k] }
            }
            elseif ($step.Config -is [System.Management.Automation.PSCustomObject])
            {
                foreach ($p in $step.Config.PSObject.Properties) { $effectiveConfig[$p.Name] = $p.Value }
            }
        }

        [pscustomobject]@{
            Key    = $key
            Fn     = [string]$validBodies[$key].Fn
            Config = $effectiveConfig
        }
    }

    return [pscustomobject]@{
        Plan     = [pscustomobject]@{
            Steps         = @($boundSteps)
            Iss           = $iss
            ProcessorKeys = @($referencedKeys)
        }
        Errors   = @()
        Warnings = $warnings.ToArray()
    }
}
#endregion

#region Resolve-WorkerBudget
function Resolve-WorkerBudget
{
    <#
    .SYNOPSIS
        Determines thread count and allocation policy for a batch.
    #>
    param(
        [Parameter(Mandatory)] [int]           $ItemCount,
        [nullable[int]]                        $MaxWorkers = $null,
        [int]                                  $ReservedCores = 2,
        [int]                                  $MinItemsPerWorker = 4
    )

    $warnings = [System.Collections.Generic.List[string]]::new()
    $logical = [Math]::Max(1, [Environment]::ProcessorCount)

    if ($null -ne $MaxWorkers)
    {
        $policy = 'Explicit'
        if ($MaxWorkers -gt $logical)
        {
            $warnings.Add("MaxWorkers ($MaxWorkers) exceeds logical core count ($logical); clamping.")
            $MaxWorkers = $logical
        }
        $ceiling = [Math]::Max(1, $MaxWorkers)
    }
    else
    {
        $policy = 'Auto'
        $reserved = [Math]::Min($ReservedCores, $logical - 1)
        $ceiling = [Math]::Max(1, $logical - $reserved)
    }

    $graded = if ($MinItemsPerWorker -gt 0 -and $ItemCount -gt 0)
    {
        [Math]::Max(1, [int][Math]::Ceiling($ItemCount / $MinItemsPerWorker))
    }
    else { $ceiling }

    $threads = [Math]::Min($ceiling, $graded)
    $threads = [Math]::Max(1, [Math]::Min($threads, [Math]::Max(1, $ItemCount)))

    return [pscustomobject]@{
        Threads  = $threads
        Policy   = $policy
        Warnings = $warnings.ToArray()
        Inputs   = [pscustomobject]@{
            ItemCount         = $ItemCount
            MaxWorkers        = $MaxWorkers
            ReservedCores     = $ReservedCores
            MinItemsPerWorker = $MinItemsPerWorker
            LogicalCores      = $logical
        }
    }
}
#endregion

#region Invoke-Plan
function Invoke-Plan
{
    <#
    .SYNOPSIS
        Dispatches a compiled Plan against a batch of items using a RunspacePool.

    .OUTPUTS
        [PSCustomObject] @{ Results; Errors; Warnings; Streams; Budget; Timing }
    #>
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Items,
        [Parameter(Mandatory)] [pscustomobject] $Plan,
        [nullable[int]]                         $MaxWorkers = $null,
        [int]                                   $ReservedCores = 2,
        [int]                                   $MinItemsPerWorker = 4,
        [int]                                   $WaitTimeoutMs = 60000
    )

    $errors = [System.Collections.Concurrent.ConcurrentBag[string]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()
    $timing = @{}
    $swTotal = [System.Diagnostics.Stopwatch]::StartNew()

    # Budget resolution
    $budgetParams = @{
        ItemCount         = $Items.Count
        MaxWorkers        = $MaxWorkers
        ReservedCores     = $ReservedCores
        MinItemsPerWorker = $MinItemsPerWorker
    }
    $budget = Resolve-WorkerBudget @budgetParams

    foreach ($w in $budget.Warnings) { $warnings.Add($w) }

    $threads = $budget.Threads
    $count = $Items.Count
    $ordered = [object[]]::new($count)

    if ($count -eq 0)
    {
        return [pscustomobject]@{
            Results  = $ordered
            Errors   = @()
            Warnings = $warnings.ToArray()
            Budget   = $budget
            Timing   = [pscustomobject]@{ TotalMs = 0 }
        }
    }

    # Slice items round-robin
    $sliceItems = [System.Collections.Generic.List[object][]]::new($threads)
    $sliceIdxs = [System.Collections.Generic.List[int][]]::new($threads)
    for ($t = 0; $t -lt $threads; $t++)
    {
        $sliceItems[$t] = [System.Collections.Generic.List[object]]::new()
        $sliceIdxs[$t] = [System.Collections.Generic.List[int]]::new()
    }
    for ($i = 0; $i -lt $count; $i++)
    {
        $slot = $i % $threads
        $sliceItems[$slot].Add($Items[$i])
        $sliceIdxs[$slot].Add($i)
    }

    # Open RunspacePool
    $swPool = [System.Diagnostics.Stopwatch]::StartNew()
    $pool = [RunspaceFactory]::CreateRunspacePool($Plan.Iss)
    $null = $pool.SetMinRunspaces(1)
    $null = $pool.SetMaxRunspaces($threads)
    $pool.ThreadOptions = [PSThreadOptions]::UseNewThread
    $pool.ApartmentState = [ApartmentState]::MTA
    $pool.Open()
    $timing['PoolOpenMs'] = $swPool.ElapsedMilliseconds

    # Stream harvester helper
    $readWorkerStreams = {
        param([object] $Ps, [int] $WorkerIndex)

        $rows = [System.Collections.Generic.List[pscustomobject]]::new()

        foreach ($e in $Ps.Streams.Error)
        {
            $rows.Add([pscustomobject]@{
                    Stream     = 'Error'
                    Worker     = $WorkerIndex
                    Message    = [string]$e.Exception.Message
                    ErrorId    = [string]$e.FullyQualifiedErrorId
                    Category   = [string]$e.CategoryInfo.Category
                    Target     = [string]$e.TargetObject
                    StackTrace = [string]$e.ScriptStackTrace
                })
        }

        foreach ($spec in @(
                @{ Name = 'Warning'; Records = $Ps.Streams.Warning }
                @{ Name = 'Verbose'; Records = $Ps.Streams.Verbose }
                @{ Name = 'Debug'; Records = $Ps.Streams.Debug }
                @{ Name = 'Information'; Records = $Ps.Streams.Information }
            ))
        {
            foreach ($rec in $spec.Records)
            {
                $msg = if ($rec -is [System.Management.Automation.InformationRecord])
                { [string]$rec.MessageData } else { [string]$rec.Message }

                $rows.Add([pscustomobject]@{
                        Stream     = $spec.Name
                        Worker     = $WorkerIndex
                        Message    = $msg
                        ErrorId    = $null
                        Category   = $null
                        Target     = $null
                        StackTrace = $null
                    })
            }
        }

        return $rows
    }

    # Worker scriptblock
    $workerScript = {
        param(
            [object[]]  $MyItems,
            [int[]]     $MyIdxs,
            [object[]]  $PlanSteps,
            [object[]]  $OrderedOut,
            [System.Collections.Concurrent.ConcurrentBag[string]] $ErrorBag
        )

        $plan = @{ Steps = $PlanSteps }

        for ($i = 0; $i -lt $MyItems.Length; $i++)
        {
            $ceParams = @{
                Item     = $MyItems[$i]
                Plan     = $plan
                ErrorBag = $ErrorBag
                Index    = $MyIdxs[$i]
            }
            $OrderedOut[$MyIdxs[$i]] = Invoke-ChainExecutor @ceParams
        }
    }

    $planStepsForWorker = @(
        $Plan.Steps | ForEach-Object { @{ Key = $_.Key; Fn = $_.Fn; Config = $_.Config } }
    )

    # Dispatch workers
    $workers = [System.Collections.Generic.List[hashtable]]::new($threads)
    $swDispatch = [System.Diagnostics.Stopwatch]::StartNew()

    for ($w = 0; $w -lt $threads; $w++)
    {
        $slice = $sliceItems[$w].ToArray()
        if (-not $slice -or $slice.Length -eq 0) { continue }
        $idxs = $sliceIdxs[$w].ToArray()

        $ps = [PowerShell]::Create()
        $cmd = $ps.AddScript($workerScript)
        [void]$cmd.AddArgument($slice).AddArgument($idxs).AddArgument($planStepsForWorker).AddArgument($ordered).AddArgument($errors)

        $ps.RunspacePool = $pool
        $async = $ps.BeginInvoke()
        $workers.Add(@{ PS = $ps; Async = $async })
    }
    $timing['DispatchMs'] = $swDispatch.ElapsedMilliseconds

    # Wait for completion
    $swWait = [System.Diagnostics.Stopwatch]::StartNew()
    $swWall = [System.Diagnostics.Stopwatch]::StartNew()
    foreach ($worker in $workers)
    {
        $remaining = [Math]::Max(50, $WaitTimeoutMs - [int]$swWall.ElapsedMilliseconds)
        if (-not $worker.Async.AsyncWaitHandle.WaitOne($remaining))
        {
            $errors.Add('Worker timed out waiting for completion.')
        }
    }
    $timing['WaitMs'] = $swWait.ElapsedMilliseconds

    # Collect results and streams
    $swCollect = [System.Diagnostics.Stopwatch]::StartNew()
    $streams = [System.Collections.Generic.List[pscustomobject]]::new()
    for ($wi = 0; $wi -lt $workers.Count; $wi++)
    {
        $worker = $workers[$wi]
        try
        {
            if ($worker.Async.IsCompleted)
            {
                $null = $worker.PS.EndInvoke($worker.Async)
            }
            else
            {
                try { $worker.PS.Stop() } catch {}
                $errors.Add('Worker did not complete before timeout; stopped forcibly.')
            }

            foreach ($row in (& $readWorkerStreams $worker.PS $wi)) { $streams.Add($row) }
        }
        catch { $errors.Add("Worker collect error: $($_.Exception.Message)") }
        finally { $worker.PS.Dispose() }
    }

    foreach ($row in $streams)
    {
        if ($row.Stream -eq 'Error') { $errors.Add("Worker [$($row.Worker)] $($row.Message)") }
    }
    $timing['CollectMs'] = $swCollect.ElapsedMilliseconds

    try { $pool.Close(); $pool.Dispose() } catch {}
    $timing['TotalMs'] = $swTotal.ElapsedMilliseconds

    foreach ($row in $streams)
    {
        if ($row.Stream -eq 'Warning') { $warnings.Add("Worker [$($row.Worker)] $($row.Message)") }
    }

    return [pscustomobject]@{
        Results  = $ordered
        Errors   = @($errors.ToArray())
        Warnings = $warnings.ToArray()
        Streams  = $streams.ToArray()
        Budget   = $budget
        Timing   = [pscustomobject]$timing
    }
}
#endregion

#region RunspaceManager
class RunspaceManager
{
    [pscustomobject] $Plan
    [nullable[int]]  $MaxWorkers = $null
    [int]            $ReservedCores = 2
    [int]            $MinItemsPerWorker = 4
    [int]            $WaitTimeoutMs = 60000

    RunspaceManager([pscustomobject]$plan)
    {
        if ($null -eq $plan) { throw 'Plan cannot be null — call Compile-Plan first and check Errors.' }
        $this.Plan = $plan
    }

    [pscustomobject] Run([object[]]$items)
    {
        $ipParams = @{
            Items             = $items
            Plan              = $this.Plan
            MaxWorkers        = $this.MaxWorkers
            ReservedCores     = $this.ReservedCores
            MinItemsPerWorker = $this.MinItemsPerWorker
            WaitTimeoutMs     = $this.WaitTimeoutMs
        }
        return Invoke-Plan @ipParams
    }
}

function New-RunspaceManager
{
    <#
    .SYNOPSIS
        Constructs a RunspaceManager instance over a compiled Plan.
    #>
    [OutputType([RunspaceManager])]
    param(
        [Parameter(Mandatory)] [pscustomobject] $Plan,
        [nullable[int]]                         $MaxWorkers = $null,
        [int]                                   $ReservedCores = 2,
        [int]                                   $MinItemsPerWorker = 4,
        [int]                                   $WaitTimeoutMs = 60000
    )

    $mgr = [RunspaceManager]::new($Plan)
    $mgr.MaxWorkers = $MaxWorkers
    $mgr.ReservedCores = $ReservedCores
    $mgr.MinItemsPerWorker = $MinItemsPerWorker
    $mgr.WaitTimeoutMs = $WaitTimeoutMs
    return $mgr
}
#endregion

Export-ModuleMember -Function @(
    'Compile-Plan'
    'Resolve-WorkerBudget'
    'Invoke-Plan'
    'New-RunspaceManager'
    'Build-Iss'
    'Import-SequenceManifest'
    'Resolve-EnabledSet'
    'Resolve-Classes'
    'Resolve-Variants'
)
