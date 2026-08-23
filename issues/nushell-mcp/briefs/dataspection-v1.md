# `dataspection` v1 — disciplined access to data

**Status:** landed · **Filed:** 2026-08-21 · **Landed:** 2026-08-22 · **Home:**
`mcp/nushell-mcp/modules/dataspection`, Nu-native, used through
`evaluate`. Census, schema, spine, preview, page, and meta are pure
(value in, value out). `read` is `--env` and stashes over cap through
`jobs`. **Supersedes:** [hist-v1](../.archive/hist-v1.md).
**Depends on:** [par-jobs-v1](../.archive/par-jobs-v1.md) for `read`
only (`jobs stash`; cap via `par cap`). Other commands: `core/*.nu`
([layering-v1](layering-v1.md)). **Consumed by:** agents via
`use dataspection *`. `par`/`jobs` consume `core/census.nu` /
`core/meta.nu`, **not** this `mod.nu`. Session host still calls
`$x | shape` through the façade. **Lineage:** jso-jackson / jso-debug
(graveyard) — the controlled-inspection doctrine, re-shaped for a
runtime where data is already structured.
**Not this brief:** `$history` indexing (session host), JSON Schema
generation, tags/notes storage (the host's journal).

Treat this file as the v1 spec. Amend; do not fork.

## Problem

An agent facing an unknown structured value — an API response, a
config, a `$history` entry, the output of the command it just ran —
needs a decision loop under context discipline: *what is this → where
is the mass → is this field safe to look at → look at exactly that →
descend.* Today each step is ad hoc (`describe`, `columns`, `skip N |
first M`) with no receipts, no census, and no bounded way to look at a
whole record. `describe` collapses heterogeneous tables to `any` and
says nothing about coverage.

jso-jackson solved this for JSONL files in PowerShell. Nu dissolves the
file layer, the formatters, and the declarative-search layer (closures
are the safe form here); what survives is the discipline itself.

## The name

Named for the **practice**, not for what it holds. `jobs` and
`nu-modules` are domain modules — named for their objects. This one is
named for what it does to whatever it is handed, because the module
*is* a discipline: census before body, receipts before disclosure,
bounded views, no silent omission.

**Membership rule:** anything that operates on a value **in hand**
belongs here. Anything that addresses a **stored or named** thing
belongs to that thing's domain module (`jobs`, `nu-modules`).

Metadata is data — a different tier, not a different kind — so `meta`
and `meta stamp` live here too. Stamping is not an exception to a
describing-only module: you stamp on the way out *so that* census
works on the way back. `$history | shape each` can only lift `ok` and
`verb` because something stamped them. One loop, one module.

**Load order.** Runtime primitives first, access discipline second.
`config.nu` and every child suite:

```
use par *
use jobs *
use dataspection *
```

`par` freezes cap knobs; `jobs` is the registry `read` stashes into.
Cross-module calls resolve at run time — `jobs emit` already calls
`par emit` this way. Dataspection does not `use jobs` internally;
over-cap `read` invokes `jobs stash` from the overlay, same as jobs
invokes `par emit`.

## Two vocabularies

Data objects are nouns; interactions are verbs; they compose. The
split is not two categories of command — it is one system, and which
grammar you use follows from **how the object arrives**.

**Nouns produce a data object** from what is in the pipeline. Each is
a first-class object, not a terminal readout:

| Noun | The object |
|---|---|
| `shape` | census of one value |
| `schema` | structural profile of a population |
| `spine` | where the mass is, over a column |
| `meta` | the provenance stamped onto a record, or `null` |

**Verbs interact with whatever object is in hand.** They are
**portable** — each means one thing wherever it appears, including in
other domains (`jobs inspect`, `nu-modules read`, `meta stamp`):

| Verb | Means |
|---|---|
| `inspect` | describe without disclosing |
| `read` | disclose the body |
| `preview` | the whole structure, leaves clipped to specification |
| `page` | one slice, with a truthful header |
| `stamp` | write this metadata onto it — always qualified by its object (`meta stamp`) |

Because they compose, a produced object is just another object:

```
$x | schema | preview            # the schema is large — clip it
$x | spine file | page 2         # the spine is long — slice it
$x | schema | shape              # how big is this schema, actually
jobs fetch sq | shape            # disclose, then census the body
```

That last line is **compose after a lawful disclose**, not an
identity. **`jobs inspect` is not `jobs read | shape`.** `inspect`
discloses nothing; `read` may decline and then `| shape` would census
the decline receipt, not the payload. `jobs inspect` keeps jobs' own
receipt (identity fields plus payload census). One `bytes` definition
means jobs calls `$payload | shape` **internally** to fill those
census fields — it does not export `jobs shape`, and it does not
route inspect through read. `nu-modules inspect` is a command
listing, a different object entirely.

**Holding is not seeing.** From the agent's side every value in the
engine is a handle — `$x`, `$history.7`, a registry payload, an
intermediate pipeline stage. The agent never has the bytes, only a
name the engine can resolve, and nothing is disclosed unless it fits
the cap. So `read` is meaningful on a piped value, not only on a
stored one. An unnamed terminal `big | read` that declines **stashes**
so the body is not lost when `$history` records the receipt.

## The disclosure ladder

One rule, expressed as four verbs. This is where "no silent omission"
stops being prose and becomes enforceable:

| Verb | Discloses | Always fits? |
|---|---|---|
| `inspect` / `shape` | nothing — census only | yes, by construction |
| `read` | the whole body | **only if under cap** — otherwise a receipt naming `jobs fetch <tag>` |
| `preview` | whole structure, leaves clipped | yes, bounded per leaf |
| `page` | one slice | yes, bounded per slice |

`read` is the **only** verb that may decline, and when it declines it
names the retrieval. That makes the cap rule a property of one verb
rather than a separate primitive: the `jobs disclose` once proposed
for par-jobs collapses into `read` itself.

## Commands (flat; `use dataspection *`)

**No command throws on odd input — failure is data.**
An agent exploring the unknown must always get the command's own
shape back;
when a step fails internally, the verb catches it and the result
carries `error: string` (first line, ~240 chars) **and** `trace:
string` (the full rendered error, `$e.rendered`/`$e.debug`) so the
cause is never lost — a fallback that hides why it fell back is silent
omission. Both fields are absent on success; `trace` is a separate
column so a consumer can `reject trace` when it only wants receipts.

### `shape` — census of one value

```
$x | shape
→ {type: string, length: int?, bytes: int, columns?: list<record>,
   nulls?: int, head: string, error?: string, trace?: string}
```

- `type`: `table | list | record | string | int | float | bool |
  datetime | duration | filesize | nothing | binary | closure | other`
  (from `describe --no-collect`, normalized; `list<int>` → `list`).
- `length`: rows (table/list), UTF-8 bytes (string), `null` otherwise.
- **`bytes`**: NUON-serialized UTF-8 length — **the one definition**
  for the whole layer. `jobs-census`, `par emit`, and every envelope
  call this; nobody re-derives it. Unserializable → `bytes: null` +
  `error`/`trace`, never a throw.
- `columns` (table/record): `[{name, type}]`, type from row 0.
  `nulls` (table): count of null cells.
- `head`: first ~80 chars of the NUON, one line. Recognizable, never a
  body.

### `shape each` — one census row per element

```
$list | shape each
→ table: {index, type, length, bytes, ok?: bool, verb?: string, head}
```

`columns`/`nulls` omitted (that is what `shape` on one element is
for). `index` = position in the input list. Piping `$history` gives
the **`$history` index** — the same slot nushell's tool result reports
as `history_index` — so census over the evaluation buffer needs no
verb of its own. Empty → empty table.

**`ok` and `verb` are lifted, not computed:** when an element is a
record carrying the layer's `ok` field and/or a `meta.verb`, the row
shows them; otherwise they are `null`. This is how a caught failure
stays legible in `$history`: a verb that returns failure-as-data is a
*successful evaluate* to the engine (it gets a `history_index`), so
the only evidence it failed is the value's own `ok: false`. `shape
each` surfaces that at census level — `$history | shape each | where
ok == false` finds every domain failure without opening one. `shape`
on a single record lifts `ok?` the same way.

### `schema` — structural profile of a population

```
$x | schema
→ table: {path: string, types: string, coverage: float, hits: int,
          records: int}
```

- One row per path observed across the population (a table's rows; a
  list's elements; a record is a population of one). Paths are dotted,
  lists traversed as `[]`: `body.items[].id`. Lexical order.
- `types`: `|`-joined sorted set of Nu type names seen at that path
  (`int|nothing`). `coverage`: % of records in which the path appears.
  `hits`: observations; `records`: distinct records contributing.
- This is what `describe` cannot say: *which* paths vary, and how
  often they are missing.

Operations on schema tables (pure):

- `schema diff <other>`: rows `{path, status: added | removed | changed,
  before?, after?}` — what appeared, vanished, changed type between two
  profiles (two points in time, two sources).
- `schema check <profile>`: validate `$in` against a profile →
  `{ok, violations: table<{path, expected, got, record}>}`. Never
  throws; violations are data.
- `schema stats <path>`: for string/list leaves at a path →
  `{path, n, len_min, len_max, len_avg, len_p95}`. The "is this field
  safe to look at" question.

### `spine <column>` — where the mass is

```
$table | spine file [--top N]
→ table: {key: any, n: int}
```

Sorted `n` desc, then `key` asc. Deterministic. `histogram` minus the
noise; closed so envelopes can embed it (rg's over-cap spine, jobs by
status, `$history` by type, mdnav shards by chunk). Missing column →
`[]`, not an error.

### `page` — one bounded slice plus a truthful header

```
$x | page <n> [--size 50] [--at K] [--around K -C k]
→ {kind: rows | lines | chars, total: int, size: int, page: int,
   pages: int, at: int, n: int, items: any}
```

- `page` is 1-based; `--at` overrides with an offset; `--around K -C k`
  is a window of `2k+1` centered on K (the `peek file 120 -C 5` idiom:
  `open f | lines | page --around 120 -C 5`, items carry line numbers
  via `enumerate` when `kind: lines`).
- Out of range → empty `items`, header still truthful.
- Never re-sorts. No byte cap — `shape` first tells you the rows are
  huge. Strings page by line, other scalars by chars over NUON.

### `preview` — one whole value, leaves clipped

```
$x | preview [--chars 200] [--items 5] [--mode head|tail|sandwich]
→ same structure as $in, leaves clipped
```

- Structure-preserving (jso's `ConvertTo-JsonPreview`): strings over
  `--chars` clipped with a `… [+N chars]` marker (head / tail /
  sandwich, default sandwich), lists over `--items` clipped with
  `[+K more]`. Records keep every key. Tables clip rows as a list.
- This is the verb that lets you see *one record* without its 40KB
  `text` field. Bounded by construction (per-leaf), not by the byte
  cap. Idempotent on already-clipped values.

### `read` — disclose the body

```
$x | read
→ the value itself when it fits the cap
→ {ok: true, disclosed: false, tag: string, bytes: int,
   retrieve: string, error?: string, trace?: string}
   | merge {meta: {verb: "read", at, …}} when it does not
```

`export def --env`. The **disclosure verb**, and the only one that may
decline. Declining is not failure (`ok: true`).

- **Cap.** `par cap`: `$env.NU_PAR.max_inline_bytes` if set, else
  `$env.NU_MCP_OUTPUT_LIMIT`, else `20000`. Do not open `policy.json`.
  `bytes` is `shape`'s definition (NUON UTF-8 length).
- **Under cap** → the value itself. Not wrapped, not stamped.
- **Over cap** → `jobs stash` (default tag `stash:<seq>`); the
  receipt copies `tag` and `bytes`, and `retrieve` is the pasteable
  command `"jobs fetch <tag>"` — never a bare "too big". Bounded
  verbs stay the ladder on a value in hand (`$x | preview`,
  `jobs fetch t | page`); they are not the decline's `retrieve`.
- **Jobs missing** (overlay has no `jobs stash`) →
  `{ok: false, disclosed: false, error, trace}`. Misconfigured
  session, not a production path; `config.nu` always loads jobs
  first. The body is not in the result.
- Duplicate tag / stash failure → that error as data (`ok: false`).
- Peek, not pop: `read` never removes or mutates `$in`; a bound `$x`
  still holds the value after a decline.
- This is the one cap rule for in-hand disclose. `xq` and rg apply
  *this*. `jobs read` uses the same cap for terminal disclose of an
  addressed payload; `jobs fetch` returns the stored body. `jobs inspect`
  never routes through `read`.

### `meta` — the provenance on a record

```
$rec | meta
→ {verb, at, tag?, elapsed?, ref?}   |   null when unstamped
```

A noun like `shape`: it produces the object, it does not fetch a body.
Projection, so consumers never reach into `$rec.meta?` by hand and
disagree about the absent case. Never throws.

Adjacent to nushell's builtin `metadata`, which returns *pipeline*
metadata (`{span}`, plus `source` on a live pipeline) and is stripped
on storage in `$history`. Different thing, similar name — the corpus
says so.

### `meta stamp` — write provenance onto a record

```
$rec | meta stamp --verb <string> [--tag t] [--elapsed d] [--ref {...}]
→ $rec | merge {meta: {verb, at, tag?, elapsed?, ref?}}
```

- **Closed sub-record.** `verb` is the producing command, dotted
  (`jobs.spawn`, `par.emit`, `xq`, `rg`, `note`) — **not** `kind`,
  which is spoken for by the journal record kind, `page`'s unit, and
  rg's finding kind ([vocabulary](../notes/vocabulary.md)).
  `at` = `date now`. `ref` points at other entries: `{history: 7}`
  (the `$history` index) or `{tag: "sweep"}`.
- **Records are stamped; tables stay bare.** On a non-record input
  `stamp` wraps: `{meta, value}` — opt-in, never automatic. Wrapping a
  table would break `| where` on the thing agents pipe most.
- `stamp` is qualified by its object because the verb is **portable**:
  a module that writes timestamps would have its own `stamp`, meaning
  the same act on a different object. Bare `stamp` is refused — that
  is the rubber-stamp metaphor, which is not what this does.
- Stamping twice replaces `meta`; it never nests.
- Pure: no env, no storage, no clock beyond `date now`.

**Why it earns its place in the discipline.** A verb that catches an
error and returns `ok: false` is a *successful evaluate* to the engine
— it gets a `history_index` and looks like any other entry. `meta`
plus the universal `ok` is what keeps that legible:
`$history | shape each | where ok == false` finds every caught failure
without opening one. Without stamps the session spine is values and
positions and nothing else.

## Result hygiene (the drill loop, taught in the skill)

```
$x | shape                     # what is it
$x | schema                    # where does structure vary
$x | schema stats body.text    # is this field safe
$x | preview --chars 200       # one record, clipped
$x | get body.items | page 2   # descend, one page
```

Census before body, mirroring `list` → `inspect` → `read` on the
handle plane. Never `each {|i| ... | page $i}` in one evaluate — one
disclosure per result.

## Tree

```
mcp/nushell-mcp/modules/core/*.nu     # census, schema, spine, views, meta, value, failure
mcp/nushell-mcp/modules/dataspection/mod.nu
  export use core/{census,schema,spine,views,meta}.nu *
  use jobs ["jobs stash"]; use par ["par cap"]
  export def --env read
mcp/nushell-mcp/skills/nushell/references/dataspection.md
config.nu             # use par *; use jobs *; use dataspection *
                      # do not preload core/*
```

Docstrings on every command. par-jobs amendments (step 3) landed
2026-08-22: `jobs-census` / `par emit` call `$payload | shape`
internally; `jobs read` uses the cap rule; retrieve is `jobs fetch`.

## Tests (child `nu -n`)

- `shape`: table (type, length, columns with types, nulls, bytes,
  one-line head ≤ ~80); string / int / record / empty list / null /
  closure → closed set, no error, `length` null where undefined
- `bytes` == `to nuon --raw | str length --utf-8-bytes` for a sample;
  unserializable → `bytes: null`
- `shape each` on `[1, "ab", [1 2 3], {a: 1}]`: 4 rows, `index` 0..3,
  no `columns`; `[]` → `[]`
- `schema` on a heterogeneous table: paths lexical, `[]` for lists,
  `types` sorted `|`-joined, coverage < 100 for a sparse path, hits ≥
  records; on a record: population of one, coverage 100
- `schema diff`: added / removed / changed with before/after types
- `schema check`: violations as rows, `ok` false, never throws
- `schema stats`: len stats on a string path; on a missing path →
  `n: 0`
- `spine`: sorted n-desc key-asc, `--top`, missing column → `[]`
- `page`: `kind` per input type; header arithmetic (`pages`, `at`,
  `n`); out of range → empty items + truthful header; `--around`
  window with line numbers on strings; never reorders
- `preview`: long string clipped with marker per mode; long list
  clipped with `[+K more]`; nested record keeps keys; idempotent
- `meta stamp`: record gains a closed `meta` with `verb`/`at`;
  `tag`/`elapsed`/`ref` present iff given; non-record wraps as
  `{meta, value}`; a table is wrapped, not merged per row; stamping
  twice replaces rather than nests
- `meta`: returns the sub-record; on an unstamped value → `null`, no
  throw
- `read`: suite loads `par`, `jobs`, then `dataspection`. Under cap
  returns the value. Over cap (force a low `$env.NU_PAR.max_inline_bytes`)
  returns `{ok: true, disclosed: false, tag, bytes, retrieve}` with
  `retrieve` matching `jobs fetch <tag>`; `jobs fetch <tag>` returns
  the original value; peek not pop (`$in` / a bound name still holds
  it). Decline receipt carries `meta.verb == "read"`. Jobs missing:
  `use dataspection` fails to load (static import; not `{ok: false}`).
  `--config` smoke required ([layering-v1](layering-v1.md)).
- every verb on `null` and on `""`: returns its shape, no throw
- forced internal failure (e.g. a closure value for `schema`, an
  unserializable value for `shape`): result has `error` (short) and
  `trace` (full rendered error, non-empty); success results have
  neither column

## Exit gate

In the MCP: `$history | shape each` after a few evaluates → receipt
table whose `index` matches the reported `history_index` values;
`$history.N | schema` on a real API-shaped record → path table with
coverage; `$history.N | preview` → the record, clipped, under the
output limit; `$history.N | get <path> | page 2 --size 20` → header +
20 items. Each is one receipt or one bounded body; nothing floods.
Over-cap `read` of a large string → decline receipt; `jobs fetch <tag>`
returns the string.

## Non-goals (v1)

- Reading `$history` implicitly (pipe it) — and no `hist` verb
- JSON Schema *generation* (a projection of `schema`, later if wanted)
- Column statistics beyond `nulls` / length stats (`polars` territory)
- Byte caps inside `page`/`preview`; smart sizing
- Searching inside values (`find` is the host's, over the journal;
  in-engine it is `where`)
- A second store. Over-cap `read` uses `$env.JOBS` via `jobs stash`;
  it does not grow `$env.DATASPECTION` or write files
- Exporting `inspect` (nushell's builtin stays). On a value in hand
  the census noun is `shape`
- `jobs shape` / collapsing `jobs inspect` into `read | shape` — jobs
  keeps its own inspect receipt; that is the amendment's problem, not
  this module's export list

---

## Follow-up report

- Landed 2026-08-22. Tree as spec: `modules/dataspection/mod.nu`, `references/dataspection.md`, `config.nu` preloads `par` then `jobs` then `dataspection`. Corpus: `mcp.md`, `sessions.md`, `gotchas.md`, `SKILL.md`. Adapters: `~/.claude/skills/nushell-mcp`, `~/.grok/skills/nushell-mcp`.
- Child tests: `nu -n mcp/nushell-mcp/tests/dataspection-v1.nu` — 13/13 (shape table + scalars + each, schema + diff/check/stats, spine, page, preview, meta stamp, read under/over cap, read jobs-missing child, null/"", forced failure).
- MCP exit gate: `$history | shape each` after a few evaluates; `$history.N | schema` / `preview` / `page`; over-cap `read` then `jobs read <tag>`.
- Deviations / spec fills:
  - `schema` on a top-level closure is fail-as-data (`ok: false` + `error`/`trace`). Walking a closure would otherwise return `[]` and hide the unserializable case the test list asked for.
  - `spine` groups with a closure (`group-by {|row| $row | get $column}`). A string variable is an unsupported grouper; a literal column name still works at the REPL.
  - Sort is n-desc then key-asc by grouping on `n`, then sorting each group by NUON of `key` (Nu `sort-by` is not a stable two-key sort).
  - `shape each` builds `ok`/`verb` in one record; mutating `ok: null` to a bool is a type mismatch.
  - Jobs-missing `read` is a child `nu -n -c` without `use jobs` (cannot unload jobs from the suite overlay).
  - `schema` shadows SQLite's `schema` while the module is in the overlay — recorded in `gotchas.md`.
- Not this brief (unchanged): `$history` indexing, JSON Schema generation, tags/notes storage, `jobs inspect` calling `shape` (step 3).
