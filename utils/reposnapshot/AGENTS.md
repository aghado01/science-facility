# AGENTS.md — developer-agent orientation for reposnapshot

This is the **developer repository** for reposnapshot — you are building the
tool, not reading its output. The deliverable is a snapshot **payload
consumed by a reading/consumer agent** (an LLM). Format and enrichment
decisions are justified by *reader cognition* — token economy, navigation,
attention dilution, lost-in-the-middle — not by conventional serialization
taste. Hold that audience frame for every design call.

**The broader mission covers code, config, and documents over ONE substrate
— asymmetrically, and flexibly.** Code ingestion is the trunk. Config
handling is an *extension of the code run* (repo config is relevant to code
analysis): not ingested by default, but surfaced as a companion document of
pointers to source (absolute paths) cross-linked to code shard rows via
linkage analysis. Markdown/docs ingestion is the *composable axis* — a
standalone corpus ingestion (thread corpus) or a repo-run extension
packaging project documentation as its own sharded/chunked payloads. The
container/addressing machinery is mode-agnostic; **the ROW is
mode-semantic** (code rows = files; doc rows = units the document's
structure yields — exchange envelopes, section-units). Track adapters, the
open element model, and header-declared schemas carry the differences —
never format forks. Flexibility is the constitution: these are composable
run modes with overridable defaults, not a fixed taxonomy.
(assemble-design §Content-class dispositions; thread-corpus brief;
md-processor-family design.)

## How to read the design docs

Design docs under `issues/reposnapshot/` describe the **target** pipeline;
parts of it are unbuilt (admiral, shards, serialize). Code that does not yet
match a design doc is not a defect and must not be reconciled in either
direction unprompted. **Tests are the only enforcement.** When the user
extends a stage toward a documented future consumer — a field nobody reads
yet, a hook nothing calls yet — that is the design landing, not a
contradiction to flag. Ask "is this free at this stage's vantage?" before
asking "who consumes it?" Rationale and history displaced from docstrings
live in `issues/reposnapshot/design/module-notes.md`; docstrings state
contracts only.

## The four analysis relationships — name yours before reasoning

Most confusion on this project is a category error between these:

1. **Self-validation** — the pipeline analyzes its *own* components
   (colonel rejects `#Requires` in processor scripts; runspace/ISS reasons).
2. **Analysis-for-mutation** — code-analysis tools applied to *ingested
   materials as data* (rs-psstrip's PS-AST comment stripping).
3. **Analysis-for-enrichment** — metrics over processed content
   (rs-content_meta, né rs-attributes — renamed 2026-08-17 after the psr
   `content_meta` block it feeds) as a payload design feature for reader
   navigation.
4. **Reader-directed guidance** — instruction prose shipped *with* the
   payload (tree Instructions block) — functional machinery, not docs.

Same construct can play different roles per relationship: `#Requires` is
*rejected* in processor bodies (inert in ISS-registered functions) and
*protected* in ingested scripts (live frontmatter sharing comment syntax).

## Recalculating something upstream already had is a lookback signal, not a task

If you find yourself about to derive a value a previous stage held, **stop and
look back**. Do not implement the derivation. Find where the fact was dropped
and ask why, because only a few reasons are legitimate and each is on record:

- **portability** — `AbsolutePath` is destroyed because a payload carrying
  machine-specific paths is not portable;
- **anti-misuse** — `SizeBytes` is excluded because its presence in the bag is
  what invited packing on it (ledger #26/#39);
- **unavailability** — the fact genuinely cannot be had at that vantage
  (ledger #38).

If the reason turns out to be tidiness, or "nothing downstream needed it yet",
the fix is **upstream**: retain the fact. The `carried` tier exists for exactly
this (ledger #50) — on the entry for downstream stages, not counted in
`Header.Elements`, never a wire column unless `container.spec.jsonc` names one.

**Why it is a defect class and not merely duplication.** Two derivations of one
fact must agree forever, with nothing forcing them to. `Extension` was the live
case: stamped at crawl by `[Path]::GetExtension`, carried intact through
membrane and ingest, destroyed at assemble, then re-derived by shards from
`RelativePath` for `ByFileType` grouping. The two agree on every realistic
input and diverge on a trailing-dot leaf. That it is a small divergence is the
point — you cannot know in advance where two independent derivations differ,
only that nothing is checking. `RelativePath` is the same pattern working:
computed once at crawl, carried to the payload as the record's identity, never
re-derived by anyone.

**What the rule is scoped to, and the test that decides it.** The smell is *one
value recomputed*. So ask: **do the two results have to agree?**

- **Must agree** → it is one fact computed twice, and nothing forces the two to
  match. Look back.
- **Must not agree** → they are different facts that happen to share atoms and a
  definition. There is nothing to fix.

A conditioned aggregate is the second case. `rollups(walked)` and
`rollups(payload)` are entirely distinct calculations answering distinct
questions over the same retained measurements (ledger #52) — they are *supposed*
to differ, and requiring them to agree would itself be the error. This is not an
exception to the rule; it was never in its scope. Reuse the definition rather
than writing a second loop, but that is ordinary economy, not a rescue.

**The test cuts both ways, and getting it backwards is easy.** A rollup has two
independent axes: the **condition** — which slice of the data it runs over
(walked, surviving, discarded; the WHERE) — and the **grouping** — how the
result is keyed (per node; the GROUP BY). "Root" is on neither axis:
`ByNode['']` is just the output row whose group happens to be the whole slice.
Conflating the axes is how `DirectoryCount` got documented as "the same
aggregation at root scope" and asserted equal to `ByNode[''].SubtreeDirCount` —
two numbers that both *sit at the root* but answer different questions (graph
nodes including root; descendants excluding self) and differ by exactly one.
The suite caught it. Two numbers being adjacent, or derived from the same data,
does not make them one fact.

## Known conflation hotspots

- **Byte semantics, three layers, never conflated**: `SizeBytes` (on-disk,
  eligibility only) · `ContentMeta.SpanBytes` (UTF-8 span of processed
  content — payload semantics; element renamed from `Attributes` 2026-08-17,
  wire block `content_meta`) · rendered row `content_bytes` (né `length`; encoded span,
  writer-side). See `issues/reposnapshot/design/rs.core.assemble-design.md` §Payload doctrine.
- **Encoding and codec belong to the serializer** (2026-08-09). Upstream
  stages measure in *canonical UTF-8 by convention* — deliberately invariant
  to what a writer emits, so attributes stay comparable across runs. Both
  declarations are owed to the reader —
  `issues/reposnapshot/planning/payload-manifest-ledger.md` #16/#17; open look-back items in
  consolidation §B.6e.
- **Planning never reads written bytes; it computes them forward** (narrowed
  2026-08-15 from "planning is not measurement"). Every byte of a shard file
  is ours and every input is in memory at plan time, so a row's serialized
  size is a pure function — `Measure-Row(-Layout -Entry)` from the one
  layout module (`rs.core.container`, landed 2026-08-17), over the same
  `Format-Row` pieces `Build-Row` builds bytes from. Shards packs on it
  exactly; there is no estimate. What stays true: **offsets are the writer's
  receipt** (`Build-Row`'s cursor, written by serialize),
  never derived from a measure and never recovered from a written file; and
  never publish a layer 2 number (`ContentMeta.SpanBytes`) where a reader will
  spend it as an offset or an exact length. `SpanBytes` remains the
  emission-invariant reader-facing attribute; it is not the packing input
  (ledger #26 stands). See `briefs/shards-brief.md`.
- **Naming grade: `Span` measures content, `Size` bounds a container** (user,
  2026-08-10). The naming corollary of the rule above, and it binds on code
  **not yet written**. `Span` belongs to numbers stating how much *content*
  something actually is — `ContentMeta.SpanBytes`, the tree manifest's byte
  spans, the rendered row `content_bytes`. `Size` belongs to numbers stating what a
  *container* holds or may hold — on-disk `SizeBytes`, and every packing
  budget. A budget named `…SpanBytes` borrows the measurement family's
  vocabulary for what is only a policy knob, which is precisely the conflation
  the rule above warns about. So v3's new `rs.core.shards` (arrangement /
  planning) names its budgets with `Size`, while `rs.core.serialize`
  (emission) is where measured spans come from — the planned module split is
  already drawn on this seam. **Forward-only:** LTS and the legacy
  `rs.core.sharding` keep `MaxShardSpanBytes` as-is; they are in service and
  deliberately not renamed.
- **PowerShell ingesting PowerShell**: pipeline code vs ingested code —
  always ask which role a construct is playing.

## History before 2026-08-06 lives under the pre-migration paths

reposnapshot moved from `D:\aghado01\utils\reposnapshot` (repo retired) into
`science-facility` at `utils/reposnapshot`, via `git subtree add`. All 77 commits
came with it — but the imported commits carry their ORIGINAL paths
(`reposnapshot-v3/...`, not `utils/reposnapshot/reposnapshot-v3/...`), and the
subtree merge is where the two path spaces join. Consequences:

- `git blame <file>` **works normally** and is the everyday tool — it traverses
  the merge and attributes lines to the original commits and paths.
- `git show <hash>` works for any pre-migration commit.
- `git log -- utils/reposnapshot/...` shows **only the merge commit**. Default
  history simplification does not cross into the imported side.
- To browse pre-migration file history, either add `--full-history` and use the
  OLD path, or log from the imported tip:
  `git log 58a1a26 -- reposnapshot-v3/processors/rs-psstrip.ps1`
  (`58a1a26` = imported reposnapshot tip; jso-jackson's is `5cf0f1e`.)

Nothing is lost; it is just addressed by the old path. Do not "fix" this by
rewriting history.

## Where things live

- `reposnapshot-v3/` — v3 modules, **named for what they implement**:
  `rs.core.crawler` → `rs.core.membrane` → `rs.core.ingest` (+ colonel chains)
  → `rs.core.assemble` → `rs.core.shards` → `rs.core.serialize` /
  `rs.core.manifest`. The **pipeline vocabulary** — *Discover → Membrane →
  Ingestion → Assembly → Export* — belongs to admiral's wrappers over these
  modules, not to the module names (crawler implements discovery; shards +
  serialize + manifest implement export). Membrane's dependency is
  `GlobCompiler` (semantics-neutral; `-GlobSemantics Ignore|Selection` says
  what a match means) — "ignore" is a semantics, not a stage. +
  `processors/` (ISS-loadable, body-only,
  `param($Item, $Config)`, copy-on-enrich, interior helpers allowed).
  `contracts/<stage>.contract.json` — per-stage I/O contracts (`{ stage, in, out }`,
  field registers under named shapes; `from: "<stage>.out.<shape>"` marks a
  field taken verbatim from upstream). `tests/contracts.tests.ps1` checks every
  `from` resolves (input ⊆ upstream output) and prints join residues — fields
  reachable only by joining a stage's output with a retained upstream output.
  Assemble reads its own contract's `out.entry.core`/`exclude`. When you add a
  field: stamp it, declare it in the origin's `out`, add `from` where it passes
  through, and add it to `assemble.out.entry.exclude` if it must not reach the
  payload. (Renamed from `*.schema.json` 2026-08-16: the files are contracts,
  and "schema" was doing double duty — decisions #34; the folder itself moved
  `schema/` -> `contracts/`.) `contracts/container.spec.jsonc` is the one
  non-contract in that folder: the **psr** container's admissible declaration,
  read by `rs.core.container`; the contracts suite globs `*.contract.json` and
  skips it.
- `issues/reposnapshot/` — design docs (`design/`, `briefs/`, `planning/`,
  `reports/`, `discussions/`, `archaeology/`). **Planning canon is the
  `planning/` triple**: `decisions.md` the settled calls, `roadmap.md` what is
  ahead, `ledger.md` what landed — plus `payload-manifest-ledger.md`, a separate
  registry of declarations the payload owes a reader. `reports/` holds
  point-in-time reports and superseded plans, `discussions/` verbatim chat logs.
  (The executed `v3-consolidation-plan.md` moved to `reports/` 2026-08-19.)
  `design/admiral-orchestration.md` the orchestrator design (admiral doesn't
  exist yet — stages carry contracts for what it will provide; test harnesses
  play admiral); `design/module-notes.md` per-module rationale displaced from
  docstrings.
- `reposnapshot-v3/CHANGELOG.md` — dated per-change sections, newest first.
- `tests/` + `reposnapshot-v3/processors/tests/` — plain-PS assert harness
  (Enter-Section / Assert-True), no Pester, `$PSScriptRoot`-relative.
  **Run the battery with `tests/run-all.ps1`** — do not hand-count PASS lines.
  It pre-parses each suite, requires the summary line, cross-checks the
  summary against the emitted asserts, and exits 1 on any suite that fails,
  aborts, or never ran. Two ways a suite can look green while truncated, and
  they need different defenses:
    - *dies before its summary / does not parse* — the runner catches this.
    - *aborts mid-run inside try{}/finally{} with no catch* — the runner
      **cannot**: finally runs, execution resumes past the block, and the
      summary prints a self-consistent passing count for the asserts that did
      run. Every suite therefore carries a `catch` that records
      `SUITE ABORTED` as a failure. **Keep it when adding a suite.**
- `RepoSnapshotLts.psm1` — the legacy monolith. **Not authoritative**
  (see `issues/reposnapshot/reports/lts-v3-transfer-audit.md`); it carries known defects
  (zeroed metrics when content off; compression_ratio always 0). As of
  2026-07-29 it is no longer load-bearing for the code-track data model:
  `rs.core.assemble.psm1` produces the IR, golden-validated against a live
  LTS monolith (`tests/assemble.tests.ps1`). LTS remains the reference for
  the writer phase (row format, byte offsets, tree manifest).

## Standing conventions

- Stages are developed independently; contracts live in module docstrings;
  data flows through the orchestrator, never laterally between stages.
- Payloads are lean: failed/empty ingests route to diagnostics, never into
  the payload. Store vs view: in-memory structures optimize for processing
  ergonomics; what the *payload* carries is a writer decision.
- User prefers working directly on main with targeted commits per work item.
- **Minimalism, proportional to the problem** (user, 2026-08-04). Prefer
  language-level PowerShell over provider/vendored surface and the piping
  baggage it drags in. Subject to expediency and robustness: *don't bring a
  bazooka to a knife fight, but bring the bazooka to the bazooka fight.* The
  target is **gratuitous** dependency, not capable tooling — Roslyn for C#
  comment extraction is sanctioned (string-literal-aware parsing genuinely
  needs it, and it ships with pwsh).

  **Weigh the caveat every time: barebones forfeits convenient guarantees.**
  Cmdlets carry edge-case semantics you inherit free and must otherwise
  re-establish by hand — `Sort-Object` is a *stable* sort where `List.Sort` /
  `[Array]::Sort` are not; `Measure-Object` survives empty input;
  `Where-Object`/`ForEach-Object` normalize null and scalar-vs-array;
  `Add-Member` tolerates collisions and awkward names. Replacements that quietly
  drop those become latent bugs of exactly the kind this repo keeps finding
  (the `[string]` → `''` null coercion, the `Dictionary.Remove` bool leak,
  GetParentPath's infinite loop).

  Guidance for new processors:
  1. Default to language constructs where the semantics are total and obvious
     (`foreach`, `if`, `-match`, `-replace`, direct .NET calls).
  2. Reach for a cmdlet when it carries a guarantee you would otherwise
     reimplement — and say which, in the self-doc block.
  3. Declare what you use; `IssPreset floor` / `Required IssModules` already
     exist in that block.
  4. Do **not** hand-roll merely to reach Bare. **Bare ISS is an aspiration,
     not a mandate** — deliberately not institutionalized; Core stays the
     working default until a declarative ISS makes the choice granular
     (consolidation §E).

  Where the fleet stands (AST-audited 2026-08-04 — audit by parser, not grep:
  a first pass miscounted docstring mentions as calls): **provider-free**, and
  `Add-Member` is now **gone entirely**, absorbed into the shared
  `processors/bag-helpers.ps1` (`Resolve-BagContent` / `Copy-Bag`, registered
  into every worker runspace by `Compile-Plan -SharedHelperPath`). The clone is
  a single `[ordered]` cast, which also works under Bare where `Add-Member`
  does not exist. `chain-executor.ps1` and `bag-helpers.ps1` use no cmdlets at
  all. What remains is four Utility calls: `Sort-Object` (rs-csstrip,
  rs-psstrip), `ForEach-Object` (rs-whitespace — né format-ws, renamed
  2026-08-17 to say its lane: code ingestion, not markdown — rs-psstrip), `Where-Object`
  (rs-indent, tp-perplexity), `Measure-Object` (rs-indent) — all with
  verified language-level equivalents, none load-bearing for stability
  (consolidation §E). Incidental debt, not structural dependency.

## Maintaining this document (recursive note)

This file is part of the deliverable-for-developer-agents surface and is
subject to the same discipline it describes: **when your work changes a
standing convention, retires or adds a module, moves a design doc, or
alters the pipeline shape, update this file in the same commit.** Stale
orientation is worse than none — it primes the next agent into the wrong
basin with full confidence. Keep it short: orientation and pointers only;
detail belongs in `issues/` design docs and module docstrings.
