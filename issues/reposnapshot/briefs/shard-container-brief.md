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
(compute-by-default, `rs-attributes` split). So header row and record rows
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
3. **Grouping decides membership, not how bytes are written.** One emission
   path consumes a shard's row list regardless of how `rs.core.shards` grouped
   it (Flat / ByFileType / …). The Flat-vs-grouped divergence disappears rather
   than being unified.

## The crux — partial presence

The format is positional (values only, no keys per row), so every record row
in a shard must carry the same column count. An element present on only some
entries forces a choice:

- (a) column with an empty marker for rows lacking it — costs a delimiter per
  row per absent element and needs an unambiguous empty representation;
- (b) excluded unless universally present — simple, silently drops real data;
- (c) **per-shard header** — the header is declared once per shard already;
  nothing requires two shards to agree.

**(c) is the leaning.** It composes with grouping instead of fighting it: under
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
- Where the renderer lives — `rs.core.serialize` (0 bytes today). Lay it out so
  the manifest split is a cut, not an untangle.
- Empty-content rows — LTS emits `row_content_end == row_content_begin` for a
  zero-length span. Under LeanPayload empty content never becomes an entry;
  confirm the case is unreachable and drop the branch rather than port dead
  semantics.
- Sequencing — freeze the header object's shape → build the renderer against a
  fixed instance → land the derivation. Keeps the two halves independently
  landable.
