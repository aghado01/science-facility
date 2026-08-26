# i thought LTS imported sharding already and was using rs.core.sharding

Good challenge — that's a factual claim about the code and I stated the relationship from the transfer-audit doc's framing rather than verifying the actual import/call graph. Let me check it directly instead of defending it. Your "extract primitives" pattern makes it very plausible that sharding was pulled _out_ of the monolith and LTS imports it back.

You're right, and I was wrong to state otherwise. LTS **does** import and use the sharding module — the evidence is unambiguous:

- `RepoSnapshotLts.psm1:21-24` — `Import-Module reposnapshot-v3\rs.core.sharding.psm1 -Force`
- `RepoSnapshotLts.psm1:2355-2360` — `Shard-SnapshotFile` guards on `Partition-Files` ("Ensure rs.core.sharding is imported") and calls it.

So sharding was already extracted out of the monolith into the V3 module and LTS consumes it — exactly your "extract primitives" pattern. My "old-gen, re-tasked to thread-corpus, separate from LTS" framing came from the stale audit doc, not the code. Let me get the _actual_ dependency graph right before I revise the map — specifically **which** parts LTS delegates vs. still does inline.

That reframes it further — and again in your favor. LTS dot-sources **both** V3 modules and delegates to them:

- `RepoSnapshotLts.psm1:11-14` — dot-sources `rs.core.template.ps1` (the **toc-template engine**), plus a re-loader `Import-TocTemplateEngine` at :79.
- `RepoSnapshotLts.psm1:21-24` — imports `rs.core.sharding.psm1`, uses `Partition-Files`.

So LTS is already a **hybrid**: the monolith hollowed out to consume the extracted `rs.core.*` writer modules, keeping only orchestration + row/offset/tree writing + `Normalize-FileContent` inline. My "these modules aren't wired / are a separate track" framing was backwards. The real question is the _other_ direction — does the **V3-native** pipeline (ingest → assemble) drive these modules, or is LTS still the only thing that does? Let me check the consumer graph.

Now I have the precise call graph, and it corrects my map materially. Let me pull the sharding module's own header (the authoritative re-disposition note — I'd been quoting the stale audit) and the `ConvertTo-ShardFiles` contract, since the CHANGELOG hints it's the intended IR→shards bridge.

Verified now — and you were right on the substance; my back-half framing was inverted. Here's what the code actually shows.

## Corrected: the writer modules _are_ extracted and in production use — via LTS

LTS is a **hollowed-out hybrid**, not a self-contained monolith:

| Surface                                                                  | Where it lives                                        | Who drives it                                                    | State                                                         |
| ------------------------------------------------------------------------ | ----------------------------------------------------- | ---------------------------------------------------------------- | ------------------------------------------------------------- |
| **Partitioning** (`Partition-Files` — grouping/packing)                  | `rs.core.sharding` module                             | **LTS calls it** (`:2360`) + module's own `ConvertTo-ShardFiles` | ✅ extracted, shared, in use                                  |
| **toc-template engine** (`Expand-TocTemplate`, TOC models)               | `rs.core.template.ps1`                                | **LTS dot-sources it** (`:11-14`, `Import-TocTemplateEngine`)    | ✅ extracted, in use                                          |
| **Code-track `.txt` emission** (escaped rows, byte offsets, tree.md)     | **inline in LTS `Shard-SnapshotFile`** (`:2443-2465`) | LTS only                                                         | ⛔ **not extracted — monolith-resident**                      |
| **JSONL/piped writer** (`ConvertTo-ShardFiles`/`Export-ShardedSnapshot`) | `rs.core.sharding` module                             | nobody yet from V3; consumes LTS JSON or `Files[]`               | 🔶 thread-corpus substrate; **IR-entries entry point queued** |

The authoritative source is the module's own header (`rs.core.sharding.psm1:22-34`), not the stale audit I quoted: the JSONL machinery is the **thread-corpus store substrate**; `Partition-Files` _additionally_ serves the LTS code-track shard path (the "arrangement layer"); and `ConvertTo-ShardFiles` is explicitly slated to gain an **IR-entries entry point** so the IR can drive it directly.

## So the real back-half gap is narrower and differently-shaped than I said

- **Carried over / shared already:** partitioning (`Partition-Files`) and the TOC-template engine. LTS consumes both. Your recollection was correct.
- **NOT carried over:** the code-track `.txt` **row/offset/tree emission** — that logic is still living inside the LTS monolith's `Shard-SnapshotFile`, writing bytes inline (`[IO.File]::Open` … `Idx | path | {attrs} | Length | Escaped`). It was never lifted into a V3 module.
- **NOT built:** the **V3-native orchestration** — `assemble` produces the IR, but nothing on the V3 side drives IR → `Partition-Files` → writer. **LTS is still the orchestrator.** That's the admiral-shaped hole, plus the queued `ConvertTo-ShardFiles` IR entry point.

So it's the inverse of my "masked, unbuilt" claim: the modules are real and in use — what's missing is (a) extracting the LTS-inline `.txt` emitter, and (b) a V3-native driver so the IR reaches these modules without the monolith. The "shared module" surface can _understate_ completeness on partitioning/TOC while _hiding_ that emission is still monolith-locked.

This also resolves an open item the audit itself flagged ("verify whether LTS already loads `rs.core.template`") — answer: **yes, both modules.**

Two corrected rows for Part B, everything in Part A stands:

- **B1/B2 restated:** not "writers unbuilt" but **"emission still monolith-inline + no V3-native driver"**; `ConvertTo-ShardFiles`'s queued IR entry point is the intended seam.
- **B4 restated:** toc-template isn't "unwired" — it's **wired into LTS**; the gap is wiring it into a V3-native path.

Want me to (1) fold this **corrected** map into `lts-v3-transfer-audit.md` (it's stale on exactly this point), or (2) keep going and nail down whether `ConvertTo-ShardFiles` already has the IR-entries entry point or it's still just queued — that's the load-bearing question for how much emission work actually remains?

# yea and what i think iw ant to do is write new code `rs.core.shards` and `rs.core.serialize` for the final two steps, parsing out sharding logic per se from the serialization concerns to json, jsonl or the custom .txt containers+\_tree.md, and wiring up template as appropriate, then lts can continue frozen and retired when v3 is standing

`ConvertTo-ShardFiles` has **no IR entry point yet** — its only parameter sets are `FromSnapshot` (an LTS JSON file on disk) and `FromFiles` (a pre-loaded array). The IR-entries seam is still just _queued_ in the docstring. So the V3-native emission path is effectively **greenfield** — which is exactly why your instinct to _write new code_ rather than retrofit that function is the right call.

**Your split falls on seams that already exist latently.** The current `rs.core.sharding` conflates two things that are already separable inside it:

- **arrangement** — `Partition-Files` (which entries go in which shard; grouping/packing) → your `rs.core.shards`
- **emission** — `Write-JSONLShard` / `Write-PipedShard` in the module, plus the `.txt`+`_tree.md` byte-writer still inline in LTS → your `rs.core.serialize`

So this isn't inventing a boundary; it's _naming_ one that's implicit and tangled. That's the extract-for-legibility move in its cleanest form.

**On "LTS frozen":** LTS imports `rs.core.sharding` and calls `Partition-Files`. The clean reading of "frozen" is — leave `rs.core.sharding` **frozen in place as LTS's dependency**, build `rs.core.shards`/`rs.core.serialize` fresh alongside, port the good logic behavior-preserving, and retire the old module _with_ LTS when V3 stands. That also rescues the JSONL machinery earmarked for the thread-corpus track — it migrates into `rs.core.serialize` as the `jsonl` format rather than being stranded in the frozen module. Is that your intent, or did you mean to evolve `rs.core.sharding` in place?

**The one crux the split forces** — and it's worth deciding before any code, because it sets the module boundary and the data flow:

> **Byte-offset packing couples arrangement to serialization.** `Partition-Files` packs on _content_ `SpanBytes` (format-agnostic). But LTS's Flat `.txt` path packs on **encoded byte-cursor positions** — it materializes the encoded byte stream, cuts on those positions, and computes the seek offsets inline. Those are two different packing disciplines, and the seek contract (byte offsets → `_tree.md` TOC via template) is a _serialization_ artifact, not an arrangement one.

So the boundary question is: does **`rs.core.shards`** decide membership purely on abstract content spans + policy (and **`rs.core.serialize`** owns encoding _and_ the byte-offset TOC, template included) — accepting that `.txt` framing/escaping shifts the real bytes? Or do you want byte-accurate `.txt` shards, which needs a serialize-measure pass feeding sizes _back_ to `shards`? That fork decides whether the two modules are a clean one-way pipe (`shards → ShardPlan → serialize`) or a two-pass loop.

How are you thinking about that coupling — is byte-exact `.txt` packing a requirement, or is content-span packing good enough and offsets become purely a serialize-side product?

---

## Session continuation (captured 2026-08-10) — serialization architecture

> **Provenance caveat.** This half of the session ran in the stale `aghado01/utils`
> copy, without the committed `shard-format-notes.md` codec spec or the
> `rs-attributes.ps1` "CANONICAL UTF-8 / planning-grade SpanBytes" note in view. So
> parts below re-derive what those already settle, and two conclusions **diverge from
> committed decisions** — flagged **RECONCILE**. The codec is authoritative in
> `shard-format-notes.md`; this note does not restate it.

**LTS `.txt` emission, decomposed into five passes** (`RepoSnapshotLts.psm1:2288-2554`):
render (escaped rows → one flat buffer, running byte offsets) · arrange (byte-cursor
cuts under `max_span`; anti-fragmentation = an oversized unit takes its own shard) ·
emit (schema block + rows; contiguous slice for Flat, per-shard render for grouped) ·
measure (post-write in-shard spans: `row_offset / row_meta_end / row_content_begin /
row_content_end`) · navigate (`_tree.md` via the template engine).

**Net-new this session (proposals for the two final stages):**
- **`rs.core.shards` (planning) vs `rs.core.serialize` (emission)** — naming the boundary
  already latent in `rs.core.sharding`: `Partition-Files` = arrangement; the writers =
  emission. `serialize` brackets `shards` as **measure → plan → execute**. serialize owns
  escaping + byte-accounting + offsets + tree; shards owns grouping + ordering + packing
  policy. The codec and byte-counter never touch shards.
- **Serializer = a stateful SDK-grade class** — holds buffer/cursor/offset-map/template
  ref; template engine **injected** (testable); buffering-vs-streaming an internal
  strategy (streaming matters for large corpora, unlike LTS's buffer-everything).
- **`shards` emits a "resolved IR"** (entries + shard assignment + order) as the contract
  into serialize.
- **`assemble.schema.json`** — the IR contract captured as a decoupled schema
  (`reposnapshot-v3/schema/`; location/naming provisional).
- **`AllowOversizedShards` = top-level policy**, orthogonal to grouping, over the
  unit-integrity invariant (never split a unit); opt-out = reject/flag. (Consistent with
  `shard-format-notes.md` §Configurability.)
- **Naming:** "escaper" → **codec** (aligns with the `jsonl_engine` `Codec` axis).

**RECONCILE — two divergences from committed spec:**
1. **SpanBytes location.** This session proposed moving `SpanBytes` out of `rs-attributes`
   into serialization ("length/spanbytes/escaping are container properties, computed
   JIT"). The committed `rs-attributes.ps1` note argues the opposite and more sharply:
   `SpanBytes` **stays in `rs-attributes`** as a UTF-8-by-convention, serializer-invariant
   **planning-grade** metric (ranking / skip / packing budgets), explicitly *not* an
   offset or encoded length. That separation (SpanBytes = content/planning vs
   `length`/offsets = encoded/serializer) is cleaner than collapsing them. **Assessment:
   committed likely wins — SpanBytes stays put; only `length` + offsets are serializer-JIT.**
2. **Packing input.** This session pushed **byte-exact** packing (a measure pass feeding
   shards exact encoded row sizes). The committed spec packs on **planning-grade
   SpanBytes** ("the right input for shard packing budgets"), offsets exact only
   post-emission.

Both collapse to one axis: **is shard packing planning-grade (committed) or byte-exact
(this session)?** User's call — and it decides whether the `measure → plan → execute`
bracket is needed or whether `shards` plans on SpanBytes and serialize measures after.
