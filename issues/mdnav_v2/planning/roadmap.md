# mdnav v2 — roadmap

**Design canon:** [design/mdnav_v2_design-brief.md](../design/mdnav_v2_design-brief.md)
(the "why" and the shape; do not fork it — amend it) and, for the
structural model — recursive discovery, flat rows with path addresses,
inside-out agreement, telescope surface —
[design/mdnav_v2_structure-brief.md](../design/mdnav_v2_structure-brief.md)
(D41, 2026-08-17; supersedes brief 03 §4 and the addressing in D11/D13). **Homework:**
[../archaelogy/figure-model-survey.md](../archaelogy/figure-model-survey.md).
**Locations:** v2 is built in `mcp/mdnav_v2/`; the legacy oracle is
`skills/doc-dive/mdnav/` and is never edited. **Decisions:**
[decisions.md](decisions.md). **Phase briefs** (execution-ready specs, one
per milestone group; the canon above stays doctrine/shape/non-goals only,
per D36): [01-spanset-claims.md](../briefs/01-spanset-claims.md) (M1+M2) ·
[02-collectors-parity.md](../briefs/02-collectors-parity.md) (M3) ·
[03-containment-queries.md](../briefs/03-containment-queries.md) (M4) ·
[04-repl-contract.md](../briefs/04-repl-contract.md) (M5a) ·
[05-framing-p0.md](../briefs/05-framing-p0.md) (M5b). This file is the
execution queue: milestones, what each delivers, which brief gates it
closes, and what it depends on. Statuses: `planned` · `in progress` ·
`done <date>` · `deferred`.

Milestones are sequential. Chip A = M0–M3 (parity). Chip B = M4–M5b (query
surface). M5 splits into **M5a** (exports/paging/budgets — settled,
mechanical) and **M5b** (sigil/framing emission — the newer, less-settled
part of the design, developed with para-agent's trajectory in mind; see M5b
below) so the two don't have to move at the same pace. M6 is a
fresh-context review. The `server.mjs` brief follows and is out of scope
here.

## Bigger picture — where this is going

**mdnav is the case study, not the destination.** The idea under test is
*structured context-stream delivery*: every chunk a tool returns to an
agent's prompt arrives with addressing, provenance, boundaries, and a
magnitude the agent can plan against, so that as results accumulate across
many tool calls, many files, and many tools, self-attention is handed
bounded, attributed, re-mentionable objects instead of an undifferentiated
span. Markdown documents are the **tractable domain to prove it on**:
structure is discoverable by delimiter geometry, everything is
byte-addressable, anchors are digest-stable across sessions, elisions can be
addressed rather than lost, and one engine (this brief) owns both the index
and the delivery. That is why the sequence is engine → MCP/REPL → payload
framing P0 on mdnav results → eval, and only then generalization.

**The destination is para-agent**, where the same principles apply to
*everything* tools return — shell/exec output, file reads of any type,
sub-agent replies, scrutiny and quarantine results, logs, MCP results from
servers we do not control — and where it gets materially harder:

- **No natural anchors.** A Markdown unit has `Dnnn:Hnnnn@digest`; a shell
  result has a command, an exit code, and bytes. Source identity + semantic
  sub-address must generalize to things without inherent structure
  (exchange ids `e17.tool.3`, byte/line offsets into a retained record,
  content digests) — the transcript store's identifiers, projected.
- **Heterogeneous content.** Prose, code, JSON, tables, binary-ish dumps,
  another agent's reply — one wrapper grammar, per-kind magnitude estimates
  (the token battery's per-kind ratios are what make `~Nt` honest here),
  and codec/raw decisions per kind, not per stream.
- **Volume and velocity.** Many results per turn, some huge; budgets, plans,
  and handles (the REPL contract) become the norm rather than a `read`
  nicety, and eviction/summarization must keep the pointer when it drops
  the bytes.
- **Composition with the harness's own framing.** Tool results already
  arrive inside the harness's `tool_result` structure; the wrapper composes
  with that boundary rather than fighting it, and namespaces must not
  collide with native tools.
- **Results from tools we do not own.** para-agent can wrap what passes
  through it; it cannot restructure what it does not mediate. The design
  has to degrade gracefully to "source identity + boundary" when nothing
  more is known.

**Path:** (1) this brief — engine; (2) `server.mjs` — REPL/MCP over it;
(3) payload P0 on mdnav results + the D20 eval; (4) the token battery
(shared); (5) the atomic payload format brief proper, informed by (3);
(6) para-agent adopts the wrapper for its mediated tool returns, mdnav
vendored in as the document channel, the transcript store supplying
identity for everything else. Each step is checkable on its own; none
requires the next to be designed first.

## M0 — Baseline and goldens · `planned`

Nothing in the engine changes. Capture the oracle.

- Copy `test/acceptance.mjs` verbatim to run against a configurable binary
  path (`MDNAV_BIN`, default the old file).
- Golden-capture script: for every fixture the suite generates, record
  `discover`, `outline` (depths 1–3, `--by breaks`, `--windows`, `--comp`),
  `read` (each mode, with/without `--strip all`), `coverage`, `locate`,
  `profile`, `marks --kind fence|blockquote|table` — stdout **and** stderr
  bytes — under a pinned work-dir/run. Store under `test/golden/` keyed by
  fixture + argv.
- Record baseline: 130/0, 1,165 lines, sidecar layout as is.
- **Gates:** 1 (harness), 16 (goldens exist and pass against the old binary).
- **Depends on:** nothing. **Delivers:** the definition of "nothing discarded".

## M1 — `SpanSet` · `planned`

Standalone `span-set.mjs` (permitted sibling): normalize, `union`,
`intersect`, `subtract`, `complement(len)`, `coverage`, `contains`. Bitmap
oracle property tests (≥ 200 random sets). No engine wiring yet.

- **Gates:** 2. **Depends on:** nothing. **Brief:**
  [01-spanset-claims.md](../briefs/01-spanset-claims.md) §1 SpanSet.

## M2 — Claims table, stores, hygiene layout · `planned`

New `mcp/mdnav_v2/mdnav.mjs` skeleton (the legacy file stays where it is):
columnar claims table + `Doc`/`Corpus` shape; `MemoryStore` +
`SidecarStore` sharing schema 3; the D39 layout — content-addressed IR
under `$MDNAV_CACHE/ir/v3/<sha>.json`, investigation work-dir
(`inventory.json`, `runs/<stamp>/{run.json,reads.jsonl}`, `LATEST`),
explicit-or-bust work-dir resolution (no global `LAST` pointer), `runs
prune`, `cache prune`; `--json` on `discover`/`index` (D40, the suite's
seam). **Populated by ported copies of the existing scanners** so outputs
are unchanged while the plumbing lands. Ported presentation and IO
(survey dispositions "PORT"): `parseArgs` (whitelisted, F4), work-dir
resolution + refusal guard, inventory/ledger IO, all verb formatters, HELP.

- **Gates:** 3, 13, 14, 16 (goldens still byte-identical), suite §hygiene
  re-pointed at the new layout **without weakening** (dot-skip, refusal,
  work-dir `LATEST`, `-2` suffix, precedence all still asserted; the two
  global-`LAST` assertions are replaced by "a `Dnnn` call with no work dir
  dies naming the override", per D39).
- **Depends on:** M0, M1. **Brief:**
  [01-spanset-claims.md](../briefs/01-spanset-claims.md) §2 (table, stores,
  hygiene), F4.

## M3 — Collectors → parity · `planned`

Replace the ported scanners with the v2 collectors: one L0 state-machine
pass (frontmatter, fence with prefix parity + `fence-unclosed` residue,
`html-comment`, `html-block` per CommonMark 1–7, `math-block`); L1
structural (heading, setext-suspect, `break` shared regex, paragraph,
blockquote/list/table/`html-block` runs — blank line closes a run); rule
collector + `rules/core.jsonl` carrying today's `data-uri`, `html-tag`,
`signed-url` (target test + keep label as `info`), `image-ref`, plus
`link`, `link-ref`, `link-def`, `footnote-ref`, `footnote-def`,
`inline-code`, `wikilink`; region-scoped execution (`Total \ inert` by
default); `--strip-match` as a `custom` rule. Census/triage from claims.
`coverage` on the algebra. Legacy untouched; repointing the doc-dive skill
is a separate decision (brief §Method 5).

- **Gates:** 4, 5, 6, 7, 9; 16 with the F1/F2 golden deltas explicitly
  inverted and named; suite additions for fenced noise, non-`---` breaks,
  multi-line comment, flag order. (Gate 12 — `coverage`/kept-label — moved
  to M4 by D36: the brief's own Sequencing text and Chip-plan paragraph both
  tie it to relations/select-ignore/lenses landing, not to this milestone;
  this list previously carried it in error.)
- **Depends on:** M2. **Brief:**
  [02-collectors-parity.md](../briefs/02-collectors-parity.md), F1–F3,
  cosmetic fixes.
- **Exit = Chip A done.** Report appended to the brief.

## M4 — Containment, relations, query language, lenses, generic basis · `planned`

Re-entry walk (region-specific rules, `container` column, nearest
container); `--enter <kinds>` as the third activation knob (root ordinals
unchanged; `outline` prints `contains:` on undescended regions); relations
(`footnote`, `link-ref`, `anchor` with GFM slug dedupe, `contains`) with
residue; a row-field query language (path/kind/level/span/ord/title/digest/
tags, relation joins via `via`) with `select`/`ignore` as ordered predicate
lists (D43) replacing `--only`/`--for`/`--in`/`--not-in`; lenses as JSON
(D44; `default` reproduces today; `chat-export`); generic `--by
<kind|pattern:>` with node-scoped `S`/`R`/`W` addressing and per-basis
partition invariant; `marks --resolve`; `profile` verb as full census +
residue.

- **Gates:** 8, 10, 10b, 11, 12 (12 moved here from M3 by D36 — see that
  milestone's note); partition invariant re-asserted per (basis, depth,
  enter).
- **Depends on:** M3. **Brief:**
  [03-containment-queries.md](../briefs/03-containment-queries.md) §2b, §4,
  §5 (basis, read, marks, lenses).

## M5a — Exports, REPL/paging/budget contract · `planned`

`isMain` guard (win32-safe) + named exports (`Corpus`, `Doc`, `SpanSet`,
`Selection`, `loadRules`, `loadProfile`, `materialize`, `Ledger`); paged +
counted queries (`limit/offset/columns` → `{total, rows}`), memoization by
`(digest, policy, args)`; budgeted `materialize` returning a **plan** over
`maxBytes`; CLI `--max-bytes`, `--limit/--offset`; `notes[]` out of band.

- **Gates:** 15, 17, 18, 19, 20.
- **Depends on:** M4. **Brief:**
  [04-repl-contract.md](../briefs/04-repl-contract.md).

## M5b — Framing P0 (sigil emission, byte accounting) · `planned`

Framing as a projection over the piece list — `--sigils legacy-comment`
(default CLI, byte-identical to today) | `typographic` | `none`; sigil
vocabulary + key measured and fixed at freeze; header field order fixed,
addressable placeholders, `content_bytes`/`span` distinct. **Trajectory
note, not a gate** (D37): the sigil vocabulary and row grammar are
co-developed with para-agent (D28/D30/D31), which is itself in active
development alongside mdnav_v2 — build with that direction in mind, decide
and ship on the design as it stands, reconcile later as its own roadmap
item.

- **Gates:** 21, 21b (byte accounting: headers count toward `maxBytes`;
  `§`/`¶` are 2 UTF-8 bytes, `…`/`⁂` are 3; all framer arithmetic is
  `Buffer.byteLength`, and the test asserts header bytes == chars + 1).
- **Depends on:** M5a (for the `materialize`/plan contract its framer fills
  in). **Brief:** [05-framing-p0.md](../briefs/05-framing-p0.md).
- **Exit = Chip B done.** Report appended.

## M6 — Fresh-context review · `planned`

A reviewer that has not seen the build: given the canon, the five phase
briefs, the survey, and all five phase reports; tries to break every gate;
dogfoods v2 on the
`issues/mdnav_v2/discussion/` corpus and one large real transcript; checks
README/HELP against behavior (F3 closed for real). Findings appended as a
dated review under `discussion/`.

## After — `server.mjs` brief (separate)

Tool names over the export surface; session/result store (`$rN` handles);
freezing the `§`/`¶` header spec with para-agent; default MCP budget chosen
from measured reads; the framed-vs-unframed behavioral gate; embeddable
`createMdnavTools` + stdio runner; vendoring into para-agent.

## After — in-context atomic payload format brief (separate, shared with para-agent)

**What:** the schema for what the mdnav backend (and para-agent) wraps a
chunk of content in *before* it enters the MCP user's context — the
lightweight, separator-based structure whose whole purpose is the
context-window optimization this thread has been working toward. **Not**
reposnapshot's artifact format: psr is a shard file consumed by seeking; this
is a stream consumed by attention. It borrows psr's *principles* (declare
before content; length/estimate prefix in lieu of escaping; positional
pipe-celled metadata; the header row is the grammar; empty marker; one
physical line per record where possible) and nothing else by default.

**Design inputs already established here (all survive into the brief):**
sigils `§` (document unit) and `¶` (exchange/turn) as the leading cell,
`…` for addressable elisions, optional `⁂` close; front-declared typed
addressed regions with `k/N`; the model-facing magnitude as a measured
token estimate (`~Nt`, from the token battery) rather than bytes; source
identity + semantic sub-address on every chunk; addressable elisions;
budgets counting emitted bytes/tokens including wrappers.

**P0 — the first prototype, deliberately narrow: atomic payload framing
per tool-call result.** Not the cross-document/file scheme in one go. The
mdnav backend wraps *every result it returns to the prompt* — bytes or
table — in one barebones structure, because agents make many tool calls
across many files and tools and those results accumulate sequentially; the
wrapper gives each accumulated chunk **addressing, provenance, and
boundaries** so self-attention has reliable structure to work with instead
of an undifferentiated span. Minimum a P0 wrapper carries, and nothing
more: opening sigil (`§` document unit / `¶` other), **source identity**
(tool + document/corpus — the provenance that makes results from different
tools distinguishable when interleaved), **semantic sub-address** (anchor,
claim address, or query id — what the agent re-mentions), **magnitude**
(bytes; `~Nt` once a token profile exists), the content, and a close.
Key/legend delivered once via the adapter skill. Everything else in this
item (key-once vs self-identifying rows, codec vs raw, `||` vs LF, `⁂`
close, cross-document interleaving rules) is layered on P0 after it has
been *used* — the eval (D20) runs against P0 first, and P0's shape is
allowed to be wrong.

**Open questions the brief must answer:** (1) rough shape `<sigil> |
<source identity> | <semantic sub-address> | <token estimate> | <content>
||` — which cells are per-row vs declared once in a key, given that the
stream **interleaves discontiguous chunks from different sources**
(key-then-records suits contiguous chunks of one document; interleaving
needs self-identifying rows — both prototyped, both must coexist);
(2) `||` vs LF as record close in the stream; (3) content cell codec
(one physical line) vs raw multi-line, and how both coexist in one stream;
(4) how the key/legend is delivered (adapter skill, first record of a
session, both); (5) tool **namespace** — no collisions with native harness
tools (`read`, `grep`, `glob`, …): `mdnav_*` prefixes or one namespaced
tool with a verb argument. **Evaluation:** D20 behavioral eval and D29
token battery decide the contested points; nothing pre-decided.

## After — token-cost measurement battery (separate, shared with para-agent)

**What:** a model-agnostic, empirical measurement of **token cost per
symbol and per pattern**, in lieu of a standalone tokenizer (not always
available for a given model), captured as **client/model-specific profiles**
that are reused and refreshed when models change. **This is the empirical
model behind the "length prefix":** the header's model-facing magnitude
becomes a *measured* token estimate for the client in use — `~629B ~160t`
— computed as Σ (unit's per-kind bytes, from the claims-table composition)
× (per-kind bytes→tokens ratio, from the client profile) + header cost,
stamped with the profile id for provenance. Model-specific by measurement,
not by reverse-engineering a tokenizer.

**Why here:** the framing header's cost (`§`, `¶`, `k/N`, `~629B`, `@digest`,
`span=..`) and the `~size` coarse magnitude are only honest in *tokens* if
we have measured them; budgets and later context-mode hooks want tokens,
not bytes; glyph choices (D28) should be validated, not assumed.

**How (sketch):** measure through the model itself, which is what makes it
agnostic — a token-count endpoint where one exists, otherwise usage deltas
(prompt a probe string, read reported input tokens, difference against a
baseline). Battery: (a) **registers** — ASCII letters/digits/punctuation,
whitespace and newline forms (LF/CRLF), Latin-1 Supplement, General
Punctuation, box drawing, a CJK sample, emoji, combining marks; bytes→tokens
ratio per register; (b) **the framing vocabulary in situ** — whole header
lines and their fields, because BPE merges with neighbours so an isolated
glyph's cost is not its cost inside `§ D002:H0108@fa8a 2/5 …`; report
ranges, not single numbers; (c) **typical payload mixes** — prose, fenced
code, tables, base64 — so `~629B` can carry a `~tokens` estimate per kind.
**Output:** `profiles/tokens/<client>-<model>-<date>.json` with per-register
ratios, per-pattern costs, and the probe set + method so it can be re-run.
**Consumers:** the framer's coarse-size field (`~629B ≈ ~160t`), `maxBytes`
→ `maxTokens` translation, D28 glyph validation, para-agent routing hooks.
Not a tokenizer; a lookup table with provenance and a refresh procedure.

## Deferred (named so they are not silently dropped)

Cadence (`GapCadence` alignment) — note in M3 report whether free.
`locate` as a first-class predicate verb rather than a post-match filter
(the field query language of D43 makes `--in`/`--not-in`-shaped filtering
available today with no bespoke flag; a dedicated `locate` surface for it
is still deferred). Pairing for named tag sets under a lens (primitive
exists after M3; no lens turns it on yet). Any second segmentation policy
beyond first-viable-boundary. Anything Allen / path-selection / facts /
origins from doccer.
