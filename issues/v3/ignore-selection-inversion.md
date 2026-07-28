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

## Design v2 — mode dichotomy + override disentanglement (user, 2026-07-28)

Supersedes the v1 population-scoped composition below in one respect: the
`Selection.Keeps ∧ ¬Ignore.Ignores` filter-time composition is **rejected as
the selection semantics** — it lets the existence of an include list
implicitly collide with ignore lists, which is exactly the tension that
motivated the original override concept. The disentanglement (user):
**overriding gitignored files by request is a different feature than a
selection mode.** What survives from v1: sentinels never invert; shared
five-stage machinery; explicit config over data-shape inference.

Three semantic devices, two run modes:

1. **Ignore regime** (Ignore mode — canonical, default): sentinel scan + user
   ignore globs merged as the virtual root ignore file — today's nested
   inheritance/annihilation semantics, byte-for-byte unchanged.
2. **Selective override** (a *nuanced feature of Ignore mode*, not a mode):
   user-requested globs that **rescue matching paths from ignore verdicts** —
   "ingest per the ignore rules, but force-include these even if gitignored."
   Composition within Ignore mode:
   `keep(path) = ¬Ignore.Ignores(path) ∨ Override.Matches(path)`.
   Distinct from gitignore `!` negations, which are in-file intent
   participating in nested semantics; the override is an executive-level
   rescue layered after the ignore verdict. Compiled by the same glob→regex
   machinery (broadcast regex, as the current override already is — but
   *composing with* the pipeline instead of *replacing* it).
3. **Selection regime** (Selection mode): the run is expressly about
   *ingesting what we want*. **Sentinel files are not consulted** (scan
   skipped entirely — no I/O); user selection globs compile as a selection
   regime through the same five-stage machinery; negations are un-keep
   exceptions ("select `*.ps1` except `tests/`");
   `keep(path) = Selection.Keeps(path)`. Period — no ignore composition.

The **mode switch** (`Ignore` | `Selection`) is explicit run config declaring
the run's intent — never inferred from which pattern lists happen to be
non-empty. Both modes express patterns in the same canonical glob semantics
and compile through the same NormalizeGlob/TranslateGlob/CompileGlobs path;
`TestPath`'s dual truth table remains the shared per-regime authority.

Carried over from v1 unchanged: prune guard (no directory pruning under
selection; ignore-mode pruning as today; empty-leaf prune cleans up),
fail-fast on empty/self-annihilated selection or override sets, and the
two-slot state shape (`CompiledIgnore`/`ExecutiveOverride`) collapsing into
orientation-stamped compiled state.

Naming/migration notes: the *word* "override" migrates to the rescue feature
(its true meaning); the current `RunOverrideBypass()` behavior is really
proto-Selection-mode and maps there. The rejected ∧-composition ("selection
within the not-ignored universe") remains expressible later as an explicit
third arrangement if a use case ever demands it — not a feature now, and
never an implicit collision.

Config surface (naming TBD): `Mode` · Ignore-mode: `SentinelFileNames`,
`IgnoreDefaults`, `IgnorePatterns`, override globs (name TBD — candidates:
`IgnoreOverrides`, `RescuePatterns`) · Selection-mode: selection globs (name
TBD: `SelectionPatterns` vs unified `Patterns` interpreted per mode).

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

Remaining open (smaller): mode/override/selection parameter naming (see Design
v2 config surface); whether the Selection regime participates in per-node
sentinel-style *local* selection sources (currently: no — user population is
root-injected only, though the machinery would permit it); shim vs clean break
for `ExecutiveOverrides`; whether the override rescue should also rescue
directory branches from pruning (a gitignored dir containing an
override-matched file must not be pruned before the rescue can apply —
implementation detail to resolve during the refactor).

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
- 2026-07-28 — **Design v2** (user): the ∧-composition rejected as selection
  semantics — implicit include/ignore collision is the original tension, not
  its resolution. Disentanglement: **selective override** (rescue gitignored
  paths by request — a nuanced feature *of* Ignore mode,
  `¬Ignores ∨ Override.Matches`) vs **Selection mode** (explicit mode switch;
  sentinels not consulted; pure `Selection.Keeps`). Both expressed in
  canonical glob semantics through the shared compile machinery. "Override"
  name migrates to the rescue feature; bypass behavior maps to Selection mode.
  New open item: override interaction with directory pruning.
