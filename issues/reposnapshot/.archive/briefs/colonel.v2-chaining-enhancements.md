Good call — here's a handoff prompt you can drop straight into Copilot:

---

**Copilot handoff — add profile-based glob routing to `rs.core.colonel.v2.psm1`**

Enhance `Compile-Plan` and `Invoke-Plan` in `rs.core.colonel.v2.psm1` to support profile-based glob routing. The chain executor and all processors are unchanged.

**Changes to `Compile-Plan`:**

- Replace the `[object[]] $Steps` parameter with `[object[]] $Profiles`
- Each profile is `@{ Globs = @('*.ps1', '*.psm1'); Steps = @(...) }` where Steps is the existing `@{ Key; Config }` array format
- Collect referenced processor keys from **all** profiles' steps combined (dedup) — bootstrap and ISS loading are unchanged
- Compile each profile's Globs into a single combined regex: `'(' + ($globs | ForEach-Object { Convert-GlobToRegex $_ } ) -join '|' + ')'` using `[regex]::new($pattern, IgnoreCase -bor Compiled)`
- Add a private `Convert-GlobToRegex` helper function: escapes the glob with `[regex]::Escape()` then replaces `\*` → `.*` and `\?` → `.`
- Plan shape changes from `@{ Steps; Iss; ProcessorKeys }` to `@{ Profiles = @(@{ Matcher; Chain = @(@{ Key; Fn; Config }) }); Iss; ProcessorKeys }`
- Add an optional `[object[]] $DefaultSteps = $null` parameter for a catch-all chain when no profile matches

**Changes to `Invoke-Plan`:**

- Before slicing, resolve each item's chain: match `$item.AbsolutePath` (or `$item.Path`) against each profile's `Matcher` in order, first match wins
- Items with no matching profile and no `DefaultChain`: add to errors, skip
- Pass the resolved per-item chain (as a plain hashtable array) to the worker alongside the item — worker receives `@{ Item; Chain; Index }` tuples or equivalent
- Update the worker scriptblock `$plan = @{ Steps = $PlanSteps }` to use the per-item resolved chain instead of a single shared plan steps array

**Constraints:**

- `Invoke-ChainExecutor` signature and body are **not changed** — it receives `@{ Steps = ... }` as `$Plan`, which is exactly what the per-item resolved chain provides
- Worker scriptblock fully-qualified type rule still applies — no `using namespace` inside `AddScript`
- `Resolve-WorkerBudget`, `Build-Iss`, `RunspaceManager` class, `New-RunspaceManager` are **not changed**
- Keep `Export-ModuleMember` list unchanged

**Processor key used for path matching:** items at dispatch time are expected to have an `AbsolutePath` or `Path` property. Match against whichever is non-null, preferring `AbsolutePath`.
