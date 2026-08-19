# Phase 05 — stream framing P0 (sigil emission, byte accounting)

> **Role:** execution-ready spec for roadmap milestone **M5b**. Canon is
> [mdnav_v2_design-brief.md](../design/mdnav_v2_design-brief.md). Sequencing/decisions in
> [planning/roadmap.md](../planning/roadmap.md) /
> [planning/decisions.md](../planning/decisions.md). Amend; do not fork.

**Depends on:** [04-repl-contract.md](04-repl-contract.md) for the
`materialize`/plan contract this phase's framer fills in with a concrete
`framed` byte total. **Delivers:** gates 21, 21b. **Trajectory note, not a
gate (D37):** the sigil vocabulary and row grammar below are co-developed
with para-agent (D28, D30, D31) — a project in active development alongside
this one, not a formal dependency of it. Build this phase with that
direction in mind (reuse the `§`/`¶`/interleaving concepts as designed, keep
the wrapper narrow per D35/P0), decide and ship on the design as it stands
here, and reconcile with para-agent later as its own roadmap item ("After —
in-context atomic payload format brief"). This split from
[04-repl-contract.md](04-repl-contract.md) keeps framing/sigil work — the
newer, less-settled part of the design — separate from the export/paging
contract, which is mechanical and settled; it is a scoping choice, not a
blocking one.

## What P0 is, deliberately narrow (D35)

Per D35, the first prototype wraps **every result the backend returns to
the prompt** (bytes or table) in one barebones structure — opening sigil,
source identity, semantic sub-address, magnitude, content, close — so
results accumulate as bounded, attributed, re-mentionable objects. This
phase builds **that wrapper only**. Cross-document/file interleaving rules,
key-once vs self-identifying rows, codec vs raw, `||` vs LF, `⁂` close are
layered on P0 *after use* by the separate, later **atomic payload format
brief** (see [planning/roadmap.md](../planning/roadmap.md) "After" section)
— this phase's job is to ship something usable, evaluate it (D20), and feed
that evidence forward, not to pre-decide the general scheme.

## Stream framing — front-declared, typed, addressed regions

The para-agent note
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
stripped), which is the claims table reflected into the stream. The row
grammar is **psr** (below): sigil, address, ordinal-of-batch, kind, basis,
`content_meta {…}` for composition/size/stamps, then `span`,
`content_bytes`, `content` — machine fields last, `content` always final.

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

Row grammar — **principles borrowed from psr; the atomic payload format is
its own brief.** *(Roadmap item; this subsection is ideation, not spec.)*
Two things must stay distinct: **reposnapshot's artifact format** (psr —
`utils/reposnapshot/reposnapshot-v3/schema/psr.header.json`; a shard file
consumed by seeking and reading) and **the in-context atomic payload
format** this brief has been converging on — what the mdnav backend wraps
a chunk in *before* it enters the MCP user's context. The second borrows
the first's *principles* — psr's raison d'être is direct consumption by a
model, proven on real artifacts — but it is not a transcription of it, and
nothing already designed here (sigils `§`/`¶`, front-declared typed
addressed regions, key-once, addressable elisions, interleaving) is
displaced by it. Principles that transfer:

- `record_terminator` LF; `field_delimiter` ` | `; `{…}` blocks one level
  deep with space-separated sub-fields; `<type>` / `<type:width>` appended
  to column names in the header row; **empty marker = nothing between
  delimiters** (`|  |`); header row is the first physical line and
  byte-identical across a run.
- **The header row IS the grammar; a row is the header projected onto one
  entry; there is no row schema** — the anti-drift doctrine (LTS wrote the
  row grammar three times and nothing checked). mdnav's key row is rendered
  from one declaration and every row from the same object.
- **`content_bytes` immediately precedes `content`; adjacency is the seek
  contract.** mdnav's `len` *is* `content_bytes` and takes that name.
  `span` (source geometry) stays mdnav's and is deliberately not that column
  — one fact, one column.
- `content_meta {…}` is an **open element model**: mdnav's composition
  block is a `content_meta` with mdnav sub-fields (`prose code tbl … ~t`),
  declared in the key like any other.
- **One physical line per row.** Line breaks inside a content cell are
  encoded by the **codec** — 1:1 visible codepoint substitution (the
  Control Pictures direction of the shard notes), *never* `\n` escaping:
  escaping degrades legibility and its token cost grows linearly with
  volume, which is exactly why psr exists.

Records are **flat** (a unit with an elision is emitted as *pieces*, each
its own row — nothing nests arithmetically). The optional close row
`⁂ | <address>` re-mentions the address (a second retrieval hook), signals
completeness, and makes nesting legible — for the machine it is only a
checksum (address/position mismatch → framing fault). The key row is
declared once per session (adapter skill + first record), never per read.

**Row terminator in the stream.** psr files lean *no trailing delimiter*
(ledger #45); LF alone frames a row for a seek reader because
`content_bytes` frames the content. The stream reader is attention, not a
seek, and cannot count bytes, so an explicit **`||` row-close** (~1 token)
gives it what LF cannot: a visible "row complete" and an unmistakable end
to a text cell. Lean: `||` in the stream, LF alone in files — reconciled
deliberately at spec freeze, not by accident.

**The one real fork — `read`'s content cell.** psr-conformant is
codec-encoded, one physical line, exactly what has been seen to work at
scale for direct consumption. mdnav's CLI covenant is *literal source
bytes* (gate 14, phase 01). Both are renderings of the same piece list, so
`content: codec | raw` is profile data: `legacy-comment` (CLI default)
stays raw and byte-identical to today; the MCP default is decided by the
behavioral eval (D20), with **codec as the psr-conformant candidate**, not
pre-decided here.

**Illustrative sketch — not the format.** The shape being converged on is
roughly `<opening sigil> | <source identity> | <semantic sub-address> |
<token-length estimate> | <content> ||`; how much of the metadata rides on
every row versus a key declared once is *the* open design question, because
the stream **interleaves discontiguous chunks from different sources** — a
key-row-then-records pattern serves contiguous chunks of one document well,
but an interleaved stream needs each chunk to be sufficiently
self-identifying (source identity on the row, at minimum). Both patterns
were prototyped earlier and both survive into the payload brief.

```
§ | D002:H0108@fa8a | 2/5 unit d2 | {72 20 ~160t} | 61234..61863 | 412 | <content> ||
… | D002:H0108@fa8a/elided.1 | data-uri | {~404KiB} | 14187..430301 | 0 | ||
¶ | e17.reply | adjutant | {~90t} | | 340 | <content> ||
§ | D002:H0108@fa8a | 2/5 unit d2 | {100 0 ~55t} | 61651..61863 | 217 | <content> ||
⁂ | D002:H0108@fa8a ||
```

(A `§` document unit, an addressable elision, an interleaved `¶` exchange
from another source, the unit's second piece, and an optional close — the
`§`/`¶` glyphs from earlier are load-bearing here and are not displaced by
pipes. `<content>` is codec-encoded one-line or raw multi-line per profile;
the atomic format brief decides how the two coexist in one stream.)

**Emission is a profile setting, not a mode.** `sigils: legacy-comment |
typographic | none` (CLI flag `--sigils`, replacing the earlier `--frame`
naming); within `typographic`, which roles emit — close on/off, elision
sigil vs a plain zero-`content_bytes` open, `content: codec | raw` — is
also profile data. `legacy-comment` is today's `<!-- mdnav … -->` (itself a
sigil convention: the HTML comment is the Markdown-inert sigil) and stays
the CLI default, byte-identical to today; `typographic` is the MCP
default; close on/off is chosen by the behavioral eval (D20). **Header
field style: pipe-celled and positional, on psr's principles** — lean, not
decision; the atomic payload format brief (roadmap) owns it, together with
key-once vs self-identifying rows, `||` vs LF, codec vs raw, and how
`§`/`¶` chunks from different sources interleave. D29 measures costs; it
does not choose. Nothing is `k=v`.

**Namespace.** MCP tool names must not collide with native harness tools
(`read`, `grep`, `glob`, `edit`, …): every mdnav tool is prefixed
(`mdnav_read`, `mdnav_outline`, …) or lives under a single namespaced tool
with a verb argument — the server brief (not this one) decides which, but
bare verbs are out; noted here because the framing header carries the tool
identity this namespacing produces.

- Address = the anchor (`Dnnn:Hnnnn@digest`, or the full node path —
  `Dnnn:H0007/q1/H1@digest`, node-scoped `S`/`R`/`W` projections, or a raw
  `Dnnn:@s..e`) — the structure brief's path grammar (D41), extended for
  placeholders (`…/f2`, `…/elided1`) — every header is something the
  Primary can hand back to `read`. **A `read` whose selection spans more
  than one node or predicate emits one packet with one header per piece**
  (phase 03 §5, D43): pieces are ordered by document reading order (`ord`),
  not argument order, and each header's address names exactly the node(s)
  that piece came from — the general form of today's `<!-- mdnav
  Dnnn:Hnnnn -->` decoration on `--headings a,b,c`, now load-bearing for
  every multi-node or multi-predicate `read`, not only that one flag.
- **`content_bytes` is emitted UTF-8 bytes of the content cell (post-codec); `span` is source geometry. Never the same
  field** — under `--select`/`--ignore` they differ, and conflating them is the
  historic byte-semantics trap. Both are *machine* fields (round-trip,
  audit, tooling); the model-facing magnitude is the coarse `~629B` /
  `~404KiB` and the `k/N` ordinal — and, when a **client token profile** is
  loaded (roadmap: token-cost measurement battery, a separate brief), a
  measured estimate `~160t` beside it, computed from the unit's per-kind
  composition × the profile's per-kind ratios + header cost, stamped with
  the profile id in the read's `note`. That estimate is the empirical
  "length prefix": model-specific by measurement, never by a bundled
  tokenizer; absent a profile the field is bytes only and no token number
  is invented. Placeholders are zero-length coding regions with a header,
  so an elision is *addressable*, not just visible.
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
sentinel are cheap and well supported. Byte `content_bytes` has **no
attention benefit** (models do not count bytes; the boundary the model uses
is the next sentinel) — it is a machine field only. Headers cost ~10–15
tokens each, so frame at unit grain by default. The claim must be evaluated
behaviorally (same tasks, `--sigils none` vs `typographic`, close on/off;
address-recall accuracy, misattribution rate, tokens-to-answer) — a
server-brief gate, not an assumption here.

## Implementation notes

1. **Framer arithmetic is bytes, period.** The header glyphs `§` (U+00A7,
   `C2 A7`) and `¶` (U+00B6, `C2 B6`) are two UTF-8 bytes; every header
   line's cost is `Buffer.byteLength(line)`, every content cell's is its
   `content_bytes`, and `maxBytes` compares against their sum. `…` U+2026,
   `⁂` U+2042 and `†` U+2020 are **three** bytes, so the drift a `.length`
   framer accrues is one byte per `§`/`¶`, two per `…`/`⁂`/`†`, and one or
   two more for every non-ASCII codepoint in the content it framed — not a
   uniform +1 (D45 corrects the earlier gate wording that said otherwise).
   A framer written with `.length` passes every gate except 21b and then
   lies in the field — the historic byte-semantics trap wearing a new hat.
   Write headers and payloads to the same `Buffer`/stream so the count and
   the bytes cannot diverge; count the row terminator with the row.

## Exit gate (this phase)

Full text is the master list in [mdnav_v2_design-brief.md](../design/mdnav_v2_design-brief.md)
§Exit gate. This phase closes:

- **21.** Framing round-trip, **P0 scope** (D45): every result framed
  (single-anchor included); a multi-node/multi-predicate read emits one
  packet, one row per contiguous piece, ordered by `ord`, each address
  resolving back through `read` to the same span; under `--sigils
  typographic --content raw`, `content_bytes` exactness (multi-byte UTF-8
  and CRLF sources included) and concatenated content cells equal to the
  `--sigils none` read byte-for-byte; `--sigils legacy-comment`
  byte-identical to today's golden fixtures.
- **21b.** Byte accounting: total bytes == Σ **row bytes excluding the
  content cell** (prefix + delimiters + terminator — the terminator is
  inside the sum, or the plan's `framed` total lies) + Σ `content_bytes`.
  Per row prefix, `Buffer.byteLength(prefix) - prefix.length` == Σ (UTF-8
  length − 1) over its non-ASCII codepoints: **+1** for 2-byte `§`/`¶`,
  **+2** for 3-byte `…`/`⁂`/`†` — a per-glyph fixture table, not one
  constant. The content cell sits outside that identity: content is
  arbitrary UTF-8 (3-byte Control Pictures under `codec`), which is the
  whole reason `.length` accounting fails. Header parser round-trips every
  field; plan's `framed` total matches what a subsequent read actually
  writes; a `maxBytes` admitting payload but not payload + framing returns a
  plan, not bytes.
- **21c** is **not** this phase's (D45): codec round-trip, elision rows, the
  `⁂` close, `||` vs LF, key-once, cross-source interleaving — all the parts
  D35 defers past P0 — move to the atomic payload format brief and settle
  with the D20 eval. Gate 21 no longer asks this phase to certify what its
  own scope section says it will not decide.

## Sequencing (within this phase)

7 (second half). Framing as a projection over the piece list.

8. Report below; then the `server.mjs` brief (roadmap "After" section).

## Report

_(appended by the implementing agent on completion — what shipped, how far
para-agent's own design had moved by the time this phase was reached and
whether anything here should be revisited against it, the D20 behavioral
eval's result, and the default MCP budget/sigil choices actually made.)_
