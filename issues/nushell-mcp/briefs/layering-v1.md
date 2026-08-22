# Layering v1 — census primitives vs handle-plane quarantine

**Status:** filed, decision open · **Filed:** 2026-08-22 · **Home:**
this brief (spec); implementation path depends on the decision below.
**Depends on:** [dataspection-v1](dataspection-v1.md),
[par-jobs-v1](../.archive/par-jobs-v1.md) (2026-08-22 amendment).
**Blocks:** [xq-v1](xq-v1.md) and every later wrapper that `use`s jobs
from its own `mod.nu`. **Not this brief:** xq itself, session host,
renaming portable verbs, a verb dispatcher / vocabulary object.

Treat this file as the v1 spec for the cut. Amend; do not fork. Pick
**A** or **B** in place before landing code.

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

`jobs read --full` (uncapped retrieve) is a **different** problem —
one verb meaning two things — and is orthogonal. See *Retrieve* below.

Nushell facts this depends on (verified 2026-08-22, nu 0.114.1):

- Multi-word commands (`jobs stash`, `par cap`, `meta stamp`) resolve
  from the **defining module's** scope, not the caller's overlay.
- There is no command named `jobs` (no `main`); a bare `jobs stash`
  without `use jobs` becomes an external `jobs`.
- `use module [cmd]` still loads `mod.nu` in full.
- Relative `use` is cwd-first, then `NU_LIB_DIRS`. Handle-plane
  imports of a sibling should be a `NU_LIB_DIRS` name, not `../`.

## Rule

> A module the handle plane imports must not import the handle plane.

Equivalently: **in-hand primitives with no jobs/par dependency are
shareable; anything that writes `$env.JOBS` is handle-plane work.**
`read` belongs with `stash`, not with `shape`. That is the less
special-case statement. Carving `read` out as a one-off file while
leaving the rest named `dataspection` is the same DAG with a weaker
identity.

## Proposed solutions

Both obey the rule. Pick one. Do not mix.

### A — sibling primitives, dataspection as facade (recommended)

A first-class `NU_LIB_DIRS` module holds the shared in-hand
implementations. `par` and `jobs` import **that**, never
`dataspection/mod.nu`. `dataspection` becomes the jobs-aware facade
agents already `use`:

```
<primitives>     shape, shape each, meta, meta stamp,
                 preview, page, schema, spine
    ↑        ↑           ↑
   par      jobs     dataspection/mod.nu
                           │
                           └── use jobs * ; export def --env read
```

Overlay load order unchanged:

```
use par *            # use <primitives> [shape]
use jobs *           # use <primitives> [shape "meta stamp"]
use dataspection *   # export use <primitives> *; use jobs *; read
```

`use dataspection *` first still works: facade → jobs → primitives,
never back into `read`'s file from `par`.

Agent surface unchanged (`shape`, `read`, `meta stamp` still arrive
via `use dataspection *`). Nushell only imports **exports**, so the
primitive module must contain schema/page/preview if they share
private helpers with `shape` — not only the two commands jobs calls.

**Name.** Not a verb (`inspect`, `read`, `probe` — already rejected as
module names). Not a coined third practice if `dataspection` remains
the agent-facing word. Fill the directory name in this brief when
landing; the overlay word stays `dataspection`.

### B — invert: dataspection *is* the primitive module; `read` moves to jobs

No third directory. Strip `read` from dataspection. Dataspection is
then the shared in-hand module (`par`/`jobs`/`xq` may import it).
Quarantine lives on the handle plane: `stash`, addressed `jobs read`,
uncapped retrieve, and in-hand `read` as a flat export of `jobs`.

```
dataspection     # no jobs dependency
    ↑        ↑
   par      jobs     # jobs exports `read` and `jobs read`
```

Smaller graph. Cost: `use jobs *` exports a flat `read`, which is
surprising next to `jobs read`, and the disclosure ladder is no
longer one `use dataspection *`. Honest if we say out loud that
`read` is quarantine, not census.

### Retrieve (orthogonal; do with A or B)

`--full` makes portable `read` mean two things (cap rule vs never
decline). A jobs-only verb for the stored body keeps `read` pure:

| Verb | Means | Cap |
|---|---|---|
| `jobs inspect` | describe, no body | always fits |
| `jobs read` | portable disclose | yes; decline names retrieve |
| `jobs fetch` | the stored payload | **no** |

In-hand `read` over cap → `jobs stash`; `retrieve: "jobs fetch <tag>"`.
`jobs fetch` is today's `--full`. xq drill uses `fetch`. This does
**not** break the cycle and does **not** replace `jobs read`.

## Rejected

- **Circular `use dataspection` ↔ `use jobs` on `mod.nu`.** `par`
  already loads `mod.nu` first.
- **Env / closure hook** (`$env.NU_READ_STASH`). Hidden second protocol.
- **Copy NUON / `meta` inside jobs.** Two `bytes` definitions; the
  amendment exists to prevent that.
- **A module named `read`.** Verb as package name; same DAG as A with
  a worse overlay word.
- **Jobs-only disclose named `fetch`, dropping `jobs read`.** Drops
  the portable verb on addressed payloads.
- **In-hand `read` that does not stash.** Decline would lose the body
  (silent omission). The `stash` dependency is correct; it must not
  sit in a file `par` loads.
- **A verb registry / dispatcher in the primitive module.** Meanings
  stay in vocabulary.md and docstrings.

## Tests (either decision)

Child `nu -n` suites are not sufficient. Add a smoke that uses the
MCP launch path:

```
nu --config mcp/nushell-mcp/config.nu -c '<over-cap value> | read'
```

Must return a decline receipt with a pasteable `retrieve`, not
`Command jobs not found`. Also: `jobs inspect` bytes still equal
`$payload | shape`; receipts still carry `meta`; `par cap` unchanged.

xq (and rg, gh) `mod.nu` files `use jobs *` and `use par *` at
**module** scope regardless of A/B. Overlay leak is not a plan.

## Landing

Same change as every other landing: implementation, `help` docstrings,
`references/dataspection.md` + `jobs.md`, adapter skills, this brief's
follow-up, vocabulary.md if `fetch` lands. Roadmap sequence: this cut
**before** xq.

---

## Follow-up report

_Chip or implementer: decision (A/B), primitive-module name if A,
whether `fetch` landed, tests run (include the `--config` smoke),
deviations._
