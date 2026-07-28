# Admiral — v3 pipeline orchestrator (scoping)

**Status:** scoping · **Filed:** 2026-07-28

Codename: **admiral**, the orchestrator above `colonel`. The glue layer over v3's
discrete stages (crawler → ignore → ingest/colonel+processors → IR assembly →
writers). It does not exist yet — LTS never needed one because the monolith fused
stages inherently as it grew; v3 needs one *by design*.

**Mission (user, 2026-07-28):** coordinate the stages, hold pipeline state, and
handle routing decisions about data and control flow.

## Architecture principle (user, 2026-07-28)

Stages are developed **independently and modularly**, with defining contracts
between each stage written as part of the development process. New v3 stages are
never built by directly fusing one stage's outputs into the next stage's
internals — the glue is admiral's job, and admiral's alone.

**Provenance of the rule:** earlier v3 development was not explicit about this and
produced an entangled mess from crawler to ignore — stages depending directly on
each other when they shouldn't. Residues of that mistake remain (see below).

## Crawler ↔ ignore: greedy-crawl decision (user, 2026-07-28)

Ignore configuration originally lived inside the crawler — partly because no
orchestrator existed, partly so ignore rules could be applied JIT during the walk
for incremental performance. **Decided: greedy crawl.** Crawl everything, collect
the data, filter afterwards. The JIT coupling isn't worth the system complexity
and the compromise of the modular-architecture principle.

## The through-line (user, 2026-07-28)

Information flows **through the orchestrator**, never laterally between stages:

- Admiral calls crawler; crawler returns *all* of its enriched outputs.
- Admiral receives them and hands ignore what it needs — or hands the same
  outputs verbatim as inputs (**unresolved** which; see open questions).
- Information produced at earlier stages is **retained and selectively usable
  downline** in the pipeline, without intervening stages needing to handle or
  pass through data they don't themselves consume.

Implication for stage contracts: a stage's input contract names what it consumes;
it is never a courier for fields addressed to later stages. Carried state lives
with admiral.

## Admiral responsibilities (accumulating)

- Stage sequencing and the through-line (retained stage outputs, selective
  hand-off downstream).
- Run-config → per-stage config projection. Includes cross-stage policy mappings
  a stage must not know about — e.g. output config says attributes are never
  emitted anywhere → compile the chain profile without `rs-attributes`
  (compute-by-default otherwise; emission is a writer knob — see transfer-audit
  work log 2026-07-28).
- The crawl→ignore join, if RelativePath enrichment moves out of ignore (open
  question below).
- Diagnostics aggregation across stages. Pattern to replicate:
  `rs.core.ingest`'s uniform `{ Results; Skipped; Errors; Warnings }` envelope
  and its reflection-based parameter forwarding (no hardcoded knowledge of
  colonel's surface).
- Optional artifact emissions (JSON monolith becomes an opt-in output, not a
  pipeline stage — transfer-audit "Monolith → IR distillation").

## Wrapper mechanism — reflection-forwarded params (user, 2026-07-28)

Admiral's needs are already anticipated in `rs.core.internals.psm1`: helpers that
expose the bound-parameter surfaces of pipeline components' functions/classes so
admiral can wrap imported stage functions **without writing out their parameter
lists**. Unconventional, but deliberately chosen for maintainability: stage
function signatures can change without updating the exact parameter calls in
admiral's wrappers.

The three primitives:

- `New-ForwardedParamDictionary` — reflects a target command's params into a
  DynamicParam dictionary (attributes preserved; common params excluded).
- `Split-ForwardedParams` — partitions the wrapper's `$PSBoundParameters` into a
  splat by excluding the wrapper's own param names.
- `Register-StageWrapper` — the decorator equivalent: registers a named wrapper
  in the `Function:` drive with full reflected surface, caller-loses-nothing
  defaults injection, and optional PreProcess (mutate splat) / PostProcess
  (transform result) hooks. This is the fullest expression of the mechanism —
  ingest only uses the first two inline.

Working proof: `Invoke-Ingest` declares only the one param it uniquely owns
(`FilteredFsGraph`) and reflects/merges the surfaces of both `Compile-Plan` and
`Invoke-Plan`, routing bound params to the right callee at call time.

Known implications the design accepts (record, don't relitigate):

- **Load-order dependency** — reflection requires the target command loaded
  before the wrapper's DynamicParam resolves; module load order is admiral's
  responsibility (already stated in ingest's NOTES).
- **Collision policy** — a wrapper fronting multiple targets needs a name-merge
  rule; ingest's precedent is priority order (Compile-Plan wins).
- **DefaultValue reflection is best-effort** (module's own note) — canonical
  defaults live in the wrapper's param block or the `Defaults` table, not in
  reflected metadata.

## Known residues to clean (identified 2026-07-28)

1. **Ignore stamps `RelativePath` onto crawler file objects** during its join
   (`rs.core.ignore.psm1` join docs) — and `file-read.ps1`'s contract expects
   `$Item.RelativePath`/`NodePath`. Hidden dependency: a raw crawl cannot feed
   ingest even with zero ignore rules. Enrichment belongs in the crawler's
   output contract or an admiral-owned join step.
2. **Shared mutable objects across the boundary** — ignore mutates crawler's
   node/file objects in place (stamping, pruning). Contracts must state
   ownership transfer or copy-on-enrich.
3. **Crawler mixes diagnostics into its graph result** — its own TODO already
   calls for a separate diagnostics feed.

## Open questions

1. Hand-off form: does admiral project per-stage inputs (hand ignore only what
   it needs) or pass whole stage outputs and let contracts name what's consumed?
   (user: unresolved)
2. Where RelativePath/NodePath enrichment lands: crawler output contract vs
   admiral join step (either removes it from ignore).
3. Mutation ownership: copy-on-enrich vs explicit ownership transfer at each
   boundary.
4. Shape of admiral's carried state: named stage-output slots addressable by
   later stages, and what "selectively used downline" looks like concretely
   (e.g. crawler's SizeBytes/last_write consumed by IR assembly without passing
   through processors).

## Cross-references

- `issues/v3/lts-v3-transfer-audit.md` — work log 2026-07-28: processor-span
  disposition (what belongs in the chain vs assembly vs writers).
- `reposnapshot-v3/rs.core.ingest.psm1` — the contract/envelope pattern admiral
  generalizes.
- `issues/thread-corpus-container.md` — open decision 6 (colonel
  helper-function fix) gates the perplexity chain admiral will eventually drive.

## Work log

_(append findings/results here)_
