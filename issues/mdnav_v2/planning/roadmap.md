# mdnav v2 — roadmap

**Design canon:** [briefs/span-layers-brief.md](../briefs/span-layers-brief.md)
(the "why" and the shape; do not fork it — amend it). **Homework:**
[../archaelogy/figure-model-survey.md](../archaelogy/figure-model-survey.md).
**Locations:** v2 is built in `mcp/mdnav_v2/`; the legacy oracle is
`skills/doc-dive/mdnav/` and is never edited. **Decisions:**
[decisions.md](decisions.md). This file is the execution queue: milestones,
what each delivers, which brief gates it closes, and what it depends on.
Statuses: `planned` · `in progress` · `done <date>` · `deferred`.

Milestones are sequential. Chip A = M0–M3 (parity). Chip B = M4–M5 (query
surface). M6 is a fresh-context review. The `server.mjs` brief follows and
is out of scope here.

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

- **Gates:** 2. **Depends on:** nothing. **Brief:** §1.

## M2 — Claims table, stores, hygiene layout · `planned`

New `mcp/mdnav_v2/mdnav.mjs` skeleton (the legacy file stays where it is):
columnar claims table + `Doc`/`Corpus` shape; `MemoryStore` +
`SidecarStore` sharing schema 3; corpus-scoped `index/` (inventory +
`documents/Dnnn.json`) and run-scoped `<stamp>/reads.jsonl` + `run.json`;
`runs prune`. **Populated by ported copies of the existing scanners** so
outputs are unchanged while the plumbing lands. Ported presentation and IO
(survey dispositions "PORT"): `parseArgs` (whitelisted, F4), work-dir
resolution + refusal guard, inventory/ledger IO, all verb formatters, HELP.

- **Gates:** 3, 13, 14, 16 (goldens still byte-identical), suite §hygiene
  re-pointed at the new layout **without weakening** (dot-skip, refusal,
  LATEST, `-2` suffix, precedence all still asserted).
- **Depends on:** M0, M1. **Brief:** §2 (table, stores, hygiene), F4.

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

- **Gates:** 4, 5, 6, 7, 9, 12; 16 with the F1/F2 golden deltas explicitly
  inverted and named; suite additions for fenced noise, non-`---` breaks,
  multi-line comment, flag order.
- **Depends on:** M2. **Brief:** §3, F1–F3, cosmetic fixes.
- **Exit = Chip A done.** Report appended to the brief.

## M4 — Containment, relations, profiles, generic basis, `--only` · `planned`

Re-entry walk (region-specific rules, `container` column, nearest
container); `--enter <kinds>` as the third activation knob (ids unchanged;
`outline` prints `contains:` on undescended regions); relations
(`footnote`, `link-ref`, `anchor` with GFM slug dedupe, `contains`) with
residue; `Selection` + suppression; profiles as JSON (`default` reproduces
today; `chat-export`); `read --only`; generic `--by <kind|pattern:>` with
`S`/`R` addressing and per-basis partition invariant; `marks --resolve`,
`read --only footnote-def --for`; `profile` verb as full census + residue.

- **Gates:** 8, 10, 10b, 11; partition invariant re-asserted per (basis,
  depth, enter).
- **Depends on:** M3. **Brief:** §2b, §4, §5 (basis, read, marks, profile).

## M5 — Exports, REPL contract, framing · `planned`

`isMain` guard (win32-safe) + named exports (`Corpus`, `Doc`, `SpanSet`,
`Selection`, `loadRules`, `loadProfile`, `materialize`, `Ledger`); paged +
counted queries (`limit/offset/columns` → `{total, rows}`), memoization by
`(digest, policy, args)`; budgeted `materialize` returning a **plan** over
`maxBytes`; CLI `--max-bytes`, `--limit/--offset`; framing as a projection
over the piece list — `--frame comment` (default CLI, byte-identical to
today) | `pilcrow` | `none`, header field order fixed, addressable
placeholders, `len`/`span` distinct; `notes[]` out of band.

- **Gates:** 15, 17, 18, 19, 20, 21, 21b (byte accounting: headers count
  toward `maxBytes`; `§`/`¶` are 2 UTF-8 bytes; all framer arithmetic is
  `Buffer.byteLength`, and the test asserts header bytes == chars + 1).
- **Depends on:** M4. **Brief:** §Front-end grammar, §REPL contract,
  §Stream framing, §Export surface.
- **Exit = Chip B done.** Report appended.

## M6 — Fresh-context review · `planned`

A reviewer that has not seen the build: given the brief, the survey, and
both reports; tries to break every gate; dogfoods v2 on the
`issues/mdnav_v2/discussion/` corpus and one large real transcript; checks
README/HELP against behavior (F3 closed for real). Findings appended as a
dated review under `discussion/`.

## After — `server.mjs` brief (separate)

Tool names over the export surface; session/result store (`$rN` handles);
freezing the `§`/`¶` header spec with para-agent; default MCP budget chosen
from measured reads; the framed-vs-unframed behavioral gate; embeddable
`createMdnavTools` + stdio runner; vendoring into para-agent.

## After — token-cost measurement battery (separate, shared with para-agent)

**What:** a model-agnostic, empirical measurement of **token cost per
symbol and per pattern**, in lieu of a standalone tokenizer (not always
available for a given model), captured as **client/model-specific profiles**
that are reused and refreshed when models change.

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
`locate --in/--not-in`. Pairing for named tag sets under a profile
(primitive exists after M3; no profile turns it on yet). Any second
segmentation policy beyond first-viable-boundary. Anything Allen /
path-selection / facts / origins from doccer.
