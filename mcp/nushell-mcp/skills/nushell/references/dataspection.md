# dataspection — disciplined access to a value in hand

Named for the **practice**, not for what it holds. `jobs` / `nu-modules` are domain modules; this one is census before body, receipts before disclosure, bounded views, no silent omission.

Preloaded: `use par *; use jobs *; use dataspection *` (`config.nu`). Does **not** export `inspect` — nushell's builtin passthrough stays; on a value in hand the census noun is `shape`. Does **not** export bare `stamp`.

Lineage: jso-jackson / jso-debug (graveyard). The file/JSONL/formatter layer dissolved; the drill loop survived.

## Two vocabularies

Nouns produce a data object. Verbs are **portable** (one meaning wherever they appear). They compose: a produced object is just another object.

| Noun | Object |
|---|---|
| `shape` | census of one value |
| `schema` | structural profile of a population |
| `spine` | where the mass is, over a column |
| `meta` | provenance on a record, or `null` |

| Verb | Means |
|---|---|
| `inspect` | describe without disclosing (`jobs inspect`, `nu-modules inspect`; in hand: `shape`) |
| `read` | disclose the body; the one cap rule |
| `preview` | whole structure, leaves clipped |
| `page` | one slice, truthful header |
| `stamp` | write metadata onto it — always qualified (`meta stamp`) |

```
$x | schema | preview
$x | spine file | page 2
jobs fetch sq | shape         # compose after a lawful disclose, not an identity
```

`jobs inspect` is **not** `jobs read | shape`. Inspect discloses nothing; jobs keeps its own receipt and calls `shape` on the stored payload internally.

## Disclosure ladder

| Verb | Discloses | Always fits? |
|---|---|---|
| `shape` | nothing — census | yes |
| `read` | the whole body | only under cap; else a receipt naming `jobs fetch <tag>` |
| `preview` | whole structure, leaves clipped | yes, per leaf |
| `page` | one slice | yes, per slice |

`read` is the only verb that may decline. Declining is not failure (`ok: true`). No silent omission: anything withheld names the retrieval.

## Drill loop (one disclosure per evaluate)

```
$x | shape                     # what is it
$x | schema                    # where does structure vary
$x | schema stats body.text    # is this field safe
$x | preview --chars 200       # one record, clipped
$x | get body.items | page 2   # descend, one page
```

Never `each {|i| ... | page $i}` in one evaluate. `$history | shape each` is the session census; `index` is the `$history` slot (`history_index` on the tool result). `| where ok == false` finds caught failures.

## Commands

**`shape`** → `{type, length, bytes, columns?, nulls?, head, error?, trace?}`. `bytes` is NUON UTF-8 length (the one definition). Unserializable → `bytes: null` + `error`/`trace`. Lifts `ok` from a record when present.

**`shape each`** → table `{index, type, length, bytes, ok, verb, head}`. Lifts `ok` / `meta.verb`. Empty list → `[]`.

**`schema`** → `{path, types, coverage, hits, records}`. Paths dotted, lists `[]` (`body.items[].id`). A record is a population of one. `schema diff`, `schema check <profile>`, `schema stats <path>` (missing path → `n: 0`).

**`spine <column> [--top N]`** → `{key, n}`, n desc then key asc. Missing column → `[]`.

**`page [n] [--size 50] [--at K] [--around K -C k]`** → `{kind, total, size, page, pages, at, n, items}`. kind `rows|lines|chars`. page is 1-based; `--at` is a 0-based offset; `--around` is 1-based (peek idiom). Out of range → empty items, header truthful. Never re-sorts.

**`preview [--chars 200] [--items 5] [--mode head|tail|sandwich]`** — strings `… [+N chars]`, lists `[+K more]`, records keep every key. Idempotent.

**`read`** (`--env`) — under cap, the value; over cap, `jobs stash` and `{ok: true, disclosed: false, tag, bytes, retrieve, meta.verb: "read"}`. `retrieve` is `jobs fetch <tag>`. Cap is `par cap`. Peek, not pop. Façade statically `use`s `jobs stash`; a session without jobs cannot load `dataspection`. `jobs read` is the same cap rule for an addressed payload; `jobs fetch` always returns the stored body.

Census/schema/spine/views/meta live in `modules/core/*.nu`; this module re-exports them. `value.*` / `failure fields` are not on `use dataspection *`.

**`meta`** — `{verb, at, tag?, elapsed?, ref?}` or `null`. Not the builtin `metadata` (pipeline `{span}`, stripped in `$history`).

**`meta stamp --verb <dotted> [--tag] [--elapsed] [--ref]`** — records merge `meta`; anything else wraps `{meta, value}` (tables included, not per-row). Twice replaces, never nests.

No command throws on odd input. Internal failure is `{error, trace}` on the command's result; both fields are absent on success.

## Gotchas in this module

- Builtin `inspect` is a flood trap under `--mcp`. Use `shape`.
- `schema` shadows SQLite's `schema` while this module is in the overlay.
- `read` is the only `--env` verb here; it uses `$env.JOBS`, not a second store.
