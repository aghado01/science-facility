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

## Sequence

1. **`par` / `jobs` v1** — [briefs/par-jobs-v1.md](briefs/par-jobs-v1.md)
   · landed 2026-08-21. Data plane + handle plane + budget on the
   persistent engine. Carries the envelope contract (shape 4) and the
   registry mechanics.
2. **`rg` wrapper v1** — [briefs/rg-wrapper-v1.md](briefs/rg-wrapper-v1.md)
   · filed, not started; depends on 1. First envelope consumer (at
   parallelism 1): pass-through query side, `--json` rows,
   spine-on-truncation, registry storage via `jobs stash` (landed
   2026-08-21 with the review fix; the owed amendment is paid).
3. **Query tools on the envelope** — mdnav_v2 chunk shards, `nu-skills
   search` fan-out. First real parallelism consumers; `par emit` shipped
   with par-jobs-v1. Align the chunk shape with mdnav_v2's brief rather
   than inventing twice.
4. **Session layer / daemon** — later. Scoped per-agent history
   (standard issue), identity plumbing exercised for real, jobs that
   outlive the MCP child, queueing at cap, process isolation.
5. **para-agent visitor grant** — later. Admit this MCP to a
   participant; same verbs, no new surface.

## Briefs

| Brief | Status |
|---|---|
| [par-jobs-v1](briefs/par-jobs-v1.md) | landed 2026-08-21 |
| [rg-wrapper-v1](briefs/rg-wrapper-v1.md) | filed, not started; depends on par-jobs-v1 |
