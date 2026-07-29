# rs.core.assemble — IR assembly stage (design seed)

**Status:** scoping · **Filed:** 2026-07-28 · **Name:** working title (user:
"`rs.core.assemble` or somesuch")

The next pipeline stage after colonel's chain execution: collates per-item
processed results into the in-memory IR — the successor of the LTS JSON
monolith *as data structure*, never as artifact (transfer-audit "Monolith → IR
distillation"). Note the ingest reframe (admiral brief, 2026-07-28): "ingest"
is not a stage — file reading is colonel's first processor, and
`rs.core.ingest.psm1` is proto-admiral tissue mediating dispatch.

## Separation of concerns vs the absent admiral (user, 2026-07-28)

The tension: up to the end of colonel's job, processor chains are applied to
ingested files. It is **admiral's** job to feed discovery-stage outputs into
colonel (ingestion manifest, configuration, etc.) and to pick up the processed
outputs for each ingested file. Admiral is not being written now — so **whatever
is written next must carry clearly delimited contracts for what to expect from
the currently absent admiral**. The LTS code flow informs the workflow, but
that workflow implicitly interleaves admiral work with assemble work; the
decomposition below is the reconciliation.

Interim rule: tests/harness scripts play admiral, calling stages against these
same contracts — the contracts are written for admiral, exercised by harnesses.

## Decomposition of the LTS flow

| LTS behavior | v3 owner |
|---|---|
| Root/output resolution, timestamp, config echo | admiral (RunContext) |
| Enumeration, ignore, eligibility | crawler + ignore stages |
| Read, normalize, metrics per file | colonel processors (file-read, strip/ws, rs-attributes) |
| Entry collation, ordering, global idx | **assemble** |
| Header stamping | **assemble** (stamps RunContext handed to it — never computes it) |
| Entry-vs-skipped policy | **assemble** (policy input; v3 default = lean payload: failed/empty reads route to the diagnostics sidecar, never rendered — see Payload doctrine below; supersedes LTS's content-less-entries behavior) |
| Tree models, previews-at-emission, monolith JSON, rows/offsets/shards | writers (deferred — no serializers yet) |

## Contracts

### ItemDescriptor — the load-bearing identity contract (NEW, blocking)

The unit that flows discovery → ingest → colonel → processors → results:

```
@{ AbsolutePath; RelativePath; NodePath; SizeBytes; LastWriteUtc }
```

- **Produced by crawler** during the greedy walk (RelativePath and LastWriteUtc
  are new — both free at collection time: root is known, FileInfo already
  constructed for SizeBytes). Resolves residue #1: ignore stops stamping
  RelativePath and becomes a pure filter. **Landed 2026-07-28** (crawler side:
  identity fields stamped at walk time; `RelativePath = NodePath + name`;
  `LastWriteUtc` as [datetime] — writers format; tests in
  `tests/crawler.tests.ps1`).
- **Path doctrine (user, 2026-07-28** — full statement in the crawler module
  docstring**):** AbsolutePath exists for unambiguous ingestion-side reads and
  never appears in rendered artifacts; RelativePath is the artifact-facing
  identity — the snapshot anchors to a root, hierarchy is represented flatly,
  and nested structure is encoded in the root-anchored relative path alone.
  Minimal-duplication design for the LLM consumer: repository structure
  without system-path prefix tokens (see the `*_tree.md` selfies + shard row
  paths for the doctrine in practice). In-memory descriptors may carry
  redundant convenience fields (NodePath is the derivable directory portion
  of RelativePath); what the *payload* carries is a writer decision —
  store-vs-view applied to paths. Multi-root snapshots ("root directories")
  stay accommodated: paths remain root-anchored; a root identifier field can
  join the descriptor later without reshaping it.
- **Ignore** prunes/filters descriptors; enriches nothing. **Landed
  2026-07-28**: de-stamped (RelativePath comes from crawler), vestigial
  `RootPath` param removed, fail-fast guard on pre-contract input.
- **Ingest passes descriptors — not paths — as colonel Items.** Finding
  (2026-07-28): `Invoke-Ingest` flattened to AbsolutePath *strings* while
  `file-read.ps1` expects the descriptor object — the code-track chain was
  broken end-to-end at this seam. Colonel tests missed it because they call
  Invoke-Plan directly with objects. **Fixed 2026-07-28**; proven by
  `tests/pipeline.smoke.tests.ps1` (23 asserts, harness-as-admiral).
- **Processors preserve identity fields on enrichment** (contract clause).
  file-read now clones ALL input properties (copy-on-enrich, never mutating
  the input reference) — descriptor evolution (e.g. a future multi-root id
  field) flows through without touching processors.

### Assemble inputs (what the absent admiral provides)

- `DispatchOutput` — `{ Results; Skipped; Errors; Warnings; Budget; Timing }`
  (the envelope currently produced by `Invoke-Ingest`, index-aligned Results;
  per the ingest reframe this is admiral's pickup of colonel's processed
  outputs, not a stage output — envelope shape unchanged).
- `RunContext` — run-level header material: root, timestamp, config echo,
  generator/version, run timing. Assemble stamps it in; computing it is
  admiral's job.
- `AssemblyPolicy` — entry-vs-diagnostics routing (default: lean payload —
  failed/empty reads to the diagnostics sidecar, see Payload doctrine) and
  track adapter selection. **Ordering is deliberately NOT AssemblyPolicy's**
  (revised 2026-07-28): the IR carries canonical ingested order; sorting,
  subsorting, and grouping are emission-side arrangement knobs (see
  Arrangement layer under the Operation-order doctrine).

### Assemble output — the IR

```
{ Header; Entries[]; Skipped; Diagnostics }
```

Entry shape informed by the LTS monolith entry
(`path, last_write, attributes{...}, preview, content`) plus addressing
identity. Attributes/preview are optional fields (compute-vs-emit doctrine —
transfer-audit 2026-07-28); absence must be legal so assemble can land before
rs-attributes does.

### Track adapters

- **Code**: 1 item → 1 entry (descriptor + processed content + attributes).
- **Thread**: 1 item (thread file) → tp-perplexity envelope
  `{Id, Path, Exchanges[]}` → **N** exchange entries (row = ExchangeBlock;
  forces thread-corpus open decision 1: row schema / thread-metadata home).

## LTS monolith inventory & v3 disposition (scoped 2026-07-28)

Sources: `Get-RepoSnapshot` assembly+serialization (`RepoSnapshotLts.psm1`
~1935–2165) and selfie ground truth (`.snapshot/reposnapshot_20260722_195015.json`,
`_20260723_035834.json`). Selfies confirm: top level is `header` + `files`
only — the flag-gated members (`DirectoryStructure`, `AsciiTree`, `paths`)
default off and are absent; entries carry no `preview` property
(`OmitEmptyPreview` + previews off); `params`/`flags` are present in
practice; `git_history` empty (never requested).

### Top level

| LTS element | v3 disposition |
|---|---|
| `header` | `IR.Header` — assemble stamps RunContext + computes assembly stats |
| `files` | `IR.Entries` — **canonical ingested order** (revised 2026-07-28: LTS's path-sort-at-serialization was the arrangement layer done as a hardcode; v3 keeps the IR in ingested order and makes sorting/subsorting/grouping an emission-side knob family — see Arrangement layer) |
| `DirectoryStructure` / `AsciiTree` / `paths` (flag-gated, default off) | writer-side view options, not IR members; tree-model construction (`Build-DirectoryTree`) is writer-phase, consuming IR entries + SpanBytes |

### Header elements

| LTS field | v3 owner / successor |
|---|---|
| `export_date` | `RunContext.RunStamp` [datetime] — writers format `'o'` |
| `root` | `RunContext.Root` — absolute; **whether it appears in payloads is a writer decision** (path doctrine: system paths are ingestion-side; flagged) |
| `file_count` | assemble-computed `EntryCount` |
| `ps_version`, `parallel_processing`, `max_parallelism` | Environment echo — RunContext + colonel's real `Budget` object (richer than LTS's booleans) |
| `max_preview_chars` | **vestige — retire** (belongs to the retired head/tail preview; see Open element model) |
| `version` ("2.7.1") | `RunContext.GeneratorVersion` (v3 generator identity) |
| `execution_time_ms` | admiral `Timing` (per-stage; colonel Timing folds in) |
| `json_depth` | writer knob — contributed at emission, not IR |
| `git_history` (optional git-log array) | optional RunContext enrichment (admiral-side external call); keep as optional block |
| `tree_diagram` (compact tree STRING in header) | **removed from IR** — LTS embeds a view inside the store; v3 store/view separation makes it a writer emission option |
| `filters{...}` | splits by provenance: pattern echo → ConfigEcho (IngestMode-world names); `derived_directory_exclusions` **retires** (no directory-first derivation in v3); `external_ignore_rule_count`/`git_ignored_count` → superseded by v3 ignore diagnostics (sentinel aggregate, skip counts, IngestMode) |
| `processing{...}` (3 booleans) | `ProfileEcho` — the compiled chain Steps/ops (strictly richer) |
| `params` (full invocation echo) | `RunContext.ConfigEcho` verbatim — the declarative run config object IS this, natively (invocation-surface duality noted in admiral Q6) |
| `flags` (derived quick-scan booleans) | **candidate retire** — derived redundancy over ConfigEcho; keep only if reader-orientation value is shown (open) |

### Entry elements

| LTS field | v3 owner / successor |
|---|---|
| `path` | `RelativePath` (crawler identity) |
| `last_write` (ISO string) | `LastWriteUtc` [datetime] (crawler); `'o'` formatting at write |
| `attributes.binary` | **retired from entries** — lean payload: binary/failed reads route to diagnostics sidecar |
| `attributes.size_bytes` (on-disk) | **replaced** by `Attributes.SpanBytes` (byte-semantics correction) |
| `attributes.char_count … line_stats` | rs-attributes (compression_ratio corrected — known golden delta) |
| `preview` | **retired as a concept** (user, 2026-07-28): the head/tail first-N…last-M preview was perfunctory and is useless — `preview`, `max_preview_chars`, `include_file_previews`, `OmitEmptyPreview` are all vestiges of it. Future previews are a NEW element family — language/doc-type-specific triage signals (e.g. word clouds) — deliberately **not committed now**; the Open element model below is how they arrive later without assemble changes |
| `content` | `Content` |

### Write-time mechanics — writer phase, NOT assemble

LTS couples these to monolith serialization; they transfer with the writers:
streaming envelope-then-entries emission; per-entry compact JSON;
`Get-EntryByteOffsets` against live `FileStream` positions (the seek
contract — offsets are inherently emission-coupled, as the transfer audit
already noted); TOC assembly → `Build-TocTree` → template-engine `_tree.md`;
`OmitEmptyPreview`. Assemble's obligation to all of this is only: ordered
entries with Content + SpanBytes.

## Open element model + config/code separation (user, 2026-07-28)

Two requirements, one architecture:

**Requirement 1 — fluid extensibility without present commitment.** Future
enrichments (doc/language-specific previews, word clouds, whatever earns its
place as a triage signal) must be incorporable later with zero assemble
edits. Therefore:

- **Entries are self-describing property bags**, not fixed schemas. The
  guaranteed core is identity + Content (per track adapter); every other
  element is whatever the chain's processors attached. Generic
  copy-on-enrich already guarantees chain-side flow-through; assemble's
  matching obligation is to **never project results down to a known column
  set** — it collates what arrives.
- **Assemble declares, writers consult.** The Header carries an `Elements`
  declaration — per-element presence counts computed from the observed
  entries (e.g. `Attributes: 20/20`, `WordCloud: 3/20`). This is the shard
  format's configurability doctrine ("readers parse exactly what the header
  declares — never a fixed column set") transposed to the IR: the payload's
  self-description starts at assembly, and doubles as coverage diagnostics.
  A new enrichment arrives as: new processor in the profile → its element
  appears in entries → appears in declarations → writers render it (or not)
  per their own config. No assemble change at any step.
- Assemble has **no per-element code branches** — it does not know what
  "Attributes" means. Element semantics live in processors (production) and
  writers (rendering); assemble is neutral collation.

**Requirement 2 — configuration separated from code, on the
`rs.core.template` precedent.** The template engine's structure is the
model: a neutral engine (`Expand-Template` — knows nothing about content) ·
thin model builders (project runtime facts into flat models) · the variable
parts as declarative data (the template string, the instruction sets).
Assemble mirrors it:

| template engine | assemble |
|---|---|
| `Expand-Template` (neutral) | collation core (neutral — property bags in, IR out) |
| model builders (`New-*TocModel`) | track adapters (code: 1 item → 1 entry; thread: envelope → N exchange entries) |
| template + instruction sets (data) | `AssemblyPolicy` + RunContext (declarative inputs); element declarations (derived data) |

Changing what a payload carries or how it is ordered is a data change
(policy/profile), never an assemble code change — same as changing the tree
manifest's wording is a template edit, never an engine edit.

## Operation-order doctrine — config selects members, implementation owns sequence (user, 2026-07-28)

Precedent: `format-ws.ps1`. `Operations` is a **set** the user subsets; the
implementation applies the selected ops in a **fixed internal order** (`lf`
first so downstream line ops see LF … `eof-eot` last) because application
order is a correctness invariant of the domain, not a user preference. The
config surface is structurally incapable of expressing a wrong order —
membership is tested (`-in $ops`), never iterated as a program. Same
coherence-by-construction family as cross-mode param inertness: invalid
states are unrepresentable by the *shape* of the surface, not rejected by
validation.

The principle transfers to assembly at three levels:

1. **Assemble's internal phases are a fixed sequence** — the direct
   format-ws analog:

   ```
   adapt   (track adapter: results → entries; envelope → N exchange entries)
   route   (entry vs diagnostics — lean-payload policy)
   derive  (Elements declaration + counts — after route so skips don't
            pollute coverage)
   stamp   (Header last — EntryCount/Elements need final entries)
   ```

   `AssemblyPolicy` plugs *selections into slots* (WHICH adapter, WHICH
   routing default) and cannot reorder the slots. The per-entry building
   convention is NOT reinvented: colonel's index-stable Results arrive in
   ingested order, entries are built in that order, and **the IR's order IS
   the canonical ingested order** — assemble has no ordering phase at all.

   **Arrangement layer (user, 2026-07-28)** — between the IR and the
   serialization write live the sorting, subsorting, and grouping knobs: a
   design feature expressing reposnapshot's configurability philosophy, not
   an assemble concern. Precedent already in place: `Partition-Files`'
   `GroupingStrategy`/`PackingStrategy`, and LTS's path-sort-at-serialization
   (the same layer, hardcoded instead of knobbed). Consequences: the IR is
   the *store order* (canonical, ingested); every emitted artifact's order
   is a *view arrangement* selected by generation knobs ("policy lives in
   generation knobs, not reader conventions" — shard-format-notes); global
   idx is assigned over the writer's final arrangement, not in the IR
   (narrows open decision 3 to the arrangement layer); golden comparison
   matches entries by path key, never by position (LTS monoliths are
   path-sorted views of their own ingested order).

2. **Chain-profile level (admiral, future)** — today, processor application
   order is the profile author's responsibility, guided by documented
   positional contracts (rs-attributes' tail rule). Candidate
   (unadjudicated): profile compilation orders *selected* processors
   mechanically from declared precedence classes (content mutators →
   enrich-only tail), completing the transfer at the chain level — the
   user picks the processor set, admiral's projection owns the sequence.

3. **Writer level (already embodied)** — `rs.core.template`'s template
   string fixes the artifact's section sequence; the model supplies
   content. Header/manifest block layout in emitted artifacts is the
   writer template's job; assemble guarantees block *content* only.

## Ownership map — what lives in the implementation vs elsewhere (2026-07-28)

Assemble is a **stage** (`rs.core.*` module convention), not a chain
processor (`rs-*.ps1`): collation is cross-item, needing all results + run
context no item carries. Conceptually it relates to the stage sequence as
rs-attributes relates to the chain — a read-only tail that mutates nothing
and adds no row-level information. Six sources of truth; only the first two
live in the implementation:

| # | truth | lives | notes |
|---|---|---|---|
| 1 | **Macro-structure** (Header/Entries/Skipped/Diagnostics exist; phase sequence; Header carries declarations) | assemble, as code | the LTS monolith's *implicit* schema (shape-of-literals residue) made an explicit, documented contract — data-independent convention, format-ws-style |
| 2 | **Derived facts** (EntryCount, Elements declaration) | assemble, computed | the only information assemble creates; all observational |
| 3 | **Row-level truth** (bag contents + accumulation, content form, row order) | the chain (manifest + Steps + ingested order) | assemble inherits, never re-decides |
| 4 | **Run-level truth** (RunStamp, Root, GeneratorVersion, ConfigEcho, Timing) | RunContext — admiral/harness | assemble stamps, never computes |
| 5 | **Policy** (routing default, adapter selection) | AssemblyPolicy (data) | two slots |
| 6 | **View concerns** (artifact block layout, wire naming, arrangement knobs, idx) | writers/arrangement layer | absent from the IR |

Two-tier schema statement: **macro-schema = convention-in-code (assemble
owns); element-schema = open + derived (chain produces, assemble declares,
per run)**. Nothing implicit remains.

### IR schema draft (concrete)

```
IR = @{
  Header = @{
    RunStamp          [datetime]   # RunContext
    Root              [string]     # RunContext (payload emission = writer call)
    GeneratorVersion  [string]     # RunContext
    EntryCount        [int]        # assemble
    Environment       @{ PSVersion; Budget }      # RunContext + colonel
    Timing            @{ per-stage ms }           # admiral
    ConfigEcho        [object]     # run config verbatim (params successor)
    ProfileEcho       @{ Steps }   # compiled chain profile
    FilterDiagnostics @{ IngestMode; SentinelIgnoreFiles summary; skip counts }
    GitHistory        [object[]]   # optional
    Elements          @{ <name> = @{ Count; Total } }   # observed-element
                                  # declaration (open element model) —
                                  # payload self-description + coverage
  }
  Entries  = @( @{ RelativePath; NodePath; LastWriteUtc; Content;
                   <any processor-attached elements, e.g.
                    Attributes = @{ SpanBytes; CharCount; ... }> } )
             # OPEN property bags — guaranteed core + whatever the chain
             # attached; assemble never projects to a fixed column set.
             # Order = CANONICAL INGESTED ORDER (store order); all other
             # orders are emission-side view arrangements (knobs)
  Skipped / Diagnostics             # lean-payload sidecar feed
}
```

PascalCase in memory; snake_case wire naming is a writer rendering decision
(narrows open decision 2: the in-memory convention is settled by doctrine,
wire naming belongs to writers).

## Payload doctrine (user, 2026-07-28)

**Byte semantics — three layers, never conflated:**

1. `SizeBytes` (descriptor identity, crawler-stamped) — filesystem
   bookkeeping. Sole legitimate consumer: pre-read eligibility (ignore
   stage's size ceiling). Irrelevant to the reader; never emitted as a
   payload attribute.
2. `Attributes.SpanBytes` (rs-attributes) — UTF-8 byte span of the
   **processed content**: the payload-description number, same semantics
   family as the tree manifest's byte spans and the precise-span read
   tooling (fetch pure content without container overhead). Also the
   natural packing input. (LTS conflated layers 1–2: its
   `attributes.size_bytes` was the on-disk size.) Naming reconciliation
   queued for the writer phase: `Partition-Files` currently probes a
   `ByteSpan` property — align to `SpanBytes`/`Attributes.SpanBytes` when
   the writers land.
3. Rendered row `length` field — writer-side span of the **encoded**
   content, computed at render time (selective encoding changes it). Never
   a pipeline value.

**Lean payload, diagnostics sidecar:** reposnapshot payloads are as lean as
possible, with options ensuring high visibility and auditability — through
the *diagnostics channel*, not payload bloat. Failed ingests (ReadError,
binary halt) and **empty reads are never rendered into the payload**; they
route to a diagnostic sidecar/log artifact. The tree manifest is part of
the payload, so routed items don't appear there either. Distinct reasons
should survive to the sidecar (at minimum: read-failure kinds vs
`EmptyFile` vs `EmptiedByProcessing` — a file stripped to nothing is a
different fact than a file empty on disk). Sidecar form/naming not settled
("a log file or diagnostic file"); the IR already carries the feed
(`Skipped` + `Diagnostics`), so the sidecar is a writer concern layered on
existing streams.

## Validation without serializers

Golden data-to-data comparison: run the v3 pipeline over this repo → IR;
regenerate an LTS monolith JSON with matching config → parse → compare entry
sets (paths, content, attributes within rounding). No writers involved. Known
deltas to tolerate: processor-vs-Normalize differences (rs-psstrip ahead of
LTS), preview initially absent, LTS zeroed-metrics-when-content-off quirk,
**compression_ratio** (LTS defect found 2026-07-28: reads disposed
MemoryStream.Length after GZipStream.Close → null → 0; every >100-char LTS
entry emits 0, verified in the 20260723 selfie. rs-attributes emits the real
ratio via ToArray — correctness over parity).

## Open decisions

1. Identity-through-chain vs admiral-side join: descriptors riding the chain
   (above) answers the code track cheaply; whether assemble *also* consumes an
   admiral-retained discovery index (for data processors shouldn't carry) is
   admiral open question 4.
2. ~~Entry shape field naming~~ — narrowed 2026-07-28: PascalCase in-memory is
   settled by doctrine; snake_case wire naming is a writer rendering decision.
   Remaining: whether ReadError reasons surface anywhere beyond Diagnostics.
3. Global idx semantics for the thread track (corpus-wide reading order across
   threads vs per-thread) — narrowed 2026-07-28: idx is assigned at the
   arrangement layer over the writer's final order, not in the IR; the
   semantic question remains but is emission-side.
4. Module name.
5. Header `flags` block: retire (derived redundancy over ConfigEcho) vs keep
   (reader quick-orientation value) — from the monolith inventory.
6. `Header.Root` in emitted payloads: absolute system path vs path doctrine —
   writer decision, but the default posture needs a call.
7. `git_history`: keep as optional RunContext enrichment (admiral-side git
   call) — assumed yes, unexercised in practice (empty in both selfies).

## Work log

_(append findings/results here)_
