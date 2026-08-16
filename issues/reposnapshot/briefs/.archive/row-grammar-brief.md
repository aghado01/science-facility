# Row grammar expressed once — brief

**Status:** filed, not started · **Filed:** 2026-08-15 · **Track:** V3 e2e sprint,
emission stage. Companion: `schema-derivation-brief.md` (supplies this step's
input). Background: the conceptual decomposition in
`discussion/opus-reposnapshotV3-LTS-updates.md` and the LTS spans it maps.

## The defect this closes

LTS writes the row grammar **three times**, as three independent format strings:

| site | purpose |
|---|---|
| `RepoSnapshotLts.psm1:2318` | render into the flat buffer |
| `:2461` | re-render for the grouped write path |
| `:2501` | re-render the meta prefix, to measure where content starts |

Six variants counting the `includeAttributes` branches. They must agree
byte-for-byte or the published offsets address the wrong bytes — and **nothing
checks**. The format's grammar is not expressed in one place anywhere in the
codebase; it is held together by copy-paste discipline across 180 lines.

Three further symptoms share one root cause, which is why they belong in one
piece of work rather than three:

- **Offsets are recovered, not recorded.** `Get-EntryByteOffsets:953` regex-matches
  `"content":"…"` out of already-serialized JSON to find where content sits — the
  writer knew and threw it away. The `.txt` path is the same instinct in gentler
  form: it re-renders the meta prefix and re-counts its bytes *after* writing the
  line.
- **Two grouping strategies are two programs.** Flat buffers everything, cuts on
  byte-cursor positions, `BlockCopy`s slices, and derives offsets as
  `shardHeaderBytes + (row.ByteStart - cutStart)`. Grouped opens a `FileStream`
  per shard, re-renders every row, and tracks a running `$currentOffset`. Same
  output format, two implementations, two offset formulas.
- **Buffer-everything.** A 4 MB `StringBuilder` holding the whole corpus, then
  `$enc.GetBytes($sb.ToString())` materializing a second full copy as bytes. Both
  live at once alongside the entries. This is what caps corpus size for the
  virtual-DB use case.

## The inversion

> **Positions are a receipt of the write, not a measurement of the artifact.**

Everything above follows from getting that backwards. A writer that emits a
positioned artifact is the only thing that knows the positions; having it return
them deletes `Get-EntryByteOffsets`, deletes the third render, and makes
streaming possible — because a running cursor is all a stream needs.

## Shape

One renderer owns the grammar and returns bytes *and* positions together:

```
Render-Row  entry, schema, cursor
            → @{ Bytes; RowOffset; RowMetaEnd; RowContentBegin; RowContentEnd; NextCursor }
```

`schema` comes from the companion brief. `cursor` is the byte position the row
will occupy in its shard, so the returned offsets are already shard-local and
nothing recomputes them downstream.

**Grouping decides membership, not how bytes are written.** One emission path
consumes a shard's row list regardless of how the rows were grouped. The Flat/
grouped divergence disappears rather than being unified.

Offsets keep the LTS semantics, which are correct and are the published contract:

```
row_offset         start of the row within the shard file
row_meta_end       last byte before the content field's delimiter (inclusive)
row_content_begin  first byte of the content span
row_content_end    last byte of the content span; == begin when the span is empty
```

## What must NOT come across

Enumerated because a verbatim port carries them silently:

- **The `ConvertTo-Json` content hop** (`:2313`, `$cj.Substring(1, $cj.Length - 2)` —
  serialize the string, then strip the surrounding quotes, using JSON as an
  escaping engine). The codec is specified and authored directly now
  (`shard-format-notes.md` §"Content codec — SPEC"): four rules, no JSON behind
  it. This hop is also the source of the `\"` residue measured at 12% of all
  escapes in a production payload.
- **Sorting at serialization** (`:2298`). IR order is canonical ingested order;
  arrangement belongs to `rs.core.shards`.
- **Disk-JSON input.** The input is the in-memory IR, not a monolith on disk.
- **Hardcoded provenance in the manifest.** The `module` field was hardcoded — and
  wrong. Provenance is supplied by the run (RunContext / ConfigEcho), not asserted
  by the writer.
- **`Write-Host` progress and emoji.**
- **Hardcoded throw text.** Errors throw idiomatically, with a real error record.

## Exit gate

**The seek contract round-trips, byte-exact.** For every emitted row, reading the
shard file's bytes at `row_content_begin..row_content_end` returns exactly the
encoded content span, and the row's declared `length` equals that span's UTF-8
byte count. This is the contract the whole format exists to keep and the one an
eyeball review cannot verify.

Plus: one grammar site provable by construction (there is only one function that
can produce a row); Flat and grouped produce identical bytes for identical
membership; full battery green **and error stream clean**.

## Non-goals

- The schema's *content* — companion brief.
- Packing, grouping, ordering, global idx — `rs.core.shards`.
- The tree manifest — it consumes the offsets this produces, but rendering it is
  separate work.
- The JSONL writer — thread-corpus track.

## Open calls

- **Streaming or per-shard buffering.** The cursor-returns-positions shape makes
  streaming possible; whether to take it now is a separate call. Per-shard
  buffering is a middle position that already beats LTS's whole-corpus double
  copy.
- **Where the renderer lives.** Staged into `rs.core.manifest` per the
  consolidate-then-divide decision; lay the file out so the eventual `serialize`
  split is a cut, not an untangle.
- **Empty-content rows.** LTS emits `row_content_end == row_content_begin` for a
  zero-length span, distinct from null. Under lean-payload routing empty content
  never becomes an entry at all — so confirm whether the zero-length case is now
  unreachable, and if so, drop the branch rather than porting dead semantics.
