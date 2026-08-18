# Phase 03 — containment, relations, profiles, generalized queries

> **Role:** execution-ready spec for roadmap milestone **M4**. Canon is
> [mdnav_v2_design-brief.md](../design/mdnav_v2_design-brief.md); depends on the claims table
> ([01-spanset-claims.md](01-spanset-claims.md)) and collectors
> ([02-collectors-parity.md](02-collectors-parity.md)) being in place.
> Sequencing/decisions in [planning/roadmap.md](../planning/roadmap.md) /
> [planning/decisions.md](../planning/decisions.md). Amend; do not fork.

**Depends on:** [02-collectors-parity.md](02-collectors-parity.md) (Chip A
done — parity, F1–F4 fixed). **Delivers:** gates 8, 8b, 8c, 10, 10b, 11, 12.
**Chip B begins here.** **Next phase:**
[04-repl-contract.md](04-repl-contract.md).

## 2b. Relations — keyed joins over claims

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

## 4. Containment and re-entry — the recursive discovery

The construction is canon
([mdnav_v2_structure-brief.md](../design/mdnav_v2_structure-brief.md) §2,
D41): at any window `W` with a context `C`, **carve** region claims (the
state-machine collectors of phase 02) → **mask** `M = W \ regions` →
**partition** `M` by the heading boundary spec into section nodes →
**recurse**, down the spine (next heading level, same window) and into
every region whose kind is enterable under `C` — a new window, a switched
context: inside `blockquote` the heading rule reads through `^ {0,3}>
{0,3}#{1,6}\s`; inside `html-block` it is the ordinary ATX rule; inside
`fence` nothing runs unless a profile says so; inside `list-item` the
continuation lines are the window — → **collect** inline leaves over `M`.
Everything found by re-entry is an ordinary claim **in source coordinates**
(no derived masters, no prefix stripping, no OffsetMap — doccer defers that
too), addressed under its parent's path (phase 01 §2, `containers[]`
derived from `path`). Nearest-container is `path` minus its last segment;
proper crossings between region claims are residue reported by `profile`,
not resolved.

This phase also builds the **inversion** (structure brief §3): a second,
independent construction from the flat claim set alone — a claim's parent
is the smallest claim whose span strictly contains it; the section tree is
a stack walk over heading claims per container window; every node's span
equals the union of its children's spans plus its own gaps. The two
constructions must **agree** (gate 8b); where they do not, or a region
fails to close, the residue kinds `crossing`, `escape`, `unclosed` +
`alternative`, `setext-suspect`, `unaligned`, `dangling`/`unused` are
reported — never repaired.

**Consequence for headings** — the third projection knob. README §Address
model has basis / depth / extent; this adds **enter**:

- Root heading ids stay `Hnnnn`, the flat legacy spine — **document order
  over root-window heading claims only**. A heading found by re-entry is
  addressed under its container's path (`…/q1/H1`, `…/x1/H1`), ordinal
  local to that window, and is never counted into the root spine — so
  **root ordinals cannot renumber when a new container kind becomes
  enterable** (a `github` `<details>`-pairing lens, list-item re-entry,
  a `--rules` file that finds headings inside fences: all add rows only
  under an existing path). `resolve()` (phase 01 §2) accepts a full path or
  any document-unique suffix, so every existing `Dnnn:Hnnnn@dig` anchor
  keeps resolving to the same bytes.
- A heading is *active* for units/outline/coverage when its **level ≤ depth
  AND its container chain is transparent**. The document root is transparent;
  region kinds become transparent via `--enter <kinds>` (or a profile). Default
  `--enter` is **empty**: `# x` inside `<details>` or a blockquote is not a
  unit boundary at top level; `outline` shows the containing region as one
  unit with a `contains: heading×2` note; `outline --enter html-block` (or
  `--within H0007 --enter html-block`) descends into it as a nested outline
  addressed under `H0007/x1/…`.
- Partition invariant unchanged, now asserted **per node** (gate 8b): active
  units tile their window byte-for-byte at every (depth, enter) combination.

This is the deliberate anchor-*activation* change the thread asked for. It is
opt-in-visible (`outline` names what it is not descending into) so nothing is
silently omitted.

## 5. Queries — projections over claims

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
  pattern:'^\[\^[^\]\s]+\]:'` (ad-hoc boundary). A basis cuts one **node**
  (the document root by default, or `--within <node>`), and the cut is
  addressed **under that node's path** — `H0007/S3` (third break segment
  inside section 7), `H0007/W2` (second window) — never a bare global
  `Snnnn`/`Rnnnn`, so two different bases over two different nodes cannot
  collide on one address (structure brief §4). One ledger throughout.
  Segmenting is recursive: `--within <node> --by <other>` re-cuts that node
  with a different delimiter — the XOR walk in CLI form.
- **`read`**: `--strip <kinds|@profile>` = `[S,E) \ coverage(sel)`;
  **new `--only <kinds>`** = `[S,E) ∩ coverage(sel)`; `--enter` as above.
  Placeholder ≥ 1 KiB with `@s..e`, `keepOf` label rule, ledger of elided
  spans, stderr warning before writing >64 KiB of stripped material — all
  unchanged. Materialization is the existing slice loop expressed as
  `subtract`; a `RewritePlan`-style ordered piece list is the internal shape
  so `--only`/`--strip`/`--enter` compose without a second code path.
- **`coverage`**: `union(reads) \ union(elided)` per doc; kept citation
  labels no longer counted elided (gate 12 — this is where the `keepOf`
  bookkeeping bug actually gets fixed: the ledger has existed since phase 01,
  but the fix depends on suppression/`--only` existing so "kept" is a
  well-defined query result rather than a special case).
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
- **`locate`**: unchanged surface; may take `--in`/`--not-in <kinds>` later
  (deferred, see roadmap).
- **`discover`/`index`**: build claims once, persist; Notes column driven by
  the profile's `triage` set; `--rules`, `--profile`.
- **`profiles`** / **`rules`** (new, trivial): list what is loaded and from
  where.
- README gains the kind table, the profile section, and *enter* as the
  third knob (F3).

## Implementation notes

**GFM slugs for the `anchor` relation.** Use GitHub's algorithm
(`github-slugger`): lowercase; remove characters that are not letters,
numbers, spaces, hyphens or underscores (Unicode letters kept); spaces →
`-`; **duplicate titles get `-1`, `-2`, … in document order**, so the
relation builder must slug headings in ordinal order and keep a
per-document counter, or `[see](#setup-1)` dangles against the wrong
heading. Store the computed slug in the heading claim's `info`.

## Exit gate (this phase)

Full text is the master list in [mdnav_v2_design-brief.md](../design/mdnav_v2_design-brief.md)
§Exit gate. This phase closes:

- **8.** `# x` inside `<details>`: claim exists at path `…/x1/H1`, container
  correct; root ordinals after it unchanged from legacy; inactive at
  `--enter ""` with `contains:` note; active under `--enter html-block`;
  per-node tiling holds at both. Same for `> # x` at `…/q1/H1`.
- **8b.** The top-down (carve/mask/partition/recurse) and bottom-up
  (smallest-containing-span, stack walk) tree constructions agree on every
  fixture and ≥ 200 generated documents; per-node tiling holds; every
  residue kind (`crossing`, `escape`, `unclosed`+`alternative`,
  `setext-suspect`, `unaligned`, `dangling`/`unused`) is exercised by a
  fixture and surfaces in residue, never repaired.
- **8c.** `select path startsWith P` ≡ `select span ⊂ span(P)` for every
  node; `read P` materializes exactly `span(P)`; `resolve()` takes a full
  path or a document-unique suffix, dies listing candidates on ambiguity;
  every legacy `Dnnn:Hnnnn@dig` anchor from the goldens still resolves.
- **10.** Footnote fixture (`[^1_1]`/`[^1_2]` refs, one dangling, one unused
  def): both kinds are claims; `marks --kind footnote-ref --resolve` pairs
  by label and flags dangling; `profile` residue lists the unused def;
  `read --only footnote-def --for <unit>` returns just the cited defs;
  `chat-export` strips furniture, keeps refs/defs. Same shape for
  `[text][id]` / `[id]: url`.
- **10b.** Generic basis: `--by fence` and `--by pattern:...` each produce
  projections addressed under the node they cut and tile that node
  byte-for-byte; `--within H0003 --by break` re-segments one node; an
  unclosed toggle basis reports `unclosed` + `alternative` residue and
  still tiles.
- **11.** `read --only fence` yields exactly the fenced bytes in order;
  `--only K` ⊕ `--strip K` reconstruct the unit byte-for-byte modulo
  placeholders.
- **12.** `coverage` after `read --strip all` reports `unit − elided`; a
  kept citation label is not counted elided. (Reconciled per D36 to this
  phase, not M3 — see the master gate list's note on gate 12.)

Partition invariant re-asserted per `(basis, depth, enter)`, at every node,
throughout.

## Sequencing (within this phase)

5. Containment + re-entry (carve/mask/partition/recurse/collect) + the
   inside-out inversion + `--enter` → gates 8, 8b, 8c.
6. Relations (§2b) + Selection / suppression / profiles (`default`,
   `chat-export`) → gate 10; generic basis under node-scoped addressing →
   gate 10b; `read --only`, coverage on the algebra → gates 11, 12.

## Report

_(appended by the implementing agent on completion — what shipped, assert
counts before/after, any relation/profile edge case the real corpus
surfaced, which residue kinds the fixtures and the real-document set
actually produced, whether the two tree constructions ever disagreed where
the fixtures did not predict it, and whether the gate-12 reconciliation
above held up in practice.)_
