# Thread-corpus JSONL container (track 3 — scoping)

**Status:** scoping · **Filed:** 2026-07-22

## Track map (user, 2026-07-22)

Three distinct tracks with different design intents and rules — the virtual-DB concept
(entry-point manifest, byte-offset seek, controlled-chunk retrieval) transfers; the
containers and processing rules diverge:

1. **Code ingestion** — current focus; mature through v3. Markdown/config files
   (json/jsonl/yaml, docs) are *not wanted* in code snapshots — a custom side-car
   container is planned for those (TODO: "different output channel/format").
2. **Structured docs / markdown** — barely touched; document-type-specific markdown
   processors; similar to code processing in some ways, different in others.
3. **Chat-thread corpora** (this brief) — near-term interest: ingest large corpora of
   chat-thread exports into a **JSONL container** agents can selectively
   seek/review/retrieve in controlled chunks.

AST subaddressing of code files: not an immediate priority.

## Purpose (user, 2026-07-23)

An extension of distributed cognition: use a reasoning model to process the user's
own externalized thinking at a capacity far beyond natural capacities. The thread
corpus IS that externalized thinking — co-authored with generative interlocutors,
hence noisy (see denoising). The substrate + frontier reader make one's own past
cognition computationally accessible to present cognition. The user remains arbiter:
the question and the acceptance of the answer stay human; the raw store as system of
record and address-anchored verdicts are the provenance guarantee that the
reconstructed trajectory remains *theirs*.

## Unit model

- **Row = ExchangeBlock** (MarkPig envelope): prompt + reply (+ citations) — the
  composite legible unit; exchanges are the chunks-in-reading-order.
- **Thread = TranscriptBlock**: ordered exchanges + thread metadata (source flavor,
  title/slug, export date, source path, content hash).
- **Corpus** = collection of threads + corpus manifest.

## Container sketch — store vs view (refined 2026-07-22)

- **Store = JSONL + `.jidx` side-car** (jso-jackson `[JsonlIndex]::Build` binary seek
  index): one exchange per row; the system of record for the corpus. Search and
  deduplication mechanisms operate here. Compatible with existing jso-jackson
  investigation tooling out of the box.
- **Planned fold-in (user, 2026-07-23): the jso-jackson primitives become the store's
  access/maintenance layer** — `[JsonlTraversal]` path navigation, `[JsonlIndex]`/.jidx
  seek indexing, `Utf8JsonWriter`-based record extraction (no PSCustomObject
  round-trip, no format loss) — for reading, investigating, AND maintaining large
  JSONL datasets. This graduates jso-jackson from ad-hoc investigation tooling to
  store infrastructure: corpora become efficiently accessible with structure and
  tooling.
- **View = rendered consumption artifacts** for LLM readers — the custom
  length-prefixed format and/or corpus manifest (the `*_tree.md` analog): threads →
  exchange index with per-row byte offsets (UTF-8-accurate, `Get-EntryByteOffsets`
  pattern) so agents seek without scanning. Extension naming of views considers RTE
  sniffing (shard-format-notes.md).
- **Operational/metacognitive guidance is first-class**: the manifest's instruction
  block (rs.core.template instruction-set pattern) ships with the payload.

## Consumption model — *ad libitum* access to a prose virtual DB (user, 2026-07-23)

The design center: **reposnapshot's virtual-database view transposed from codebase to
prose corpus**, consumed ***ad libitum*** — the agent grazes on the corpus at its own
pace, in the order the emerging synthesis demands, over **successive inference
cycles**, given the user's prompt ("here's a virtual DB of exchanges; I'm thinking
about XYZ — piece together the architecture emerging across many turns"). Raw
material in context, minimal intervening tool-call noise, never compressed
projections. The point is **digestibility, not auditability**: chunks small enough to
be digested bit by bit, so synthesis and signal extraction stay faithful across a
multi-step inference process. The user cannot hold the corpus in working memory and
attend over it; an agentic model with an addressable substrate can.

**Explicitly not a glorified firehose (user).** The substrate exists so the agent can
**explore the dataset and investigate agentically**. Chunked + addressable + formatted
is the affordance; the intelligence lives in the reader: **what to read, in what
order, and how much per gulp are the reasoning agent's decisions, made per cycle**.
Chronologically ordered chunked reading of a long thread is a strategy the agent will
often sensibly choose — never a contract the container imposes. The container's
obligations end at: semantic unit edges, dense self-describing rows, complete
addressing, an orienting manifest — and *no policy* above unit granularity.

- **The failure modes bracket the design.** Retrieval-mediated sampling reads too
  little and speculates; single-gulp bulk ingestion reads too much at once and
  develops recency bias and middle amnesia (attention dilution, lost-in-the-middle).
  *Ad libitum* bites thread between the two: each chunk small enough for
  full-fidelity attention, accumulated across cycles until effective coverage — the
  agentic loop (KV-cached prior reads + successive small ingestions) achieves what
  single-context self-attention over the whole corpus cannot.
- **Bite geometry is a design axis distinct from transport.** Shard span serves
  upload/fetch horizons; *digestion* wants far smaller units — an exchange row or a
  short run of rows. The fetch-granularity ladder (shard → row → span;
  mcp-surface.md) is therefore not merely precision retrieval — it is bite-size
  control, and the row-level rungs (`.jidx` / byte-offset seeks, offset+count runs)
  are the primary interface of this mode.
- **Interleaved integration is the operating mechanism.** Cycles alternate ingestion
  with the agent's own distillation notes; self-authored integration re-anchors
  mid-corpus content (a model attends reliably to its own recent reasoning), which is
  what converts "middle" material into durable, recallable form. Effective context =
  cached raw bites + the growing integration layer.
- **Manifest as menu, not reading plan**: order is question-driven; revisits are
  cheap and expected. The embedded instruction block (metacognitive-guidance
  doctrine) is the bridge from affordance to behavior: it *teaches* consumption
  patterns — orient, plan, adapt gulp size, interleave integration, revisit —
  without mandating any.
- **The read pattern is part of the reasoning trace.** Which addresses the agent
  visited, at what gulp size, and what it chose to revisit mirrors the hypothesis
  structure — an interpretable investigation record that neither a firehose nor a
  query log provides. Adaptive gulp sizing is attention allocation under
  uncertainty: scan large while confident, bite small at surprise.

- One shard = one continuous ingestion (one Read locally; one upload in web chat; one
  fetch from the public repo) — versus dozens of retrieval round trips, each carrying
  harness framing, fragmentary windows, duplicated context, and shuffled order.
- **Reading order is semantic for prose** — the transposition's key delta from the
  code track. Exchanges pack in thread order; threads pack chronologically (in a
  decision-point archive, corpus-level chronology IS the story). GroupingStrategy
  gains ByThread; the no-fragmentation stance applies at exchange granularity
  (an oversized thread gets a dedicated shard run, never mid-exchange cuts).
- **Gaits**: *ad libitum* grazing is the general contract; the end-to-end sequential
  scan with carried state remains a specific gait for order-dependent work (trajectory
  adjudication reads in thread order by necessity). Same rows, same addresses —
  different consumption programs over the same container.
- **Dispatch boundary (user, 2026-07-23 — Swendsen-Wang analogy).** Trajectory
  synthesis does not admit embarrassing parallelism: chunked fan-out summarization
  loses order and summarizes blind to the global context that IS the signal — and the
  reduce does not commute with the partition (a verdict is a *nonlinear* observable of
  the whole trajectory; per-chunk digests are lossy projections chosen before the
  question the whole will ask of the part is known — some things aggregate only after
  all observations are made). As in SW cluster MC: the chain is stateful, and the
  meaningful clusters span any partition. Legitimate parallel grains: **across
  threads** (independent chains), the **mechanical tier** (stripping, indexing,
  stats), and **full-context replicas** (multiple whole-thread readers with different
  lenses). Never chunk one chain. Corollary: the raw store is the saved configuration
  timeseries — new observables can be measured later from stored configurations
  without re-running the simulation; that is the store/derived-layer split restated in
  MC terms.
- Shard span tunes to the reader's ingestion horizon AND co-tunes with the user's
  context-mode routing thresholds, so the serving format never triggers its own
  deployment's advisory nudges (.txt camouflage already helps).
- Near-dup/dedup runs before sharding — re-exported and overlapping threads would
  silently spend shard budget twice.

## Guidance layer — instruction block as cognitive stdlib (user, 2026-07-23)

The manifest's instruction block is a designed cognitive artifact, not documentation —
the reposnapshot tree's metacognitive guidance elevated to a first-class layer.

- **Framing/priming is mechanism for LLM readers.** In-context language literally
  conditions all subsequent computation; the manifest's stance-setting prose is
  functional machinery, not decoration. Placement matters: guidance adjacent to the
  payload conditions the read; guidance far away decays (the ships-with-payload
  doctrine already gets this right).
- **"Ephemeral cognitive lambdas" (user):** the instruction block ships a **standard
  library, never a `main()`** — small named, composable, session-scoped procedures
  the reader *calls* ad libitum; guidance teaches, never drives. Candidate stdlib:
  `ORIENT` (manifest → question-plan) · `DIVE` (choose address + gulp size) ·
  `SURFACE` (write integration notes before the next dive) · `REVISIT` (re-read under
  a firmed hypothesis) · `ADJUDICATE` (verdict pass over a thread). First-class and
  conditional — the agent composes them; they never compose the agent.
- **Memento discipline (user metaphor: Leonard).** The reader is memoryless across
  cycles and sessions; its rolling notes are its tattoos — the next cycle treats them
  as ground truth and cannot cheaply re-derive them. Leonard's failure mode is the
  exact risk: an unanchored conclusion becomes an unfalsifiable fact ("don't believe
  his lies," no evidence trail). Therefore `SURFACE` carries epistemic hygiene rules:
  every durable note states (a) the address(es) it derives from, (b) an epistemic
  status marker (observed / inferred / hypothesis). **Never tattoo a hypothesis as
  fact.** Rolling notes are self-administered priming — the protocol is what keeps
  the self-programming honest.
- Sharpened mapping: the lesion is **consolidation, not working memory** — the
  context window is working memory, and a good one; what's missing is durable
  carryover across cycle/session boundaries. The substrate + note protocol are the
  consolidation organs (cf. the replay/schema framing under Purpose).
- **Activation discipline (user):** vocabulary is basin selection. Conventionally
  dense terms ("RAG," "chunking," "summarize," "index") are addresses into
  heavily-reinforced training clusters — naming one summons its entire prefab
  architecture, and generation warps toward it (the first local minimum the model
  fits). For unconventional designs, prefer relationally precise, low-anchor
  language and structure-mapping metaphors (*ad libitum*, gaits, Leonard): a distant
  source domain transfers its relational skeleton without leaking surface content,
  forcing the reader to *compose* meaning rather than *retrieve* a package. Negative
  metaphor inoculates — naming the adjacent attractor as wrong ("not a glorified
  firehose") makes basin-sliding self-detectable. Constitutional values (parsimony)
  constrain the objective, never the solution basis: evaluation function installed,
  templates withheld. Anchor-withholding is a frontier-reader affordance — weaker
  readers need the conventional anchor (two-era tiering again).
- **Register doctrine (user):** guidance speaks in principles, abstract values,
  suggestions, and warnings — not commands and contraindications. For capable
  readers, rationale-bearing principles outperform imperatives: a bare "never X"
  cannot communicate its own scope and gets applied literally at the edges;
  "avoid X because Y" lets the reader detect when Y does not apply and derive right
  action in unforeseen cases. Warnings are the strongest form — they install
  *recognition* of a failure mode rather than a behavior. Commands are reserved for
  true invariants (framing/format contracts, safety) — few and hard. Register tiers
  with reader capability (two-era doctrine): weaker readers get more procedure,
  stronger readers more principle. Precedent in the user's own infrastructure:
  context-mode-core advisory routing (token-policy denials → non-blocking nudges;
  security denials stay blocking).

## Derived layers — adjudication products and navigation metadata (2026-07-23)

Motivating tension (user): context economy vs the occasional need for broad synthesis
across many large documents. Pointing agents at raw markdown yields speculative
synthesis — sampling without coverage accountability; fluency masks the gaps.

- **Derived layers do not substitute for reading (user correction, 2026-07-23):
  previews/summaries are not the consumption mode.** They serve two subordinate
  roles: (a) **navigation metadata** in the manifest — titles, topics, spans — the
  orientation layer consulted before and between bulk reads; (b) **cached products
  of frontier reading passes** — chiefly the verdict/trajectory layer below, written
  *after* raw consumption so later sessions inherit the adjudication without
  re-reading the corpus.
- **Denoising ≠ summarization (user).** Design threads have a characteristic noise
  profile: each reply is part genuine insight, part confident-but-misdirected
  declaration of what happens next / what the architecture should be; the user's
  subsequent turns are the course corrections, and performing that filtering while
  reading is cognitively taxing. Summarization — at any model capacity — produces the
  *wrong artifact* here: confident declarations compress crisply while tentative
  insight smooths away, so summaries preserve or amplify the noise. The needed
  artifact is a **verdict**: what each reply contributed that *survived* the thread's
  subsequent trajectory, what was corrected, what was abandoned.
- **Signal is resolved by the future of the thread.** A turn's status as
  insight-vs-misdirection is mostly not decidable locally — it is settled by later
  turns. Adjudication is therefore inherently sequential (thread-at-a-time, reading
  order), not a row-local map job. Exchange rows in reading order are exactly the
  required input shape.
- **Tiered reasoning economics:**
  1. *Mechanical* (deterministic/local): segmentation, addressing, indexing, dedup —
     the substrate itself. Local GGUF at most for trivial tags.
  2. *Judgment* (frontier, batch): per-thread adjudication — the frontier reader
     consumes the thread's shards raw, in order, and emits the verdict layer as its
     *product*. Local GGUF capacity is explicitly insufficient for this tier (user,
     2026-07-23). Once per thread, cached by content hash (exported threads are
     immutable → cache is permanent), thread-parallel. The cognitively taxing role
     transfers: user audits verdicts by row address instead of performing the
     filtering.
  3. *Synthesis* (frontier, interactive): cross-thread synthesis still reads raw
     shards; prior verdict layers ride along as inherited carried state — adjudication
     is never a substitute for the material, it is the accumulated margin notes.
- **User trajectory track is first-class.** The user's prompts are the low-noise
  backbone; "what I was actually working out, in order" is itself a primary synthesis
  product. Reply verdicts hang off that trajectory. This is the first-milestone
  promise ("when did I decide this, on what evidence, which model said what") made
  into a schema'd layer rather than an interactive retrieval hope.
- Verdict spans are emitted by the adjudicator (quote/offset anchors into the reply),
  so open decision 3 (mechanical secondary chunking) stays deferred — verdict
  attachment does not require pre-chunking.

## What already exists

- `reposnapshot-v3/processors/tp-perplexity.ps1` — Perplexity flavor parser → Exchange
  objects (Index/Prompt/Reply/Citations); the mask→segment→restore architecture is the
  template for other flavors.
- `reposnapshot-v3/rs.core.sharding.psm1` — **re-dispositioned**: the v3.1 JSONL/piped
  generation (Write/Read-JSONLShard with offset+count, Build-ShardMetadata TOC,
  manifest, Get-FileFromShard) is the natural substrate for THIS track, not vestigial
  code-track machinery. (Resolved 2026-07-23: Build-ShardMetadata now binds
  `rs.core.numerics` — working SimHash from the hashlib-new lineage.)
- `RepoSnapshotLts.psm1` `Get-EntryByteOffsets` — byte-accurate row addressing to port.
- Hashing for dedup / near-dup thread detection: consolidate the corrected
  **PowerShell equivalents** (mathdig `hashlib-new.ps1` masked-uint64 patterns) —
  this is not a C# project; the hashish/.cs successors are study/reference material
  for the eventual centralization, not a binding. ~~Do not use rs.core.hash/lsh as-is
  (broken numerics).~~ Landed 2026-07-23 as `rs.core.numerics.psm1` (G3 pull:
  hashlib-new SimHash/MinHash + SHA256 identity + fixed Hamming/Levenshtein;
  see issues/v3/rs.core.numerics-design.md and the cross-exam doc).
- Prior art in PowerShellCore: `rs.core/threadparser` (.legacy Markdig parser),
  NDPSON doc-ingestion discussions under `rs.core/.discussion/sharding/`.

## Open decisions

1. Row schema: flat exchange rows with thread-id keys vs thread-header rows + exchange
   rows; where thread metadata lives.
2. Layout: one JSONL per thread, sharded corpus files, or thread files + corpus index.
3. Long-reply secondary chunking (code fences as opaque regions; reply sections) —
   likely deferred until a real corpus demands it.
4. Flavor coverage: perplexity first; claude/chatgpt/gemini export flavors next;
   flavor detection vs explicit configuration.
5. Citation/footnote normalization across flavors.
6. Orchestration: colonel fits naturally (items = thread files, chain = tp-{flavor});
   requires the colonel helper-function contract fix (tp-perplexity currently rejected
   for `function _MaskByRegex`).
7. Naming (user's Latin-slug brand; MarkPig envelope relationship).
8. Verdict/adjudication schema: verdict categories (survived / corrected / abandoned /
   deferred-open), span anchoring (quote vs byte offset), and where adjudication
   artifacts live (columns on exchange rows vs per-thread derived sidecar). Which
   frontier surface runs the batch pass and how its cost is scheduled/amortized.
9. Iterative-consumption contract: form and location of the rolling notes the reader
   carries between shards (scratch file vs appended sidecar; do they graduate into the
   verdict layer); shard-span co-tuning with context-mode routing thresholds; whether
   inherited verdict layers ship inside the view (manifest-adjacent) or load on
   demand. Note hygiene rules per the Guidance layer (address-anchored,
   status-marked).
10. Guidance-layer authoring: stdlib procedure set and wording (ORIENT/DIVE/SURFACE/
    REVISIT/ADJUDICATE as candidates); how much stance-priming prose the manifest
    carries per reader profile (web-chat vs tool-bearing agent); whether procedures
    are versioned with the corpus or with the generator.

## Suggested first milestone

tp-perplexity → JSONL end-to-end over a small sample corpus: crawl a folder of exports
→ parse to Exchanges → write corpus manifest + JSONL rows + byte offsets → verify the
agent-seek round trip (fetch exchange N of thread T by offsets alone, no scan).

**Candidate first corpus:** the ps.core.pwshspc markbrain historical docs — the
Gemini "compiled kernel" report and the Perplexity/other digestion threads around the
pwshspc → ThermoMapper pivot. A decision-point archive whose retrieval value is
exactly the track's promise ("when did I decide this, on what evidence, which model
said what"), multi-flavor, modestly sized, personally meaningful — ideal dogfood.

## Work log

- 2026-07-23 — Added "Derived layers" section (synthesis view + adjudication tier)
  from design session; local-GGUF capacity ruled out for judgment-tier passes (user);
  open decision 8 added.
- 2026-07-23 — Consumption model corrected (user): sharded raw-in-context reading is
  the primary mode — reposnapshot's virtual-DB philosophy transposed to prose;
  previews/summaries demoted to navigation metadata + cached reading products;
  decision 9 added.
- 2026-07-23 — Consumption contract refined (user): ***ad libitum*** — digestibility,
  not auditability; anti-pathology stance (recency bias / middle amnesia vs sampling
  speculation); bite geometry (row-level rungs) distinct from shard transport;
  interleaved-integration mechanism; sequential scan demoted to one gait among gaits.
- 2026-07-23 — Agentic-investigation recenter (user): not a glorified firehose —
  agent-determined reads (what / order / gulp size, per cycle); container policy ends
  at unit granularity; instruction block as affordance→behavior bridge; read pattern
  recognized as reasoning trace.
- 2026-07-23 — Guidance layer promoted to first-class section (user): instruction
  block as cognitive stdlib ("ephemeral cognitive lambdas"); Memento/Leonard
  discipline → note-hygiene rules (address-anchored, status-marked); consolidation
  (not working memory) identified as the lesion; decision 10 added.
- 2026-07-23 — Register doctrine added (user): principles/values/suggestions/warnings
  over commands/contraindications; commands reserved for invariants; register tiers
  with reader capability; advisory-routing precedent noted.
- 2026-07-23 — Activation discipline added (user): vocabulary as basin selection;
  metaphor as structure-mapping without target-domain anchoring; negative-metaphor
  inoculation; values constrain objective, not basis.
- 2026-07-23 — Dispatch boundary added (user, post-dogfood): Swendsen-Wang analogy —
  chunked fan-out violates statefulness and observable commutativity; parallel grains
  = threads / mechanical tier / full-context replicas; raw store = saved
  configurations (re-measure new observables without re-simulation).

_(append findings/results here)_
