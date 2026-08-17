# `mdnav` claims engine — typed span claims, profiles, containment — brief

> **Role:** design canon — the "why" and the shape. Execution lives in
> [planning/roadmap.md](../planning/roadmap.md) (milestones M0–M6, gate
> subsets, chip seams), the audit trail in
> [planning/decisions.md](../planning/decisions.md) (D1–D32, ascending), and the
> figure-model homework in
> [archaelogy/figure-model-survey.md](../archaelogy/figure-model-survey.md)
> (function-by-function dispositions, must-survive behaviors, test map).
> Amend this brief; do not fork it.

**Status:** filed, not started · **Filed:** 2026-08-17 (rev 2, same day —
rev 1 framed this as "layers + masks"; superseded) · **Home:**
[mcp/mdnav_v2/](../../../mcp/mdnav_v2/) — new, empty at filing; the
**figure model / oracle** is the legacy
[skills/doc-dive/mdnav/mdnav.mjs](../../../skills/doc-dive/mdnav/mdnav.mjs),
which stays in place, untouched, serving the doc-dive skill (single-file, zero-dep
Node ≥ 18; sibling modules permitted where a primitive is genuinely
standalone — `span-set.mjs`, `claims.mjs` — a six-module split is not; see
Non-goals) · **Purpose:** generalize the substrate under every existing verb
so mdnav becomes a queryable **markdown-docs-as-virtual-db** backend the
incubating **mdnav MCP** imports in-process. **Nothing currently working is
discarded**: every verb keeps its CLI, output format, anchors and byte-fidelity
covenant; what changes is what they are computed *from* and what else becomes
askable.

**Lineage** (the conversation this brief closes out, in order):

1. Codex converged spec v0.1 — [codex-design-discussion-full.md](../discussion/codex-design-discussion-full.md)
   §1–13 (`mdnav outline D002 --depth 3` → H0107–H0141). Verb contract;
   governing principles (attention is the instrument; structure informs
   navigation without determining meaning; source authoritative; never
   silently omit bytes); non-goals incl. "MCP wrapping unless later
   justified" — now justified, the MCP is being built.
2. Fable review 2026-07-29 — [fable-review-20260729.md](../discussion/fable-review-20260729.md)
   §"mdnav tooling" (H0002): F1 noise detection fence-blind, F2 `profile` vs
   `--by breaks` disagree on breaks, F3 help/README/comment drift, F4 greedy
   boolean flags. **All four still open** (only commit since: the move to
   `mcp/`, 8d063b8). Absorbed here.
3. Sol XOR note — [sol-XOR-discussion.md](../discussion/sol-XOR-discussion.md):
   mdnav as *consumer witness* of doccer primitives, not their definition; the
   recursive walk — classify delimiter candidates → mask/parity → bounded
   regions → **re-enter each region with context-specific rules** → repeat;
   every intermediate keeps its material basis and source coordinates.
4. Gemini note 2026-08-16 — [gemini-mdnav-next-gen.md](../discussion/gemini-mdnav-next-gen.md):
   port doccer's `SpanSet`; hierarchical layers; slice-program
   materialization; cadence; module/MCP blueprint. This brief takes the
   algebra and the layering, generalizes "mask" to *claims + suppression
   query*, and defers the module split and `server.mjs`.
5. This thread 2026-08-17: (a) masking is an index concept — kinds indexed
   independently so they can be filtered, read selectively, counted, composed;
   never "hide"; (b) `# x` inside an html-block is a **nested** heading reached
   by re-entering the block, not flattened to top level and not ignored;
   (c) drop the noise/prose binary — documents contain **typed objects**, and
   whether a type is signal or noise is a **profile** (a skill disposition), the
   way `nushell-mcp` has nu-skills/nu-modules; (d) span algebra + bitmaps over
   parsing — an AST tool (markdig) is not opposed, but parsing is brittle;
   (e) doccer is the inspiration, never the dependency.

**Doccer sources** (read for the port; `D:\aghado01\codex-scientiae\src\doccer`,
10.6 k lines C#, README is the contract): `Algebra/SpanSet.cs`,
`Algebra/Suppression.cs`, `Core/SpanBatch.cs` (`SpanClaim`, `SpanLevel`,
`ClaimOrder`), `Collector/RegexCollector.cs` + `PatternRuleLoader.cs`
(`PatternRule`, `ExecutionScope`, region-scoped matching), `Algebra/Pairing.cs`,
`Vectors/BooleanVector.cs` (`PrefixParity`), `Core/TextSlice.cs`,
`Algebra/LaminarView.cs` + `HierarchyView.cs` (`NearestContainers`),
`Algebra/GapCadence.cs` (itself transcribed from mdnav's profiler),
`Materialization/RewritePlan.cs`.

## Doctrine (transcribed, not invented)

Doccer's governing rule, which is also this brief's:

> Claims carry evidence. Queries execute named policies and return results.
> Orchestration selects policies and interprets results. The engine never
> pre-resolves.

and its suppression rule, which is the whole answer to "noise vs prose":

> Suppression is a query policy, never a claim property. No claim carries
> `is_mask` … One code-block claim suppresses heading recognition under one
> query and is the primary target of a language collector under the next, and
> both readings must remain available from the same batch.

For mdnav: the engine **discovers typed constructs** and records them as claims
with source coordinates. `--strip`, "noise", "active heading", "unit boundary"
are all *queries* a caller (CLI flag, profile, MCP tool, skill) names over
those claims. mdnav's own design rule — presume about the reading process,
never about the content — is the same rule from the other side.

## Problem

Three symptoms, one cause. Probe today (345-byte doc, scratchpad):

- Multi-line `<!-- … -->` **leaks through `--strip all`** — `noiseSpans`
  (mdnav.mjs:223) is line-scoped so `<!--[\s\S]*?-->` cannot match; the
  comment at :222 claiming multi-line HTML is "reported" is false (F3).
- `data:image/png;base64,…` inside a ```` ```html ```` fence **is elided** and
  triage counts fenced examples as noise (F1; the July repro reported a doc as
  "25.7 % embedded" when every byte was a quoted example).
- `profile` calls `***`/`----` a `break`; `--by breaks` accepts only exact
  `---` (mdnav.mjs:416) and silently returns one segment (F2).

Cause: three independent scanners (`analyze()` headings, `constructRuns()`,
`noiseSpans()`), three notions of extent, no shared claim table, no shared
region algebra, and a hard-coded binary — `NOISE` kinds vs everything else —
baked into `STRIP_ALL`, the triage ratio, and the `noise=` columns. Nothing
can express "this fence is the thing I want" or "this `[^12]` is a citation,
keep it, but the `<div>` around it is furniture."

## Shape

Five primitives, in dependency order. Each is usable without the ones after
it (doccer's "capability library, not a pipeline").

### 1. `SpanSet` — geometry algebra

Normalized sorted disjoint half-open byte intervals; linear two-pointer
`union`, `intersect`, `subtract`, `complement(len)`, `coverage`,
`contains(off)`. ~60 lines. **Identity-forgetting on purpose** — that is what
makes it usable as a mask. The Gemini sketch's `intersect`/`subtract` are
correct as written; prove it against a brute-force bitmap, not by inspection.

### 2. Claims — the occurrence table

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

Kind vocabulary is **open**. Built-in kinds this brief must produce (today's
constructs, plus the ones the discussion named):

| family | kinds | extent rule | today |
|---|---|---|---|
| region (re-enterable) | `frontmatter` `fence` `html-block` `html-comment` `math-block` `blockquote` `list` `list-item` `table` `footnote-def` | frontmatter: `---`@0 … next `---`/`...` line; fence: opener char+len … matching closer or EOF (+ residue claim `fence-unclosed`); html-comment: `<!--` … first `-->` (multi-line, no nesting); html-block: CommonMark block **start conditions 1–7 with their end conditions** (1–5 terminator string, 6–7 blank line) — never open/close tag pairing; math-block: `$$` line … `$$` line; blockquote/list/table: contiguous runs as today; footnote-def: `^\[\^label\]:` … next non-continuation line | fence, html (line-runs), blockquote, list, table exist; rest missing |
| structural | `heading` `setext-heading` `break` `paragraph` | heading: ATX outside `fence ∪ html-comment ∪ frontmatter` (info: level, title, digest); setext: as today's suspects, promoted to a claim; **`break` = `-{3,}|\*{3,}|_{3,}` with blank line before, one regex shared by every consumer** (F2) | exist, disagree |
| inline object | `html-tag` `link` `link-ref` `image-ref` `data-uri` `signed-url` `footnote-ref` `inline-code` `wikilink` `custom:<id>` | today's regexes for `html-tag` (= today's `html` noise kind, single tag, inner text not part of the claim), `link`, `image-ref`, `data-uri`, `signed-url`; `footnote-ref` `\[\^[^\]\s]+\]` (info: label); `link-ref` `\[text\]\[id\]` / collapsed `[id][]` (info: id); `inline-code` backtick spans; `wikilink` `\[\[…\]\]`; all executed **region-scoped** (below) | first five exist, unmasked |
| definition | `footnote-def` `link-def` | `^\[\^label\]:` … next non-continuation line (region, re-enterable — a def body can hold links, code, even a nested list); `^\[id\]:\s*<?url>?` one line (info: id, target) | missing |

Footnotes (`[^1_1]` in prose, `[^1_1]: https://…` in foot-matter) and link
reference definitions are **idiomatic Markdown**, not a site disposition —
they are core kinds, and what matters is the **relation** between the
reference and its definition (§2b), which is what an interactive preview
renders as a click.

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

### 2b. Relations — keyed joins over claims

Some constructs only mean something in pairs. A **relation** is a keyed
join between two kinds on a field of `info`, computed at query time (or
cached in the sidecar) and returned as ordinal pairs plus residue:

| relation | left kind → right kind | key | residue |
|---|---|---|---|
| `footnote` | `footnote-ref` → `footnote-def` | label | dangling refs, unused defs |
| `link-ref` | `link-ref` → `link-def` | id (case-insensitive) | dangling refs, unused defs |
| `anchor` | `link` with `#fragment` target → `heading` | GFM slug of the heading title | dangling anchors |
| `contains` | any → region claim | geometry (nearest container) | crossings |

Relations are the query-form of "clickable": from a ref, its def span; from
a unit, the foot-matter it cites (`read --only footnote-def --for H0007`);
from a doc, its dangling refs (`profile` residue). They are **not** doccer's
`ClaimPairView` — no Allen labels, no general occurrence relation — just the
three keyed joins Markdown idiom actually defines, plus containment.

### 3. Collectors — how claims are discovered

**Delimiter geometry is the unifying idea.** Idiomatic Markdown constructs
are recognizable by their delimiters, and delimiters come in exactly three
geometries; a collector is a delimiter spec plus one of these, and masking,
isolating and segmenting are the same operation with different arguments:

| geometry | examples | mechanism | yields |
|---|---|---|---|
| **boundary** (singleton) | ATX heading line, thematic break, `[^n]:` def start, blank line, fixed byte window after a newline | candidate boundaries → ordinal partition of the window; first viable boundary is the only policy | a **partition** that tiles the window byte-for-byte (today's `--depth`, `--by breaks`, `--windows`) |
| **toggle** (one token opens and closes) | ```` ``` ````/`~~~`, `$$`, `` ` ``, `<!--`/`-->` as a token pair | delimiter positions → **prefix parity** (XOR fold) → inside/outside; odd carry-out is residue | **regions** + `unclosed` residue |
| **pair** (distinct open/close) | `<details>`…`</details>`, `[`…`]`, `\begin{}`…`\end{}` | strict-stack pairing under a named compatibility policy | **nested regions** + unclosed-open / dangling-close residue |

A delimiter spec is data: `{ pattern, geometry: boundary|toggle|pair(open,
close), scope: line|whole, kind }`. Built-in kinds are just shipped specs;
a caller may pass one ad hoc. Partitions are **validated values** (shared
endpoints, disjoint, exact window coverage) — the existing partition
invariant, applied to every basis, not just headings.

Two collector kinds, both writing to the same table:

- **State-machine collectors** for region kinds whose extent is a toggle or a
  block condition (frontmatter, fence, html-comment, html-block, math-block).
  One pass, replaces the two duplicated fence trackers. Toggle-defined regions
  (fence, `$$`) are **prefix-parity** over their delimiter claims (doccer
  `BooleanVector.PrefixParity`): delimiter positions XOR-fold to inside/outside,
  and an odd carry-out is residue (`fence-unclosed`), reported never repaired.
  Balanced-pair regions use strict-stack pairing with residue for unclosed
  opens / dangling closes (doccer `Pairing.Pair`) — used only for kinds a
  profile nominates as paired (e.g. `<details>` under a `github` profile), never
  by default.
- **Rule collectors** — doccer's `PatternRule` in JS: `{ id, pattern, kind,
  source, level: char|line|multi, scope: line|whole, priority, capture?,
  info? }`, loaded from **JSONL inventories**. Execution: the rule's `scope`
  proposes regions (each line's content extent, or the whole master), the
  caller's `SpanSet` admits regions, and the rule runs over `proposed ∩
  admitted` **piece by piece so a match can bridge neither an excluded gap nor
  a line break**. This is F1's structural fix: inline collectors run over
  `Total \ coverage(fence ∪ html-comment ∪ frontmatter)` by default, and
  *what is excluded is itself a named policy* the caller can change (a
  `code-review` profile wants `data-uri` found *inside* fences).
  Built-in rules live in `mcp/mdnav_v2/rules/core.jsonl` (everything in the
  kind table above that is regex-shaped); further inventories are for
  constructs Markdown does *not* define — a corpus-specific tracking pixel, a
  house citation style, an export tool's wrapper tags — loaded via
  `rules/*.jsonl` or `--rules <file>`. Load-time validation with per-line provenance on
  failure. `--strip-match <re>` becomes sugar for a one-off rule of kind
  `custom`.

Collection is **transactional per document**: a failing rule leaves the
table untouched and names its line.

### 4. Containment and re-entry — the recursive walk

Region claims are containers. After L0 (regions) and L1 (structural over
`Total \ inert`), the walk **re-enters each region claim** and runs the
structural collectors over the region's own window with region-specific
rules — inside `blockquote` the heading rule is `^ {0,3}> {0,3}#{1,6}\s`;
inside `html-block` it is the ordinary ATX rule; inside `fence` nothing runs
unless a profile says so; inside `list-item` continuation lines are the
window. Claims found by re-entry get `container = <region ordinal>` and are
otherwise ordinary claims **in source coordinates** (no derived masters, no
prefix stripping, no OffsetMap — doccer defers that too). Nearest-container is
the containment relation (doccer `LaminarHierarchy.NearestContainers`);
proper crossings between region claims are residue reported by `profile`,
not resolved.

**Consequence for headings** — the third projection knob. README §Address
model has basis / depth / extent; this adds **enter**:

- Heading ids `Hnnnn` stay **ordinal over all heading claims in document
  order** — a nested heading keeps the same number it has today, so existing
  anchors do not move.
- A heading is *active* for units/outline/coverage when its **level ≤ depth
  AND its container chain is transparent**. The document root is transparent;
  region kinds become transparent via `--enter <kinds>` (or a profile). Default
  `--enter` is **empty**: `# x` inside `<details>` or a blockquote is not a
  unit boundary at top level; `outline` shows the containing region as one
  unit with a `contains: heading×2` note; `outline --enter html-block` (or
  `--within H0007 --enter html-block`) descends into it as a nested outline.
- Partition invariant unchanged: active units tile the source byte-for-byte
  at every (depth, enter) combination — the invariant test gains the second
  axis.

This is the deliberate anchor-*activation* change the thread asked for. It is
opt-in-visible (`outline` names what it is not descending into) so nothing is
silently omitted.

### 5. Queries — projections over claims

Every verb becomes a query with named policies; existing flags are the
first policies.

- **Selection**: a set of claim ordinals from predicates (`kind in …`,
  `container == …`, `within [S,E)`, `ruleId`, `priority ≥`) with
  union/intersect/subtract; `.coverage()` → `SpanSet` (identity dropped —
  doccer `ClaimSelection.Coverage`).
- **Suppression** = `coverage(selection)`; the caller names the suppressors.
- **Profiles** are named suppression/entry/emphasis policies as **data**,
  `mcp/mdnav_v2/profiles/*.json`:
  ```json
  { "name": "chat-export", "rules": ["core"],
    "strip": ["html-tag", "html-block", "data-uri", "signed-url"],
    "keep":  ["footnote-ref", "footnote-def", "link-def"],
    "enter": [], "collect-inside": { "fence": [] },
    "triage": ["data-uri", "html-tag", "html-block"] }
  ```
  A profile says nothing about *what* is in the document — every kind is
  detected regardless — only which kinds this reader treats as furniture,
  which it insists on keeping even when a broader strip would take them,
  which containers it descends into, and what `discover` should warn about.
  `default` reproduces today's behavior exactly (`strip` = today's
  `STRIP_ALL`, `triage` = the same, `enter` = []). Selected by `--profile
  <name>` or `$MDNAV_PROFILE`; individual flags override. A profile is a
  disposition, loadable and composable, not code.
- **Basis, generalized**: `--by <kind | pattern:<re>>` on `outline`, `read`,
  `coverage`, `locate`. Today's three bases become cases: `--by heading`
  (default, with `--depth`), `--by break`, `--windows <n>`. New: `--by
  footnote-def` (foot-matter as units), `--by fence` (regions as units;
  gaps between regions are units too, so the tiling holds), `--by
  pattern:'^\[\^[^\]\s]+\]:'` (ad-hoc boundary). Boundary bases address as
  `Snnnn`, region bases as `Rnnnn`; all share one address space and one
  ledger. Segmenting is recursive: `--within <anchor> --by <other>` re-enters
  a unit with a different delimiter — the XOR walk in CLI form.
- **`read`**: `--strip <kinds|@profile>` = `[S,E) \ coverage(sel)`;
  **new `--only <kinds>`** = `[S,E) ∩ coverage(sel)`; `--enter` as above.
  Placeholder ≥ 1 KiB with `@s..e`, `keepOf` label rule, ledger of elided
  spans, stderr warning before writing >64 KiB of stripped material — all
  unchanged. Materialization is the existing slice loop expressed as
  `subtract`; a `RewritePlan`-style ordered piece list is the internal shape
  so `--only`/`--strip`/`--enter` compose without a second code path.
- **`coverage`**: `union(reads) \ union(elided)` per doc; kept citation
  labels no longer counted elided.
- **`outline`**: unchanged columns; `noise=` becomes `strip=` computed from
  the active profile's `strip` set (label kept as `noise=` under `default`
  for output stability); `--enter`; a `contains:` note on units holding
  non-transparent regions with headings.
- **`profile`** (verb): census over **all** kinds present — counts, bytes,
  ratio, cadence — not just construct runs; residue section (unclosed fences,
  crossing regions, undefined footnote refs).
- **`marks --kind <k>`**: any kind, incl. rule-defined; `--within`, `--in
  <container-kind>`; `--resolve` joins through the kind's relation
  (`marks --kind footnote-ref --resolve` → ref span, def span, label,
  dangling flag). `read --only footnote-def --for <anchor>` materializes the
  defs a unit cites.
- **`locate`**: unchanged surface; may take `--in`/`--not-in <kinds>` later.
- **`discover`/`index`**: build claims once, persist; Notes column driven by
  the profile's `triage` set; `--rules`, `--profile`.
- **`profiles`** / **`rules`** (new, trivial): list what is loaded and from
  where.
- `parseArgs`: whitelist value-taking flags (F4). Help/README/:222 made true
  (F3); README gains the kind table, the profile section, and *enter* as the
  third knob.

### Front-end grammar (constraint on this brief; the server brief owns it)

The model for the MCP tool surface is already running in
`science-facility/mcp/nushell-mcp`: `nu-skills` and `nu-modules` expose one
small verb grammar with **typed, pure-content returns** —
`list → table`, `read <x> → string` (raw), `search <re> → table` of hits,
`inspect <x> → table` (signature + one doc line), `status → record` — and
the discipline is **progressive disclosure**: index first, one item on
demand, search across, never preload. Three layers: Claude adapter skill →
augmentation layer (config + modules) → native server. mdnav maps onto it
almost verb-for-verb today (`discover`≈list, `outline`≈inspect,
`read`≈read, `locate`≈search, `profile`/`coverage`≈status, `marks`≈a typed
list), so the backend contract is: **every query returns either literal
source bytes or a flat table/record of claims and anchors — never prose,
never a summary, never a recommendation beyond stderr triage.** The exports
below must make that shape natural for `server.mjs`; if a verb's result
cannot be expressed as bytes-or-table, that is a design smell to report.

### Agent context hygiene — the REPL contract

What is being built is a **Markdown-documents REPL for an agent**: a
persistent session over a corpus, small typed calls, results held
server-side and sliced on demand. The scarce resource is the *caller's*
context, and a tool surface that can only answer by inlining is useless
however good the engine is. The model is `nu --mcp` as used from this
harness: every evaluation returns a bounded record, the full value is kept
in `$history.N`, and the caller pages it afterward. mdnav's rule becomes:
**a query never inlines more than the caller's budget; everything else is a
handle.** Backend obligations (the server brief owns tool names and the
session store; the engine must make these natural):

- **Every query is paged and counted.** `select`, `partition`, `relations`,
  `locate`, `marks` take `{limit, offset, columns}` and return `{total,
  rows}`; `total` is always present, rows only up to `limit`. Values are
  plain arrays of records so a session store can hold and re-slice them
  without recompute; queries are memoized by `(digest, policy, args)` so
  re-asking is free.
- **`materialize` takes a budget and can answer with a plan.** `{maxBytes}`
  is a first-class argument (CLI: `--max-bytes`, default generous; MCP
  default small, e.g. 8 KiB). Over budget it returns **no bytes** — instead
  `{bytes, spans, elided, anchors, suggestion}`: the plan the caller would
  have paid for, with the anchors to narrow by (`--depth`, `--enter`,
  `--only`, `--strip`, a smaller `--within`). Today's ">64 KiB stderr warn
  before writing" is the seed; the MCP form refuses rather than warns,
  because once bytes are in context the cost is paid.
  **Budgets count emitted bytes, headers included.** `maxBytes` is compared
  against the total the framer will actually write — every header line
  (UTF-8, so `§`/`¶` are 2 bytes each) plus every `len` — never against
  payload alone; the plan reports both `payload` and `framed` totals. All
  framing arithmetic is `Buffer.byteLength`, never string length.
- **Bytes-or-table, never both.** A read result is bytes plus a one-line
  stderr-style `note`; a table result is rows plus `total`; a `record` for
  status. No prose, no summaries, no recommendations beyond `suggestion`
  in a plan.
- **Anchors are the agent's memory, not bytes.** The ledger already makes a
  set of anchors a re-readable batch; expose `coverage` and `reads` so an
  agent — or a post-compaction agent — can see what has been ingested and
  re-read by anchor rather than carrying content. `@digest` on anchors turns
  a stale note into a warning, not wrong content. Notes should hold
  `D003:H0002@1281`, not paragraphs.
- **Previews are bounded by construction.** `outline --preview N`,
  `locate` snippets ≤ 120 chars, `marks --preview` all cap at the engine, not
  the presenter; `truncate` on titles likewise. A table row is never allowed
  to smuggle a body.
- **Session state makes calls short.** Current corpus, run, profile,
  default budget, and "current document" (`cd`-like) live in the session so
  a call is `outline H0007 --depth 2`, not a repeat of the world. Result
  handles (`$r3`) can be passed back as inputs (`read $r3.anchors`,
  `select --within $r3`) so an investigation composes without re-inlining.
- **Diagnostics stay out of band.** stderr today; a small `notes[]` field in
  MCP results, never mixed into rows or bytes.

**Stream framing — front-declared, typed, addressed regions.** The
para-agent note
[grok-addressable-context-stream.md](../../para-agent/notes/grok-addressable-context-stream.md)
describes the model-facing stream as *coding regions* (clean content)
separated by *non-coding headers*: thin, regular, low-entropy, fixed field
order, with a short local address, so the Primary can re-mention
`e17.reply` without re-injecting it. The "length-prefix" there is a
metaphor for what a protocol prefix *does* — declare kind and magnitude
before the payload, bound it independently of content, make it addressable,
signal completeness — adapted to a model reader. The model-side analog of
each: **declare-before-payload** (under causal attention every payload token
is encoded already attending to a preceding header — prefix beats suffix;
an *advance organizer*), **magnitude and cardinality** rather than bytes
(`k/N`, coarse size — usable for tracking completeness and planning the
read), **the sentinel** as the content-independent boundary, and **the
address** for random access. mdnav's `read` is the document-side instance
and emits the same framing, so documents and exchanges are one kind of
object in the Primary's stream — and the header declares the *interpretive
frame the backend already knows* (the claim kind, the basis, what was
stripped), which is the claims table reflected into the stream:

```
§ D002:H0108@fa8a 2/5 kind=unit basis=d2 ~629B strip=html-tag span=61234..61863 len=629
<629 bytes of source>
§ D002:H0108@fa8a/elided.1 kind=data-uri ~404KiB span=14187..430301 len=0
§ D002:H0117@aabc 3/5 kind=unit basis=d2 ~540B span=… len=540
…
```

Field order is fixed: glyph, address, ordinal-of-batch, kind, basis, coarse
size, policy stamps, then the machine fields (`span`, `len`) last.

*The non-coding convention is a **sigil vocabulary**, not a "frame"
apparatus (proposed, pending the shared spec freeze).* The concept — not
the characters — comes from reposnapshot's shard format
(`issues/reposnapshot/design/shard-format-notes.md`, §Sigil selection):

1. **The length prefix is the framing authority; sigils are presentation
   for the reader.** Nothing about parsing depends on a sigil.
2. **Sigils are chosen by measurement, not taste** — line-start frequency in
   real corpora (backtick was disqualified there at 64 % of md lines), UTF-8
   bytes, token cost *in situ* (D29), survival through NFC and strip ops,
   visibility (no invisible/zero-width marks), and semantic honesty (the
   glyph should already mean roughly what it marks).
3. **The correspondence is declared once, ahead of content, as a short
   legible key** — "a cipher key, not a decoder spec": addressed to the
   model's in-context bookkeeping so it has read the sigil↔meaning mapping
   before it meets one. It lives in the adapter skill and as the first
   record of a session, never per read.
4. **Payloads are read as-is**, without tooling.

Vocabulary — candidates, roles, and why each glyph (final set ≤ 5, fixed
at freeze after measurement on the `issues/mdnav_v2/discussion/` corpus and
one large real transcript):

| sigil | role | prior it borrows |
|---|---|---|
| `§` U+00A7 | **open** — document unit (section) | section mark; `§ 3.2` already reads as a section reference |
| `¶` U+00B6 | **open** — exchange/turn or generic coding region (transcript side) | paragraph mark |
| `…` U+2026 (or `⋯` U+22EF if `…` proves too frequent at line start) | **elision** — an addressable zero-length region | "something omitted" is what the glyph means |
| `⁂` U+2042 (asterism; alt `⁋` U+204B reversed pilcrow) | **close** — optional overlay | asterism historically marks a section's end/break |
| `†` U+2020 | foot-matter / definition region, *if ever* | typographic footnote convention |

Row grammar — **the metadata block is a pipe-celled row; the payload is a
raw multi-line cell.** The evidence is a reposnapshot shard read directly
(`D:\aghado01\project-snapshots\ThermoMapper\src_20260701_122622_s024_hashish.txt`,
2026-08-17): its typed header row (`idx<int> | path<str> |
attributes:{…} | length<int> | content<str> |`) is a key read once and used
positionally thereafter; its front-loaded metadata cells (`246 |
hashish/tokenizer.cs | {1916 145 0.2526 4.6996} | 1982 |`) primed the read
— address, identity, composition, size, before a byte of content; pipes cut
the line into cells that attention treats as a header without being told;
the trailing pipe is a one-character close. The content cell was
single-line with `\n` escapes — and comprehension was **intact**:
indentation spaces are literal, only the physical newline is encoded, and
whitespace tokens read no differently from printed ones. That encoding is
reposnapshot's deliberate invariant, **one physical line per row**, and its
benefits transfer: a physical newline always and only means "next record",
rows are line-addressable and tool-friendly, and a header can never be
confused with content. mdnav adopts it **by record class**: table/record
outputs (outline rows, locate hits, marks/claims rows, coverage, plans) are
one physical line per row with content cells escaped (previews are already
whitespace-collapsed today). The one exception is **source
materialization**: `read`'s payload is a raw, multi-line, unescaped cell of
exactly `len` bytes — not for legibility, but because the covenant is
*literal source bytes* (gate 14; `legacy-comment` byte-identical to today) —
and the length prefix is what makes that exception safe.

Records are **flat and newline-delimited** (a unit with an elision is
emitted as *pieces*, each its own record — nothing nests arithmetically);
the optional close row `⁂ | <address> |` re-mentions the address (a second
retrieval hook), signals completeness, and makes nesting legible — for the
machine it is only a checksum (address/position mismatch → framing fault).
If a payload does not end in LF the framer inserts one before the next row;
that LF is framing, counted in `framed`, never in `len`. The key row is
declared once per session (adapter skill + first record), not per read; a
`{…}` group is a positional sub-block declared in the key, as in the shard.

```
key | sigil | addr | k/N | kind | basis | {comp} | ~B | ~t | span | len |
§ | D002:H0108@fa8a | 2/5 | unit | d2 | {prose72 code20} | ~629B | ~160t | 61234..61863 | 412 |
<412 bytes of raw source, multi-line>
… | D002:H0108@fa8a/elided.1 | | data-uri | | | ~404KiB | | 14187..430301 | 0 |
§ | D002:H0108@fa8a | 2/5 | unit | d2 | {prose100} | ~217B | ~55t | 61651..61863 | 217 |
<217 bytes>
⁂ | D002:H0108@fa8a |
```

**Emission is a profile setting, not a mode.** `sigils: legacy-comment |
typographic | none` (CLI flag `--sigils`, replacing the earlier `--frame`
naming); within `typographic`, which roles emit — close on/off, elision
sigil vs a plain zero-`len` open — is also profile data. `legacy-comment`
is today's `<!-- mdnav … -->` (itself a sigil convention: the HTML comment is
the Markdown-inert sigil) and stays the CLI default, byte-identical to
today; `typographic` is the MCP default; close on/off is chosen by the
behavioral eval (D20). **Header field style: pipe-celled, positional,
declared by a key row** — decided on direct reading evidence (above), with
D29 confirming the token cost rather than choosing the style. A framed
mdnav stream is then a psr row grammar with one multi-line cell — one
reader across reposnapshot, para-agent, mdnav. Optional stamps that vary
per profile go in a trailing `{…}` group declared in the key, never as
`k=v` in the row.

- Address = the anchor (`Dnnn:Hnnnn@digest`, or `Snnnn`/`Rnnnn`/`Wnnnn`,
  or a raw `Dnnn:@s..e`), extended compositionally for nested claims and
  placeholders (`…/fence.2`, `…/elided.1`) — every header is something the
  Primary can hand back to `read`.
- **`len` is emitted UTF-8 bytes; `span` is source geometry. Never the same
  field** — under `--strip`/`--only` they differ, and conflating them is the
  historic byte-semantics trap. Both are *machine* fields (round-trip,
  audit, tooling); the model-facing magnitude is the coarse `~629B` /
  `~404KiB` and the `k/N` ordinal — and, when a **client token profile** is
  loaded (roadmap: token-cost measurement battery), a measured estimate
  `~160t` beside it, computed from the unit's per-kind composition × the
  profile's per-kind ratios + header cost, stamped with the profile id in
  the read's `note`. That estimate is the empirical "length prefix": model-
  specific by measurement, never by a bundled tokenizer; absent a profile
  the field is bytes only and no token number is invented. Placeholders are
  zero-length coding regions with a header, so an elision is *addressable*,
  not just visible.
- Every read is framed, including single-anchor reads (today undecorated),
  because the header is what makes the region re-mentionable later.
- The sigil vocabulary, key, and row grammar are a **shared spec** with
  para-agent and mdnav *conforms* to it; until it is frozen, emission is a
  projection over the materialization piece list — `--sigils
  legacy-comment|typographic|none` — one piece list, several renderings;
  the piece list is what later context-mode hooks route on.

*Evidence status of the framing claim* (so it is carried honestly): the
value is real but uneven. Exact, short, re-mentioned addresses are the
best-grounded part — repeated exact token sequences are the strongest
in-context retrieval cue transformers have; declare-before-payload has a
causal-attention rationale; provenance/kind labels, `k/N`, and a regular
sentinel are cheap and well supported. Byte `len` has **no attention
benefit** (models do not count bytes; the boundary the model uses is the
next sentinel) — it is a machine field only. Headers cost ~10–15 tokens
each, so frame at unit grain by default. The claim must be evaluated behaviorally
(same tasks, `--sigils none` vs `typographic`, close on/off; address-recall accuracy,
misattribution rate, tokens-to-answer) — a server-brief gate, not an
assumption here.

**Vendoring.** mdnav 2.0 is expected to become an internally vendored MCP
subsystem of para-agent, as `nushell-mcp` will. Constraints that follow:
the engine stays single-file zero-dep; the server is an embeddable
`createMdnavTools({ corpus, session, framing })` plus a thin standalone
stdio runner, so para-agent can mount it in-process and supply its own
session/result store; result handles and addresses are plain data that can
sit in a para-agent transcript row (`e17.tool.3 → D002:H0108@fa8a`), giving
cross-reference between exchange addresses and document addresses for free.

Exit-gate additions: **17.** `select`/`partition`/`marks` honour
`limit/offset` and always return `total`; **18.** `materialize` over
`maxBytes` returns a plan with zero bytes and anchors that, followed,
produce a within-budget read; **19.** no table query can return a field
longer than the preview cap; **20.** the CLI exposes `--max-bytes` and
`--limit/--offset` so the one-shot path has the same discipline; **21.**
framing round-trip: under `--sigils typographic` every header's `len` equals the
bytes that follow it exactly (incl. multi-byte UTF-8 and CRLF sources), the
concatenated coding regions of a multi-anchor read equal the `--sigils none`
read byte-for-byte, an elision emits a zero-`len` header whose address
`read` accepts and resolves to the elided source span, and `--sigils legacy-comment`
output is byte-identical to today's for the golden fixtures; **21b.** byte
accounting: total bytes written == Σ `Buffer.byteLength(header line)` + Σ
`len`; each header line's byte length == its char length + 1 (the glyph is
the only non-ASCII bytes — asserted for every sigil in the vocabulary, incl. the 3-byte `…`/`⁂`); a header parser
that reads the stream back recovers every address, `k/N`, `span`, `len`
exactly; the plan's `framed` total equals the bytes a subsequent read
within budget actually writes; a `maxBytes` that admits the payload but not
payload + headers returns a plan, not bytes.

### Export surface (the MCP foundation)

`mdnav.mjs` gains named exports — `Corpus` (open a work-dir with a store;
`discover`, `doc(ref)`, `invalidate`), `Doc` (`buf`, `digest`, `claims`,
`select(pred)`, `partition(basis, policy)`, `relations(name)`), `SpanSet`,
`Selection`, `loadRules`, `loadProfile`, `materialize(doc, spans, policy)`,
`Ledger` — object-shaped so a server holds one `Corpus` for the process and
CLI verbs open-query-close — and the top-level CLI dispatch (last five lines
today: `parseArgs` → `VERBS[verb](args)`) moves under an `if (isMain)` guard
keyed on `import.meta.url` vs `process.argv[1]`. **There is no guard and no
export today; `import()` runs the CLI.** After this, `server.mjs` (next
brief) imports in-process, and MCP tools are thin: `mdnav_query({doc, kind,
within, profile})` is a Selection; `mdnav_read` is a projection.

## Implementation notes (things that bite if left to memory)

1. **`isMain` guard on Windows.** `import.meta.url` is `file:///D:/…` with
   forward slashes; `process.argv[1]` is `D:\…` and the drive letter's case
   is whatever the caller typed (`mdnav.ps1` passes `Join-Path $PSScriptRoot
   'mdnav.mjs'`). Compare `realpathSync.native(fileURLToPath(import.meta.url))`
   against `realpathSync.native(resolve(process.argv[1]))`, case-insensitively
   on `win32`. Test 15 must run through the `.ps1` wrapper as well as bare
   `node`.
2. **GFM slugs for the `anchor` relation.** Use GitHub's algorithm
   (`github-slugger`): lowercase; remove characters that are not letters,
   numbers, spaces, hyphens or underscores (Unicode letters kept); spaces →
   `-`; **duplicate titles get `-1`, `-2`, … in document order**, so the
   relation builder must slug headings in ordinal order and keep a
   per-document counter, or `[see](#setup-1)` dangles against the wrong
   heading. Store the computed slug in the heading claim's `info`.
3. **CommonMark HTML block conditions, verbatim.** Start conditions and their
   terminators — 1: `<script`/`<pre`/`<style`/`<textarea` … line containing
   `</script>` etc.; 2: `<!--` … `-->`; 3: `<?` … `?>`; 4: `<!` + letter …
   `>`; 5: `<![CDATA[` … `]]>`; 6: one of the ~60 block-level tag names,
   open or close … **first blank line**; 7: any complete open or close tag
   alone on the line (cannot interrupt a paragraph) … first blank line. Type
   2 is emitted as the `html-comment` kind, not as `html-block`, so the two
   never double-claim. Types 6/7 ending on a blank line — never on a matching
   close tag — is what keeps malformed transcript HTML bounded.
4. **`parseArgs` whitelist.** Value-taking today: `by depth max-depth extent
   from glob heading headings kind max min preview run span strip-match to
   truncate windows within work-dir`; new here: `only enter rules profile for
   in not-in out`. Boolean today: `comp composition help i recursive refresh`;
   new: `resolve`. **`--strip` is optional-value** (bare = `all`): treat it as
   value-taking only when the next token is `all` or a comma-list whose every
   member is a known kind or `@profile`; otherwise bare. Anything not in
   either list is an error, not a guess.
5. **Framer arithmetic is bytes, period.** The header glyphs `§` (U+00A7,
   `C2 A7`) and `¶` (U+00B6, `C2 B6`) are two UTF-8 bytes; every header
   line's cost is `Buffer.byteLength(line)`, every payload's is its `len`,
   and `maxBytes` compares against their sum. A framer written with
   `.length` passes every gate except 21b and then lies in the field by one
   byte per header — the historic byte-semantics trap wearing a new hat.
   Write headers and payloads to the same `Buffer`/stream so the count and
   the bytes cannot diverge.

## Non-goals (this brief)

- No six-module split, no `server.mjs`, no "virtual database engine"
  marketing. One file plus at most `span-set.mjs` / `claims.mjs` where a
  primitive is standalone and testable alone.
- No CommonMark parser, no markdig. Extents by shape, toggles and block
  conditions. The codex non-goals (classification, semantic chunking,
  ranking, repair, rewriting, summarization) all stand — profiles express
  *disposition*, never *meaning*.
- No open/close **tag-pair** HTML masking by default; pairing exists as a
  primitive and only a profile turns it on for named tags.
- No derived masters / OffsetMap / prefix stripping for re-entry.
- No changes to `Dnnn:Hnnnn@digest` numbering, `--depth`/`--extent`
  semantics, the partition invariant, or any output format except the fixes
  named above and the `enter`-driven activation described in §4.
- Not ported from doccer: Allen relations, `ClaimPairView`, path selection,
  facts/saturation, origins, `RewritePlan` as a public type, vectors beyond
  prefix parity. Cadence stays as is; note in the report whether the
  claims refactor makes `GapCadence`'s window-basis form a free alignment.
- Doccer is never a runtime dependency; nothing here calls .NET.

## Exit gate

All in `mcp/mdnav_v2/test/acceptance.mjs` — a verbatim copy of the legacy
[skills/doc-dive/mdnav/test/acceptance.mjs](../../../skills/doc-dive/mdnav/test/acceptance.mjs)
made at M0, then extended — via
the existing runner; the suite must report assert counts, not just PASS.

1. Every pre-existing acceptance test passes unchanged, except those that
   encode F1/F2 behavior, which are inverted and named as such.
2. `SpanSet`: union/intersect/subtract/complement agree with a brute-force
   bitmap over ≥ 200 random small interval sets; adjacent `[a,b)[b,c)` merge;
   outputs always normalized.
3. Claims table: sorted `Geometry` order; nested claims carry the correct
   `container`; `MemoryStore` and `SidecarStore` yield equal tables for the
   same bytes; sidecar round-trips at schema 3; unchanged file → no rescan
   under either store; a touched-but-identical file (mtime changed, digest
   same) → no rescan; changed bytes → that document only is rebuilt;
   schema-2 sidecar refreshed, not trusted; `Dnnn` ids identical after a
   `Corpus` is closed and reopened **and across successive `discover` runs
   on the same work-dir**; after 5 `discover` calls the work-dir holds
   exactly one `index/documents/Dnnn.json` per document and 5 run dirs each
   containing only `reads.jsonl` + `run.json`; `runs prune --keep 2` leaves
   two.
4. Rule collector: a `scope: line` rule cannot match across a line break; a
   `scope: whole` rule cannot match across an excluded gap (test with a
   pattern that would span it); a bad rule fails at load with file:line and
   leaves the table empty; `--strip-match` still works as a `custom` rule.
5. Fenced `data:` URI and fenced `<div>` survive `--strip all` under
   `default`; `discover` Notes for that doc show no `embedded=`/`html=`;
   `profile` counts them as `fence` content. Under a profile with
   `collect-inside: {fence: ["data-uri"]}` the same URI *is* found, with
   `container` = the fence.
6. Multi-line `<!-- … -->` is a claim, elided by `--strip all` (placeholder
   ≥ 1 KiB), and `# x` inside it is not a heading at any `--enter`.
7. `# x` inside a fence is not a heading (existing regression, kept).
8. `# x` inside `<details>` (blank line before): heading claim exists with
   `container` = the html-block, keeps its ordinal id; **not active** at
   `--enter ""` (unit = the whole block, `contains: heading×1` note);
   **active** under `--enter html-block`; partition invariant holds at both.
   Same for `> # x` inside a blockquote via the blockquote rule.
9. `***` and `----` segment under `--by breaks`; `profile` and `--by breaks`
   report the same break count.
10. Fixture with `[^1_1]`/`[^1_2]` in prose and `[^1_1]: https://…` defs
    at the end (one ref dangling, one def unused): both kinds are claims;
    `marks --kind footnote-ref --resolve` pairs them by label and flags the
    dangling ref; `profile` residue lists the unused def; `read --only
    footnote-def --for <unit>` returns just the defs that unit cites;
    `chat-export` profile strips the surrounding `<div>` furniture and keeps
    refs and defs. Same shape for `[text][id]` / `[id]: url`.
10b. Generic basis: `outline --by fence` and `--by pattern:'^\[\^[^\]\s]+\]:'`
    each produce units that tile the document byte-for-byte (partition
    invariant asserted per basis); `outline --within H0003 --by break`
    re-segments one unit; a toggle basis with an unclosed opener reports
    `unclosed` residue and still tiles.
11. `read --only fence` yields exactly the fenced bytes of a unit in order;
    `--only K` ⊕ `--strip K` reconstruct the unit byte-for-byte modulo
    placeholders.
12. `coverage` after `read --strip all` reports `unit − elided`; a kept
    citation label is not counted elided.
13. `discover --recursive .` ≡ `discover . --recursive`.
14. Byte fidelity: `read` without `--strip`/`--only` is byte-identical to the
    source span (existing).
15. `node -e "import('./mdnav.mjs').then(m => m.SpanSet && m.Selection)"`
    resolves without running the CLI.
16. `default` profile output for every existing fixture **and the 3.5 MB real
    corpus the README cites** is byte-identical to pre-change output for
    `outline`, `read`, `coverage`, `locate` (golden files captured in
    sequencing step 2, before any scanner changes), except where 5/6/9/12
    (bug fixes) and 8 (html-block-contained headings inactive by default)
    say otherwise. Every diff against the goldens must be attributable to
    one of those items by name; an unattributed diff fails the gate. The
    report must list which real-corpus documents changed under 8, so the
    `default` `enter` decision can be revisited with evidence.

## Method — new engine, ported presentation, old file as figure model

This is a **rewrite of the engine**, not a refactor: the brief inverts the
control flow (verbs become queries over a claims table built once), so
every verb body changes and the three divergent scanners are the thing
being replaced. Retrofitting a table under functions designed not to have
one would carry the old seams forward. But it is a rewrite *from a figure
model*: the legacy [skills/doc-dive/mdnav/mdnav.mjs](../../../skills/doc-dive/mdnav/mdnav.mjs)
encodes behavior the brief does not restate — PREAMBLE/BODY, setext suspects, the
partition invariant on odd documents, CRLF/BOM, unclosed-fence warning,
`UNBROKEN` windows, `--within` semantics, stamp `-2` suffixes, `LATEST`,
the work-dir refusal guard, `keepOf`, the blockquote regression the tests
encode — and that behavior is read and ported, never edited in place.

1. **Tests first, verbatim.** Copy the legacy `test/acceptance.mjs` into
   `mcp/mdnav_v2/test/` unchanged (binary path made configurable) and write
   the golden-capture script *before* any engine code. The new binary runs
   the old suite from day one (gate 1) and matches goldens under `default`
   (gate 16). The legacy file at `skills/doc-dive/mdnav/` is the oracle and
   is **never edited**; it keeps serving the doc-dive skill throughout.
2. **New engine, clean:** `SpanSet`, claims, collectors, containment,
   `Selection`, `materialize` — doccer-shaped, no lineage from the old
   scanners.
3. **Ported presentation and IO, with intent:** `parseArgs` (fixed),
   work-dir resolution + guard, inventory/ledger IO, `outline`/`discover`
   formatting, HELP, stderr conventions — copied because they are right,
   changed only where this brief says.
4. **README as the second figure model.** Design rule, address model,
   triage philosophy, artifact locality all stay true; amend, don't rewrite.
5. At parity, **repointing the doc-dive skill** at `mcp/mdnav_v2` (or
   keeping it pinned to legacy) is a separate, one-line decision recorded
   in `planning/decisions.md` — not part of the build. Nothing is deleted;
   v2 carries its own `mdnav.ps1`.

Chip plan follows the seam this creates: **Chip A — parity** (old suite +
goldens green on the new architecture, F1–F4 fixed; gates 1–7, 9, 13, 14,
16); **Chip B — the query surface** (containment/`--enter`, relations,
profiles, `--only`, generic `--by`, exports, budgets/paging, framing; gates
8, 10–12, 15, 17–21); then a **fresh-context review** against the gates.
Sequential, worktree-isolated, each appends its report below. Not parallel
sub-agents: one file, hard ordering, and a golden baseline that must be
captured before anything moves.

## Sequencing

1. `SpanSet` + property tests (2). Standalone.
2. Claims table + sidecar schema 3, populated by the *existing* scanners
   unchanged (3). Golden files captured here (16).
3. State-machine collector: unify fence trackers, add html-comment,
   html-block, math-block, frontmatter as region claims; prefix-parity fences
   with residue → (6), (7).
4. Rule collector + `rules/core.jsonl` carrying today's inline regexes;
   region-scoped execution → (4), (5). Shared `break` rule → (9).
5. Containment + re-entry + `--enter` → (8).
6. Relations (§2b) + Selection / suppression / profiles (`default`,
   `chat-export`) → (10);
   `read --only`, coverage on the algebra → (11), (12).
7. Exports + guard (15), `parseArgs` (13), docs (F3), `profile` verb census.
8. Report below; then the `server.mjs` brief.

## Report

_(appended by the implementing agent on completion — what shipped, what was
deferred and why, assert counts before/after, which kinds the fixtures
surfaced that this table lacks, and anything the claims/containment model
turned out to get wrong.)_
