# `rs.core.shards` — from the IR to a shard plan — brief

**Status:** filed, not started · **Filed:** 2026-08-15 · **Revised:** 2026-08-16
(packing algorithm and policy stack resolved; supersedes the five-phase LTS
algorithm and the `Greedy | Balanced | Loose` knob), 2026-08-18 (objective
clause 2 is a *shape* — `PackObjective = FrontLoad | Even`, both implemented;
least-overshoot demoted to an invariant; overflow restated as outranking
the objectives; strict+tolerance open call closed; comparison harness added to
the gate) · **Track:** V3 e2e sprint,
export phase 1 (assemble → **shards** → serialize → manifest) ·
**Archaeology:** `design/gemini-shard-recon.md` (LTS knob roster, pathology
table) · **Discussion:** `discussion/opus-export-packing-discussion.md`,
`discussion/packing-strategies-details.md`, and the 2026-08-16 session that
resumed them (LTS shape re-anchored on `project-snapshots/reposnapshot/…0422…`
and `project-snapshots/ThermoMapper/src_20260701_122622_tree.md`) ·
**Companion:** `shard-container-brief.md` (header row, record rows, framing —
the layout module this stage depends on) · **Doctrine touched:** ledger #26
stands; #39 stands; new #40–#48 (#40 amended by #48).

## What this stage is

A **pure planning stage**: takes the IR (`assemble.out`) and decides
*membership, arrangement, and global indexing* — which entries go in which shard
file, in what order, under which knobs — and returns a plan. Zero I/O, zero
writing, zero offset arithmetic. Serialize consumes the plan; manifest consumes
serialize's receipt. Nothing flows backwards (shard-container-brief §Seam).

Module: `rs.core.shards.psm1`, entry point `New-ShardPlan`. Dependencies:
`rs.core.numerics` (`Get-PathHash`, ledger #4 — now only as an optional sort
key) and the container layout module (`rs.core.container`) for `Measure-Row`.

## Vocabulary (fixed; see ledger #46)

- **run** — one execution producing one payload (tree + every shard, every group).
- **record** — one ingested file, pre-assembled into one row. **Never split**
  (atomicity; ledger #47 — fragmentation is not on the v3 critical path).
- **group** — the containment unit set by `Grouping`; a shard never mixes groups.
  `Flat` is one group. Packing runs per group; groups are independent.
- **sidx / shard index** — the fixed-width ordinal in the shard **filename**
  (`s001`, `s001_clustering`); global and monotone across groups. Not a row
  column — self-evident from the file; the tree joins on it.
- **idx** — optional global record ordinal, one address scheme among several
  (path, tree offsets). Which address columns v3 carries is open (container
  thread); packing needs only that any such column be fixed-width.
- **quota / ceiling** — `ShardQuotaBytes` (target) and `ShardQuotaBytes +
  ShardToleranceBytes` (ceiling), both exact bytes; e.g. 32 768 + 4 096 =
  36 864. No percentages.
- **singleton / in-band / oversized / runt** — four different things that can
  look alike in a listing (see §Policy stack). Diagnostics keep them apart.

## Planning is exact — how the measurement works

Every byte of a shard file is under our control and every input is in memory
at plan time, so a row's serialized size is a **pure function**, not an estimate:

```
row = [address fields ·] path · D · [attr_block · D] · length_str · D · content_span · NL

Measure-Row(entry, header) =
    Σ fixed-width address fields + |D|·k
  + utf8(path) + |D| + [utf8(attr_block) + |D|]
  + digits_fixed(spanBytes) + |D| + spanBytes + |NL|
  where spanBytes = utf8(codec(Content))
```

- **Row bytes are packing-invariant.** Every field is either content-derived
  (known at measure time — path, attributes, length, content) or
  **fixed-width with the width taken from a bound known before packing**
  (`idx` ← `digits(EntryCount)`; any ordinal ← its bound). No field is both
  variable-width and position-dependent. LTS's plain-integer `idx` is the
  counterexample: row bytes shift at every order of magnitude. Width overflow
  is a plan-time error, never a silent widen.
- **The header row is the schema; the row is its shadow.** The run resolves
  the header schema once (which admissible fields are on); `headerBytes` =
  `Measure-HeaderRow` of that resolved line, one constant per run, identical in
  every shard; each `rowBytes` is the same schema projected onto a record.
  Measure and render read one source — nothing to drift.
- `content_span = codec(Content)` — the container codec (shard-format-notes
  §SPEC) over the processed content already in memory; `spanBytes` is computed
  without allocating (`Measure-ContentSpan`, a counting fold over the same rule
  table `ConvertTo-ContentSpan` materializes with).
- **Termination is `NL` = LF alone; the LTS trailing `|` is dropped** (leaning,
  ledger #45 — the container is newline-delimited, one physical line per row,
  jsonl-like). Byte-exactness assumes **UTF-8 without BOM and `\n` only**; the
  writer controls newline bytes explicitly regardless of platform. *(Propagate
  to shard-container-brief.)*
- Shard file size = `headerBytes` + Σ `rowBytes`. Plan = file, by construction.

**One grammar site, three callers.** `Format-Row → pieces` in
`rs.core.container`; `Measure-Row` sums piece lengths (shards, plan time);
`Build-Row` concatenates to bytes and returns the offset receipt (serialize writes,
write time). **Offsets remain the writer's receipt** — nobody derives an offset
from `Measure-Row`; serialize never reports back into the plan.

What this replaced (unchanged from the 08-15 filing): the doctrine "planning is
not measurement — pack on `Attributes.SpanBytes`" (element now `ContentMeta`). Ledger #26 stands
(`SpanBytes` is a reader-facing attribute, not the packing input); `SizeBytes`
is not needed for packing.

## Contract

`shards.in`: `assemble.out.result` — `Header` (`EntryCount`, `Elements` → the
resolved header schema, so field presence and widths are known) and `Entries`
(references; canonical ingested order in). Params: the knob roster below.

`shards.out` — the **ShardPlan**:

```
result:    @{ Plan; Groups[]; Shards[]; IdxMap }        # no Header — the plan
                                                        # embeds nothing upstream
plan:      @{ TotalEntries; TotalPlannedSizeBytes; ShardCount; OversizedCount;
              SingletonCount; InBandCount;
              TotalOvershootBytes; MaxOvershootBytes;   # overshoot-facing / tolerance-facing
              MaxFillBytes; MinFillBytes; HeaderOverheadBytes;
              Grouping; GroupSort; OrderStrict; PackObjective;
              ShardQuotaBytes; ShardToleranceBytes; HeaderBytes; IdxWidth }
group:     @{ GroupKey; EntryCount; SumRowBytes; ShardCount; LowerBound; Gap;
              OversizedCount; SingletonCount; InBandCount;
              TotalOvershootBytes; MaxOvershootBytes; MaxFillBytes; MinFillBytes }
shard:     @{ Ordinal; Key; GroupKey; Class (Normal|Singleton|InBand|Oversized);
              IsOversized; PlannedSizeBytes; OvershootBytes; EntryCount;
              Entries[] (references into assemble.out.result.Entries, shard order) }
placement: RelativePath → @{ GlobalIdx; ShardOrdinal; ShardKey; ShardIndex }  (IdxMap values)
```

`schema/shards.contract.json` (minted 2026-08-17) declares it in the house
convention; `contracts.tests` checks `shards.in ⊆ assemble.out ∪
container.out` (four-segment `from` into `assemble.out.entry.core`) and prints
the residue. Layout (`HeaderBytes`, `IdxWidth`, `Columns`) is an input from
`container.out.layout`, resolved before this stage — not derived here.

## Knob roster (Size-graded; recon §3 with this session's corrections)

| LTS | v3 | values · working default | disposition |
|---|---|---|---|
| `GroupingStrategy` | `Grouping` | `Flat \| ByFileType \| ByRootDirectory` · `Flat` | keep, rename |
| `PackingStrategy` (`Greedy \| Balanced \| Loose`) | — | — | **drop** (ledger #40). Objective is tightest packing, not evenness; the ×1.1 / ×0.8 constants go with it. Replaced by the four knobs below — note these are *orthogonal axes*, not a flat enum: LTS's three names turned out to be one number, and a cross-product collapsed into a name list is how that happened. A named preset resolving to a knob tuple is fine, provided the plan records what it resolved to (ConfigEcho; payload-manifest-ledger #11) |
| `MaxShardSpanBytes` / `MaxShardSizeKB` | `ShardQuotaBytes` | long · 32 768 (working) | consolidate, rename — a **Size** (whole written file: header + rows). "Span" was meant as the file's whole span; the word is now content-measure vocabulary, so it leaves the knob name |
| — | `ShardToleranceBytes` | long · 4 096 (working) | **new** (ledger #41). Exact bytes above quota that a *packed* shard may reach when doing so eliminates a shard. Ceiling = quota + tolerance |
| — | `OrderStrict` | switch · `$false` (working) | **new** (ledger #43). `$true`: shards are contiguous runs of the group's sorted order. `$false`: membership is optimized within the group; sort restored within each shard for rendering |
| — | `PackObjective` | `FrontLoad \| Even` · `FrontLoad` (working) | **new** (ledger #48). Clause 2 of §Objective — the *shape*: how the sub-shard remainder is distributed at the minimum shard count. `FrontLoad` = fill to quota in order, remainder as the group's tail; `Even` = spread it. Both implemented; least overshoot is an invariant of both, not a third value. Never overrides overflow (atomicity) |
| *(implicit)* | `GroupSort` | `PathAsc \| PathHash \| …` · `PathAsc` | **new**, per-group sort key. `PathAsc` = `RelativePath` ordinal ascending. `PathHash` (`Get-PathHash`, ledger #4) survives as an option — under flexible packing FFD does the dispersion job, so it is a reading-order device, not a packing input |
| `MaxFilesPerShard` | `MaxFilesPerShard` | int · 100 000 | keep — a second capacity dimension the packer honors alongside bytes |
| `AllowOversizedShards` | — | — | **retire** (leaning, ledger #42): overflow is policy, not a switch. A fail-fast diagnostic gate, if ever wanted, is not a packing knob |
| `Strategy` (`Auto`/`ContentBased`/`FileLevel`/`FixedSize`) | — | — | **drop** — dead wrappers |
| `ShardPrefix` / `Stem` | `ShardStem` | string · from RunContext/Root | keep, rename |
| `ExcludeAttributes` / `ExcludeShardBlocks`, `Format`, `Compress` | — | — | **relocate to serialize** — emission knobs |

Working defaults are values from the discussion, not final config-surface calls.

## Objective (ledger #40, clause 2 per #48)

**Overflow outranks everything below.** A record whose `headerBytes + rowBytes`
exceeds the ceiling is never split and never dropped — it gets its own shard
at whatever size (§Policy stack, *Overflow*). That shard is outside quota,
outside tolerance, and outside every objective term here; it is declared to the
reader as a hazard. Atomicity is the anti-fragmentation guarantee; the numbers
below govern only the *packable* set.

Per group, lexicographic:

1. **Fewest shards** such that every *packed* shard's `PlannedSizeBytes ≤`
   ceiling. Total written bytes = Σ rows + k · `headerBytes`, so fewest shards
   ≡ least overhead. `k` is the minimum under the joint constraints (bytes,
   ceiling, count cap) — no objective ever changes it.
2. **Shape**, per `PackObjective` — how the remainder (`Σ_g` is almost never
   an exact multiple of capacity; the slack is < one shard) is distributed
   among the `k` shards. Both implemented, selectable (ledger #48):

   | value | shape | contiguous procedure (exact) |
   |---|---|---|
   | `FrontLoad` (working default) | fill to quota in nominal order; the remainder is the group's tail. "Pack as much as possible" — `k−1` full shards + one tail | greedy at quota; if that yields more than `k` shards, absorb the last shard backward into predecessors within the ceiling (adjacent merge) |
   | `Even` | spread the remainder; minimize the largest shard, then the next largest, and so on — `k` shards near `Σ_g / k` | linear partition — binary search on the bound + greedy feasibility, or DP over cut points |

3. **Least overshoot** *within the chosen shape*: among arrangements that
   satisfy 1 and 2, minimize Σ per-shard `overshoot = max(0, PlannedSizeBytes −
   ShardQuotaBytes)`. An invariant both shapes honor, **not a shape of its
   own** — see #48 for why a "minimize overshoot" objective is dominated.

**Tolerance is a per-shard bound, not a pool.** It is the wiggle room the
optimizer may use when considering candidates for an underutilized shard —
each shard independently may reach `quota + tolerance`; nothing is "consumed"
across shards. *Overshoot* is the measurement: how far a given shard actually
sits above quota, always `≤ tolerance`. Same relation as quota (bound) to fill
(measurement).

Without clause 2, quota is decorative in flexible mode (the packer would just
fill to the ceiling); clause 3 is what keeps tolerance a bound for
shard-eliminating moves rather than routine fill.

Interaction with stage 7: under `FrontLoad` the tail rule (min-fill bin last)
*places* the remainder; under `Even` there is little for it to do. Same rule,
both shapes.

## Policy stack (each enforced at exactly one stage)

- **Atomicity** — the planner's unit is the record; content is never split.
  Structural: `Entries[]` per shard; the packer moves whole records. (Stage 4.)
- **Overflow** — `headerBytes + rowBytes > ceiling` → the record gets its own
  shard, header + one row, whatever its size (`Class = Oversized`,
  `IsOversized`). Rare; more likely as quota shrinks. Pinned before packing;
  never enters FFD/elimination; **excluded from total/max overshoot and from
  lower-bound comparisons** (its excess is atomicity honored, not overshoot). A declared **reader hazard**: the tree names each oversized shard and
  its size (payload-manifest-ledger, same class as #8/#16). (Stage 4.)
- **Quota / ceiling** — quota is the packing capacity; ceiling is the
  feasibility bound for shard-eliminating moves only, never routine fill.
  Reader-facing statement: *every shard ≤ ceiling except those flagged
  oversized*. (Stages 5–6.)
- **Group containment** — no cross-group stage exists. Each group carries its
  own tail; that is a designed property of grouping, not waste. (Stage 1.)
- **Order** — a per-group knob (`GroupSort`), applied at enumerate and restored
  within each shard at sequence. Flexible membership is legitimate under any
  `Grouping` — directory-listing adjacency is a human convention the reading
  agent does not need. (Stages 1, 7.)
- **Single-record shard bands** (classification, exact bytes):
  `headerBytes + rowBytes ≤ quota` → **Singleton** (a full shard that happens to
  hold one record; not a runt, not a hazard); `quota < … ≤ ceiling` → **InBand**
  (permitted overshoot; note the header can push a "row under quota" here);
  `> ceiling` → **Oversized**. A **runt** is a *small* group tail — different
  again. Empty group ≠ singleton group: an empty group yields no shard; a
  singleton group yields one shard, classified as above.

## Algorithm — the cascade (in memory, no I/O)

1. **Enumerate.** Records from `Entries`; assign group per `Grouping` (keys as
   before: `Flat` one bucket; `ByFileType` = `Extension.ToLower()` /
   `'.noext'`; `ByRootDirectory` = first path segment, `'.root'` first); sort
   within group by `GroupSort` → **nominal order**. `EntryCount` known.
2. **Fix schema.** Resolve header schema; `headerBytes`; widths for
   fixed-width fields (`IdxWidth = digits(EntryCount)`).
3. **Measure.** `rowBytes = Measure-Row(entry, header)` for every record, once.
   Per-group size vector, `Σ_g`. Diagnostics: distribution, max, count near/over
   quota.
4. **Classify.** Oversized per §Policy → pinned singleton bins, removed from the
   packable set. `LB_g = ⌈Σ_packable / (quota − headerBytes)⌉ + |oversized_g|`.
5. **Strict baseline** (always, per group). Greedy contiguous over nominal
   order, capacity `quota − headerBytes` and `MaxFilesPerShard` → `k₀_g`. It is
   provably optimal for contiguous partitions at quota, and reproduces LTS's
   cuts on the 0422 sample exactly.
   - `OrderStrict && Tolerance == 0` → done.
   - `OrderStrict && Tolerance > 0` → `k_min` = greedy at the ceiling, then
     the shape, exact under **either**:
     - `FrontLoad`: greedy at quota; while it yields more than `k_min` shards,
       absorb the last shard backward into predecessors within the ceiling
       (adjacent merge, latest-first). Overshoot arises only where the merge
       forces it — clause 3 falls out.
     - `Even`: linear-partition into `k_min` contiguous parts, minimize the
       largest part, then the next — binary search on the bound + greedy feasibility, `O(n log Σ)`;
       or DP over cut points. Clause 3 holds by Schur-convexity (#48).
     The two procedures the 08-16 revision listed as competing candidates for
     one objective *are* the two objectives; that open call is closed.
6. **Flexible rearrangement** (per group, `!OrderStrict`).
   a. **FFD** over the packable set, capacity `quota − headerBytes` (+ count
      cap); sort by `rowBytes` desc, ties → nominal order. Take
      `min(k₀, k_FFD)`; on tie keep the strict arrangement (order for free).
      Flexible is never worse than strict.
   b. If `k > LB_g` and `Tolerance > 0`: **bin elimination** — smallest bin
      first, best-fit its records into other bins with capacity = ceiling;
      eliminated iff all placed; repeat passes until a full pass changes
      nothing. Deterministic scan order.
   c. If still `> LB_g`: stop; report `Gap`. No stochastic/local search in v1
      (ledger #44).

   **Shape pass**, at the settled `k`, before sequencing: `FrontLoad` is
   already served — FFD fills bins to quota in turn and elimination only uses
   the tolerance band to remove a bin; the small bin FFD leaves is the tail (stage 7).
   `Even` needs a distribution step: LPT over the `k` bins (longest row first
   into the least-filled bin), deterministic, within ~4/3 of optimal. Note the
   asymmetry with stage 5 — **the ordered case is exact, the flexible case is
   approximate**, so an `Even` payload is more even under `OrderStrict` than
   without it. That inverts the usual expectation that flexible dominates, and
   it is a real reason to pick `OrderStrict` rather than a concession.
   d. *Repair pass* (reduce total overshoot by moves that cost no shard) —
      **roadmap item, gated on v1 MVP results** (not "defer and forget").
7. **Sequence.** Within each group order bins by the nominal position of their
   first record, then **move the group's minimum-fill bin to the tail** (ties →
   later nominal position) — so runts are always group tails; no threshold
   needed. Restore nominal sort within each bin. Concatenate groups in group
   order → shard `Ordinal`, `Key = "s{0:D3}"` (+ `_<cleanGroup>` when grouped
   and not `.root`; width fixed before any name is written), and global `idx`
   `0..N−1` in final reading order (`IdxMap`). Oversized shards stay where
   nominal order puts them.
8. **Plan.** Emit `plan / groups[] / shards[] / idxmap` per §Contract, with the
   diagnostics. Membership and predicted sizes are planned here; **offsets are
   not** — serialize measures them.

*(Stage 9, serialize, is downstream: writes header + rows, measures offsets,
builds the tree from measured values.)*

Testability falls out: the packer is `(sizes[], headerBytes, quota, tolerance,
orderStrict, maxFiles) → assignment` — exercised on synthetic size vectors with
no repo, no ingestion, no fixtures.

## Calibration on real shapes (for the reader of this brief)

`reposnapshot-v3_20260422_201912` (11 records, quota 32 768, header 138):
Σ = 85 508, LB = 3. Strict greedy at quota → k = 4 (= LTS, runt `s004`
3 801 B). Strict + tolerance 8 192 → k = 3, tail 35 397 (one shard over quota,
under ceiling). Flexible FFD at quota → k = 3 with zero overshoot. Stage 6b/6d
and the strict DP have no work to do at this n; they bite on lumpier repos.
`ThermoMapper/src_20260701_122622` shows the grouped shape: 11 groups, 70
shards, per-group tails, and mid-group oversized singletons (`s062`, `s069`).

## What must NOT come across (recon §2/§6, unchanged)

Two emission engines; grammar rendered thrice; regex offset recovery; packing
on LTS `ByteSpan`; dead `Strategy` wrappers; any I/O in the planner; sorting at
serialization; the doubled header row of the 0422 sample (an old LTS bug).

## Exit gate

- **Plan = file, by construction**: `PlannedSizeBytes` equals each shard file's
  byte length exactly; assert in `pipeline.smoke` once serialize exists.
- **Deterministic**: identical IR + identical knobs → bit-identical plan
  (including bin order and tie-breaks).
- **Coverage + atomicity**: every entry in exactly one shard, whole; Σ
  `EntryCount` = `IR.EntryCount`.
- **Ceiling with carve-out**: every shard with `Class ≠ Oversized` has
  `PlannedSizeBytes ≤ ShardQuotaBytes + ShardToleranceBytes`; every `Oversized`
  shard has `EntryCount = 1`.
- **Overshoot bounded** (the tolerance-facing check): per group and plan,
  `MaxOvershootBytes ≤ ShardToleranceBytes` — equivalently every non-oversized
  shard's `OvershootBytes ≤ ShardToleranceBytes`; `Tolerance == 0` ⇒
  `MaxOvershootBytes == 0`. `TotalOvershootBytes` is the overshoot-facing
  aggregate (clause 3, harness), not a bound.
- **Never worse than strict**: per group, `ShardCount ≤ k₀_g`; and
  `ShardCount ≥ LowerBound` with `Gap` reported.
- **Tail rule**: within a group, the minimum-fill non-oversized bin is last.
- **Shape honored**: at the settled `ShardCount`, `FrontLoad` yields `k−1`
  shards that no earlier-in-order record could have joined without breaching
  quota (or ceiling where a merge was forced), and `Even` admits no
  rearrangement with smaller lexicographic max fill — checked by brute force
  over all partitions on small vectors. Under both, no arrangement of the same
  shape has smaller `TotalOvershootBytes` (clause 3). `ShardCount` is identical
  under both shapes for the same knobs — clause 1 is lexicographically first.
  **"Never worse than strict" is a claim about count only** — under `Even`,
  flexible may be *less* even than strict, since stage 5 is exact and stage 6
  is LPT.
- **Overflow outranks shape**: an `Oversized` shard is never touched by either
  objective, never enters `TotalOvershootBytes` / `MaxOvershootBytes` / `MaxFillBytes`, and is present
  in the plan under both values with identical `PlannedSizeBytes`.
- **Idx**: `IdxMap` values `0..N−1`, monotone in reading order; widths fixed.
- **Synthetic vectors**: the packer passes the above on hand-built size vectors
  covering: all-fit-one-shard; exact-multiple; single oversized; oversized mid
  sequence; runt tail absorbed only with tolerance; FFD beats strict; k == LB
  short-circuit; count cap binding; empty group; singleton group; strict +
  tolerance under each shape; **a vector where the two shapes visibly
  disagree** (`k = 2`, remainder large: `FrontLoad` → full + runt, `Even` →
  two near-equal); an oversized record present under both shapes.
- **Shape comparison harness** (the science): both shapes × both `OrderStrict`
  values over the *same* enumerated dataset — only stages 5–7 rerun, never
  ingestion — reporting `ShardCount / LowerBound / Gap / TotalOvershootBytes / MaxOvershootBytes /
  MaxFillBytes / MinFillBytes / HeaderOverheadBytes` per cell. Four rows, one
  table, one dataset. Lives in the battery, not the shipping path. Without it,
  "implement both" produces two black boxes and no basis for choosing a
  default.
- `contracts.tests` green with `shards.contract.json`; battery green; error
  stream clean.

## Roadmap (not v1; recorded so it is not lost)

- Repair pass (stage 6d) — pending v1 MVP results.
- AST-based fragmentation (one file → N records, e.g. markdown H2 sections, with
  a semantic sub-addressing scheme). Lands upstream of packing (a longer size
  vector); packing is already fragmentation-agnostic. Touches the row schema
  and tree addressing, not this stage.
- Local search beyond FFD + elimination — only if diagnostics show `Gap > 0`
  on real payloads.

## Non-goals

- Bytes, offsets, header-row derivation, wire naming, which address columns
  exist — `shard-container-brief` / serialize.
- The manifest — consumes the plan and serialize's receipt (and declares
  oversized shards to the reader).
- Un-excluding `SizeBytes` in assemble.

## Open calls

- Working defaults (`32 768 / 4 096 / OrderStrict $false / FrontLoad`) →
  final config surface.
- `PackObjective` value names — `FrontLoad | Even` are descriptive, not yet
  house vocabulary; and whether a named preset layer sits over the
  `{Grouping, GroupSort, OrderStrict, PackObjective}` tuple.
- Which shape becomes the shipped default once the comparison harness has run
  on real payloads — the working default is a placeholder, not a finding.
- `FrontLoad` under flexible order when a merge is forced: which bin absorbs
  the tail's records — FFD's natural residue vs. an explicit backward pass.
  Contiguous is settled (adjacent merge, latest-first).
- Whether a fail-fast switch for oversized survives as a diagnostic gate.
- Whether the plan holds entry *references* (assumed) or copies.
- Layout module name: `rs.core.container` (assumed) vs. exporting `Measure-Row`
  from `rs.core.serialize`.
- **Propagation owed to shard-container-brief**: LF-only termination, no
  trailing `|`; UTF-8 no BOM; fixed-width rule for ordinal/address fields;
  header schema as the superset with rows as its shadow; which address columns
  v3 carries (`idx` optional).
