# `rg` wrapper v1 — disciplined search returns in nushell-mcp

**Status:** filed, not started · **Filed:** 2026-08-20 · **Home:**
`mcp/nushell-mcp`, Nu-native module, used only through `evaluate`.
**Depends on:** [par-jobs-v1](par-jobs-v1.md) — this is the **first
consumer** of its query envelope (shape 4) and of the registry-as-store.
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
rg [...args]    # --wrapped; argv forwarded to ^rg
```

- **Zero flag curation.** `args` is opaque. Forwarded verbatim.
  The wrapper injects exactly one flag: `--json`, prepended if absent,
  never doubled. No other rewrite, no reordering.
- `-h` / `--help` belong to Nushell (every `def`). That is wrapper
  help (`help rg` / `rg --help`). Native help is `^rg --help`. Engine-
  owned, not a curated rg flag — the one exception.
- Flags incompatible with `--json` (`-l`, `--count`, `--files`, …) fail
  with rg's own error surfaced on the envelope (`ok: false`); use `^rg`.
  v2 may add adapters for those modes. Known nerf-edge; accepted.
- Empty `rg` is forwarded empty; rg's usage error is exit 2 → envelope.
- Ordering of findings is rg's emission order (per-file, line ascending;
  cross-file order is rg's traversal). Not re-sorted. Pass `--sort path`
  yourself when you need run-to-run determinism.
- The contract below is **documented, not encoded**: `main` docstring
  (`help rg`), reference corpus, `nu-modules` inspection.

## Envelope (the only return shape)

```
{ok: bool, n: int, n_files: int, elapsed: duration, bytes: int,
 truncated: bool, args: list<string>, error?: string,
 findings?: table, spine?: table}
```

- `ok`: rg exit 0 or 1. Exit 1 (no matches) is `ok: true, n: 0` — not an
  error. Exit 2 → `ok: false`, `error` short (~240 chars, first line).
- `n` = match rows; `n_files` = distinct files; `bytes` = NUON size of
  the full findings table (the value tested against the cap); `args` =
  executed child argv (what `^rg` received, `--json` once) for
  provenance in `$history`.
- `findings` present **iff** `truncated == false`. `spine` present
  **iff** `truncated == true`. Never both, never neither (on `ok: true`).
- Truncate on **bytes** only, cap = `max_inline_bytes` from
  `modules/par/policy.json` (null → this process's `NU_MCP_OUTPUT_LIMIT`).
  No new knob file.

### `findings` — one row per JSON event

```
{file: string, line: int, col: int?, kind: string, match: string}
```

- `kind` closed set: `match | context`. Context rows (from a passed
  `-C`/`-A`/`-B`) have `col: null`. No context flags → all `match`.
- `match` is the line text as rg emitted it. No re-trimming.

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
`jobs inspect rg:0` gives shape, `jobs read rg:0` returns the table.

`jobs stash` / `jobs emit` landed in par-jobs-v1 on 2026-08-21 (the
registry amendment this brief owed is paid). The wrapper uses `stash`
directly rather than `emit`, because its envelope carries `n_files`,
`spine`, and `args` beyond the generic `par emit` shape.

v1 storage is in-engine only. If registry contents are ever spilled to
disk, the filename carries session/agent identity — see par-jobs-v1
**Persistence and identity** (no generic filenames in joint sessions).

Two lawful drill modes, both already paid for:

1. **Slice the stored value** — `jobs read rg:0`, then ordinary Nu
   (`where`, `group-by`, `slice`) on `$history.N`. No re-search.
2. **Re-run scoped** — rg is fast; a narrower query is often cleaner
   than paging. Under cap it comes back inline.

Body context around a hit is `open $file | lines | slice` — native,
surgical. The wrapper grows no context-dump feature.

Unlawful: re-running the same broad query to "page" it; capping the live
pipeline; parsing `^rg` text output when the wrapper exists.

## Policy

Reads `modules/par/policy.json` (`max_inline_bytes` only). No threads
knob — rg parallelizes itself; do not shard rg through `par` for speed
(design-center scribe in par-jobs-v1). For a long sweep over a huge tree
the lawful shape is `jobs spawn { rg ... } --tag sweep`: non-blocking +
quarantine, not throughput.

## Tree

```
mcp/nushell-mcp/modules/rg/
  mod.nu              # main (envelope), json event parser
mcp/nushell-mcp/skills/nushell/references/search.md
  rg wrapper contract, drill patterns, ^rg escape, spine doctrine
config.nu             # use rg *   (preloaded, after par/jobs)
```

Docstrings on `main` are part of the deliverable.

## Tests (child `nu -n`, fixture tree)

- no match: exit 1 → `{ok: true, n: 0, truncated: false, findings: []}`
- bad flag (exit 2): `ok: false`, short `error`, no findings/spine
- small query: `findings` inline, `kind: match`, `n`/`n_files`/`bytes`
  consistent; no `spine` column
- `-C 1` before or after the pattern: context rows present,
  `kind: context`, `col: null`, interleaved in rg order
- `-e PATTERN` forwards (wrapper has no positional pattern)
- over-cap (fixture with many hits, cap forced low): `truncated: true`,
  `spine` sorted hits-desc/file-asc, no `findings`; registry has
  `rg:0` completed row; `jobs read rg:0` returns the full table;
  `jobs inspect rg:0` has no body
- two over-cap queries: tags `rg:0`, `rg:1`; seq monotonic
- `args` is the executed argv; `--json` present once — not doubled if
  the caller already passed it
- `help rg` is the wrapper contract; `^rg --help` still reaches the
  raw external

## Exit gate

Three `evaluate`s: broad query over cap → envelope with census + spine,
no findings; `jobs read rg:0` → full findings table (native truncation +
`$history` paging apply); scoped re-query under cap → inline findings.
At no point does raw rg text hit a tool result.

## Non-goals (v1)

- New MCP tools; this is a module verb through `evaluate`
- Flag curation, "safe" flag subsets, pattern rewriting
- Adapters for `-l` / `--count` / `--files` (v2 candidates)
- Sharding rg through `par`; any throughput claim
- Context-dump / snippet-expansion features (use `open | lines | slice`)
- A second storage surface (`$env.RG_LAST` rejected: registry is the
  one queryable store)
- Re-sorting findings; injecting `--sort path`
- Multi-query sessions, result diffing, watch mode

---

## Follow-up report

_Chip or implementer: append outcome, tests run, deviations from this spec._
