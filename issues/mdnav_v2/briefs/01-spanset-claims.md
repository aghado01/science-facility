# Phase 01 — `SpanSet`, claims table, stores, hygiene layout

> **Role:** execution-ready spec for roadmap milestones **M1 + M2**. Canon
> (doctrine, non-goals, method, master exit-gate list) is
> [mdnav_v2_design-brief.md](../design/mdnav_v2_design-brief.md); do not restate it here —
> read it first for the "why." Sequencing, dependencies and status live in
> [planning/roadmap.md](../planning/roadmap.md); decisions in
> [planning/decisions.md](../planning/decisions.md). Amend this file; do not
> fork it.

**Depends on:** nothing beyond M0 (baseline goldens captured, per roadmap).
**Delivers:** gates 1, 2, 3, 13, 14, 16 (capture). **Next phase:**
[02-collectors-parity.md](02-collectors-parity.md).

## 1. `SpanSet` — geometry algebra

Normalized sorted disjoint half-open byte intervals; linear two-pointer
`union`, `intersect`, `subtract`, `complement(len)`, `coverage`,
`contains(off)`. ~60 lines. **Identity-forgetting on purpose** — that is what
makes it usable as a mask. The Gemini sketch's `intersect`/`subtract` are
correct as written; prove it against a brute-force bitmap, not by inspection.

Standalone `span-set.mjs` (permitted sibling per the Non-goals module-split
rule): normalize, `union`, `intersect`, `subtract`, `complement(len)`,
`coverage`, `contains`. Bitmap oracle property tests (≥ 200 random sets). No
engine wiring yet — this module has no dependency on the claims table below
and should be built and tested first, alone.

## 2. Claims — the occurrence table

One table per document, **an in-memory value first** (typed arrays,
≈12–16 B/claim; buffers + claims ≈ 1.2× corpus bytes), columnar:
`starts[]`, `ends[]`, `kinds[]` (interned), `sources[]` (interned:
which collector), `levels[]` (`char|line|multi`), `priorities[]`,
`ruleIds[]` (interned, null for built-ins), `containers[]` (ordinal of the
immediate containing region claim, or −1), `info[]` (kind-specific: fence
lang, heading level+title, link target, footnote label…). Byte coordinates,
sorted `ClaimOrder.Geometry` (start asc, end desc, ordinal). **Overlap and
nesting are preserved** — a `data-uri` inside an `html-block` inside a
`fence` is three claims. No `noise` flag exists anywhere.

Kind vocabulary is **open**. Built-in kinds this phase must produce (today's
constructs, plus the ones the discussion named — the *collectors* that
populate them land in phase 02, but the table shape and its columns are this
phase's deliverable, so the vocabulary is specified here):

| family | kinds | extent rule | today |
|---|---|---|---|
| region (re-enterable) | `frontmatter` `fence` `html-block` `html-comment` `math-block` `blockquote` `list` `list-item` `table` `footnote-def` | frontmatter: `---`@0 … next `---`/`...` line; fence: opener char+len … matching closer or EOF (+ residue claim `fence-unclosed`); html-comment: `<!--` … first `-->` (multi-line, no nesting); html-block: CommonMark block **start conditions 1–7 with their end conditions** (1–5 terminator string, 6–7 blank line) — never open/close tag pairing; math-block: `$$` line … `$$` line; blockquote/list/table: contiguous runs as today; footnote-def: `^\[\^label\]:` … next non-continuation line | fence, html (line-runs), blockquote, list, table exist; rest missing |
| structural | `heading` `setext-heading` `break` `paragraph` | heading: ATX outside `fence ∪ html-comment ∪ frontmatter` (info: level, title, digest); setext: as today's suspects, promoted to a claim; **`break` = `-{3,}|\*{3,}|_{3,}` with blank line before, one regex shared by every consumer** (F2) | exist, disagree |
| inline object | `html-tag` `link` `link-ref` `image-ref` `data-uri` `signed-url` `footnote-ref` `inline-code` `wikilink` `custom:<id>` | today's regexes for `html-tag` (= today's `html` noise kind, single tag, inner text not part of the claim), `link`, `image-ref`, `data-uri`, `signed-url`; `footnote-ref` `\[\^[^\]\s]+\]` (info: label); `link-ref` `\[text\]\[id\]` / collapsed `[id][]` (info: id); `inline-code` backtick spans; `wikilink` `\[\[…\]\]`; all executed **region-scoped** (below) | first five exist, unmasked |
| definition | `footnote-def` `link-def` | `^\[\^label\]:` … next non-continuation line (region, re-enterable — a def body can hold links, code, even a nested list); `^\[id\]:\s*<?url>?` one line (info: id, target) | missing |

Footnotes (`[^1_1]` in prose, `[^1_1]: https://…` in foot-matter) and link
reference definitions are **idiomatic Markdown**, not a site disposition —
they are core kinds, and what matters is the **relation** between the
reference and its definition (phase 03), which is what an interactive
preview renders as a click.

Only shape decides membership (README §Triage principle stands): the
`signed-url` target test, the `data-uri` `![](…)` wrapper rule, the
`keepOf` label rule all carry over unchanged as claim `info`.

**Stores.** The engine is a persistent-process design: a server holds one
`Corpus` (buffers, claims, memoized views keyed by `(digest, policy)`) for
its lifetime and answers queries from memory; invalidation is
`statSync` size+mtime per query, digest on change, rebuild per document.
Disk is for what must survive a process: the **inventory** (`Dnnn` → path
— ids appear in agents' notes and must come back identical after restart)
and the **reads ledger** (coverage and provenance across sessions;
append-only JSONL as today). The sidecar (schema 3) is the serialization of
the in-memory table behind a small store interface — `MemoryStore` (server)
and `SidecarStore` (one-shot CLI, which has no warm process) — so the CLI
and a running server pointed at the same work-dir see one index. Views are
never persisted; they are cheap to recompute and policy-dependent.

**Hygiene — persistence with rehydration, not accretion.** Today every
`discover` mints `.doc-dive/<stamp>/` with its own `inventory.json` and
`documents/Dnnn.index.json` per doc, so N discoveries of one small document
leave N copies of its index, and ids are per-run. Split what is
*corpus-scoped* from what is *run-scoped*:

```
<work-dir>/
├── index/                         corpus-scoped, ONE copy, replaced in place
│   ├── inventory.json             Dnnn ↔ path — ids stable across runs and restarts
│   └── documents/Dnnn.json        digest, claims table (compact columnar JSON), no source body
├── <stamp>/                       run-scoped, small: provenance for one investigation
│   ├── reads.jsonl                append-only ledger (as today)
│   └── run.json                   which index digests this run read against
└── LATEST                         as today
```

A server **rehydrates** `index/` at start, refreshes a document only when
its digest changes, and rewrites that one file in place — never a second
copy. Runs stay stamped because a run *is* provenance, but a run holds one
ledger, not an index. `--work-dir` / `$MDNAV_WORK_DIR` / `<corpus>/.doc-dive/`
resolution and the "refuse a work dir the crawler can see" guard are
unchanged. Add `mdnav runs prune --keep <n>` (trivial) so an interactive
session's exhaust is one command to trim. The one-shot CLI keeps working
against the same layout — it has its own exaptations — it just pays the
rehydrate on each call instead of once.

## Ported presentation and IO

Populate the new claims table with **ported copies of the existing
scanners, unchanged** — outputs must stay identical while the plumbing
lands; the collector rewrite is phase 02, not this one. Also ported here,
because it is IO/presentation rather than engine, and is a prerequisite for
every later phase: `parseArgs` (fixed, see below), work-dir resolution +
refusal guard, inventory/ledger IO, all verb formatters, HELP.

**`parseArgs` whitelist (F4).** Today's `parseArgs` is greedy — any
`--flag` eats a following non-`--` token, which silently corrupts flag-order
edge cases. Whitelist value-taking flags: `by depth max-depth extent from
glob heading headings kind max min preview run span strip-match to truncate
windows within work-dir`; new here (consumed by later phases, whitelisted
now so the parser doesn't need touching again): `only enter rules profile
for in not-in out`. Boolean today: `comp composition help i recursive
refresh`; new: `resolve`. **`--strip` is optional-value** (bare = `all`):
treat it as value-taking only when the next token is `all` or a comma-list
whose every member is a known kind or `@profile`; otherwise bare. Anything
not in either list is an error, not a guess.

## Exit gate (this phase)

Full text is the master list in [mdnav_v2_design-brief.md](../design/mdnav_v2_design-brief.md)
§Exit gate. This phase closes:

- **1.** Every pre-existing acceptance test passes unchanged (F1/F2-encoding
  tests excepted — those invert in phase 02).
- **2.** `SpanSet` bitmap-oracle property test, ≥ 200 random sets, adjacency
  merge, normalization.
- **3.** Claims table ordering/containment/store-equivalence/sidecar
  round-trip/invalidation/id-stability/hygiene-layout assertions (full list
  in the master gate).
- **13.** `discover --recursive .` ≡ `discover . --recursive`.
- **14.** Byte fidelity: unmodified `read` is byte-identical to source.
- **16 (capture only).** Golden files for every fixture and the 3.5 MB real
  corpus, captured against the *old* binary, before any scanner changes —
  the baseline every later phase's gate-16 delta is measured against.

## Sequencing (within this phase)

1. `SpanSet` + property tests. Standalone.
2. Claims table + sidecar schema 3, populated by the *existing* scanners
   unchanged. Golden files captured here.

## Implementation notes

**GFM slugs and CommonMark HTML-block conditions are NOT this phase's
concern** — they belong to relations (phase 03) and collectors (phase 02)
respectively; do not front-load them here.

## Report

_(appended by the implementing agent on completion — what shipped, assert
counts before/after, any kind-vocabulary or hygiene-layout surprise the
fixtures turned up.)_
