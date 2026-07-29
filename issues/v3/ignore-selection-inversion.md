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

Supersedes design v1 (the population-scoped composition — retired from this
doc; see work log 2026-07-28 for its record) in one respect: the
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

## Design v3 — override collapses into negation merge (user, 2026-07-28; FINAL for implementation)

Names adopted provisionally (`IngestMode` / `IgnorePatterns` /
`IgnoreOverridePatterns` / `SelectionPatterns`) — renameable later; the
**semantics of the control surface** are what is settled:

- **Cross-mode params are inert, never errors** (supersedes the v2
  binding-aware coherence throws): in Selection mode, IgnorePatterns and
  IgnoreOverridePatterns are simply not consulted; in Ignore mode,
  SelectionPatterns is not consulted. Rationale: ergonomic defaults and mode
  switching without emptying the other mode's parameter sets.
- **The override is not a separate device** (supersedes v2's rescue layer
  `¬Ignores ∨ Override.Matches`): `IgnorePatterns` behaves as a virtual
  root-level ignore file merged with the sentinels; `IgnoreOverridePatterns`
  behaves as *negations in that same virtual file*, merged identically.
  Negations inside IgnorePatterns are valid (it IS a virtual ignore file);
  negations inside IgnoreOverridePatterns (double negation → positive
  ignore) are silly but admissible — the engine handles them. **Both params
  are treated identically as virtual global ignore sources — containers for
  additional ignores and negations by convention** — because the engine is
  already all about merging, inheritance, negation, and precedence. No
  broadcast regex, no filter-time composition, no prune special-casing:
  `CompiledState = { Regime; Positives; Exceptions }` and the five stages do
  the rest.
- **Inherited gitignore semantic (flagged)**: as root-level negations,
  overrides follow canonical gitignore precedence — a file-only negation
  cannot re-include content under an excluded directory (the branch prunes
  first; git has the identical rule). Rescuing inside an ignored branch
  requires negating the directory (override `dist/` rescues the branch and
  its contents). **Migration note**: the retired ExecutiveOverride bypass
  punched through everything; pure-selection use maps to Selection mode,
  targeted rescues map to overrides with gitignore rules.
- **ExecutiveOverrides: clean break** (no shim — pre-release module, no
  external callers; the bypass behavior ≈ Selection mode).
- Fail-fast retained *within* mode: Selection mode with an
  empty/self-annihilated SelectionPatterns set throws.
- **Unresolved tension (recorded, admiral brief)**: config-driven execution
  will come in time but will not displace direct bound-param invocations —
  the duality of the two invocation surfaces is a standing design question.

Config surface — candidate naming (user, 2026-07-28; ~~not settled~~ adopted
provisionally by Design v3 above):

- `IngestMode` = `'Ignore'` | `'Selection'` — named from the run's
  perspective (the mode IS run intent), so the engine param and admiral's
  future declarative `mode:` field can share the name.
- Ignore mode: `SentinelFileNames`, `IgnoreDefaults` (unchanged) ·
  `IgnorePatterns` — user globs *added to* the discovered ignore-file
  materials (the virtual root ignore file, as today) ·
  `IgnoreOverridePatterns` — user globs that *countermand* ignore-file
  materials (the rescue layer). The Ignore-prefix pairing makes the
  added-to vs countermands relationship legible in the names.
- Selection mode: `SelectionPatterns`.

## Reconciliation with the current implementation (2026-07-28)

### Structural fact the design exploits

The five-stage pipeline in `rs.core.ignore.psm1` is **already
semantics-neutral**: Normalize→Coalesce→Walk→Reduce→CompileRegex transforms
(pattern sources per node) into (per-node `{Positives, Exceptions}` regex
pairs) with no knowledge of what matching *means*. Mode-awareness today exists
only at the rim (`IsOverrideMode` → `RunOverrideBypass()`) and at test time
(`TestPath` branching on the two-slot state). Design v2 therefore reshapes the
rim and touches none of the intricate middle.

### Internal architecture — mode-aware rim, neutral core

- **Core (untouched):** all five stage methods, NormalizeGlob/TranslateGlob/
  CompileGlobs/GlobSubsumes/GetParentPath, the signature regex cache, the
  sentinel scan body, eligibility filters, empty-leaf prune. ~90% of the
  engine survives verbatim.
- **Compile rim (ONE mode decision — source assembly + prune policy):**
  - *Ignore mode:* sources = sentinel entries + virtual root entry
    (IgnoreDefaults + IgnorePatterns), as today → five stages → Prune →
    override globs compiled separately (NormalizeGlob + annihilation +
    CompileGlobs → one broadcast regex; same utilities, no five-stage needed
    for a root-level broadcast set).
  - *Selection mode:* sources = virtual root entry (selection globs) only;
    sentinel scan **not invoked** (no I/O) → same five stages (Walk/Reduce run
    unchanged — root-only sources make them trivially cheap, zero branches,
    and future-proof per-node local selection sources) → Prune skipped.
- **State shape:** two slots collapse to one regime-stamped state:
  `CompiledState = { Regime; Positives; Exceptions; Override }`
  (Override non-null only in Ignore mode). `RunOverrideBypass()` and
  `IsOverrideMode` are deleted.
- **Test rim (the single semantic authority):** `TestPath` evaluates the dual
  truth table on `Regime`, with the override rescue folded in for Ignore
  states (`excluded = ignoreVerdict ∧ ¬Override.IsMatch`). No caller ever
  branches on mode; `Invoke-IgnoreFilter`'s inline `.Where()` semantics
  duplication collapses to a `TestPath` call.

Complexity accounting: mode branches total **two** — one at compile rim
(source assembly + prune policy), one inside TestPath (truth table). Stages:
zero. Net code volume shrinks (bypass method + duplicated filter logic
deleted).

### Prune × override resolution (was open)

Greedy crawl changes the calculus: pruning runs on an already-walked graph, so
it is a **CPU optimization only** (saves per-file regex tests), never I/O.
Resolution: **when override globs are present, skip directory-branch pruning**;
per-file TestPath (with rescue folded in) + the existing empty-leaf prune
produce the correct result. File-targeted overrides (`*.py`) therefore rescue
correctly even inside gitignored branches, with no glob-prefix reachability
analysis. A subsumption-based branch-rescue optimization (prune unless an
override glob could match under the branch) remains available later if the
regex-test cost ever matters.

### Config surface (proposal)

- `-Mode 'Ignore' | 'Selection'` — explicit, ValidateSet, default `'Ignore'`.
  Mode is run config; when admiral's declarative run-config exists this is its
  `mode:` field. Never inferred from which pattern lists are non-empty.
- Ignore mode: `-SentinelFileNames`, `-IgnoreDefaults`, `-IgnorePatterns`
  (all as today) + `-OverridePatterns` (the rescue; replaces
  `ExecutiveOverrides` naming and semantics).
- Selection mode: `-SelectionPatterns`.
- **Coherence validation via binding-awareness:** explicitly *bound*
  cross-mode params throw (`$PSBoundParameters` check — e.g. Selection mode +
  `-OverridePatterns` is a user error); defaulted-but-unused params are
  silently not consulted (IgnoreDefaults has defaults and cannot be
  throw-worthy by mere presence). Fail-fast additionally on empty/annihilated
  selection or override sets. (PowerShell parameter sets could make cross-mode
  binding unrepresentable at the interactive surface; runtime validation is
  the canonical layer since config will arrive declaratively via admiral.)

### Touch list

Changed: ctor signature, `Invoke()`, `TestPath`, `EmitOutput`,
`New-IgnoreCompiler` params + sentinel-scan gating, `Invoke-IgnoreFilter`
filter block + docstring contracts. Untouched: everything listed under Core.
Sequencing: composes freely with the RelativePath de-stamping edit (both touch
`Invoke-IgnoreFilter`; can land as one ignore-engine pass or separately).

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
- 2026-07-28 — **Reconciliation recorded**: five-stage core confirmed
  semantics-neutral (mode-awareness was always rim-only); architecture =
  mode-aware rim / neutral core, two total mode branches; state collapses to
  regime-stamped `CompiledState`; prune×override resolved (greedy crawl makes
  prune CPU-only → skip branch pruning when overrides present); config surface
  proposed (`-Mode` + per-mode named params + binding-aware coherence
  validation); touch list drawn. Remaining before code: naming adjudication
  (Mode values, OverridePatterns/SelectionPatterns), shim vs clean break.
- 2026-07-28 — Candidate naming recorded (user, not settled): `IngestMode`
  ('Ignore'|'Selection'); `IgnorePatterns` (added to discovered materials) +
  `IgnoreOverridePatterns` (countermands them); `SelectionPatterns`.
- 2026-07-28 — **Design v3 adjudicated and IMPLEMENTED** (Phase 2 complete):
  names adopted provisionally; override collapsed into negation merge (both
  ignore-side params = virtual root ignore sources, containers by
  convention); cross-mode params inert; CompiledState regime-stamped single
  slot; TestPath dual truth table; bypass deleted (clean break on
  ExecutiveOverrides); prune guarded to Ignore regime; fail-fast retained.
  Bonus latent bug fixed: Invoke-IgnoreFilter's empty-leaf prune leaked
  Dictionary.Remove's bool into the pipeline (masked until Selection mode
  made empty leaves common). New `tests/ignore.tests.ps1` 27/27 incl. the
  gitignore parent-dir constraint + directory-negation recipe as executable
  documentation; six-suite battery 205/205.
