# `xq` v1 — execute-and-quarantine for externals

**Status:** filed, not started · **Filed:** 2026-08-21 · **Home:**
`mcp/nushell-mcp/modules/xq`, Nu-native, used only through `evaluate`.
**Depends on:** [par-jobs-v1](../.archive/par-jobs-v1.md) (`jobs stash`, cap
resolver). **Consumed by:** [rg-wrapper-v1](rg-wrapper-v1.md) — rg is
`xq` + JSON-event parse + spine; build this first.
**Not this brief:** per-tool wrappers (fd, jq, jj, delta), a shell, a
job queue, sandboxing.

Treat this file as the v1 spec. Amend; do not fork.

## Problem

- Every external the agent runs (`cargo build`, `pytest`, `git log`,
  `fd`, `jq`) floods the same way rg does, and the right answer is the
  same every time: `complete`, census, inline under cap, stash over cap.
- `^cmd | complete` already gives `{stdout, stderr, exit_code}` — but
  no census, no cap, no quarantine, no elapsed, and every agent
  re-derives the discipline ad hoc (or forgets it).
- One primitive, then consumers. The rg brief's "text mode" is `xq`
  trying to get out.

## Command

Module `xq`, `export def --wrapped main [...args]`.

```
xq <cmd> [...args]          # --wrapped; argv forwarded verbatim to ^cmd
$in | xq <cmd> [...args]    # pipeline input becomes the child's stdin
```

- **Zero curation.** `args[0]` is the command, the rest is opaque. No
  wrapper flags in v1 — with `--wrapped`, a wrapper flag after the
  command name would be ambiguous with the child's flags. Everything
  the wrapper needs it derives (tag from command name + seq, cap from
  policy, job context from `job id`).
- Runs `^($args.0) ...($args | skip 1) | complete`, streams kept
  separate. `o+e>|` interleaving is not offered; if you need ordering
  across streams, that is a consumer concern.
- Missing binary → `{ok: false, error: "not found: <cmd>", ...}` with
  `exit_code: null`. Fail closed; never search for the binary (PATH is
  `config.nu` layout — `deps/cli`).
- **Inside a job** (`(job id) != 0`, i.e. `jobs spawn { xq ... }`): the
  job itself is the quarantine, and job threads cannot write
  `$env.JOBS`. `xq` therefore returns **full streams inline, never
  stashes**, `truncated: false`. The job's receipt/`read` discipline
  applies to the whole envelope. Verified: `job id` is `0` on the main
  thread, nonzero in a spawned job.
- The contract is **documented, not encoded**: `help xq`, reference
  corpus, `nu-modules` inspection.

## Envelope (the only return shape)

```
{ok: bool, cmd: string, args: list<string>, exit_code: int?,
 elapsed: duration, stdout_bytes: int, stderr_bytes: int,
 truncated: bool, error?: string, tag?: string,
 stdout?: string, stderr?: string}
```

- `ok` = `exit_code == 0`. Nothing else. Tools with meaningful non-zero
  exits (rg's 1 = no match) are interpreted by their consumer, not here.
- `cmd` = `args[0]`; `args` = the forwarded tail (what the child
  received) for provenance in `$history`.
- `stdout_bytes` / `stderr_bytes` = UTF-8 byte length of each stream.
  `elapsed` = wall time around the child.
- **Truncate on total bytes**: `stdout_bytes + stderr_bytes` vs
  `max_inline_bytes` (policy; null → `NU_MCP_OUTPUT_LIMIT`). One rule,
  not per-stream.
- `truncated == false` → `stdout` and `stderr` present (possibly empty
  strings). `truncated == true` → both omitted, `tag` present, and the
  record `{stdout, stderr}` is stashed via
  `jobs stash --tag xq:<cmd>:<seq>` (e.g. `xq:cargo:3`). `jobs read`
  returns that record; slice `.stdout | lines` from `$history`.
- `tag` present **iff** something was stashed — same rule as `jobs emit`.
- `error` present only for wrapper-level failures (not found, spawn
  failure). A child that runs and exits non-zero is `ok: false` with
  streams, no `error`.

## Storage and drill-in

Registry only (`jobs stash`) — one queryable store, no `$env.XQ_LAST`.
`jobs list` shows `xq:*` rows next to jobs; `jobs inspect` gives census;
`jobs read xq:cargo:3` returns `{stdout, stderr}`.

Drill: `(jobs read xq:cargo:3).stderr | lines | where $it =~ '^error'`.
Paging is ordinary Nu on `$history`. For a long-running child, prefer
`jobs spawn { xq cargo build } --tag build` — non-blocking, and the job
row *is* the quarantine.

Unlawful: `| head`/`| first N` on the live child (THE RULE); re-running
to page; a consumer re-implementing cap/stash instead of calling `xq`.

## Policy

Reads `max_inline_bytes` through the same resolver `par emit` uses
(export it as `par cap` if not already; do not duplicate). No threads,
no timeouts in v1 (a hung child is the agent's to `jobs cancel` when
spawned; foreground `xq` blocks `evaluate` like any external does).

## Tree

```
mcp/nushell-mcp/modules/xq/
  mod.nu              # main (--wrapped), envelope, stash-or-inline
mcp/nushell-mcp/skills/nushell/references/jobs.md
  + `xq` section: envelope, in-job behavior, drill idioms
config.nu             # use xq *   (after par/jobs)
```

Docstring on `main` is part of the deliverable. rg-wrapper-v1's
implementation calls `xq` internally; amend that brief's Tree/Command
when this lands (its text mode collapses into "xq's envelope plus JSON
parse when stdout is events").

## Tests (child `nu -n`, use a portable child: `nu -n -c ...`)

- exit 0 with stdout: `ok: true`, `exit_code: 0`, streams inline,
  `stdout_bytes` == length, `truncated: false`, no `tag`/`error`
- exit non-zero with stderr: `ok: false`, `exit_code` set, streams
  inline, no `error` column
- not found: `ok: false`, `exit_code: null`, `error` starts
  `not found:`, nothing stashed
- stdin passthrough: `"abc" | xq nu -n -c 'print $in'`-style child
  echoes input
- over cap (cap forced low, child prints a large block): `truncated:
  true`, no streams, `tag: xq:nu:0`, `jobs read` returns `{stdout,
  stderr}` with the full text; registry row `completed`, `job_id: null`
- two over-cap runs: seq monotonic in tags
- inside a job: `jobs spawn { xq nu -n -c <big print> }`, `collect`,
  `read` → envelope has full `stdout`, `truncated: false`, no `tag`;
  registry has exactly one row (the job), no `xq:*` row
- `args` echo excludes `cmd`; `cmd` == first token
- elapsed is a duration > 0

## Exit gate

Two `evaluate`s: `xq nu -n -c "1..5000 | to text"` → envelope with
census, `truncated: true`, `tag`, no text; `jobs read <tag>` → the
record. Then `jobs spawn { xq nu -n -c "..." } --tag bg` → receipt;
`jobs read bg` → full envelope inline. No raw child output ever hits a
tool result over the cap.

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
