# `mdnav` span layers — kind-labeled span index + interval algebra — brief

**Status:** filed, not started · **Filed:** 2026-08-17 · **Home:**
[mcp/mdnav/mdnav.mjs](../../../mcp/mdnav/mdnav.mjs) (single-file, zero-dep
Node ≥ 18; a sibling `span-set.mjs` is permitted, a six-module split is not —
see Non-goals) · **Purpose:** generalize the substrate under every existing
verb so the incubating **mdnav MCP** can import it in-process instead of
shelling out. **Nothing currently working is discarded.** Every verb keeps
its CLI, its output format and its anchors; what changes is what they are
computed *from*.

**Lineage** (the conversation this brief closes out, in order):

1. Codex converged spec v0.1 — [codex-design-discussion-full.md](../discussion/codex-design-discussion-full.md)
   §1–13 (`mdnav outline D002 --depth 3` → H0107–H0141). Contract for
   discover/index/outline/read; governing principles (attention is the
   instrument; structure informs navigation without determining meaning;
   source authoritative; never silently omit bytes); non-goals incl. "MCP
   wrapping unless later justified". The MCP is now justified — it is being
   built — so this brief is the substrate work that justification implies.
2. Fable review 2026-07-29 — [fable-review-20260729.md](../discussion/fable-review-20260729.md)
   §"mdnav tooling" (H0002). F1 noise detection fence-blind (confirmed again
   today, see Problem), F2 `profile` vs `--by breaks` disagree on what a
   break is, F3 help/README/comment drift, F4 greedy boolean flags. **All
   four are still open** — the only commit since is the move to `mcp/`
   (8d063b8). This brief absorbs them.
3. Sol XOR note — [sol-XOR-discussion.md](../discussion/sol-XOR-discussion.md).
   mdnav as a *consumer witness* of doccer primitives, not their definition;
   the recursive walk (classify delimiter candidates → mask/parity → bounded
   regions → re-enter with context-specific rules → repeat); every
   intermediate result keeps its material basis and source coordinates.
4. Gemini note 2026-08-16 — [gemini-mdnav-next-gen.md](../discussion/gemini-mdnav-next-gen.md).
   Port doccer's `SpanSet` interval algebra; hierarchical mask layers;
   slice-program materialization; cadence; a module/MCP blueprint. This brief
   takes the algebra and the layers, corrects the framing (below), and defers
   the module split and `server.mjs` to their own brief.

**Doccer sources** (read for the port, not a runtime dependency):
`D:\aghado01\codex-scientiae\src\doccer\Algebra\SpanSet.cs` (263 lines),
`Algebra\GapCadence.cs`, `Materialization\RewriteMaterialization.cs`.

## Framing correction, stated once

A **mask is not a way to hide things.** It is one *layer* of an index: the
set of spans of one kind, indexed independently so any reader can filter it
out, read only it, count it, or compose it with other layers. Policy — what a
given `read` elides, what `outline` counts, what the heading scanner ignores
— is a *projection over layers chosen at query time*, never a property of
the layer. Doccer's `SpanSet` "deliberately forgets claim identity" — it is
the algebra, not the index. mdnav needs both: **kind-labeled span records per
layer** (what `constructRuns` and `noiseSpans` already emit, but persisted
and unified) plus **`SpanSet`** for composing queries over them. The Gemini
note ports only the algebra; do not let the port flatten kinds into one
anonymous mask.

## Problem

Three symptoms, one cause. Probe today (345-byte doc, scratchpad):

- `<!--` … `-->` spanning lines **leaks through `--strip all`**.
  `noiseSpans` (mdnav.mjs:223) feeds the regex one line at a time, so
  `<!--[\s\S]*?-->` can never match. The comment at :222 says multi-line
  HTML is "reported rather than pretended away" — nothing reports it (F3).
- A `data:image/png;base64,…` inside a ```` ```html ```` fence **is elided**
  by `--strip all` — the fenced example is destroyed, and `discover`/`index`
  triage counts quoted example code as noise (F1; the July repro reported a
  doc as "25.7 % embedded" when every byte was a fenced example).
- `profile` calls `***` / `----` a `break`; `--by breaks` accepts only exact
  `---` (mdnav.mjs:416) and returns one segment for the whole file, silently
  (F2). The documented profile→marks→basis telescope dead-ends.

Cause: mdnav has **three independent scanners** with three notions of extent
— the heading pass in `analyze()` (fence-aware, frontmatter-aware),
`constructRuns()` (fence-aware, its own break regex), and `noiseSpans()`
(no fence state, line-scoped regex) — and no shared way to say "search this
region minus those regions". Every verb re-scans at call time and each
composes exclusions by hand (`if (n.start < p) continue;`).

## Shape

### Layers

A **layer** is a kind-labeled list of byte spans over the immutable source:
`{ kind, start, end, info? }`, half-open, byte coordinates, sorted by start.
Spans of *different* layers may nest or overlap (a `data-uri` inside an
`html-block` is both). Within one layer spans are disjoint.

| family | kinds | extent rule (end condition) | today |
|---|---|---|---|
| inert | `frontmatter` | `---` at byte 0 … next `---`/`...` line | detected in `analyze` |
| inert | `fence` | opening ```` ``` ````/`~~~` (char+len tracked) … matching close, else EOF + warn | `constructRuns`, `analyze` (twice) |
| inert | `html-comment` | `<!--` … first `-->`, any number of lines, no nesting | **missing** |
| inert | `math-block` | `$$` line … `$$` line | missing (cheap; optional) |
| structural | `heading` `break` `blockquote` `list` `table` `paragraph` `html-block` | current `LINE_KIND` runs; **`break` = `-{3,}|\*{3,}|_{3,}` everywhere** (F2); `html-block` uses CommonMark block *end conditions* (types 1–5 terminator string, 6–7 blank line) — **never open/close tag pairing** (an unclosed `<div>` in a transcript would swallow the file) | `constructRuns` |
| noise | `data-uri` `html-tag` `signed-url` `image-ref` `custom` | existing detectors + `keepOf` label rule; scanned over `Total \ (fence ∪ html-comment ∪ frontmatter)` | `noiseSpans` (unmasked) |

`html-tag` (single tag, inner text preserved — today's `html` noise kind)
and `html-block` (whole block) are **two layers**, not one. "Strip tags,
keep prose" is a projection over the first; "elide the whole `<details>`" is
a projection over the second. Both must be available; today only the first
exists and it is the default `--strip all` member. Keep that default.

**Scan discipline** (order matters, everything in byte offsets):

- L0 inert extents: one state machine, one pass. Replaces the two duplicated
  fence trackers.
- L1 structural: line classification over `Total \ (fence ∪ frontmatter)`.
  Headings additionally exclude `html-comment`. **Headings inside
  `html-block` remain headings** — GitHub renders `# x` after a blank line
  inside `<details>` as a heading, mdnav counts them today, and changing that
  would move anchors in existing corpora. Flag as a decision; default no
  change.
- L2 noise: over `Total \ (fence ∪ html-comment ∪ frontmatter)`. Outer-span-
  wins dedupe (already there) stays.

### Algebra — `SpanSet`

Port of doccer `SpanSet`: normalized sorted disjoint half-open intervals,
linear two-pointer `union`, `intersect`, `subtract`, `complement(len)`,
`coverage` (Σ lengths), `contains(offset)`. ~60 lines. Constructed *from* a
layer (`SpanSet.of(layer)`) or from anchor spans; identity is dropped on
purpose at this boundary — that is what makes it a mask. The Gemini sketch's
`intersect`/`subtract` are correct as written; verify against a brute-force
bitmap in tests rather than by inspection.

### Verbs, re-expressed (outputs unchanged unless noted)

- `index`/`discover` — build all layers once; persist in the sidecar
  (schema 2 → 3); `noise` and `counts` derived from layers; triage no longer
  counts fenced examples. Sidecar reused when digest matches, as today.
- `outline` — unit/subtree sizes unchanged; `noise=` column computed as
  `unit ∩ ∪(STRIP_ALL layers)`; composition (`--comp`) reads layers.
- `read` — `--strip <kinds>` = `[S,E) \ ∪(kind layers)`; **new dual
  `--only <kinds>`** = `[S,E) ∩ ∪(kind layers)` (read just the fences of a
  unit; just the tables). Placeholder ≥ 1 KiB, `keepOf` label rule, ledger of
  elided spans — all unchanged. Byte fidelity without `--strip`/`--only`
  unchanged (existing test).
- `coverage` — `union(reads) \ union(elided)` per doc. Fixes the cosmetic
  "kept citation label counted as elided" while here.
- `locate` — unchanged surface; may take `--in <kinds>` / `--not-in <kinds>`
  later; not required by this brief.
- `profile`, `marks --kind`, `--by breaks` — all read the same layers, so
  they agree by construction (F2).
- `parseArgs` — whitelist value-taking flags so `discover --recursive .`
  works (F4). Orthogonal, small, touched anyway.
- Help text / README / :222 comment — made true (F3). README §Triage gains
  the layer table; §Windowing note about fence-aware headings extends to
  comments.

### Export surface (the MCP foundation)

`mdnav.mjs` gains named exports — `analyze`/`buildIndex`, `layersOf`,
`SpanSet`, `materialize(buf, spans, {strip, only})`, `coverageOf`. The
top-level CLI dispatch (last five lines of the file today: `parseArgs` →
`VERBS[verb](args)`) moves under an `if (isMain) main()` guard keyed on
`import.meta.url` vs `process.argv[1]` — there is **no guard and no export
today**, so `import()` currently runs the CLI. After this, `server.mjs` (next
brief) does `import { … } from './mdnav.mjs'` and never spawns a process. CLI
behavior is unaffected.

## Non-goals (this brief)

- No six-module split, no `server.mjs`, no "virtual database engine". One
  file, optionally `span-set.mjs` beside it. Modularization is a later,
  separate decision once the MCP's needs are concrete.
- No CommonMark parser. Layers are extents by shape; the codex non-goals
  (classification, semantic chunking, ranking, repair, rewriting) all stand.
- No open/close tag-pair HTML masking.
- No change to anchor ids, `Dnnn:Hnnnn@digest`, unit/subtree partition
  semantics, `--depth` semantics, or any existing output format except where
  a fix above says so.
- Cadence (`GapCadence` port) is not in scope; `profile`'s existing cadence
  is left as is unless the layer refactor makes the CV thresholds trivially
  alignable — note it in the report either way.

## Exit gate

All in [test/acceptance.mjs](../../../mcp/mdnav/test/acceptance.mjs), run
via the existing runner; suite must report the assert count, not just PASS.

1. Every pre-existing acceptance test passes unchanged, except tests that
   encode F1/F2 behavior, which are inverted and named as such.
2. `SpanSet`: `union`/`intersect`/`subtract`/`complement` agree with a
   brute-force bitmap over ≥ 200 random small interval sets; normalization
   merges adjacent `[a,b)[b,c)`; results are always normalized.
3. Fenced `data:` URI and fenced `<div>` survive `--strip all`; `discover`
   Notes for that doc show no `embedded=`/`html=`; `profile` counts them as
   `code`, not noise.
4. Multi-line `<!-- … -->` is elided by `--strip all` (placeholder when
   ≥ 1 KiB), counted in `noise.html-comment`, and `# x` inside it is not a
   heading.
5. `# x` inside a fence is not a heading (existing regression, kept).
6. `***` and `----` (blank line before) segment under `--by breaks`;
   `profile` and `--by breaks` report the same break count.
7. `read --only fence` on a unit yields exactly the fenced bytes of that unit
   in order; `--only` ∪ `--strip` of the same kinds reconstruct the unit
   byte-for-byte (placeholders aside).
8. `coverage` after reading a unit with `--strip all` reports
   `unit_bytes − elided_bytes`; a kept citation label is not counted elided.
9. Sidecar: layers persisted at schema 3; a second `index` on an unchanged
   file does not rescan (assert via a spy/timing or a `--stats` line on
   stderr); a schema-2 sidecar is refreshed, not trusted.
10. `discover --recursive .` and `discover . --recursive` behave identically.
11. Byte fidelity: `read` without `--strip`/`--only` is byte-identical to the
    source span (existing).
12. `node -e "import('./mdnav.mjs').then(m => m.SpanSet)"` resolves and does
    not run the CLI.

## Sequencing

1. `SpanSet` + property tests (2). Standalone; nothing else depends on it yet.
2. Unify the fence trackers into one L0 pass; add `html-comment`; persist
   layers in the sidecar (schema 3). Existing tests still green.
3. Route `noiseSpans` through the L0 mask → (3), (4). Route `analyze` break
   detection to the shared `break` regex → (6). Reads (7), coverage (8).
4. `--only`, exports (12), `parseArgs` (10), docs (F3).
5. Report below; then the `server.mjs` brief.

## Report

_(appended by the implementing agent on completion — what shipped, what was
deferred and why, test counts before/after, anything the layer model turned
out to get wrong.)_
