# composition v1 — outcomes and payload ownership

**Status:** landed 2026-08-23 · **Filed:** 2026-08-23 · **Home:**
`mcp/nushell-mcp/modules/core`, Nu-native dependency units consumed by
`par`, `jobs`, `dataspection`, `xq`, and `rg`.
**Amends:** [par-jobs-v1](../.archive/briefs/par-jobs-v1.md),
[dataspection-v1](../.archive/briefs/dataspection-v1.md),
[layering-v1](../.archive/briefs/layering-v1.md),
[xq-v1](xq-v1.md), and [rg-wrapper-v1](rg-wrapper-v1.md).
**Unblocks:** [gh-v1](gh-v1.md) and the first parallel query-envelope
consumers in the [roadmap](../roadmap.md).
**Not this brief:** host-side result interpretation, a second registry,
timeouts, binary rg finding support, or changes to the MCP transport.

Treat this file as the cross-cutting composition spec. The amended
command briefs remain canonical for their local shapes. Where a landed
v1 brief predicts a tag, equates `ok` only with a child exit code, or
uses `(job id) != 0` as the whole storage-owner test, this brief controls
until those local sections are reconciled on landing.

## Problem

Failure-as-data works at one command boundary but is not yet
compositional:

- `par` and `jobs spawn` call every non-throwing closure successful,
  even when a custom Nushell command returns `{ok: false, ...}`.
- A background job that returns a failed command envelope is recorded
  as `status: completed, ok: true`; the failure is visible only after
  disclosing its payload.
- `xq`, `rg`, and `jobs emit` synthesize a retrieval tag before they
  know that `jobs stash` succeeded. A collision can make the tag name
  an unrelated existing payload.
- A `par-each` worker has `job id == 0`, but its environment mutation
  does not propagate. A worker can therefore report a successful stash
  that the foreground registry never receives.
- `complete` may return binary streams. Treating a failed string byte
  count as zero bypasses the disclosure cap.

The repair is one return-path contract: summarize declared outcomes
without discarding their values; make lifecycle and domain success
separate facts; let only the persistent foreground context mutate the
registry; and count the stream value actually returned.

## `ok` boundary

`ok` is universal on an **outcome-bearing boundary**: an operation
result, receipt, envelope, or outcome row. It is not injected into
arbitrary payload records, rg findings, census sub-records, budget
records, or a `meta` sub-record merely because they are records.

An expected domain failure is a successful Nushell evaluation whose
returned outcome carries `ok: false`. It remains in `$history`. An
uncaught engine failure throws, leaves no `$history` entry, and is a
different level. The host preserves that distinction as
`exit.ok: true` with returned `data.ok: false`; it does not interpret
the Nu value further.

## Outcome projection

`core/outcome.nu` will provide one internal projection used by `par`
and `jobs`. It does not alter or wrap the value.

The projection is shallow and closed:

1. A top-level record with boolean `ok` declares an outcome. Preserve
   its `ok`; on failure use its string `error`, or the short fallback
   `"failed"`.
2. A non-empty top-level table/list declares an aggregate outcome only
   when every row is a record with boolean `ok`. Aggregate with `all`.
   On failure the short outer error is `"<n> of <total> failed"`; the
   original rows retain the detailed errors.
3. An empty table and any value without that closed convention declare
   no outcome and are successful ordinary values.
4. Do not recurse into arbitrary fields such as `value`, `findings`, or
   `meta`. Callers retain the original value so a declared failure is
   never reduced to its summary.

The internal projection may expose `{declared, ok, error}` to its
module consumers. It is not re-exported through the dataspection
façade or preloaded into the agent surface.

## `par` composition

The public row shape remains:

```nu
{index: int, ok: bool, item: any, value: any, error: string?, elapsed: duration}
```

| Closure result | Row |
|---|---|
| throws | `ok: false`, `value: null`, caught short `error` |
| returns a declared failure record | `ok: false`, original record in `value`, lifted short `error` |
| returns a declared outcome table with failures | `ok: false`, original table in `value`, aggregate short `error` |
| returns a declared success or ordinary value | `ok: true`, original value, `error: null` |

Every input still produces one row. A returned failure never throws,
cancels siblings, creates a hole, or changes keep-order behavior.

## `jobs` composition

`status` is execution lifecycle; `ok` is the stored operation outcome.
They are related but not synonyms.

| Closure result | Registry row |
|---|---|
| throws or vanishes before returning | `status: failed`, `ok: false`, `output: null` |
| is cancelled | `status: cancelled`, `ok: false`, `output: null` |
| returns a declared failure | `status: completed`, `ok: false`, original `output` retained |
| returns a declared success or ordinary value | `status: completed`, `ok: true`, original `output` retained |

`jobs read` / `jobs fetch` gate disclosure on `status: completed`, not
on `ok`. A completed domain-failure payload is therefore inspectable
and fetchable. A failed/cancelled execution has no payload and keeps
the N15 failure receipt.

Completed-on-arrival `jobs stash` rows report whether the storage
operation succeeded; they do not reinterpret an arbitrary stored
payload as work that the registry executed.

Missing or non-running `jobs cancel` is an expected failed operation:
`{ok: false, cancelled: false, error, ...}`. A successful cancellation
is `{ok: true, cancelled: true, ...}`.

## Execution context and registry ownership

`core/execution.nu` will describe the current Nu execution context for
module consumers. It imports no higher layer. `par` carries an internal
marker into its workers, including whether the enclosing dispatch is
already inside a background job. The marker name is implementation,
not launch surface or agent vocabulary.

There are three payload-owner cases:

| Context | Over-cap behavior |
|---|---|
| foreground registry owner | stash through `jobs`, then return the verified tag |
| background job, including `par` nested in it | return the full value to the outer job; create no nested stash |
| foreground `par` worker | return `ok: false`, no tag, keep the batch running; direct the agent to wrap the dispatch in `jobs spawn` |

Only the persistent foreground context may mutate `$env.JOBS`.
Registry-mutating commands such as `jobs spawn`, `jobs stash`, and
`jobs cancel` fail as data in a non-owning context. Registry reads may
inspect the inherited snapshot but must not claim that a local harvest
or mutation persisted.

The context rule applies to every current quarantine caller:

- in-hand `read`;
- `jobs emit`;
- `xq`;
- both `rg` return modes.

Inside an outer background job, these commands return their full value
to that job even when it exceeds `par cap`; the job row is the payload
quarantine. In a foreground worker with no owner, they fail closed
rather than publish an irretrievable address or disclose an unbounded
value.

## Registry-allocated tags

Exact caller naming remains:

```nu
$payload | jobs stash --tag $tag
```

Generated naming becomes registry-owned:

```nu
$payload | jobs stash --prefix "xq:nu"
```

- `--tag` and `--prefix` are mutually exclusive.
- Exact duplicate tags return `ok: false`; no new row is stored.
- With `--prefix`, `jobs` selects a unique human-readable tag inside
  the same foreground mutation that appends the row.
- The receipt returns the actual tag. Callers do not predict it, derive
  it from `jobs list | length`, or assume its suffix equals registry
  `seq`.
- A caller envelope inserts `tag` only when the stash receipt confirms
  storage. Stash failure makes the caller outcome `ok: false` and
  publishes no retrieval tag.
- Generated retrieval text renders the confirmed tag as NUON.

`xq`, `rg`, and `jobs emit` use `--prefix`; in-hand `read` may use the
default generated namespace. The registry remains the single storage
surface.

## Capture and stream values

`core/stream.nu` will own terminal stream measurement, distinct from
dataspection's `bytes` field:

- string → UTF-8 byte length;
- binary → binary byte length;
- anything else → `ok: false`, never zero by catch fallback.

`stdout_bytes` and `stderr_bytes` use that definition. They are not
the NUON size named by the unqualified `bytes` census field.

`process capture` returns a closed capture outcome:

```nu
{ok: bool, cmd: string, args: list, stdout: string|binary,
 stderr: string|binary, exit_code: int?, elapsed: duration,
 error?: string, trace?: string}
```

`ok` says whether capture itself ran. A captured child exit code may be
non-zero while capture is `ok: true`. Missing/non-executable/spawn
failures preserve their actual short error and trace; they are not all
relabeled `not found`. `cmd` and forwarded `args` remain present on
both paths.

`xq.ok` is the terminal command outcome: capture succeeded, the child
exit code is zero, and any required payload quarantine succeeded.
`exit_code` preserves the child fact. `rg.ok` accepts ripgrep exit 0 or
1 only when capture, interpretation, and required quarantine also
succeed.

Ripgrep JSON may carry `path.bytes` or `lines.bytes`. This cut fails
that result explicitly as unsupported encoding instead of emitting an
empty `file` or `match`. A byte-backed finding schema is deferred until
a consumer requires one.

## Layering

Planned internal file units:

```text
modules/core/outcome.nu    # declared outcome projection
modules/core/execution.nu  # job/worker/registry-owner context
modules/core/stream.nu     # string/binary terminal stream measurement
```

They have no `main`, are imported by name at module scope, and are not
re-exported by `dataspection/mod.nu`. None imports `par`, `jobs`,
`dataspection`, `xq`, or `rg`, so layering A remains acyclic.

## Tests

New child suite `tests/composition-v1.nu`, plus local regression cases:

- `par`: thrown failure, returned record failure, returned mixed table,
  ordinary value; every sibling remains and returned failures retain
  their value;
- `jobs spawn`: returned domain failure is `completed + ok:false` and
  fetchable; thrown failure is `failed + ok:false` with no payload;
- `jobs spawn { ... | par ... }`: mixed rows aggregate to `ok:false`
  while the full table remains fetchable;
- exact duplicate stash remains failure data; pre-seeded future-looking
  `xq:*`, `rg:*`, and `emit:*` names cannot misroute generated tags;
- foreground worker over-cap calls return failure rows with no tag;
  the same dispatch inside one outer job creates exactly one registry
  row and retains all child results;
- binary stdout larger than cap is stashed and fetched byte-for-byte;
- byte-backed rg JSON is explicit failure, never `match: ""`;
- missing/non-running cancellation has `ok: false`;
- suite failure exits non-zero at the child-process level.

Regression gates remain dataspection, par/jobs, xq, and rg suites,
config-loaded external-cwd smoke, all core units loading, and no new
internal command leaking into the agent surface.

## Rollout

1. Outcome cut: `core/outcome.nu`; `par` / `jobs` composition and
   cancellation semantics.
2. Ownership cut: `core/execution.nu`; registry allocation; migrate
   `read`, `jobs emit`, `xq`, and `rg`.
3. Stream cut: `core/stream.nu`; capture, xq binary sizing, rg encoding
   failure.
4. Reconcile docstrings, corpus pages, and all three client adapters in
   each landing commit. Append follow-up reports with test evidence.

`gh-v1` and roadmap query-envelope consumers wait for all three cuts.
Session-host-v1 may proceed in parallel because it relays Nu values and
keeps engine `exit.ok` separate from returned data; it gains one
acceptance case for `exit.ok: true` plus returned `data.ok: false`.

## Non-goals

- Recursive interpretation of arbitrary nested values
- Host or TypeScript understanding of Nu outcomes
- A new public command or MCP tool
- A second store or worker-owned registry
- Predictable generated tag suffixes
- Byte-backed rg finding rows in this cut
- Turning domain failures back into throws

## Follow-up report

- **2026-08-23 — stream cut.** `modules/core/stream.nu`. Capture `ok: true` on
  successful spawn; missing-binary normalized from error+trace; xq sizes
  string/binary via `stream bytes` and stashes exact bytes; rg fails closed
  on binary streams and `path.bytes`/`lines.bytes`. Child tests:
  composition-v1 31/31 plus regressions. N18 landed. Brief landed.
- **2026-08-23 — ownership cut.** `modules/core/execution.nu`. `par` wraps
  `par-each` in `with-env` (`NU_EXEC_WORKER` / `NU_EXEC_IN_JOB`). `jobs`
  harvest/drain refuse off-owner; `stash --prefix` allocates `$prefix:<n>`
  against existing tags. `xq`, `rg`, `read`, `jobs emit` follow the three-context
  table. Child tests: composition-v1 27/27 plus regressions. N17 landed.
  Stream cut remains.
- **2026-08-23 — outcome cut.** `modules/core/outcome.nu` (`outcome project`:
  record / outcome table-or-list, no recursion). `par` lifts returned
  `{ok: false}` and outcome tables onto the row while retaining `value`
  (tag / retrieve / meta). `jobs spawn` packer uses `returned`; harvest
  is `status: completed` + `ok` from the projection, payload fetchable.
  Throw/vanish stay `status: failed` with no payload. `jobs stash` does
  not project stored values. `jobs cancel` is `{ok, cancelled, job_id}`
  on every path. Child tests: composition-v1 20/20, par-jobs-v1 29/29,
  dataspection-v1 13/13, xq-v1 8/8, rg-v1 13/13. N16 landed. Ownership
  and stream cuts remain.
