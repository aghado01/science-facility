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
| Entry-vs-skipped policy | **assemble** (policy input; LTS precedent = keep binary/oversized as content-less entries, visible in tree/rows) |
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
- `AssemblyPolicy` — ordering (path-sort for code track; semantic order for
  thread track; processors stay order-blind), entry-vs-skipped policy
  (default: LTS precedent, keep content-less entries), track adapter selection.

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
2. Entry shape finalization: field naming (LTS snake_case JSON vs v3 PascalCase
   objects), where NodePath lives on entries, whether ReadError entries carry
   their reason into attributes.
3. Global idx semantics for the thread track (corpus-wide reading order across
   threads vs per-thread).
4. Module name.

## Work log

_(append findings/results here)_
