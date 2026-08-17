# Shard container — header row, record rows, and the grammar that keeps them coherent — brief

**Status:** filed, not started · **Filed:** 2026-08-15, merging
`schema-derivation-brief.md` (2026-08-15) and `row-grammar-brief.md`
(2026-08-15), both archived under `briefs/.archive/` · **Track:** V3 e2e
sprint, export phase (`rs.core.shards` → `rs.core.serialize` →
`rs.core.manifest`) · **Spec:** `design/shard-format-notes.md` (codec, framing,
posture) · **Sources:** LTS emission spans (`RepoSnapshotLts.psm1` ~2277–2520,
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
- **framing** — the length prefix + delimiters that let a reader seek to a
  content span without parsing the row.
- *"schema"* now means **stage I/O contract** (`reposnapshot-v3/schema/`), not
  the payload's column set. *"Row grammar"* is retired — the header row **is**
  the grammar; rows are rendered from it.

## The problem this closes — coordination

**Which fields a record row carries is configurable in principle** — the open
element model attaches whatever the chain produced (`Attributes`,
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
   Render-Row  entry, header, cursor
               → @{ Bytes; RowOffset; RowMetaEnd; RowContentBegin; RowContentEnd; NextCursor }
   ```
   `cursor` is the byte position the row will occupy in its shard, so returned
   offsets are shard-local and nothing recomputes them. Offsets keep the LTS
   semantics (correct, and the published contract): `row_offset` start of row ·
   `row_meta_end` last byte before the content delimiter · `row_content_begin`
   · `row_content_end` (== begin when empty).
   The layout is a **dependency of two stages**, so it lives in its own small
   module — `rs.core.container` — as `Format-Row → pieces`, from which
   `Measure-Row` (shards, sums lengths) and `Render-Row` (serialize, writes)
   derive; likewise `Measure-Content` / `Encode-Content` over the one codec
   rule table (count without allocating vs materialize), and the header-row
   pair. One grammar site, three callers; plan and file cannot disagree.
3. **Grouping decides membership, not how bytes are written.** One emission
   path consumes a shard's row list regardless of how `rs.core.shards` grouped
   it (Flat / ByFileType / …). The Flat-vs-grouped divergence disappears rather
   than being unified.

## The header row is the declaration — why there is no row schema (2026-08-16)

The container spec is named **psr** (*piped snapshot rows*); the file
extension stays `.txt` as a reader accommodation (tool allowlists,
preview/truncation windows), not a format marker. Its admissible column set is
declared once, in `reposnapshot-v3/schema/psr.header.json` — **read by code**
(`rs.core.container` resolves the run's layout from it; ledger #6), and
deliberately not `*.contract.json` (stage contracts, ledger #33/#34 — renamed
from `*.schema.json` 2026-08-16 so "schema" stops doing double duty).

Wire order and roles:

```
gidx<int:N> | path<str> | content_meta:{chars<int> words<int> ws_ratio<float> entropy<float>} | content_bytes<int> | content<str>
   record       record            content (extensible block)                                content          content
```

- Required: `path`, `content_bytes`, `content`. Optional: `gidx` (one address
  scheme among several; open), `content_meta` (renamed from LTS `attributes` —
  a noun, and prefixed `content_` because it is metadata *about the content
  span*, pairing it with `content_bytes` and `content`; sub-fields are run
  configuration and extensible by processors).
- `content_bytes` is the exact byte width of the encoded content span in the
  file — the number a reader seeks with. Not `SizeBytes`, not `chars`. It
  immediately precedes `content`; that adjacency is the seek contract. The
  *row* span (whole physical line) is not a column.
- LF terminator, no trailing `|`; UTF-8, no BOM (ledger #45).

**The header row's declaration determines the datatypes of every field in
every record row, so a record row has no schema of its own.** A row is the
resolved header projected onto one entry: for each column in order, take the
source, render per type and width, join, terminate. The header names and types
the value; the row carries the value. `Measure-Row` and `Render-Row` iterate
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
the empty marker is what `psr.header.json` declares.** Retained as record: under
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
- **Type annotations** (`idx<int>`, `path<str>`, `whitespace_ratio<float>`) —
  LTS hardcodes them. Derived from values is fragile (an all-integer float
  column reads `<int>`); declared by the producing processor is honest and
  implies processors describe their own elements (same mechanism as the
  disposition above).
- **Nested blocks** — `attributes:{…}` is positional-values-in-braces;
  generalizing to arbitrary nesting needs a rule and probably a depth limit.
- **Wire naming** — in-memory PascalCase by doctrine; snake_case in the payload
  is a writer rendering decision. The mapping lives here.
- **Header per shard vs per run** — (c) above implies per shard; confirm the
  manifest's `ColumnHeader` is then per-shard too, or a union with per-shard
  detail.

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

- **The seek contract round-trips, byte-exact**: for every emitted row, reading
  the shard file at `row_content_begin..row_content_end` returns exactly the
  encoded content span, and the row's declared length equals its UTF-8 byte
  count. The one property an eyeball review cannot verify.
- **One layout site, provable by construction** — only one function can produce
  a record row; header row and every record row in a shard agree on column
  count, asserted not assumed.
- Header derived from a real IR reproduces the LTS column set for the
  equivalent configuration (derivation is not merely *different*).
- A bag carrying a **novel** element reaches the payload as a column with zero
  writer changes — the open-element-model claim, never tested e2e.
- Column order stable across repeated runs on identical input.
- Flat and grouped membership produce identical bytes for identical membership.
- Full battery green **and error stream clean**.

## Non-goals

- Packing / grouping / ordering / global idx — `rs.core.shards`.
- Rendering the tree manifest — consumes the header object and the offsets;
  separate work in `rs.core.manifest`.
- Deciding `Encoding`'s home (ledger #28) — flagged, not owned.
- The JSONL writer for the thread-corpus track — its header comes free from
  its own serialization.

## Open calls

- Streaming vs per-shard buffering — the cursor shape makes streaming
  possible; per-shard buffering already beats LTS's whole-corpus double copy.
- Where the layout lives — leaning `rs.core.container` (a dependency of shards
  and serialize), with `rs.core.serialize` (0 bytes today) owning the emission
  loop over a plan. Lay it out so the manifest split is a cut, not an untangle.
- Empty-content rows — LTS emits `row_content_end == row_content_begin` for a
  zero-length span. Under LeanPayload empty content never becomes an entry;
  confirm the case is unreachable and drop the branch rather than port dead
  semantics.
- Sequencing — freeze the header object's shape → build the renderer against a
  fixed instance → land the derivation. Keeps the two halves independently
  landable.
