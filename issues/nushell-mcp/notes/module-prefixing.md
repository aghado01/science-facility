# Module prefixing — parked decision, accumulated rationale

**Written:** 2026-08-22 · **Status:** **parked, not decided.** Owner is
holding it; nothing in the repo assumes it. Current state: `par`,
`jobs`, `dataspection`, `meta` bare; `nu-skills`, `nu-modules`
prefixed by accident of history.
**Related:** [vocabulary](vocabulary.md) (naming rules),
`mcp/nushell-mcp/AGENTS.md` (the landing gate this would make visible).

## The question

`modules/` mixes two populations that nothing currently distinguishes:

- **Furnished by this console** — `nu-skills`, `nu-modules`, `par`,
  `jobs`, and (unbuilt) `dataspection`, `meta`, `xq`, `rg`, `gh`.
- **Vendored general utilities** — `argx`, `formats`, `crypto`,
  `duplicates`, `data_extraction`, `with_externals`. Mostly
  nu_scripts-derived; some modified here.

Should the first group carry a prefix?

## Why `use`-pinning forces the question

Today *pinned* and *furnished* coincide — `config.nu` preloads exactly
`nu-skills`, `nu-modules`, `par`, `jobs` — so pinning **accidentally**
marks provenance. The moment general primitives get pinned too (owner
wants `argx` reachable without loading, and likely others), that
correlation breaks: the agent sees one flat namespace where
`argx parse`, `par budget`, and `shape` all look alike, with nothing
indicating which has a spec behind it.

So pinning-everything is what removes the existing signal, and is the
strongest argument for replacing it with a deliberate one.

## What the prefix should mean

Not "part of the brand" — that is a judgment call and will drift.
Better: **"has a contract in this repo"** — a brief in
`issues/nushell-mcp/briefs/`, a reference-corpus entry, and a
follow-up report on landing. That is precisely AGENTS.md's landing
gate, so the prefix becomes a *visible marker of a rule already
enforced* rather than a new category to maintain.

It sorts without argument:

| Prefixed (has a contract) | Bare (no contract) |
|---|---|
| `nu-skills`, `nu-modules`, `par`, `jobs`, `dataspection`, `meta`, `xq`, `rg`, `gh` | `argx`, `formats`, `crypto`, `duplicates`, `data_extraction`, `with_externals` |

`argx` is the useful test case: substantially modified here, has its
own suite, pinned for reach — and still bare, because it is a general
utility maintained here rather than a capability this console
furnishes. The rule gets that right without anyone deciding.

And it says something actionable to an agent: prefixed means spec'd,
tested, documented in the corpus, safe to build on; bare means it
works but carries no promise.

## Three mechanisms, three audiences

The goal ("group them, make them visible") is served differently
depending on who is looking:

| Mechanism | Audience | Cost |
|---|---|---|
| **Name prefix** (`nu-dataspection`) | the **agent**, at the point of use — the command name itself carries it | renames `par`, `jobs` and every reference |
| **Subdirectory** (`modules/{furnished,lib}/`) | the **developer** browsing the tree | none — `NU_LIB_DIRS` takes both paths, `use` unaffected |
| **A `source` column in `nu-modules list`** | the **agent**, on lookup | none — a data change in the concierge |

These are not exclusive. The subdirectory and the column are free and
could land whenever; only the prefix requires renaming.

## Timing: all-or-nothing

Prefixing is free for modules that do not exist yet
(`dataspection`, `meta`, `xq`, `rg`, `gh`) and expensive for landed
ones (`par`, `jobs` — code, tests, corpus, cross-brief links). The
temptation is to adopt it for new modules and backfill later; **that
is the worst outcome**, because a half-applied convention reads as
inconsistency rather than as a rule. Decide once, apply everywhere, or
not at all.

## If it is ever adopted

- Prefix candidate is `nu-`, already established by `nu-skills` /
  `nu-modules`. Note it currently reads as *about nushell* (both of
  those genuinely are); adopting it for provenance redefines it to
  *furnished by this console*. Say so explicitly in AGENTS.md, or the
  next reader will infer the older sense.
- The rename touches: module directories, `config.nu` preloads, every
  brief's Tree section, the reference corpus, docstrings, and
  `nu-modules list` output in tests.
- `dataspection` keeps its practice-name either way
  (`nu-dataspection`); the prefix marks provenance, not kind.
