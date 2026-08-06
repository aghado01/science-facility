using namespace System
using namespace System.Collections.Concurrent
using namespace System.Management.Automation
using namespace System.Management.Automation.Runspaces
using namespace System.Threading

#Requires -Version 7.6
Set-StrictMode -Version Latest

<#
.SYNOPSIS
    RepoSnapshot V3 colonel — processor-chain compilation and runspace-pool
    dispatch (v2: plan-driven; the v1 fluent/RunMode API is retired).

.DESCRIPTION
    Two-call surface:
      Compile-Plan — validates processor scripts (AST: top-level param block
        required, interior helpers legitimate, #Requires rejected via
        $ast.ScriptRequirements), registers bodies + chain-executor into an
        InitialSessionState, returns a frozen Plan. All name resolution and
        planning happens here; workers make zero decisions.
      Invoke-Plan — slices Items round-robin across a worker budget
        (Resolve-WorkerBudget), executes the chain per item via
        Invoke-ChainExecutor inside a runspace pool, returns the
        index-stable envelope @{ Results; Errors; Warnings; Streams; Budget;
        Timing }. Errors are collected and collated like any other output
        stream — see `Streams` in the Invoke-Plan contract below.

    Items are ItemDescriptor objects dispatched verbatim (rs.core.ingest
    forwards them); processors receive them as $Item and copy-on-enrich.
    The _ChainHalt convention is owned by chain-executor (processors only
    set the property). RunspaceManager/New-RunspaceManager is a thin
    convenience holder over Invoke-Plan for repeated Run() calls with
    sticky knobs — the pipeline path (ingest) calls Invoke-Plan directly.

    Module-level #Requires is fine HERE — the prohibition is on processor
    scripts, whose bodies become ISS-registered functions where the
    directive is inert (see Compile-Plan validation).
#>

# =============================================================================
# ENUMS
# =============================================================================

enum IssPreset
{
    Bare  # Create()          — empty engine (0 cmdlets); processor scripts must be fully self-contained
    Core  # CreateDefault2    — PS core cmdlets only; default; good isolation/speed balance
    Full  # CreateDefault     — full module + provider set; use when processors need providers
}

# =============================================================================
# PURE FUNCTIONS — planning and budget; no side effects, no class state
# =============================================================================

# -----------------------------------------------------------------------------
# $script:ReadProcessorScript
# Validates and reads a single processor script file.
# Stored as a module-scoped scriptblock so Compile-Plan can hand it to raw
# [PowerShell]::Create() workers without capturing module-scope state.
# RUNSPACE BOUNDARY: must reference only its own parameters.
# -----------------------------------------------------------------------------
$script:ReadProcessorScript = {
    param([string]$Key, [string]$Path)
    $result = @{ Key = $Key; Fn = "Invoke-$Key"; Body = $null; Error = $null }
    try
    {
        if ([string]::IsNullOrWhiteSpace($Key)) { $result.Error = 'Processor key cannot be empty.'; return $result }
        if ([string]::IsNullOrWhiteSpace($Path)) { $result.Error = 'Processor path cannot be empty.'; return $result }
        if (-not (Test-Path -LiteralPath $Path)) { $result.Error = "Script not found: $Path"; return $result }

        $body = Get-Content -LiteralPath $Path -Raw

        # AST validation of the body-only contract. The positive requirement
        # is a TOP-LEVEL param block (chain-executor calls processors with two
        # positional args); a file that is just an outer function wrapper has
        # no top-level param block and fails here. Interior helper functions
        # (e.g. tp-perplexity's _MaskByRegex) are legitimate — the previous
        # regex rejected any 'function' keyword and blocked them.
        $parseErrors = $null
        $astTokens = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput(
            $body, [ref]$astTokens, [ref]$parseErrors)
        if ($parseErrors.Count -gt 0)
        {
            $result.Error = "Processor script does not parse: $($parseErrors[0].Message)"
            return $result
        }

        # #Requires check via the parser's own authority, not a regex. The
        # directive is only honored for script FILES — inert inside an
        # ISS-registered function body, whose environment Build-Iss owns.
        # (A regex over-matches: '# Requires manual setup' is an ordinary
        # comment — PowerShell's directive syntax is exactly '#Requires'.)
        if ($null -ne $ast.ScriptRequirements)
        {
            $result.Error = 'Processor scripts must not declare #Requires (ISS-load contract).'
            return $result
        }

        if ($null -eq $ast.ParamBlock)
        {
            $result.Error = 'Processor scripts must declare a top-level param($Item, $Config) block — body only, no outer function wrapper.'
            return $result
        }

        # Engine-state commands are banned for the same reason as #Requires: the
        # environment belongs to Build-Iss, and a body-only fragment must not set
        # it. Set-StrictMode was the live case — carried by only 2 of 7 processors,
        # so the fleet was already inconsistent, and under the Bare preset it is a
        # NON-terminating error: the processor keeps running WITHOUT strict mode
        # while writing to the error stream, which colonel now collects per worker.
        # The strictness that matters is structural anyway (processors probe
        # PSObject.Properties rather than assuming shape), and the test harnesses
        # set it at script scope — strictness where it catches bugs, without the
        # runtime dependency where it costs.
        # Checked over the whole fragment, interior helpers included.
        $banned = @('Set-StrictMode', 'Set-PSDebug')
        $cmdAsts = $ast.FindAll(
            { param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)
        foreach ($c in $cmdAsts)
        {
            $name = $c.GetCommandName()
            if ($null -ne $name -and $banned -contains $name)
            {
                $result.Error = "Processor scripts must not call $name — engine state belongs to Build-Iss, not to a body-only fragment (same contract as the #Requires ban)."
                return $result
            }
        }

        $result.Body = $body
    }
    catch { $result.Error = $_.Exception.Message }
    return $result
}

# -----------------------------------------------------------------------------
# Build-Iss
# Constructs an InitialSessionState from a preset + optional module list.
# NOT thread-safe — always call serially.
# -----------------------------------------------------------------------------
function Build-Iss
{
    param(
        [IssPreset] $Preset = [IssPreset]::Core,
        [string[]]  $Modules = @()
    )

    $iss = switch ($Preset)
    {
        ([IssPreset]::Bare)
        {
            # NOT ::CreateEmpty() — no such method exists on InitialSessionState.
            # Its statics are Create / CreateDefault / CreateDefault2 / CreateFrom /
            # CreateFromSessionConfigurationFile / CreateRestricted. The prior call
            # threw, leaving $iss null; Compile-Plan still reported success and the
            # failure only surfaced at dispatch as "Invoke-ChainExecutor is not
            # recognized". Bare had therefore never worked — masked because every
            # profile uses Core (every processor documents an IssPreset floor of Core).
            #
            # Create() is the empty factory, and it defaults to LanguageMode
            # NoLanguage — which rejects the AddScript this module uses at the worker
            # boundary. CreateDefault2 defaults to FullLanguage, which is why Core
            # never needed this. The mode must therefore be set explicitly.
            $bare = [InitialSessionState]::Create()
            $bare.LanguageMode = [System.Management.Automation.PSLanguageMode]::FullLanguage
            $bare
        }
        ([IssPreset]::Core) { [InitialSessionState]::CreateDefault2() }
        ([IssPreset]::Full) { [InitialSessionState]::CreateDefault() }
        default { [InitialSessionState]::CreateDefault2() }
    }

    # Fail loudly here rather than letting a null ISS travel: that is what turned a
    # bad factory call into a misleading downstream error about a missing function.
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

# -----------------------------------------------------------------------------
# Compile-Plan
# Reads + validates processor scripts, builds the ISS, registers all processor
# functions and Invoke-ChainExecutor into the ISS, returns a frozen Plan.
#
# Parameters
#   Manifest          hashtable  { 'processor-key' = 'path/to/script.ps1' }
#   Steps             ordered object[]  @{ Key = string; Config = hashtable }
#   ChainExecutorPath string     path to chain-executor.ps1
#   SharedHelperPath  string[]   optional library files whose TOP-LEVEL functions
#                                are each registered into the ISS (e.g.
#                                processors/bag-helpers.ps1). Unlike processors,
#                                these declare function wrappers.
#   IssPreset         IssPreset  enum value (default Core)
#   IssModules        string[]   extra PS modules pre-loaded into every worker
#   InitThreads       int        max concurrent bootstrap readers (default 4)
#
# Returns [pscustomobject] @{ Plan; Errors; Warnings }
#   Plan is $null when Errors is non-empty.
#   Plan shape:
#     Steps         — ordered array [pscustomobject] @{ Key; Fn; Config }
#     Iss           — InitialSessionState (processors + chain-executor loaded)
#     ProcessorKeys — string[]
# -----------------------------------------------------------------------------
function Compile-Plan
{
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

    # ── Input validation ──────────────────────────────────────────────────────
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

    # ── Collect referenced processor keys ─────────────────────────────────────
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

    # ── Phase 1: Parallel bootstrap read + validate (PSOne-style fan-out) ─────
    # Raw [PowerShell]::Create() — no pool, no ISS, no budget machinery.
    # Bypasses colonel's own ISS to avoid the bootstrap catch-22.
    # ISS construction in Phase 3 is serial (InitialSessionState is not thread-safe).

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

    # ── Phase 2: Validate loaded bodies ───────────────────────────────────────
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

    # ── Phase 3: Serial ISS construction ─────────────────────────────────────
    # InitialSessionState is not thread-safe — must be serial.
    $iss = Build-Iss -Preset $IssPreset -Modules $IssModules

    # Register processor function bodies
    foreach ($key in $referencedKeys)
    {
        $entry = $validBodies[$key]
        $iss.Commands.Add(
            [System.Management.Automation.Runspaces.SessionStateFunctionEntry]::new($entry.Fn, $entry.Body)
        )
    }

    # Register Invoke-ChainExecutor — loaded exactly like processors, same ISS mechanism.
    # chain-executor.ps1 must be body-only (no outer function wrapper), param() first.
    $chainBody = Get-Content -LiteralPath $ChainExecutorPath -Raw
    $iss.Commands.Add(
        [System.Management.Automation.Runspaces.SessionStateFunctionEntry]::new('Invoke-ChainExecutor', $chainBody)
    )

    # Register shared helper libraries. UNLIKE processors and chain-executor,
    # these files DO declare function wrappers — each top-level function is
    # registered separately, so one file can supply several helpers. The body
    # text is taken from the AST rather than by string surgery, so nested braces
    # and here-strings inside a helper are handled by the parser, not a regex.
    foreach ($helperPath in $SharedHelperPath)
    {
        $helperSrc = Get-Content -LiteralPath $helperPath -Raw
        $helperAst = [System.Management.Automation.Language.Parser]::ParseInput($helperSrc, [ref]$null, [ref]$null)
        foreach ($fn in $helperAst.FindAll(
                { param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false))
        {
            # Body.Extent.Text includes the wrapping braces; SessionStateFunctionEntry wants the interior.
            $bodyText = $fn.Body.Extent.Text
            $iss.Commands.Add(
                [System.Management.Automation.Runspaces.SessionStateFunctionEntry]::new(
                    $fn.Name, $bodyText.Substring(1, $bodyText.Length - 2))
            )
        }
    }

    # ── Phase 4: Bind steps to resolved Fn names ─────────────────────────────
    # All name resolution happens here at compile time.
    # Workers receive resolved Fn strings — no manifest lookups at runtime.
    $boundSteps = foreach ($step in $Steps)
    {
        [pscustomobject]@{
            Key    = [string]$step.Key
            Fn     = [string]$validBodies[$step.Key].Fn
            Config = $step.Config ?? @{}
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

# -----------------------------------------------------------------------------
# Resolve-WorkerBudget
# Pure function. Determines thread count for a given batch.
#
# Parameters
#   ItemCount         int           required
#   MaxWorkers        nullable[int] explicit ceiling; $null = auto
#   ReservedCores     int           cores withheld when auto (default 2)
#   MinItemsPerWorker int           grading threshold (default 4)
#
# Returns [pscustomobject] @{ Threads; Policy; Warnings; Inputs }
# -----------------------------------------------------------------------------

# TODO: adjust budget policy based on new testing
# | Items | Graded | Ceiling | Threads |
# | ---- - | ------ | ------ - | ------ - |
# | 1     | 1      | 14      | 1       |
# | 4     | 1      | 14      | 1       |
# | 8     | 2      | 14      | 2       |
# | 20    | 5      | 14      | 5       |
# | 60    | 15     | 14      | 14      |
# | 200   | 50     | 14      | 14      |

function Resolve-WorkerBudget
{
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
        $reserved = [Math]::Min($ReservedCores, $logical - 1)   # always leave at least 1 core
        $ceiling = [Math]::Max(1, $logical - $reserved)
    }

    # Grading: don't spin workers that would receive fewer than MinItemsPerWorker items
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

# =============================================================================
# Invoke-Plan
# Dispatches a compiled Plan against a batch of items using a RunspacePool.
# Pool is opened with (1, $threads) — Threads=1 is the serial case, no branch.
# Each worker calls Invoke-ChainExecutor per item in its slice.
# Results are written by index into a pre-allocated ordered array.
#
# Parameters
#   Items             object[]
#   Plan              pscustomobject   from Compile-Plan
#   MaxWorkers        nullable[int]    explicit thread ceiling; $null = auto
#   ReservedCores     int              (default 2)
#   MinItemsPerWorker int              (default 4)
#   WaitTimeoutMs     int              (default 60000)
#
# Returns [pscustomobject] @{ Results; Errors; Warnings; Streams; Budget; Timing }
#
#   Streams   ALL five worker streams, structured and collated in worker order:
#             @{ Stream; Worker; Message; ErrorId; Category; Target; StackTrace }
#             Stream is Error|Warning|Verbose|Debug|Information. Errors are one
#             stream among five, not a special case — Warning/Verbose/Debug/
#             Information were formerly discarded, so a processor's Write-Warning
#             vanished silently. Records keep FullyQualifiedErrorId, CategoryInfo,
#             TargetObject and ScriptStackTrace, which ToString() destroys.
#   Errors    flat string[] projection kept for existing consumers (ingest merges
#             it; suites assert on it). Fed from the structured rows plus
#             chain-executor's per-item entries and dispatch-level failures.
#   Warnings  budget warnings plus worker Warning records.
# =============================================================================
function Invoke-Plan
{
    param(
        # AllowEmptyCollection: Mandatory alone rejects @() at binding time,
        # which made the intentional count-0 early-return below unreachable
        # for direct callers (ingest short-circuits earlier, harnesses don't).
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

    # ── Budget ────────────────────────────────────────────────────────────────
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

    # Pre-allocate index-stable output array.
    # Untyped to prevent PS from unrolling a single-null [object[]] on assignment.
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

    # ── Slice items round-robin across workers ────────────────────────────────
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


    # ── Open pool — (1, $threads); Threads=1 is serial, no special branch ────
    $swPool = [System.Diagnostics.Stopwatch]::StartNew()
    $pool = [RunspaceFactory]::CreateRunspacePool($Plan.Iss)
    $null = $pool.SetMinRunspaces(1)
    $null = $pool.SetMaxRunspaces($threads)
    $pool.ThreadOptions = [PSThreadOptions]::UseNewThread
    $pool.ApartmentState = [ApartmentState]::MTA
    $pool.Open()
    $timing['PoolOpenMs'] = $swPool.ElapsedMilliseconds

    # ── Stream collation ──────────────────────────────────────────────────────
    # Results are collated index-stably; streams get the same treatment rather
    # than being flattened to one joined string per worker. Errors are ONE stream
    # among five — Warning/Verbose/Debug/Information used to be discarded
    # outright, so a processor calling Write-Warning vanished without trace.
    # Records are kept structured: ToString() throws away FullyQualifiedErrorId,
    # CategoryInfo, TargetObject and ScriptStackTrace, which are precisely the
    # fields worth having when a processor misbehaves inside a runspace.
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
                # InformationRecord carries MessageData; the rest carry Message.
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

    # ── Worker scriptblock — RUNSPACE BOUNDARY ────────────────────────────────
    # using namespace directives are parse-time and module-scoped — they do NOT
    # propagate into AddScript() contexts. All .NET types here must be fully qualified.
    $workerScript = {
        param(
            [object[]]  $MyItems,
            [int[]]     $MyIdxs,
            [object[]]  $PlanSteps,    # array of hashtable @{ Key; Fn; Config }
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

    # Serialize Plan.Steps as plain hashtables for safe runspace boundary crossing.
    # pscustomobject properties survive serialization but hashtables are safer and
    # avoid deserialization type-fidelity surprises with nested objects.
    $planStepsForWorker = @(
        $Plan.Steps | ForEach-Object { @{ Key = $_.Key; Fn = $_.Fn; Config = $_.Config } }
    )

    # ── Dispatch ──────────────────────────────────────────────────────────────
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

    # ── Wait ──────────────────────────────────────────────────────────────────
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

    # ── Collect results, streams, and dispose workers ─────────────────────────
    # Worker order is deterministic here (the $workers list is built in slice
    # order), so $streams is collated deterministically even though $errors
    # remains a ConcurrentBag whose own ordering is not guaranteed.
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

            # Harvest EVERY stream, whether or not HadErrors is set — warnings and
            # verbose output are worth collecting from a worker that succeeded.
            foreach ($row in (& $readWorkerStreams $worker.PS $wi)) { $streams.Add($row) }
        }
        catch { $errors.Add("Worker collect error: $($_.Exception.Message)") }
        finally { $worker.PS.Dispose() }
    }

    # Back-compat projection: Errors stays a flat string[] for existing consumers
    # (ingest merges it; suites assert on it), now fed from the structured rows.
    foreach ($row in $streams)
    {
        if ($row.Stream -eq 'Error') { $errors.Add("Worker [$($row.Worker)] $($row.Message)") }
    }
    $timing['CollectMs'] = $swCollect.ElapsedMilliseconds

    # ── Pool teardown ─────────────────────────────────────────────────────────
    try { $pool.Close(); $pool.Dispose() } catch {}

    $timing['TotalMs'] = $swTotal.ElapsedMilliseconds

    # Worker Warning records join the envelope's Warnings (previously only
    # Resolve-WorkerBudget could contribute, so processor warnings were lost).
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

# =============================================================================
# RunspaceManager / New-RunspaceManager
# Thin holder for a compiled Plan plus runtime knobs.
# All planning lives in Compile-Plan. This class only holds state between
# Run() calls and surfaces the Invoke-Plan parameters as settable properties.
#
# Typical usage:
#   $compiled = Compile-Plan -Manifest $m -Steps $s -ChainExecutorPath $p
#   if ($compiled.Errors) { throw ($compiled.Errors -join "`n") }
#
#   $manager = New-RunspaceManager -Plan $compiled.Plan
#   $result  = $manager.Run($items)
#   # $result.Results  — [object[]] ordered by original batch index
#   # $result.Errors   — string[]
#   # $result.Budget   — thread count + policy detail
#   # $result.Timing   — phase breakdown in ms
# =============================================================================
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

Export-ModuleMember -Function @(
    'Compile-Plan'
    'Resolve-WorkerBudget'
    'Invoke-Plan'
    'New-RunspaceManager'
    'Build-Iss'
)
