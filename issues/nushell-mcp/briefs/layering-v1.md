# Layering v1 — census primitives vs handle-plane quarantine

**Status:** ruled A · **Filed:** 2026-08-22 · **Ruled:** 2026-08-22 ·
**Home:** `mcp/nushell-mcp/modules/core/*.nu` (units) +
`modules/dataspection/mod.nu` (façade). **Depends on:**
[dataspection-v1](dataspection-v1.md),
[par-jobs-v1](../.archive/par-jobs-v1.md) (2026-08-22 amendment).
**Blocks:** [xq-v1](xq-v1.md). **Not this brief:** implementing xq/rg/gh;
session host; a verb dispatcher. `jobs fetch` is N10 (landed after this cut). **Trail:**
[sol-circularity-remediation.md](../discussion/sol-circularity-remediation.md),
[sol-nushell-mcp-rearchitect-revisions.md](../discussion/sol-nushell-mcp-rearchitect-revisions.md).

Treat this file as the v1 spec. Amend; do not fork.

## Problem

The 2026-08-22 par-jobs amendment made `jobs inspect` / drain census
call `shape`, and receipts call `meta stamp`, so `bytes` and `meta`
have one definition. To resolve those names inside `jobs` (overlay
`use *` does not leak into a module's scope) the amendment did
`use dataspection *` from `jobs/mod.nu`, and `use dataspection [shape]`
from `par/mod.nu`.

That import loads **all of** `dataspection/mod.nu`. Selective
`use dataspection [shape]` is not a partial parse. `read` — the only
dataspection command that writes `$env.JOBS` — is compiled as a
side-effect of `use par *`, **before** `jobs` exists.

In the live launch path (`nu --mcp --config config.nu`, and a bare
`nu --config config.nu -c`):

```
$x | read          # over cap
→ {ok: false, error: "Command `jobs` not found", …}
```

`scope commands` still lists `jobs stash`, so the “jobs missing” guard
does not fire. The call site inside `read` is parsed as an external
`jobs`. `jobs stash` from the overlay works. Child tests
(`nu -n mcp/nushell-mcp/tests/*.nu`) did **not** catch this: they
`use` from the script overlay, which is not the config overlay the
MCP child uses.

So: census consumption by the handle plane broke in-hand `read` under
the only launch path that matters, and the test bar did not see it.

## Nature of the flaw

Portable verbs (`inspect`, `read`, `preview`, `page`, `stamp`) are
**meanings**. They were never going to be one implementation:
`jobs inspect` is not `shape`; `nu-modules inspect` is another object.
Meanings live in [vocabulary.md](../notes/vocabulary.md). Encoding them
as a table of handles is already refused (AGENTS.md: contracts
documented, not encoded).

What `dataspection/mod.nu` actually mixed is two **dependency
classes**:

| Class | Commands | Depends on jobs? | Needed by par/jobs? |
|---|---|---|---|
| In-hand, pure | `shape`, `shape each`, `meta stamp`, `preview`, `page`, `schema`, `spine` | no | `shape` and `stamp` yes |
| Quarantine | `read` | **yes** (`jobs stash`) | no |

`read` looks special because it is the only impure command in a census
module. The knot is packaging: the handle plane was told to import
census, and census owned a client of the handle plane.

Agent-facing custom commands are **terminal composition surfaces, not
libraries**. Split a module when (1) a lower layer needs only part of
it, or (2) a downstream wrapper needs the data before disclosure
policy runs. (1) is this cut. (2) is `process capture` on xq-v1 — not
this landing.

Nushell facts (verified 2026-08-22, nu 0.114.1):

- Multi-word commands resolve from the **defining module's** scope.
- There is no command named `jobs` (no `main`); a bare `jobs stash`
  without `use jobs` becomes an external `jobs`.
- `use module [cmd]` still loads `mod.nu` in full.
- Relative `use` is cwd-first, then `NU_LIB_DIRS`. Sibling imports
  are `NU_LIB_DIRS` names (`core/census.nu`), not `../`.
- `nu-modules` treats only **immediate** children of `NU_LIB_DIRS`
  with `mod.nu` as `kind: module`. A nested `core/census/mod.nu` would
  list as a stray file. Loose `.nu` files under a dir with no `mod.nu`
  list as `core/census.nu` (`kind: file`) — the formats/crypto pattern.

## Rule

> A module the handle plane imports must not import the handle plane.

In-hand primitives with no jobs/par dependency are shareable; anything
that writes `$env.JOBS` is handle-plane work. Overlay preload is the
agent surface, not dependency injection into definitions.

## Cut — A (ruled)

Sibling **file units** under `modules/core/` (no `core/mod.nu`, no
`dataspection-core`, no `nushell-mcp-core`). `par` and `jobs` import
those files, never `dataspection/mod.nu`. `dataspection` is the
jobs-aware façade agents already `use`.

### Tree

```
mcp/nushell-mcp/modules/core/     # no mod.nu
  failure.nu     # failure fields — normalize a caught Nu error
  value.nu       # value kind, value columns, value nuon
  census.nu      # shape, shape each          ← par, jobs
  schema.nu      # schema, schema diff/check/stats
  spine.nu       # spine                      ← rg later
  views.nu       # preview, page
  meta.nu        # meta, meta stamp           ← jobs
  capture.nu     # later, xq-v1: process capture
dataspection/mod.nu              # export use core/{census,schema,spine,views,meta}.nu *
                                 # use jobs ["jobs stash"]; use par ["par cap"]
                                 # export def --env read
```

`capture.nu` is **not** this landing. It lands with xq-v1.

### Units

**`failure.nu`** — `failure fields <error>` → `{error, trace}`. Does
not throw. Replaces duplicated `catch-fields`. Optional later for
`jobs-short`; not required to close the cycle.

**`value.nu`** — `value kind`, `value columns`, `value nuon`.
`value nuon` returns `{ok: true, bytes, nuon}` or `{ok: false, bytes:
null, nuon: "", error, trace}`. This is the internal source of the
one `bytes` measurement. **`shape` remains the agent-facing census
contract.** `par` and `jobs` call `shape`, never `value nuon`.

**`census.nu`** — `shape`, `shape each`. Imports `value` and `failure`
only. This is what `par` and `jobs` consume.

**`schema.nu`** — the whole schema family in one file. Do not split
`schema diff` out (would export traversal internals).

**`spine.nu`** — `spine` only. Own file because rg needs it without
schema or views.

**`views.nu`** — `preview`, `page` plus clipping helpers. One unit
(bounded view of a value in hand). Do not split into `preview.nu` /
`page.nu` for v1.

**`meta.nu`** — `meta`, `meta stamp`. Metadata is still data; the file
is not a new practice. `jobs` imports `"meta stamp"` only.

Cross-file helpers **must** be those exported, qualified commands
(`value kind`, `failure fields`). The façade does **not** re-export
`value.*` or `failure fields`. They will appear in `nu-modules list`;
document as dependency units, do not hide them, do not put them on
`use dataspection *`.

### Who imports what

```
failure
   ▲
 value
   ▲
   ├──── census  ← par, jobs
   ├──── schema
   ├──── spine   ← rg (later)
   ├──── views
   └──── meta    ← jobs

dataspection façade
   ├── export use census/schema/spine/views/meta
   ├── use par ["par cap"]
   ├── use jobs ["jobs stash"]
   └── owns read
```

`export use core/census.nu *` already puts `shape` in the façade
scope; do not also `use core/census.nu [shape]`.

### Overlay (`config.nu`)

Unchanged agent surface. Do **not** `use core/*` here.

```
use nu-skills *
use nu-modules *
use par *
use jobs *
use dataspection *
```

Agents keep `use dataspection *` then `$x | shape` / `preview` / `read`.

Once the façade statically imports `jobs stash`, “jobs missing” is a
**module-construction failure** (throw / cannot `use dataspection`),
not `{ok: false}`. Drop the `scope commands` guard and the dataspection
jobs-missing child test. Drop NUON fallbacks in `par` and `jobs`.

### Failure semantics

Unchanged at the exported-command boundary: expected failure is
`ok: false` + `error` / `trace`; throws are parse/load/unresolved
definition/engine invariants. Private helpers may throw internally if
the export catches and translates.

## Retrieve — N10 (landed after this cut)

`--full` made `read` mean two things. `jobs fetch` is the uncapped
stored body. `jobs read` has no `--full`. Decline `retrieve` is
`jobs fetch <tag>`. Do not drop `jobs read`.

## Tests

Child `nu -n` suites are not sufficient.

```
nu --config mcp/nushell-mcp/config.nu -c '<over-cap value> | read'
```

Must return a decline receipt with pasteable `retrieve`, not
`Command jobs not found`. Also: `jobs inspect` bytes equal
`$payload | shape`; receipts still carry `meta`; `par cap` unchanged;
`use dataspection *` without jobs **fails to load**.

xq/rg/gh `mod.nu` files `use` jobs/par/core units they call, at
**module** scope. Overlay leak is not a plan.

## Landing

Implementation of `core/*.nu` (except `capture.nu`) + façade `read` +
static imports in `par`/`jobs`/`dataspection`. Docstrings, 
`references/dataspection.md` + `jobs.md`, adapter skills, this
follow-up. Sequence: this cut, then N10 (`jobs fetch`), then xq-v1
(with `core/capture.nu`).

## Rejected

- **B** — `read` moves onto jobs as a flat export. Smaller graph;
  surprising overlay; disclosure ladder no longer one `use dataspection *`.
- **Circular `use`** on `dataspection/mod.nu`. `par` already loads it first.
- **Env / closure hook** for stash.
- **Copy NUON / `meta` inside jobs.**
- **A module named `read`.**
- **`dataspection-core` as the import name.** Handle plane would still
  `use` a dataspection-branded library.
- **`nushell-mcp-core` as one bag.** Collides with the package; next
  extract (`capture`) would stuff or lie.
- **Nested `core/census/mod.nu`.** Breaks `nu-modules` discovery.
- **Jobs-only `fetch`, dropping `jobs read`.**
- **In-hand `read` that does not stash.**
- **A verb registry / dispatcher.**
- **`par`/`jobs` calling `value nuon` instead of `shape`.**

---

## Follow-up report

- Landed 2026-08-22. Tree as spec: `modules/core/{failure,value,census,schema,spine,views,meta}.nu`; façade `dataspection/mod.nu` (`export use` those, `use jobs ["jobs stash"]`, `use par ["par cap"]`, owns `read`). `par` `use core/census.nu [shape]`; `jobs` `use core/census.nu [shape]`, `core/meta.nu ["meta stamp"]`, `par ["par cap" "par budget" "par emit"]`. No `capture.nu`.
- Child tests: `nu -n mcp/nushell-mcp/tests/dataspection-v1.nu` — 13/13 (jobs-missing replaced by `--config` over-cap `read`); `par-jobs-v1.nu` — 27/27.
- `--config` smoke: over-cap `$x | read` → decline + `retrieve: jobs read <tag> --full` (**superseded by N10:** retrieve is `jobs fetch` + NUON-quoted tag). Overlay has `shape`/`read`, not `value nuon` / `failure fields`.
- Deviations:
  - `schema.nu` / `spine.nu` / `meta.nu` export the noun as `main` (Nu forbids `export def` named the same as the file stem). After `use`/`export use *` the command is still `schema` / `spine` / `meta`.
  - `read` uses `$x | shape` for `bytes` (not `value nuon` directly).
- Not this landing: `jobs fetch` (N10), `core/capture.nu` (N11 / xq-v1).
