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

## The four analysis relationships — name yours before reasoning

Most confusion on this project is a category error between these:

1. **Self-validation** — the pipeline analyzes its *own* components
   (colonel rejects `#Requires` in processor scripts; runspace/ISS reasons).
2. **Analysis-for-mutation** — code-analysis tools applied to *ingested
   materials as data* (rs-psstrip's PS-AST comment stripping).
3. **Analysis-for-enrichment** — metrics over processed content
   (rs-attributes) as a payload design feature for reader navigation.
4. **Reader-directed guidance** — instruction prose shipped *with* the
   payload (tree Instructions block) — functional machinery, not docs.

Same construct can play different roles per relationship: `#Requires` is
*rejected* in processor bodies (inert in ISS-registered functions) and
*protected* in ingested scripts (live frontmatter sharing comment syntax).

## Known conflation hotspots

- **Byte semantics, three layers, never conflated**: `SizeBytes` (on-disk,
  eligibility only) · `Attributes.SpanBytes` (UTF-8 span of processed
  content — payload semantics) · rendered row `length` (encoded span,
  writer-side). See `issues/v3/rs.core.assemble-design.md` §Payload doctrine.
- **PowerShell ingesting PowerShell**: pipeline code vs ingested code —
  always ask which role a construct is playing.

## Where things live

- `reposnapshot-v3/` — v3 modules (crawler → ignore/selection → colonel
  chains → assemble → writers) + `processors/` (ISS-loadable, body-only,
  `param($Item, $Config)`, copy-on-enrich, interior helpers allowed).
- `issues/v3/` — design docs. **`v3-consolidation-plan.md` is the sequenced
  work ledger**; `admiral-orchestration.md` holds the orchestrator design
  (admiral doesn't exist yet — stages carry contracts for what it will
  provide; test harnesses play admiral).
- `reposnapshot-v3/CHANGELOG.md` — dated per-change sections, newest first.
- `tests/` + `reposnapshot-v3/processors/tests/` — plain-PS assert harness
  (Enter-Section / Assert-True), no Pester, `$PSScriptRoot`-relative.
- `RepoSnapshotLts.psm1` — the legacy monolith. **Not authoritative**
  (see `issues/v3/lts-v3-transfer-audit.md`); it carries known defects
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

## Maintaining this document (recursive note)

This file is part of the deliverable-for-developer-agents surface and is
subject to the same discipline it describes: **when your work changes a
standing convention, retires or adds a module, moves a design doc, or
alters the pipeline shape, update this file in the same commit.** Stale
orientation is worse than none — it primes the next agent into the wrong
basin with full confidence. Keep it short: orientation and pointers only;
detail belongs in `issues/` design docs and module docstrings.
