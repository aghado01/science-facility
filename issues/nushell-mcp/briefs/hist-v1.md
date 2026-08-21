# `hist` / `shape` / `page` v1 — census and paging over the console's store

**Status:** filed, not started · **Filed:** 2026-08-21 · **Home:**
`mcp/nushell-mcp/modules/hist`, Nu-native, used only through `evaluate`.
**Depends on:** nothing in-layer (pure value → value). Shares the
`bytes` definition with par-jobs-v1.
**Not this brief:** persisted history (session layer), search over
history contents, editing or pruning `$history`.

Treat this file as the v1 spec. Amend; do not fork.

## Problem

- `$history` is the store the whole MCP leans on ("nothing is lost, you
  always get a `history_index`"), yet it has **no receipt surface**. The
  only way to see what it holds is to dump it — which is the flood the
  store exists to prevent.
- "Skeletal metadata first" is currently true only for jobs payloads
  (`jobs inspect`). Agents want it for *any* value: what did I just get,
  how big is it, what are its columns — before deciding what to read.
- Paging is re-derived ad hoc (`skip N | first M`) with no header saying
  where you are or how much is left.

## Three verbs, all pure, all pipeline-in

`$history` is an MCP-provided variable; a module cannot name it at parse
time, and child tests have no such variable. So nothing here reads
`$history` implicitly — the agent pipes it. Explicit beats magic, and it
makes every verb testable on any list.

```
$history     | hist                 # receipt table, one row per entry
$history.7   | shape                # one census record for any value
$history.7   | page 3 --size 50     # one page + header; works on strings too
```

### `shape` — one record, no body

```
{type: string, length: int?, bytes: int, columns?: list<record>,
 nulls?: int, head: string}
```

- `type` = `describe --no-collect`-style summary (`table`, `list`,
  `record`, `string`, `int`, …). `length` for list/table/string (rows /
  rows / UTF-8 bytes); `null` otherwise.
- `bytes` = NUON-serialized UTF-8 length — **the same definition as
  receipts and envelopes** (par-jobs-v1). Not row length, not on-disk.
- `columns` (tables and records only): `[{name, type}]`, type taken from
  the first row. `nulls` = count of null cells (tables) — a cheap
  "how sparse" signal.
- `head` = first ~80 chars of the NUON, single line. Enough to recognize
  a value, never enough to be a body.
- Never errors on a weird value; falls back to `{type, bytes, head}`.

### `hist` — receipt table over a list

```
{index: int, type: string, length: int?, bytes: int, head: string}
```

- `$in | enumerate | each shape`, projected to the closed set above
  (`columns`/`nulls` dropped — that is what `shape N` is for). `index`
  is the list position, which for `$history` **is** the `history_index`.
- Sorted by `index` ascending. All rows — no cap on receipts; they are
  small by construction. If a session has thousands of entries,
  `hist | last 20` is ordinary Nu on a receipt table (THE RULE concerns
  live payloads, not receipts).
- Empty list → empty table.

### `page` — one page plus a header

```
$in | page <n> [--size 50]
→ {kind: string, total: int, size: int, page: int, pages: int,
   at: int, n: int, items: any}
```

- `kind` closed set: `rows | lines | chars`. List/table → `rows`; string
  → `lines` (split on `\n`); anything else → `chars` over its NUON.
- `page` is 1-based; `at` = offset of the first item; `n` = items on
  this page; `pages` = `ceil(total / size)`. Out of range → empty
  `items`, header still truthful (so an agent can see it overshot).
- `items` preserves the underlying value's shape (a table page is a
  table). `page` never re-sorts.
- Default `--size 50`. No byte cap inside `page` — a page of 50 huge
  rows is the agent's call; `shape` first tells it they are huge.

## Result hygiene

- `shape` and `hist` are receipts: always safe to return inline.
- `page` is the **one** body in a tool result — same conservation law as
  `jobs read`. Do not `each {|i| $history | page $i}`.
- `hist` → `shape N` → `page N k` is the lawful drill: census before body,
  mirroring `list` → `inspect` → `read` on the handle plane. Teach it in
  the skill alongside THE RULE.

## Tree

```
mcp/nushell-mcp/modules/hist/
  mod.nu              # hist (main), shape, page
mcp/nushell-mcp/skills/nushell/references/mcp.md
  + `$history | hist`, `shape`, `page` as the drill idiom
config.nu             # use hist *
```

Docstrings on all three are part of the deliverable. `jobs inspect`
should call `shape` for its census once this lands (one definition).

## Tests (child `nu -n`, any list stands in for `$history`)

- `shape` on table: `type: table`, `length` = rows, `columns` names +
  types from row 0, `nulls` counted, `bytes` > 0, `head` single line
  ≤ ~80 chars
- `shape` on string / int / record / empty list / null: closed set,
  no error, `length` null where undefined
- `bytes` equals `to nuon --raw | str length --utf-8-bytes` (the shared
  definition) for a sample value
- `hist` on `[1, "ab", [1 2 3], {a: 1}]`: four rows, `index` 0..3,
  types right, no `columns` column, sorted
- `hist` on `[]` → `[]`
- `page 1 --size 2` on a 5-row table: `kind: rows`, `total: 5`,
  `pages: 3`, `at: 0`, `n: 2`, items is a 2-row table
- `page 3 --size 2` → `n: 1`, `at: 4`; `page 4 --size 2` → `n: 0`,
  header still `total: 5`
- `page` on a multi-line string → `kind: lines`, items are lines
- `page` on an int → `kind: chars`
- page never reorders: items equal `$in | skip at | first n`

## Exit gate

In the MCP: `$history | hist` after a few evaluates → receipt table
whose `index` matches the `history_index` values the tool reported;
`$history.N | shape` → census, no body; `$history.N | page 2 --size 20`
→ header + 20 items. `hist` output fits inline regardless of how large
the payloads are.

## Non-goals (v1)

- Reading `$history` implicitly (module-level `$history`; a `--from`
  flag) — pipe it
- Searching inside history values (`hist grep`) — later, on `par`
- Persisting, pruning, or re-indexing `$history` (session layer)
- Byte caps inside `page`; smart page sizing
- Column statistics beyond `nulls` (min/max/distinct — `polars`
  territory)
- Any write, any env mutation

---

## Follow-up report

_Chip or implementer: append outcome, tests run, deviations from this spec._
