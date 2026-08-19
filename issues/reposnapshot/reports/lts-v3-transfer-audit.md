# LTS ↔ v3 transfer audit

**Status:** scoping · **Filed:** 2026-07-22

## Provenance (why this audit exists)

The v3 modules were authored first; improvements were then **backported into the LTS
monolith** and v3 went stale (user, 2026-07-22 — this is how rs-psstrip fell behind its
own LTS descendant). Consequence: **LTS is not authoritative.** Not everything in LTS is
intended to transfer to v3, and backporting blurred which behaviors are design vs
monolith convenience. Every candidate transfer needs an intent re-evaluation first.

Per capability, the decision is one of: **transfer to v3** · **LTS-only convenience**
(dies with the monolith) · **retire**.

## Inventory — LTS surface vs v3 counterpart

**Structural correction (verified 2026-08-09, from code — supersedes any "separate
implementations" reading of this table):** LTS is **not** a standalone monolith. It
dot-sources `reposnapshot-v3\rs.core.template.ps1` at load
(`RepoSnapshotLts.psm1:11-14`, also re-loadable via `Import-TocTemplateEngine`) and
imports `reposnapshot-v3\rs.core.sharding.psm1` (`:21-24`), **consuming both v3 modules
as an orchestrator**. For the Tree/TOC and Sharding rows the "v3 counterpart" is
therefore already the LTS-driven engine, not a parallel reimplementation — the gap is a
**V3-native driver**, not the writer modules themselves. Those two rows corrected below.

| Capability | LTS (RepoSnapshotLts.psm1) | v3 counterpart | Direction / status |
|---|---|---|---|
| Comment stripping | `Normalize-FileContent` stage 4 — token walk (2026-07-22 fix); cs/py/js combined alternation scan | `rs-psstrip` (kind ops + masking + auto-route, ahead of LTS as of 2026-07-22), `rs-csstrip` | **Resolved both sides.** End state: LTS dispatches to processors (comment-ontology). rs-csstrip should adopt LTS's combined-alternation technique (superior to span regexes for cs/js) — evaluate. |
| Whitespace/normalize | `Normalize-FileContent` stages 1–3 | `format-ws` (richer op vocabulary) | v3 forward; check stages 1–3 for behaviors format-ws lacks (NBSP→space, region markers → `region-markers` kind). |
| Ignore/selection | `Get-GitIgnoredPaths`, `Read-GitIgnoreRules`, `Convert-GitIgnoreGlobToRegex`, `Build-GitIgnoreMatcher`, `Find-ExternalIgnoreRules`, `Normalize-PatternArray`, `New-PathInclusionTester` | `rs.core.ignore` (IgnoreCompiler: inheritance walk, exception domination, override bypass, regex cache) | v3 is the design forward. Audit LTS for semantics v3 lacks: external ignore rules, `SelectionOverrides` behavior. Redesign complete 2026-07-28: `issues/reposnapshot/reports/ignore-selection-inversion.md` (Design v2 — mode dichotomy + override rescue + reconciliation); implementation pending. |
| Binary/content filter | `Test-IsBinaryFile`, `Get-FilteredFiles`, `Filter-Content` (has the `-ExpandProperty Count -gt 0` bug) | `file-read` NUL guard; `Invoke-IgnoreFilter` size/ext blacklist | v3 forward; decide whether content-pattern filtering (`Filter-Content`) survives at all or retires. |
| Preview/byte offsets | `New-ContentAndPreview`, `Get-EntryByteOffsets` (UTF-8 byte-accurate — the seek contract) | none yet | Split 2026-07-28: **preview RETIRED as a concept** (perfunctory head/tail; future previews = new element family, uncommitted — assemble-design). **Byte offsets still transfer** with the writers; the seek contract remains load-bearing for the MCP fetch API. |
| Tree/TOC rendering | `Build-DirectoryTree`, `Build-AsciiTree`, `Build-TreeDiagramCompact`, `Build-TocTree` (inline renderers); `Import-TocTemplateEngine` (loads the v3 engine) | `rs.core.template.ps1` (handlebars-lite, TOC models) — **shared, already LTS-consumed** | **"Verify" RESOLVED 2026-08-09: YES.** LTS dot-sources `rs.core.template.ps1` at module load (`:11-14`) and via `Import-TocTemplateEngine` (`:79`) — the template engine is the shared engine LTS already drives, not a v3-only reimplementation. Remaining gap: (a) wire it into a V3-native path (no ingest/assemble consumer today), (b) consolidate LTS's **inline** `Build-*Tree` renderers against the module's TOC models. |
| Sharding/output | `Shard-SnapshotFile`, `Get-ShardedRepoSnapshot` — **inline `.txt`+`*_tree.md` emission** (escaped rows, byte offsets); **delegates grouped-strategy partitioning to the module** (`Partition-Files`, `:2355-2360`; Flat cuts inline) | `rs.core.sharding` (v3.1 gen): `Partition-Files` (arrangement) + JSONL/piped writers + toc + manifest | **Corrected 2026-08-09 — three surfaces, not two.** (1) `Partition-Files` = shared **arrangement** layer, **already LTS-consumed** for the code-track shard path. (2) The code-track **`.txt` row/offset/tree emission is still inline in LTS `Shard-SnapshotFile`** (`:2443-2465`, `[IO.File]::Open` byte writes) — the one piece **not** lifted to a v3 module. (3) The module's **JSONL/piped writers** (`ConvertTo-ShardFiles`/`Export-ShardedSnapshot`) are the **thread-corpus** substrate (module header `:22-34`); `ConvertTo-ShardFiles` takes `FromSnapshot`/`FromFiles` today with an **IR-entries entry point queued** — the intended IR→shards seam. Real gap = extract the inline `.txt` emitter + a V3-native driver (assemble IR → `Partition-Files` → writer). Format decision (json monolith optional; runstamped subdir) still open; the module's JSONL machinery is NOT vestigial (`issues/thread-corpus-container.md`). |
| Orchestration | inline sequential + serialized-function parallel runspaces | `rs.core.colonel.v2` (ISS plan compile, chain executor, worker budget) | Colonel forward. 2026-07-29: v3 pipeline is whole through the IR (crawl → ignore → colonel chains → assemble, golden-validated); LTS retires for the code track when the writers land. |
| Path utilities | `Resolve-RelPath`, `Norm-Path`, `Get-SnapshotPathParts`, `Get-SnapshotSiblingPath`, `Get-SnapshotArtifactPaths` | crawler `ToNodePath`; sharding `Get-NormalizedPath`, `ConvertTo-RelativePath` | Consolidate into one v3 home (internals?); currently three dialects of path normalization. |

## Known cross-cutting items

- **✓ DELIVERED 2026-07-29 — Monolith → IR distillation (the LTS spine).**
  `rs.core.assemble.psm1` produces the IR, golden-validated against a live
  LTS monolith (tests/assemble.tests.ps1); optional monolith *emission* is
  writer-phase. Original statement kept below for provenance.
  LTS still runs artifact-first: it
  emits the JSON monolith beside the shard directories (see the two ~256–273KB `.json`
  files under `.snapshot/`), then shards from it — because the monolith was the spine
  of the original code. History: reposnapshot originally emitted a single large JSON
  file, which failed on model-side ingestion — preview/context truncation horizons are
  model-dependent and uncontrollable — and that failure is the origin of sharding
  itself. v3 direction: the monolith is unnecessary *as an artifact*; its role becomes
  the **in-memory IR** assembled during ingestion (crawl → ignore → ingest → entries),
  which then feeds either or both writers (JSONL store / custom-format view). Artifact
  emission becomes an optional output, not a pipeline stage — which also makes row
  encoding a first-class writer decision instead of a serialization byproduct
  (shard-format-notes: selective encoding).

- **Gratuitous quote escaping in emitted rows — LTS defect, precluded in v3 (user,
  2026-08-09).** Measured on a production C# payload
  (`project-snapshots/ThermoMapper/src_20260701_122622`, 70 shards): **`\"` accounts
  for 7050 escapes, 12.0% of every escape in the artifact** — second only to `\n` at
  87.8%, and dwarfing `\\` at 127 (0.22%). It is pure `ConvertTo-Json` residue: under
  length-prefix framing quotes need no escaping at all, since the frame is declared
  and content is the final field. It is also where the payload's real legibility
  damage lives — `return '\"' + text.Replace(\"\\\"\", \"\\\"\\\"\") + '\"';` for a
  source line reading `return '"' + text.Replace("\"", "\"\"") + '"';`. v3 drops the
  whole class *by construction* (no JSON hop), so this needs no work — but it must
  not be reintroduced by a writer that reaches for `ConvertTo-Json` out of habit.
  Spec: `shard-format-notes.md` §"What the length prefix buys".
- Instruction template drift: sharded instructions still say "seek to row_offset in the
  .json file" for .txt shards (visible in selfie tree.md).
- `Filter-Content` bug is live in LTS whenever include patterns/indicators are used.
- Subaddressing (extent linearization → composite chunks) will sit on the v3 side and
  is a *new* capability, not a transfer — but the shard-row/tree conventions it extends
  are currently defined by LTS output. Format decision above gates it.

> **Canonical sequenced plan as of 2026-07-28:** `issues/reposnapshot/reports/v3-consolidation-plan.md`
> (consolidation-first doctrine; supersedes the inline plan sequencing in the
> work-log entries below, which remain as session record).

## Work log

- 2026-07-28 — **Processor-span disposition** (design session). Inventory of LTS work
  between content normalization and row rendering, classified:
  - **Chain (processor) candidates:** `rs-attributes.ps1` — entry metrics
    (char/word/punct counts, unique chars, entropy, compression ratio, whitespace
    ratio, line stats) + binary flag; contractually a **tail step** — LTS computes
    metrics on *post-normalization* content, so it must run after all content
    transforms in the profile. **Preview generation** (`New-ContentAndPreview`
    head/tail + `<...omitted...>` marker) — own processor or a config surface of
    rs-attributes. **`Filter-Content` line filtering** — processor only if it
    survives its retire decision (inventory row above); its `-ExpandProperty Count`
    bug dies with the monolith either way.
  - **Compute-vs-emit doctrine confirmed** (user): attributes/preview are computed in
    the chain by default; omission (`ExcludeAttributes` / `ExcludeShardBlocks`,
    `OmitEmptyPreview`, `IncludeFileContent`) is a **writer** knob, applied
    end-to-end (schema row and data rows agree). Improves an LTS quirk: LTS zeroes
    the metrics when content emission is off; v3 metrics describe the real processed
    content regardless of emission. Waste guard (attributes never emitted anywhere →
    chain profile compiled without rs-attributes) is an admiral config-projection
    mapping, not stage knowledge.
  - **Not processor work:** `last_write` capture → **crawler** (it already constructs
    FileInfo for SizeBytes; no v3 source exists today). **Entry-vs-skipped policy**
    for binary/oversized files — LTS keeps them as content-less entries, visible in
    tree and rows; v3 currently `_ChainHalt`s (file-read) or Skips (ignore size cap);
    the boundary is an IR-assembly contract decision. **Corpus ordering + global
    idx** → IR assembly (processors stay order-blind; thread track uses semantic
    order instead of path sort). Header assembly, tree model, row
    escaping/lengths/offsets → admiral and writers (deferred — serializers are not
    being written yet; pipeline is built one stage at a time).
  - **Colonel helper-function fix scoped:** `ReadProcessorScript`'s regex rejects
    interior helpers (tp-perplexity `_MaskByRegex`). Replace with an AST check that
    rejects only a single wrapping FunctionDefinitionAst / missing top-level param
    block, allowing interior helper functions.
  - **Crawler↔ignore residues named**; resolution architecture and the greedy-crawl
    decision recorded in `issues/reposnapshot/design/admiral-orchestration.md` (new brief, same
    session): information through-line via admiral, no lateral stage fusing,
    RelativePath-stamping/mutation-ownership/diagnostics-split cleanups.

- 2026-07-28 — **Ingest→processor seam broken (finding)** + **forward plan**.
  `Invoke-Ingest` passes colonel Items as AbsolutePath *strings*; `file-read.ps1`
  expects the descriptor object (`.AbsolutePath/.SizeBytes/.RelativePath/.NodePath`)
  — every chained item would `_ChainHalt` with ReadError. Root cause is the
  admiral-shaped hole: no owned item-identity contract at the seam. Resolution:
  **ItemDescriptor contract** (crawler stamps `AbsolutePath, RelativePath, NodePath,
  SizeBytes, LastWriteUtc`; ignore becomes pure filter; ingest passes descriptors;
  processors copy-on-enrich preserving identity fields) — spec in
  `issues/reposnapshot/design/rs.core.assemble-design.md`. **Plan (present vs deferred):**
  1. *Now (blocking):* crawler enrichment (RelativePath + LastWriteUtc) → remove
     ignore's stamping → ingest passes descriptor objects → end-to-end smoke test
     (crawl→ignore→ingest→file-read over this repo).
  2. *Now-adjacent (independent):* `rs-attributes.ps1` + tests; colonel AST
     validation fix + tests.
  3. *Next stage:* `rs.core.assemble` (name pending) per design seed — golden
     data-to-data validation of the IR against a fresh LTS monolith JSON, no
     serializers involved.
  4. *Explicitly deferred:* preview processor, Filter-Content retire decision,
     crawler diagnostics split, tree model home, all writers, admiral itself.

- 2026-07-28 — **Ingest reframe** (user): "ingest" is not a discrete stage — file
  reading is colonel's first processor; everything between ignore-compiler output
  and colonel's execution of it is the implicit admiral's purview.
  `rs.core.ingest.psm1` recognized as proto-admiral tissue (admiral brief updated;
  seam fix now understood as admiral-owned code repair). **Ignore-engine
  selection-inversion design elaborated** (user; extends TODO's "antisemantics"
  item): make selection semantics first-class as an *inversion* of ignore
  semantics — a `selection` vs `ignore` mode switch that inverts pattern
  semantics symmetrically, reusing the same glob→regex compilation machinery with
  an inverted-semantics mechanism, replacing today's gitignore-compiler +
  executive-override-for-keeps shape. **Solved reference implementation:**
  ThermoMapper's repo-audit machinery — originally adapted to C# from v3's
  crawler/ignore, then rearchitected with exactly this symmetric mode switch;
  port the architecture back. Adjudication: non-blocking for the ItemDescriptor
  seam work (de-stamping stays trivial); schedule as its own refactor when the
  ignore engine is next opened beyond de-stamping. Full comparison + backport
  sketch (same session): `issues/reposnapshot/reports/ignore-selection-inversion.md` — semantics
  as interpretation (enum + state stamp + dual TestPath truth table + Include-
  mode prune guard); C# dead-cache defect flagged do-not-import; sentinel
  semantics under Selection mode identified as the open design decision.

- 2026-08-09 — **Sharding/template consumer graph verified from code; inventory
  corrected** (prompted by user: "I thought LTS imported sharding already and was using
  that" — correct). All facts file:line-checked:
  - LTS dot-sources `rs.core.template.ps1` (`RepoSnapshotLts.psm1:11-14`) and imports
    `rs.core.sharding.psm1` (`:21-24`) — a **hybrid orchestrator over the extracted v3
    writer modules**, not a standalone monolith. Resolves the Tree/TOC row's standing
    "verify whether LTS already loads rs.core.template" → **yes**.
  - Sharding is **three** surfaces: `Partition-Files` (shared arrangement; LTS calls it
    at `:2360` for grouped strategies); the code-track **`.txt`/tree/offset emission
    still inline in LTS `Shard-SnapshotFile`** (`:2443-2465`); and the module's
    JSONL/piped writers = thread-corpus substrate with an IR-entries entry point
    **queued** on `ConvertTo-ShardFiles` (module header `:22-34`).
  - Back-half framing corrected: the writer *modules* are real and in production use
    **via LTS**; what is unbuilt is the **V3-native driver** (assemble IR →
    `Partition-Files` → writer) plus extraction of the inline `.txt` emitter.
    "Writers unbuilt" was too strong — "emission monolith-locked + no V3 orchestrator"
    is accurate. Audit-only correction; no code changed this session.
