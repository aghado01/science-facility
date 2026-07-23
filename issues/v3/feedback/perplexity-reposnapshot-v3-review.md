Good, I have everything. Here's a full review:

---

## Code Review — RepoSnapshot V3

### `rs.core.colonel.v2.psm1`

**Strong overall.** A few specific issues:

**1. `$ordered` array passed into worker scriptblock — mutation-via-ref is fragile**

`$ordered = [object[]]::new($count)` is passed as `$OrderedOut` into each worker. This works because arrays are reference types, but only as long as the runspace pool serializes them on the way in as a live reference — which it does _not_ guarantee across runspace boundaries. In practice PowerShell's `BeginInvoke` serializes arguments via `PSSerializer`. You should instead have workers return results keyed by index, and collect in the host after `EndInvoke`. The current code _may_ work in simple cases but is not safe. The clean fix: have the worker script output `[PSCustomObject]@{ Index = $MyIdxs[$i]; Value = <result> }`, collect from `EndInvoke`, then fill `$ordered` in the host.

**2. Worker timeout rolling window is slightly off**

```powershell
$remaining = [Math]::Max(50, $WaitTimeoutMs - [int]$swWall.ElapsedMilliseconds)
```

This is correct in spirit but `$swWall` starts _before_ the wait loop, not before dispatch — so slow dispatch eats into timeout. Minor but worth noting; start `$swWall` right before the foreach wait loop, not before dispatch.

**3. `Compile-Plan` silently swallows unreferenced manifest keys**

Keys in `$Manifest` that no step references are silently ignored. This is fine by design but worth a `$warnings.Add(...)` for the caller's diagnostics — a typo in a step key shows up as a warning instead of a silent miss.

**4. `#Requires -Version 7.6` but module header says `7.5`**

The colonel file has `#Requires -Version 7.6`, but `rs.core.crawler.psm1` and `rs.core.ignore.psm1` both have `7.5`. Pick one floor and be consistent. If nothing in colonel actually requires 7.6-specific APIs, drop it to 7.5.

---

### `rs.core.crawler.psm1`

Clean and tight. One issue:

**`Files` on the root node doesn't include `RelativePath`**

The crawler adds `@{ AbsolutePath; SizeBytes }` to `$node.Files` — no `RelativePath`. `Invoke-IgnoreFilter` adds `RelativePath` later via `Add-Member`, which is fine, but the shape inconsistency is worth noting. The cleaner long-term fix is to add `RelativePath` in the crawler since it already has `$this.RootPath` — but this is cosmetic since the filter compensates.

---

### `rs.core.ignore.psm1`

**Good structure.** Two real issues:

**1. `$node.Files = $remainingFiles` in `New-IgnoreCompiler` mutates the crawler's nodes directly**

```powershell
$node.Files = $remainingFiles  # strips sentinel files from the node
```

The crawler's `Graph` nodes are passed in by reference. Stripping sentinel files from `$node.Files` in-place means the original graph is permanently mutated before `Invoke-IgnoreFilter` runs. This is a hidden side effect — the caller's `CrawlerGraph` comes back with sentinels removed. Either deep-copy nodes before mutating, or document this contract explicitly and ensure callers don't reuse the original graph after calling `New-IgnoreCompiler`.

**2. `IgnoreCompiler` constructor still references `$node.IgnoreFiles` directly**

```powershell
$this.NodeLookup[''].IgnoreFiles.Insert(0, $virtualEntry)
```

This is the root node's `IgnoreFiles` list that was added by `New-IgnoreCompiler` via `Add-Member`. This is correct functionally but the property name is still `IgnoreFiles` inside the class — the rename to `SentinelIgnoreFiles` hasn't propagated inside the compiler internals yet. The class-level aggregate property is correctly named `SentinelIgnoreFiles` but the per-node property is still `IgnoreFiles`, meaning the rename is half-done.

---

### `rs.core.ingest.psm1`

**One real issue:**

**`Split-ForwardedParams` OwnParams exclusion for `$dispatchSplat` is wrong**

```powershell
$dispatchSplat = Split-ForwardedParams -BoundParameters $PSBoundParameters `
    -OwnParams (@('FilteredFsGraph') + (Get-Command 'Compile-Plan').Parameters.Keys)
```

`Get-Command 'Compile-Plan'` does a runtime command lookup — this only works if `rs.core.colonel.v2.psm1` is already imported into the caller's session at the time `Invoke-Ingest` runs. If colonel isn't loaded yet (wrong import order), this silently produces an empty exclusion list and `$dispatchSplat` bleeds compile params into `Invoke-Plan`. Worth caching the keys at module load time or using a static list.

---

### Todos — Prioritization Read

The todo list is well-organized. A few observations:

- **Item 1 (crawler/ignore decoupling)** — the `IgnoreFiles` rename half-done issue above is part of this; finish the rename sweep before wiring `SentinelIgnoreFiles` into `Discover()`
- **Item 3 (Scriban/LTS excavation)** — this is the biggest unknown-unknowns risk; the note about `.j2` interop exceptions with `upper` suggests there are Jinja2-isms in the templates that Scriban won't handle cleanly without a shim
- **Item 4 (test harness)** — the ordered-result mutation bug in colonel is exactly the kind of thing a runspace integration test would catch immediately; worth bumping this priority
- **Item 5 (admiral config precedence)** — bound params > config file is the right instinct; keep it simple with `$PSBoundParameters` as the authority and config file as defaults only
