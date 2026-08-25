# RepoSnapshot V3 Architecture & Design Documentation

This directory contains the collected architectural doctrines, invariants, and design specifications for RepoSnapshot V3 (`rs.core` suite and processors).

## Table of Contents

### Pipeline Stages & Orchestration
- [Stage Architecture](file:///D:/aghado01/science-facility/utils/reposnapshot/reposnapshot-v3/docs/stage-architecture.md) — Pipeline lifecycle (Crawl → Membrane → Ingest → Colonel → Assemble → Shards → Serialize → Manifest), macro-structure, and ownership boundaries.
- [Crawler & Graph](file:///D:/aghado01/science-facility/utils/reposnapshot/reposnapshot-v3/docs/crawler-and-graph.md) — BFS directory walk, graph representation, rollup separation, and stamped free metadata.
- [Membrane & Globs](file:///D:/aghado01/science-facility/utils/reposnapshot/reposnapshot-v3/docs/membrane-and-globs.md) — Selection vs Ignore semantics, 5-stage `GlobCompiler`, eligibility guards.
- [Colonel & ISS](file:///D:/aghado01/science-facility/utils/reposnapshot/reposnapshot-v3/docs/colonel-and-iss.md) — Plan compilation, AST script validation, InitialSessionState presets, and runspace pool dispatch.
- [Spine & Routing](file:///D:/aghado01/science-facility/utils/reposnapshot/reposnapshot-v3/docs/spine-and-routing.md) — Canonical stage spine, processor registry (`processors/registry.json`), per-file-class plan families, and variant dispatch for heterogeneous ingests. *(Target shape.)*
- [Assemble & IR](file:///D:/aghado01/science-facility/utils/reposnapshot/reposnapshot-v3/docs/assemble-and-ir.md) — In-memory Intermediate Representation (IR), open element model, and entry routing.
- [Container & Wire](file:///D:/aghado01/science-facility/utils/reposnapshot/reposnapshot-v3/docs/container-and-wire.md) — Piped Snapshot Rows (`psr`), spec-driven grammar (`container.spec.jsonc`), and symbol substitution codec.
- [Sharding & Packing](file:///D:/aghado01/science-facility/utils/reposnapshot/reposnapshot-v3/docs/sharding-and-packing.md) — Multi-objective deterministic bin packing (`FrontLoad` vs `Even`), group sorting, and quota management.
- [Serialize & Manifest](file:///D:/aghado01/science-facility/utils/reposnapshot/reposnapshot-v3/docs/serialize-and-manifest.md) — Writer receipts, plan-file invariance, and Handlebars-lite tree manifest generation.
- [Horizontal Internals](file:///D:/aghado01/science-facility/utils/reposnapshot/reposnapshot-v3/docs/horizontal-internals.md) — Parameter forwarding via `DynamicParam` reflection and stage wrapper registration.
- [User CLI & Config](file:///D:/aghado01/science-facility/utils/reposnapshot/reposnapshot-v3/docs/user-cli-and-config.md) — Orchestration entry point, resolution precedence, and configuration lifecycle.

### Processors & Mutator Doctrines
- [Mutator Contracts](file:///D:/aghado01/science-facility/utils/reposnapshot/reposnapshot-v3/docs/mutator-contracts.md) — Harmonized content mutators, copy-on-mutate, bag resolution, and `_ChainHalt`.
- [Content Metrics](file:///D:/aghado01/science-facility/utils/reposnapshot/reposnapshot-v3/docs/content-metrics.md) — `ContentMeta` statistics, invariant UTF-8 `SpanBytes` vs on-disk `SizeBytes`, and entropy/compression formulas.
- [Whitespace & Invisibles](file:///D:/aghado01/science-facility/utils/reposnapshot/reposnapshot-v3/docs/whitespace-invisibles.md) — Code-lane whitespace normalization, semantic invisible preservation (ZWJ/ZWNJ), `pad-breaks`, and receipt honesty.
- [Comment Stripping & AST](file:///D:/aghado01/science-facility/utils/reposnapshot/reposnapshot-v3/docs/comment-stripping.md) — PowerShell AST parse-boundary partitioning (`FrontMatter` vs `Native`), regex fallback, and C# regex classifier.
- [Thread Parsing](file:///D:/aghado01/science-facility/utils/reposnapshot/reposnapshot-v3/docs/thread-parsing.md) — Perplexity export parsing, asymmetric citations, and sentinel masking.
