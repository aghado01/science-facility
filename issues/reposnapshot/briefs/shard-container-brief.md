# Shard container — header row, record rows, and the grammar that keeps them coherent — brief

**Status:** **landed 2026-08-17; realigned 2026-08-22** —
`reposnapshot-v3/rs.core.container.psm1` (`Resolve-Layout` ·
`Measure-ContentSpan`/`ConvertTo-ContentSpan` · `Format-Row` →
`Measure-Row`/`Build-Row` · header-row pair), `tests/container.tests.ps1`
(78 asserts: plan = file by construction, codec SPEC rules 1–4 with
measure == encode across a surrogate/terminator/control battery, offsets with
inclusive ends and the seek round-trip, empty markers, width overflow, and the
value walk of every declared accessor against a real `rs-content_meta` entry)
plus `tests/container-spec.tests.ps1` (34 asserts: the declaration executed —
every `$ref` walked, and rows rendered through the spec's templates validated
against the spec's own patterns in all four on/off configurations).

The 2026-08-22 realignment is what this brief is being reconciled against: the
declaration was restructured and renamed (`schema/psr.header.json` →
`contracts/container.spec.jsonc`), the module became its **interpreter** rather
than a reader of hardcoded shape, and **the wire changed** — see §The item
model. Where this document said `gidx<int:N>` it now says `gidx: int(4)`.
Open calls below still stand where marked. · **Filed:** 2026-08-15, merging
`schema-derivation-brief.md` (2026-08-15) and `row-grammar-brief.md`
(2026-08-15), both archived under `briefs/.archive/` · **Track:** V3 e2e
sprint, export phase (`rs.core.shards` → `rs.core.serialize` →
`rs.core.manifest`) · **Spec:** `design/shard-format-notes.md` **§Content codec
— SPEC only** (posture + the four rules). That document's §Row grammar is an
**LTS specimen**, not v3's wire — v3's is `contracts/container.spec.jsonc` and
§The item model below. · **Sources:** LTS emission spans (`RepoSnapshotLts.psm1` ~2277–2520,
`Get-EntryByteOffsets:953`), the conceptual decomposition in
`discussion/opus-reposnapshotV3-LTS-updates.md`, `payload-manifest-ledger.md`.

## Vocabulary (settled here; "schema" and "row grammar" retired from the payload side)

The container is a hybrid of **CSV** (a header row names the columns; records
are positional), **JSONL** (one record per line, self-documenting store — each
row casts an implicit schema-shadow, but the container spec is its own), and
**LPAC**-style **length-prefix framing** (content spans are addressed by byte
offset, no quoting engine). Informally it shares DNA with **columnar SQL
tables** too: a declared column set, typed, and rows that conform.

- **header row** — the first record of a shard; declares the columns (name,
  type) every record row in that shard carries. In-band, so the shard is
  self-documenting: *readers parse exactly what the header declares, never a
  fixed column set* (shard-format-notes §Configurability).
- **record row** — one entry rendered per the header row: positional values,
  framed; the content span addressed by recorded offsets.
- **framing** — the length prefix + structural marks that let a reader seek to a
  content span without parsing the row. Note the marks are **items**, not
  delimiters carrying their own spacing (§The item model).
- **item** — the unit a row is built from: a value, a key (carrying its trailing
  colon), or a structural mark. A row is its item list joined by one space.
- *"schema"* now means **stage I/O contract** (`reposnapshot-v3/contracts/`), not
  the payload's column set. *"Row grammar"* is retired — the header row **is**
  the grammar; rows are rendered from it.

## The problem this closes — coordination

**Which fields a record row carries is configurable in principle** — the open
element model attaches whatever the chain produced (`ContentMeta` — né `Attributes`,
`Processing`, `Encoding`, novel enrichments); emission is a writer knob
(compute-by-default, `rs-content_meta` (né rs-attributes) split). So header row and record rows
must be generated from **one declaration**, or they drift. LTS solved this
in an ugly way and it is the reason a verbatim port is refused (ledger #5):

- Two literal header strings selected by a boolean (`:2277–2281`) — "header
  and rows agree" maintained by discipline, contradicting the format's own
  doctrine.
- The row grammar written **three times** as independent format strings
  (`:2318` flat render · `:2461` grouped re-render · `:2501` meta prefix
  re-render to *measure* where content starts) — six variants counting the
  `includeAttributes` branches; must agree byte-for-byte or published offsets
  address the wrong bytes, and **nothing checks**.
- **Offsets recovered, not recorded** — `Get-EntryByteOffsets` regex-matches
  `"content":"…"` out of already-serialized JSON; the writer knew and threw it
  away.
- **Two grouping strategies are two programs** — Flat buffers everything and
  `BlockCopy`s slices; grouped opens a stream per shard and re-renders. Same
  output, two implementations, two offset formulas.
- **Buffer-everything** — a 4 MB `StringBuilder` for the corpus, then a second
  full copy as bytes; caps corpus size for the virtual-DB use.

## Shape

**One declaration, two products, one renderer.**

1. **Header derivation** — from the IR (`assemble.out`): *core columns always
   (`RelativePath`, `NodePath`, `LastWriteUtc`, `Content`) · observed elements
   conditionally.* `Header.Elements` (per-element `Count/Total`) is the input
   and already exists; nothing consumes it yet. The header object is computed
   **once** and consumed by two sinks — the shard's header row (serialize) and
   the tree manifest's `ColumnHeader` (manifest). Computing it twice
   reintroduces the drift class above.
2. **Record rendering** — one function owns the layout and returns bytes *and*
   positions together, because **positions are a receipt of the write, not a
   measurement of the artifact**:
   ```
   Build-Row  entry, header, cursor
               → @{ Bytes; RowOffset; RowMetaEnd; RowContentBegin; RowContentEnd; NextCursor }
   ```
   `cursor` is the byte position the row will occupy in its shard, so returned
   offsets are shard-local and nothing recomputes them. Offsets keep the LTS
   semantics (correct, and the published contract): `row_offset` start of row ·
   `row_meta_end` last byte before the content delimiter · `row_content_begin`
   · `row_content_end` (== begin when empty).
   The layout is a **dependency of two stages**, so it lives in its own small
   module — `rs.core.container` — as `Format-Row → items`, from which
   `Measure-Row` (shards, sums lengths) and `Build-Row` (serialize, writes)
   derive; likewise `Measure-ContentSpan` / `ConvertTo-ContentSpan` over the one codec
   rule table (count without allocating vs materialize), and the header-row
   pair. One grammar site, three callers; plan and file cannot disagree.
   `Format-Row` returns items through `content_bytes` — the mark before
   `content` and the span itself are `Build-Row`'s — so `items -join item_join`
   is exactly the prefix whose last byte is `row_meta_end`.
3. **Grouping decides membership, not how bytes are written.** One emission
   path consumes a shard's row list regardless of how `rs.core.shards` grouped
   it (Flat / ByFileType / …). The Flat-vs-grouped divergence disappears rather
   than being unified.

## The header row is the declaration — why there is no row schema (2026-08-16)

The container spec is named **psr** (*piped snapshot rows*); the file
extension stays `.txt` as a reader accommodation (tool allowlists,
preview/truncation windows), not a format marker. Its admissible column set is
declared once, in `reposnapshot-v3/contracts/container.spec.jsonc` — **read by
code** (`rs.core.container` resolves the run's layout from it; ledger #6), and
deliberately not a `*.contract.json` (those are stage contracts, ledger #33/#34
— renamed from `*.schema.json` 2026-08-16 so "schema" stops doing double duty).
It sits *among* them because it points *into* them: each column binds its value
by a `$ref` into the contract that owns it, and `contracts.tests` is told to
skip it precisely because it is a declaration, not a stage.

Wire order and roles — the header row at the default configuration, verbatim:

```
gidx: int(4) | path: string | content_meta: [ line_mean: double , num_chars: int , num_words: int , ws_ratio: double , entropy: double ] | content_bytes: int | content: string
   record         record                              content (extensible block)                                                            content            content
```

and the record row beneath it, same positions, values only:

```
0042 | src/Foo.cs | [ 9.5000 , 30 , 5 , 0.4037 , 4.2516 ] | 30 | line one\nline two\n<TAB>tabbed é
```

- Required: `path`, `content_bytes`, `content`. Optional: `gidx` (one address
  scheme among several; open), `content_meta` (renamed from LTS `attributes` —
  a noun, and prefixed `content_` because it is metadata *about the content
  span*, pairing it with `content_bytes` and `content`; sub-fields are run
  configuration and extensible by processors, ordered by `val_rank`, with the
  default set marked `default: true`).
- `content_bytes` is the exact byte width of the encoded content span in the
  file — the number a reader seeks with. Not `SizeBytes`, not `num_chars`. It
  immediately precedes `content`; that adjacency is the seek contract. The
  *row* span (whole physical line) is not a column.
- **`gidx` is zero-padded to `digits(EntryCount)`**, resolved once per run —
  the only padded field, because it is the only one assigned *after* packing
  (#46). Zero, never space: a space-padded value would put whitespace inside an
  item, at exactly the level where the join is doing structural work. Overflow
  is a plan-time throw, never a silent widen. `content_bytes` is unpadded and
  canonical (no leading zeros) — it is known before packing, so nothing needs
  bounding.
- LF terminator, no trailing mark; UTF-8, no BOM (ledger #45, **settled**
  2026-08-22 — with marks as items there is no trailing-mark item to drop, and
  `container.tests` asserts both).

## The item model — how a row is built (ledger #49, 2026-08-22)

**A row is a list of ITEMS joined by exactly one space.** Items are values, keys
(a key carries its trailing colon), and the structural marks `|` `[` `]` `,`.
A sub-grammar with its own internal syntax — a type expression `int(4)`, the
encoded content span — renders itself **first** and enters as **one** item; its
internal spacing is its own business.

Three consequences the rest of the export phase leans on:

1. **The writer's arithmetic is exact by construction**: `row bytes = Σ item
   bytes + (item count − 1) + record_delimiter`. Nothing is hidden inside a
   concatenation — under the old shape a block's internal delimiters were buried
   in one pre-assembled piece and had to be re-measured.
2. **There is no padding property and must not be one.** Padding is what the
   join does. The declaration carries the separator as a *character* (so it can
   interpolate into a regex character class) and the join separately; a
   `" | "` string would break both at once.
3. **Lexing is structural, never a whitespace split.** Items may contain spaces
   — `content` does by construction, and `path` did in 23.5% of a real corpus
   (chat-export fixtures with sentence-fragment filenames). A reader splits on
   `" | "`, then `" , "` inside a block.

The choice was made on declaration and interpreter simplicity, not economy:
measured on a real 4.6 MB payload the spacing costs **+0.046%** tokens against
a fully tight `|`, and removes the one real boundary artifact — under tight
`|` the token `]|` merged the block close with the column separator in
**102/102** rows.

**An empty value is a zero-length item**, which the join surfaces as a doubled
space rather than as nothing (`… |  | …`). That is an improvement over a tight
separator, where the same defect would have hidden as an unremarkable `||`.
psr never emits one by design; a reader that meets one should read it as a
defect signal, not data.

**The header row's declaration determines the datatypes of every field in
every record row, so a record row has no schema of its own.** A row is the
resolved header projected onto one entry: for each column in order, take the
source, render per type and width, join, terminate. The header names and types
the value; the row carries the value. `Measure-Row` and `Build-Row` iterate
the *same* resolved column list from the *same* layout object, so header and
rows cannot disagree on count, order, or type — by construction, not by check.
A separate row schema would be a second artifact that must agree with the
first: exactly the LTS drift class (row grammar written three times, nothing
checks). Ledger #34 (the header row *is* the grammar), #46 (header is the
superset, the row its shadow).

**One header per run, byte-identical in every shard** — settled in the packing
thread (shards-brief; ledger #46), and what the LTS artifacts already do. This
supersedes the per-shard-header leaning below: partial presence resolves per
*row* with the empty marker, never per shard.

## The crux — partial presence (per-shard header option SUPERSEDED 2026-08-16 — see section above)

The format is positional (values only, no keys per row), so every record row
in a shard must carry the same column count. An element present on only some
entries forces a choice:

- (a) column with an empty marker for rows lacking it — costs a delimiter per
  row per absent element and needs an unambiguous empty representation;
- (b) excluded unless universally present — simple, silently drops real data;
- (c) **per-shard header** — the header is declared once per shard already;
  nothing requires two shards to agree.

**(c) was the leaning — superseded 2026-08-16 by one header per run; (a) with
the empty marker is what `container.spec.jsonc` declares.** Retained as record: under
`ByFileType` a shard is homogeneous by construction, so a language-specific
element is present on every row or none, and the header states which —
honestly, per shard. Corpus-wide 30% coverage becomes 100% in three shards and
0% elsewhere. It also sharpens roles: `Header.Elements` is corpus-level
coverage *diagnostics*; each shard's header row is the local truth its rows
must match.

## Also to settle

- **Which elements become columns at all.** Not everything on a bag is row
  material — `Processing` is a receipt; `Encoding` is a run-level constant
  riding on every entry (ledger #28, encoding-lookback). Likely a disposition
  per element — and it must not become a per-element branch in the writer, or
  the open element model is defeated. Cleanest: the disposition is *declared
  by the producing processor* alongside its element.
- **Column order** — deterministic, or payloads differ run to run for no
  reason. `Elements` is first-observed order: stable given stable ingest order,
  but an accident, not a guarantee.
- **Type annotations** (`gidx: int(4)`, `path: string`, `ws_ratio: double`) —
  **answered in shape 2026-08-22, not fully closed.** Neither LTS's hardcoding
  nor derivation-from-values (fragile: an all-integer double column reads
  `int`). The type is declared once in `container.spec.jsonc` as `record_type` /
  `val_type` — wire-facing, one place — while the *value* binds by `$ref` into
  the contract of whatever produced it, and a dangling pointer **fails at
  load**. So the container spec cannot name a value the producer does not
  declare, without the processor having to know the wire exists. What remains
  open is the disposition question above: nothing yet lets a processor say
  *whether* its element should become a column at all.
- **Nested blocks** — `content_meta: [ … ]` is positional-values-in-brackets and
  the recursion rule is now stated: a cell renders itself atomically, and the
  block is the **one** cell that is itself an item list. Depth stays at one
  deliberately; arbitrary nesting would need a rule and a limit, and no consumer
  wants it.
- **Wire naming** — in-memory PascalCase by doctrine; snake_case in the payload.
  The mapping is no longer prose: it is the `$ref` crosswalk (`num_chars` →
  `…/out/ContentMeta/CharCount`), one concept in three casings by convention
  (wire `content_meta` · in-memory `ContentMeta` · processor `rs-content_meta`).

## What must NOT come across from LTS

- The `ConvertTo-Json` content hop (`:2313` — serialize then strip quotes,
  JSON as an escaping engine; source of the `\"` residue at 12% of escapes).
  The codec is specified and authored directly (shard-format-notes §"Content
  codec — SPEC").
- Sorting at serialization (`:2298`) — IR order is canonical ingested order;
  arrangement is `rs.core.shards`'.
- Disk-JSON input — the input is the in-memory IR.
- Hardcoded provenance in the manifest (`module` was hardcoded — and wrong).
  Provenance comes from RunContext / ConfigEcho.
- `Write-Host` progress and emoji; hardcoded throw text.

## Seam with sharding policy (`rs.core.shards`)

Adjacent, coordinated, separable. **Shards** decides allocation (Size budgets —
naming grade: `Size` bounds a container, `Span` measures content), grouping,
sorting/subsorting, global idx, membership per shard — consuming numerics
(`Get-PathHash` for Flat ordering, ledger #4). **The container** decides bytes:
given a shard's ordered entry list and the derived header, render header row +
record rows, recording offsets. Interface: shards → serialize hands over
`@{ ShardKey; Entries[]; … }`; serialize hands manifest `@{ Header; Rows[] with
offsets; ByteLength }`. Neither reaches into the other's decision.

**Two questions, two truths, no feedback loop** (user, 2026-08-15; ledger
#26/#27; AGENTS "planning is not measurement"):

- *Which entries go in which shard* is a **planning** question. Its inputs are
  in memory after ingestion, and — revised the same day (ledger #39) — the
  plan is **exact, computed forward**: `Measure-Row(entry, header, idxWidth)`
  from the layout module gives a row's serialized size as a pure function
  (`spanBytes = utf8(codec(Content))`, counted without allocating; fixed-width
  idx). Policy is grouping, overflow, anti-fragmentation, target size per shard
  file. Planning **never reads written bytes**; a shard file's length equals
  its `PlannedSizeBytes` by construction (`shards-brief` exit gate).
- *Where each row's bytes landed* is a **measurement** question, and only the
  writer knows. Serialize records offsets as a receipt of the write; manifest
  reads them. That is why manifest follows serialize, and why nothing
  "recovers" positions — and why no offset is ever derived from `Measure-Row`.

The knot this cuts: `rs-content_meta` (né rs-attributes) was once asked to serve the first question
with a number deliberately invariant to emission settings — wrong tool, wrong
direction (#26). Now neither stage measures for the other: both call the same
`rs.core.container` layout function — shards to sum, serialize to write.
Serialize never reports back to shards. If a future policy wants post-write
rebalancing, that is a new stage after serialize, not a loop.

## Exit gate

Marked against the battery at **17 suites · 1049 passed · 0 failed** (2026-08-22).

- ✅ **The seek contract round-trips, byte-exact**: for every emitted row, reading
  the shard file at `row_content_begin..row_content_end` returns exactly the
  encoded content span, and the row's declared length equals its UTF-8 byte
  count. The one property an eyeball review cannot verify — asserted on the
  bytes themselves, not on the offsets.
- ✅ **One layout site, provable by construction** — only one function can produce
  a record row; header row and every record row agree on column count, asserted
  not assumed. Strengthened 2026-08-22: `Measure-Row == Build-Row.Bytes.Length`
  is checked, *and* the `#49` byte identity is asserted independently of the
  implementation that computes it.
- ✅ **Column order stable across repeated runs on identical input** — now
  ordered by the declaration's `col_position` rather than by key enumeration.
  The old code sorted by `$decl.columns.Keys`, which PowerShell does not
  guarantee for a hashtable; the ordering was correct by luck.
- ⬜ Header derived from a real IR reproduces the LTS column set for the
  equivalent configuration (derivation is not merely *different*). **Not built**
  — needs an LTS-side fixture, and the wire has since diverged deliberately, so
  the comparison is now column *set*, never column *text*.
- ⬜ A bag carrying a **novel** element reaches the payload as a column with zero
  writer changes — the open-element-model claim, still never tested e2e. Cheaper
  now than when written: the test is a new sub-field in the spec + its `$ref`,
  and nothing in the module should move.
- ⬜ Flat and grouped membership produce identical bytes for identical
  membership. Blocked on `rs.core.shards`, by construction.
- ✅ Full battery green **and error stream clean**.

## Non-goals

- Packing / grouping / ordering / global idx — `rs.core.shards`.
- Rendering the tree manifest — consumes the header object and the offsets;
  separate work in `rs.core.manifest`.
- Deciding `Encoding`'s home (ledger #28) — flagged, not owned.
- The JSONL writer for the thread-corpus track — its header comes free from
  its own serialization.

## Open calls

- Streaming vs per-shard buffering — **open**. The cursor shape makes streaming
  possible; per-shard buffering already beats LTS's whole-corpus double copy.
  `Build-Row` touches no stream, so the call stays `rs.core.serialize`'s.
- Empty-content rows — **open**. LTS emits `row_content_end == row_content_begin`
  for a zero-length span, and the branch is ported and asserted. Under
  LeanPayload empty content never becomes an entry; confirm the case is
  unreachable and drop the branch rather than keep dead semantics alive by test.
- ~~Where the layout lives~~ — **settled**: `rs.core.container`, a dependency of
  shards and serialize, with `rs.core.serialize` owning the emission loop over a
  plan. The manifest split is a cut: nothing in the layout module knows a
  manifest exists.
- ~~Sequencing~~ — **done** as planned: the layout object's shape was frozen,
  the renderer built against it, the derivation landed. The realignment then
  proved the sequencing was right — the wire changed underneath and only the
  renderer and its suite moved.
