# para-agent inspiration archaeology

**Status:** design companion; no implementation authorized | **Date:** 2026-08-10

**Sources:** cybernetic-copilot, vscodepilot, and hierarchical-memory snapshots

## Executive finding

The three old projects are useful as architectural lineage, not as code to port. They independently approached several boundaries that para-agent now expresses more cleanly:

- persistent console capture separated from model context;
- durable asynchronous work represented by handles and files;
- stable protocols separated from volatile client adapters;
- typed observations separated from policy decisions;
- scoped records separated from retrieval;
- compact capability guidance separated from implementation documentation.

They also reveal why those boundaries matter. The old implementations repeatedly blurred launch with completion, file visibility with model exposure, physical duplication with memory promotion, advisory detection with enforcement, and JSONL storage with database correctness.

The current four agent-facing layers should survive intact. “Garden” is an ingress pattern within the artifact plane, not a fifth subsystem. Durable knowledge promotion should remain an explicit reference-bearing boundary, not be smuggled into Console Journal or job events. Semantic supervision may observe any plane, while separately authorized governance may independently use that observation as evidence for its own intervention decision; advisory authority is never upgraded in place. Runtime components still enforce their schemas, authorization, leases, deadlines, cancellation, and resource bounds. The companion [`context-mode-cross-examination.md`](context-mode-cross-examination.md) further separates the Guidance layer from cross-cutting Harness Adapters and an out-of-band privileged Control Plane.

## Method and source map

The snapshot tree manifests were treated as indexes and their byte ranges were used to select relevant virtual files. Supplementary vscodepilot Markdown was inspected for the later architectural interpretation of that code.

- [cybernetic-copilot tree](../../../project-snapshots/cybernetic-copilot/cybernetics_20260421_001818_tree.md)
- [vscodepilot tree](../../../project-snapshots/vscodepilot/src_20260423_121624_tree.md), [architecture](../../../project-snapshots/vscodepilot/ARCHITECTURE.md), [salvage matrix](../../../project-snapshots/vscodepilot/SALVAGE-MATRIX.md), [garden design](../../../project-snapshots/vscodepilot/majestic-garden.md), and [digest](../../../project-snapshots/vscodepilot/DIGEST.md)
- [hierarchical-memory tree](../../../project-snapshots/hierarchical-memory/hierarchical-memory_20260421_001801_tree.md)

The code predates para-agent and is incomplete in places. It is evidence of recurring design pressure, not evidence that an implementation is production-safe.

## Cross-project disposition

| Historical concept | Current judgment | Architectural home |
|---|---|---|
| Persistent terminal plus correlated command/output records | Already integrated and materially improved | Console plane |
| File-backed async jobs, signals, results, cancellation, and rehydration | Adapt as an append-only typed job protocol | Job-exchange plane |
| Format-based producer contracts | Keep as a governing doctrine | Every provider boundary |
| “Garden” of envelopes retrieved by consumers | Adapt as context ingress, never direct prompt injection | Artifact plane |
| Session/sequence/project/global memory scopes | Adapt as context dimensions and retention/promotion policies | Artifact and future knowledge boundary |
| Typed observations and loop/drift detectors | Adapt only as evidence-bearing advisory events | Optional observer across planes |
| Recipes, examples, and capability hints | Adapt as retrievable, typed teaching resources | Guidance layer |
| Client-specific primer or metacognitive monologue | Retire | Replaced by small skill, receipts, and sparse JIT guidance |
| Central “supervisor” object | Retire as an abstraction; admit a coordinator only when it owns real runtime duties | Runtime implementation detail |
| JSONL read-modify-rewrite without leases | Retire | Append-only truth plus disposable projections |
| File stability, silence, or timeout as terminal job truth | Retire | Authoritative lifecycle-owner events |
| Probabilistic stream-dedup hints | Implement deliberately through the Node-native Hashish port, but keep only for candidate nomination; prohibit equality, freshness, or exposure authority | Derived Artifact projection |

## Cybernetic-copilot

### What has already arrived in para-agent

`CyberneticConsole.psm1` gives the current PowerShell process a session identity, `Start-Transcript` capture, and selective readers for presumed `session + seq + cmd/out` dump records. It neither provides detached persistence across client processes nor writes that dump format end to end. The lineage is session identity, transcript capture, correlation, and selective reading; para-agent realizes those ideas more completely through psmux panes, journal turns, sentinels, receipts, sidecar bodies, and a producer-neutral contract. See [shard s003](../../../project-snapshots/cybernetic-copilot/cybernetics_20260421_001818_s003.txt), bytes `[204,27999)`.

`CopilotObservation.psm1` derives bounded typed observations containing a type, timestamp, hash, summary, metadata, and rough size estimate. This remains a useful view shape if the full source artifact stays authoritative and every view carries completeness, omissions, and its source reference. Hashing a whitespace-compressed or truncated summary cannot establish source identity. See [shard s001](../../../project-snapshots/cybernetic-copilot/cybernetics_20260421_001818_s001.txt), bytes `[6528,17168)`.

### What is worth adapting

- `CyberneticAutomata.psm1` supplies the ancestor of a file-backed job exchange: stable job IDs, status, result/signal/cancel paths, timeout, retention, and cleanup. Replace mutable job snapshots and transport heuristics with typed append-only events, causal links, cursor waits, leases, and artifact references. Terminal truth comes from the executor or an authoritative runtime coordinator. See [shard s002](../../../project-snapshots/cybernetic-copilot/cybernetics_20260421_001818_s002.txt), bytes `[205,19677)`.
- Its `ExpectedArtifacts` idea should become typed requested outputs or postconditions. A receipt must distinguish “produced,” “verified,” and “accepted”; path existence alone proves none of them.
- Session, sequence, project, and global are useful vocabulary for applicability and promotion. They should not become new Console Journal kinds or mutually exclusive storage buckets.
- The supervision modules suggest an optional observer contract. A signal should name its rule, observation window, evidence references, confidence, and proposed action. When it is causally job-scoped, it can enter that job as a `finding`, `objection`, or `decision_request`; otherwise it remains a scoped diagnostic/artifact or uses a future advisory stream.
- The old context composition code suggests an explicit `context_pack` recipe: materialize selected references under a declared aggregate budget and return provenance plus omissions. It must never become eager standing injection.

The strongest new design extrapolation motivated by this snapshot is **guidance observability**. The old system inventories some instruction files, sizes, modules, and environment state; it does not establish what entered model context. A modern diagnostic can expose adapter-visible guidance candidates so Claude overhead can be measured and possible conflicts can be nominated for controlled testing.

### What should remain retired

- Regex inspection of serialized tool arguments accompanied by large universal mandates. Preserve only the typed `{code, severity, evidence, alternative}` shape from `CopilotContextManagement.psm1`; discard the brittle policy and repeated prose. See [shard s001](../../../project-snapshots/cybernetic-copilot/cybernetics_20260421_001818_s001.txt), bytes `[346,6458)`.
- Hard-coded “similarity,” “circularity,” and “drift” thresholds whose proxies do not establish the semantic claim. Advisory heuristics must describe what was actually observed.
- Artifact existence as proof of successful execution.
- File quiescence, watcher timeout, or cancellation-file creation as proof of a terminal state.
- Keyword searches such as `ERROR` over arbitrary stdout as authoritative error semantics.
- Global mutable state coupling console, memory, feedback, hooks, and supervision.
- Pretty multi-line JSON appended to a file whose readers assume one JSON object per line.

## vscodepilot

### What has already arrived in para-agent

The old `safe-shell.ts` established the essential move: dispatch interactive terminal work without blocking the caller, then read durable JSONL records. para-agent supersedes its guessed “recent command” correlation and fixed sleep instructions with turns, sentinels, receipts, and cursor-aware retrieval. See [shard s012](../../../project-snapshots/vscodepilot/src_20260423_121624_s012.txt), bytes `[207,14797)`.

The later architecture documents make two durable distinctions:

1. direct invocation creates a vendor dependency, while a documented format allows an external producer; and
2. a runtime “supervisor” for jobs is not semantic supervision or policy merely because the words sound related.

Those distinctions directly support a producer-neutral Console Journal and the current console/artifact/job/guidance split.

### What is worth adapting

- `job-store.ts` and `parallel-tools.ts` show the needed surface—job identity, rehydration, result and signal artifacts, waiting, and cancellation—but should be recast as typed durable events. See [shard s007](../../../project-snapshots/vscodepilot/src_20260423_121624_s007.txt), bytes `[9824,20657)`, and [shard s010](../../../project-snapshots/vscodepilot/src_20260423_121624_s010.txt), bytes `[211,30539)`.
- The JSON-RPC host/worker topology remains reasonable if a coordinator eventually owns several real responsibilities: psmux lifecycle, single-writer sequencing, job state, filesystem watches, and atomic hook projections. A daemon solely for wake-up is still unjustified.
- The “garden” should become the federation seam: producers publish typed envelopes and references; consumers retrieve them deliberately; adapters do not inject source material straight into model state. Transport may be a named pipe, filesystem, or MCP call without changing the semantic contract.
- `recipe-types.ts` is a useful ancestor for typed, searchable, composable recipes with examples and usage evidence. See [shard s011](../../../project-snapshots/vscodepilot/src_20260423_121624_s011.txt), bytes `[18295,22504)`. Recipes should describe typed operations and preconditions, not interpolate parameters into executable shell templates.
- The thin-adapter rule is especially important for Claude hooks: the stable core and volatile client adapter both depend on the protocol; the adapter contains no domain policy.

### What should remain retired

- A fixed “sleep 1–2 seconds” workflow and recent-record guessing.
- Whole-file JSONL reads or rewrites, swallowed parse failures, and deletion of evidence on first read.
- `cancelled` set when a cancellation request is merely written.
- Result-file age as completion and missing sidecar state as orphan proof.
- The old supervisor implementation, whose initialization, spawn, stdout framing, and launcher contracts conflict internally.
- Primer/handshake injection as ordinary participant Markdown. It is neither dependable system guidance nor economical context.
- Treat Bloom filters, rolling hashes, and fuzzy signatures as useful Node-native projections, but only for negative acceleration, anchors, chunking, or candidate nomination according to their exact contracts. Do not extend them into equality, freshness, retrieval suppression, or exposure authority. The concrete port boundary is specified in [`node-hashish-port-design.md`](node-hashish-port-design.md).

## Hierarchical-memory

### What the snapshot actually is

The project is not yet a hierarchical memory system. It is a scoped append-only event-log router: records receive one of four scope tags, a broad type, contextual metadata, and a destination filename. There is no parent relation, inheritance, retrieval widening, promotion graph, semantic/relevance ranking, decay, deduplication, or exposure accounting; retrieval does sort reverse-chronologically. See `MemorySystem.ps1` in [shard s001](../../../project-snapshots/hierarchical-memory/hierarchical-memory_20260421_001801_s001.txt), bytes `[336,11038)`.

This is still useful because it makes four concepts possible to separate:

1. **Context:** where an occurrence applies.
2. **Retention:** how long its canonical body remains addressable.
3. **Promotion:** a deliberate decision to make referenced evidence available to a broader or longer-lived collection.
4. **Delivery:** which bytes were actually admitted to a particular client context and epoch.

The old exclusive `scope` field blurred context with physical storage. Its `Aggregate` flag copied the same JSON into another file, confusing publication with duplication. Neither operation says anything about model exposure.

### What is worth adapting

- Keep stable typed envelopes with namespaced extension payloads, but do not create a universal event enum spanning console, artifacts, jobs, guidance, and knowledge.
- Replace one exclusive scope with simultaneous context dimensions such as `project_id`, `session_id`, `epoch_id`, `job_id`, `parent_job_id`, and `actor_id`.
- Make retrieval widening explicit. A caller can begin in a job or session context and deliberately widen to project or shared collections.
- Preserve one canonical occurrence by default. Promotion creates an edge and records who promoted it, why, the stable destination collection, the guarded source, the retention effect, and stale/missing behavior. An explicit snapshot may create a new immutable derived occurrence with provenance.
- Keep batching, health/status, explicit flush, and retention as lifecycle concerns, but replace the old writer and smoke test.

The snapshot reader is not salvageable: it scans files, silently drops malformed records, has no cursor or completeness proof, and fails to apply its time cutoff consistently. The background writer lacks a reliable cross-runspace queue and cross-writer lease. The test deletes current-day files in a shared user directory and should not be revived. Its code appears in [shard s001](../../../project-snapshots/hierarchical-memory/hierarchical-memory_20260421_001801_s001.txt), bytes `[11104,14480)`.

## Refined architecture

The archaeology does not require another agent-facing para-agent plane. It sharpens the existing boundaries; client adapters cross them rather than belonging inside the Guidance layer, and privileged administration stays outside the runtime:

```text
console producers ── Console Journal provider ─────────────┐
file/Markdown/JSONL provider adapters ─────────────────────┼─> artifact refs + receipts
job actors ── Job Exchange (events + derived state)                      │
                    └─ evidence/report references ─────────┘             ├─> materialization + delivery
                                                                        └─> optional promotion

client capability profile + skill + recipes select typed operations across planes
client harness adapters normalize and lower native events at every client edge
optional observers read evidence and emit scoped advice
authorized governance may independently evaluate observations and intervene under its own rules
runtime components independently enforce contract mechanics and resource bounds
out-of-band control adapters compile, deploy, validate, and roll back native client projections
```

The smallest reusable semantic kernel is:

| Concept | Meaning |
|---|---|
| Occurrence | A provider or actor produced a record, event, or body. |
| Reference | Stable identity, provider-native coordinates, and a freshness guard for that occurrence. |
| Materialization | A caller selected bounded bytes from a guarded reference. |
| Delivery | Those bytes entered one identified consumer context and epoch. |
| Promotion | An actor linked the reference into a broader or longer-lived collection. |
| Observation | An observer derived an evidence-bearing but potentially fallible claim. |

An envelope is therefore not model context merely because it exists. A promotion is not a delivery, a delivery is not semantic understanding, and an observation is not governance authority. These distinctions allow new providers and workflows without weakening correctness.

### Job truth

Only an event from the executor or an authoritative runtime coordinator may establish `completed`, `failed`, `cancelled`, or `timed_out`. That authority requires a bound writer role, job generation or lease identity, and fencing against stale executors. A coordinator can classify a verified process death or execution deadline under those rules; an incidental observer cannot. Other facts retain their narrower names:

| Observation | Honest interpretation |
|---|---|
| Cancellation marker written | `cancellation_requested` |
| Watch timed out | `observer_timeout` |
| Result file unchanged | `quiescent` |
| Process cannot be found | `producer_unreachable` |
| Output path exists | `artifact_observed` |
| Postcondition passed against guarded output | `verified` |
| Authoritative execution deadline reached | terminal `timed_out` |

For incremental reads across multiple job writers, causal links are not a cursor. `job_wait` needs either a coordinator-assigned ingestion cursor or a vector cursor mapping each writer to its last seen sequence.

Completion, verification, and acceptance are separate transitions. A consumer may accept an unverified result, reject a completed result, or verify an artifact after the producing process exits.

### Promotion by reference

Promotion is deliberately outside Console Journal v1. A future artifact or knowledge extension can use a record such as:

```json
{
  "promotion_id": "opaque",
  "source": {
    "provider": "provider-id",
    "artifact_id": "provider-stable-id",
    "guard": "provider-defined"
  },
  "from_context": {},
  "destination": { "collection_id": "project:stable-id" },
  "promoted_by": "actor",
  "reason": "reusable verified finding",
  "retention": { "effect": "none|pin_until|snapshot", "until": null },
  "on_source_unavailable": "mark_stale|mark_missing|use_snapshot",
  "time": "RFC3339",
  "supersedes": null
}
```

With `none` or `pin_until`, promotion refers to canonical evidence rather than copying its body; a guard detects change but does not preserve the source. `snapshot` deliberately creates a new immutable occurrence that points back to its provenance. Promotion does not imply retention forever, semantic truth, or delivery into any current model context. Confidence in a claim belongs to its finding or assessment record, not to the promotion edge.

### Guidance as a measurable signal chain

The guidance layer needs both a teaching interface and an observability interface.

The teaching interface should contain:

- a tiny resident intent-to-capability map;
- on-demand recipes with typed parameters, preconditions, expected receipts, tradeoffs, and primitive escape hatches;
- exact schema-valid continuations in receipts and errors;
- sparse capability-aware hook correction;
- detailed implementation material only when explicitly retrieved.

Recipe use may be measured, but frequency must not automatically turn an observed sequence into policy or resident guidance. Promotion into the skill or paved-path surface is a reviewed design decision.

A bounded `guidance_explain` or doctor-style receipt could report metadata and references, not source bodies:

```json
{
  "client": "claude|codex|other",
  "profile": "profile-id",
  "epoch": "known-or-unknown",
  "guidance_sources": [
    {
      "kind": "instruction|skill|tool_schema|hook",
      "id": "stable-source-id",
      "scope": "client-defined",
      "hash": "content-identity-only",
      "bytes": { "value": null, "basis": "measured|provider_reported|estimated|unknown" },
      "injection": "resident|on_demand|jit|unknown",
      "configured": true,
      "adapter_observed": true,
      "provider_reported": null,
      "model_admission": "unknown"
    }
  ],
  "context_contributors": [
    { "kind": "history|tool_result", "bytes": { "value": null, "basis": "unknown" } }
  ],
  "capabilities": {},
  "totals": {
    "adapter_observed_bytes": { "value": null, "basis": "unknown" },
    "tool_schema_bytes": { "value": null, "basis": "unknown" },
    "jit_bytes": { "value": null, "basis": "unknown" }
  },
  "counts": {},
  "complete": false,
  "omitted": [{ "kind": "provider_hidden", "reason": "not_observable" }],
  "guard": "inventory-snapshot-guard",
  "continuations": [],
  "unknowns": ["provider-hidden serialization"]
}
```

This should normally be a deferred resource, CLI diagnostic, or existing diagnostic mode. Adding an eagerly exposed MCP tool solely to measure tool overhead would be self-defeating. The diagnostic must not claim access to hidden provider serialization: bytes are not tokens, a content hash proves only content identity, and an adapter-visible inventory may omit system material. Context occupancy also grants no instruction authority; history, garden artifacts, and tool results remain data unless an explicit trust contract says otherwise. Controlled A/B usage measurements remain the authority for the Claude overhead investigation.

### Optional observer contract

A detector should emit what it can prove rather than naming a speculative mental state:

```json
{
  "observer": "observer-id",
  "rule": "rule-id-and-version",
  "window": {},
  "observation": "three writes targeted the same guarded file",
  "evidence": [],
  "severity": "info|warning|critical",
  "confidence": 0.0,
  "recommendation": {},
  "enforcement": "advisory"
}
```

Job-scoped observers can generate findings, objections, or decision requests in that job. Other observations remain scoped diagnostics/artifacts or use a future advisory stream; the architecture should not invent a job merely to carry them. An observer cannot turn advice into intervention. Separately authorized governance may consume the observation as evidence and reach a new decision under its own rule and authority. Runtime components may still halt work under independent contract mechanics such as cancellation, deadlines, authorization, or resource bounds.

## Design decisions now clarified

1. Keep the four agent-facing layers; treat ingress, promotion, and observation as functions, Harness Adapters as cross-cutting boundaries, and privileged administration as an out-of-band control plane.
2. Use multi-dimensional context, not one exclusive memory scope.
3. Separate occurrence identity, content equality, semantic similarity, prior delivery, retention, and promotion.
4. Require authoritative lifecycle-owner terminal job state—executor or coordinator under a verified lease—and model incidental observer knowledge honestly.
5. Make recipes typed, retrievable, and non-executable by interpolation.
6. Make guidance sources and client capability assumptions inspectable, with explicit uncertainty.
7. Preserve primitive operations and handles beneath every paved path.
8. Do not revive legacy implementations without new contract tests; their value is in the boundary lessons.

## Suggested next design artifacts

The archaeology modestly extends the existing sequence:

1. Console v1 conformance errata.
2. Artifact reference and receipt contract, including deliberate context packing.
3. Job exchange contract, including honest lifecycle observations and requested-output verification.
4. Harness routing and granular client-capability contract.
5. Guidance-observability profile and one semantic guidance source.
6. A minimal skill outline plus two or three typed recipe resources.

Memory promotion should remain a reserved extension until a concrete consumer and retention policy exist.
