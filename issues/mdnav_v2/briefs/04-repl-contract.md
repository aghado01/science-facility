# Phase 04 — exports, REPL/paging/budget contract

> **Role:** execution-ready spec for roadmap milestone **M5a** (the
> settled, mechanical half of M5). Canon is
> [mdnav_v2_design-brief.md](../design/mdnav_v2_design-brief.md). Sequencing/decisions in
> [planning/roadmap.md](../planning/roadmap.md) /
> [planning/decisions.md](../planning/decisions.md). Amend; do not fork.

**Depends on:** [03-containment-queries.md](03-containment-queries.md)
(Selection/queries must exist to page and budget over). **Delivers:** gates
15, 17, 18, 19, 20 — exports, paging, and budgets, all internal to mdnav.
**Sibling phase:** [05-framing-p0.md](05-framing-p0.md) (M5b,
framing/sigils — the newer, less-settled part of the design, developed with
para-agent's trajectory in mind per D37; can run before, after, or
alongside this phase once M4 is done).

## Export surface (the MCP foundation)

`mdnav.mjs` gains named exports — `Corpus` (open a work-dir with a store;
`discover`, `doc(ref)`, `invalidate`), `Doc` (`buf`, `digest`, `claims`,
`select(pred)`, `partition(basis, policy)`, `relations(name)`), `SpanSet`,
`Selection`, `loadRules`, `loadProfile`, `materialize(doc, spans, policy)`,
`Ledger` — object-shaped so a server holds one `Corpus` for the process and
CLI verbs open-query-close — and the top-level CLI dispatch (last five lines
today: `parseArgs` → `VERBS[verb](args)`) moves under an `if (isMain)` guard
keyed on `import.meta.url` vs `process.argv[1]`. **There is no guard and no
export today; `import()` runs the CLI.** After this, `server.mjs` (a later,
separate brief per roadmap) imports in-process, and MCP tools are thin:
`mdnav_query({doc, kind, within, profile})` is a Selection; `mdnav_read` is
a projection.

## Front-end grammar (constraint on this brief; the server brief owns it)

The model for the MCP tool surface is already running in
`science-facility/mcp/nushell-mcp`: `nu-skills` and `nu-modules` expose one
small verb grammar with **typed, pure-content returns** —
`list → table`, `read <x> → string` (raw), `search <re> → table` of hits,
`inspect <x> → table` (signature + one doc line), `status → record` — and
the discipline is **progressive disclosure**: index first, one item on
demand, search across, never preload. Three layers: Claude adapter skill →
augmentation layer (config + modules) → native server. mdnav maps onto it
almost verb-for-verb today (`discover`≈list, `outline`≈inspect,
`read`≈read, `locate`≈search, `profile`/`coverage`≈status, `marks`≈a typed
list), so the backend contract is: **every query returns either literal
source bytes or a flat table/record of claims and anchors — never prose,
never a summary, never a recommendation beyond stderr triage.** The exports
above must make that shape natural for `server.mjs`; if a verb's result
cannot be expressed as bytes-or-table, that is a design smell to report.

## Agent context hygiene — the REPL contract

What is being built is a **Markdown-documents REPL for an agent**: a
persistent session over a corpus, small typed calls, results held
server-side and sliced on demand. The scarce resource is the *caller's*
context, and a tool surface that can only answer by inlining is useless
however good the engine is. The model is `nu --mcp` as used from this
harness: every evaluation returns a bounded record, the full value is kept
in `$history.N`, and the caller pages it afterward. mdnav's rule becomes:
**a query never inlines more than the caller's budget; everything else is a
handle.** Backend obligations (the server brief owns tool names and the
session store; the engine must make these natural):

- **Every query is paged and counted.** `select`, `partition`, `relations`,
  `locate`, `marks` take `{limit, offset, columns}` and return `{total,
  rows}`; `total` is always present, rows only up to `limit`. Values are
  plain arrays of records so a session store can hold and re-slice them
  without recompute; queries are memoized by `(digest, policy, args)` so
  re-asking is free.
- **`materialize` takes a budget and can answer with a plan.** `{maxBytes}`
  is a first-class argument (CLI: `--max-bytes`, default generous; MCP
  default small, e.g. 8 KiB). Over budget it returns **no bytes** — instead
  `{bytes, spans, elided, anchors, suggestion}`: the plan the caller would
  have paid for, with the anchors to narrow by (`--depth`, `--enter`,
  `--only`, `--strip`, a smaller `--within`). Today's ">64 KiB stderr warn
  before writing" is the seed; the MCP form refuses rather than warns,
  because once bytes are in context the cost is paid.
  **Budgets count emitted bytes, headers included.** `maxBytes` is compared
  against the total the framer will actually write (header lines plus every
  `content_bytes`) — never against payload alone; the plan reports both
  `payload` and `framed` totals. The exact byte arithmetic for headers is
  [05-framing-p0.md](05-framing-p0.md)'s concern (the header shape isn't
  frozen yet); this phase's `materialize`/plan contract must accept a
  `framed` total as an opaque number supplied by whatever framer is active,
  not assume a specific header format.
- **Bytes-or-table, never both.** A read result is bytes plus a one-line
  stderr-style `note`; a table result is rows plus `total`; a `record` for
  status. No prose, no summaries, no recommendations beyond `suggestion`
  in a plan.
- **Anchors are the agent's memory, not bytes.** The ledger already makes a
  set of anchors a re-readable batch; expose `coverage` and `reads` so an
  agent — or a post-compaction agent — can see what has been ingested and
  re-read by anchor rather than carrying content. `@digest` on anchors turns
  a stale note into a warning, not wrong content. Notes should hold
  `D003:H0002@1281`, not paragraphs.
- **Previews are bounded by construction.** `outline --preview N`,
  `locate` snippets ≤ 120 chars, `marks --preview` all cap at the engine, not
  the presenter; `truncate` on titles likewise. A table row is never allowed
  to smuggle a body.
- **Session state makes calls short.** Current corpus, run, profile,
  default budget, and "current document" (`cd`-like) live in the session so
  a call is `outline H0007 --depth 2`, not a repeat of the world. Result
  handles (`$r3`) can be passed back as inputs (`read $r3.anchors`,
  `select --within $r3`) so an investigation composes without re-inlining.
- **Diagnostics stay out of band.** stderr today; a small `notes[]` field in
  MCP results, never mixed into rows or bytes.

## Vendoring

mdnav 2.0 is expected to become an internally vendored MCP subsystem of
para-agent, as `nushell-mcp` will. Constraints that follow: the engine stays
single-file zero-dep; the server is an embeddable `createMdnavTools({
corpus, session, framing })` plus a thin standalone stdio runner, so
para-agent can mount it in-process and supply its own session/result store;
result handles and addresses are plain data that can sit in a para-agent
transcript row (`e17.tool.3 → D002:H0108@fa8a`), giving cross-reference
between exchange addresses and document addresses for free.

## Implementation notes

1. **`isMain` guard on Windows.** `import.meta.url` is `file:///D:/…` with
   forward slashes; `process.argv[1]` is `D:\…` and the drive letter's case
   is whatever the caller typed (`mdnav.ps1` passes `Join-Path $PSScriptRoot
   'mdnav.mjs'`). Compare `realpathSync.native(fileURLToPath(import.meta.url))`
   against `realpathSync.native(resolve(process.argv[1]))`, case-insensitively
   on `win32`. Test 15 must run through the `.ps1` wrapper as well as bare
   `node`.

## Exit gate (this phase)

Full text is the master list in [mdnav_v2_design-brief.md](../design/mdnav_v2_design-brief.md)
§Exit gate. This phase closes:

- **15.** `node -e "import('./mdnav.mjs').then(m => m.SpanSet && m.Selection)"`
  resolves without running the CLI.
- **17.** `select`/`partition`/`marks` honour `limit/offset` and always
  return `total`.
- **18.** `materialize` over `maxBytes` returns a plan with zero bytes and
  anchors that, followed, produce a within-budget read.
- **19.** No table query can return a field longer than the preview cap.
- **20.** CLI exposes `--max-bytes` and `--limit/--offset` so the one-shot
  path has the same discipline.

## Sequencing (within this phase)

7 (first half). Exports + guard (gate 15), paging/budget contract (gates
17–20), docs (F3 — README gains the REPL/budget rules).

## Report

_(appended by the implementing agent on completion — what shipped, assert
counts before/after, the default MCP budget number proposed from measured
reads (D26), and whether the export surface stayed thin enough for
`server.mjs` to be a genuinely separate brief.)_
