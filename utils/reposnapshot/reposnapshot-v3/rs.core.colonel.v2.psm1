#Requires -Version 7.6

using namespace System
using namespace System.Collections.Concurrent
using namespace System.Management.Automation
using namespace System.Management.Automation.Runspaces
using namespace System.Threading

<#
.SYNOPSIS
    RepoSnapshot V3 colonel — processor-chain compilation and runspace-pool dispatch.

.DESCRIPTION
    Two-call API surface:
      Compile-Plan: Validates processor scripts via AST, registers bodies and
                    chain_executor into an InitialSessionState, returns a frozen Plan.
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
# Sequencer resolution: enable, then one occupancy walk per extension, interned
# as a family. The compiler is the only component that reads the sequencer;
# nothing below plan compilation branches on file type. Import-SequenceManifest,
# Resolve-EnabledSet, Resolve-Chain, and Resolve-Family are pure over hashtables
# except the single read in Import-SequenceManifest.

# Private. Binds a declared filename to the on-disk inventory, returning the stub
# the manifest is keyed by. Catches both an absent processor and a right-stem /
# wrong-extension typo, which a stub comparison alone would let through.
function Resolve-ProcessorFile
{
    param(
        [Parameter(Mandatory)] [string]    $File,
        [Parameter(Mandatory)] [hashtable] $Manifest,
        [Parameter(Mandatory)] [string]    $Where
    )

    $key = [System.IO.Path]::GetFileNameWithoutExtension($File)
    if (-not $Manifest.ContainsKey($key))
    {
        throw "Import-SequenceManifest: $Where names '$File', which has no processor on disk (known: $($Manifest.Keys -join ', '))."
    }

    $onDisk = [System.IO.Path]::GetFileName([string]$Manifest[$key])
    if ($onDisk -ne $File)
    {
        throw "Import-SequenceManifest: $Where names '$File', but the processor on disk is '$onDisk'."
    }

    return $key
}

function Import-SequenceManifest
{
    <#
    .SYNOPSIS
        Loads and validates the sequence manifest into a normalized structure.

    .DESCRIPTION
        Every declared convention is enforced here and every failure is terminating:
        a malformed manifest is a stop, not a degraded run.

    .OUTPUTS
        [PSCustomObject] @{ Path; Processors }
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
    # Normalize entries. Group and Rank are ordinals; an entry is routed when it
    # carries a Routing array in place of a File, so routed-ness is structural and
    # needs no sigil to mark it.
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

        # Exactly one of File or Routing: a slot either names its processor outright
        # or defers to per-extension occupancy. Both, or neither, is a declaration bug.
        $hasFile = $e.Contains('File') -and -not [string]::IsNullOrWhiteSpace([string]$e['File'])
        $hasRoutes = $e.Contains('Routing') -and $null -ne $e['Routing']
        if ($hasFile -eq $hasRoutes)
        {
            throw "Import-SequenceManifest: '$key' must declare exactly one of File or Routing."
        }

        $procKey = $null
        $routes = @()

        if ($hasFile)
        {
            $procKey = Resolve-ProcessorFile -File ([string]$e['File']) -Manifest $Manifest -Where "'$key'"
        }
        else
        {
            $claimed = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($r in @($e['Routing']))
            {
                if ($r -isnot [System.Collections.IDictionary] -or -not $r.Contains('File'))
                {
                    throw "Import-SequenceManifest: a route under '$key' names no File."
                }

                $rFile = [string]$r['File']
                $rKey = Resolve-ProcessorFile -File $rFile -Manifest $Manifest -Where "route '$rFile' under '$key'"

                $exts = @()
                if ($r.Contains('Extensions') -and $null -ne $r['Extensions']) { $exts = @($r['Extensions']) }
                if ($exts.Count -eq 0)
                {
                    throw "Import-SequenceManifest: route '$rFile' under '$key' declares no Extensions."
                }

                # Extensions normalize to the crawler's leading-dot form. Occupancy of
                # a slot must be unambiguous, so no two routes may claim the same one —
                # but separate slots claiming it is legitimate and expected.
                $norm = [System.Collections.Generic.List[string]]::new()
                foreach ($x in $exts)
                {
                    $ext = '.' + ([string]$x).TrimStart('.').ToLowerInvariant()
                    if (-not $claimed.Add($ext))
                    {
                        throw "Import-SequenceManifest: extension '$ext' is claimed by two routes under '$key'."
                    }
                    $norm.Add($ext)
                }

                $routes += [pscustomobject]@{ Key = $rKey; File = $rFile; Extensions = $norm.ToArray() }
            }

            if ($routes.Count -eq 0)
            {
                throw "Import-SequenceManifest: '$key' declares an empty Routing array."
            }
        }

        $procs[$key] = @{
            Slot     = $key
            Group    = $group
            Rank     = $rank
            Default  = if ($e.Contains('Default')) { [bool]$e['Default'] } else { $false }
            Requires = $requires
            Key      = $procKey
            Routes   = $routes
            IsRouted = $hasRoutes
        }
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
        Path       = $Path
        Processors = $procs
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
            throw "Resolve-EnabledSet: '$k' has no sequencer entry. Add one, or supply the chain literally with -RunVerbatim."
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

# Private. Positional chain identity. NOT Compare-Object, which defaults to set
# semantics — @('a','b') and @('b','a') compare equal there, so two chains with the
# same processors in a different order would intern as one. That is safe only while
# the canon fixes order, and leaning on an invariant maintained elsewhere is the
# coupling this design keeps removing.
function Test-SameChain
{
    param([object[]]$A, [object[]]$B)

    $a = @($A)
    $b = @($B)
    if ($a.Count -ne $b.Count) { return $false }
    for ($i = 0; $i -lt $a.Count; $i++)
    {
        if ($a[$i].Key -ne $b[$i].Key) { return $false }
        if ($a[$i].Slot -ne $b[$i].Slot) { return $false }
    }
    return $true
}

function Resolve-Chain
{
    <#
    .SYNOPSIS
        Compiles the dense step list one extension gets, in a single walk of the canon.

    .DESCRIPTION
        Occupancy is tested at the slot where it matters, in the same pass that emits
        the ordered steps: a routed slot no route claims is spliced out and leaves no
        hole. There is no intermediate resolution to carry between passes, and no
        identity to derive — the chain IS the answer.

    .PARAMETER OrderedSlots
        Enabled slots pre-sorted by (Group, Rank). Sorted once by the caller, because
        the canon does not change between extensions.

    .OUTPUTS
        [PSCustomObject[]] @{ Key; Slot; Config }, in canon order
    #>
    param(
        [Parameter(Mandatory)] [pscustomobject]                      $Sequence,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]]   $OrderedSlots,
        [AllowNull()] [string]                                       $Extension
    )

    $procs = $Sequence.Processors

    $ext = ''
    if (-not [string]::IsNullOrWhiteSpace($Extension))
    {
        $ext = '.' + ([string]$Extension).TrimStart('.').ToLowerInvariant()
    }

    $steps = foreach ($slot in @($OrderedSlots))
    {
        $meta = $procs[$slot]

        if ($meta.IsRouted)
        {
            $hit = @($meta.Routes | Where-Object { $ext -in $_.Extensions })
            if ($hit.Count -eq 0) { continue }
            $key = $hit[0].Key
        }
        else { $key = $meta.Key }

        [pscustomobject]@{ Key = $key; Slot = $slot; Config = @{} }
    }

    return @($steps)
}

function Resolve-Family
{
    <#
    .SYNOPSIS
        Compiles one chain per distinct resolution across the corpus extension set.

    .DESCRIPTION
        Interning is a CACHE over unique extensions, not a relation: extensions whose
        chains compare equal share one entry, so .ps1/.psm1/.psd1 collapse because
        their compiled chains agree — not because anything about them stringifies the
        same. Ids are therefore opaque ordinals: nothing can parse them, and unlike a
        guid they are stable across runs on the same corpus, which the payload's
        determinism depends on.

        DefaultVariant names the pass-through chain: the canon with every routed slot
        spliced out. It is always compiled, because "no route claims this file" is an
        expected outcome rather than a failure — an extension the strippers do not
        cover, or a file with no extension at all, still flows through the rest of
        the canon. An extension that resolves nothing interns onto it like any other.

    .OUTPUTS
        [PSCustomObject] @{ Variants; ExtensionMap; DefaultVariant }
    #>
    param(
        [Parameter(Mandatory)] [pscustomobject]                       $Sequence,
        [Parameter(Mandatory)] [string[]]                             $Enabled,
        [AllowEmptyCollection()] [AllowNull()] [string[]]             $Extensions = @()
    )

    $procs = $Sequence.Processors

    # The canon, resolved once — not per extension.
    $orderedSlots = @(@($Enabled) | Sort-Object { $procs[$_].Group }, { $procs[$_].Rank })

    # Sorted, so ordinal ids are the same on every run over the same corpus.
    $unique = @(
        @($Extensions) |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { '.' + ([string]$_).TrimStart('.').ToLowerInvariant() } |
            Sort-Object -Unique
    )

    $variants = @{}
    $extMap = @{}
    $next = 0

    # Pass-through, compiled first and always. A file no route claims — an unknown
    # extension, or none at all — takes the canon with every routed slot spliced
    # out. That is a VALID chain, one step shorter, not an error: requesting
    # StripComments over a mixed corpus means "strip where a stripper exists", and
    # everything else flows through unstripped. Pruning this when every corpus
    # extension happens to be routed is a false economy that breaks the guarantee
    # for extensionless files.
    $defaultId = [string]$next
    $next++
    $variants[$defaultId] = Resolve-Chain -Sequence $Sequence -OrderedSlots $orderedSlots -Extension ''

    foreach ($ext in $unique)
    {
        $chain = Resolve-Chain -Sequence $Sequence -OrderedSlots $orderedSlots -Extension $ext

        $id = $null
        foreach ($k in @($variants.Keys))
        {
            if (Test-SameChain $variants[$k] $chain) { $id = $k; break }
        }
        if ($null -eq $id)
        {
            $id = [string]$next
            $next++
            $variants[$id] = $chain
        }

        $extMap[$ext] = $id
    }

    return [pscustomobject]@{
        Variants       = $variants
        ExtensionMap   = $extMap
        DefaultVariant = $defaultId
    }
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
        [object[]]                          $Steps,
        [string]                            $SequenceManifest,
        [AllowEmptyCollection()][AllowNull()][string[]] $IncludeProcessors = @(),
        [AllowEmptyCollection()][AllowNull()][string[]] $Extensions = @(),
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
    if (-not $SequenceManifest -and ($null -eq $Steps -or $Steps.Count -eq 0))
    {
        $errors.Add('Neither SequenceManifest nor Steps was supplied — nothing to compile.')
        return [pscustomobject]@{ Plan = $null; Errors = $errors.ToArray(); Warnings = $warnings.ToArray() }
    }
    if (-not (Test-Path -LiteralPath $ChainExecutorPath))
    {
        $errors.Add("chain_executor script not found: $ChainExecutorPath")
        return [pscustomobject]@{ Plan = $null; Errors = $errors.ToArray(); Warnings = $warnings.ToArray() }
    }

    # Either the sequencer compiles a plan family, or a literal Steps list runs as a
    # family of one. Everything downstream sees the same shape, so Invoke-Plan never
    # learns which path produced it and grows no mode branch.
    $variants = @{}
    $routing = @{}
    $defaultVariant = $null

    if ($SequenceManifest)
    {
        try
        {
            $sequence = Import-SequenceManifest -Path $SequenceManifest -Manifest $Manifest
            $enabled = Resolve-EnabledSet -Sequence $sequence -IncludeProcessors $IncludeProcessors
            $family = Resolve-Family -Sequence $sequence -Enabled $enabled -Extensions $Extensions
            $variants = $family.Variants
            $routing = $family.ExtensionMap
            $defaultVariant = $family.DefaultVariant
        }
        catch
        {
            $errors.Add($_.Exception.Message)
            return [pscustomobject]@{ Plan = $null; Errors = $errors.ToArray(); Warnings = $warnings.ToArray() }
        }
    }
    else
    {
        # A literal chain is a family of one that routes nothing, so every item takes it.
        $variants['0'] = @($Steps)
        $defaultVariant = '0'
    }

    $referencedKeys = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($vk in $variants.Keys)
    {
        foreach ($step in $variants[$vk])
        {
            if ([string]::IsNullOrWhiteSpace($step.Key))
            {
                $errors.Add('A step has an empty or missing Key.')
                continue
            }
            [void]$referencedKeys.Add($step.Key)
        }
    }
    if ($referencedKeys.Count -eq 0)
    {
        $errors.Add('No variant references a processor — nothing to execute.')
        return [pscustomobject]@{ Plan = $null; Errors = $errors.ToArray(); Warnings = $warnings.ToArray() }
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

    # Bind steps to resolved Fn names and load external JSON configs, once per variant.
    # The loop body is variant-agnostic: it only ever sees one step at a time.
    $boundVariants = @{}
    foreach ($vk in $variants.Keys)
    {
    $boundSteps = foreach ($step in $variants[$vk])
    {
        $key = [string]$step.Key

        # The slot a step fills is the sequencer's fact, not the processor's — a
        # routed processor cannot know which capability it was chosen for. Carry it
        # in the config so the Processing trail can name the capability that ran.
        $slot = ''
        if ($step -is [System.Collections.IDictionary])
        {
            if ($step.Contains('Slot')) { $slot = [string]$step['Slot'] }
        }
        elseif ($step.PSObject.Properties['Slot'])
        {
            $slot = [string]$step.PSObject.Properties['Slot'].Value
        }
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

        if ($slot) { $effectiveConfig['Slot'] = $slot }

        [pscustomobject]@{
            Key    = $key
            Slot   = $slot
            Fn     = [string]$validBodies[$key].Fn
            Config = $effectiveConfig
        }
    }
        $boundVariants[$vk] = @($boundSteps)
    }

    return [pscustomobject]@{
        Plan     = [pscustomobject]@{
            Variants       = $boundVariants
            Routing        = $routing
            DefaultVariant = $defaultVariant
            Iss            = $iss
            ProcessorKeys  = @($referencedKeys)
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
        [int]                                   $WaitTimeoutMs = 90000
    )

    $errors = [System.Collections.Concurrent.ConcurrentBag[string]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()
    $timing = @{}
    $swTotal = [System.Diagnostics.Stopwatch]::StartNew()

    # A plan with no variants would dispatch every item through an empty chain and
    # return unprocessed content with no failure anywhere — the loudest possible bug
    # rendered silent. Refuse it here, at the point of use.
    $variantMap = @{}
    $vProp = $Plan.PSObject.Properties['Variants']
    if ($vProp -and $vProp.Value -is [System.Collections.IDictionary]) { $variantMap = $vProp.Value }
    if ($variantMap.Count -eq 0)
    {
        return [pscustomobject]@{
            Results  = [object[]]::new($Items.Count)
            Errors   = @('Plan carries no compiled variants — nothing to dispatch.')
            Warnings = $warnings.ToArray()
            Streams  = @()
            Budget   = $null
            Timing   = [pscustomobject]@{ TotalMs = 0 }
        }
    }

    $routingMap = @{}
    $rProp = $Plan.PSObject.Properties['Routing']
    if ($rProp -and $rProp.Value -is [System.Collections.IDictionary]) { $routingMap = $rProp.Value }

    $defaultVariant = ''
    $dProp = $Plan.PSObject.Properties['DefaultVariant']
    if ($dProp -and $null -ne $dProp.Value) { $defaultVariant = [string]$dProp.Value }

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

    # Slice items round-robin, carrying each item's variant key alongside. Round-robin
    # stays the right shape under a family: every worker gets a representative mix, so
    # cost-skew between variants never concentrates in one slice.
    $sliceItems = [System.Collections.Generic.List[object][]]::new($threads)
    $sliceIdxs = [System.Collections.Generic.List[int][]]::new($threads)
    $sliceKeys = [System.Collections.Generic.List[string][]]::new($threads)
    for ($t = 0; $t -lt $threads; $t++)
    {
        $sliceItems[$t] = [System.Collections.Generic.List[object]]::new()
        $sliceIdxs[$t] = [System.Collections.Generic.List[int]]::new()
        $sliceKeys[$t] = [System.Collections.Generic.List[string]]::new()
    }
    for ($i = 0; $i -lt $count; $i++)
    {
        # Route on the Extension the crawler already stamped — measured at the point
        # of authority, never re-derived here. A miss (unknown extension, none at
        # all, or a literal chain that routes nothing) falls to DefaultVariant.
        $ext = ''
        $extProp = $Items[$i].PSObject.Properties['Extension']
        if ($extProp) { $ext = [string]$extProp.Value }

        $vk = ''
        if ($ext -and $routingMap.ContainsKey($ext)) { $vk = [string]$routingMap[$ext] }
        if (-not $vk) { $vk = $defaultVariant }

        if (-not $vk -or -not $variantMap.ContainsKey($vk))
        {
            $errors.Add("No compiled chain covers item $i (extension '$ext') — the plan does not cover this corpus.")
            continue
        }

        $slot = $i % $threads
        $sliceItems[$slot].Add($Items[$i])
        $sliceIdxs[$slot].Add($i)
        $sliceKeys[$slot].Add($vk)
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
            [string[]]  $MyKeys,
            [hashtable] $Family,
            [object[]]  $OrderedOut,
            [System.Collections.Concurrent.ConcurrentBag[string]] $ErrorBag
        )

        # One plan object per variant, built once; per item this is a lookup, never a
        # decision. The Family is shared by reference across every worker and is read
        # only — total plan storage for a run is V chains, not N.
        $plans = @{}
        foreach ($k in $Family.Keys) { $plans[$k] = @{ Steps = $Family[$k] } }

        for ($i = 0; $i -lt $MyItems.Length; $i++)
        {
            $ceParams = @{
                Item     = $MyItems[$i]
                Plan     = $plans[$MyKeys[$i]]
                ErrorBag = $ErrorBag
                Index    = $MyIdxs[$i]
            }
            $OrderedOut[$MyIdxs[$i]] = Invoke-ChainExecutor @ceParams
        }
    }

    # Marshal the family once, keeping the deliberate minimal step shape, and share
    # the one object across every worker. In-process runspaces share the heap, so
    # this passes by reference — workers must treat it as immutable.
    $familyForWorkers = @{}
    foreach ($vk in $variantMap.Keys)
    {
        $familyForWorkers[$vk] = @(
            $variantMap[$vk] | ForEach-Object { @{ Key = $_.Key; Fn = $_.Fn; Config = $_.Config } }
        )
    }

    # Dispatch workers
    $workers = [System.Collections.Generic.List[hashtable]]::new($threads)
    $swDispatch = [System.Diagnostics.Stopwatch]::StartNew()

    for ($w = 0; $w -lt $threads; $w++)
    {
        $slice = $sliceItems[$w].ToArray()
        if (-not $slice -or $slice.Length -eq 0) { continue }
        $idxs = $sliceIdxs[$w].ToArray()
        $keys = $sliceKeys[$w].ToArray()

        $ps = [PowerShell]::Create()
        $cmd = $ps.AddScript($workerScript)
        [void]$cmd.AddArgument($slice).AddArgument($idxs).AddArgument($keys).AddArgument($familyForWorkers).AddArgument($ordered).AddArgument($errors)

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
    [int]            $WaitTimeoutMs = 90000

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
        [int]                                   $WaitTimeoutMs = 90000
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
    'Resolve-Chain'
    'Resolve-Family'
)
