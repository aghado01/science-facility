# `par` / `jobs` v1 — agent parallelism in nushell-mcp

**Status:** filed, not started · **Filed:** 2026-08-21 · **Home:**
`mcp/nushell-mcp`, Nu-native modules, used only through `evaluate`.
**Prior art (shape, not code):** vscodepilot `parallel-tools.ts` job
lifecycle; colonel `Resolve-WorkerBudget` + sticky knobs.
**Not this brief:** session daemon, extra MCP tools, para-agent mux,
`PARA_NU_BIN`, visitor-MCP loading.

Treat this file as the v1 spec. Amend; do not fork.

## Problem

- Native `par-each` / `job *` exist but are hostile to an agent (`job recv`
  takes no id; tags are ints; main thread is `0`; `--threads` is honor-system).
- vscodepilot solved this in PowerShell with RunspacePool + signal files + a
  TypeScript host. Wrong runtime here.
- Colonel’s useful piece is **allocation policy**, not the pool.

## Layers (do not collapse)

| Layer | Owns | v1? |
|---|---|---|
| `nu --mcp` REPL | persistent engine, `$history`, auto-promote | given |
| `par` + `jobs` | data-plane map + handle-plane, budget | **this** |
| Session daemon | isolation, jobs that outlive the MCP child | later |
| para-agent visitor grant | admit this MCP to a participant | later, same verbs |

Agent console **is** this REPL. Do not generate PowerShell/Nu **strings** to
eval; the agent writes pipelines. para-agent JSON-RPC is a PTY console
(receipts/bytes), a different surface.

## Two modules

MATLAB/vscodepilot **names** (`parfor`, `parforeach`, `parwhile`, …) are a
corpus map only. Do not export them.

### `par` — data plane

Pipeline in, table out, **no handles**. One command:

```
$in | par try {|row| ... } [--threads N] [--no-keep-order]
```

- Wraps `par-each`. `--threads` is a **request** (`MaxWorkers` for this
  dispatch), not a grant.
- **Default `--keep-order`.** Completion order is not a result. Opt out with
  `--no-keep-order` (not the agent default).
- Row shape and order: see **Shapes and order**.
- Grant applied internally via `resolve-budget` (item count = `$in | length`).

Export `par budget` (pure; testable). `jobs` calls it. No third “colonel”
module.

### `jobs` — handle plane

vscodepilot TS API as Nu verbs. Hide mailbox protocol.

| Verb | Returns |
|---|---|
| `jobs spawn { ... } --tag <string>` | receipt `{tag, job_id, status: running}` or budget-failure row |
| `jobs list` | receipt table: tag, job_id, status, + native `job list` fields. **No payloads.** |
| `jobs collect --timeout <duration>` | receipt table of *finished* jobs (see below). Still-running stay on `list` |
| `jobs inspect <id\|tag>` | shape only: `{tag, job_id, ok, type, length, bytes, columns?}` |
| `jobs read <id\|tag>` | **one** payload. MCP `$history` / `NU_MCP_OUTPUT_LIMIT` still apply |
| `jobs cancel <id>` | `{job_id, cancelled: bool}` |
| `jobs status` | record: knobs, cores, ceiling, inflight, policy |
| `jobs policy ...` | mutate sticky knobs; still clamped |

Spawn **wraps** the closure (this replaces signal files):

```
job spawn --description $tag {
  try { {tag, ok: true, output: (do $work), error: null} | job send 0 --tag $mbox }
  catch {|e| {tag, ok: false, output: null, error: $e.msg} | job send 0 --tag $mbox }
}
```

- Registry: `$env.JOBS` table, append-only spawn `seq` (0,1,2,…). Lookup by
  `tag` or `job_id`. Duplicate `tag` → refuse. Dies with the MCP child. No
  `%TEMP%`, no JSONL store.
- Fan-out v1: two `jobs spawn` in **one** `evaluate`, later evaluate
  `collect`. No list-of-closures API unless it falls out for free.
- `collect` **never** `job recv` without timeout. Default: drain ready
  (`0sec`) or a short bound (`5sec`). Partial = receipts for what’s done.
- At inflight ≥ ceiling: **refuse** `{ok: false, error: "budget", budget: {...}}`.
  Do not block `evaluate` for a slot.

## Result returns (context hygiene)

`evaluate` **is** injection into the model context. Parallelism that
inlines **N job payloads** in one tool result is a context bug.
vscodepilot `getJobResults` dumping JSONL, and a `collect` that returns
`output` for every tag, are that failure. No synthetic tool results, no
primer stuffing.

**One findings table with metadata is lawful.** That is the query/search
shape: the product *is* the hits, plus census. It is not N bodies. See
**Query / search consumers**.

**Handle plane: receipts only, until an explicit `read` of one id.**

- Payload stays in the `$env.JOBS` registry (in-engine). `collect` drains
  the mailbox into that store, then returns the **projection**. The
  `$history` entry for that `evaluate` is the receipt table only.
- `jobs inspect` = shape, never body.
- `jobs read` = one value (the stored payload, already ordered if it was a
  `par try` table). Native MCP truncation applies (`NU_MCP_OUTPUT_LIMIT`,
  currently 20kb in `.mcp.json`); full value is in `$history.N` for that
  read. Page with ordinary Nu. No `collect --inline`. Direct values: `par
  try`, one `jobs read`, or a query envelope.
- Never `read` in a loop inside one `evaluate` over all tags. That’s
  collect-with-payloads again.

**Data plane (`par try`): values, because it is a pipeline.** Hygiene is
routing, not a second receipt protocol:

- Small maps in the foreground (`1..20 | par try {|i| ...}`) — table is
  the result; native truncation + `$history` paging is the backstop.
- Large maps **must** be `jobs spawn { $data | par try {|row| ...} }`,
  then inspect/read. Corpus states this; v1 does not auto-promote `par try`
  into jobs (that’s magic / daemon-shaped).
- Do not return per-row handles from `par try`.

## Shapes and order

Closed column sets. Extra native fields do not leak onto receipts.
Column order below is the NUON/table order.

Colonel wrote results into a pre-allocated array by **input index** even
when workers finished out of order. Same rule: **identity is index/seq,
not finish time.** Native `par-each` completion order and mailbox FIFO
are implementation accidents; they are not the contract.

`status` closed set: `pending | running | completed | failed | cancelled`.
Budget refusal is not a job row: `{ok: false, error: "budget", budget: record}`.

**Fail-soft is the default.** One failed row or job does not abort the
batch, cancel siblings, or skip later `seq`s. There is no fail-fast flag
in v1; cancel is explicit (`jobs cancel` / `job kill`). Errors are data:
`ok: false` on that object, everyone else still runs and still appears.

Timing is **census**, not payload. Cheap scalars belong on receipts and
`par try` rows. Stacks, streams, and bodies do not.

### `par try` — table, one row per input, **input order**

```
{index: int, ok: bool, item: any, value: any, error: string?,
 elapsed: duration?}
```

- `index` is 0-based position in `$in` (colonel’s slot). Stable even if
  someone later `sort-by ok`.
- Default `par-each --keep-order`. `--no-keep-order` is opt-out only.
- Failed closure: `ok: false`, `value: null`, `error` short (~240 chars),
  `elapsed` still set if work started. The row still occupies `index`. No
  holes, no dropped items, no stop-the-map.
- Empty input → empty table.
- `item` is the input cell (agent needs it to know *which* file failed).
  Large `$in` therefore does not belong in a foreground `par try`.
- `elapsed` is per-item wall time. No `started`/`finished` on map rows
  (N timestamps for a large `$in` is noise; the job receipt carries those).

### Job receipt — `spawn` (record) / `list` / `collect` (table)

```
{seq: int, tag: string, job_id: int, ok: bool, status: string,
 bytes: int?, type: string?, length: int?, error: string?,
 started: datetime, finished: datetime?, elapsed: duration?}
```

- No `output` column.
- `seq` is spawn order (0,1,2,…), assigned on `spawn`, never reused.
- `error` short (~240 chars, first line). Stacks only via `inspect`/`read`.
- `bytes` / `type` / `length` / `finished` / `elapsed` are census (`null`
  while running). `started` is set at spawn.
- `ok: false` + `status: failed|cancelled` is still a **row**. Collect
  includes it in `seq` order next to successes.
- `spawn` returns one receipt (`status: running`, census null except
  `started`).
- `list`: **all** registry rows, sorted by `seq` ascending. Not native
  `job list` order.
- `collect`: **finished** rows only (`completed|failed|cancelled`), still
  sorted by `seq` ascending — **not** mailbox/completion order. Partial
  collect omits running seqs; it does not shuffle the ones that finished
  and does not drop failures.
- Same `job_id` never appears twice after a drain.

### `jobs inspect` — one record, no body

```
{seq, tag, job_id, ok, status, type, length, bytes, columns?: list<string>,
 error?: string, started, finished?, elapsed?}
```

### `jobs read` — the stored value (any)

Order inside a list/table payload is whatever was stored (for `par try`,
that is input order). `read` does not re-sort. One id only.

### `jobs status` — one record (not a table)

Knobs, cores, ceiling, inflight, policy. No job rows.

### `jobs cancel` — `{job_id: int, cancelled: bool}`

### Conservation

- One tool result never contains more than **one** payload (one findings
  table, or one `jobs read`). Never N job `output`s.
- Census before body (`list`/`collect`/`inspect` → optional `read`),
  unless the command *is* a query wrapper returning findings (below).
- Failures are short on receipts; on findings rows they are `ok: false`
  data. Success bodies on the handle plane stay opt-in.
- Parallel **completion** is not parallel **disclosure**.

### Query / search consumers

Tools built **on** `par`/`jobs` (parallel search, shard queries, fan-out
`nu-skills search` over topics, …) should return **findings + metadata**,
not a receipt table of workers.

Lawful:

1. Foreground: `$data | par try {|row| query $row }` — the row table
   **is** findings with metadata (`index`, `ok`, `item`, `value`, `error`,
   `elapsed`). Fail-soft: a dead shard is a row, hits from others still
   present. Input order.
2. Flatten hits inside `value` (e.g. each file returns a list of matches)
   with **deterministic concat**: by `index`, then in-list order. Do not
   concat in completion order.
3. One background job: `jobs spawn { $data | par try {|row| query $row} }`
   then `jobs read` **once**. The stored payload is that findings table.
4. Envelope (preferred for a named query tool):

```
{ok: bool, n: int, n_ok: int, n_err: int, elapsed: duration,
 bytes: int, truncated: bool, findings?: table}
```

   - `findings` present iff `truncated == false`.
   - Truncate on **bytes** (policy `max_inline_bytes`, default = this
     session’s `NU_MCP_OUTPUT_LIMIT`). Over cap: omit `findings`, keep
     census, store the full table (same registry as jobs, or `$history`
     if this `evaluate` *is* the query). Agent pages via `read` /
     `$history`. `truncated: true` is the receipt bit.
   - `n` is finding count (or input rows if you did not flatten). Closed
     envelope; no worker list, no payloads-per-tag.

Unlawful: `collect` of many tagged queries with bodies attached; looping
`read` over tags in one `evaluate`; stuffing stacks into findings rows.

v1 engine implements `par try` (shape 1) and `jobs read` (shape 3). The
envelope (shape 4) is the **contract for wrappers**; a tiny `par emit`
helper may wait until the first query tool needs it. Do not invent
`collect --inline` to paper over (4).

## Policy and discovery

Facts ≠ knobs.

**Facts (once per MCP start):**

1. `sys cpu | get name | length` (portable; this host: 18)
2. else Windows `$env.NUMBER_OF_PROCESSORS | into int`
3. else fail closed with a typed error — do not scrape `/proc` in v1

Do not mint `NU_CORES`. Do not prefer the Windows env when `sys` works.

**Knobs** — JSON next to the module that owns the resolver:

`mcp/nushell-mcp/modules/par/policy.json`

```json
{
  "max_workers": null,
  "reserved_cores": 2,
  "min_items_per_worker": 4,
  "max_inline_bytes": null
}
```

`null` max_workers = auto. `null` max_inline_bytes = this process’s
`NU_MCP_OUTPUT_LIMIT` (20kb in current `.mcp.json`). Collect **ignores**
`max_inline_bytes` (always receipts). Query envelopes **use** it.
Optional later: `$env.NU_PAR_MAX_WORKERS` overrides JSON, still clamped
to discovered cores.

**Resolver** (colonel `Resolve-WorkerBudget`, pure):

- Ceiling: explicit max, else `logical_cores - reserved_cores` (always ≥1 core left).
- Explicit max **clamps** to logical cores + warning; it does not win.
- Grade (maps only): `ceil(item_count / min_items_per_worker)` (default 4).
- Grant: `min(ceiling, graded, item_count)`, at least 1.
- `jobs spawn` uses **ceiling only** (each job = 1 inflight). No item grading.

**Sticky record** `$env.NU_PAR`, frozen in `config.nu` after `use par *`:
`{cores, os, knobs..., ceiling, policy}`. Do not re-probe `sys cpu` on every
spawn.

| Dispatch | ItemCount | Grant |
|---|---|---|
| `par try` | `$in \| length` | full resolver → `par-each --threads $grant` |
| `jobs spawn` | inflight jobs | ceiling; refuse at cap |

Native `par-each --threads` bypasses policy — corpus: use `par try`. Do not
monkey-patch the builtin.

**Nested oversubscribe:** enforce at REPL dispatch only. A spawned closure
that itself calls `par try` can oversubscribe; document it. No `$env` mutex
from job threads in v1.

`InitThreads` (colonel bootstrap cap) is **not** this object. Revisit only if
discovery probes go parallel.

## Tree

```
mcp/nushell-mcp/modules/par/
  mod.nu              # par try, par budget, host discovery
  policy.json         # knobs
mcp/nushell-mcp/modules/jobs/
  mod.nu              # spawn list collect inspect read cancel status policy
mcp/nushell-mcp/skills/nushell/references/jobs.md
  native job/par-each, module verbs, vscodepilot/MATLAB name map
config.nu             # load JSON + discover once; use par *; use jobs *
```

Preload both. This is the point of the augmentation, same as `nu-skills`.

## Tests (child `nu -n`)

Budget table (cores=16, reserved=2, min_items=4):

| items | threads |
|---|---|
| 1, 4 | 1 |
| 8 | 2 |
| 20 | 5 |
| 60, 200 | 14 |

- explicit 32 → clamp 16 + warning
- explicit 1, items 200 → 1
- `par try` with one failing item: both rows present, `ok` mixed, `index`
  0..n-1 in order (`[3,1,2] | par try {|x| if $x == 1 { error make {msg: 'x'} } else { $x }}` →
  index 0,1,2 with middle `ok: false`); later items still have `value`
- two jobs, first errors: `collect` has **both** receipts in `seq` order;
  `ok` mixed; the success is `read`able; the failure has `finished`/`elapsed`
  and short `error`; sibling was not cancelled
- `par try` order matches input even when work times differ (sleep in the
  first item; still index 0 first)
- two tagged `jobs spawn` (slow first, fast second), `collect` → two-row
  **receipt** table in **seq order** (slow tag still row 0), no `output`
  column; `bytes`/`type` present
- `jobs read` of one tag returns the value; the other payload is not in
  that evaluate’s return
- `jobs inspect` has no body
- flatten-by-index: two inputs whose `value` is a list of hits concat in
  `index` order, not finish order
- query envelope over cap: `truncated: true`, no `findings`, census present
- `collect --timeout 0sec` does not hang
- `jobs spawn` × (ceiling+1) in one eval: last row budget-fail; inflight ≤ ceiling
- cancel then list

## Exit gate

Three `evaluate`s: `jobs spawn { 1..8 | par try {|i| $i * $i} } --tag sq` →
receipt; `jobs collect` → receipt with `ok`/`bytes`/`type`, **no values**;
`jobs read sq` → the table (or `$history` page). No `job send`/`recv`, no
signal files, no MATLAB names. `jobs status` shows cores + knobs. Inflight
never exceeds ceiling.

## Non-goals (v1)

- Extra MCP tools (`nushell__startParallelJob`, …)
- Signal files / `jobs.jsonl` / `%TEMP%`
- Process isolation / daemon / JSON-RPC supervisor
- `parwhile` / `paruntil` / canned FileHash-style batches
- Sharing engine, config, or job table with `PARA_NU_BIN` panes
- Queueing at cap (daemon)
- Parallel `evaluate` (races one stack)
- `collect --inline` / dumping **N** job payloads in one result
- Synthetic tool results or host-side body injection into the chat
- Forbidding a query tool from returning **one** findings table + census
- Returning collect/list in completion or mailbox order
- Open receipt shapes (leaking raw `job list` columns)
- Fail-fast / cancel-siblings-on-error
- Per-item `started`/`finished` on `par try` rows

---

## Follow-up report

_Chip or implementer: append outcome, tests run, deviations from this spec._
