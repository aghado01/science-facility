# `rg` wrapper v1 — disciplined search returns in nushell-mcp

**Status:** landed · **Filed:** 2026-08-20 · **Landed:** 2026-08-22 · **Home:**
`mcp/nushell-mcp`, Nu-native module, used only through `evaluate`.
**Depends on:** [layering-v1](layering-v1.md), [par-jobs-v1](../.archive/par-jobs-v1.md)
(registry), [xq-v1](xq-v1.md) — **`process capture`**, not ordinary `xq`.
Rg runs `process capture`, parses JSON events (or falls to text), then
applies its own spine/envelope/quarantine. Build capture first.
**Not this brief:** a search engine, rg flag curation, mdnav chunking.

Treat this file as the v1 spec. Amend; do not fork.

## Problem

- Raw `rg` in the console floods: a broad pattern returns thousands of
  text lines straight into the tool result. Native `NU_MCP_OUTPUT_LIMIT`
  truncation is a byte chop — blind, mid-line, uninformative.
- The fix is **not** capping the query (THE RULE stands; `head`-style
  caps on a live search are banned) and **not** nerfing rg's flags.
- Discipline belongs on the **return path**: structured rows, envelope,
  and informative truncation — the spine instead of a chopped body.

## Command

Module `rg`, `export def --wrapped main [...args]`. Occupies the name;
`^rg` is the untouched escape hatch and stays documented.

The wrapper does **not** parse rg's CLI. A required-positional
`pattern` was the starting sketch — Nushell would steal `-C`, `--type`,
`-e`, `-f`, and anything before the pattern. Rejected.

```
rg [...args]    # --wrapped; argv forwarded via process capture to ^rg
```

- **Zero flag curation.** `args` is opaque. Forwarded verbatim.
  The wrapper injects exactly one flag: `--json`, prepended if absent,
  never doubled. No other rewrite, no reordering.
- `-h` / `--help` are **forwarded** like any flag — verified: `--wrapped`
  does not let Nushell intercept them. `rg --help` is therefore rg's
  own text help, handled by text mode (below). The wrapper contract is
  `help rg` only.
- **`--json` is overridden, not rejected.** Verified: `rg --json -l`,
  `-c`, `--files` exit 0 and emit plain text; rg silently drops
  `--json` in list/count/files modes (and for `--help`, `--version`,
  `--type-list`). There is no error to surface. The wrapper therefore
  detects **on the return path**: output that does not parse as rg JSON
  events is **text mode** — still no raw text in the tool result (see
  Envelope). No flag inspection, no curation. v2 may add structured
  adapters for list/count modes.
- Empty `rg` is forwarded empty; rg's usage error is exit 2 → envelope.
- **Prerequisite: `rg` on the MCP child's PATH — satisfied by layout,
  not by the wrapper.** `config.nu` prepends `deps/cli/` (vendored
  ripgrep 14.1.1, gitignored, see `deps/README.md`) to `$env.PATH`, so
  a config-loaded child resolves `^rg` deterministically ahead of the
  host PATH (verified 2026-08-21). The wrapper calls `process capture`
  (which calls `^rg`) and fails closed with capture's `not found: rg`
  — it never hunts for or bundles a binary.
- Ordering of findings is rg's emission order (per-file, line ascending;
  cross-file order is rg's traversal). Not re-sorted. Pass `--sort path`
  yourself when you need run-to-run determinism.
- The contract below is **documented, not encoded**: `main` docstring
  (`help rg`), reference corpus, `nu-modules` inspection.

## Envelope (the only return shape)

```
{ok: bool, mode: string, n: int, n_files: int, elapsed: duration,
 bytes: int, truncated: bool, args: list<string>, error?: string,
 tag?: string, findings?: table, spine?: table, text?: string}
```

- `ok`: rg exit 0 or 1. Exit 1 (no matches) is `ok: true, n: 0` — not an
  error. Exit 2 → `ok: false`, `error` short (~240 chars, first line).
- `mode` closed set: `json | text`. `json` when stdout parses as rg JSON
  events; `text` otherwise (list/count/files modes, `--help`,
  `--version`, …). Decided on the return path, never from flags.
- Census comes from rg's own `summary` event, not from counting:
  `n` = `stats.matched_lines` (= match rows), `n_files` =
  `stats.searches_with_match`, `elapsed` = `elapsed_total`. Text mode:
  `n`/`n_files` are 0, `elapsed` is wall time.
- `bytes` = NUON size of the full findings table (json) or UTF-8 length
  of stdout (text) — the value tested against the cap. `args` =
  executed child argv (what `^rg` received, `--json` once) for
  provenance in `$history`.
- **json mode:** `findings` present **iff** `truncated == false`;
  `spine` present **iff** `truncated == true`. Never both, never neither
  (on `ok: true`).
- **text mode:** `text` present **iff** `truncated == false` (the
  stdout string, e.g. `--version`'s one line). Over cap: omitted, no
  spine (there are no files to census).
- **`tag` present iff something was stashed** — same rule as
  `jobs emit`. Over-cap findings *or* over-cap text go through
  `jobs stash --tag rg:<seq>`; `jobs fetch rg:<seq>` retrieves the
  table or the string. Raw rg text never reaches a
  tool result inline beyond the cap.
- Truncate on **bytes** only. Cap is `par cap`. No new knob file.
  Do not reopen `policy.json`.

### `findings` — one row per JSON event

```
{file: string, line: int, col: int?, kind: string, match: string}
```

- One row per `match` / `context` event (= one per line). `begin`,
  `end`, `summary` events are consumed for census, never rows.
- `kind` closed set: `match | context`. Context rows (from a passed
  `-C`/`-A`/`-B`) have `col: null` (verified: `submatches: []`). Match
  rows: `col` = first submatch `start` (byte offset). Multiple
  submatches on one line do not multiply rows. No context flags → all
  `match`.
- `match` is `lines.text` as rg emitted it, trailing newline stripped.
  No other re-trimming.

### `spine` — informative truncation, one row per file

```
{file: string, hits: int}
```

- Sorted `hits` descending, then `file` ascending. Deterministic.
- The spine is census, not payload: it tells the agent where the mass is
  so the drill can be surgical. A 40k-hit result becomes a short table.

## Storage and drill-in

Over-cap findings are **stored, not dropped**: the wrapper pipes the
full table through `jobs stash --tag rg:<seq>` — a completed-on-arrival
registry row (`status: completed`, census set, `job_id: null`). One
retrieval surface for the whole console — `jobs list` shows it,
`jobs inspect rg:0` gives shape, `jobs fetch rg:0` returns the table.

`jobs stash` / `jobs emit` landed in par-jobs-v1 on 2026-08-21 (the
registry amendment this brief owed is paid). The wrapper uses `stash`
directly rather than `emit`, because its envelope carries `n_files`,
`spine`, and `args` beyond the generic `par emit` shape.

v1 storage is in-engine only. If registry contents are ever spilled to
disk, the filename carries session/agent identity — see par-jobs-v1
**Persistence and identity** (no generic filenames in joint sessions).

Two lawful drill modes, both already paid for:

1. **Slice the stored value** — `jobs fetch rg:0`, then ordinary Nu
   (`where`, `group-by`, `slice`) on `$history.N`. No re-search.
2. **Re-run scoped** — rg is fast; a narrower query is often cleaner
   than paging. Under cap it comes back inline.

Body context around a hit is `open $file | lines | slice` — native,
surgical. The wrapper grows no context-dump feature.

Unlawful: re-running the same broad query to "page" it; capping the live
pipeline; parsing `^rg` text output when the wrapper exists.

## Policy

Cap is `par cap`. No threads knob — rg parallelizes itself; do not
shard rg through `par` for speed. `use core/capture.nu`,
`use core/spine.nu` (or `core/census.nu` for `shape`),
`use jobs ["jobs stash"]`, `use par ["par cap"]` at module scope.
Inside a job, do **not** stash (same as xq). For a long sweep:
`jobs spawn { rg ... } --tag sweep`.

## Tree

```
mcp/nushell-mcp/modules/rg/mod.nu    # --wrapped main; capture + parse + envelope
mcp/nushell-mcp/skills/nushell/references/search.md
  rg wrapper contract, drill, ^rg escape, spine; not ordinary xq
config.nu             # use rg *   (after xq)
```

Docstrings on `main` are part of the deliverable.

## Tests (child `nu -n`, fixture tree)

Tests skip with a typed reason (not fail) when `which rg` is empty in
the child — the prerequisite is host setup, not module correctness.

- no match: exit 1 → `{ok: true, mode: json, n: 0, truncated: false,
  findings: []}`
- unknown flag (`--bogus`, exit 2): `ok: false`, short `error`, no
  findings/spine/text
- small query: `mode: json`, `findings` inline, `kind: match`, `n` ==
  summary `matched_lines`, `n_files` == `searches_with_match`, `bytes`
  consistent; no `spine`/`text`/`tag` columns
- text mode, small: `rg --json -l PATTERN` (rg drops `--json`) →
  `mode: text`, `text` inline is the file list, `n: 0`, no findings;
  `rg --version` → `mode: text`, one line inline; `-h` is forwarded
  (text mode), not Nushell help
- text mode, over cap (cap forced low): `text` omitted, `tag: rg:<seq>`,
  `jobs fetch` returns the string
- `-C 1` before or after the pattern: context rows present,
  `kind: context`, `col: null`, interleaved in rg order
- `-e PATTERN` forwards (wrapper has no positional pattern)
- over-cap (fixture with many hits, cap forced low): `truncated: true`,
  `spine` sorted hits-desc/file-asc, no `findings`, `tag: rg:0`;
  registry has `rg:0` completed row; `jobs fetch rg:0` returns the
  full table; `jobs inspect rg:0` has no body
- rg absent (empty `$env.PATH` or missing binary): capture's
  `not found: rg`, nothing stashed
- two over-cap queries: tags `rg:0`, `rg:1`; seq monotonic
- `args` is the executed argv; `--json` present once — not doubled if
  the caller already passed it
- `help rg` is the wrapper contract; `^rg --help` still reaches the
  raw external

## Exit gate

Three `evaluate`s: broad query over cap → envelope with census + spine,
no findings; `jobs fetch rg:0` → full findings table; scoped
re-query under cap → inline findings.
At no point does raw rg text hit a tool result beyond the cap — in
text mode the string is inline only under cap, otherwise stashed.

## Non-goals (v1)

- New MCP tools; this is a module verb through `evaluate`
- Flag curation, "safe" flag subsets, pattern rewriting — including
  inspecting `args` to *predict* text mode; detect on the return path
- Structured adapters for `-l` / `--count` / `--files` (v2 candidates;
  v1 returns them as text mode)
- Parsing rg's CLI with `argx` or anything else — `--wrapped` is the
  whole query-side contract
- The wrapper locating or bundling an `rg` binary; PATH is `config.nu` layout (`deps/cli`)
- Sharding rg through `par`; any throughput claim
- Context-dump / snippet-expansion features (use `open | lines | slice`)
- A second storage surface (`$env.RG_LAST` rejected: registry is the
  one queryable store)
- Re-sorting findings; injecting `--sort path`
- Multi-query sessions, result diffing, watch mode

---

## Follow-up report

- Landed 2026-08-22. `modules/rg/mod.nu` (`--env --wrapped main`); `config.nu`
  `use rg *` after xq. Corpus: `references/search.md`. Adapters: Claude/Grok.
- Child tests: `nu -n mcp/nushell-mcp/tests/rg-v1.nu` — 13/13 (no match, unknown
  flag, small json, json-once, text version/list, `-C` context, `-e`, over-cap
  spine, text over-cap, monotonic tags, rg absent, `help rg`, in-job no stash).
  Suite prepends `deps/cli` so `nu -n` (no config) still finds vendored rg.
- Deviations:
  - Spine rename is `rename --column {key: "file", n: "hits"}`. Positional
    `rename key file` retitles by column order, not by name.
  - JSON parse requires every line to be a record with `type` (injected
    `--json` on `--version`/`-l` yields strings).
  - Empty findings are `[]`, not a typed empty table.
- Not this brief: gh, structured `-l`/`--count` adapters.
