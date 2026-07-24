# Changelog — rs.core - formerly threadparser/v2-new

## 2026-07-23 — rs.core.numerics consolidation

### rs.core.numerics.psm1 — new module, replaces rs.core.hash / rs.core.lsh / rs.core.measures

- **The three G1 placeholder modules are deleted.** They were empirically non-functional
  (FNV/Pearson overflow throws, dead rolling-hash surface via the class default-param trap,
  Levenshtein 2D comma-index throw, Hamming sign-bit infinite loop) — full defect inventory
  in `issues/v3/rs-core-numerics-cross-exam-20260723.md`, design in
  `issues/v3/rs.core.numerics-design.md`.
- **Demand-driven surface** (sharding + near-term thread-corpus): identity (`Get-PathHash`,
  `Get-ContentHash`, `Get-StreamHash` — SHA256 hex), signatures (`Get-SimHash` BM25-saturated
  with optional IDF corpus weighting via `Get-DocStats`, `Get-MinHashSignature`,
  `Get-JaccardEstimate`), measures (`Get-HammingDistance/-Similarity` — chunked, any-width
  sigs, BitOperations popcount; `Get-JaccardSimilarity/-Distance` — empty-set safe, J(∅,∅)=1;
  `Get-LevenshteinDistance/-Similarity` — two-row DP, explicit `-CaseInsensitive`;
  `Get-CosineSimilarity`).
- **Provenance**: SimHash/MinHash ported from mathdig `hashlib-new.ps1` (masked-uint64
  generation, composite snapshot `json-jsonl_20260424_022119`); pinned lineage vectors in
  tests guarantee bit-identical outputs. Classes are internal — function-only surface, no
  `using module` needed by consumers.
- **Masked-arithmetic law** documented in the module header (5 rules distilled from the
  cross-exam); `processors/tests/rs-numerics.tests.ps1` keeps the four G1 traps as
  permanent regressions (sign-bit Hamming runs under a 3 s hang guard).
- **rs.core.sharding.psm1**: two imports (hash + lsh) replaced by one (numerics); call
  sites unchanged (`Get-PathHash`, `Get-ContentHash -Content`, `Get-SimHash -Text`).
  SimHash values in shard metadata change generation — no compat burden, the G1 SimHash
  always threw so no metadata ever carried one.
- **Excluded by design** (stay in the snapshot inventory until demand exists): CTPH, TLSH,
  CDC/rolling-window chunking, Compare-WithMetric dispatcher, Manhattan/Chebyshev/Angular/
  Dice/PrimeFactor, Mahalanobis/KL/JS, PMI/co-occurrence/entropy family.

## 2026-04-22 — Crawler / ignore compiler decoupling (continued)

### rs.core.ignore.psm1 — IgnoreDefaults, sentinel aggregate, empty-sentinel short-circuit

- **`$IgnoreDefaults` parameter added to `New-IgnoreCompiler`**: `[string[]]`, defaults to
  `@('.snapshot/', '.git/', 'node_modules/')`. Prepended to `$IgnorePatterns` before pipeline entry.
  Visible and overridable — pass `@()` to suppress entirely. No hardcoded tiers; single param, consistent
  treatment. Combined list replaces the prior `$IgnorePatterns`-only injection at the root node.
- **`$SentinelIgnoreFiles` aggregate field added to `IgnoreCompiler` class**: `[List[PSCustomObject]]`,
  populated during the factory sentinel scan. Stores `@{ NodePath; Source; Globs }` for every sentinel
  file successfully read across all nodes. Accessible on the compiler instance for diagnostics after
  `Invoke()` completes without walking every node.
- **Aggregate exposed on factory return shape**: `New-IgnoreCompiler` now returns
  `@{ CompiledNodes; SentinelIgnoreFiles }` instead of a raw array. `CompiledNodes` is passed to
  `Invoke-IgnoreFilter -CompiledNodes`; `SentinelIgnoreFiles` is the flat cross-tree diagnostic list.
  **Downstream note**: any existing call passing `$compiled` directly to `Invoke-IgnoreFilter -CompiledNodes`
  must be updated to `$compiled.CompiledNodes`.
- **Empty `$SentinelFileNames` short-circuit**: `IgnoreFiles` stamp is now separated from the sentinel
  scan loop. All nodes always get `IgnoreFiles = [List[PSCustomObject]]::new()` (required by constructor).
  The file-reading, `$remainingFiles` rebuild, and `Files` mutation are gated behind
  `if ($SentinelFileNames.Count -gt 0)` — passing `@()` skips all I/O and no `Files` lists are touched.
- **Sentinel pruning from `Files`**: sentinels are removed from `$node.Files` in the same pass that
  reads them. They do not appear in snapshot output. On read failure the file is still pruned — consumed
  as a configuration candidate regardless of parse success.

## 2026-04-22 — Crawler / ignore compiler decoupling

### rs.core.crawler.psm1 — sentinel file concerns removed

- **`SentinelIgnoreFiles` field removed**: crawler no longer holds or reads ignore file names.
- **`ReadIgnoreFiles` method removed**: glob parsing and sentinel detection moved to ignore compiler.
- **`IgnoreFiles` property removed from node shape**: root and child nodes now carry only `NodePath`,
  `AbsolutePath`, `NodeDepth`, and `Files`. Crawler owns filesystem structure and file metadata only.
- **Constructor and factory cleaned up**: `sentinelIgnoreFileNames` param and all related stubs removed.
  `New-FileSystemCrawler` is now a single-param call.
- **All commented-out stubs removed**: transplant to ignore compiler is complete; no vestigial
  reference code remains.

### rs.core.ignore.psm1 — absorbs sentinel scan; constructor hardened

- **`using namespace System.IO` added**: required by `[Path]::GetFileName` and `[File]::ReadAllLines`
  in the sentinel scan.
- **`IgnoreCompiler` constructor made `hidden`**: enforces factory-only construction. Direct
  `[IgnoreCompiler]::new()` calls from outside the module are blocked at the language level.
- **Sentinel scan added to `New-IgnoreCompiler`**: after normalizing the crawler graph to `$flatNodes`,
  walks every node's `Files` list, matches filenames against `$SentinelFileNames`, reads and parses
  matching files (stripping blank lines and `#` comments), and stamps `IgnoreFiles = [List[PSCustomObject]]`
  on each node before passing to the constructor. Failures are non-fatal (`Write-Warning`).
- **`SentinelFileNames` parameter added to `New-IgnoreCompiler`**: `[string[]]`, defaults to
  `@('.gitignore', '.snapignore')`. Moves the default list from the crawler's removed factory param.
- **Vestigial `else` branch removed from constructor**: `IgnorePatterns` injection previously had a
  type-check + fallback array path. Sentinel scan always stamps a `List[PSCustomObject]`, so the
  `Insert(0, ...)` branch is always taken. Dead branch excised.
- **Input contract updated**: nodes no longer carry `IgnoreFiles` from the crawler. Contract now
  specifies `Files` only; `IgnoreFiles` is built internally by the sentinel scan.
- **Namespace references normalized**: `[IO.Path]` and `[System.IO.Path]` consolidated to `[Path]`
  throughout, consistent with the `using namespace System.IO` declaration.
- **Module synopsis corrected**: "Translate pipeline" → "Gather-Scatter pipeline" (Stage 4 name).
- **`Invoke-IgnoreFilter` description corrected**: stale `[IO.Path]::GetRelativePath()` reference
  updated to `[Path]::GetRelativePath()`.
- **"backward compat" label removed** from `Test-PathIgnored` comment — no releases, no external users.

## 2026-04-22 — V3 pipeline maturation: ingest, ignore filter, internals, colonel.v2

### rs.core.internals.psm1 — horizontal utility reframe

- **Import guidance updated**: rs.core.internals.psm1 is now explicitly documented as a horizontal
  utility designed to be imported by any pipeline member, not just the top-level
  orchestrator. Module-level header added: no domain logic, no rs.core dependencies,
  freely importable by any stage or caller. "Admiral's responsibility" framing removed
  from load-order notes across the pipeline.

### rs.core.ingest.psm1 — self-imports internals; simplified to colonel orchestration only

- **Self-imports internals**: `Import-Module "$PSScriptRoot/rs.core.internals.psm1" -Force`
  added at module scope. Eliminates fragile implicit load-order dependency. Any module
  that needs internals should follow the same pattern — import directly, don't duplicate
  or assume ambient availability.
- **Extension filtering and `MaxSizeBytes` removed**: both metadata gates moved upstream
  to `Invoke-IgnoreFilter`. `Invoke-Ingest` now owns only colonel orchestration (compile
  - dispatch). `$ingestOwn` trimmed to `@('FilteredGraph')`.
- **Graph normalization updated**: accepts `@{ Graph; Skipped }` shape from
  `Invoke-IgnoreFilter` and merges upstream `Skipped` entries into its own output.
  Back-compat: plain dictionary / flat array input still works.
- **Introduced** (same session): new pipeline stage between `Invoke-IgnoreFilter` and
  colonel. `Invoke-Ingest` declares only the one param it uniquely owns; all
  `Compile-Plan` / `Invoke-Plan` params surfaced via `DynamicParam` using
  `New-ForwardedParamDictionary`. Runtime routing partitions `$PSBoundParameters`
  by inspecting each colonel function's declared parameter set — no hardcoded
  forwarding lists.

### rs.core.ignore.psm1 — metadata pre-filtering in Invoke-IgnoreFilter

- **Size ceiling and extension blacklist moved here from ingest**: both filters applied
  inside `Invoke-IgnoreFilter` immediately after `RelativePath` stamping, before ignore
  regex evaluation and before branch pruning. Already holds per-file metadata; runs
  before any I/O — the earliest meaningful elimination point.
  - `Invoke-IgnoreFilter` gains `MaxSizeBytes` and `ExtensionBlacklist` params.
  - Return type changed from raw `Dictionary[string, PSCustomObject]` to
    `[PSCustomObject] @{ Graph; Skipped }`. `Skipped` carries `FileTooLarge` and
    `ExtensionBlacklisted` entries with typed metadata.
  - Pre-filter loop stamps `RelativePath`, checks size, checks extension — one pass,
    no extra I/O.
- **`$script:HardExtensionBlacklist` moved here**: replaces old `$FileExtBlacklist`
  stub. Expanded list: images, video/audio, archives, compiled binaries, documents,
  fonts, data/model blobs.

### rs.core.colonel.v2.psm1 — backtick cleanup

- All line-continuation backticks replaced. Cmdlet calls converted to splat style
  (`@budgetParams`, `@ceParams`, `@ipParams`); `.AddScript().AddArgument()...` chain
  replaced with intermediate `$cmd` variable and single chained call.

### processors/file-read.ps1 — \_ChainHalt on failure

- Both error paths (NUL/binary content and read exceptions) now stamp `_ChainHalt = $true`
  on the returned `PSCustomObject` in addition to `ReadError`. Downstream chain executor
  can short-circuit remaining processors without inspecting the error type.
- Shallow copy of `$Item` fields (`AbsolutePath`, `SizeBytes`, `RelativePath`, `NodePath`)
  taken up-front — result is always a clean object regardless of exit path.

### processors/format.psm1 → format-ws.psm1

- Renamed. No stale references found in the workspace — no cascading changes.

### Architecture decisions settled

- Profile-based glob routing stays inside colonel (`Compile-Plan` / `Invoke-Plan`)
  — not abstracted to the caller.
- Post-ignore eligibility filtering is a discrete pipeline stage (ingest), not ad-hoc
  caller code.
- `rs.core.internals.psm1` is the canonical home for pipeline horizontal utilities;
  pipeline members import it directly rather than duplicating or relying on ambient load order.

## 2026-04-10 — tests/ — colonel-bench.ps1 generalized + test-cases added

- **`colonel-bench.ps1` moved** from `rs.core/colonel/` into `rs.core/tests/`
  alongside `colonel.tests.ps1`.
- **`colonel-bench.ps1` rewritten as general-purpose bench**: hardcoded stroll-corpus
  and `format` processor replaced with params `-CorpusPath`, `-Filter`, `-Processor`,
  `-ProcessorPath`, `-FileCounts`, `-InitIterations`, `-RunIterations`, `-TestName`,
  `-Export`. Default values preserve original behaviour.
- **`-Export` flag** writes processed output to
  `tests/results-temp/{callerScript}_{testName}_{timestamp}/`.
- **`tests/test-cases/`** added — integration fixtures: `ps.core-import-scratch.ps1`
  (parseable) and `ps.core-import-scratch-error.ps1` (missing final `}` — triggers
  `rs-psstrip` regex fallback).
- **`colonel.tests.ps1`** — stale `tp-generic.ps1` processor path corrected to
  `format.ps1`.
- **`project-map.txt` updated**: `colonel-bench.ps1`, `test-cases/`, `results-temp/`
  added under `tests/`.

## 2026-04-10 — project-map.txt + colonel/TODO.md

- **`project-map.txt` updated**: `rs-indent.ps1` and `rs-indent.tests.ps1` added.
- **`colonel/TODO.md` updated**: `rs-indent.ps1` checked off; bracket-access fix
  item added for `rs-psstrip.ps1` and `format.ps1`.

## 2026-04-09 — conventions and project map

- **`project.txt` renamed to `project-map.txt`** — name better reflects its role
  as a navigational file map rather than a generic project document.
- **`project-map.txt` updated**: `tp-generic.ps1` → `format.ps1`, self-reference
  updated.
- **`CONTRIBUTING.md` updated**: all `project.txt` references updated to
  `project-map.txt`; processor naming convention section added (no-prefix =
  pipeline-agnostic; `rs-` = RS-scoped; `tp-` = TP-scoped; prefix tracks pipeline
  scope, not language specificity).

## 2026-04-09 — project organization

- **`project.txt` introduced** at `rs.core/` root — diagrammatic layout of the
  operational module surface. Only operational items are listed; unlisted folders
  are implicitly non-canonical (archival, discussion, wip, etc.).
- **`tests/` folder introduced** — module-level test harnesses live here, adjacent
  to the module files they test (`colonel.tests.ps1` as first entry).
- **`processors/tests/` folder introduced** — processor unit tests scoped to the
  processors folder by locality (`rs-psstrip.tests.ps1`, `tp-generic.tests.ps1`).
- **`CONTRIBUTING.md` introduced** — covers project layout, processor contract
  (ISS-load-safe rules), test harness conventions, runspace hygiene, module conventions,
  and changelog convention. Closing ceremony documents the commit-and-record workflow.
- **Locality-based changelog convention established** — each operational folder
  carries its own `CHANGELOG.md` rather than rolling everything into the root log.
  Folder-specific changes are recorded in the nearest changelog; the root changelog
  records structural / cross-cutting decisions like this one.
- **Changelog convention amended** (per CONTRIBUTING.md) — test harnesses roll up to
  their parent folder's changelog rather than maintaining separate test-folder changelogs.
  Active changelogs: `rs.core/CHANGELOG.md` (this file), `processors/CHANGELOG.md`.

## 2026-04-09 — rs.core.colonel.psm1 + processors — cleanup and consistency pass

- **`IssPreset` enum renamed**: `Minimal→Bare`, `Standard→Full`. `Bare` maps to
  `CreateEmpty`, `Core` to `CreateDefault2`, `Full` to `CreateDefault`. All docstrings
  and examples updated to match.
- **`ResultMode` enum**: members now carry inline descriptions. String comparisons
  (`'Ordered'`, `'Unordered'`) in the serial branch replaced with typed
  `[ResultMode]::Ordered` / `[ResultMode]::Unordered` comparisons.
- **`$selectorProperty` rename**: `$key` parameter renamed throughout `RunCore`,
  `RunCoreSerial`, and `RunCoreParallel` signatures and bodies for clarity.
- **`$fnMapRef` removed**: `$this.ProcessorManifest` inlined directly at the
  `AddArgument()` call site in `RunCoreParallel`; intermediate reference variable gone.
- **Config clone fixed**: `$this.Config = $this.Config?.Clone()` in `Run()` was mutating
  manager state on every call. Replaced with a local `$configForRun` variable threaded
  through all dispatch signatures. `$this.Config` is never mutated.
- **Vestigial comments removed**: stale aspirational comments (`# set for deprecation`,
  `# ResultMode should be a first-class enum`, etc.) removed. `BuildIss()` carries an
  accurate `# FUTURE:` note about a CreateEmpty-based ISS planner.
- **Runspace boundary tags**: `# >> RUNSPACE BOUNDARY` tags added at the bootstrap
  reader and parallel worker `AddScript` call sites. Canonical explanation of
  `using namespace` parse-time scoping added to `.NOTES` in the class docstring.
- **Unified error attribution**: all error messages in both serial and parallel paths
  now use the `"Item [N]: <msg>"` prefix. Serial path previously used `"Serial item [N]:"`.
  Parallel worker now clears `$Error` before each processor call and checks `$Error.Count`
  after, so non-terminating (Write-Error) errors from processors are attributed per-item
  via `$errBag` rather than as a per-slice `"Worker error:"` at EndInvoke.
- **`rs-psstrip.ps1`**: `[CmdletBinding()]` and `[Parameter(Mandatory)]` removed — these
  caused `ParameterBindingException` in non-interactive ISS worker contexts. Config
  resolution migrated from 5 boolean fields to an `Operations` string array
  (`@('block-comments','doc-strings','comment-blocks','line-comments')` by default),
  matching the `tp-generic.ps1` pattern. Both early-return paths return
  `Operations = @($ops)`. Docstring updated throughout.
- **`tp-generic.ps1`**: docstring references to `Standard`/`Minimal` updated to
  `Full`/`Bare`.

## 2026-04-08 — rs.core.colonel.psm1 + processors — initial processor work

- **`ResultMode` enum** (Ordered/Unordered/None) introduced at module level.
  Parallel worker `$shared` hashtable was already removed (2026-04-06); this
  enum formalises the result-collection contract.
- **`[System.Collections.Concurrent.ConcurrentBag[string]]` fully-qualified** in
  the parallel worker `param` block. The short alias `[ConcurrentBag[string]]`
  (from `using namespace System.Collections.Concurrent`) is parse-time /
  module-scope and is not available inside `AddScript()` worker contexts.
- **`rs-psstrip.ps1` initial implementation** — AST-based PowerShell comment
  stripper. Five comment kinds: BlockComment (top-level `<#..#>`), DocString
  (`<#..#>` inside function/class body), CommentBlock (contiguous 2+ `#` lines),
  LineComment (standalone `#` line), InlineComment (`#` with preceding code).
  Span reconstruction uses character offsets with leading-whitespace and
  trailing-newline consumption to avoid blank-line artifacts. Config via boolean
  toggle keys (StripBlockComments, StripDocStrings, …) — migrated to Operations
  array in 2026-04-09.
- **`tp-generic.ps1`**: `[Parameter(Mandatory)]` removed from Item parameter;
  `[CmdletBinding()]` commented out. Neither attribute is ISS-worker-safe.
  Processor self-documentation block added to docstring.

## 2026-04-06 — rs.core.colonel.psm1 — bugfix

- **`$iss` local variable renamed to `$issState` in `BuildIss()`** — `$iss` collides
  case-insensitively with the class property `$this.Iss` under `Set-StrictMode -Version Latest`
  in PS 7.6+, causing a parser error on import. Gotcha: local variable names inside class
  methods must not case-insensitively match any class property name.

## 2026-04-06 — rs.core.colonel.psm1 — RunMode unification

- **`RunMode` enum** (ApplyAll/KeyMatch) introduced at module level.
  `ApplyAll` broadcasts one processor key to all items (existing behaviour).
  `KeyMatch` resolves the processor key per item from a named property on the item
  object — enables mixed-format post-processing batches without grouped dispatch.
- **`RunCore` / `RunCoreSerial` / `RunCoreParallel`** replace the former `RunSerial`
  and `RunStaticByFunction` hidden methods. Serial-vs-parallel is one axis inside a
  single unified implementation; dispatch mode (ApplyAll/KeyMatch) is the orthogonal
  axis. Both branches share the same fn-resolution logic.
- **`Run([object[]]$items, [RunMode]$mode, [string]$key)`** explicit overload added.
  Existing `Run([object[]]$items, [string]$processorKey)` shorthand retained as an
  ApplyAll delegate — no call-site breakage.
- **`$shared` synchronized hashtable removed** from the parallel branch. Workers now
  write results directly to the pre-allocated `$this.OrderedOutput` array by index
  (distinct-index concurrent writes to a .NET reference-type array are safe) and
  errors directly to `$this.Errors` (ConcurrentBag[string]).
- **`MaterializeMs` timing phase removed** — no post-pass needed without `$shared`.
- **`AssertProcessorFunctionLoaded` removed** — redundant post-ISS-load validation;
  any real ISS failure surfaces on the first worker error.
- **`ResolveProcessorFunction` removed** — inlined as a direct
  `ProcessorManifest.ContainsKey` check in `RunCore`.
- **`PoolOpenMs` timing** moved inside `RunCoreParallel` with a dedicated stopwatch
  (previously measured in `Run()` before the pool-open call).
- **Return envelope**: `DispatchMode` field added; `Function` field removed (was the
  resolved fn name for ApplyAll; derivable from manifest if needed). `SerialMs` timing
  key removed — `SerialRunspaceOpenMs` + `SerialProcessMs` sub-keys cover the serial
  path fully; `TotalMs` covers the outer span.

## 2026-04-05 — rs.core.colonel.psm1 and some reorg

- moved `rs.core.colonel` to `ps.core.reposnapshot/rs.core` along with the benchmark script and this changelog and the processors subfolder with runspace ps1 scripts
- created .feedback folder for feedback threads
- moved the rest of threadparser to rs.core under rs.core/threadparser

## 2026-04-05 — rs.core.colonel.psm1

- **`IssPreset` enum** (Minimal/Core/Standard) introduced. All ISS construction
  centralised in `BuildIss()`; no direct `CreateDefault*` / `CreateEmpty` calls
  exist outside that method.
- **`SetIssPreset([IssPreset])`** and **`SetIssModules([string[]])`** fluent setters
  added. `IssModules` pre-loads PS modules into every worker runspace alongside
  processor functions.
- **Serial fast-path** (`RunSerial`): when graded worker budget resolves to 1 thread,
  a single lightweight runspace is opened instead of a pool (~3ms vs ~300ms
  steady-state open cost). `Run()` branches on `budget.Threads == 1`; no pool
  is created on that path.
- **Timing granularity**: `SerialRunspaceOpenMs` and `SerialProcessMs` added inside
  `RunSerial`; `SerialMs` was the total on the `Run()` caller side
  _(removed in 2026-04-06 — `TotalMs` covers the outer span)._
- **Lazy `SystemCores`**: WMI (`Get-CimInstance Win32_Processor`) deferred to first
  `ResolveWorkerBudget` call; construction no longer fires WMI.
- **PSOne-style parallel manifest bootstrap**: `LoadProcessorsFromManifest` refactored
  into Phase 1 (concurrent raw PS fan-out, capped at `InitThreads`) and Phase 2
  (serial ISS construction — `InitialSessionState` is not thread-safe). Resolves the
  bootstrap catch-22: colonel cannot use its own Tau/K machinery before the ISS exists.
- **`SetInitThreads([int])`** fluent setter added for bootstrap concurrency cap (default 4).
- Docstring overhauled: `.SYNOPSIS`, `.DESCRIPTION`, `.FLUENT SETTERS`, revised examples
  covering current API surface including new ISS setters.

## 2026-04-01 — Factory method

- renamed `ps.core.hpc` to `rs.core.colonel`
- Renamed class to RunspaceManager
- Refactored user-facing parameters, introduced new names MaxCoresAllowed NumCoresReservedcollectresults is set to false
- Deprecated custom threads mode and customthreads number, it was redundant and introduced unnecessary complexity
- removed SafeMode and inserted a warning to log in its place

## 2026-04-01 — Factory method removal

- Removed static factory methods `ForContentProcessing()`, `ForFileProcessing()`, `ForBulkProcessing()` from the class.
- Removed wrapper functions `New-ContentProcessor`, `New-FileProcessor`, `New-BulkProcessor` and their exports.
- Sole export is now `New-ParallelismEngine`; the `ParallelismEngine` class is auto-available on import.

Rationale: the factory presets were thin sugar over two-call fluent chains and covered only 3 of 12+ pattern/threading combinations. Callers already need to understand the primitives to choose a preset, so the indirection added no value. The fluent API is the intended configuration surface.

## 2026-04-01 — Architecture remediation pass

Bug fixes:

- Fixed Cascade/Reducer double-invocation: `& $this.CascadeScript.Invoke(...)` was calling the scriptblock twice (once via `.Invoke()`, once via `&`). Changed to `& $this.CascadeScript $results $this.Config`. Same fix applied to Reducer.
- Fixed `RunQueue` silent exception swallowing: `$ps.EndInvoke($ps._async) | Out-Null` discarded all terminating errors from queue workers. Wrapped in `try/catch` with errors appended to `$this.Errors`. ForEach and Static already had this; Queue was the outlier.
- Added 50ms floor to `WaitAllHandles` per-handle timeout (`[Math]::Max(50, ...)`) to prevent cliff-edge zero-timeout polling when an early handle consumes the bulk of the timeout budget.

Dead code removal:

- Removed `$safe` parameter from `RunForEach` and `RunStatic` inner scriptblock `param()` blocks and corresponding `.AddArgument($this.SafeMode)` calls. SafeMode enforcement already happens on the main thread at the top of `Run()`.
- Removed `WriteGate` (`ReaderWriterLockSlim`) property, `_Init` allocation, `InvokeWithWriteLock()` method, and `Dispose()` cleanup. Never called; `ConcurrentBag` handles all thread-safe collection.
- Removed `UseArrayCollector` property, `EnableArrayCollector()` fluent setter, and the O(n²) branch in `GetResults()` that used `$arr = @(); $arr += $x` with a misleading comment about "7.5.2's fast +=". Collapsed `GetResults()` to a single `return $this.Collector.ToArray()` path.

Performance:

- Replaced `$handles = @()` / `$handles += ...` with `List<WaitHandle>` and `.Add()` in all three execution patterns. Same for `$collectors` and `$workers`. Eliminates O(n²) array reallocation on accumulation.
- Replaced `RunStatic` slice building from `$slices[$t] = @(); $slices[$t] += ...` to `List<object>[]` with `.ToArray()` at the end.
- Replaced `(Get-Date).ToString('o')` with `[DateTime]::UtcNow.ToString('o')` in `WriteTrace`.

Documentation:

- Added `ConcurrentBag<T>` non-deterministic ordering note to module header and `GetResults()` method comment.
- Updated module synopsis to remove stale references to 7.5.2 array consolidation and 7.5.3 serialization.
- Updated trace format string to remove `arrayCollector` placeholder.

Sources: cross-examination of Gemini Deep Research report, Comet architecture review, and Comet revisions thread. Gemini correctly identified the EndInvoke swallowing, dead `$safe` param, dead WriteGate, and WaitAllHandles cliff-edge (though prescribed the wrong fix for the latter — `WaitHandle.WaitAll()` regresses the STA-safety fix already in the code). Comet caught the Cascade/Reducer double-invocation bug that Gemini missed entirely, correctly rebuffed the WaitAll regression, and identified the `ConcurrentBag` ordering concern. The `UseArrayCollector` O(n²) bug and `+=` remediation across all patterns were consensus findings from both.

## 2026-03-31 — Additional cleanup

- renamed `threadparser/v2-new/pwshspc.core.hpc.psm1` to `ps.core.hpc.psm1` to eliminate confusion
- bumped required powershell to 7.5.3
- removed 7.3 enforcement
- removed references to deprecated serialization from pwshspc original source
- updated formatting of module exports to use array @(..)

## 2026-03-31 — CliXml cleanup

- Removed `Serialization` configuration property and `SetSerialization()` fluent API.
- Deleted `SerializeWorkItem()` helper and all `ConvertTo-CliXml`/`ConvertFrom-CliXml` branches.
- Simplified worker scriptblock `param()` lists and `.AddArgument()` calls to remove serialization arguments.
- Updated run-time trace message to remove serialization placeholder.

Rationale: this forked copy under `threadparser/v2-new` does not require the CliXml serialization paths (they were gated behind a non-default option). Removing them keeps the module compatible with the declared `#Requires -Version 7.3`, reduces complexity, and avoids referencing PS 7.5-only serialization behavior.

Notes:

- These changes are localized to the `spc.core.hpc.psm1` copy in `v2-new` and do not affect other repositories.
- If you want a brief compatibility note included in a module manifest or README, I can add it.

## 2026-03-31 — Additional cleanup

- renamed `threadparser/v2-new/pwshspc.core.hpc.psm1` to `ps.core.hpc.psm1` to eliminate confusion
- bumped required powershell to 7.5.3
- removed 7.3 enforcement
- removed references to deprecated serialization from pwshspc original source
- updated formatting of module exports to use array @(..)

## 2026-03-31 — CliXml cleanup

- Removed `Serialization` configuration property and `SetSerialization()` fluent API.
- Deleted `SerializeWorkItem()` helper and all `ConvertTo-CliXml`/`ConvertFrom-CliXml` branches.
- Simplified worker scriptblock `param()` lists and `.AddArgument()` calls to remove serialization arguments.
- Updated run-time trace message to remove serialization placeholder.

Rationale: this forked copy under `threadparser/v2-new` does not require the CliXml serialization paths (they were gated behind a non-default option). Removing them keeps the module compatible with the declared `#Requires -Version 7.3`, reduces complexity, and avoids referencing PS 7.5-only serialization behavior.

Notes:

- These changes are localized to the `spc.core.hpc.psm1` copy in `v2-new` and do not affect other repositories.
- If you want a brief compatibility note included in a module manifest or README, I can add it.
