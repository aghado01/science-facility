# `mdnav` claims engine — typed span claims, profiles, containment — brief

> **Role:** design canon — the "why" and the shape, at the altitude that
> applies across every phase. Execution is five sequential phase briefs in
> this directory ([01-spanset-claims.md](01-spanset-claims.md),
> [02-collectors-parity.md](02-collectors-parity.md),
> [03-containment-queries.md](03-containment-queries.md),
> [04-repl-contract.md](04-repl-contract.md),
> [05-framing-p0.md](05-framing-p0.md)), sequenced and gated in
> [planning/roadmap.md](../planning/roadmap.md) (milestones M0–M6, chip
> seams), the audit trail in [planning/decisions.md](../planning/decisions.md)
> (D1–D36, ascending), and the figure-model homework in
> [archaelogy/figure-model-survey.md](../archaelogy/figure-model-survey.md)
> (function-by-function dispositions, must-survive behaviors, test map).
> Amend this brief and the phase briefs; do not fork them.

**Status:** filed, not started · **Filed:** 2026-08-17 (rev 3, same day —
rev 1 framed this as "layers + masks", superseded by rev 2; rev 2 was one
886-line document mixing doctrine, per-milestone implementation detail, and
~200 lines of flagged ideation at one altitude — split into this canon plus
five phase briefs per D36, nothing discarded) · **Home:**
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
5. Thread of 2026-08-17: (a) masking is an index concept — kinds indexed
   independently so they can be filtered, read selectively, counted, composed;
   never "hide"; (b) `# x` inside an html-block is a **nested** heading reached
   by re-entering the block, not flattened to top level and not ignored;
   (c) drop the noise/prose binary — documents contain **typed objects**, and
   whether a type is signal or noise is a **profile** (a skill disposition), the
   way `nushell-mcp` has nu-skills/nu-modules; (d) span algebra + bitmaps over
   parsing — an AST tool (markdig) is not opposed, but parsing is brittle;
   (e) doccer is the inspiration, never the dependency; (f) rev 2 was split
   into this canon and five phase briefs (D36) after a review found the
   single document unusable as a working spec for one chip without reading
   past the others.

**Doccer sources** (read for the port; `D:\aghado01\codex-scientiae\src\doccer`,
10.6 k lines C#, README is the contract): `Algebra/SpanSet.cs`,
`Algebra/Suppression.cs`, `Core/SpanBatch.cs` (`SpanClaim`, `SpanLevel`,
`ClaimOrder`), `Collector/RegexCollector.cs` + `PatternRuleLoader.cs`
(`PatternRule`, `ExecutionScope`, region-scoped matching), `Algebra/Pairing.cs`,
`Vectors/BooleanVector.cs` (`PrefixParity`), `Core/TextSlice.cs`,
`Algebra/LaminarView.cs` + `HierarchyView.cs` (`NearestContainers`),
`Algebra/GapCadence.cs` (itself transcribed from mdnav's profiler),
`Materialization/RewritePlan.cs`. This repo is external to the mdnav_v2 work
tree; a phase brief that needs specific behavior from one of these files
quotes the relevant fragment rather than assuming the reader has this path
mounted.

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

Five primitives, in dependency order, each usable without the ones after it
(doccer's "capability library, not a pipeline"). Full spec for each lives in
its phase brief; this is the map.

1. **`SpanSet`** — geometry algebra over normalized sorted disjoint half-open
   byte intervals (union/intersect/subtract/complement/coverage/contains),
   identity-forgetting on purpose. → [01-spanset-claims.md](01-spanset-claims.md)
2. **Claims** — the occurrence table: one columnar record per document
   (starts/ends/kinds/sources/levels/priorities/ruleIds/containers/info), an
   open kind vocabulary, overlap and nesting preserved, backed by
   `MemoryStore`/`SidecarStore` over a corpus-scoped `index/` +
   run-scoped ledger layout. → [01-spanset-claims.md](01-spanset-claims.md)
   (table/stores/hygiene) and **2b. Relations** — keyed joins over claims
   (`footnote`, `link-ref`, `anchor`, `contains`) →
   [03-containment-queries.md](03-containment-queries.md)
3. **Collectors** — how claims are discovered: delimiter geometry (boundary /
   toggle / pair) as the unifying spec; state-machine collectors for region
   kinds, rule collectors (doccer `PatternRule`) loaded from JSONL, executed
   region-scoped. → [02-collectors-parity.md](02-collectors-parity.md)
4. **Containment and re-entry** — the recursive walk: region claims are
   containers, structural collectors re-enter each region window with
   region-specific rules, in source coordinates; `--enter <kinds>` is the
   third projection knob (basis / depth / extent / *enter*) governing heading
   activation. → [03-containment-queries.md](03-containment-queries.md)
5. **Queries** — projections over claims: Selection, suppression, profiles as
   data, generalized `--by`, `read --only`/`--strip`, `coverage`, `marks
   --resolve`. → [03-containment-queries.md](03-containment-queries.md).
   Export surface, the REPL/paging/budget contract, and stream framing (P0)
   are downstream of the query layer and live in
   [04-repl-contract.md](04-repl-contract.md) and
   [05-framing-p0.md](05-framing-p0.md).

## Non-goals (the whole brief — every phase inherits these)

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
  named in the phase briefs and the `enter`-driven activation described in
  [03-containment-queries.md](03-containment-queries.md).
- Not ported from doccer: Allen relations, `ClaimPairView`, path selection,
  facts/saturation, origins, `RewritePlan` as a public type, vectors beyond
  prefix parity. Cadence stays as is; note in the report whether the
  claims refactor makes `GapCadence`'s window-basis form a free alignment.
- Doccer is never a runtime dependency; nothing here calls .NET.

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
   changed only where a phase brief says.
4. **README as the second figure model.** Design rule, address model,
   triage philosophy, artifact locality all stay true; amend, don't rewrite.
5. At parity, **repointing the doc-dive skill** at `mcp/mdnav_v2` (or
   keeping it pinned to legacy) is a separate, one-line decision recorded
   in `planning/decisions.md` — not part of the build. Nothing is deleted;
   v2 carries its own `mdnav.ps1`.

Sequencing, chip seams, and milestone dependencies are
[planning/roadmap.md](../planning/roadmap.md)'s job, not restated here — a
second numbered sequence in this document is exactly the kind of drift F3
already names once (help/README/comment) and D36 found again (a gate
misattributed between this brief and the roadmap). One execution queue.

## Exit gate — master list (single source of truth; phase briefs cite by number)

All in `mcp/mdnav_v2/test/acceptance.mjs` — a verbatim copy of the legacy
[skills/doc-dive/mdnav/test/acceptance.mjs](../../../skills/doc-dive/mdnav/test/acceptance.mjs)
made at M0, then extended — via the existing runner; the suite must report
assert counts, not just PASS. Every gate below is closed by exactly one
phase brief; see [planning/roadmap.md](../planning/roadmap.md) for the
milestone → gate map kept in sync with this list.

1. Every pre-existing acceptance test passes unchanged, except those that
   encode F1/F2 behavior, which are inverted and named as such. — *01*
2. `SpanSet`: union/intersect/subtract/complement agree with a brute-force
   bitmap over ≥ 200 random small interval sets; adjacent `[a,b)[b,c)` merge;
   outputs always normalized. — *01*
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
   two. — *01*
4. Rule collector: a `scope: line` rule cannot match across a line break; a
   `scope: whole` rule cannot match across an excluded gap (test with a
   pattern that would span it); a bad rule fails at load with file:line and
   leaves the table empty; `--strip-match` still works as a `custom` rule. — *02*
5. Fenced `data:` URI and fenced `<div>` survive `--strip all` under
   `default`; `discover` Notes for that doc show no `embedded=`/`html=`;
   `profile` counts them as `fence` content. Under a profile with
   `collect-inside: {fence: ["data-uri"]}` the same URI *is* found, with
   `container` = the fence. — *02*
6. Multi-line `<!-- … -->` is a claim, elided by `--strip all` (placeholder
   ≥ 1 KiB), and `# x` inside it is not a heading at any `--enter`. — *02*
7. `# x` inside a fence is not a heading (existing regression, kept). — *02*
8. `# x` inside `<details>` (blank line before): heading claim exists with
   `container` = the html-block, keeps its ordinal id; **not active** at
   `--enter ""` (unit = the whole block, `contains: heading×1` note);
   **active** under `--enter html-block`; partition invariant holds at both.
   Same for `> # x` inside a blockquote via the blockquote rule. — *03*
9. `***` and `----` segment under `--by breaks`; `profile` and `--by breaks`
   report the same break count. — *02*
10. Fixture with `[^1_1]`/`[^1_2]` in prose and `[^1_1]: https://…` defs
    at the end (one ref dangling, one def unused): both kinds are claims;
    `marks --kind footnote-ref --resolve` pairs them by label and flags the
    dangling ref; `profile` residue lists the unused def; `read --only
    footnote-def --for <unit>` returns just the defs that unit cites;
    `chat-export` profile strips the surrounding `<div>` furniture and keeps
    refs and defs. Same shape for `[text][id]` / `[id]: url`. — *03*
10b. Generic basis: `outline --by fence` and `--by pattern:'^\[\^[^\]\s]+\]:'`
    each produce units that tile the document byte-for-byte (partition
    invariant asserted per basis); `outline --within H0003 --by break`
    re-segments one unit; a toggle basis with an unclosed opener reports
    `unclosed` residue and still tiles. — *03*
11. `read --only fence` yields exactly the fenced bytes of a unit in order;
    `--only K` ⊕ `--strip K` reconstruct the unit byte-for-byte modulo
    placeholders. — *03*
12. `coverage` after `read --strip all` reports `unit − elided`; a kept
    citation label is not counted elided. — *03* (reconciled by D36: the
    brief's own Sequencing text and Chip-plan paragraph both tied this to
    relations/`--only`/profiles landing, i.e. M4; an earlier `roadmap.md`
    draft had listed it under M3 — corrected there to match)
13. `discover --recursive .` ≡ `discover . --recursive`. — *01*
14. Byte fidelity: `read` without `--strip`/`--only` is byte-identical to the
    source span (existing). — *01*
15. `node -e "import('./mdnav.mjs').then(m => m.SpanSet && m.Selection)"`
    resolves without running the CLI. — *04*
16. `default` profile output for every existing fixture **and the 3.5 MB real
    corpus the README cites** is byte-identical to pre-change output for
    `outline`, `read`, `coverage`, `locate` (golden files captured in M0,
    before any scanner changes), except where 5/6/9/12 (bug fixes) and 8
    (html-block-contained headings inactive by default) say otherwise. Every
    diff against the goldens must be attributable to one of those items by
    name; an unattributed diff fails the gate. The report must list which
    real-corpus documents changed under 8, so the `default` `enter` decision
    can be revisited with evidence. — *01 (capture) / 02 (F1/F2 deltas) / 03
    (item 8 delta)*
17. `select`/`partition`/`marks` honour `limit/offset` and always return
    `total`. — *04*
18. `materialize` over `maxBytes` returns a plan with zero bytes and anchors
    that, followed, produce a within-budget read. — *04*
19. No table query can return a field longer than the preview cap. — *04*
20. The CLI exposes `--max-bytes` and `--limit/--offset` so the one-shot path
    has the same discipline. — *04*
21. Framing round-trip: under `--sigils typographic` every row's
    `content_bytes` equals the content cell's bytes exactly (post-codec under
    `codec`, raw under `raw`) (incl. multi-byte UTF-8 and CRLF sources), the
    concatenated coding regions of a multi-anchor read equal the `--sigils
    none` read byte-for-byte, an elision emits a zero-`content_bytes` row
    whose address `read` accepts and resolves to the elided source span, and
    `--sigils legacy-comment` output is byte-identical to today's for the
    golden fixtures. — *05*
21b. Byte accounting: total bytes written == Σ `Buffer.byteLength(row bytes
    excluding content)` + Σ `content_bytes`; each header line's byte length ==
    its char length + 1 (the glyph is the only non-ASCII bytes — asserted for
    every sigil in the vocabulary, incl. the 3-byte `…`/`⁂`); a header parser
    that reads the stream back recovers every address, `k/N`, `span`,
    `content_bytes` exactly; the plan's `framed` total equals the bytes a
    subsequent read within budget actually writes; a `maxBytes` that admits
    the payload but not payload + headers returns a plan, not bytes. — *05*

## Report

Each phase brief (01–05) carries its own Report section, appended by the
agent that implements that phase. This canon is amended once all five close
and M6's fresh-context review has run — see
[planning/roadmap.md](../planning/roadmap.md) M6.
