# Ignore stage semantics — Ignore / Selection regimes (Design v3)

**Status:** IMPLEMENTED 2026-07-28 — this is what `rs.core.ignore.psm1` does
(`-IngestMode` on `New-IgnoreCompiler`; regime-stamped `CompiledState`;
`TestPath` dual truth table; `tests/ignore.tests.ps1`). · **Filed:** 2026-07-28;
carved out of `ignore-selection-inversion.md` 2026-08-15 so the semantics stand
alone from the backport analysis (that file keeps scope, cautions, sequencing
and the work log). · **Contract:** `reposnapshot-v3/schema/ignore.schema.json`
(in/out shapes; enforced by `tests/contracts.tests.ps1`). Names
(`IngestMode` / `IgnorePatterns` / `IgnoreOverridePatterns` /
`SelectionPatterns`) are provisional; the semantics are settled.

Reading order: Operational context → Design v3 (final) → Reconciliation. v2 and
the inversion architecture are kept as the record of how v3 was reached.

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