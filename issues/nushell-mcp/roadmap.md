# nushell-mcp roadmap

**Status:** living doc — amend in place, newest thinking wins ·
**Started:** 2026-08-21 · **Home:** `mcp/nushell-mcp` (implementation),
this folder (specs).

## North star

An **augmented interactive console experience** on a persistent Nu
session — not a compute platform. It maintains strict context hygiene,
encourages planning and thoughtful execution, and treats the agent's
context window as the scarcest resource in the loop:

- **Non-blocking operations** — slow work runs while the agent keeps
  thinking; the console never holds `evaluate` hostage.
- **Payload quarantine** — big results are written to file or held in
  engine memory and *queried as results*, never dumped into context.
- **Skeletal metadata first** — receipts, census, and spine views expose
  the shape of a dataset so retrieval can be surgical and responsible.

## Doctrine (settled)

- **Interactive fan-out over batch compute.** Parallel search inside a
  session is the design center; dataset processing is secondary,
  big-data ergonomics deferred. Ambiguous calls favor the console.
- **Non-blocking + quarantine is the product; parallelism is a
  feature.** A single `jobs spawn` at parallelism 1 is a design-center
  use, not a degenerate case.
- **Division of labor:** `rg` owns textual search throughput (internally
  parallel — never sharded through `par` for speed); `par` owns
  structural per-item predicates. `rg` finds *where*, `par` judges
  *what*.
- **Durable primitives**, use-case-agnostic: budgeted dispatch,
  receipts-before-bodies, registry-as-queryable-store. Parallel
  completion is not parallel disclosure.
- **Contracts are documented, not encoded.** Verbs name the dispatch;
  shapes and error stances live in docstrings, the reference corpus, and
  `nu-modules` inspection — never in the handle.
- **Persistence and identity:** the MCP writes no generic filenames;
  identity is **routed by the caller** at spawn (launcher contract =
  `--config` + identity); scoped session history is **standard issue**
  for a persistent session, other historical stores opt-in. Full text in
  [par-jobs-v1](briefs/par-jobs-v1.md) → Persistence and identity.
- **`nu --mcp` is the engine protocol, not the product surface**
  (decided 2026-08-21). It uniquely provides a persistent engine behind
  JSON-RPC — keep it. Its surface is narrow (verified: one tool,
  output-only `$history`, hooks never fire, metadata stripped), so a
  **thin TypeScript host** fronts it: transport, ledger, identity,
  policy. Thinness rule: the host never implements Nu semantics; if a
  feature needs the host to understand a Nu value, it is a Nu verb.
  The agent's experience stays pure Nushell. See
  [session-host-v1](briefs/session-host-v1.md).
- **Receipts carry provenance by convention.** Every record the layer
  returns has a closed `meta` sub-record (`kind, at, tag?, elapsed?,
  ref?`) via one pure `stamp` primitive; tables stay bare. `$history`
  is a spine of values + positions; `meta` is how entries describe
  themselves and point at each other. (probe-v1, to be filed.)

## Sequence

1. **`par` / `jobs` v1** — [briefs/par-jobs-v1.md](briefs/par-jobs-v1.md)
   · landed 2026-08-21. Data plane + handle plane + budget on the
   persistent engine. Carries the envelope contract (shape 4) and the
   registry mechanics.
2. **probe v1** — to be filed (supersedes
   [briefs/hist-v1.md](briefs/hist-v1.md)). Pure primitives, one module:
   `shape` (+ `each`), `schema` (+ `diff`/`check`/`stats`), `spine`,
   `page`, `preview`, `stamp`. jso-jackson's controlled-exploration
   doctrine in Nu's data orientation; the `bytes` definition lives here
   once. No deps — can land in parallel with 3 and H.
3. **`xq` v1** — [briefs/xq-v1.md](briefs/xq-v1.md) · filed; depends
   on 1. Execute-and-quarantine for every external: `complete` + census
   + inline-under-cap / stash-over-cap, job-aware via `job id`. The
   primitive rg is a special case of — build before 4.
4. **`rg` wrapper v1** — [briefs/rg-wrapper-v1.md](briefs/rg-wrapper-v1.md)
   · filed, not started; depends on 1 and 3. `xq` + JSON-event parse +
   spine; `--wrapped` query side, registry storage via `jobs stash`.
5. **Query tools on the envelope** — mdnav_v2 chunk shards, `nu-skills
   search` fan-out. First real parallelism consumers; `par emit` shipped
   with par-jobs-v1. Align the chunk shape with mdnav_v2's brief rather
   than inventing twice.
6. **Session layer / daemon** — later. Scoped per-agent history
   (standard issue), identity plumbing exercised for real, jobs that
   outlive the MCP child, queueing at cap, process isolation.
7. **para-agent visitor grant** — later. Admit this MCP to a
   participant; same verbs, no new surface.

**H. Session host v1** — [briefs/session-host-v1.md](briefs/session-host-v1.md)
· filed. Parallel track: thin TS MCP host in front of `nu --mcp` —
host-side history ledger (at, source, census), `annotate`, `read`,
`console`, caller-routed identity with one engine per `(session,
agent)`, scoped JSONL history artifacts, keepalive, informative
truncation. Absorbs the hist-v1 index sidecar and the session-layer
history work from 6; 6 keeps only what needs a true daemon.

## Briefs

| Brief | Status |
|---|---|
| [par-jobs-v1](briefs/par-jobs-v1.md) | landed 2026-08-21 |
| [hist-v1](briefs/hist-v1.md) | superseded → probe-v1 (primitives) + session-host-v1 (index) |
| [session-host-v1](briefs/session-host-v1.md) | filed, not started; parallel track |
| [xq-v1](briefs/xq-v1.md) | filed, not started; depends on par-jobs-v1 |
| [rg-wrapper-v1](briefs/rg-wrapper-v1.md) | filed, not started; depends on par-jobs-v1, xq-v1 |
