# Spine & Routing

Per-file plan compilation for heterogeneous ingestion sets. A declared **spine** fixes the canonical stage sequence; routed stages carry a meta-token resolved per file class from the **processor registry**. `Compile-Plan` emits a **plan family** — a small set of dense, frozen chains plus an extension→variant map — and the colonel hands each ingest item its assigned chain. Language-specificity exists only as data in the registry, consumed only by the compiler.

> **Status**: target shape. Current code compiles a single monolithic chain; the adaptation sites and sequence are listed under [Implementation Sequence](#implementation-sequence).

## Two-Layer Contract

The design rests on two independent guarantees that must not be conflated:

1. **Correctness — precondition self-sufficiency.** Each processor establishes its own preconditions (see [mutator-contracts.md](mutator-contracts.md)); some operations therefore run redundantly across processors. This is deliberate: it makes *every* stage combination correct by construction, including compiled variants with stages spliced out. No stage may ever assume its canonical predecessor ran. This discipline is load-bearing for routing — the day it erodes, per-file variation silently breaks for the variants that omit a stage.
2. **Canon — nominal ordering.** The spine orders the nominal path for quality and non-waste. Placement is derived, not taste: **stage A follows stage B if B can produce output violating A's postcondition.** (Stripping emits trailing whitespace → tidy follows strip; measurement describes the content rendered downstream, not the raw input, so every mutation invalidates it → measure runs last.) A new stage is placed by asking which existing postconditions it can break.

Correctness never depends on the canon; the canon exists so the nominal run is clean and so a reading agent can rely on a stable stage story.

## The Registry Artifact

One file, `processors/registry.json`, is the source of truth for canonical ordering and routing. It is normalized into three sections — **order is a spine fact, extensions are language facts, classification is a processor fact** — so each fact is declared exactly once:

```json
{
  "Spine": ["read", "$strip", "indent", "whitespace", "measure"],
  "Languages": {
    "powershell": ["ps1", "psm1", "psd1"],
    "csharp":     ["cs", "csx"]
  },
  "Processors": {
    "file-read":       { "Stage": "read" },
    "rs.ps.strip":     { "Stage": "$strip", "Language": "powershell" },
    "rs.cs.strip":     { "Stage": "$strip", "Language": "csharp" },
    "rs-indent":       { "Stage": "indent" },
    "rs-whitespace":   { "Stage": "whitespace" },
    "rs-content_meta": { "Stage": "measure" }
  }
}
```

`Spine` ids name **processor families** in their prescribed rank order — read before everything, measurement after every mutation. A family is either fixed (exactly one member) or language-routed (a `$` token); the rank order is a property of the family, so strippers for any language occupy the same slot in otherwise equivalent chains.

`Processors` is keyed on processor keys — the same keyspace as the manifest and `configs/<key>.json` — so **exactly-once holds by construction** (one entry, one `Stage`) and **completeness is a set comparison**. Routes are **derived**, not declared: the `$strip` members for `powershell` are the processors whose entries declare that pair. Registry entries carry classification only, never config; `configs/` stays at exactly one file per processor key.

Loader rules:

| Rule | Behavior |
|---|---|
| Malformed file | Hard error (unlike `configs/<key>.json`, which warns and defaults). |
| Extensions | Dot-less in `Languages`; normalized to lowercase-with-dot on load. An extension maps to at most one language — routing must be a function. |
| `Stage` values | Must appear in `Spine`. Token stages (`$`-prefixed) require `Language` on their members; fixed stages forbid it and have exactly one member. |
| `Language` values | Must appear in `Languages`. A string or an array — a generic processor may serve several languages, still one stage. |
| No phantom members | A language is listed in `Languages` only if some processor claims it; membership cannot be declared for a processor that does not exist. Extensions of unclaimed languages stay unmapped and fall to `default`. |
| Registry validation | Every `Processors` key must exist in the processor manifest — validated unconditionally, even for entries no corpus file will use. |
| Within-partition rank | Ordering inside a family binds only within a (stage, language) **partition**. A single-member partition takes no `Rank`, and declaring one is an error; a multi-member partition requires an explicit unique `Rank` on every member and hard-errors until supplied. File position is never consulted. No partition is multi-member today, so no `Rank` appears in the shipped registry. |
| Token discipline | Tokens (`$strip`, …) exist only as data read from this file — never as PowerShell string literals in source (double-quoted `"$strip"` interpolates to empty). |

## Compilation: The Plan Family

`Compile-Plan` walks the spine once per file class present in the ingestion set: enabled stages are kept, routed tokens are resolved for that class, and unresolved tokens are **spliced out** — dense lists, no tombstones. A null/no-op placeholder step is explicitly rejected: it would force the executor to know what a hole is.

Example — heterogeneous ingest of `.py`, `.ps1`, `.ts` with `$strip` enabled and a Python route present but no TypeScript route:

| Variant | Chain |
|---|---|
| `powershell` | `file-read → rs.ps.strip → rs-indent → rs-whitespace → rs-content_meta` |
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

- **File class = language.** `Languages` maps extensions to a class; unmapped extensions fall to `default`. **Variant identity** is the class's tuple of token resolutions, not the class name — `.ps1` and `.psm1` share one compiled chain because they share a language, and *distinct classes whose tuples coincide share one too* (a generic stripper claiming c/cpp/objc yields one variant, three extensions mapping into it). The family is bounded by tuples actually present in the corpus, not the product of the registry.
- **The default variant always exists** and equals the spine minus every hole. An unrouted file gets no routed treatment but everything else in the same order — its chain is simply shorter. "Language without a processor yet" and "extension never heard of" are the same bucket, deliberately: adding a route later moves files out of the default with zero code diff.
- **Validation vs binding are split**: the whole registry validates always (a broken entry for an absent language fails today, not on first encounter); only corpus-present variants are bound and registered into the ISS.
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

By analogy — to the selection/sequence split alone, not to the mechanism — this is [rs-whitespace](whitespace-invisibles.md)'s `Operations` model one scale up. There the caller lists which ops run and the sequence is fixed in source (`if ('pad-breaks' -in $ops)` blocks in declaration order), so array position never mattered. Here the caller lists which processors participate and the registry resolves order. Selection is the caller's, sequence is the implementation's, at both scales.

The resolution itself is two-level, where rs-whitespace has a single flat sequence:

- **Across families** — rank comes from `Spine`, which orders the families themselves; a member inherits its family's rank.
- **Within a family** — order binds only among members that *co-apply* to one file class, i.e. share a (stage, language) partition, and comes from an explicit `Rank`. `$strip` therefore has **no internal ordinality**: its members are partitioned by language and never co-exist in a chain. The question goes live the first time one language declares two members (a stripper plus a dedoc pass), at which point the loader refuses the registry until ranks are supplied. Fixed families have exactly one member and no within-family question at all.

`-Processors` forks into two explicit modes:

- **Set under canon** (default): the caller names participants; the compiler orders them by the spine. Array position is meaningless.
- **Verbatim** (`-RunVerbatim`): the literal sequence runs as written on every file — no family compiled, no routing, today's monolithic path. Cautions only. This preserves reposnapshot as an instrument for deliberately violating its own invariants without letting a plain call do it by accident; because routing is bypassed, a language-specific processor in a verbatim chain runs on every file regardless of class, which is exactly what was asked for.

Under the canon path, today's soft chain cautions become compiler guarantees and are no longer printed; under `-RunVerbatim` they remain as warnings.

### Classification

The registry is keyed on processor keys, so classification *is* the entry:

- Every processor has exactly one entry declaring its `Stage` — with `Language` qualification when that stage is a token. Declared is not enabled: an entry fixes position only; the stage runs when a caller enables it.
- **Routes are derived** — a language stripper is a `$strip`/`powershell` processor because its entry says so; the compiler assembles routes from entries, and no separate route table exists to fall out of sync.
- `configs/<key>.json` carries **no ordering metadata** — it stays pure config with its warn-and-default posture; classification lives in the registry, where hard-error validation and referential integrity already are (a stage or language rename cannot orphan classifications living in the same document).

Consequences:

- **Set-mode resolution**: naming a processor key enables its stage. For a routed stage this enables the token — routing still decides per file class, so `-Processors 'rs.ps.strip'` on a mixed corpus enables `$strip` wherever it resolves. `-StripComments` and naming a `Strip` member are the same operation spelled two ways.
- **Unregistered processor named under canon mode** → hard error stating both fixes: add a registry entry, or run `-RunVerbatim`. Deliberately harsher than rs-whitespace's unknown-op skip receipt — an unknown op has an obvious no-op fallback, an unplaceable processor does not, and running it at an arbitrary position would be worse than refusing.
- **Unreferenced processor *file* on disk** → inert, not an error — a WIP processor can land in `processors/` without breaking runs. Completeness for the shipped set (manifest ⊆ registry keys) is a repo test, not a runtime check.
- **Deferral is structural**: `processors/deferred/` sits outside the non-recursive manifest glob, so a parked processor (`tp-perplexity`, document-ingestion lineage) is invisible to manifest, registry, and completeness alike. Restoring the file to `processors/` is the re-activation gesture — plus a registry entry to run under canon.

## Echo

Tokens are the unit of report. Per-variant ConfigEcho must keep three stories distinguishable:

| Story | Echo |
|---|---|
| Routed and resolved | `$strip → rs.ps.strip` |
| Enabled but unresolved for this class | `$strip → ∅` (stripping was *on*; no resolver existed — e.g. TypeScript comments present for this reason, not because stripping was off) |
| Stage disabled for the run | stage absent from every variant |

Any manifest structure that tabulates per-step data across files keys by variant + processor key, never by position.

## Invariants

1. No component below plan compilation branches on file type. The compiler alone reads the registry; the colonel applies an opaque map; the executor iterates what it is given.
2. Stages self-establish preconditions (correctness layer); the spine orders the nominal path (quality layer). Neither substitutes for the other.
3. Variants are dense — splice, never tombstone.
4. Indices are variant-local cursors; cross-variant and cross-run identity is by processor key or stage token, never position. Chains of unequal length coexist in one run.
5. The shared plan family is immutable in workers.
6. The default variant always exists and equals the spine minus all holes.
7. Tokens exist only as data, never as PowerShell string literals.
8. Each stage's postcondition states which byte accounting survives it (`SpanBytes` vs `SizeBytes` — see [content-metrics.md](content-metrics.md)); wherever line-ending canonicalization lands, this is stated, not discovered.
9. Every processor is classified by its single registry entry — one stage, with language qualification when routed. `configs/` carries no ordering metadata; classification is structural.
10. All ordering is explicit data — family rank in `Spine`, member rank in `Rank`. The registry file's own arrangement carries no semantics: sorting or regrouping it must never change a compiled chain.

## Implementation Sequence

Each step lands with its tests through `tests/run-all.ps1` before the next begins. Steps 1–2 change no runtime behavior; existing monolithic calls keep working until step 3 wires the family through.

| Step | Work | Test gate |
|---|---|---|
| 1 | `processors/registry.json` (`Spine`/`Languages`/`Processors` sections; `$strip` members for powershell/csharp) + loader with normalization and hard-error validation | Malformed-file errors; extension normalization and one-language-per-extension; registry keys exist in manifest; stage/language cross-validation; rank required iff partition is multi-member; reordering the file changes no compiled chain |
| 2 | `Compile-Plan` emits the family (`Variants`/`Routing`/union `Iss`/union `ProcessorKeys`) | Pure-function tests: mixed extension set → expected variant tuples; dense chains of differing lengths; default variant present; spine invariants (measure last, strip precedes whitespace); validate-all vs bind-present; completeness (manifest ⊆ registry) |
| 3 | Colonel: third slice array, family marshal, worker lookup table | Index-stable envelope over mixed corpus; each item demonstrably ran its assigned chain (bag `Processing` trail) |
| 4 | Caller surface: `-StripComments` → `$strip`; `-Processors` set semantics (stage enablement); `-RunVerbatim` retaining today's monolithic path; unregistered-processor hard error; caution retirement on canon path | End-to-end heterogeneous ingest (`.ps1`/`.cs`/`.md`); `-RunVerbatim` runs a literal out-of-canon chain and still prints its cautions |
| 5 | Per-variant ConfigEcho with token resolutions | Echo assertions in the e2e test |
