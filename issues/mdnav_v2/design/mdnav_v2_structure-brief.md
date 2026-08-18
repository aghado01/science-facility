# `mdnav` v2 — recursive structure discovery: flat claims, path addresses, telescope surface — design brief

> **Role:** design canon for the *structural model* — how a document's
> structure is discovered, stored, addressed, and offered to a reader.
> **Supersedes** (2026-08-17, D41): [mdnav_v2_design-brief.md](mdnav_v2_design-brief.md)
> §Shape items 2–5 as a *relationship* (the five primitives stand; how they
> compose is restated here); [../briefs/01-spanset-claims.md](../briefs/01-spanset-claims.md)
> §2 column list; [../briefs/03-containment-queries.md](../briefs/03-containment-queries.md)
> §4 (containment / re-entry / heading activation) and §5's addressing;
> decisions D11 and D13. **Does not change:** doctrine, non-goals (one is
> sharpened, §7), method (goldens first, legacy as figure model), M0–M6
> order, D39/D40 layout, or any gate except 8 and 10b (reworded, §8) plus
> new 8b/8c. Phase briefs 01–03 are to be amended to cite this document;
> until then, where they disagree with it, this document wins.

**Status:** filed 2026-08-17, not started · **Origin:** the M0 capture
discussion of the same day, stepping back from the "nested heading
ordinal" question ([../reports/fable-planning-briefs-review-20260817.md](../reports/fable-planning-briefs-review-20260817.md)
§3.1) to the model that makes it a non-question · **Home:**
`mcp/mdnav_v2/` · **One-line:** *the backend's first job is to discover
every valid Markdown object and resolve the hierarchy to the extent it
exists — spine and object graph alike — by one recursive procedure, store
the result as flat rows with structure in a path field, and let a reader
telescope in and out by address.*

---

## 1. Two hierarchies, one procedure

A Markdown document carries two hierarchies, overlaid, only one of them
delimited:

- **Container blocks — explicit.** Fence, html-block, html-comment,
  math-block, frontmatter are **opaque leaves**: nothing inside them is
  structure. Blockquote, list → list-item, footnote-def, table are
  **containers**: things inside them *are* structure, and they nest by
  containment (a list item holds a blockquote holds a fence). This is the
  block-structure half of CommonMark's own two-phase strategy — resolvable
  line by line from prefixes and block conditions — and it needs no inline
  parsing. The object graph.
- **Sections — implicit.** A heading opens a section that runs to the next
  heading of ≤ level *within the same container window*. No closing token;
  H1 followed by H2 means the H2 is structurally contained by the H1. The
  root window has a section tree; so does every container that holds
  headings. The spine.

Both are products of **one recursive step** over a window with a context
(§2). Both are stored **flat** (§4). Neither is repaired: where the two
constructions of the tree (§3) disagree, that is residue, reported.

## 2. The construction — carve, mask, partition, recurse, collect

At any **window** `W` (a byte span, in source coordinates — no derived
masters, no offset maps, D12) with a **context** `C` (which delimiter specs
apply here, and how lines are prefixed):

1. **Carve** — run `C`'s region specs over `W` in one line-driven pass:
   opaque kinds by state (fence opener/closer rule as legacy: same char,
   ≥ length, empty info; `$$`; `<!--`…`-->`; frontmatter at offset 0; html
   block-start conditions 1–7 with their terminators), then container
   line-runs (blockquote `>`, list markers, table rows; **a blank line
   closes a run**). Yields region claims `R₁…Rₙ` and residue (`unclosed`,
   `crossing`). Toggle-defined regions use prefix parity for residue only —
   *which lines are delimiters is decided by the state machine, not by XOR
   over every fence-looking line.*
2. **Mask** — `M = W \ ⋃Rᵢ`. The text of `W` at this resolution; a
   `SpanSet`, nothing more.
3. **Partition** — run `C`'s boundary spec over `M` (ATX headings, prefix-
   aware per `C`; every level, the depth cut is a *query* later) → section
   nodes. A section's extent is contiguous in `W` — heading line to the
   next boundary of ≤ level found in `M` — so it **contains** whatever
   regions fall inside it, while its boundaries are only ever found in `M`.
4. **Recurse, two ways:**
   - *down the spine* — each section is partitioned by the boundary spec at
     level + 1 over its own span ∩ `M`;
   - *into containers* — each container region whose kind is enterable
     under `C` becomes a new window with a switched context: `blockquote`
     reads through the `> ` prefix (boundary spec `^ {0,3}> {0,3}#{1,6}\s`,
     regions likewise prefixed); `list-item`: the item's continuation window;
     `html-block`, `footnote-def`: ordinary rules; `fence` and other opaque
     kinds: nothing, unless a lens says so (then whatever is found lives
     *under* the fence's path and can never disturb the spine).
5. **Collect** — rule collectors (inline objects: links, refs, defs, tags,
   data-URIs, signed URLs, wikilinks, inline code, `custom:*`) run over `M`,
   piece by piece, so a match can bridge neither an excluded region nor a
   line break. Leaves of whatever section or container holds them.

```
shake(W, C, level):
  R  = carve(W, C.regions)                       # regions + residue
  M  = W \ union(R)
  S  = partition(M, C.boundary, level)           # sections, extents contiguous in W
  L  = collect(M, C.rules)                       # inline leaves
  for s in S: s.children += shake(s.span, C, level+1)          # spine
  for r in R: if C.enterable(r.kind): r.children = shake(r.window, C[r.kind], 1)   # object graph
  return rows(S, R, L) + residue
```

**Carve before partition** is the whole ordering rule, and it is what the
current gates already say in special-case form: `# x` in a fence is not a
heading (7); `# x` in a comment is not (6); `> # x` is not a *root* boundary
but *is* one inside the quote (8); F1's fix is step 5 running over `M`.
Nearest container, `--enter`, `--within` re-segmentation (`--by` is a
different boundary spec handed to step 3 at one node) all fall out.

**"To the extent it exists."** Container runs are line-runs closed by a
blank line — CommonMark lazy continuation is a named limitation, not
emulated. Shape-detected tables and html blocks may include lines a real
parser would reject. Unclosed fences swallow to EOF (still a tree, a wrong-
looking one — see §3). Setext headings are suspects, never promoted.

## 3. The inversion — validate outside-in against inside-out

The recursion *assigns* every node its parent by construction: the window
it was found in. A second, independent construction uses only the flat rows
— spans and heading levels — with no memory of the walk:

- a claim's parent is the **smallest claim whose span strictly contains
  it** (SpanSet containment, identity-forgetting);
- the section tree is the **stack walk over heading claims per container
  window** (legacy `subtreeEnd`, done inside-out);
- every node's span equals the union of its children's spans plus its own
  gaps — the **partition invariant per node**, at every node, not only per
  depth cut.

**Agreement is a gate (8b). Disagreement is residue. Reconciliation is
reporting both readings, never repairing.** Residue kinds:

| kind | meaning | example |
|---|---|---|
| `crossing` | two regions from different specs overlap without nesting | shape-detected `<div>` block vs a blockquote run |
| `escape` | a claim found in a child window whose span leaks past that window | a collector bug — caught mechanically |
| `unclosed` + `alternative` | an opaque region swallowed to EOF; the alternative reading closes it at the next delimiter-looking line and reports what reappears | "unclosed fence at L412; 6 headings after it are read as content" |
| `setext-suspect` | `===`/`---` underline after a non-blank line | as legacy |
| `unaligned` | H1 count vs break count | as legacy `aligned` tri-state |
| `dangling` / `unused` | relation residue | footnote ref with no def; def no ref cites |

The inversion is also the **test oracle for the recursion**: two
implementations, property-tested against each other on generated documents
and every fixture, exactly as `SpanSet` is tested against a bitmap.

## 4. The data structure — flat rows, structure in the path

One table per document (the IR of D39; columnar, interned, content-
addressed). Nothing is nested in the file. Overlap is the norm: a claim over
a sub-span is valid under its parent.

```
ord   path                  kind         span            level  info                 digest
0     /fm                   frontmatter  0..212          —      —                    —
1     /H0001                heading      213..9840       1      title="Design…"      8502
2     /H0001/p1             paragraph    240..612        —      —                    —
3     /H0001/q1             blockquote   613..1900       —      —                    —
4     /H0001/q1/H1          heading      619..1420       2      title="What I…"      c1d3
5     /H0001/q1/H1/f1       fence        700..1380       —      lang=bash            —
6     /H0001/H0002          heading      1901..9840      2      title="Notes"        0cc4
7     /H0001/H0002/p1       paragraph    1930..2400      —      —                    —
8     /H0001/H0002/p1/link1 link         2210..2260      —      target=…             —
```

Columns: `ord`, `path`, `kind`, `start`, `end`, `level` (headings),
`source` (which collector), `priority`, `ruleId`, `info` (kind-specific),
`digest` (where a title exists). `parent` = `path` minus its last segment;
`container` (nearest region ancestor) is derived; both may be materialized
as columns for speed but are not authoritative.

**Three identities at three stabilities, all in the row:**

- **`ord`** — reading order: the row index in Geometry sort (start asc, end
  desc, then discovery). Stable within one build of the IR. The machine's
  handle; what `limit/offset` page over.
- **`path`** — the structural address (grammar below). Stable under engine
  evolution and lens choice — a new enterable kind or a lens that looks
  inside fences only ever adds rows *under* an existing path. The agent's
  handle.
- **`digest`** — 4 hex of the title text (legacy recipe). Stable under edits
  elsewhere in the document. The "did this move under me" guard.

An anchor is `Dnnn:<path-or-suffix>@digest`.

**Path grammar.** `/` separates segments; each segment is `<code><n>`, `n`
1-based among siblings of that kind under the same parent, in reading
order.

| code | kind | | code | kind |
|---|---|---|---|---|
| `Hnnnn` | heading, **root window only** — flat document-order ordinal over root headings at any level, 4-digit (legacy spine, `H0000` = PREAMBLE/BODY) | | `Hn` | heading inside a container window (flat within that window) |
| `p` | paragraph | | `q` | blockquote |
| `f` | fence | | `x` | html-block |
| `c` | html-comment | | `m` | math-block |
| `l` / `i` | list / list-item | | `t` | table |
| `d` | footnote-def | | `fm` | frontmatter |
| `S` / `W` | projections: break segments / byte windows cut *under* a node (`/H0007/S3`, `/H0007/W2`) | | `elided` | placeholder piece under a read (`/H0007/elided1`, brief 05) |
| *(name)* | inline kinds spelled out: `link1`, `footnote-ref2`, `data-uri1`, `html-tag3`, `custom:pixel1` | | | |

Root spine ids nest in the path (`/H0001/H0002` for an H2 under an H1)
because the path *expresses* structure; the ids themselves are unique
document-wide, so **`resolve()` accepts a full path or any unique suffix**:
`H0002` alone resolves; `H1` inside a quote does not (every quote has one),
so `q1/H1` or the full path is required; ambiguity dies listing the
candidates. Legacy anchors `Dnnn:Hnnnn@dig` therefore keep resolving
unchanged. Titles resolve too, as a convenience (`read 'What I checked'
--within H0007`), never as an identity.

**Consequences.** Nested headings need no numbering rule (the review's §3.1
dissolves — a heading in a quote is `…/q1/H1`, and no root ordinal can move
when the engine learns a new place to look). `S`/`R` ambiguity dissolves
(projections are cut under a node and named under it). Coverage stays
**byte-based** — union of materialized spans — because rows overlap by
design and counting rows would double-count. **"Give me section 1"** is one
selection with two equivalent forms — `path startsWith /H0001` (top-down)
and `span ⊂ span(H0001)` (bottom-up) — and their equality *is* the
agreement gate (8c); materialize the union and you get the section with
everything nested in it; cut with `--depth`/`--enter`/`--only` and you get
a coarser view of the same rows.

## 5. The surface — telescope, not chunks

"Would you like to know more" is the tree, one level per call. A call names
a node and returns its **children at the next resolution** — each a span
with an address, a kind, a magnitude, and a **census of what is under it**
(the legacy `contains:` note generalized to every kind at every level):

```
tree D002:H0007 --enter blockquote
  addr           kind        span           level  contains                        title / preview
  H0007/q1       blockquote  61234..61863   —      heading×1 fence×1 link×3        > Framing statement from…
  H0007/q1/H1    heading     61240..61700   2      fence×1                         What I checked
  H0007/f1       fence       61870..62410   —      —  [bash]                       # this is a comment, not…
  H0008          heading     62411..70120   2      blockquote×2 footnote-ref×4     Notes
```

Because the kind vocabulary is universal, the census makes "know more"
predictable: at any node the reader knows what drilling could reveal and how
it is encoded, without opening it. Every response is a typed table or bytes
(D16); the verbs are tree operations — **`tree`** (children of a node at a
cut), **`read`** (materialize a node: unit / subtree / `--only` / `--strip`),
**`find`** (pattern under a node → rows), **`status`** (coverage, residue,
what is loaded) — and the legacy verbs are projections of them
(`outline` = `tree` at the heading cut with legacy formatting, `marks` =
`tree --kind`, `profile` = census + residue at the root, `locate` = `find`,
`coverage` = `status`). Framing ([../briefs/05-framing-p0.md](../briefs/05-framing-p0.md))
wraps *whatever comes back*; discovery never speaks in chunks.

**The telescope knobs, restated:** `--depth` = the level at which the spine
recursion is cut for this view; `--enter <kinds>` = which container windows
are transparent for that cut; `--within <addr>` = which node is `W`; `--by
<spec>` = swap the boundary spec at that node (breaks, windows, a kind, a
pattern) — a projection, addressed under the node; `--only`/`--strip <kinds>`
= which leaf kinds are materialized. All are queries over the same rows.

## 6. What this changes in the plan (edits to make)

| document | change |
|---|---|
| canon `mdnav_v2_design-brief.md` §Shape | items 2–5 gain "composed as [structure brief] §2–§4"; item 2's column list defers to §4 here; Non-goal "no CommonMark parser" → "no *inline* parser; block structure by shape and block conditions" |
| `briefs/01-spanset-claims.md` §2 | columns per §4 (`ord`, `path`, `digest` explicit; `containers[]` derived); the kind table stays; add the path-code table |
| `briefs/02-collectors-parity.md` §3 | collectors are `carve` / `partition` / `collect`; fence = state machine emitting matched delimiters, parity for residue only; `<!--`/`-->` is a pair |
| `briefs/03-containment-queries.md` §4 | replaced by §2–§3 here (recursion + inversion + residue kinds); §5 addressing per §4 here; `--enter` semantics unchanged; `S`/`R` → projections under a node |
| `briefs/04-repl-contract.md` | export surface + REPL contract expressed over `tree`/`read`/`find`/`status`; census column is part of every `tree` row |
| `briefs/05-framing-p0.md` | address bullet: `Dnnn:<path>@dig`; placeholder = `…/elidedN` in the same grammar |
| `planning/decisions.md` | D41 (this brief; amends D11, D13) |
| `reports/m0-legacy-capture-20260817.md` §1 | `legacyView(doc)` is a *projection of the tree* into the legacy sidecar shape; `--json` (D40) returns rows per §4 |
| survey §429–471, §592–604 | "ids over all heading claims" → root spine flat, nested by path |

## 7. Non-goals (reaffirmed, one sharpened)

Everything in the canon's Non-goals stands. Sharpened: **no inline parser** —
the block-structure phase (containers, opaque regions, section overlay) is
computed by shape and block conditions and *is* the model; inline structure
beyond rule-collected leaves is never computed. No repair: residue is
reported with the alternative reading, never resolved. No semantics:
`kind` is what a construct *is*, never what it *means*; signal-vs-noise is a
lens.

## 8. Exit gates (this brief's contribution to the master list)

- **8 (reworded).** `# x` inside `<details>` (blank line before): a heading
  claim exists at `…/x1/H1` with `container` = the html-block; root ordinals
  after it are what they would be if the block were opaque; not active at
  `--enter ""` (unit = the whole block; the `tree` row's census shows
  `heading×1`); active under `--enter html-block`; per-node tiling holds at
  both. Same for `> # x` at `…/q1/H1`. The gate-16 report lists every
  fixture/real document whose *root* numbering differs from legacy — the
  only admissible causes are gate 6 (comment-interior `# x` no longer a
  heading) and this gate (html-block-interior `# x` no longer at root).
- **8b (new) — agreement.** For every fixture and ≥ 200 generated
  documents, the top-down tree (parent by window) equals the bottom-up tree
  (parent by smallest strictly-containing span; sections by stack walk per
  window); every node satisfies span == union(children) ∪ gaps; each residue
  kind in §3 is exercised by a fixture and appears in `status`/`profile`
  residue, never resolved.
- **8c (new) — selection identity.** For every node, `select path
  startsWith P` ≡ `select span ⊂ span(P)`; `read P` materializes exactly
  `span(P)`; `resolve()` accepts full paths and unique suffixes, dies listing
  candidates on ambiguity, and resolves every legacy `Dnnn:Hnnnn@dig` anchor
  from the goldens to the same bytes.
- **10b (reworded).** Generic basis: `--by fence` / `--by pattern:…` /
  `--by breaks` / `--windows N` under a node produce projections addressed
  `<node>/Sn` or `<node>/Wn` that tile that node byte-for-byte; `--within
  <node> --by <spec>` re-segments one node; an unclosed toggle basis reports
  `unclosed` + `alternative` and still tiles.

## Report

_(appended by the implementing agent(s) of phases 02–03 once the recursion,
inversion and path resolution land — assert counts, which residue kinds the
fixtures and the real-document set actually produced, and whether the two
tree constructions disagreed anywhere the fixtures did not predict.)_
