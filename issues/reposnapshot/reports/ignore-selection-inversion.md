# Ignore ↔ Selection semantics inversion — repo-audit backport analysis

**Status:** ~~design analysis~~ **IMPLEMENTED 2026-07-28** (Design v3 —
`-IngestMode` on `New-IgnoreCompiler`; `tests/ignore.tests.ps1` 27/27; see
work log) · **Filed:** 2026-07-28
**Sources compared:** `ThermoMapper/src/repo-audit/{IgnoreEngine.cs, GlobCompiler.cs}`
(descendant) vs `reposnapshot-v3/rs.core.ignore.psm1` (ancestor).
Extends TODO's "antisemantics" item; supersedes LTS `SelectionOverrides` and v3
`ExecutiveOverrides` as the selection mechanism.
**Semantics moved out (2026-08-15):** operational context, lineage, inversion
architecture, Design v2/v3 and the reconciliation now live in
`ignore-semantics-update.md`. This file keeps the backport scope, cautions,
sequencing and work log.

## Scope of "backport" (user, 2026-07-28)

**Backport means incorporating the symmetric-inversion *concept* that emerged
in repo-audit's adaptation — NOT replacing reposnapshot's ignore engine with a
transliteration of repo-audit's machinery.** The two applications share
overlapping needs met by this lineage, but their use cases differ: repo-audit's
needs are less complicated and more contained; reposnapshot's charter is more
general. Design for reposnapshot specifically, without letting repo-audit's
missteps or simplifications corrupt the intricate work in reposnapshot's
engine.


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

Remaining open after implementation (2026-07-29 refresh): final naming
(current names adopted provisionally, renameable); whether the Selection
regime ever gains per-node sentinel-style *local* selection sources
(currently: no — user population is root-injected only, though the machinery
would permit it). Resolved en route: ~~shim vs clean break~~ (clean break,
Design v3); ~~override × directory pruning~~ (superseded by Design v3 —
overrides are ordinary root-level negations under canonical gitignore
precedence; the directory-negation recipe is the documented, tested answer).

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
