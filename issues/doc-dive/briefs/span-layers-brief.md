# `mdnav` claims engine — typed span claims, profiles, containment — brief

**Status:** filed, not started · **Filed:** 2026-08-17 (rev 2, same day —
rev 1 framed this as "layers + masks"; superseded) · **Home:**
[mcp/mdnav/mdnav.mjs](../../../mcp/mdnav/mdnav.mjs) (single-file, zero-dep
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

One table per document, persisted in the sidecar (schema 2 → 3), columnar:
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
  Built-in rules live in `mcp/mdnav/rules/core.jsonl` (everything in the
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
  `mcp/mdnav/profiles/*.json`:
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

### Export surface (the MCP foundation)

`mdnav.mjs` gains named exports — `analyze`/`buildIndex`, `claimsOf`,
`SpanSet`, `Selection`, `loadRules`, `loadProfile`, `materialize(buf, spans,
policy)`, `coverageOf` — and the top-level CLI dispatch (last five lines
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

All in [test/acceptance.mjs](../../../mcp/mdnav/test/acceptance.mjs), via
the existing runner; the suite must report assert counts, not just PASS.

1. Every pre-existing acceptance test passes unchanged, except those that
   encode F1/F2 behavior, which are inverted and named as such.
2. `SpanSet`: union/intersect/subtract/complement agree with a brute-force
   bitmap over ≥ 200 random small interval sets; adjacent `[a,b)[b,c)` merge;
   outputs always normalized.
3. Claims table: sorted `Geometry` order; nested claims carry the correct
   `container`; sidecar round-trips at schema 3; unchanged file → no rescan;
   schema-2 sidecar refreshed, not trusted.
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
16. `default` profile output for every existing fixture is byte-identical to
    pre-change output for `outline`, `read`, `coverage`, `locate` (golden
    files), except where 5/6/9/12 say otherwise.

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
