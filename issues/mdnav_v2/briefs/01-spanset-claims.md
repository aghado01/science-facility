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
`ruleIds[]` (interned, null for built-ins), `info[]` (kind-specific: fence
lang, heading level+title, link target, footnote label…), plus three
identity columns (design canon
[mdnav_v2_structure-brief.md](../design/mdnav_v2_structure-brief.md) §4):
`ord[]` (this build's reading-order index — Geometry sort, start asc, end
desc, discovery order), `path[]` (the structural address — see the code
table below), `digest[]` (4 hex of title text, kind-appropriate claims
only). `containers[]` (ordinal of the immediate containing region claim, or
−1) is **derived from `path`**, not stored authoritatively — a claim's
container is whatever `path` minus its last segment resolves to. Byte
coordinates throughout, sorted `ClaimOrder.Geometry`. **Overlap and nesting
are preserved** — a `data-uri` inside an `html-block` inside a `fence` is
three claims, three rows, three paths. No `noise` flag exists anywhere.

**Path grammar** (structure brief §4): `/` separates segments, each
`<code><n>` — `n` 1-based among siblings of that kind under the same
parent, in reading order. Root heading claims keep the flat 4-digit legacy
spine (`Hnnnn`, `H0000` = PREAMBLE/BODY); a heading found by re-entry (phase
03) is `Hn` local to its container window, so `/H0007/q1/H1` is the first
heading inside the first blockquote under root section 7 — **root ordinals
never renumber when a new container kind becomes enterable**. Other codes:
`p` paragraph, `q` blockquote, `f` fence, `x` html-block, `c` html-comment,
`m` math-block, `l`/`i` list/list-item, `t` table, `d` footnote-def, `fm`
frontmatter; inline kinds spelled out (`link1`, `footnote-ref2`,
`data-uri1`, `custom:pixel1`); `S`/`W` for basis projections cut under a
node (`/H0007/S3`); `elided` for read-time placeholders (`/H0007/elided1`,
phase 05). `resolve()` accepts a full path or any document-unique suffix,
so legacy `Dnnn:Hnnnn@dig` anchors keep resolving unchanged; an ambiguous
suffix dies listing the candidates. This phase emits `path` for the region
and structural kinds it produces (ported scanners have no nesting yet, so
every claim is a root-level segment — `container` universally −1, `path`
one segment deep); phase 02/03 populate nested paths as re-entry lands.

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
its lifetime and answers queries from memory. Disk holds two things with two
different owners (D39): the **IR** — the claims table for a given byte
content, engine-owned, content-addressed, disposable — and the
**investigation** — inventory (`Dnnn` → path; ids appear in agents' notes
and must come back identical after restart) plus the reads ledger
(coverage and provenance; append-only JSONL as today), owned by whoever owns
the session (a directory for the CLI, para-agent's store for the server).
`MemoryStore` (server) and `SidecarStore` (one-shot CLI, which has no warm
process) share the IR schema (3) behind one small store interface, so the
CLI and a running server pointed at the same cache see one index. Views are
never persisted; they are cheap to recompute and policy-dependent.

**Layout (D39 — replaces the legacy per-run sidecar layout outright; there
is no legacy mode).** Two roots, two env vars:

```
$MDNAV_CACHE                        engine-owned · content-addressed · disposable · shareable
  default: %LOCALAPPDATA%\mdnav\cache (win32) · ~/.cache/mdnav (else)
  └── ir/v3/<sha[0:2]>/<sha256>.json     IR for those bytes: claims table (compact columnar,
                                         interned), line stats (bom, newline, maxLine),
                                         windows keyed "<size>:<start>..<end>". No path, no Dnnn.

$MDNAV_WORK_DIR                     investigation-owned · identity + provenance · stamped
  default: <dir of first target>/.doc-dive/  (only for calls that carry a path — see below)
  ├── inventory.json     {schema:3, docs:[{id, path, name, sha256, bytes, mtimeMs}]}
  │                      Dnnn ↔ canonical path; the sha/size/mtime row is the fast-path
  │                      invalidation table (stat matches → trust; else rehash → IR cache hit, or build)
  ├── LATEST             → stamp (the default for --run within this work dir)
  └── runs/<stamp>/
        ├── run.json     {stamp, started, argv, cwd, cache, docs:[{id, sha256}]} — what this run read against
        └── reads.jsonl  ledger, as today + explicit basis / enter / lens
```

- **IR is a pure function of bytes, so it is content-addressed**: never
  stale, never per-run, never per-work-dir; a touched-but-identical or moved
  file is a cache hit by hash; overlapping corpora share IR; `tmp + rename`
  writes make concurrent CLI/server use safe. There is no invalidation
  logic, only GC: `mdnav cache prune --older-than <d> | --unreferenced
  <work-dir>`. Schema bumps change the key prefix (`v3/`); old IR is simply
  never read.
- **Resolution is explicit or bust.** `--work-dir` > `$MDNAV_WORK_DIR` >
  `<dir of first target>/.doc-dive` — the last only when the call carries a
  path (`discover`, `index <file>`, `outline <file>`, …). A `Dnnn` with no
  work dir dies: `D001 needs a work dir — pass --work-dir <path> or set
  $MDNAV_WORK_DIR`. **The legacy global `$TMP/mdnav/LAST` pointer is
  dropped** (D39). Cache: `--cache` > `$MDNAV_CACHE` > the platform default
  (the suite points both roots at temp dirs so it never touches the user's
  cache and never gets a cross-run cache hit it did not ask for). The
  "refuse a dir the crawler can see" guard applies to both roots.
- Runs stay stamped because a run *is* provenance; `runs prune --keep <n>`
  trims them. `run.json` records the digests read against, so a ledger row
  can always be checked against the bytes it came from.
- **`--json` on `discover`/`index`** prints the per-document record
  (today's sidecar shape — `counts`, `noise`, `breaks`, `headings`,
  `windows`, `maxLine`, `newline`, … — built from inventory row + IR). This
  is the suite's seam (D40): the legacy suite reads sidecar files directly
  in 17 places and inventory/ledger paths in ~15; with `--json` it asks the
  binary instead and becomes black-box, and the same record is the typed
  return the MCP wants (D16). See
  [../reports/m0-legacy-capture-20260817.md](../reports/m0-legacy-capture-20260817.md)
  §1 for the coupling inventory.

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
windows within work-dir`; new here: `cache` (D39), and (consumed by later
phases, whitelisted now so the parser doesn't need touching again) `select
ignore lens via enter rules out older-than keep unreferenced`. Retired
before use, so never whitelisted: `only for in not-in profile` — the query
language (D43) and the lens rename (D44) supersede those spellings before
any implementation exists. Boolean today: `comp composition help i
recursive refresh`; new: `resolve json`. **`--strip` is optional-value**
(bare, or `--strip=all`) and, per D43, **accepts no other value** — the
comma-list-of-kinds spelling this flag used to take is retired in favor of
`--select`/`--ignore`, which removes F4's remaining parse-time-vocabulary
problem (the 2026-08-17 review's §3.7): `--strip` never needs the kind
table at parse time, because `all` is the only word it recognizes.

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
- **16 (capture only).** Golden files for every fixture and the named
  real-document set (`issues/mdnav_v2/discussion/`), captured against the
  *old* binary, before any scanner changes — the baseline every later
  phase's gate-16 delta is measured against.

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
