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

| Capability | LTS (RepoSnapshotLts.psm1) | v3 counterpart | Direction / status |
|---|---|---|---|
| Comment stripping | `Normalize-FileContent` stage 4 — token walk (2026-07-22 fix); cs/py/js combined alternation scan | `rs-psstrip` (kind ops + masking + auto-route, ahead of LTS as of 2026-07-22), `rs-csstrip` | **Resolved both sides.** End state: LTS dispatches to processors (comment-ontology). rs-csstrip should adopt LTS's combined-alternation technique (superior to span regexes for cs/js) — evaluate. |
| Whitespace/normalize | `Normalize-FileContent` stages 1–3 | `format-ws` (richer op vocabulary) | v3 forward; check stages 1–3 for behaviors format-ws lacks (NBSP→space, region markers → `region-markers` kind). |
| Ignore/selection | `Get-GitIgnoredPaths`, `Read-GitIgnoreRules`, `Convert-GitIgnoreGlobToRegex`, `Build-GitIgnoreMatcher`, `Find-ExternalIgnoreRules`, `Normalize-PatternArray`, `New-PathInclusionTester` | `rs.core.ignore` (IgnoreCompiler: inheritance walk, exception domination, override bypass, regex cache) | v3 is the design forward. Audit LTS for semantics v3 lacks: external ignore rules, `SelectionOverrides` behavior; TODO's "antisemantics" toggle redesign lands here. |
| Binary/content filter | `Test-IsBinaryFile`, `Get-FilteredFiles`, `Filter-Content` (has the `-ExpandProperty Count -gt 0` bug) | `file-read` NUL guard; `Invoke-IgnoreFilter` size/ext blacklist | v3 forward; decide whether content-pattern filtering (`Filter-Content`) survives at all or retires. |
| Preview/byte offsets | `New-ContentAndPreview`, `Get-EntryByteOffsets` (UTF-8 byte-accurate — the seek contract) | none yet | **Transfer to v3** with the sharding writer; the byte-offset contract is load-bearing for the MCP fetch API. |
| Tree/TOC rendering | `Build-DirectoryTree`, `Build-AsciiTree`, `Build-TreeDiagramCompact`, `Build-TocTree`, `Import-TocTemplateEngine` | `rs.core.template.ps1` (handlebars-lite, TOC models) | Overlapping; verify whether LTS already loads rs.core.template (Import-TocTemplateEngine) and consolidate renderers in v3. |
| Sharding/output | `Shard-SnapshotFile`, `Get-ShardedRepoSnapshot` (.txt shards + `*_tree.md`, escaped rows) | `rs.core.sharding` (older 3.1 gen: JSONL/piped + toc + manifest) | **Format decision pending** (TODO: make json monolith optional; runstamped subdir convention). LTS's txt+tree format is the agent-proven one for the CODE track. Re-disposition 2026-07-22: the module's JSONL machinery is NOT vestigial — it's the substrate for the thread-corpus track (`issues/thread-corpus-container.md`); don't retire. |
| Orchestration | inline sequential + serialized-function parallel runspaces | `rs.core.colonel.v2` (ISS plan compile, chain executor, worker budget) | Colonel forward; LTS path retires when v3 pipeline is whole. |
| Path utilities | `Resolve-RelPath`, `Norm-Path`, `Get-SnapshotPathParts`, `Get-SnapshotSiblingPath`, `Get-SnapshotArtifactPaths` | crawler `ToNodePath`; sharding `Get-NormalizedPath`, `ConvertTo-RelativePath` | Consolidate into one v3 home (internals?); currently three dialects of path normalization. |

## Known cross-cutting items

- **Monolith → IR distillation (the LTS spine).** LTS still runs artifact-first: it
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

- Instruction template drift: sharded instructions still say "seek to row_offset in the
  .json file" for .txt shards (visible in selfie tree.md).
- `Filter-Content` bug is live in LTS whenever include patterns/indicators are used.
- Subaddressing (extent linearization → composite chunks) will sit on the v3 side and
  is a *new* capability, not a transfer — but the shard-row/tree conventions it extends
  are currently defined by LTS output. Format decision above gates it.

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
    decision recorded in `issues/v3/admiral-orchestration.md` (new brief, same
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
  `issues/v3/rs.core.assemble-design.md`. **Plan (present vs deferred):**
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
  ignore engine is next opened beyond de-stamping.
