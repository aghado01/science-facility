# `dataspection` v1 — disciplined access to data

**Status:** filed, not started · **Filed:** 2026-08-21 · **Home:**
`mcp/nushell-mcp/modules/dataspection`, Nu-native, pure (value in,
value out), used through `evaluate`. **Supersedes:**
[hist-v1](../.archive/hist-v1.md).
**Depends on:** nothing in-layer. **Consumed by:** par-jobs
amendments (`jobs inspect` → `read | shape`), xq-v1, rg-wrapper-v1
(`spine`), the session host (calls `shape` for informative
truncation). **Lineage:** jso-jackson / jso-debug (graveyard) — the
controlled-inspection doctrine, re-shaped for a runtime where data is
already structured.
**Not this brief:** `$history` indexing (session host), `meta stamp`
([meta-v1](meta-v1.md)), JSON Schema generation, anything that writes.

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
belongs to that thing's domain module (`jobs`, `nu-modules`, `meta`).

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

**Verbs interact with whatever object is in hand.** They are
**portable** — each means one thing wherever it appears, including in
other domains (`jobs inspect`, `nu-modules read`, `meta stamp`):

| Verb | Means |
|---|---|
| `inspect` | describe without disclosing |
| `read` | disclose the body |
| `preview` | the whole structure, leaves clipped to specification |
| `page` | one slice, with a truthful header |

Because they compose, a produced object is just another object:

```
$x | schema | preview            # the schema is large — clip it
$x | spine file | page 2         # the spine is long — slice it
$x | schema | shape              # how big is this schema, actually
jobs read sq | shape             # pull the payload, then shape it
```

That last line is an identity worth stating: **`jobs inspect <tag>` ≡
`jobs read <tag> | shape`, plus the job's identity fields.** Same for
`nu-modules inspect`. `inspect` on an addressed thing simply *is*
read-then-shape, which is why there is one census definition and not
several.

**Holding is not seeing.** From the agent's side every value in the
engine is a handle — `$x`, `$history.7`, a registry payload, an
intermediate pipeline stage. The agent never has the bytes, only a
name the engine can resolve, and nothing is disclosed unless it fits
the cap. So `read` is meaningful on a piped value, not only on a
stored one, and the verb vocabulary is uniform across both.

## The disclosure ladder

One rule, expressed as four verbs. This is where "no silent omission"
stops being prose and becomes enforceable:

| Verb | Discloses | Always fits? |
|---|---|---|
| `inspect` / `shape` | nothing — census only | yes, by construction |
| `read` | the whole body | **only if under cap** — otherwise a receipt naming where it went and pointing at the bounded verbs |
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
   retrieve: string} when it does not
```

- The **disclosure verb**, and the only one that may decline. Under
  `max_inline_bytes` it returns the value. Over it, the value is
  stashed and the receipt names the retrieval (`retrieve: "page"` /
  `"preview"` / `"jobs read <tag>"`) — never a bare "too big".
- This is the one cap rule for the whole layer. `jobs read`,
  `xq`, and the rg module apply *this*, not their own copy.
- Peek, not pop: `read` never removes or mutates what it discloses.

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
mcp/nushell-mcp/modules/dataspection/
  mod.nu              # shape, shape each, schema (+diff/check/stats), spine, page, preview, read
mcp/nushell-mcp/skills/nushell/references/dataspection.md
  the two vocabularies, the disclosure ladder, the drill loop, jso lineage
mcp/nushell-mcp/skills/nushell/references/mcp.md
  + `$history | shape each` as the history idiom
config.nu             # use dataspection *   (before par/jobs, which call shape/read)
```

Docstrings on every command. On landing, par-jobs amendments (step 3
of the roadmap) switch `jobs-census` to `shape`, and `par emit` /
`jobs read` to the `read` cap rule.

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
- `read`: under cap returns the value; over cap returns
  `{disclosed: false, tag, bytes, retrieve}` and the value is
  retrievable by that tag; peek not pop
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

## Non-goals (v1)

- Reading `$history` implicitly (pipe it) — and no `hist` verb
- `meta stamp` — moved to its own module ([meta-v1](meta-v1.md))
- JSON Schema *generation* (a projection of `schema`, later if wanted)
- Column statistics beyond `nulls` / length stats (`polars` territory)
- Byte caps inside `page`/`preview`; smart sizing
- Searching inside values (`find` is the host's, over the journal;
  in-engine it is `where`)
- Any write, any env mutation, any dependency on `jobs`

---

## Follow-up report

_Chip or implementer: append outcome, tests run, deviations from this spec._
