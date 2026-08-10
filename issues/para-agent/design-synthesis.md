# para-agent: design synthesis and next architecture

**Status:** design report; no implementation authorized | **Date:** 2026-08-10
**Scope:** para-agent, its prospective shared artifact substrate, the driver↔para exchange, and agent-facing guidance

## Executive conclusion

para-agent should remain a dependable console and process substrate. It should not absorb context policy, semantic supervision, exposure accounting, and agent collaboration into the Console Journal contract merely because all of them can be represented as JSONL.

The next useful shape has four distinct layers:

1. **Console plane:** panes, commands, output capture, lifecycle, and Console Journal records.
2. **Artifact plane:** common references, receipts, selective materialization, freshness guards, and delivery accounting across console output, files, Markdown, and JSONL.
3. **Job-exchange plane:** typed delegation, waiting, report-back, questions, objections, evidence, and completion.
4. **Guidance layer:** a small platform-agnostic capability map, retrievable typed recipes, and sparse client-specific hook guidance.

Client adapters are not part of that fourth layer. They are cross-cutting boundary compilers that normalize native events, prove identity and effect capabilities, and format native responses. Privileged cross-client deployment is a separate out-of-band control plane, not a fifth agent-facing plane.

Beneath Console, Artifact, and Job, para-agent also needs an internal capability substrate: an in-process application facade over engines for capture, storage, serialization, querying, projections, receipts, and lifecycle. That is implementation architecture, not a fifth model-visible layer and not a new family of primitive MCP tools.

The common path should be short and economical, but the primitive console surface must remain available. The system should offer paved paths rather than a mandatory workflow language.

## Evidence and provenance

This synthesis builds on:

- the assignment and established findings in [`claude-agy-codesign-brief.md`](../../mcp/issues/para-agent/claude-agy-codesign-brief.md);
- the completed para-agent design review at `C:\Users\azrie\.para-agent\journals\streams\agent-agy\turns\000003.out`;
- the subsequent source-verification critique in `C:\Users\azrie\.claude\projects\D--aghado01\d4607405-dfd4-47b3-a156-3451c7e07c2a.jsonl`;
- a direct audit of [`src/`](../../mcp/para-agent/src), [`CONSOLE-CONTRACT.md`](../../mcp/para-agent/contract/CONSOLE-CONTRACT.md), [`ParaConsole.psm1`](../../mcp/para-agent/capture/ParaConsole.psm1), and the relevant rector-codicis design documents;
- the selective old-project archaeology and disposition analysis in [`project-archaeology.md`](project-archaeology.md).
- the upstream and locally customized context-mode cross-examination in [`context-mode-cross-examination.md`](context-mode-cross-examination.md).
- the engine/client boundary analysis in [`backend-engine-architecture.md`](backend-engine-architecture.md).
- the direct Node port analysis for ThermoMapper Hashish, jso-jackson, and cybernetic-copilot in [`node-hashish-port-design.md`](node-hashish-port-design.md).
- the algorithm-by-algorithm conceptual and application map in [`hashish-capability-inventory.md`](hashish-capability-inventory.md).

The default `agy` journal contains failed login attempts rather than another completed report, so it was not treated as substantive design evidence.

## Archaeology addendum

The cybernetic-copilot, vscodepilot, hierarchical-memory, and context-mode lineages reinforce the four agent-facing layers, but their implementations should not be revived wholesale. Their strongest shared lesson is to preserve stable format contracts while separating runtime control, artifact ingress, policy observation, durable knowledge promotion, guidance, volatile client adapters, and privileged administration.

The archaeology also sharpens four rules:

- an executor- or authoritative-coordinator-authored terminal event, not file age, watcher timeout, or cancellation request, establishes terminal job state;
- context, retention, promotion, and delivery are distinct facts;
- “garden” is deliberate artifact ingress, not direct prompt injection or a new umbrella subsystem;
- guidance needs an inspectable signal chain so adapter-visible sources can be inventoried, candidate conflicts nominated, and client overhead tested rather than guessed.

Context-mode adds three sharper constraints:

- capture, derivation, indexing, memory, and guidance require distinct semantics even when one high-level call composes them;
- client capabilities are facts about a version, mode, event, native tool, field, and effect—not booleans such as `supportsModify`;
- every applicable enforcement policy must run before optimization guidance, and decision authority must never be recovered by regexing prose.

## The Claude-harness confound

The current measurements are important but not universal laws of the architecture.

The observed Claude harness carried a roughly 52,477-token baseline on every model turn. The audit therefore found turn serialization to be the dominant avoidable cost: small solo tool calls paid the same large prompt rent as productive reasoning turns. The design-review round itself produced an 8.1 KB report after nine agent turns and reported a cost of about $1.02.

Those facts justify minimizing model round trips in the current environment. They do **not** justify hard-coding 52K-token economics, Claude hook behavior, or a universal inline threshold into para-agent. The overhead may include:

- harness system material and client-specific injection;
- eager or deferred MCP tool definitions;
- skill listings and standing instructions;
- agent listings;
- conversation history and tool-result residency;
- cache accounting peculiarities;
- headless versus interactive behavior;
- client-version-specific hook behavior.

The architecture should therefore consume an observed **client capability/economics profile**, while its correctness contracts remain client-independent. Round-trip removal is the primary optimization under the current profile; prevention of resident payload is still valuable because it improves later turns and context signal-to-noise.

A local `tools/list` measurement found that para-agent's 13 current tool definitions serialize to 15,739 UTF-8 bytes: 6,601 characters of descriptions and 7,372 characters of schemas. Consolidating tools is useful only if it reduces the serialized surface and misuse rate, not merely the visible tool count.

## Findings that survive scrutiny

### 1. Turn count is the first economic variable

The most useful additions are operations that collapse a known multi-call sequence into one model turn:

- a batch of commands known in advance;
- command execution plus caller-selected evidence;
- search plus bounded materialization;
- delegation plus launch, wait, capture, and final report;
- a cursor wait returning only new typed job events.

An outline that must always be fetched before a body is not progressive disclosure under this cost model; it is an extra 52K-token decision point. Progressive disclosure must be available **within one call** when the caller already knows the desired selector.

### 2. Receipt-first capture is the right substrate

The current `run → log/find → body` path already demonstrates the core pattern: durable body, small receipt, selective follow-up, and explicit omission. This converges with mdnav, doccer, and the JSONL work for good reason.

The generalization is not a universal semantic outline. It is a common three-face protocol:

- **receipt:** identity, size, status, and references;
- **description:** only structure declared or mechanically established by the provider;
- **materialization:** exact provider-native selectors, preferably batched.

Markdown can expose headings. JSONL can expose records and fields. Console text can expose lines, byte ranges, tail, channels, regex hits, or a producer-declared JSON/test format. Arbitrary stdout should not receive invented hierarchy.

### 3. Stateful hook decisions need a bounded projection

The context-mode decision plane is blind because its PreToolUse process cannot safely load the capture database. para-agent's plain files show that a stateless hook can read useful state cheaply, but the hook should not scan a growing journal or infer liveness from a directory.

Publish a small, atomically replaced, writer-leased projection containing only decision facts such as:

- current client/session/epoch identity or `unknown`;
- live pane and job handles;
- recent exact operation fingerprints with freshness evidence;
- turn and delivery counters;
- throttled-guidance markers;
- safe wrapper availability and tested hook capabilities.

The append-only ledgers remain the audit truth. The projection is disposable derived state.

### 4. Typed MCP inputs are the reliable routing surface

`PreToolUse.updatedInput` modifies the input to the same tool; it cannot turn a native `Bash` call into `mcp__para-agent__run`. The local context-mode adapter also records Claude Code 2.1.x ignoring Bash `updatedInput.command` and converting the attempted redirect into a denial (`packages/context-mode/hooks/formatters/claude-code.mjs:57-100`).

Receipt inversion therefore has two viable forms:

1. the agent selects a typed MCP operation before emitting the verbose native call; or
2. a proven same-tool wrapper/CLI executes or forwards the original command and prints only a receipt.

The second form must be tested against the installed client and must declare semantic differences involving cwd, environment, signals, shell state, and the selected persistent pane. Denial is not a token-policy fallback: it spends another model turn.

## Correctness gate for Console Journal v1

The current implementation is a strong prototype, but the contract is not yet a safe foundation for more planes.

Required repairs or explicit contract changes include:

- **Writer serialization:** `_seq` is process-local and incremented before an unlocked append (`src/journal.js:44,72-80`). Add a per-stream serialized append path and a cross-process writer lease or single writer.
- **Sidecar identity:** the implementation keys sidecars by `turn`, while the contract says `seq`. `turn` is the natural command-correlation identifier; amend the contract unless v1 compatibility has already become external.
- **Lifecycle truth:** a detected dead pane currently yields a note and no `exit(outcome:"died")` (`src/capture.js:255-268`), erasing the distinction the contract explicitly promises.
- **Cancellation truth:** the consumer can write `.cancel`, but captured commands do not poll it. Implement producer cooperation or retract the promise.
- **No silent omission:** missing output files become empty output, missing referenced bodies become empty reads, malformed journal records can fall below the public cursor, exhausted inbox retries return silently, and abandoned `.claim` files are not recovered.
- **Executable continuations:** receipts name internal operations such as `read(...)` and `search(...)`, while public tools are `log` and `find`. Continuations should be structured `{tool, input, covers}` objects and schema-valid.
- **Selection correctness:** `body(grep)` advertises `offsetLines` pagination but ignores the offset in its grep branch. Nonmatches should not make a query incomplete; completeness is relative to the requested selection.
- **Regex safety:** free-form `g` or `y` flags make reused JavaScript `RegExp.test()` stateful and silently skip matches.
- **Fidelity claim:** PowerShell output is rendered through `Out-String -Stream`, decoded as UTF-8, and line selections are rejoined. This is useful rendered text, not arbitrary byte-exact process output. Either narrow the claim or add a distinct raw-byte artifact path.
- **Reproducibility:** the README records historical passing counts, but the repository currently has no para-agent test script or committed automated tests.

`exec(keepJournal:false)` also needs a coherent retention rule. It warns that a large result is unreachable while leaving its files on disk. Externalized output should remain addressable under an explicit TTL; pane lifecycle and artifact retention are separate decisions.

## Proposed contracts

### Artifact reference

Historical version graphs are not required. Current state remains authoritative, while a guard prevents a selector from silently resolving against changed material.

```json
{
  "provider": "console|markdown|jsonl|file|job",
  "artifact_id": "provider-stable identity",
  "guard": "current material or topology guard",
  "basis": "provider-defined coordinate system",
  "selector": {}
}
```

Identity, coordinate compatibility, and provenance must remain separate. For large mutable artifacts, CDC chunk identifiers may preserve unchanged regions across occurrences without retaining a version history.

Artifact guards use complete cryptographic digests over exact bytes. The current eight-hex `cmd_hash` and `out_hash` fields are convenient display/correlation prefixes, not equality or suppression authorities. Rolling hashes choose anchors or chunk boundaries; profile-compatible signatures nominate similar candidates, with model identity required where applicable; exact verification resolves the candidate.

### Receipt

```json
{
  "status": "complete|partial|running|stale|missing|failed",
  "reference": {},
  "counts": {},
  "bytes": { "source": 0, "returned": 0 },
  "complete": true,
  "omitted": [],
  "continuations": []
}
```

`complete` means that nothing matching the requested selection was omitted. Deferred source material, nonmatching content, and query omissions are separate facts.

### Delivery record

The exposure ledger records bytes actually delivered into a particular client context, not what the model understood:

```json
{
  "consumer": "client/session",
  "epoch": "known epoch or unknown",
  "reference": {},
  "chunks": [],
  "bytes": 0,
  "source_call": {}
}
```

Unknown epoch must fail open: do not suppress material merely because it may have been delivered before. Explicit materialization requests should normally be honored; novelty filtering is a requested policy, never silent behavior.

### Job exchange

The versioned job contract must distinguish requests, emitted events, derived states, and incidental observations rather than collapsing them into one enum:

| Vocabulary | Candidate values |
|---|---|
| Requests | `dispatch`, `answer`, `decide`, `cancel` |
| Events | `accepted`, `started`, `progress`, `finding`, `objection`, `question`, `decision_request`, `cancellation_acknowledged`, `completed`, `failed`, `cancelled`, `timed_out` |
| Derived states | `pending`, `running`, `needs_input`, `cancellation_requested`, `completed`, `failed`, `cancelled`, `timed_out`, `unreachable` |
| Observer facts | `observer_timeout`, `quiescent`, `producer_unreachable`, `artifact_observed` |

Every event needs job, actor/writer, bound writer role, job generation or lease identity, per-writer sequence, causation, evidence, budget, and report references as applicable. Terminal writers must be fenced so a stale executor cannot complete a newer job generation. An authoritative execution deadline can yield terminal `timed_out`; an incidental watcher timeout remains only `observer_timeout`.

Causal links and per-writer sequence define semantic ordering, but they do not create one cross-writer polling cursor. A multi-writer `job_wait` must use either a coordinator-assigned ingestion cursor or a vector cursor `{writer: seq}`. A globally meaningful total event order is unnecessary unless a real consumer requires it; if it does, one coordinator must assign it.

## Backend capability substrate

The Codex-Scientiae `jsonl_engine` comparison clarifies the implementation boundary. Its Python package owns store semantics; its PowerShell client hides runtime, process, protocol, and value-conversion impedance; its public cmdlets provide ergonomic calls. In para-agent's single Node runtime, the subprocess and CLI protocol should disappear, but the semantic boundary should remain:

```text
MCP handler → ParaApplication facade → Console / Artifact / Job engines
                                      → JSONL, selector, digest, and Hashish capabilities
                                      → mux and storage adapters
```

One MCP call should cross that boundary once per agent intent. The backend can then perform record-wise framing, capture, locking, sequencing, hashing, projection, publication, and cleanup without extra model turns. The agent chooses the task, target, requested evidence, and material lifecycle; it does not choose scratch paths, sidecars, sentinels, polling mechanics, serialization profiles, or hash primitives.

MCP handlers should be nearly declarative: validate a public request, call one application method, and present its neutral result. The application facade owns operation identity, deadline/cancellation, response budget, retention, composition, typed partial outcomes, and receipt assembly. Engines provide measured facts and source guards. Stores do not know tool names or emit continuation prose; the MCP presenter maps a neutral continuation to the exact exposed `{tool, input}` pair.

Hashish and jso-jackson-derived functionality live below the Artifact query/projection engine. A module, algorithm, or internal CLI verb becomes a public tool only when it represents a distinct agent decision, effect/permission boundary, and result contract. The full responsibility map, current `index.js` pressure points, and design-only migration sequence are in [`backend-engine-architecture.md`](backend-engine-architecture.md).

## Agent-facing guidance as an explicit layer

The current system has tool descriptions and inherited habits, but no deliberate teaching surface connecting capabilities into efficient workflows. That layer should be designed rather than allowed to accrete.

### Separation of responsibilities

| Layer | Responsibility |
|---|---|
| Tool schema | What can be called; exact typed decision surface and safe defaults. |
| Tool description | When this tool is appropriate; one compact standing brief. |
| Skill | How capabilities compose into efficient, open-ended workflows. |
| Receipt/error | What happened and the exact typed continuations available now. |
| JIT hook guidance | Sparse client-specific correction when a cheaper path is known. |
| Harness adapter | Normalize native events, retain native evidence, bind identity only when proven, check exact effect support, and format the response. |
| Runtime contract | Schema, authorization, leases, cancellation, deadlines, and resource bounds. |
| Governance | Independently evaluates observations under its own authority and may intervene; it does not upgrade an advisory decision into an enforcement decision. |
| Administrative control | Build, deploy, validate, and roll back one explicit client target outside the model-visible data plane. |

The skill should not repeat schemas or long reference material already paid elsewhere. Its core can be a short intent router:

- persistent stateful shell work → session + batched run;
- agent delegation → typed job operation with a brief reference;
- large output investigation → capture-time selector or find with bounded hit materialization;
- interactive/TUI work → send plus cursor wait, with screen heuristics clearly marked;
- exact evidence needed → explicit materialization;
- unusual workflow → drop to primitives.

Recipes should teach high-value compositions, not prescribe one pipeline. Each paved path must expose the underlying handles, artifact references, receipts, and primitive escape hatch. This preserves agent initiative and makes novel workflows possible without forfeiting economy.

Guidance itself must follow progressive disclosure:

1. a small capability map resident in the skill;
2. concise recipes selected by intent;
3. retrievable detailed references and client-specific limitations;
4. implementation documentation only on demand.

Recipes should be retrievable typed data rather than interpolated executable templates. A recipe can declare intent, parameters, preconditions, expected receipts, tradeoffs, and primitive escape hatches. Usage evidence may nominate a recipe for review, but frequency alone must never promote it into resident guidance or policy.

The same layer should expose a bounded `guidance_explain` or doctor-style receipt. It should list adapter-visible guidance sources—such as instructions, skills, tool schemas, and hooks—and separately summarize broader context contributors such as history and tool results. Values need nullable coverage and measurement basis so unknown never masquerades as zero; configured, adapter-observed, provider-reported, and actual model admission are different claims. Prefer a deferred resource, CLI diagnostic, or existing diagnostic surface; an eagerly exposed MCP tool would add to the overhead being measured. The receipt must enumerate unknowns: observed bytes are not provider tokens, and a client adapter may not see hidden system serialization. Controlled usage measurements remain authoritative for the Claude-harness confound.

Repeated JIT prose should become a terse code plus a retrievable resource. Guidance can fire once per epoch and periodically after long sessions or compaction. A client capability manifest should state facts such as support for same-tool input modification, context epoch hooks, long-running calls, notifications, parallel tool calls, and headless behavior. Each claim needs client version, mode, event, native tool, field, `supported|unsupported|unknown`, evidence, and last verification where applicable. The platform-agnostic skill consumes those facts rather than naming Claude behavior as universal.

Tool exposure and discovery remain separate from guidance and routing. A hook cannot generally make an unlisted MCP schema callable; a host-specific discovery operation may cost another turn. Guidance must therefore account for whether a capability is visible and ready to the current actor, including fixed-tool subagents.

## Node-native Hashish as a derived projection library

The intended integration is a deliberate Node port of the canonical [`ThermoMapper/src/hashish`](../../../ThermoMapper/src/hashish) source, not a PowerShell/.NET bridge and not an ad hoc generic SimHash. The algorithms should live in a pure internal ESM capability library beneath the Artifact query/projection engine. They do not define a public operation catalog; an agent-level query or comparison may use them internally and disclose the relevant profile/model provenance in its receipt.

Keep the result classes distinct:

- streaming SHA-256 cryptographically identifies and guards exact captured bytes;
- Jaccard and Levenshtein exactly compare one declared representation;
- SimHash and MinHash nominate candidates under compatible preprocessing profiles; a fitted model ID is additionally required only for model-based signatures such as fitted SimHash;
- Bloom accelerates negative membership and requires exact verification of positives;
- Count-Min and HyperLogLog produce estimates, never receipt counts;
- rolling hashes select anchors or CDC boundaries, whose chunks receive cryptographic digests.

Every persisted result needs an algorithm/profile, input basis, parameters, source guard, and model identity. The donor SimHash's empty-map/zero-unknown defaults collapse all input to zero, so the corrected para profile must require a fitted IDF model or explicitly select a separately named no-corpus weighting rule such as constant-IDF BM25 or TF-only SimHash. Donor compatibility remains a test profile, not an accidental runtime default.

The full port design, jso-jackson integration, cybernetic observation cleanup, and conformance sequence are in [`node-hashish-port-design.md`](node-hashish-port-design.md).

## Ranked design moves

| Rank | Move | Expected turn effect |
|---:|---|---|
| 1 | Typed `delegate` operation: profile, auth/preflight, launch/resume, wait, capture, report, and optional caller-supplied postconditions/verifiers with an explicit `unverified` outcome | Removes roughly 2-4 model turns per delegation. |
| 2 | `run` batch with `commands[]`, per-pane mutex, `stopOnError`, and per-command return selectors | Removes `N-1` model turns for commands knowable in advance. Each command remains a journal turn. |
| 3 | Capture-time projection and bounded `find` hit materialization under a declared aggregate byte budget | Removes the common receipt/search-to-body follow-up turn. |
| 4 | `job_wait` using a coordinator ingestion cursor or vector cursor until `needs_input|terminal`, returning only new typed events | Replaces repeated screen polling and enables bounded talk-back. |
| 5 | Console correctness gate and schema-valid steering errors | Prevents expensive retry turns caused by ambiguous or dishonest state. |
| 6 | Atomic hook projection plus natively verified, semantics-preserving same-tool patches or explicit wrappers | Can reduce returned payload where the exact field behavior is proven; unsupported cases advise or no-op rather than deny/retry. |
| 7 | Exposure ledger and context epochs | Removes repetition only when paired with an explicit novelty-aware delivery policy; telemetry alone saves no turn. |
| 8 | Full SHA-256 guard → optional CDC chunk manifest → profile-scoped Hashish candidate signatures with model identity where applicable, each on demand | Improves integrity, dedup candidates, and robustness later; approximate stages do not themselves prove equality or remove a turn. |

The default 2 KB inline threshold should become a caller or client-profile decision. A final delegated report is usually the desired evidence and may rationally be returned inline even at 8-16 KB when fetching it later costs another full model turn. Unrequested bulk should remain external.

## What not to build now

- A token-policy denial router. A denied call plus retry is usually more expensive than the original call.
- Bash-to-MCP identity rewriting based on `updatedInput`; the hook cannot perform that transformation.
- Raw unbounded journal scans in PreToolUse. Read a bounded projection.
- `cmd_hash` as a cache authority. Identical command text does not imply identical result state.
- SimHash or another fuzzy signature as equality, freshness, or suppression proof.
- An ad hoc JavaScript sketch that changes Hashish preprocessing/model/integer semantics or lacks donor-parity fixtures. A deliberate Node-native port is the intended integration path.
- Governance, exposure, or job events disguised as new Console Journal v1 `kind` values.
- A mandatory semantic outline for unstructured stdout.
- A daemon solely to simulate wake-up. A daemon becomes justified only if it owns several real responsibilities such as single-writer sequencing, psmux lifecycle, job state, and atomic hook projections.
- A skill that encodes one closed workflow or repeats verbose capability prose every turn.
- A monolithic client adapter that combines runtime event translation with privileged configuration mutation.
- A unified knowledge index that allows search relevance to imply memory, policy, or instructional authority.

## Measurement program for the Claude confound

Before setting defaults, run controlled A/B workloads against the actual installed Claude client and record the client version and mode. Capture the adapter-visible guidance inventory for each run, while marking provider-hidden material as unknown.

Measure separately:

- model turns;
- tool calls per model turn;
- fixed prompt and cache-read tokens;
- novel input tokens;
- generated output tokens;
- serialized tool-definition bytes;
- skill and hook-injection bytes;
- tool-result bytes admitted to history;
- bytes remaining resident across later turns;
- retries and misuse chains;
- wall time and provider-reported cost.

Suggested experiments:

1. Baseline with para-agent, its skill, and hooks disabled.
2. Enable only the MCP surface.
3. Enable only minimal capability guidance.
4. Compare minimal guidance, recipe guidance, and verbose guidance on the same tasks.
5. Compare primitive multi-call delegation with one typed `delegate` call.
6. Compare repeated `run` calls with `commands[]` batching.
7. Compare receipt-only, automatic 2 KB inline, and caller-selected projection.
8. Re-test Bash/PowerShell `updatedInput` in interactive and headless modes before any wrapper policy is enabled.

The important guidance metrics are not subjective elegance: solo-tool turn rate, retry-chain length, receipt-to-body follow-up rate, repeated retrieval, never-used tool/schema bytes, wrong execution-model choices, and successful use of primitive escape hatches.

## Author decisions still required

1. Can multiple para-agent server processes serve the same journal root or stream?
2. Is genuine mid-task talk-back required in the first job contract, or is final report plus later follow-up sufficient initially?
3. Is Console Journal v1 already externally immutable, or may its sidecar and fidelity claims be corrected in place?
4. Should the federated driver↔para ledger use a coordinator ingestion cursor or vector cursors, and does any consumer truly require a total order?
5. Which layer owns agent profiles, worktree policy, auth preflight, and optional caller-supplied verification/postconditions?
6. What Claude events reliably mark a new context epoch, especially after automatic or manual compaction?
7. What response budget should the Claude client profile recommend for known-needed final reports?
8. Which primitive tools remain eagerly exposed after higher-level operations exist, and which schemas can be deferred without making the capabilities unusable in fixed-tool clients?
9. Should the backend derivation/index providers begin inside para-agent, or become shared packages only after a second real consumer appears?
10. Where should the semantic guidance source and out-of-band client control plane live so neither becomes para-agent runtime authority?
11. Which Node Hashish profile should ship first: frozen-IDF SimHash, an explicit constant-IDF/TF-only profile, or only exact digest/verification primitives until a corpus lifecycle exists?

## Recommended next design artifacts

Before implementation, write six small contracts rather than another umbrella document:

1. **Console v1 conformance errata** — explicit corrections, compatibility decision, and executable invariant tests.
2. **Backend application boundary** — neutral operation context/result, cancellation, budgets, retention, errors, and dependency rules for MCP handlers versus engines.
3. **Artifact reference and receipt contract** — provider-neutral identity, guard, selector, completeness, and structured continuations.
4. **Job exchange contract** — states, typed talk-back, causal links, budgets, and report artifacts.
5. **Harness routing and capability contract** — native observations, typed decision domains, exact effect support, identity quality, and decision receipts.
6. **Guidance and observability profile** — one semantic guidance source, adapter-visible projections, measurement basis, and explicit unknowns.

The skill should then be drafted against those contracts as the teaching interface over them. This ordering prevents guidance from fossilizing accidental details of the current 13-tool prototype while keeping the eventual workflow open-ended.

The Hashish descriptor and source/model guards belong inside the Artifact contract rather than another umbrella contract or an MCP surface. Implementation should begin with donor fixtures and exact digests only after that vocabulary is stable.
