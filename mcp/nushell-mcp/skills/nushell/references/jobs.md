# `par` / `jobs` — budgeted fan-out on the persistent console

Agent console **is** this REPL. Write pipelines; do not generate strings to eval.

Design center: interactive fan-out (and a **single** `jobs spawn` at parallelism 1). Non-blocking + payload quarantine is the product; parallelism is a feature on top. `rg` finds *where* (do not shard it through `par` for speed). `par` judges *what*.

Two modules, preloaded (`use par *; use jobs *` in `config.nu`). MATLAB / vscodepilot **names** (`parfor`, `parfeval`, `getJobResults`, …) are a corpus map only — they are not exported.

## Native vs this layer

| Native | Hostile bit | Use instead |
|---|---|---|
| `par-each --threads N` | honor-system; completion order is not identity | `par` (budgeted grant, closed row shape, default `--keep-order`) |
| `job spawn` / `job send` / `job recv` | recv takes no id; tags are ints; main thread is `0` | `jobs spawn` / `list` / `collect` / `inspect` / `read` |
| `job kill` | no registry stamp | `jobs cancel` (stamps `cancelled` + `finished`) |

Native `par-each --threads` bypasses policy. Do not monkey-patch the builtin. Do not `job send`/`recv` the module mailbox (`0x4A4F4253`).

Nested oversubscribe: a spawned closure that itself calls `par` can oversubscribe. Policy is enforced at REPL dispatch only. No `$env` mutex from job threads.

## `par` — data plane (values, no handles)

```
$in | par {|row| ... } [--threads N] [--no-keep-order]
```

- `--threads` is a **request** (MaxWorkers), not a grant. `par budget` resolves it.
- Default `--keep-order`. Opt out with `--no-keep-order`.
- Fail-soft: one dead item is a row (`ok: false`); later items still run. No fail-fast.
- Empty input → empty table. `index` is 0-based input position.
- Large maps: `jobs spawn { $data | par {|row| ...} }` then `inspect`/`read`. v1 does not auto-promote.

Row shape, input order:

```
{index: int, ok: bool, item: any, value: any, error: string?, elapsed: duration?}
```

`par budget <items> [--threads] [--cores] …` is pure (testable). Returns `{grant, ceiling, cores, graded, clamped, warning}`.

`par emit` wraps a findings table in the query envelope (below). Built for wrappers. Over cap it omits `findings` and stores nothing — in the foreground prefer `jobs emit`, which stashes the full table under a tag you can `jobs read`.

## `jobs` — handle plane (receipts until one `read`)

| Verb | Returns |
|---|---|
| `jobs spawn { ... } --tag <string>` | running receipt, or `{ok: false, error: "budget", budget}` |
| `jobs list` | all receipts, **seq** order. No payloads |
| `jobs collect [--timeout 5sec]` | finished receipts only (`completed\|failed\|cancelled`), seq order |
| `jobs inspect <id\|tag>` | shape/census, never body |
| `jobs read <id\|tag>` | **one** payload (peek, not pop) |
| `jobs cancel <id>` | `{job_id, cancelled}` |
| `jobs status` | knobs, cores, ceiling, inflight, policy |
| `jobs policy --max-workers N …` | mutate session knobs; still clamped |
| `$v \| jobs stash [--tag t]` | store any value as a completed-on-arrival row (`job_id: null`); receipt back, `read` later |
| `$findings \| jobs emit [--tag t]` | `par emit` + stash when truncated; envelope gains `tag` only if stored |

Receipt (no `output` column):

```
{seq, tag, job_id, ok, status, bytes, type, length, error, started, finished, elapsed}
```

`status`: `pending | running | completed | failed | cancelled`. Budget refusal is **not** a job row.

- Registry: `$env.JOBS`, append-only `seq` 0,1,2,…. Duplicate `tag` → refuse. Dies with the MCP child.
- Every mutating verb is `def --env` so the write survives the next `evaluate`.
- `collect` never `job recv` without timeout. `0sec` drains ready; default `5sec` is a short bound. Partial = what's done.
- At inflight ≥ ceiling: **refuse**. Do not block `evaluate` for a slot.
- `jobs spawn` uses ceiling only (each job = 1 inflight). `par` grades by item count.
- Census (`bytes`/`type`/`length`) is NUON byte length / `describe` / list length, computed **once at drain**.
- `list`/`collect` drain the mailbox **first**, then mark vanished (`error: "vanished"`) if absent from native `job list` with no pending message.
- `cancel` stamps the row; a killed job never hits the wrapper `catch`.

## Result hygiene

One tool result never contains more than **one** payload. `collect`/`list`/`inspect` are receipts. `jobs read` is one body. Do not loop `read` over tags in one `evaluate`.

Query / search consumers return **findings + metadata**, not a receipt table of workers:

1. Foreground: `$data | par {|row| query $row }` — the row table **is** findings.
2. Flatten hits inside `value` **by `index`**, then in-list order. Not completion order.
3. One background job: `jobs spawn { $data | par {|row| query $row} }` then `jobs read` **once**.
4. Envelope (`par emit` / wrapper contract):

```
{ok, n, n_ok, n_err, elapsed, bytes, truncated, findings?}
```

`findings` present iff `truncated == false`. Cap is `max_inline_bytes` (JSON `null` → this process's `NU_MCP_OUTPUT_LIMIT`).

## Policy

Facts (once per MCP start): `sys cpu | get name | length`, else Windows `NUMBER_OF_PROCESSORS`, else fail closed. Do not mint `NU_CORES`.

Knobs: `modules/par/policy.json` (`max_workers` null = auto, `reserved_cores` 2, `min_items_per_worker` 4, `max_inline_bytes` null). Sticky `$env.NU_PAR`. `jobs policy` is session-scoped and never writes the JSON back.

Grant: `min(ceiling, ceil(items / K), items)`, at least 1. Explicit `--threads` / `max_workers` clamps to logical cores + warning; it does not win.

## Persistence (v1: none)

Registry and `$history` die with the MCP child. When a store appears later: identity in the path (`<store>-<session-id>[-<agent-id>].<ext>`), routed by the **caller** at spawn — the MCP never self-derives identity. No generic filenames.

## Name map (do not export)

| MATLAB / vscodepilot | this layer |
|---|---|
| `parfor` / `parforeach` | `par` |
| `parfeval` / `startParallelJob` | `jobs spawn --tag` |
| `fetchOutputs` / `getJobResults` | `jobs collect` (receipts) then `jobs read` (one body) |
| `cancel` / `job kill` | `jobs cancel` |
| `parwhile` / `paruntil` / FileHash batches | not v1 |
| `gcp` / batch / `%TEMP%` jsonl | not v1 |
