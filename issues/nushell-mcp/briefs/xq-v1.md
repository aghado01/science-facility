# `xq` v1 — execute-and-quarantine for externals

**Status:** filed, not started · **Filed:** 2026-08-21 · **Home:**
`mcp/nushell-mcp/modules/xq`, Nu-native, used only through `evaluate`.
**Depends on:** [layering-v1](layering-v1.md) (N9 landed in code first),
[par-jobs-v1](../.archive/par-jobs-v1.md) (`jobs stash`),
[dataspection-v1](dataspection-v1.md). **Consumed by:** [rg-wrapper-v1](rg-wrapper-v1.md)
— rg consumes `process capture`, not ordinary `xq`. **Not this brief:**
per-tool wrappers (fd, jq, jj, delta), a shell, a job queue, sandboxing.

Treat this file as the v1 spec. Amend; do not fork.

## Problem

- Every external the agent runs (`cargo build`, `pytest`, `git log`,
  `fd`, `jq`) floods the same way rg does, and the right answer is the
  same every time: `complete`, census, inline under cap, stash over cap.
- `^cmd | complete` already gives `{stdout, stderr, exit_code}` — but
  no census, no cap, no quarantine, no elapsed, and every agent
  re-derives the discipline ad hoc (or forgets it).
- One capture primitive, then a terminal command, then consumers.
  Rg needs the streams **before** xq withholds them; it must not call
  ordinary `xq`.

## Commands

Two surfaces. `process capture` is the unbounded unit (layering split
condition 2). Ordinary `xq` is the agent-facing terminal command.

### `process capture` — `core/capture.nu`

```
export def --wrapped "process capture" [...args]
process capture <cmd> [...args]
$in | process capture <cmd> [...args]
```

- Named export, **not** `main`, so `process capture cargo` does not
  become a child named `capture`. `--wrapped`; argv forwarded.
- Returns `{stdout, stderr, exit_code, elapsed}` always in full.
  Missing binary: `try/catch` around `^cmd` (literal `^cmd | complete`
  **throws**). Fail-as-data `{ok: false, error: "not found: <cmd>",
  exit_code: null, …}` with the closed column set filled (zeros /
  empty streams / `elapsed: 0sec` / `truncated` absent or false).
- Empty args → `{ok: false, error: …}`, no index panic.
- Pipeline `$in`: attach stdin **only** when `$in` is not `nothing`.
  A bare `process capture rg pattern` must not hang the child on stdin.
  Verified: `'hello' | nu -n --stdin -c '$in'` echoes; without
  `--stdin`, `$in` is empty.
- No cap, no stash, no `par`/`jobs`. xq and rg both `use core/capture.nu`.

### `xq` — `modules/xq/mod.nu`

```
xq <cmd> [...args]          # --wrapped main; argv forwarded to the child
$in | xq <cmd> [...args]
```

- `use core/capture.nu`; `use jobs ["jobs stash"]`; `use par ["par cap"]`.
- Runs `process capture`, then census + cap + quarantine on the
  streams. Cap is **`stdout_bytes + stderr_bytes` vs `par cap`**, not
  `shape.bytes` of the envelope (same knob, different measure — say
  so; do not call `read`).
- Zero curation on `main`. Empty args: fail-as-data, not `args[0]` throw.
- **Inside a job** (`(job id) != 0`): capture is already full; **do
  not stash** (job threads cannot write `$env.JOBS`). Envelope has
  full streams, `truncated: false`, no `tag`. The job row is the
  quarantine.
- Tag for a stash: `xq:<cmd>:<seq>` with `seq` = `(jobs list | length)`
  (append-only, matches next jobs seq). Do not call private
  `jobs-next-seq`.
- Stamp the envelope `meta.verb: xq`.
- Documented, not encoded: `help xq`; skills say `xq`, not
  `process capture` (flood hatch, same class as `jobs fetch` /
  `^cmd | complete`).

## Envelope (the only return shape)

```
{ok: bool, cmd: string, args: list<string>, exit_code: int?,
 elapsed: duration, stdout_bytes: int, stderr_bytes: int,
 truncated: bool, error?: string, tag?: string,
 stdout?: string, stderr?: string, meta}
```

- `ok` = `exit_code == 0`. Nothing else. Tools with meaningful non-zero
  exits (rg's 1 = no match) are interpreted by their consumer, not here.
- `cmd` = `args[0]`; `args` = the forwarded tail (what the child
  received) for provenance in `$history`.
- `stdout_bytes` / `stderr_bytes` = UTF-8 byte length of each stream.
  `elapsed` = wall time around the child.
- **Truncate on total bytes**: `stdout_bytes + stderr_bytes` vs
  `par cap`. One rule, not per-stream. Not `shape.bytes`.
- `truncated == false` → `stdout` and `stderr` present (possibly empty
  strings). `truncated == true` → both omitted, `tag` present, and the
  record `{stdout, stderr}` is stashed via
  `jobs stash --tag xq:<cmd>:<seq>` (e.g. `xq:cargo:3`). `jobs fetch
  <tag>` returns that record (over cap by construction);
  slice `.stdout | lines` from `$history`, or compose `| page`.
- `tag` present **iff** something was stashed — same rule as `jobs emit`.
- `error` present only for wrapper-level failures (not found, spawn
  failure). A child that runs and exits non-zero is `ok: false` with
  streams, no `error`.

## Storage and drill-in

Registry only (`jobs stash`) — one queryable store, no `$env.XQ_LAST`.
`jobs list` shows `xq:*` rows next to jobs; `jobs inspect` gives census;
`jobs fetch xq:cargo:3` returns `{stdout, stderr}`.

Drill: `(jobs fetch xq:cargo:3).stderr | lines | where $it =~ '^error'`.
Paging is ordinary Nu on `$history`. For a long-running child, prefer
`jobs spawn { xq cargo build } --tag build` — non-blocking, and the job
row *is* the quarantine.

Unlawful: `| head`/`| first N` on the live child (THE RULE); re-running
to page; a consumer calling ordinary `xq` when it needs the streams
(rg); a consumer re-implementing capture instead of `process capture`.

## Policy

Reads `max_inline_bytes` through `par cap` (do not duplicate). No threads,
no timeouts in v1 (a hung child is the agent's to `jobs cancel` when
spawned; foreground `xq` blocks `evaluate` like any external does).

## Tree

```
mcp/nushell-mcp/modules/core/capture.nu   # process capture (--wrapped)
mcp/nushell-mcp/modules/xq/mod.nu         # use capture + jobs stash + par cap; --wrapped main
mcp/nushell-mcp/skills/nushell/references/jobs.md
  + `xq` section: envelope, capture vs terminal, in-job, drill
config.nu             # use xq *   (after dataspection; do not preload capture)
```

Docstring on `main` and on `process capture` are part of the deliverable.

## Tests (child `nu -n`, use a portable child: `nu -n -c ...`)

- exit 0 with stdout: `ok: true`, `exit_code: 0`, streams inline,
  `stdout_bytes` == length, `truncated: false`, no `tag`/`error`
- exit non-zero with stderr: `ok: false`, `exit_code` set, streams
  inline, no `error` column
- not found: `ok: false`, `exit_code: null`, `error` starts
  `not found:`, nothing stashed
- stdin passthrough: `"abc" | xq nu -n --stdin -c '$in'` echoes input;
  bare `xq …` does not attach stdin (`$in` is `nothing`)
- over cap (cap forced low, child prints a large block): `truncated:
  true`, no streams, `tag: xq:nu:0`, `jobs fetch` returns `{stdout,
  stderr}` with the full text; registry row `completed`, `job_id: null`
- two over-cap runs: seq monotonic in tags
- inside a job: `jobs spawn { xq nu -n -c <big print> }`, `collect`,
  `jobs fetch` → envelope has full `stdout`, `truncated: false`,
  no `tag`; registry has exactly one row (the job), no `xq:*` row
- `args` echo excludes `cmd`; `cmd` == first token
- elapsed is a duration > 0

## Exit gate

Two `evaluate`s: `xq nu -n -c "1..5000 | to text"` → envelope with
census, `truncated: true`, `tag`, no text; `jobs fetch <tag>` → the
record. Then `jobs spawn { xq nu -n -c "..." } --tag bg` → receipt;
`jobs fetch bg` → full envelope. No raw child output over the cap.

Also: `process capture` of a missing binary is fail-as-data, not a
throw. `rg` must not appear in xq's tests as a caller of ordinary `xq`.

## Non-goals (v1)

- Wrapper flags (`--tag`, `--timeout`, `--cwd`, `--env`) — ambiguous
  under `--wrapped`; revisit only with a scheme that cannot collide
- Interleaved `o+e>` capture
- Timeouts / kill-on-timeout (use `jobs spawn` + `jobs cancel`)
- Per-tool wrappers for `fd`, `jq`, `jj`, `delta` — `xq fd ...` is the
  wrapper
- Parsing any child's output (that is the consumer's job — rg, later
  jq/json consumers)
- A second store, any file writes, any PATH discovery

---

## Follow-up report

_Chip or implementer: append outcome, tests run, deviations from this spec._
