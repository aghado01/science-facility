# `rs.core.shards` — from the IR to a shard plan — brief

**Status:** filed, not started · **Filed:** 2026-08-15 · **Track:** V3 e2e
sprint, export phase 1 (assemble → **shards** → serialize → manifest) ·
**Archaeology:** `design/gemini-shard-recon.md` (LTS knob roster, pathology
table, five-phase algorithm — adopted here with the corrections in §"What the
recon got that this brief changes") · **Companion:** `shard-container-brief.md`
(the container: header row, record rows, framing; the layout module this stage
depends on) · **Doctrine touched:** AGENTS "planning is not measurement"
narrowed; ledger #26 stands; new #39.

## What this stage is

A **pure planning stage**: takes the IR (`assemble.out`) and decides
*membership, arrangement, and global indexing* — which entries go in which shard
file, in what order, under which knobs — and returns a plan. Zero I/O, zero
writing, zero offset arithmetic. Serialize consumes the plan; manifest consumes
serialize's receipt. Nothing flows backwards (shard-container-brief §Seam).

Module: `rs.core.shards.psm1`, entry point `New-ShardPlan`. Dependencies:
`rs.core.numerics` (`Get-PathHash`, ledger #4) and the container layout module
(`rs.core.container`, below) for `Measure-Row`.

## Planning is exact — how the measurement works

Every byte of a shard file is under our control and every input is in memory
at plan time, so a row's serialized size is a **pure function**, not an estimate:

```
row = idx_str · D · path · D · [attr_block · D] · length_str · D · content_span · T · NL

Measure-Row(entry, header, idxWidth) =
    idxWidth + |D| + utf8(path) + |D| + [utf8(attr_block) + |D|]
  + digits(spanBytes) + |D| + spanBytes + |T| + |NL|
  where spanBytes = utf8(codec(Content))
```

- `idx_str` at a **fixed width** = digits(`EntryCount`), zero-padded — kills the
  only circularity (idx is assigned after packing; its width is known before).
- `attr_block` present iff the derived header declares the column; floats via
  one deterministic formatter (layout's decision).
- `content_span = codec(Content)` — the container codec (shard-format-notes
  §SPEC) over the processed content already in memory. `spanBytes` is computed
  **without allocating**: `Measure-Content` = `UTF8.GetByteCount(Content)` +
  line-break inflation − stripped controls, a counting fold over the same rule
  table `Encode-Content` materializes with. Two functions, one table, cannot
  disagree.
- Shard file size = `Measure-HeaderRow(header)` + Σ `Measure-Row(...)`.

**One grammar site, three callers.** The layout lives in `rs.core.container`
(a dependency, like numerics — of both shards and serialize): `Format-Row →
pieces`; `Measure-Row` sums piece lengths (shards, plan time); `Render-Row`
concatenates, writes, and returns `@{ Bytes; RowOffset; RowMetaEnd;
RowContentBegin; RowContentEnd; NextCursor }` (serialize, write time); the same
pair for the header row. Plan and file cannot disagree because they were
computed by the same function over the same pieces. **Offsets remain the
writer's receipt** — `Render-Row`'s running cursor; nobody derives an offset
from `Measure-Row`.

What this replaces: the doctrine "planning is not measurement — pack on
`Attributes.SpanBytes`, escape inflation is negligible" (AGENTS; ledger #26/#27
context). That was written against LTS's `ByteSpan` conflation and LTS's
inability to know row size without rendering thrice. The narrower truth:
**planning never reads written bytes; it computes them forward from the one
layout function; offsets are still the writer's receipt.** Ledger #26 (the
`Attributes` element does not own planning) stands — `SpanBytes` stays an
emission-invariant reader-facing attribute; it is simply not the packing input.
`SizeBytes` is not needed for packing at all; it stays the eligibility number
and the ceiling on any estimate (admiral can join it back from retained
`ingest.out.bag` if a policy ever wants on-disk size — no need to un-exclude it
in assemble for this).

Trade accepted: the plan now depends on emission knobs (attributes on/off,
wire naming, codec) — flip one and membership can shift. Emission-invariant
plans were a property nobody asked for; an exact quota is what
`MaxShardSizeBytes` says (soft in the sense below — oversized shards exceed
it by convention — but exact where it applies).

## Contract

`shards.in`: `assemble.out.result` — `Header` (`EntryCount`, `Elements` → the
derived header, so `attr_block` presence and idx width are known) and `Entries`
(references; canonical ingested order in). Params: the knob roster below.

`shards.out` — the **ShardPlan**:

```
result:  @{ Header (from assemble.out.result); Plan; Shards[]; IdxMap }
plan:    @{ TotalEntries; TotalPlannedSizeBytes; ShardCount; OversizedCount;
            Grouping; Packing; MaxShardSizeBytes; IdxWidth }
shard:   @{ Ordinal; Key; GroupKey; IsOversized; PlannedSizeBytes; EntryCount;
            Entries[] (references to assemble.out.entry, in shard order) }
idxmap:  RelativePath → @{ GlobalIdx; ShardOrdinal; ShardKey; ShardIndex }
```

`schema/shards.schema.json` declares it in the house convention —
`from: "<stage>.out.<shape>"`, three segments — so `contracts.tests` checks
`shards.in ⊆ assemble.out` and prints the residue (`Skipped`, `Diagnostics`
do not ride into the plan; that is a fact, not a failure).

## Knob roster (from LTS, Size-graded; recon §3, corrections applied)

| LTS | v3 | values · default | disposition |
|---|---|---|---|
| `GroupingStrategy` | `Grouping` | `Flat \| ByFileType \| ByRootDirectory` · `Flat` | keep, rename |
| `PackingStrategy` | `Packing` | `Greedy \| Balanced \| Loose` · `Greedy` | keep, rename; **constants extracted from LTS, marked revisit**: Balanced flushes at target×1.1 where target = Σsize / ⌈Σsize / max⌉; Loose packs to 0.8×max |
| `MaxShardSpanBytes` / `MaxShardSizeKB` | `MaxShardSizeBytes` | long · 2 097 152 | consolidate, rename (Size grade; bytes, no KB) |
| `MaxFilesPerShard` | `MaxFilesPerShard` | int · 100 000 | keep |
| `AllowOversizedShards` | `AllowOversizedShards` | switch · **`$true`** | keep, invert default: an entry whose `Measure-Row` alone exceeds the budget gets its own shard (`IsOversized`); `$false` throws |
| `Strategy` (`Auto`/`ContentBased`/`FileLevel`/`FixedSize`) | — | — | **drop** — dead wrappers over Grouping × Packing |
| `ShardPrefix` / `Stem` | `ShardStem` | string · from RunContext/Root | keep, rename |
| `ExcludeAttributes` / `ExcludeShardBlocks`, `Format`, `Compress` | — | — | **relocate to serialize** — emission knobs, not planning |

**Anti-fragmentation is a property, not a knob** (user, 2026-08-15) — it falls
out of three things already above, and needs nothing added:

1. **Atomicity** — the planner's unit is the entry; an ingested file's content
   is **never split across shard files**. That is the fragmentation being
   avoided. Invariant of the plan structure (`Entries[]` per shard).
2. **The overflow exception** — `AllowOversizedShards` (`$true`): when a
   single entry's `Measure-Row` exceeds the quota, it is neither fragmented
   nor dropped — it gets its own shard, oversized by convention,
   `IsOversized = $true`, exactly one entry.
3. **Smoothing** — `Packing = Balanced | Loose`, so a group's tail is not one
   tiny shard.

Consequence for the quota's meaning: **`MaxShardSizeBytes` is a quota for
multi-entry shards, not a hard cap on every file** — oversized shards exceed
it by design; tail shards fall short. Two different determinisms, do not
conflate: shard *sizes* are not uniform and the quota is soft; each shard's
`PlannedSizeBytes` is exact and equals its written file.

## Algorithm — five phases, in memory, no I/O

1. **Group** — `[ordered]` buckets. `Flat`: one bucket. `ByFileType`: key =
   `Extension.ToLower()` (`'.noext'` if empty), first-observed order.
   `ByRootDirectory`: first path segment, `'.root'` for root-level files forced
   to index 0.
2. **Order within group** — `Flat`: by `Get-PathHash(RelativePath)` (uniform
   dispersion, stable across runs; ledger #4). Grouped: ordinal by
   `RelativePath` (reading order). *(Recon's inference on Flat; confirm against
   LTS before implementing — the sort key is a policy call either way.)*
3. **Pack** — per group, `cumulative += Measure-Row(entry, header, idxWidth)`;
   flush when `cumulative + next > quota` or `count ≥ MaxFilesPerShard`;
   oversized isolation per the switch (a lone entry over quota → its own
   shard, whole); effective quota per `Packing`. `PlannedSizeBytes`
   includes `Measure-HeaderRow`.
4. **Name** — `Ordinal = i+1`; `Key = "s{0:D3}"`, plus `_<cleanGroup>` when
   grouped and not `.root` (`cleanGroup` = group key minus leading `.`, path
   separators → `_`, non-`[A-Za-z0-9_-]` → `_`).
5. **Global idx** — sequential `0..N-1` across shards in final reading order;
   `IdxMap` records `GlobalIdx / ShardOrdinal / ShardKey / ShardIndex`. Fixes
   LTS's idx-hopping defect (`tempIdx` stamped pre-partition, `:2303–2339`).

## What must NOT come across (recon §2/§6, unchanged)

Two emission engines (Flat `BlockCopy` vs grouped `FileStream`); grammar
rendered thrice; regex offset recovery (`Get-EntryByteOffsets:953`); packing on
LTS `ByteSpan` (rendered-row size mislabeled — ledger #27); dead `Strategy`
wrappers; any I/O in the planner; sorting at serialization.

## What the recon got that this brief changes

- `from: "assemble.out.result.Header"` (four segments) → `shards.in.result:
  { Header: {from: "assemble.out.result"}, Entries: {from: "assemble.out.result"} }`.
- "0 join residues" as an exit gate → residues are facts; the suite prints them.
- Planning input: recon planned on `Attributes.SpanBytes` / content length
  (following the old doctrine) → this brief plans on `Measure-Row` (exact).
- `NodePath` in the §4.1 example is the directory portion (`'src/'`), not the
  file path.
- `SizeBytes` is excluded from entry bags by assemble; the recon's "bounded by
  SizeBytes" is a property of the estimate, not an input — and with exact
  measurement it is not needed for packing.

## Exit gate

- **Plan = file, by construction**: for a plan and its serialized shards,
  `PlannedSizeBytes` equals each shard file's byte length exactly (fixed-width
  idx makes this exact, not bounded). This is the new gate the measurement
  buys; assert it in `pipeline.smoke` once serialize exists.
- Deterministic: identical IR + identical knobs → bit-identical plan.
- Coverage + atomicity: every entry in exactly one shard, whole; Σ `EntryCount`
  = `IR.EntryCount`; no entry appears in two shards.
- Oversized isolation: a synthetic entry over quota gets its own shard under
  `$true` (`IsOversized`, `EntryCount = 1`); throws under `$false`. Every
  non-oversized shard's `PlannedSizeBytes ≤ MaxShardSizeBytes`.
- Idx: `IdxMap` values are `0..N-1`, monotonic across shards in reading order.
- `contracts.tests` green with `shards.schema.json` present; battery green and
  error stream clean.

## Non-goals

- Bytes, offsets, header-row derivation, wire naming — `shard-container-brief`
  / serialize.
- The manifest — consumes the plan (`IdxMap`, keys) and serialize's receipt.
- Anti-frag policy design beyond recording the open call.
- Un-excluding `SizeBytes` in assemble.

## Open calls

- `Balanced` ×1.1 / `Loose` ×0.8 — keep LTS constants or re-derive.
- Flat ordering key — `Get-PathHash` (recon) vs something else; confirm LTS.
- Whether the plan holds entry *references* (assumed) or copies.
- Layout module name: `rs.core.container` (assumed here) vs exporting
  `Measure-Row` from `rs.core.serialize`. Either satisfies "one grammar site";
  a separate module makes the dependency explicit for both callers.
