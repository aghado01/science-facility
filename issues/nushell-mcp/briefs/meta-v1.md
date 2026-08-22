# `meta` v1 — provenance stamped onto records

**Status:** filed, not started · **Filed:** 2026-08-22 · **Home:**
`mcp/nushell-mcp/modules/meta`, Nu-native, pure.
**Depends on:** nothing. **Consumed by:** par-jobs amendments
(receipts), xq-v1, rg-wrapper-v1, the session host (lifts `meta` into
journal `note` data).
**Not this brief:** the `$history` index (session host), tags/notes
storage (nothing in Nu tracks them), identity receipts
([identity-routing](../notes/identity-routing.md)).

Treat this file as the v1 spec. Amend; do not fork.

## Why its own module

`stamp` was drafted inside the dataspection module and does not belong
there: dataspection **describes** what it is handed, `stamp`
**writes** onto it. It is the only command in that set that modifies
its input, and the membership rule ("operates on a value in hand,
describing it") excludes it.

It is also the case that makes the verb vocabulary portable. `stamp`
is a real act with a real object — times get stamped, dates get
stamped, identities get stamped — so it takes a noun domain, exactly
as `inspect` and `read` do:

```
meta stamp        # stamp a meta record onto this
```

A module that writes timestamps would have its own `stamp`, meaning
the same act on a different object. The verb is the constant; the
namespace is the variable. Bare `stamp` is refused for the same reason
"deferred bodies" was: unqualified it is the rubber-stamp metaphor,
which is not what this does.

## `meta stamp`

```
$rec | meta stamp --verb <string> [--tag t] [--elapsed d] [--ref {...}]
→ $rec | merge {meta: {verb, at, tag?, elapsed?, ref?}}
```

- **Closed sub-record.** `verb` is the producing command, dotted
  (`jobs.spawn`, `par.emit`, `xq`, `rg`, `note`) — **not** `kind`,
  which is spoken for by the journal record kind, `page`'s unit, and
  rg's finding kind ([vocabulary](../notes/vocabulary.md)).
  `at` = `date now`. `ref` points at other entries:
  `{history: 7}` (the `$history` index) or `{tag: "sweep"}`.
- **Records are stamped; tables stay bare.** On a non-record input
  `stamp` wraps: `{meta, value}` — opt-in, never automatic. Wrapping a
  table would break `| where` on the thing agents pipe most.
- Pure: no env, no clock beyond `date now`, no storage.

## `meta of`

```
$rec | meta of
→ the `meta` sub-record, or null when unstamped
```

Projection, so consumers do not reach into `$rec.meta?` by hand and
disagree about the absent case. Never throws.

## Why this matters (the two failure levels)

A verb that catches an error and returns `ok: false` is a **successful
evaluate** to the engine — it gets a `history_index` and looks like any
other entry. `meta` plus the universal `ok` is what keeps that legible:
`$history | shape each` lifts both, so
`$history | shape each | where ok == false` finds every caught failure
without opening one. Without the stamp, the spine of the session is
values with positions and nothing else.

## Tree

```
mcp/nushell-mcp/modules/meta/
  mod.nu              # meta stamp, meta of
mcp/nushell-mcp/skills/nushell/references/dataspection.md
  + the stamp convention and what lifts it
config.nu             # use meta
```

`use meta` (not `use meta *`) — the commands are namespaced, since
they address a domain rather than acting on a value in hand.

## Tests (child `nu -n`)

- record gains `meta` with `verb`/`at`; `tag`/`elapsed`/`ref` present
  iff given, absent otherwise
- non-record (string, list, int, null) wraps as `{meta, value}`
- a table piped through is wrapped, not merged per row
- `meta of` returns the sub-record; on an unstamped value → `null`,
  no throw
- stamping twice replaces `meta`, does not nest it
- `verb` is required; omitting it errors at the signature

## Exit gate

`{ok: true, n: 3} | meta stamp --verb par.emit --tag sweep` → the
record plus one closed `meta`; `| meta of` → that sub-record;
`$history | shape each` shows `verb` lifted into the census row.

## Non-goals (v1)

- Automatic stamping of anything
- Mutating or removing a stamp (`meta strip` — add only if wanted)
- Tags/notes storage; that is the host's journal
- Identity receipts (`{scope, id, source, via}`) — a different shape
  with a different owner

---

## Follow-up report

_Chip or implementer: append outcome, tests run, deviations from this spec._
