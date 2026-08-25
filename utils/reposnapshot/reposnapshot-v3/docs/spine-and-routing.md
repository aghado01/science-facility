# Spine & Routing

Per-file plan compilation for heterogeneous ingestion sets. A declared **spine** fixes the canonical stage sequence; routed stages carry a meta-token resolved per file class from **routing tables**. `Compile-Plan` emits a **plan family** — a small set of dense, frozen chains plus an extension→variant map — and the colonel hands each ingest item its assigned chain. Language-specificity exists only as data in the routing tables, consumed only by the compiler.

> **Status**: target shape. Current code compiles a single monolithic chain; the adaptation sites and sequence are listed under [Implementation Sequence](#implementation-sequence).

## Two-Layer Contract

The design rests on two independent guarantees that must not be conflated:

1. **Correctness — precondition self-sufficiency.** Each processor establishes its own preconditions (see [mutator-contracts.md](mutator-contracts.md)); some operations therefore run redundantly across processors. This is deliberate: it makes *every* stage combination correct by construction, including compiled variants with stages spliced out. No stage may ever assume its canonical predecessor ran. This discipline is load-bearing for routing — the day it erodes, per-file variation silently breaks for the variants that omit a stage.
2. **Canon — nominal ordering.** The spine orders the nominal path for quality and non-waste. Placement is derived, not taste: **stage A follows stage B if B can produce output violating A's postcondition.** (Stripping emits trailing whitespace → tidy follows strip; every mutator invalidates measurement → measure runs last.) A new stage is placed by asking which existing postconditions it can break.

Correctness never depends on the canon; the canon exists so the nominal run is clean and so a reading agent can rely on a stable stage story.

## The Routing Artifact

One file, `processors/routing.json`, holds both the spine and the routing tables — token ids must agree across them, so they are never split. `configs/` stays at exactly one file per processor key.

```json
{
  "Stages": [
    { "Stage": "read",       "Processor": "file-read" },
    { "Stage": "parse",      "Processor": "tp-perplexity" },
    { "Stage": "$strip",     "Routed": "Strip" },
    { "Stage": "indent",     "Processor": "rs-indent" },
    { "Stage": "whitespace", "Processor": "rs-whitespace" },
    { "Stage": "measure",    "Processor": "rs-content_meta" }
  ],
  "Strip": {
    "powershell": { "Extensions": ["ps1", "psm1", "psd1"], "Processors": ["rs-psstrip"] },
    "csharp":     { "Extensions": ["cs", "csx"],           "Processors": ["rs-csstrip"] }
  }
}
```

Loader rules:

| Rule | Behavior |
|---|---|
| Malformed file | Hard error (unlike `configs/<key>.json`, which warns and defaults). |
| Extensions | Dot-less in the file; normalized to lowercase-with-dot on load. |
| `Processors` entries | Processor **keys** (manifest names), in declared order; multi-entry routes splice as consecutive peer steps. |
| Route validation | Every route's keys must exist in the processor manifest — validated unconditionally, even for routes no corpus file will use. |
| Exactly-once | Every processor the spine references belongs to exactly one stage: either one fixed stage's `Processor`, or route membership under exactly one token (multiple routes under the *same* token may share a processor). Double appearance is a hard error — this supersedes the earlier duplicate-splice caution. |
| Token discipline | Tokens (`$strip`, …) exist only as data read from this file — never as PowerShell string literals in source (double-quoted `"$strip"` interpolates to empty). |

## Compilation: The Plan Family

`Compile-Plan` walks the spine once per file class present in the ingestion set: enabled stages are kept, routed tokens are resolved for that class, and unresolved tokens are **spliced out** — dense lists, no tombstones. A null/no-op placeholder step is explicitly rejected: it would force the executor to know what a hole is.

Example — heterogeneous ingest of `.py`, `.ps1`, `.ts` with `$strip` enabled and a Python route present but no TypeScript route:

| Variant | Chain |
|---|---|
| `powershell` | `file-read → rs-psstrip → rs-indent → rs-whitespace → rs-content_meta` |
| `python` | `file-read → rs.py.strip → rs-indent → rs-whitespace → rs-content_meta` |
| `default` (ts, everything unrouted) | `file-read → rs-indent → rs-whitespace → rs-content_meta` |

The Plan becomes:

```
Plan = {
  Variants      = @{ variantKey → frozen step list of @{ Key; Fn; Config } }
  Routing       = @{ normalized extension → variantKey }   # miss → 'default'
  Iss           = one InitialSessionState registering the UNION of processors across variants
  ProcessorKeys = union across variants
}
```

- **Variant identity** is the tuple of token resolutions (not one token's, not per-extension) — `.ps1` and `.psm1` share one compiled chain. The family is bounded by tuples actually present in the corpus, not the product of the tables.
- **The default variant always exists** and equals the spine minus every hole. An unrouted file gets no routed treatment but everything else in the same order — its chain is simply shorter. "Language without a processor yet" and "extension never heard of" are the same bucket, deliberately: adding a route later moves files out of the default with zero code diff.
- **Validation vs binding are split**: all routes validate always (a broken route for an absent language fails today, not on first encounter); only corpus-present variants are bound and registered into the ISS.
- Per-variant chain checks ("measure is last", "chain omits whitespace") run per compiled variant — strictly more coverage than a single monolithic check.

## Dispatch

The colonel stays flat and the executor stays dumb:

- **Slicing** remains round-robin over the flat item list; a third parallel array beside `sliceItems`/`sliceIdxs` carries per-item variant keys, resolved at slice time from `Plan.Routing`. Flat round-robin is the load-balancing optimum here — each worker gets a representative mix of variants, so cost-skew between chains never concentrates in one worker. Partitioning dispatch by chain is rejected.
- **One RunspacePool from the one superset ISS** — the pool layer already works this way; the only change is that registered keys are the union across variants.
- **The family is marshalled once** (same minimal-shape discipline as the current single-chain marshal) and the same object is shared by reference across all workers. Total plan storage for a run is V chains + N per-item keys — never N chains. Workers treat the shared family as **immutable**.
- **Workers** prebuild a `variantKey → plan` table once at startup; per item, plan selection is a dictionary lookup. The invocation of `Invoke-ChainExecutor` is unchanged: it receives a fully resolved, internally consistent plan for the given typed item.
- **Untouched**: `chain-executor.ps1`, `bag-helpers.ps1`, budget resolution, bin packing, stream harvesting, the index-stable output envelope.

Routing resolves before `file-read` runs, so it can never depend on content (no shebang sniffing for extensionless files). Extension-only routing is the v1 call; the escape hatch — hoist `file-read` into a fixed prologue and route on the post-read bag — is a known shape, not a planned one.

## Caller Surface

Callers **enable stages, never order them** — the routing instance of [stage-architecture.md](stage-architecture.md)'s "Config Selects, Implementation Owns Sequence". `-StripComments` enables `$strip`; position comes from the spine.

`-Processors` forks into two explicit modes:

- **Set under canon** (default): the caller names participants; the compiler orders them by the spine. Array position is meaningless.
- **Verbatim** (distinct flag, name TBD — `-OrderStrict` is taken by bin packing): the literal sequence runs as written, cautions only. This preserves reposnapshot as an instrument for deliberately violating its own invariants without letting a plain call do it by accident.

Under the canon path, today's soft chain cautions become compiler guarantees and are no longer printed; under verbatim they remain as warnings.

### Classification

The spine is the **single processor registry**; classification is structural, declared by where a processor appears:

- **Fixed-stage processors** appear as a stage entry (`{ "Stage": "parse", "Processor": "tp-perplexity" }`). Declared is not enabled: a spine entry fixes position only; the stage runs when a caller enables it.
- **Routed processors** are classified by route membership — a language stripper is a `$strip`-stage processor *because* a `Strip` route names it. No separate declaration exists or is needed.
- `configs/<key>.json` carries **no ordering metadata** — it stays pure config with its warn-and-default posture; classification lives where hard-error validation and referential integrity already are (the same argument that fused spine and routing tables into one file extends to membership: a stage rename cannot orphan classifications in the same document).

Consequences:

- **Set-mode resolution**: naming a processor key enables its stage. For a routed stage this enables the token — routing still decides per file class, so `-Processors 'rs-psstrip'` on a mixed corpus enables `$strip` wherever it resolves. `-StripComments` and naming a `Strip` member are the same operation spelled two ways.
- **Unregistered processor named under canon mode** → hard error stating both fixes: register it in the spine, or run verbatim.
- **Unreferenced processor *file* on disk** → inert, not an error — a WIP processor can land in `processors/` without breaking runs. Completeness for the shipped set (manifest ⊆ spine) is enforced by a repo test, not at runtime.

## Echo

Tokens are the unit of report. Per-variant ConfigEcho must keep three stories distinguishable:

| Story | Echo |
|---|---|
| Routed and resolved | `$strip → rs-psstrip` |
| Enabled but unresolved for this class | `$strip → ∅` (stripping was *on*; no resolver existed — e.g. TypeScript comments present for this reason, not because stripping was off) |
| Stage disabled for the run | stage absent from every variant |

Any manifest structure that tabulates per-step data across files keys by variant + processor key, never by position.

## Invariants

1. No component below plan compilation branches on file type. The compiler alone reads the routing tables; the colonel applies an opaque map; the executor iterates what it is given.
2. Stages self-establish preconditions (correctness layer); the spine orders the nominal path (quality layer). Neither substitutes for the other.
3. Variants are dense — splice, never tombstone.
4. Indices are variant-local cursors; cross-variant and cross-run identity is by processor key or stage token, never position. Chains of unequal length coexist in one run.
5. The shared plan family is immutable in workers.
6. The default variant always exists and equals the spine minus all holes.
7. Tokens exist only as data, never as PowerShell string literals.
8. Each stage's postcondition states which byte accounting survives it (`SpanBytes` vs `SizeBytes` — see [content-metrics.md](content-metrics.md)); wherever line-ending canonicalization lands, this is stated, not discovered.
9. Every processor is classified by a single appearance in the spine — one fixed stage, or route membership under one token. `configs/` carries no ordering metadata; classification is structural.

## Implementation Sequence

Each step lands with its tests through `tests/run-all.ps1` before the next begins. Steps 1–2 change no runtime behavior; existing monolithic calls keep working until step 3 wires the family through.

| Step | Work | Test gate |
|---|---|---|
| 1 | `processors/routing.json` (spine incl. fixed `parse` entry for `tp-perplexity` + `Strip` routes for powershell/csharp) + loader with normalization and hard-error validation | Malformed-file errors; extension normalization; route keys exist in manifest; exactly-once |
| 2 | `Compile-Plan` emits the family (`Variants`/`Routing`/union `Iss`/union `ProcessorKeys`) | Pure-function tests: mixed extension set → expected variant tuples; dense chains of differing lengths; default variant present; spine invariants (measure last, strip precedes whitespace); validate-all vs bind-present; completeness (manifest ⊆ spine) |
| 3 | Colonel: third slice array, family marshal, worker lookup table | Index-stable envelope over mixed corpus; each item demonstrably ran its assigned chain (bag `Processing` trail) |
| 4 | Caller surface: `-StripComments` → `$strip`; `-Processors` set semantics (stage enablement) + verbatim flag; unregistered-processor hard error; caution retirement on canon path | End-to-end heterogeneous ingest (`.ps1`/`.cs`/`.md`) |
| 5 | Per-variant ConfigEcho with token resolutions | Echo assertions in the e2e test |
