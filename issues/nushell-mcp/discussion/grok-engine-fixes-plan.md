# Composition hardening — remaining cuts

**Spec:** [composition-v1](../briefs/composition-v1.md) (canonical).
**Diagnosis:** [sol-engine-fixes.md](sol-engine-fixes.md).
**Review:** [gemini-engine-fixes-plan-review.md](gemini-engine-fixes-plan-review.md) — sequence confirmed; footguns below are constraints, not optional notes.
**Authority when they disagree:** the brief’s three-cut rollout and the pointed commit titles, not the report’s bundling of `execution.nu` into the first implementation commit.

## Product invariant — failure is data, disclosure stays optional

A domain failure must not throw, abort the engine session, or cancel a batch. The call **returns**: the evaluate succeeds, a `$history` entry exists, and the value is an outcome with `ok: false` plus whatever receipt and linking the command already produced (`tag`, `retrieve`, `meta`, `exit_code`, short `error`). The agent opts into the body later (`jobs fetch`, `page`, `preview`) — it is not dumped, and it is not lost.

Two levels, never collapsed:

| Level | What happened | Session | History | Outer facts |
|---|---|---|---|---|
| Engine | uncaught throw | evaluate fails | no `$history` entry | host `exit.ok: false` |
| Domain | command captured a failure | evaluate succeeds | value is in `$history` | host `exit.ok: true`, returned `data.ok: false` |

Composition exists so the second level survives `par` and `jobs`:

- One dead item is a row; siblings still run. One dead job is a receipt; siblings still complete.
- `par` / `jobs` **summarize** `ok` / short `error` on the outer row or registry receipt. They **retain** the original value, including tags and retrieve strings. Projection must not wrap, strip `meta`, or reduce a failure envelope to `{ok: false, error}`.
- `jobs` lifecycle (`status`) stays separate. A returned domain failure is `status: completed` + `ok: false` so `jobs read` / `jobs fetch` still disclose. A throw/vanish is `status: failed` and has no payload — that is the engine-level case inside the job, not a captured tool failure.
- Receipts-before-bodies still holds: `collect` / `list` / `inspect` never include the body. The link on the receipt (`tag`, and `retrieve` on a decline) is how progressive disclosure starts.

This is why today’s harvest bug is load-bearing: mapping “returned `{ok: false}`” onto `status: failed` **drops the payload**, so the failure is no longer inspectable. Commit 2 exists to keep captured failures in the spine.

## Assessment

### Done

`1c9eff5` **nushell-mcp: freeze result composition contract** — docs only.

Landed: `briefs/composition-v1.md`; composition amendments on `xq-v1` / `rg-wrapper-v1` / `gh-v1`; vocabulary (`outcome`, `registry owner`); decisions **N16–N18 carried**; roadmap item **5a**; AGENTS.md rules **4a** and **4c**.

Not landed: no `modules/core/{outcome,execution,stream}.nu`; no engine behavior change. Brief status is still **filed, not landed**. Ledger gained only an archived-path fix, not a freeze entry.

### Still broken in code

| Defect | Where |
|---|---|
| Any non-throwing closure is success, including `{ok: false, …}` | `par/mod.nu` worker; `jobs spawn` packer |
| Harvest maps `msg.ok` onto both `ok` **and** `status` | `jobs-apply`: throw and domain failure both become `status: failed` |
| `jobs cancel` missing/non-running has no `ok` | `{job_id, cancelled: false}` |
| Callers predict tags (`jobs list \| length`, `jobs-next-seq`) and publish `tag` before stash confirms | `xq`, both `rg` branches, `jobs emit`; `read` is closer (uses receipt tag) |
| Payload owner is `(job id) != 0` | `xq`, `rg`. `par-each` workers are `job id == 0`; env mutation does not propagate → phantom tags. `jobs list` inside a worker also **harvests the mailbox** |
| Capture success omits `ok`; every spawn catch is `not found:`; `utf8-bytes` catch → **0** | `core/capture.nu`, `xq`, `rg` |
| Ripgrep `path.bytes` / `lines.bytes` become `file:""` / `match:""` | `rg-parse` |

Existing suites still encode the old contract: `par-jobs-v1` asserts auto-stash tag `stash:1` (suffix = seq); `rg-v1` asserts exact `rg:0` / `rg:1`. Those need loosening in the ownership cut, not before.

### Out of this sequence

- `gh-v1` and roadmap item 6 (blocked until all three cuts are green)
- Session-host work (parallel; add one `exit.ok: true` + `data.ok: false` case when that brief is implemented)
- Byte-backed rg *finding* rows
- Host/TypeScript outcome interpretation
- `sol-nu-core-review.md` — **file does not exist**. N15 already landed as `bb9994b`. Do not block on resurrecting it
- Unrelated dirty `reposnapshot` paths; stage named nushell-mcp paths only
- The untracked `issues/nushell-mcp/discussion/` report is working notes, not a landing artifact

## Approach

Three pointed commits. Tests grow in `tests/composition-v1.nu` (same child-suite shape as `par-jobs-v1.nu`: `t` helper, `error make` on `n_err > 0`). Each commit also updates docstrings, corpus pages, and the three client adapters in the same change.

```text
1c9eff5 freeze (done)
    → commit 2  outcome.nu + par/jobs composition + cancel
    → commit 3  execution.nu + registry-allocated tags + migrate callers
    → commit 4  stream.nu + capture/xq binary + rg encoding failure
    → final gate (all suites, --config smoke, adapter parity, one MCP evaluate)
```

Core units: no `main`, imported by name, **not** re-exported by `dataspection/mod.nu`, import **no** `par`/`jobs`/`dataspection`/`xq`/`rg`.

### Review constraints (do not rediscover)

From the Gemini audit. These are part of the cuts they sit in, not a fourth commit.

| Cut | Constraint |
|---|---|
| 2 | Outcome tables **and** `list<record>` / `list<any>` of outcome rows. `describe =~ '^table'` misses heterogeneous record lists. Project with row `all`, not a type-name prefix. |
| 3 | Worker markers via `with-env`, **not** mutate-and-restore. A throw would leak `$env.NU_EXEC_*` into the caller. |
| 3 | Gate **both** `jobs-harvest` and `jobs-drain` on `owns_registry`. Any internal helper that drains is otherwise a mailbox steal. |
| 3 | Prefix allocation scans **existing tags**, not `seq`. `--tag rg:2` must not make the next generated tag `rg:3` if `rg:0` is free. |
| 3 | `jobs emit` has the same three-context table as `xq`/`rg`. In a job: findings inline, `truncated: false`, no stash. |
| 3 | Foreground-worker over-cap: `ok: false`, **`truncated: false`**, no `tag`. `truncated: true` without a retrieve path is silent omission. |
| 4 | Windows missing-binary errors are often `"The system cannot find the file specified"`. Normalize substrings `not found` / `cannot find` / `executable not found` to `not found: <cmd>`; otherwise keep the raw short error. |

---

## Commit 2 — `nushell-mcp: compose outcomes through par and jobs`

New: `modules/core/outcome.nu`

```nu
# outcome project  →  {declared: bool, ok: bool, error: string?}
```

Shallow, closed:

1. Top-level **record** with boolean `ok` → declared. Preserve `ok`. On failure: string `error` if present, else `"failed"`.
2. Non-empty top-level **table or list** where **every** row is a record with boolean `ok` → aggregate with `all`. Failure error: `"<n> of <total> failed"`. Original rows stay on the caller’s value. Detect rows by walking them, **not** by `describe =~ '^table'`:

```nu
$val | all {|r|
    (($r | describe) | str starts-with "record")
    and ("ok" in ($r | columns))
    and (($r.ok | describe) == "bool")
}
```

   A `list<record>` / `list<any>` of outcome records is an outcome table. A mixed list (record + int) is an ordinary successful value.
3. Empty table/list, or any other value → not declared, `ok: true`, `error: null`.
4. Do **not** recurse into `value` / `findings` / `meta`.

**`par`:** after `do $fn`, project the returned value. Thrown → `ok: false`, `value: null`, short error (no captured envelope — the item died). Returned declared failure → row `ok: false`, lifted short `error`, **`value` is the original record/table unchanged** (`tag`, `retrieve`, `meta`, `exit_code` still there). Ordinary / declared success → `ok: true`. Public row shape unchanged. Fail-soft and keep-order unchanged: a returned failure never throws, never cancels siblings, never punches a hole.

**`jobs spawn` packer:** distinguish throw vs return (today `ok` means “did not throw”). Suggested packed shape: `{tag, returned: bool, output, error}`.

**`jobs-apply`:** throw/vanish → `status: failed`, `ok: false`, `output: null` (nothing to disclose). Returned value → `status: completed`, `ok` from `outcome project`, **output is the original value**. Receipt `error` is the short projection for the spine; the body still carries the detailed envelope. Do **not** project stash payloads: completed-on-arrival rows still report storage success.

**`jobs cancel`:** every path returns `{ok: bool, cancelled: bool, job_id: int, ...}` (missing, non-running, running, and — in commit 3 — non-owner). Missing/non-running → `{ok: false, cancelled: false, error, job_id}`. Success → `{ok: true, cancelled: true, ...}`. Data, not a throw.

`jobs read` / `jobs fetch` already gate on `status: completed`, not `ok` — a captured domain failure stays fetchable. That is the linking path.

### Tests (commit 2)

`tests/composition-v1.nu` starts here:

- `outcome project`: record fail/success; mixed **table**; mixed **list of records** (not a typed table); empty table; ordinary list; mixed list (record + int) is *not* an outcome; nested `ok` inside `value` ignored
- `par`: throw, returned `{ok: false, error, tag, retrieve, meta}`, returned mixed outcome table (original table in `value`), ordinary value; siblings all present; retained failure still has `tag`/`retrieve`/`meta`
- `jobs spawn { {ok: false, error: "x", tag: "t", retrieve: "jobs fetch t"} }`: `status: completed`, `ok: false`, `jobs fetch` returns that record **including** tag/retrieve
- `jobs spawn { [true, false] | par {|x| if $x { 1 } else { {ok: false, error: "no"} } } }`: collect `ok: false`, full table fetchable, both rows present
- thrown job: `status: failed`, `ok: false`, fetch is N15 failure receipt (existing `par-jobs-v1` “two jobs first errors” still covers this)
- `jobs cancel` unknown id and already-completed id: `ok: false`, does not throw

Local: add cancel-missing to `par-jobs-v1`. Do **not** yet assert `jobs spawn { xq missing }` if that belongs more naturally once xq’s envelope is treated as a declared outcome — it *is* a declared outcome today (`xq-fail` has boolean `ok`), so include it here: `status: completed`, `ok: false`, payload fetchable.

### Docs (commit 2)

- `par` / `jobs spawn` / `jobs cancel` docstrings
- `skills/nushell/references/jobs.md` — `status` vs `ok`; cancel carries `ok`
- Client adapters (`~/.claude`, `~/.grok`, `~/.codex` `skills/nushell-mcp/SKILL.md`): one line that returned `{ok: false}` composes through `par`/`jobs` without becoming a throw
- Prepend ledger; composition-v1 follow-up report: outcome cut only
- N16 stays **carried** until commit 4 (or mark N16 landed here and N17/N18 later — prefer landed-per-cut: N16 this commit)

---

## Commit 3 — `nushell-mcp: make jobs authoritative for payload quarantine`

New: `modules/core/execution.nu`

Internal API (names not agent vocabulary; do not document in skills):

- `execution context` → `{kind: "foreground" | "job" | "worker", owns_registry: bool, in_job: bool}`
- `execution worker-env [--in-job]` → the record passed to `with-env` (`NU_EXEC_WORKER: "1"`, `NU_EXEC_IN_JOB: "1"|"0"`)

Detection:

- `(job id) != 0` → `kind: "job"`, `owns_registry: false`, `in_job: true`
- else if `$env.NU_EXEC_WORKER == "1"` → `kind: "worker"`, `owns_registry: false`, `in_job: ($env.NU_EXEC_IN_JOB == "1")`
- else → `kind: "foreground"`, `owns_registry: true`, `in_job: false`

`par` wraps **both** `par-each` paths in `with-env (execution worker-env --in-job $in_job) { ... }`. Compute `$in_job` from `execution context` **before** the wrap (job thread, or already inside a job-owned worker). Do **not** assign `$env.NU_EXEC_*` and restore by hand — a throw leaks the marker into the caller. Nested `par` inside a job still reports `in_job: true` because workers inherit the wrapped env (their own `job id` is 0).

### Registry verbs

- `jobs spawn` / `jobs stash` / `jobs cancel` / `jobs policy` (any `$env.JOBS` or `$env.NU_PAR` mutation): if not owner → stamped `{ok: false, error}`, no mutation. Cancel’s non-owner path is the same closed shape `{ok: false, cancelled: false, job_id, error}`.
- Guard the **entry** of `jobs-harvest` **and** `jobs-drain`: `if not (execution context).owns_registry { return }`. Non-owner `list` / `inspect` / `read` / `fetch` inspect the inherited `$env.JOBS` snapshot only. They must not `job recv`.

### `jobs stash --prefix`

```nu
$payload | jobs stash --tag $tag      # exact; duplicate → ok: false, no row
$payload | jobs stash --prefix "xq:nu"
$payload | jobs stash                 # generated in the `stash` namespace
```

- `--tag` and `--prefix` mutually exclusive
- Generated tag is `$prefix:<n>` with the smallest `n >= 0` **absent from existing `$env.JOBS` tags** (not from `seq`):

```nu
mut n = 0
loop {
    let c = $"($prefix):($n)"
    if not ($c in $existing_tags) { break $c }
    $n = $n + 1
}
```

  `--tag rg:2` with `rg:0` unused must allocate `rg:0`, not `rg:3`.
- Receipt returns the **actual** tag after the row is stored
- Suffix is **not** registry `seq` — loosen `par-jobs-v1` `stash:1` to “starts with `stash:`, unique, fetchable”

### Caller migration (complete set)

| Caller | Change |
|---|---|
| in-hand `read` | default generated namespace (already uses receipt tag). Over-cap in a **job**: return the full value, no stash. Foreground **worker**: `{ok: false, disclosed: false, error}` advising `jobs spawn`, no tag |
| `jobs emit` | `--prefix "emit"` (or caller `--tag`). `tag` on the envelope **only** if stash `ok`. Duplicate/stash fail → envelope `ok: false`, **no** `tag` (today it inserts both). **In a job** (`in_job`): skip stash, keep `findings` inline, `truncated: false`, no tag — `par emit` alone would omit the body. Foreground worker over-cap: `ok: false`, `truncated: false`, no tag, advise `jobs spawn` |
| `xq` | drop `jobs list` import. `--prefix $"xq:(stem)"`. Over-cap owner → stash then tag. Over-cap in job (including par-inside-job) → full streams, `truncated: false`, no tag. Foreground worker over-cap → `ok: false`, **`truncated: false`**, no tag, batch continues, error names `jobs spawn { … \| par { … } }` |
| `rg` (json + text) | drop `jobs list`. `--prefix "rg"`. Same three-context table, including `truncated: false` on the worker fail-closed path. Stash fail → `ok: false`, no tag |

Exact-duplicate `--tag` remains `ok: false`. Pre-seeded `xq:*` / `rg:*` / `emit:*` cannot be retrieved as a later generated payload.

### Tests (commit 3)

Add to `composition-v1.nu`:

- Pre-seed `--tag "rg:0"` / `"xq:nu:0"` / `"emit:0"`, then over-cap generate → different tag, fetch of generated tag is the new payload
- Hole: `--tag "rg:2"` on an empty `rg:` namespace, then generate → `rg:0` (smallest free), not `rg:3`
- Foreground `par { xq large }`: row `ok: false`, no `tag` in value, `truncated` not true, registry has no worker stash
- `jobs spawn { data \| par { xq large } }`: **exactly one** registry row; both child values present in the fetched table
- `jobs emit` inside `jobs spawn` over cap: one registry row (the job), fetched envelope has findings, no nested emit tag
- `jobs stash` / `jobs spawn` / `jobs cancel` from a worker fail as data
- Duplicate `--tag` still `ok: false`

Amend `rg-v1` “over cap json spine” / “two over-cap tags”: assert uniqueness and fetch, not exact `rg:0`/`rg:1` (or keep `rg:0` only as “empty registry + prefix rg starts at 0”, plus a collision case). `xq-v1` already uses `starts-with "xq:"` — keep that.

### Docs (commit 3)

- `jobs stash` docstring (`--prefix`, no predicted suffix)
- `jobs.md`, `search.md` (`rg:<seq>` → allocated `rg:*` tag from the receipt)
- Adapters: `jobs fetch rg:<seq>` → `jobs fetch` the envelope’s `tag`
- N17 landed; composition-v1 follow-up for the ownership cut

---

## Commit 4 — `nushell-mcp: harden capture and rg byte paths`

New: `modules/core/stream.nu`

```nu
# stream bytes  →  {ok: true, bytes: int} | {ok: false, bytes: null, error}
```

- string → UTF-8 byte length (`str length --utf-8-bytes`)
- binary → binary byte length
- anything else → failure, **never** zero by catch fallback

Replace `xq`/`rg` `utf8-bytes` helpers. `stdout_bytes` / `stderr_bytes` use this. Distinct from `shape.bytes` (NUON).

### `process capture`

Closed outcome on **every** path:

```
{ok, cmd, args, stdout: string|binary, stderr: string|binary,
 exit_code: int?, elapsed, error?, trace?}
```

- `ok` = capture ran, **independent of child exit code**. Success includes `ok: true` (today success omits `ok`; xq only checks `ok? == false`)
- Preserve forwarded `args` on miss/fail (today miss forces `args: []`)
- Spawn catch uses `failure fields`. Normalize to `not found: <cmd>` only when the short error matches `(?i)not found|cannot find|executable not found` (Windows: `"The system cannot find the file specified"`). Otherwise keep the raw short error and `trace` — do not treat permission/other spawn failures as missing binaries
- Streams keep their native type; do not stringify binary

### `xq`

- Cap uses `stream bytes` on each stream; unsupported stream → `ok: false`, never under-count
- Overall `ok: false` if capture failed **or** child exit ≠ 0 **or** required quarantine failed
- Keep `exit_code` on all of those
- Binary over cap: stash `{stdout, stderr}` as returned; `jobs fetch` is byte-for-byte

### `rg`

- Binary capture stream → explicit failure (do not parse as text)
- In `rg-parse`, if an event has `path.bytes` or `lines.bytes` (no usable `.text`) → unsupported-encoding failure for the **command**, not `file:""` / `match:""`
- No byte-backed finding schema in this cut
- `rg.ok` still accepts child exit 0 or 1 only when capture, interpretation, **and** required quarantine succeed

### Tests (commit 4)

- `stream bytes` on string, binary, record
- Capture success has `ok: true` with nonzero `exit_code` possible
- Non-missing spawn failure is not `not found:` (if a reliable local spawn error exists; otherwise skip rather than fake it)
- Binary stdout over cap: stash and `jobs fetch` equal the original binary
- File with invalid UTF-8 containing a match: `rg` returns `ok: false` with an encoding error, findings absent, no `match: ""`
- Existing `xq-v1` / `rg-v1` still pass (string path)

During the cut, verify with the pinned `deps/nushell/nu.exe` how `complete` types non-UTF-8 stdout — do not guess; write the binary fixture against the observed type.

### Docs (commit 4)

- `process capture` / `xq` / `rg` docstrings
- `jobs.md` xq section, `search.md` bytes/encoding
- Adapters: capture `ok` ≠ child exit; binary possible
- N18 landed; composition-v1 **Status: landed**; roadmap 5a landed; xq/rg “hardening pending” cleared
- Follow-up reports with suite counts

---

## Final gate (after commit 4, not a fifth product commit)

Run, all must be green:

```
nu -n mcp/nushell-mcp/tests/composition-v1.nu
nu -n mcp/nushell-mcp/tests/par-jobs-v1.nu
nu -n mcp/nushell-mcp/tests/dataspection-v1.nu   # includes --config over-cap read
nu -n mcp/nushell-mcp/tests/xq-v1.nu
nu -n mcp/nushell-mcp/tests/rg-v1.nu
```

Also: `nu-modules list` shows the three new core **files** and does not leak them through `use dataspection *`; adapter three-way parity on the `rg:<seq>` line; one live MCP `evaluate` of a returned `{ok: false}` that still gets a `history_index` (engine success, domain failure, receipt/linking intact on the stored value). Session-host test waits for that brief.

Suite failure must exit nonzero (`error make` on `n_err`) — already the pattern; keep it.

## Commit hygiene

- Pointed `git add` of named nushell-mcp paths only (`mcp/nushell-mcp/...`, `issues/nushell-mcp/...`, and the three home-dir adapters)
- Do not touch `reposnapshot`
- Prepend ledger entries; do not full-read ledger
- Leave `issues/nushell-mcp/discussion/sol-engine-fixes.md` untracked unless you want it filed as historical notes in a separate docs commit

## Implementation notes (do not rediscover)

1. **Stash vs harvest projection.** `jobs-apply` projects returned job *work*. `jobs stash` never interprets the stored value as an executed outcome.
2. **`par emit`** already aggregates rows with a boolean `ok` column. After commit 2 it will count lifted domain failures in `n_err`. Leave `par emit` as-is; do not recurse into `value`. `jobs emit` in a job must **not** rely on `par emit`’s truncation — it has to put findings back inline.
3. **Mailbox.** Removing `jobs list` from `xq`/`rg` is not only tag allocation — it stops workers calling `jobs-harvest` → `job recv`. The harvest/drain owner-gate is the backstop if any other caller remains.
4. **Default generated tags.** `stash:<n>` starting at `0` with collision skip will change `stash:1` after a `--tag s` row. That is spec-compliant; fix the test, not the allocator, to keep suffix==seq.
5. **Layering A** remains acyclic: `outcome` / `execution` / `stream` sit beside `failure`/`value`/`census`. `par` imports `outcome` (+ `execution` in commit 3). `jobs` same. `xq`/`rg` import `stream` in commit 4; they never import `outcome` (their envelopes already declare `ok`).
6. **`with-env` vs `--env`.** Worker markers are scoped to the `par-each` block. `execution.nu` does not export enter/leave mutators.
