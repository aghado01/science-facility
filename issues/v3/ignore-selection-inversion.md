# Ignore ↔ Selection semantics inversion — repo-audit backport analysis

**Status:** design analysis · **Filed:** 2026-07-28
**Sources compared:** `ThermoMapper/src/repo-audit/{IgnoreEngine.cs, GlobCompiler.cs}`
(descendant) vs `reposnapshot-v3/rs.core.ignore.psm1` (ancestor).
Extends TODO's "antisemantics" item; supersedes LTS `SelectionOverrides` and v3
`ExecutiveOverrides` as the selection mechanism.

## Scope of "backport" (user, 2026-07-28)

**Backport means incorporating the symmetric-inversion *concept* that emerged
in repo-audit's adaptation — NOT replacing reposnapshot's ignore engine with a
transliteration of repo-audit's machinery.** The two applications share
overlapping needs met by this lineage, but their use cases differ: repo-audit's
needs are less complicated and more contained; reposnapshot's charter is more
general. Design for reposnapshot specifically, without letting repo-audit's
missteps or simplifications corrupt the intricate work in reposnapshot's
engine.

## Operational context — what the RS ignore engine actually is (user, 2026-07-28)

- RS was originally written to ingest a repository with *fluency*: detect and
  respect the repo's own ignore files — gitignore, dockerignore, and kin — so
  the snapshot captures essential code material, not low-signal or irrelevant
  files. v3 codifies this as the `SentinelFileNames` convention (bound param,
  sensible defaults) — respected *if detected* by the crawler.
- **Selection semantics don't naturally touch sentinel files**: (a) there are
  no "gitselect" files in the wild; (b) ignore files carry ignore *intent*,
  not just globs available for reinterpretation.
- **User-supplied globs are operationally a virtual ignore file**: RS merges
  the user's include/exclude lists into the engine as an additional
  root-level gitignore-like source, so they participate in the nested
  gitignore semantics — inheritance, annihilation, anchor-prefixing. This
  integration is the intricate work to preserve.
- The tension: the elegant shared mechanism with a switch vs the operational
  reality of what ignore files mean. Theoretical workflows like "ingest the
  complement of an ignore file" are explicitly **out of the weeds we're
  entering** — not designed for now.
- Essential requirement: the canonical ignore-file-driven workflow stays
  as-is; the user gains the ability to supply globs *for selection*; the
  underlying semantic processing machinery is shared, switched by semantic
  orientation.

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

## Proposed design — population-scoped semantics (2026-07-28, pending adjudication)

The untangling move (from the user's operational framing): **the semantic
orientation switch attaches to the user pattern population, not to the
engine.** Repo-audit inverts the whole engine — affordable in its contained
charter, wrong for RS where sentinel files carry non-negotiable intent.

Two pattern populations with different semantic ownership:

- **Sentinel population** — repo-native ignore files (`SentinelFileNames`
  discovery, as today). Constitutionally ignore-semantic; **never inverted**.
- **User population** — caller-supplied globs, with a declared orientation:
  - `Ignore` orientation (default): merged into the sentinel regime as the
    virtual root ignore file, **exactly as today** — inheritance,
    annihilation, anchor-prefixing preserved; one regime; zero behavior
    change to the canonical workflow.
  - `Selection` orientation: the user set compiles as a **separate selection
    regime** through the *same* five-stage machinery; negations become
    un-keep exceptions ("select `*.ps1` except `tests/`" is one pattern set).

Filter-time composition when a selection regime is present:

```
keep(path) = Selection.Keeps(path) AND NOT Ignore.Ignores(path)
```

- Selection restricts within the not-ignored universe — "all `*.cs` that
  aren't gitignored" — the composition the old bypass could not express.
- Pure selection (old ExecutiveOverride behavior) = Selection orientation +
  `SentinelFileNames @()`; now with negation support and full machinery.
- **Pruning stays ignore-side only**: gitignored branches still prune (better
  than repo-audit's all-or-nothing Include-mode prune skip); selection never
  prunes directories; the existing post-filter empty-leaf prune cleans up.
- **Fail-fast preserved**: empty/self-annihilated selection set throws (RS
  behavior), never silently excludes all (C# behavior).
- Because the regimes are separate, exotic workflows (inverting sentinel
  intent, complement-of-ignore-file) remain *expressible later* without
  redesign — but are deliberately not designed for now.

Mechanism reuse from the C# concept: compiled state stamped with its
orientation; `TestPath` as the single dual-truth-table authority evaluated per
regime; `Invoke-IgnoreFilter`'s inline `.Where()` branching collapses into
TestPath calls, retiring the two-slot `CompiledIgnore`/`ExecutiveOverride`
state shape and `RunOverrideBypass()`. `ExecutiveOverrides` retires with a
migration shim (≈ Selection orientation + sentinels off).

Config surface (naming TBD): `SentinelFileNames` (unchanged) · user patterns ·
orientation switch for the user set. Code/config separation: orientation is
run config, never inferred from data shape.

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

## ~~Open design decision — sentinels under Selection semantics~~ (resolved)

Resolved 2026-07-28 by population-scoping (design above): sentinels are
constitutionally ignore-semantic and never invert; the orientation switch
applies only to the user population. The earlier framing (engine-global mode
with sentinel handling as a problem to patch) inherited repo-audit's
simplification — the C# design compiles sentinel patterns under inverted
semantics in Include mode, which would read a .gitignore as keep rules; its
callers presumably dodge this by passing empty sentinel names. Population
scoping dissolves the problem instead of patching it.

Remaining open (smaller): orientation parameter naming; whether the Selection
regime participates in per-node sentinel-style *local* selection sources
(currently: no — user population is root-injected only, though the machinery
would permit it); shim vs clean break for `ExecutiveOverrides`.

## Sequencing

Unchanged from the audit-log adjudication: non-blocking for the ItemDescriptor
seam work; this refactor is its own pass when the ignore engine is next opened
beyond de-stamping. The de-stamping edit (RelativePath moves to crawler) and
this inversion touch different regions of the module and can land independently
in either order.

## Work log

- 2026-07-28 — Backport scope clarified (user): concept, not transliteration;
  repo-audit charter is narrower — guard RS's engine from its simplifications.
  Operational context recorded (sentinels as intent; user globs as virtual
  ignore file participating in inheritance/annihilation). Design reframed from
  engine-global mode to **population-scoped semantics**: orientation attaches
  to the user pattern set; sentinels never invert; filter-time composition
  `Selection.Keeps ∧ ¬Ignore.Ignores`; ignore-side pruning retained. Prior
  sentinel open decision resolved by the reframe. GatherScatter dead-cache gap
  in repo-audit acknowledged by user (was unknown).
