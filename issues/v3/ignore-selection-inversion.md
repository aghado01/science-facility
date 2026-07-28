# Ignore ↔ Selection semantics inversion — repo-audit backport analysis

**Status:** design analysis · **Filed:** 2026-07-28
**Sources compared:** `ThermoMapper/src/repo-audit/{IgnoreEngine.cs, GlobCompiler.cs}`
(descendant) vs `reposnapshot-v3/rs.core.ignore.psm1` (ancestor).
Extends TODO's "antisemantics" item; supersedes LTS `SelectionOverrides` and v3
`ExecutiveOverrides` as the selection mechanism.

## Lineage correspondence (confirmed)

The C# engine is the PowerShell engine, stage for stage — Normalize (separator
collapse, degenerate rejection) → Coalesce (positives/exceptions partition,
exact-match annihilation, anchor-prefix) → Walk (BFS inheritance,
depth-annotated dicts, cross-depth annihilation) → Reduce (deeper-positive
subsumption domination) → Gather-Scatter (signature-keyed regex compile) →
Prune (ancestor propagation + parent-state test). `TranslateGlob` char-walks
are identical arm for arm. Structural divergence is only at the rim: C#
`Filter()` fuses compile+apply into one call returning a filtered
`CrawlerResult`; PS splits `New-IgnoreCompiler` / `Invoke-IgnoreFilter` (keep
the PS split — it matches the stage-contract doctrine).

## The inversion architecture

**v3 today — selection as bypass (asymmetric, two code paths):** presence of
`ExecutiveOverrides` (data-driven, not a declared mode) routes to
`RunOverrideBypass()`: patterns normalized, partitioned, annihilated, then ONE
regex compiled from positives only and broadcast identically to every node.
Match = KEEP. The entire five-stage machinery is skipped: no sentinel
participation, no anchor-prefixing, no inheritance, no depth precedence — and
**negations are discarded** after annihilation (no subtractive selection).
Consumers branch on which of two mutually-exclusive state slots
(`CompiledIgnore` vs `ExecutiveOverride`) is non-null; `Invoke-IgnoreFilter`'s
`.Where()` block re-implements `TestPath`'s branching inline (existing
duplication).

**repo-audit — semantics as interpretation (symmetric, one code path):**
compilation is semantics-neutral; the mode is a declared config value that is
consulted only at the edges. Three loci carry the entire inversion:

1. **`GlobSemantics` enum** `{ Ignore, Include }` — an explicit mode-switch
   parameter on the entry point (config, not data-driven inference).
2. **Compiled state is stamped with the mode** (`CompiledIgnoreState.Semantics`)
   — filter-time code needs no out-of-band mode knowledge.
3. **`TestPath` holds the dual truth table** — the single semantic authority:

   | | Ignore | Include |
   |---|---|---|
   | no positives | keep all | **exclude all** |
   | non-match | kept | excluded |
   | match | excluded | kept |
   | match + exception match | **rescued** (kept) | **keep undone** (excluded) |

   Exceptions keep one meaning in both modes: *undo the primary verdict*. So
   `!` patterns work in selection mode — "select `*.cs` except `generated/`" —
   which the bypass architecture structurally cannot express.

Plus exactly **one guarded asymmetry** in the pipeline: **Prune is skipped in
Include mode** — a file-targeted keep pattern (`*.cs`) can never match a
directory path, so under include semantics every directory would test
"excluded" and subtrees would be pruned before their files were ever evaluated.
Documented inline in C#; the one place the modes genuinely differ.

**What selection mode inherits for free** by running the full pipeline:
sentinel inheritance machinery, anchor-prefixing of node-local patterns, depth
precedence, exception subsumption, per-node compiled states with the signature
cache. Under the bypass, none of these exist for selection.

## Backport sketch (rs.core.ignore.psm1)

1. Add a `Semantics` mode switch (`'Ignore'` | `'Selection'`, ValidateSet or PS
   enum) to `New-IgnoreCompiler` — explicit config, replacing the data-driven
   override inference. Code/config separation: the mode is run config.
2. Delete `RunOverrideBypass()`; both modes run all five stages.
3. Stamp `Semantics` on compiled node state; rewrite `[IgnoreCompiler]::TestPath`
   as the dual truth table (single authority).
4. Guard `Prune()` on Ignore mode. Selection mode relies on
   `Invoke-IgnoreFilter`'s existing post-filter empty-leaf prune for cleanup —
   the PS side already has the piece C# lacks here; the mapping is clean.
5. Collapse `Invoke-IgnoreFilter`'s inline `.Where()` semantics branching into a
   `TestPath` call — retires the duplication and the two-slot state shape
   (`CompiledIgnore` + `ExecutiveOverride` → one `CompiledState` with
   `Semantics`).
6. Retire `ExecutiveOverrides` (breaking-change note or thin migration shim:
   `-ExecutiveOverrides $x` ≈ `-Semantics Selection -Patterns $x` minus the
   negation/inheritance upgrades).

## Cautions — do NOT import these from the C# side

- **Dead regex cache (C# defect):** in `GatherScatter`, `cache` is never
  populated and `result[node.NodePath]` is assigned only inside the cache-miss
  branch — every node recompiles (correct output, no reuse; and had the cache
  ever hit, the node would be *dropped from the result*). The PS
  `CompileRegex()` does this correctly (populate cache, stamp node from cache
  unconditionally). Keep the PS shape.
- **Comment normalization drift:** C# `NormalizeGlob` discards `#` comments;
  PS passes them through raw and relies on Coalesce to skip them. Adopt the C#
  behavior while in there (cleaner), but it's cosmetic.
- **Empty-selection behavior:** C# Include mode with no positives silently
  excludes everything; PS override mode **throws** on a self-annihilated empty
  selection set. Keep PS's fail-fast — an empty selection is a user error, not
  a valid request for nothing.

## Open design decision — sentinels under Selection semantics

The one place the symmetric design needs a decision the C# code dodges: in
Include mode, repo-audit compiles sentinel (.gitignore) patterns under the same
inverted semantics — a .gitignore's contents would be read as *keep* rules,
which is semantically wrong (gitignore files are inherently ignore-semantic;
the C# caller presumably passes empty sentinel names in Include mode). Options
for v3:

1. **Selection mode disables sentinel scan by default** (explicit opt-in to
   the C# behavior) — simplest, matches the old override-bypass expectation.
2. **Dual-regime compile** — caller patterns compile under Selection semantics,
   sentinel patterns stay Ignore-semantic; keep = matches selection AND not
   gitignored. Strictly more useful ("all *.cs that aren't build artifacts")
   but two state sets per node — real scope growth. Defer unless a use case
   demands it; record as the principled end state.

## Sequencing

Unchanged from the audit-log adjudication: non-blocking for the ItemDescriptor
seam work; this refactor is its own pass when the ignore engine is next opened
beyond de-stamping. The de-stamping edit (RelativePath moves to crawler) and
this inversion touch different regions of the module and can land independently
in either order.

## Work log

_(append findings/results here)_
