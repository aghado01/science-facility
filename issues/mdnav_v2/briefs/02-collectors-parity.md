# Phase 02 — collectors: state-machine + rule, parity with F1–F4 fixed

> **Role:** execution-ready spec for roadmap milestone **M3**. Canon is
> [span-layers-brief.md](span-layers-brief.md); the claims table this phase
> populates is specified in [01-spanset-claims.md](01-spanset-claims.md).
> Sequencing/decisions in [planning/roadmap.md](../planning/roadmap.md) /
> [planning/decisions.md](../planning/decisions.md). Amend; do not fork.

**Depends on:** [01-spanset-claims.md](01-spanset-claims.md) (claims table,
stores must exist). **Delivers:** gates 4, 5, 6, 7, 9, 16 (F1/F2 deltas
named). **Exit = Chip A done** (M0–M3): the old suite plus goldens are green
on the new architecture, F1–F4 fixed. Report appended below closes Chip A;
[planning/roadmap.md](../planning/roadmap.md) M6 (fresh-context review)
follows Chip B, not this phase directly. **Next phase:**
[03-containment-queries.md](03-containment-queries.md).

## 3. Collectors — how claims are discovered

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
  kind table in [01-spanset-claims.md](01-spanset-claims.md) that is
  regex-shaped); further inventories are for constructs Markdown does *not*
  define — a corpus-specific tracking pixel, a house citation style, an
  export tool's wrapper tags — loaded via `rules/*.jsonl` or `--rules
  <file>`. Load-time validation with per-line provenance on failure.
  `--strip-match <re>` becomes sugar for a one-off rule of kind `custom`.

Collection is **transactional per document**: a failing rule leaves the
table untouched and names its line.

**The `NOISE` table today** (`data-uri`, `html`, `signed-url`, `image-ref`;
`STRIP_ALL = ['data-uri','html','signed-url']`) absorbs into
`rules/core.jsonl` entries plus `keep` as claim `info`; `STRIP_ALL` becomes
the `default` profile's `strip` set (profiles land in phase 03, but this
phase must preserve the `STRIP_ALL` set's exact membership so that handoff
is a data move, not a behavior change). Must-survive: signed-url **target
test** and **label keep**; image-ref opt-in; the wrapper-vs-bare data-uri
distinction; **outer-span-wins dedupe** (a data-uri inside an `<img>` tag).

## Implementation notes

**CommonMark HTML block conditions, verbatim.** Start conditions and their
terminators — 1: `<script`/`<pre`/`<style`/`<textarea` … line containing
`</script>` etc.; 2: `<!--` … `-->`; 3: `<?` … `?>`; 4: `<!` + letter …
`>`; 5: `<![CDATA[` … `]]>`; 6: one of the ~60 block-level tag names,
open or close … **first blank line**; 7: any complete open or close tag
alone on the line (cannot interrupt a paragraph) … first blank line. Type
2 is emitted as the `html-comment` kind, not as `html-block`, so the two
never double-claim. Types 6/7 ending on a blank line — never on a matching
close tag — is what keeps malformed transcript HTML bounded.

## Exit gate (this phase)

Full text is the master list in [span-layers-brief.md](span-layers-brief.md)
§Exit gate. This phase closes:

- **4.** Rule collector: `scope: line` cannot cross a line break; `scope:
  whole` cannot cross an excluded gap; a bad rule fails at load with
  file:line and leaves the table empty; `--strip-match` still works as a
  `custom` rule.
- **5.** Fenced `data:` URI and fenced `<div>` survive `--strip all` under
  `default`; `discover` Notes show no `embedded=`/`html=`; `profile` counts
  them as `fence` content; under `collect-inside: {fence: ["data-uri"]}` the
  URI *is* found with `container` = the fence.
- **6.** Multi-line `<!-- … -->` is a claim, elided by `--strip all`
  (placeholder ≥ 1 KiB), and `# x` inside it is not a heading at any
  `--enter` (activation itself is phase 03, but the claim/container must
  already be correct here).
- **7.** `# x` inside a fence is not a heading (existing regression, kept).
- **9.** `***` and `----` segment under `--by breaks`; `profile` and `--by
  breaks` report the same break count.
- **16 (F1/F2 deltas).** Every diff against the M1 goldens attributable to
  5/6/9 by name; unattributed diffs fail the gate.

Plus suite additions named in [planning/roadmap.md](../planning/roadmap.md)
M3: fenced noise, non-`---` breaks, multi-line comment, flag order.

## Sequencing (within this phase)

3. State-machine collector: unify fence trackers, add html-comment,
   html-block, math-block, frontmatter as region claims; prefix-parity fences
   with residue → gates 6, 7.
4. Rule collector + `rules/core.jsonl` carrying today's inline regexes;
   region-scoped execution → gates 4, 5. Shared `break` rule → gate 9.

## Report

_(appended by the implementing agent on completion — what shipped, assert
counts before/after, which kinds the fixtures surfaced that the phase-01
table lacks, whether `GapCadence`'s window-basis alignment fell out free per
the Non-goals note, and anything the collector model turned out to get
wrong. This closes Chip A.)_
