---
format: Structural
exported_at: 2026-08-22T23:55:24.1935326Z
exchanges: 32
user_label: Aipithicus
sessions:
  - b5ebe4e1
models:
  - claude-fable-5
  - claude-opus-5
  - claude-sonnet-5
exclude:
  - thinking
  - synthetic
  - timestamps
  - session-markers
  - exchange-markers
  - tool-calls
  - tool-results
  - subagents
---

# so lets review the new plans for building reposnapshot's export stages `Export phase now has its three specs: shards-brief (plan) → shard-container-brief (bytes) → manifest (existing module, to be checked against the receipt)`

Read all three: [shards-brief.md](issues/reposnapshot/briefs/shards-brief.md), [shard-container-brief.md](issues/reposnapshot/briefs/shard-container-brief.md), [rs.core.manifest.psm1](utils/reposnapshot/reposnapshot-v3/rs.core.manifest.psm1), plus the codec SPEC and `assemble.schema.json` to check the claims against.

The split is right and the central move — one layout function, `Measure-Row`/`Render-Row` derived from one `Format-Row → pieces` — is what makes the "plan = file" gate possible at all. Below is what I found that doesn't hold yet.

## Contradictions to resolve before code

**1. Per-shard headers reintroduce the circularity you just killed.**
The container brief leans (c) per-shard header ([:102](issues/reposnapshot/briefs/shard-container-brief.md:102)). The shards brief packs with `Measure-Row(entry, header, idxWidth)` where `header` is _the_ derived header, one per plan ([:32](issues/reposnapshot/briefs/shards-brief.md:32)).

Under per-shard headers, row size depends on the shard's column set → column set depends on membership → membership depends on row size. Under `ByFileType` this is benign (the group is homogeneous and decided in phase 1). Under `Flat` — the default — membership is path-hash dispersion, so it's genuinely circular.

The invariant that fixes it: **the header a row is measured against must be knowable before packing.** That makes it a **per-group** header, not per-shard — decided at phase 1, rendered into every shard file of that group. Under `ByFileType` you get (c)'s entire benefit; under `Flat` it degrades to corpus-wide, which is precisely the case where partial presence still needs an (a)-or-(b) answer. So the three-way choice isn't three-way: it's (c) where grouping permits, with a declared fallback. This also settles the container brief's open call "header per shard vs per run".

**2. `Packing = Balanced` can breach the quota the exit gate asserts.**
Gate: every non-oversized shard's `PlannedSizeBytes ≤ MaxShardSizeBytes` ([:186](issues/reposnapshot/briefs/shards-brief.md:186)). Balanced flushes at `target × 1.1`, `target = Σ / ⌈Σ / max⌉` ([:106](issues/reposnapshot/briefs/shards-brief.md:106)). Take Σ = 1.9·max: ⌈1.9⌉ = 2, target = 0.95·max, threshold = 1.045·max. The LTS constant and the new gate are incompatible. Either clamp the effective quota to `min(target×1.1, max)` or scope the gate to Greedy/Loose.

**3. "Core columns always" contradicts the LTS-parity gate — and the lean-row doctrine.**
Container brief: core = `RelativePath, NodePath, LastWriteUtc, Content` ([:64](issues/reposnapshot/briefs/shard-container-brief.md:64)). Its own gate: "Header derived from a real IR reproduces the LTS column set" ([:193](issues/reposnapshot/briefs/shard-container-brief.md:193)). The observed LTS grammar is `idx | path | [attributes] | length | content` — no `NodePath`, no `LastWriteUtc`. Two extra columns on every row, and `NodePath` is the directory portion of `RelativePath`, i.e. redundant by derivation. That's hard to square with the doctrine that made attributes opt-in _because_ per-row metadata fragments a reader's attention.

## Specification holes

- **Row terminator `T` is still open.** `Measure-Row`'s formula ends `· T · NL` ([:30](issues/reposnapshot/briefs/shards-brief.md:30)), but shard-format-notes §"Row termination — to confirm in spec" ([:36](issues/reposnapshot/design/shard-format-notes.md:36)) has three candidate emissions unresolved. An open format question sits inside the exact-measurement formula, and it's in neither brief's open calls.
- **`Measure-Content`'s arithmetic is signed, not "inflation".** Stated as `GetByteCount + line-break inflation − stripped controls` ([:44](issues/reposnapshot/briefs/shards-brief.md:44)). Per-terminator UTF-8 deltas: LF/CR/VT/FF `+1`, CRLF `0`, NEL `0`, **LS/PS U+2028/9 `−1`** (3 bytes → 2). Deflation exists. Also worth stating the C0 partition explicitly, since TAB and VT/FF are C0 exceptions to rule 3.
- **"Two functions, one table, cannot disagree" is an aspiration, not a construction.** Same table, two code paths, still divergeable. Make the shared unit a per-character decision returning replacement length, so the only difference is _sum_ vs _append_ — and add the differential property test `Measure-Content(c) == GetByteCount(Encode-Content(c))`.
- **The header row isn't in the packing accumulator.** `PlannedSizeBytes` includes `Measure-HeaderRow` ([:147](issues/reposnapshot/briefs/shards-brief.md:147)) but packing starts `cumulative += Measure-Row` from zero — every shard overshoots by one header row. Seed `cumulative = Measure-HeaderRow`, and apply the same to the oversized test.
- **Fixed-width idx is a container decision made in a planning brief, and it's payload-visible.** `0007 | path` instead of `7 | path` diverges from LTS's grammar and from shard-format-notes. It's the right call — unpadded means the plan only _bounds_ the file — but state it as a requirement shards places on the container, and record the trade rather than presenting it as free.
- **The receipt has no schema and no owner.** It appears once, as a sketch: `@{ Header; Rows[] with offsets; ByteLength }` ([:158](issues/reposnapshot/briefs/shard-container-brief.md:158)). In a three-spec set whose thesis is _the receipt is the only source of positions_, it's the least-specified artifact. No `serialize.schema.json`, no `manifest.schema.json` — only assemble/crawler/ingest/membrane exist.

## Manifest, checked against the receipt

- **`ColumnHeader` is misidentified.** The container brief says the derived header object feeds "the tree manifest's `ColumnHeader`" ([:68](issues/reposnapshot/briefs/shard-container-brief.md:68)). Today `ColumnHeader` is the _offset table's_ schema — `name<TAB>shard_index<TAB>row_offset<TAB>…` ([:301](utils/reposnapshot/reposnapshot-v3/rs.core.manifest.psm1:301)) — not the payload column set. Those are different declarations. If the tree should also declare the shard grammar (it should — it's the exclusive entrypoint), that's a _new_ block, and under per-group headers it's N declarations, not one string.
- **`shard_index` name collision.** The manifest column must identify _which file_ to seek; the plan's `IdxMap.ShardIndex` is position _within_ a shard ([:93](issues/reposnapshot/briefs/shards-brief.md:93)), which is useless for seeking. Same name, two meanings, silent wrong payload.
- **Stale doctrine in the QUEUED note** ([:33–44](utils/reposnapshot/reposnapshot-v3/rs.core.manifest.psm1:33)): still calls Compaction a "cipher key" and cites "the LF/CRLF distinction the codec's preserve stance exists to maintain." Both were retired — notice-not-key, normalize-not-preserve.
- **Instructions are wrong for a sharded payload**: "Seek to `row_offset` in the .json file" ([:221](utils/reposnapshot/reposnapshot-v3/rs.core.manifest.psm1:221)). There is no JSON anywhere in v3.
- **Dead surface**: `New-SnapshotTocModel` + `Get-MonolithInstructionSet` serve the JSON monolith that assemble's IR replaced. `WriteMetadataBlock` and `ExcludedShardBlocks` are model fields the template never reads ([:286](utils/reposnapshot/reposnapshot-v3/rs.core.manifest.psm1:286)) — and `ExcludeShardBlocks` is a knob the shards brief relocates to serialize.
- **`SummaryLine` is caller-formatted** and its documented example (`Strategy: Auto | MaxShardSizeKB: 2048`) names a dropped knob and a renamed one. It should be built from `shards.out.plan`.
- **`Results` contract** (`.Path`, `.Files`) needs rewriting against `shards.out.shard` + the receipt. Also: the file is `.psm1` with no `Export-ModuleMember`, while its own `.NOTES` says "Standalone file — dot-source to use. Not a module."

## Sequencing

`rs.core.container` is a dependency of both stages, has no stub (only shards and serialize are 0-byte), and its name is an _open call in both briefs while both bodies assume it_. Close that first — it's load-bearing.

Then move the headline gate down a level. "Plan = file" is currently deferred to `pipeline.smoke` "once serialize exists" ([:180](issues/reposnapshot/briefs/shards-brief.md:180)), which means shards can land fully green without its central property ever being exercised. At the container level you can assert `Measure-Row(e) == Render-Row(e).Bytes.Length` with no serialize stage at all — same property, testable immediately, and it's the kind of gate that catches the header-row and terminator issues above rather than deferring them.

Want me to fold the accepted items into the two briefs and open a manifest brief for the audit list?

---

# yea there's still alot of confusion so i guess we'll need to take this one thing at a time. the design briefs clearly don't fully capture intent or points where i want to retain aspects of LTS design. Lets unpack the packing question

Before I frame anything, let me go to the LTS source rather than the recon's summary of it.
Went to the source — `Partition-Files` in [rs.lts.sharding.psm1:250–609](utils/reposnapshot/rs.lts.sharding.psm1:250). The ground truth changes the shape of this question considerably.

## The three packing strategies are one algorithm with one number

Greedy, Balanced, and Loose are the _same_ sequential first-fit loop, triplicated ~75 lines each. Walk the group's files in order, accumulate, flush when the next file would breach a threshold. The only thing that differs across the three branches is the threshold:

|                                                                    | flush threshold                                                              |
| ------------------------------------------------------------------ | ---------------------------------------------------------------------------- |
| Greedy ([:416](utils/reposnapshot/rs.lts.sharding.psm1:416))       | `maxSpan`                                                                    |
| Balanced ([:504–508](utils/reposnapshot/rs.lts.sharding.psm1:504)) | `min(target × 1.1, maxSpan)`, `target = groupTotal / ⌈groupTotal / maxSpan⌉` |
| Loose ([:535](utils/reposnapshot/rs.lts.sharding.psm1:535))        | `maxSpan × 0.8`                                                              |

Everything else — oversized handling, flush-and-restart, the `MaxFilesPerShard` check, the tail flush — is copy-pasted identically three times.

**Correction to what I said last turn:** I claimed Balanced could breach `MaxShardSizeBytes` and contradict the exit gate. That's wrong about LTS — line 505 checks `wouldExceedMax` as a second conjunct, so Balanced is bounded by max too. What's actually true is narrower and still matters: [shards-brief:106](issues/reposnapshot/briefs/shards-brief.md:106) transcribes Balanced as "flushes at target×1.1" and **drops the max backstop**. Implement the brief literally and you get the breach; implement LTS and you don't. It's a transcription loss in the brief, not a defect in LTS.

## Two things the docstring claims that the code doesn't do

- **"Balanced: Best-fit with load balancing"** ([:258](utils/reposnapshot/rs.lts.sharding.psm1:258)) — there is no best-fit anywhere in the file. Best-fit requires multiple open shards and a search for the tightest fit; there is only ever one open shard, `$currentShard`. Balanced is first-fit with a lower threshold.
- **"Loose: Conservative packing with 20% headroom"** — this one is accurate.

And best-fit was never _available_, which I think is the substantive point: **order is load-bearing here.** Phase 2 deliberately arranges entries — path-hash for Flat ([:311](utils/reposnapshot/rs.lts.sharding.psm1:311)), `RelativePath` within group for ByFileType/ByRootDirectory ([:329](utils/reposnapshot/rs.lts.sharding.psm1:329), [:349](utils/reposnapshot/rs.lts.sharding.psm1:349)). Any real bin-packing algorithm reorders by size and destroys that arrangement. So given a fixed order, the _only_ lever for evenness is where you cut — which is exactly what the threshold does. The docstring describes an algorithm that would have contradicted the stage above it.

Incidentally this closes one of the brief's open calls: Flat-by-`Get-PathHash` and grouped-by-`RelativePath` are both confirmed against source, as is `.root` forced to index 0 ([:353](utils/reposnapshot/rs.lts.sharding.psm1:353)) and ByFileType's first-observed key order (via `[ordered]`, despite the comment claiming a sort).

## Two real defects worth not porting

1. **Packing input is content bytes, not row bytes.** `$file.ByteSpan` or `GetByteCount($file.Content)` ([:376](utils/reposnapshot/rs.lts.sharding.psm1:376)) — the idx, path, delimiters, attributes block, length prefix and terminator are all unbudgeted. So LTS **systematically undercounts**, in one direction: real shard files are always larger than `MaxShardSizeKB`, and by more the smaller the average file. That's the concrete cash value of moving to `Measure-Row`.

2. **Accumulation is in KB as doubles.** `$currentSizeKB += $fileSizeKB` ([:437](utils/reposnapshot/rs.lts.sharding.psm1:437)), compared against `$maxSpanBytes / 1KB`. Float drift across thousands of files, and boundary behavior that isn't reproducible. The brief's "bytes, no KB" rename fixes the naming; the thing that actually matters is accumulating in `long` bytes.

Also worth knowing: `MaxFilesPerShard` defaults to 1000 in the module ([:279](utils/reposnapshot/rs.lts.sharding.psm1:279)) but the production call site passes 100000 ([RepoSnapshotLts.psm1:2360](utils/reposnapshot/RepoSnapshotLts.psm1:2360)) — i.e. it's disabled in practice. The brief took the call-site value as the default.

## So the decisions

The reframe is: there is one packing algorithm, and the question is what governs its cut points. Which leaves you these forks:

1. **Do the three names survive?** They're a vocabulary, not three implementations. Keeping `Greedy | Balanced | Loose` as a knob over one parameterized loop is entirely defensible — it's a user-facing surface with three understood meanings. The alternative is exposing the threshold directly (a fill fraction) and dropping the names. What I'd push back on either way: don't port three loops.

2. **Does Balanced stay a heuristic, or become real?** If order is fixed, "minimize the largest shard over contiguous runs" is exactly solvable — binary-search the threshold, O(n log n), no reordering, no magic 1.1. That would make Balanced mean what its name says while respecting phase 2. Keeping the 1.1 heuristic is fine too, but then it should be described as "a lower cut threshold derived from an estimated shard count," not load balancing.

3. **Does the quota now mean row bytes?** The brief says yes, and that's the right call, but note it silently changes what an existing `2048` means to anyone who tuned it — shards will hold fewer files at the same number.

4. **Header row in or out of the budget?** Still open from last turn, and now more concrete since the header may be per-group.

Which of those do you want to take first — or is there an aspect of the LTS design you're trying to retain that I haven't hit?

---

# see `D:\aghado01\science-facility\issues\reposnapshot\discussion\packing-strategies-details.md` for some answers on my thinking about packing, quota, and headroom. still need to standardize vocabulary, but i want the intent to be clear first

Read it. The truncation rationale is the piece that was missing — it changes what the quota _is_, not just what it's called.

## What the note settles

- Quota governs **written file bytes**: header row + every record row + all delimiters and terminators. Confirms seeding the accumulator with `Measure-HeaderRow` and confirms the move off LTS's content-bytes-only input.
- Greedy/Balanced/Loose are gone. Objective is **tightest packing**, not evenness. That kills the 1.1 and 0.8 constants and makes my "linear-partition to make Balanced real" suggestion moot — you don't want even shards, you want full ones.
- **Group containment is hard; order within a group is negotiable.** Inverts LTS's implicit priority, where the sort was baked in before packing ever ran.
- Flat is one group, not a special case.
- Binary units throughout.

Two things follow immediately. First, "fewest shards" and "least overhead" are the same objective here — the only variable cost is one header row per shard — so tightest packing has a single unambiguous meaning. Second, since the header row is inside the quota, **the header must be sized before packing starts**, which is only possible if the header is per-group. Your own "Flat is logically a single group" framing resolves the circularity I flagged last turn, at no cost.

## The one thing in the note that doesn't hold

**Tolerance applied unconditionally is arithmetically identical to a larger quota.**

Your rule reduces to: admit if `cumulative + candidate ≤ target + tolerance`. All three of your examples agree with that one form — the "quota remainder + headroom" phrasing is the same inequality rearranged. But if that test runs at every candidate, then every shard fills to `target + tolerance`, and the loop is indistinguishable from greedy with a quota of `target + tolerance`. Target becomes decorative; 32768/8192 is just 40960.

For tolerance to mean something, it has to be **conditional** — and the condition that makes it earn its name is anti-runt. Concretely: pack strictly to target; then if a group's tail shard is small, merge it back into its predecessor provided that keeps the predecessor within `target + tolerance`. Same numbers, same admission arithmetic, but the overshoot only ever happens to eliminate a fragment, never as routine fill. That also makes it the direct replacement for what Balanced/Loose were nominally for — smoothing the tail — except local, exact, and one rule instead of two constants.

The alternative is honest too: collapse to one number, accept that "tolerance" was a bigger quota, and drop the second knob. What I'd avoid is keeping two numbers that behave as one.

## What truncation-safety does to "soft quota"

The shards brief currently says `MaxShardSizeBytes` is soft — oversized shards exceed it "by convention." Under your rationale that's backwards: exceeding it is precisely the failure the quota exists to prevent, because a silently truncated read makes an agent conclude things from absence. So:

- The number that must sit under the reader's threshold is **`target + tolerance`**, not target. Whichever way the tolerance question lands, that's the ceiling, and it's the number worth declaring.
- An oversized shard (single entry over quota, atomicity preserved) is no longer a benign convention — it's a **reader hazard that has to be announced**. The plan already carries `IsOversized`; the tree manifest should say which shards exceed the safe read size and roughly by how much. That reads like a payload-manifest-ledger entry to me — same class as #8 (offsets need their unit) and #16 (compaction notice): a declaration that stops a reader drawing a wrong conclusion.

## On "work out the minimal packing"

Worth knowing before you invest in it: **with order enforced, the naive loop is already optimal.** If shards must be contiguous runs of the group's sequence, greedy-fill-until-it-doesn't-fit provably minimizes shard count — each greedy cut lands no earlier than any other solution's corresponding cut, by induction. There's no cleverness to add. Strict-order mode is done.

The cleverness only becomes available in **flexible mode**, where reordering turns it into genuine bin packing (NP-hard; first-fit-decreasing lands within ~11/9 of optimal and is fine at this n). One refinement I'd suggest: use FFD to decide _membership_ only, then restore the group's sort order _within_ each shard before rendering. You get the tighter packing without the payload reading in descending-size order, and global idx follows the plan as it already does.

A consequence worth noting: under Flat, the path-hash sort exists to disperse large files so no shard turns pathological. In flexible mode FFD does that job directly and better, so the hash sort collapses to a tie-break/reading-order device rather than a packing input. Flexible mode is most defensible exactly where the order is already arbitrary to a human — Flat — and least defensible under ByRootDirectory, where `RelativePath` order is the reason the payload reads like a directory listing.

## Deferred, but flagged

The note says the quota is on "shardfile total content bytes" and then defines it as header + rows — i.e. the whole file. That's the Size/Span distinction the container brief grades (`Size` bounds a container, `Span` measures content), and it's the historic confusion site. Not renaming anything yet, just marking that this quota is a **Size**, and `MaxBytesSpan` would name it wrong.

So the fork I'd want your call on: does tolerance become conditional (anti-runt tail-merge), or does it collapse into a single quota number?

---

# I don't agree that headroom is tantamount to a different quota. the semantics are different because we have a specific target, with some specified tolerance above that for making packing decisions based on other settings like whether or not order is enforced. I think one of the early stages in planning should be to enumerate all of the records regardless of which shard file they are in, so that we know the dataset up front. the "schema" of the header row is fixed at run time (non-negotiables TBD + optionals like the nested "attributes" block), which determines what goes into the rows as well as the header rows themselves, with number of header rows in the dataset determined by the number of shard files that resolve. things like the length prefix are byte spans of the prefixed content block for a given row, etc. so every record (one per ingested file) should be enumerated first, and then planning can work from there. and I think we can be more creative with packing algorithm

You're right and my claim was too narrow. The equivalence only holds for a packer that _admits_ sequentially — first thing under the bound goes in. The moment the packer **optimizes**, target and tolerance take genuinely different roles: target is the objective the arrangement aims at, tolerance is the feasibility bound that says what's admissible at all. Those are two different things being asked of two different numbers, and my proof collapsed them because I assumed the LTS loop shape. Enumerating up front is precisely what makes the optimizing packer possible, so the two moves in your note are the same move.

## Enumerate-first, and what it buys

Restating to check I have it: fix the header schema at run time (core columns TBD + optional blocks like `attributes`) → that determines every row's content → measure every record exactly, one per ingested file → _now_ you have the dataset. Packing works from that.

What that structurally changes:

- **Packing becomes a pure integer problem.** A vector of record sizes, a header size, a target, a tolerance. No IR, no entries, no content. Which means it's testable against synthetic size vectors — `[16384, 8192, 4096, …]` — with no repo, no ingestion, no fixtures. That's a much better seam than the brief's five-phase inline algorithm, where packing can only be exercised end-to-end.
- **The measured record list becomes a real intermediate**, not "references to entries." `{ entry; rowBytes }` × N. Worth naming in the contract, because it's the thing both the packer and any diagnostics consume.
- **Diagnostics come free before any packing decision**: size distribution, largest record, how many records individually exceed the quota. You know the shape of the problem before choosing how to solve it.
- **A lower bound you can measure against.** With Σ known, the minimum achievable shard count is `⌈Σrecords / (capacity − header)⌉`. Any packer's output can be reported against it, so packing efficiency is a measured number in the plan rather than an assertion. That's a better exit gate than "deterministic."
- **idx width falls out naturally** rather than as a trick to break circularity — the dataset is enumerated, so `EntryCount` is known before anything is arranged.

## One consequence worth catching now

"The schema of the header row is fixed at run time… with the number of header rows determined by the number of shard files that resolve" reads to me as: **one schema per run, N identical header rows, and you just count them.** If that's right it settles the question I raised two turns ago — the container brief's lean toward a per-shard header, and my per-group counter-proposal, are both off. One global schema, `headerBytes` a single constant, known before packing.

The cost is that it re-opens partial presence: with a global schema, an element present on 30% of entries must either become a column with an empty marker on the other 70%, or be excluded. The per-shard header was the escape from that choice, and fixing the schema per run closes it. That's a real trade and it belongs to the header/container thread, not this one — flagging it so it doesn't get lost.

## Where the creativity actually lives

With the dataset known and order enforced (contiguous runs), you can solve this exactly rather than heuristically:

1. **Minimum shard count** — greedy gives it, provably, and it _is_ tightest packing: total written bytes is Σrecords + k·header, so minimizing k minimizes overhead. Nothing to improve.
2. **Then arrange.** Among all partitions into exactly k contiguous parts, choose the one that best fits your target — minimize the largest shard, or minimize total deviation from target. Classic linear partitioning: binary-search + feasibility check, or DP over cut points. Cheap at this n.

That two-stage split is what makes your semantics real: **tolerance can lower k** (a wider feasibility band may admit a k-part solution that target alone wouldn't), and **target shapes the arrangement** within that k. Different numbers, different jobs, and the runt-tail problem dissolves without any special-casing — stage 2 redistributes it away, because k is already fixed and the mass has to go somewhere.

Flexible order is the same two stages with stage 1 becoming genuine bin packing (FFD, or exact for small groups) and stage 2 rebalancing fills. My earlier suggestion stands there: decide membership by size, then restore the group's sort order within each shard for rendering, so the payload doesn't read in descending-size order.

The fork I'd want your read on: in stage 2, is the objective **minimize the largest shard** (simplest, binary-searchable, compresses the distribution) or **minimize deviation from target** (aims at your number directly, needs DP)? They diverge when Σ sits well below k·target — minimize-max spreads evenly and undershoots target everywhere; minimize-deviation packs most shards near target and leaves the slack in one.

---

# i would implement both approaches for the sake of science, and possibly user preference. each may be valid depending on the user's needs/wants. perhaps exposed as a packing strategy enum

Both is right, and the 2×2 is genuinely all-meaningful. But I'd push against a flat enum — that's how LTS ended up with three names over one number. What you have is **two orthogonal axes**, and the enum should be presets that _resolve_ to them, not the primitive:

|                                             | **Ordered** (contiguous runs, sort preserved)             | **Free** (reorder within group)                   |
| ------------------------------------------- | --------------------------------------------------------- | ------------------------------------------------- |
| **Even** (minimize largest shard)           | linear partition — binary search + feasibility, **exact** | makespan / P‖Cmax — NP-hard, LPT ≈ 4/3            |
| **Target** (minimize deviation from target) | DP over cut points, **exact**                             | k-bin assignment minimizing deviation — heuristic |

Worth noting the asymmetry: Ordered isn't the conservative choice, it's the one with exact solutions. Free buys tighter fills and gives up guarantees. If you want the named vocabulary back, a preset resolving to `{Order, Objective, Fit}` fits the effective-config machinery you already have queued (ledger #11 — `{Name; Value; Source}`), so the plan records what the preset actually resolved to rather than just its name.

## Correcting something I said last turn

I claimed the runt-tail problem "dissolves" once k is fixed and stage 2 redistributes. That's true for **Even** and false for **Target** — and the distinction is the whole reason both are worth having.

Mass is conserved. With k parts, mean fill is Σ/k regardless of objective. Even compresses the distribution around that mean; Target pushes shards _to_ target and pools the remainder in one tail shard. So Target reintroduces the runt by design — that's what aiming at a number means.

Two consequences:

- **At k = k_min the two converge.** Minimizing k already forces mean fill near capacity, so there's little room to arrange differently. Target can't reach target when Σ/k already exceeds it.
- **They diverge when k is forced above minimum** — which is common: group fragmentation under `ByFileType` (a group with three `.yml` files is one small shard no matter what), the file-count cap binding, or many small groups generally. That's exactly where a group's Σ/k sits well below target and the objectives pull apart: Even gives you two shards at 60%, Target gives you one at 100% and a runt at 20%.

So the strategy choice is nearly inert under Flat and does real work under grouped configurations. Which is also where the reading experience matters most — a reader scanning `ByRootDirectory` shards notices ragged sizes.

## Strict vs tolerant is a third knob, and it's the one that decides k

Stage 1 minimizes k over some capacity. Which capacity is the strict/tolerant decision:

- **Strict**: capacity = target. Tolerance never lowers k; it only lets an individual record that overshoots target slightly be a normal member instead of triggering an oversized shard.
- **Tolerant**: capacity = target + tolerance. Tolerance can buy you a whole shard fewer — and then mean fill lands near target+tolerance, because that's what minimizing k means.

That's the honest statement of the trade, and it's why `target + tolerance` is the number that has to sit under the reader's truncation threshold, not target.

## For the sake of science

If you're implementing both to compare, the plan has to carry the metrics or you get two black boxes. Since packing is now a pure function over a size vector, you can run **all cells on one enumerated dataset** — stage 1 and 2 rerun, ingestion doesn't. That's a cheap, real experiment, and it belongs in the test battery as a comparison harness rather than in the shipping path.

Metrics that make the cells comparable:

- `ShardCount` vs `MinPossibleShardCount` = `⌈Σrecords / (capacity − headerBytes)⌉`
- fill max / min / mean / spread
- `ToleranceConsumedBytes` = Σ over shards of `max(0, size − target)`
- `ShardsOverTarget`, `OversizedCount`
- `HeaderOverheadBytes` = `k × headerBytes` — the actual cost of a worse k

That last one is the thing that makes "tightest packing" measurable rather than asserted: the entire penalty for k+1 shards is one header row plus whatever the truncation risk is worth to you.

---

We've now got a coherent packing design across four turns — quota semantics and the truncation rationale, enumerate-first, the two-stage formulation, three orthogonal knobs, and the comparison harness. None of it is in a document yet, and the briefs still say Greedy/Balanced/Loose. Want me to write it up as a design note under `issues/reposnapshot/design/` — intent and mechanics, placeholder names flagged as unsettled — before we move to the next thread?

---

# yea scribe it up

Before I write anything — the decisions ledger already has a **Shard packing** section, entries #40–#47 dated 2026-08-16, citing `shards-brief §Objective / §Policy stack / §Algorithm / §Vocabulary / §Roadmap`. None of those sections exist in the brief I read. Let me reconcile before scribing.
The on-disk state has moved since my turn-1 read — the brief has been rewritten (`§Objective`, `§Policy stack`, `§Algorithm — the cascade`, `§Calibration`) and the ledger's packing section #40–#47 already settles much of what we just re-derived. Reading the current brief before I write anything.
The brief already carries this design — it was rewritten on 2026-08-17/18 with `§Objective`, `§Policy stack`, the eight-stage cascade, and calibration against the 0422 payload, and the ledger settled it as #40–#47. So rather than a parallel design note that would duplicate and drift, the thing actually missing is your call from this turn: clause 2 is currently _fixed_ at Σ overshoot with alternatives noted as "a one-line swap." I'll scribe the delta into the brief and the ledger.
The file is being edited concurrently — re-reading before the remaining edits.
All hunks in the diff are mine — the brief's rewrite was already committed, so my changes sit cleanly on top.
Scribed and committed as [22fb6cc](issues/reposnapshot/briefs/shards-brief.md).

**What I found first:** the brief on disk is not what I read at the top of this session. It was rewritten on 2026-08-16/17 — `§Objective`, `§Policy stack`, an eight-stage cascade, calibration against the real 0422 and ThermoMapper payloads — and ledger #40–#47 already settle most of what we re-derived over the last four turns, including the tolerance-vs-quota distinction (#41) and the two-stage formulation (#44). A prior session covered turns 1–3 of this conversation almost verbatim and died at the point where you pointed me at the example tree file; its transcript is `discussion/opus-export-packing-discussion.md`.

So a new design note would have duplicated settled material. I wrote the actual delta instead — your call from this turn, which the brief had explicitly left as a constant with a note saying "a one-line swap if the call changes."

**Into the brief:**

- `§Objective` clause 2 becomes `PackObjective = MinOvershoot | MinMaxFill`, both implemented, with the justification I worked out this turn: **they diverge exactly where `MinOvershoot` goes indifferent.** Once any zero-overshoot arrangement exists — which the brief's own calibration shows is the common case — every such arrangement scores identically and the tie-break silently picks the shape. `MinMaxFill` keeps discriminating.
- Mass-conservation note: with `k` fixed by clause 1, the objective chooses the distribution, never the total. They nearly agree at `k = LB` and part when `k` is forced up — small `ByFileType` groups, count cap binding.
- An asymmetry worth flagging: **`OrderStrict` is exact for both objectives** (DP for overshoot, binary-search linear partition for max-fill) while flexible is LPT-approximate. So `MinMaxFill` produces a _more_ even payload under strict order. That inverts the usual "flexible dominates" expectation and makes strict a real choice rather than a concession.
- Knob roster gains `PackObjective`, with a note that these are orthogonal axes rather than a flat enum — a named preset is fine provided the plan records what it resolved to. That's the LTS lesson written down where it can't be re-learned.
- Contract gains `MaxFillBytes` / `MinFillBytes` / `HeaderOverheadBytes`; stage 6 gains the objective pass; exit gate gains an objective-honored check (brute force on small vectors), a synthetic vector where the two provably disagree, and the four-cell comparison harness — both objectives × both order modes over one enumerated dataset, in the battery rather than the shipping path.
- Open calls now record that the shipped default is deliberately unsettled until that harness runs on real payloads.

**Into the ledger:** #48, with #40 amended to point at it.

One thing I'd flag rather than fix: `§Objective` is now the longest section in the brief, and the "why both" reasoning is doing work that arguably belongs in the discussion doc with only the call in the brief. If you want the brief tighter I can move the divergence argument out and leave the table plus a pointer.

---

# <command-name>/model</command-name>

            <command-message>model</command-message>
            <command-args>claude-fable-5</command-args>

---

# <local-command-stdout>Set model to claude-fable-5</local-command-stdout>

---

# "They diverge when k is forced above minimum — which is common: group fragmentation under ByFileType (a group with three .yml files is one small shard no matter what), the file-count cap binding, or many small groups generally. That's exactly where a group's Σ/k sits well below target and the objectives pull apart: Even gives you two shards at 60%, Target gives you one at 100% and a runt at 20%." in what sense is k forced above minimum if our goal is packing as much as posible given constrains

In no sense — that phrase was wrong, and your question pulls on the right thread. Let me correct it and follow where it leads.

## The correction

Clause 1 already guarantees `k = k_min` under the constraints (bytes, ceiling, count cap). Nothing is ever "forced above minimum." What I was gesturing at is **slack**: `Σ_g` is almost never an exact multiple of capacity, so at `k_min` there is a remainder — strictly less than one shard's worth — that has to land somewhere. The divergence between shapes is _entirely_ about where that remainder goes, and it exists at every `k_min ≥ 2`, not in some special "forced" case.

The `.yml` example was worse than sloppy: three small files → `k = 1` → exactly one arrangement → no divergence at all. The count-cap example survives only if you read it as "the minimum is set by count rather than bytes, so byte-slack is large" — k is still the minimum.

## What your question actually exposes

"Pack as much as possible" names a specific shape: **fill each shard to quota, in order, remainder in the tail.** Greedy. Full shards plus one runt.

That is not `MinOvershoot`. Check the arithmetic: at fixed `k` and `Σ_g`, `Σ max(0, size_i − quota)` is Schur-convex — the flattest arrangement always minimizes it. If the mean fill is under quota, every under-quota arrangement ties at zero and the flattest is among them; if the mean is over quota, total excess is fixed at `Σ_g − k·quota` and the flattest achieves it exactly. So `MinMaxFill` (with a lexicographic tie-break) is a _refinement_ of `MinOvershoot`, not an alternative — the two I scribed are near-identical, both even-ish, and can only differ by discreteness slop. Neither of them is the greedy shape you just described.

The real pair is:

- **Front-loaded** — fill to quota in order; remainder as the group's tail. Contiguous: literally greedy at quota. If greedy-at-quota gives more shards than greedy-at-ceiling, spend tolerance to absorb the last shard backward into predecessors — which is exactly the brief's "greedy-at-quota + adjacent merge" open call.
- **Even** — spread the remainder; minimize max fill. Contiguous: linear partition, exact — the brief's "greedy-at-ceiling + DP."

So the brief already contains both objectives; it just listed them as competing _procedures_ for one objective. And `MinOvershoot` isn't a shape at all — it's a constraint both should honor: spend the least tolerance consistent with the chosen shape.

## Where they diverge, corrected

Same `k`, always. Front-loaded: `k−1` full shards + one runt of size `remainder`. Even: `k` shards at `Σ_g/k`. At large `k` the runt is small relative to the payload; at small `k` it's conspicuous — a group of two shards at 100% and 5% versus two at 52%. Under `ByFileType` with many small groups you get many small `k`s, which is why grouped payloads are where the choice shows.

## What I'd amend

`PackObjective = FrontLoad | Even` (names placeholder), with "least tolerance spent within the shape" as a stated invariant rather than a value; the strict+tolerance open call closes because its two candidates _are_ the two objectives; ledger #48 rewritten. `MaxFillBytes` / `MinFillBytes` still the right diagnostics.

Want me to make that pass on the brief and ledger, or is there something in the front-loaded shape you'd define differently first?

---

# "why both" goes into the decision ledger. and yes about minovershoot, but don't forget the overarching policy with exception cases to allow exceeding quota + tolerance for anti fragmentation purposes

Rewriting `§Objective` tight — the call and the invariants only; the "why both" argument moves to ledger #48.
Now the ledger — #48 rewritten to carry the "why both" argument, and #40/#44 amended.
Done — [a98843f](issues/reposnapshot/briefs/shards-brief.md).

**Brief** — `§Objective` is now short and ordered the way the policy actually stacks:

- **Overflow first, above every clause.** A record whose row alone exceeds the ceiling gets its own shard at any size; that shard is outside quota, tolerance, and every objective term, and is declared to the reader. Atomicity is the anti-fragmentation guarantee; the numbers govern only the packable set. Also added as an exit gate: an oversized shard is present under both shape values with identical `PlannedSizeBytes`.
- Clause 1 fewest shards (unchanged, always the minimum).
- Clause 2 **shape**: `PackObjective = FrontLoad | Even`. `FrontLoad` = fill to quota in nominal order, remainder as the group's tail; contiguous procedure is greedy-at-quota + adjacent merge. `Even` = lexicographic min-max; contiguous procedure is linear partition. Both exact under `OrderStrict`.
- Clause 3 least tolerance spent — an invariant both shapes honor, not a value.

The 08-16 "strict + tolerance procedure" open call closes as a side effect: its two candidate procedures _were_ the two shapes. One new open call replaces it — under flexible order, which bin absorbs a forced-merge tail.

**Ledger #48** carries the "why both" argument in full: why a shape knob at all (remainder placement, not k), why not `MinOvershoot` (Schur-convexity makes it a dominated constraint), why the old open call closes, and the exactness inversion that makes `OrderStrict` a real choice. #44 amended and its "proposed" status closed. #40 still points to #48.

Working default is `FrontLoad`, matching your "pack as tightly as possible" — but flagged as a placeholder until the comparison harness runs on real payloads.

---

# also remind me why its called 'min/max fill' instead of just "max fill", and im not sure about "minovershoot". i thought we were just calling that tolerance?

Both fair — and both are the vocabulary-standardization pass you said was still owed.

**"min-max fill."** It's the optimization term: _minimize the maximum_ — the shape whose objective is "make the biggest shard as small as possible." The "min" is load-bearing because "max fill" alone reads as its opposite (_maximize_ fill = pack full = FrontLoad). But the knob value is now `Even`, so "min-max" only survives as the description of what `Even` optimizes, and it doesn't need the jargon: _minimize the largest shard, then the next, and so on_ says it plainly. I'd drop "min-max" from the brief on the next pass and leave the term to #48 where the math lives.

**"MinOvershoot" vs tolerance.** They're the same axis at two levels — a budget and a spend:

|                             | knob (bound)          | measurement (actual)                           |
| --------------------------- | --------------------- | ---------------------------------------------- |
| bytes a file may hold       | `ShardQuotaBytes`     | fill — `PlannedSizeBytes`                      |
| bytes above quota permitted | `ShardToleranceBytes` | overshoot — `max(0, PlannedSizeBytes − quota)` |

_Tolerance_ is what you're allowed; _overshoot_ is what a shard actually used of it. `SumOvershootBytes` in the plan is total tolerance consumed. `MinOvershoot` was the name for "spend the least of it" as an objective — retired this morning to clause 3, and now appears only in #48 as the name it _isn't_ called.

If the two-word split still feels like one thing wearing two names, the cleaner fix is to name the measurement after the knob it draws from: `SumOvershootBytes` → `ToleranceSpentBytes`, per-shard `OvershootBytes` → `ToleranceSpentBytes`, and clause 3 stays "least tolerance spent." Then "overshoot" disappears from the surface entirely and the pairing quota/fill, tolerance/spent is visible in the names. I lean toward that. Want it in the same pass as the min-max wording?

---

# "tolerance spent" feels off. tolerance is a per-shard-file property. its the wiggle room allowed for the optimizers to consider candidates for packing underutilized shards

Agreed — that's a better statement of it than mine, and it kills the "spend" framing outright: tolerance is a **per-shard bound**, not a pool that draws down. Two shards each going 3 KB over quota haven't "consumed 6 KB of tolerance"; each independently sat within its own wiggle room. So "spent"/"consumed" is wrong at the root, and the measurement shouldn't be named after the knob at all.

That leaves **overshoot** as the right word for the measurement — plainly "bytes over quota," per shard, with `overshoot ≤ tolerance` as the invariant. Clause 3 becomes "least overshoot within the shape." Let me scrub the spend language.
Committed as `6a81589`.

**Vocabulary now:**

- **tolerance** — the knob; a per-shard bound. Wiggle room the optimizer may use when considering candidates for an underutilized shard. Each shard independently may reach `quota + tolerance`; nothing is drawn down across shards.
- **overshoot** — the measurement; how far a given shard sits above quota, always `≤ tolerance`. Same relation as quota → fill.
- Clause 3 is "least overshoot within the shape." Every "spent" / "consumed" is gone from brief and ledger, and #48 records the reason so it doesn't creep back.
- "min-max" is gone from the brief — `Even` now reads "minimize the largest shard, then the next largest, and so on." The term survives only in #48, parenthetically, as the optimization name.

One residual: `SumOvershootBytes` in the plan/group contract still sums a per-shard measurement across shards. That's a legitimate diagnostic (the harness compares it across cells), but if the sum-of-a-per-shard-property reads as pool-thinking creeping back, `MaxOvershootBytes` per group would be the purer number. Left as is; flag if you want it changed.

---

# max vs sum are speaking to tolerance vs overshoot. "Total Overshoot" could be the diagnostic

Right — the max is the _tolerance-facing_ number (the bound check: `MaxOvershootBytes ≤ ShardToleranceBytes` is exactly the invariant), the sum is the _overshoot-facing_ aggregate. Both belong in the plan; they answer different questions. Renaming `Sum` → `Total` and adding the max.
`795d1a9`. Plan and group now carry both, labeled by which side they face:

- `MaxOvershootBytes` — tolerance-facing; the exit-gate check is literally `MaxOvershootBytes ≤ ShardToleranceBytes` (and `== 0` when tolerance is 0).
- `TotalOvershootBytes` — overshoot-facing; the clause-3 aggregate and the harness column, explicitly _not_ a bound.

Every `Σ overshoot` / `SumOvershootBytes` in brief and ledger is renamed, and #48 records the split so the naming rationale travels with the decision.

Packing thread is scribed and coherent end to end now: quota/tolerance/overshoot vocabulary, enumerate-first, overflow above the objectives, `FrontLoad | Even` with least-overshoot as the invariant, the four-cell harness. Next thread whenever you're ready — the header schema question (per-run vs per-shard, partial presence) is the one the packing design leans on hardest.

---

# the comparison should be (total bytes - (quota + tolerance) ) or something, where a negative number means overpacked, a number > quota and < (quota + tolerance) is overshoot

Yes — a signed, unclamped number per shard is better than `max(0, ·)`, because the clamp throws away the underfill side, and both shapes' behavior lives on that side. One thing to settle: the anchor.

Anchoring at the ceiling (`size − (quota + tolerance)`) merges two regions you want apart — "under quota" and "in the tolerance band" are both negative, and you'd need tolerance again to split them. Anchoring at **quota** separates all three with tolerance as the only threshold, and keeps sign aligned with the vocabulary (overshoot is positive):

```
DeviationBytes = PlannedSizeBytes − ShardQuotaBytes        # signed, per shard

  < 0                  underfilled — slack; the remainder lives here
  0 … tolerance        overshoot — in band, tolerance honored
  > tolerance          beyond ceiling — Oversized only, by construction
```

`OvershootBytes = max(0, Deviation)` and `SlackBytes = max(0, −Deviation)` both derive from it, and so does `Class` (`Oversized ⇔ Deviation > tolerance`; `InBand ⇔ 0 < Deviation ≤ tolerance`), which is tidier than carrying the classification as a separate fact. Writing it in.
`3327ce8`. Per shard, `DeviationBytes` is now the stored fact — signed, anchored at quota — with `OvershootBytes` / `SlackBytes` / `Class` all derived from it, and the classification bands rewritten in deviation terms (`≤ 0` Singleton · `0 < d ≤ tolerance` InBand · `> tolerance` Oversized). Plan and group gain `TotalSlackBytes` — the remainder, wherever the shape put it — and a mass-conservation gate ties slack and overshoot to `k·quota − Σ size`, so the two aggregates can't drift apart.

If you meant the ceiling anchor deliberately — say so and I'll flip it — but I read your "negative = overpacked" as the sign coming out backwards from the ceiling frame, and the quota anchor is the one where the sign matches the words.

---

# ok so considering the redesign we've been doing and dangling items from earlier, what's left and what might dissolve on account of the upstream design changes we just worked through

Here's the ledger of what's left, sorted by what today did to it. A lot moved between my turn-1 read and now — the container brief **landed 2026-08-17** (`rs.core.container.psm1`, 70 asserts) and contracts were minted for serialize/manifest — so I've checked each item against disk rather than memory.

## Dissolved by today's packing redesign

| item (turn 1–2)                                                      | why it's gone                                                  |
| -------------------------------------------------------------------- | -------------------------------------------------------------- |
| Balanced can breach the quota gate; brief dropped LTS's max backstop | Balanced doesn't exist                                         |
| ×1.1 / ×0.8 constants — keep or re-derive                            | gone with the names                                            |
| Confirm Flat sort key against LTS                                    | confirmed at source (`Get-PathHash`), now the `GroupSort` knob |
| `AllowOversizedShards` default inversion                             | switch retired — overflow is policy, above the objectives      |
| Anti-fragmentation as property vs knob                               | subsumed: atomicity structural, overflow outranks every clause |
| "Soft quota" language                                                | ceiling-with-carve-out; oversized = declared hazard            |
| Header row missing from the packing accumulator                      | capacity = `quota − headerBytes` throughout the cascade        |
| Strict+tolerance procedure (DP vs adjacent merge)                    | closed — they were the two shapes                              |
| My "tolerance ≡ bigger quota"                                        | retracted; ledger #41                                          |
| My per-group header counter-proposal                                 | dissolved by per-run schema                                    |

## Resolved by the 08-16/17 revision I hadn't seen (verified on disk)

- Per-shard header circularity → schema fixed per run, `headerBytes` one constant; container brief marks (c) superseded, partial presence resolved by **empty marker per row** (`psr.header.json` declares it).
- Row terminator → #45, LF only, no trailing `|`, UTF-8 no BOM; already in the container brief.
- Fixed-width idx as a container decision → #46 rule; `idx` optional.
- "Two functions, one table" aspiration → landed: `Measure-ContentSpan` == `ConvertTo-ContentSpan` across a surrogate/terminator/control battery; LS/PS in the rule regex.
- "Plan = file" gate at container level → in `container.tests.ps1`.
- No `rs.core.container` stub / name open → landed. **The shards brief still lists "layout module name" as an open call ([:407](issues/reposnapshot/briefs/shards-brief.md:407)) — stale, strike it.**
- Receipt has no schema → `serialize.contract.json` + `manifest.contract.json` exist.
- `ColumnHeader` misidentified → manifest contract says "from the resolved header row, not a hardcoded string." Fixed in the _contract_, not the code.

## Still standing — and what today added to each

**1. `shards.contract.json` is now stale against the brief.** It still says `SumOvershootBytes` and has none of `PackObjective`, `DeviationBytes`, `SlackBytes`, `TotalSlackBytes`, `MaxOvershootBytes`, `MaxFillBytes`/`MinFillBytes`, `HeaderOverheadBytes`. That's the direct debt from this session; it should be updated before `rs.core.shards.psm1` (0 bytes) is written against it.

**2. `rs.core.manifest.psm1` is still a byte-copy of the LTS template** — the contract says so in its own header. Every turn-1 audit item stands: stale QUEUED note (cipher key / preserve stance), "seek in the .json file" instruction, dead monolith surface, `WriteMetadataBlock`/`ExcludedShardBlocks` never read by the template, caller-formatted `SummaryLine` naming dropped knobs, `.psm1` with no exports. Today _sharpened_ two: the `shard_index` collision is now formal (#46: sidx = filename ordinal ≠ `IdxMap.ShardIndex` = position within shard), and the manifest now has more to declare — oversized shards with sizes (hazard), shape/quota/tolerance in the summary, and Class per shard.

**3. Payload-manifest-ledger owes the oversized-hazard entry.** #42 and the manifest contract both cite it "same class as #8/#16"; the ledger itself stops at #17 with no such row.

**4. `rs.core.serialize.psm1`** — 0 bytes, contract minted, container primitives ready. Nothing today changed its shape.

**5. Shards brief open calls that survive today:** `FrontLoad` under flexible order when a merge is forced (which bin absorbs); shipped default pending the harness; `FrontLoad | Even` as house vocabulary + whether a preset layer exists; fail-fast switch for oversized as a diagnostic gate; entry references vs copies.

**6. Container thread, untouched today:** core columns "always" vs the LTS-parity gate (still both in the container brief, [:70](issues/reposnapshot/briefs/shard-container-brief.md:70) vs [:246](issues/reposnapshot/briefs/shard-container-brief.md:246)); which address columns v3 carries (#46 open). `psr.header.json` may already answer these — I haven't read it.

**Sequencing that falls out:** contract refresh → shards module + synthetic-vector suite + harness → serialize → manifest rewrite. Manifest last is right (it consumes both), and the payload-ledger row is a five-minute fix I can do now.

Want me to take #1 and #3 now — refresh `shards.contract.json` to the brief and file the ledger row — since both are pure consequences of decisions already made?

---

# 5. shard brief, i dont want those enum presets. tolerance semantics replace that. those old profiles in LTS i never really liked

`99e886c`. Presets are out — the knob roster row and #40 now say so explicitly ("no preset/profile layer over the knobs; quota + tolerance semantics are the whole surface"), the open call is reduced to just the `FrontLoad | Even` naming, and I struck the stale layout-module-name call while in there.

That leaves the open-call list at: `FrontLoad` forced-merge absorption under flexible order · shipped default pending harness · value names · fail-fast oversized gate · references vs copies · propagation check to the container brief.

Shall I do the two mechanical consequences now — refresh `shards.contract.json` to the brief's current contract, and add the oversized-hazard row to the payload-manifest-ledger?

---

# isn't frontloat redundant with the packing strategy knobs we already discussed

Yes. Look at what `FrontLoad` says: fill to quota in order, remainder as the tail, tolerance used only to absorb a tail into underutilized predecessors. That is not a choice — it's a restatement of what quota, tolerance, and `OrderStrict` already mean. Under strict order it's literally the stage-5 greedy baseline. `FrontLoad` is the null shape: what the packer produces when you don't add a step.

`Even` is the only thing on that axis that's actually a _decision_ — a post-pass at fixed `k` that redistributes the remainder. So `PackObjective` is a boolean wearing an enum: `Even` on or off, and the "off" value got a name it doesn't need. Same disease as the profiles, one size smaller — a name over the default behavior.

Two honest ways to land it:

- **Switch.** `-EvenFill` (name TBD), default off. Off = the knob semantics as written, no shape vocabulary anywhere. On = spread the remainder (linear partition under strict, LPT under flexible). Clause 3 stays an invariant. The harness becomes two rows, not four: with vs without evening, × `OrderStrict`.
- **Roadmap.** Drop `Even` from v1 entirely. It's what LTS "Balanced" claimed to be and never was, and it's the one piece of the packing design that exists for a reader preference nobody has expressed yet. Reinstate if a real payload shows ragged grouped shards someone minds.

I lean **switch** — it's cheap (both procedures are already specified), it doesn't touch the default path, and "does spreading the remainder buy anything a reader notices" is a question the harness can answer only if the switch exists. But your instinct against the profiles is the same instinct that's flagging this, and roadmap is the purer answer to it.

Which — and I'll rewrite §Objective clause 2, the knob roster, ledger #48, and the harness accordingly. It shortens all of them.

---

# so i just spent a few hours rewriting the psr.header.json because the old version was absolutely mind boggingly bad. like how is such slop even possible? its not done yet but please take a look `D:\aghado01\science-facility\utils\reposnapshot\reposnapshot-v3\schema\psr.header.json` at how i'm making things self-documenting and self-evident without a bunch of manifesto and pseudocode in a schema file

Read it, and diffed against the c2e2a65 version so I know what you're reacting to. The old file was ~40% `$comment` prose — doctrine, rationale, "do not 'fix' this" — in a file the code walks. That's an agent pattern (those commits are session work), and it's the wrong place for it: doctrine goes in the brief/ledger, the file declares. Your instinct is right, and the shape you're building toward is better. Here's what I see, in order of consequence.

## The one thing that changes what "done" means

**`Resolve-Layout` reads this file.** [rs.core.container.psm1:189–260](utils/reposnapshot/reposnapshot-v3/rs.core.container.psm1:189) does `ConvertFrom-Json` and walks `format == 'psr'`, `framing.empty_marker`, `columns{}` keyed by name, and per column `type / width / source / fields`. Your rewrite renames the root keys and moves columns under `row_schemas.header_row_schema.items[]` — so the 70 container asserts go red the moment it parses (and today it doesn't parse: `//` comments, a trailing comma after `"bom": false`, a missing comma at `…materializing""source"`, and `content_bytes`/`content` have landed _inside_ the `content_meta` object after `defaults` rather than as siblings). None of that is a criticism of a WIP — but it means the file and `Resolve-Layout` are one change, not two. Either the walker moves to your shape (fine, it's ~30 lines) or the declaration stays walkable. Worth deciding before you polish further, because it decides how much structure the file can afford.

## The design point — you're most of the way to it

The best move in the new file is **record binds to header by reference**: `"required": "header_row_schema.gidx.required"`, `"type": "header_row_schema.content_meta.items[3].type_name"`. That expresses "one declaration, two products" _in the data_, which the old file could only assert in prose.

Take it all the way. Your own inline note asks whether the record items should be "unpacked programmatically based on the header metadata" — yes, and the file already proves why: the eight `content_meta` sources are listed **twice**, and the record row's items are in a **different order** than the header's (`path` then `gidx` vs `gidx` then `path`), with two descriptions swapped between them. That's the drift the file exists to prevent, appearing in the file. If `source` and the value `pattern` move onto the header column items — where `source` already lives for content_meta — then `record_row_schema` reduces to one line: _same items, values per `source`, rendered per `type_name`, no names_. Nothing left to drift.

## What's missing that has to be data, not comments

The old file buried these in prose; the new one drops them, and the container can't render bytes without them:

- field delimiter `|`, record terminator `\n`, empty marker (nothing between delimiters)
- block open/close `{ }` and the **sub-field delimiter** — your `construction` and record pattern say `;`; LTS and the old declaration say space (`{594 69 0.1414 4.6930}`). If that's a deliberate change, fine, but it's a wire change and should be visible as one key, not inferred from a regex.
- float precision / formatter (`4 decimals, invariant culture`)
- **width rule on `gidx`** — `digits(EntryCount)`. Fixed-width is ledger #46 and `Resolve-Layout` needs it; the record pattern `^[0-9]{4}$` hardcodes a width the plan computes.

Six or seven keys under `properties`. That's the whole framing spec, and it's shorter than one of the old `$comment`s.

## Nits, all fast

- `type: "string"` on every column carries nothing (everything is text on the wire) and half-wears the JSON-Schema costume while `type_name`/`source`/`construction` are your own vocabulary. Pick one: it's a declaration with a small vocabulary — say so in the description and drop `type`, keep `type_name` (or just call it `type`).
- `num_lines` ← `LineStats.Mean` — a mean isn't a line count (and it's typed `int`). Probably `LineStats.Count` or whatever the processor names it.
- Record `content` item: `type: header_row_schema.content_bytes.type_name` — should be `.content.type_name`.
- `"version": "0."` — unfinished.
- Header `pattern` — the description says the format is one physical line per row, so the pattern shouldn't need to hedge on newline flavors; ledger #45 makes it `\n` strictly. Your own note says revise; I'd resolve it toward strict since upstream guarantees it.
- `content` description says "idiomatic C-style escape sequence substitutions" — the codec SPEC is narrower (line breaks → `\n`, controls stripped, `\` never doubled). "C-style" over-promises `\t`, `\\` etc. Say "line breaks encoded as `\n`; see codec."

The approach is right and the file will be a fraction of the old one's size when it's done. Want me to (a) do the `Resolve-Layout` walker change against your shape once you call it stable, or (b) draft the `properties` framing block and the collapsed record schema for you to react to?

---

# right and there are still some empty fields. i still have to fill out the idiomatic patterns expressed as regex, im hoping those can be parsed intelligibly in a render loop to give the shape they describe. im trying to not have pseudocode in the json file. I also don't think we need float precision. i'm fine with fixed precision double at 2-3 decimal points and fixing the width accordingly

On the regex-as-shape idea — I'd push back before you sink hours into it. A regex is a **recognizer**, not a generator. It can tell you a rendered row is well-formed; it can't tell a render loop _how_ to produce one, except for the trivial subset (literal segments + fixed-width digit classes), and the moment you have optional columns, a repeated block, or a variable-width path, the regex is either too loose to render from or so structured it _is_ pseudocode — just in a harder syntax. And you'd have two things that must agree: the pattern the renderer parses and the row it emits.

The clean inversion: **the layout data is the source; the regex is a product.** Framing constants + per-column `{name, type, precision?, width?, source, presence}` are exactly enough to render, and from those same fields a validator can _derive_ the pattern for the header row and each record row mechanically. Regex becomes something the tests build and check, not something the file authors. That's zero pseudocode, one source, and the "self-evident" property you want — a reader of the file sees the row's shape as a column list, which is what it is.

On precision: agreed, no knob — but it's still one constant the renderer needs, so it's a single key, not prose. `type: double, precision: 3` on the column (or once under framing if all doubles agree). Two consequences worth noting:

- **Doubles become fixed-width for free.** Ratios in `[0,1]` at 3 decimals are always `0.414` — 5 chars; entropy `< 10` is `4.693` — 5 chars. So the block's double sub-fields are constant width without padding.
- **Don't extend that to the ints.** `num_chars`/`num_words` vary by orders of magnitude, and padding them means zeros a reader has to look past. The fixed-width rule (#46) exists for _position-dependent_ fields — `gidx` is assigned after packing, so its width has to be known before. Content-derived ints are known at measure time; they don't need it. Same rule, correctly scoped.

Net effect on the file: `properties` gets ~6 framing keys; each column is five or six plain fields; `record_row_schema` collapses; the only regexes anywhere are the ones you _want_ as data — `path`'s allowed-character rule, maybe — and even those are validation, not shape.

Two open questions I can't answer for you: is the block sub-field delimiter now `;` (your pattern) or space (LTS)? And does the header row carry precision in the type annotation (`ws_ratio<double:3>`) or just `<double>`? The first is a wire change; the second decides whether a reader can know the width from the header alone.

---

# no, but the regex is a clear spec for what is permissible. it shoudl be possible to decode it and it is a configuration item

Fair — I argued against the wrong thing. A single row-level regex generating structure is a bad idea; **per-column value patterns** as the permissibility spec are a different animal, and that's what your file actually has. Those are decodable, provided the subset is disciplined. Concretely:

**What makes a column pattern decodable**

- **Anchored, one class, explicit quantifier.** `^\d{4}$`, `^\d+$`, `^\d\.\d{3}$`, `^[A-Za-z0-9_./-]+$`. The render loop doesn't interpret regex in general — it reads _shape_ from a tiny recognized subset: `{n}` → fixed width n · `+` → unbounded · `\d\.\d{k}` → precision k · a char class → allowed alphabet (validation only, nothing to render). Anything outside that subset is a declaration error, not something the loop guesses at.
- **Precision lives in the pattern.** `^\d\.\d{3}$` _is_ "double, 3 decimals, ratio-shaped" — you don't need a `precision` key at all. `^\d{1,2}\.\d{3}$` for entropy. That's the config item, and it's readable by a human as a shape.
- **Run-resolved widths are a slot, not a literal.** `gidx` can't be `\d{4}` in the file — the width is `digits(EntryCount)`. Either `^\d{gidx_width}$` with the layout substituting once per run, or the column carries `width: digits(EntryCount)` and the pattern is derived. The first keeps regex as the single spec; the second is one more key. Either way the value is decided at enumerate, not authored.

**Row and header patterns are composed, never authored.** Row = `column.pattern` fragments joined by the framing delimiter literal (`|`), the block likewise one level down with its own delimiter, terminated by `\n`. Optional columns just drop out of the join — no combinatorial patterns, no `header_row_schema.pattern` to maintain by hand. And `content` is last and framed by `content_bytes`, so the composed row pattern is a _validator of shape_, not a splitter — it never has to disambiguate `|` inside content.

**What stays a literal config item, outside regex:** the delimiters, the block braces, the terminator, the empty marker. Those are the join glue and they're what let column patterns compose; putting them _in_ patterns means escaping and duplication.

Under this, `record_row_schema` collapses completely — the record row is the header's column list with values, and its pattern is derived. Your file's structure already fits: each header column carries `pattern`; the two things to fix are the empty ones and moving `source` up onto the same items.

Two questions still yours: block sub-field delimiter — `;` or space? And does the header annotation carry the shape (`ws_ratio<0.000>` / `<double:3>`) or just `<double>`?

---

# i also made changes to fields and field names, there's alot of back-port/adaptation to be made based on tehse revisions once its done

Understood — and now I can size it, because I pulled the old column table and what `rs-content_meta` actually emits. The back-port has three layers, and one of them isn't a rename.

## Layer 1 — the source paths must match a real processor

Your new file cites four sources the processor **doesn't produce**:

| new sub-field       | cited source                   | processor emits                                                   |
| ------------------- | ------------------------------ | ----------------------------------------------------------------- |
| `num_lines`         | `ContentMeta.LineStats.Mean`   | `LineStats.{Mean, Median, StdDev, Max}` — **no line count**       |
| `cardinality_words` | `ContentMeta.UniqueWords`      | not computed                                                      |
| `punct_ratio`       | `ContentMeta.PunctuationRatio` | `PunctuationCount` (a count)                                      |
| _(dropped)_         | —                              | `CompressionRatio`, `SpanBytes`, `LineStats.*` no longer declared |

So this is a redesign of the _content_meta element_, not just its wire names — `rs-content_meta.ps1` grows `LineCount`, `UniqueWords`, `PunctuationRatio` (and its 4-decimal rounding becomes 3 to match your precision call). That's the right order of dependency: the declaration says what the payload carries, and the processor is adapted to supply it. But it's a processor change plus its test suite, and it needs to happen _before_ the container can be re-pointed, or the sources dangle.

## Layer 2 — the walker (`Resolve-Layout` / `Format-Value` / `Resolve-SourceValue`)

Everything the code keys on has moved:

- root: `format == 'psr'` → your `name`; `framing.*` → your `properties` (which currently lacks delimiter, terminator, block braces/delimiter, empty marker); `columns{}` keyed by name → `row_schemas.header_row_schema.items[]`
- type vocabulary: code switches on `int | float | str | block` — yours is `int | double | string | array`
- source prefix: code accepts `entry.*` — yours is `record.*`; `codec.text` for content is now `""`
- gidx width rule `digits(EntryCount)` — nowhere in the new file (needs the slot we discussed)
- sub-field admissibility is validated against the declaration's list — new names throughout

~30–40 lines in [rs.core.container.psm1:189–315](utils/reposnapshot/reposnapshot-v3/rs.core.container.psm1:189) plus `Format-Value`. Mechanical, but it can't start until Layer 1 is fixed and the file parses.

## Layer 3 — everything downstream that names fields

`container.tests.ps1` (44 name references — including the "value walk of every source against a real entry", which is the test that will catch Layer 1), `container.contract.json`, `serialize.contract.json`, `manifest.contract.json`, the shards brief's `Measure-Row` formula (`attr_block` → block), and the LTS-parity exit gate in the container brief (the LTS column set was `char_count word_count whitespace_ratio entropy` — your `defaults` are close but not identical; that gate needs restating or retiring).

## Sequencing I'd suggest

1. Finish the declaration (framing keys, empty patterns, `source` up onto header items, drop the record duplicate).
2. Adapt `rs-content_meta.ps1` to emit exactly what the declaration sources — new fields, 3-decimal rounding — with its tests.
3. Re-point the walker; container tests go green again on the new names.
4. Contracts + briefs catch up.

Not a small pass, but a linear one, and step 2 is the only part with design content — the rest is renaming under test cover. Do you want me to hold until the declaration is stable, or take step 2 now against the sources as they stand (assuming `num_lines` = line count, `punct_ratio` = punct/chars, `cardinality_words` = distinct words)?

---

# i still haven't figured out a clean way to express the "grammar" elements, like how the optional content_meta is an embedded list of mixed values while its associated header cell column is an array of strings, but both share the same inner container shape {...;...;...} or some such. maybe just space delimited i dunno

The clean expression is that **the block is a row, one level down.** Same grammar, different glue:

- top level: items joined by `|`, terminated by `\n`
- block level: items joined by _something_, wrapped in `{ }`

Header vs record isn't a second schema at either level — it's a _projection_ of the same column list: header cell = `name<type>` per item, record cell = formatted value per item, positional in both. That's already how the outer row works; the block just applies it recursively. So the declaration needs exactly two things:

```json
"framing": {
  "row":   { "open": "",  "delimiter": " | ", "close": "\n" },
  "block": { "open": "{", "delimiter": " ",   "close": "}", "label": "name:" }
}
```

and a column whose `items` are sub-fields with the _same_ per-item shape (`name, type, pattern, source`) as top-level columns. No `construction` string, no `header_row_schema.content_meta.items[3].type_name` references — the recursion is in the structure, and the header/record split is a rendering choice the file never has to spell out. The composed regex falls out the same way: block pattern = `open` + item patterns joined by `delimiter` + `close`, exactly like the row.

On space vs `;` — one criterion actually decides it: **can a sub-field be individually empty?** With a space delimiter, an empty marker of nothing gives `{12  0.414}` — a double space a reader has to count. With `;` it's `{12;;0.414}`, unambiguous. So:

- if the block is all-or-nothing per row (entry has `ContentMeta` or it doesn't), sub-fields are never individually empty → **space**, LTS-compatible, one fewer token per field, and all values are numeric so nothing ever contains a space;
- if a sub-field can be absent on its own (the processor only computes `LineStats` when `charCount > 0`, for instance), either use `;` or keep space with a visible empty marker like `-`.

I'd lean space + treat the block as atomic per row — and make the processor guarantee it emits every declared field (zeros, not absence). That puts the invariant where it's cheap and keeps the wire clean. Either way it's one framing key, changeable later without touching a column.

---

# unlikely, but theoretically possible. i prefer separating with `;` i think. this is partly a concern for the reader's sake, regularity that doesn't silently introduce disparities between the header row nested struct and its values in the record_row schema

`;` it is — and the reason is a good one to write down, because it's not about parsing. Under `;`, header cell and record cell always have the same delimiter count: `{num_lines<int>;ws_ratio<double>;entropy<double>}` ↔ `{12;0.414;4.693}`, and an empty slot is `{12;;4.693}` — still three slots, still indexable by eye. Space would let an absence silently collapse the alignment. So the delimiter is doing the same job the length prefix does one level up: keeping the frame legible without asking the reader to infer it.

Consequences worth being explicit about:

- **It's a wire divergence from LTS** (`{594 69 0.1414 4.6930}`) — shard-format-notes describes the LTS form and should note v3's. Same class as the dropped trailing `|` (#45).
- The block pattern composes exactly as before: `open + items joined by ";" + close`; your existing record pattern already had `;` in it, so the file was ahead of the discussion.
- One invariant becomes assertable at render time and should be: header block slot count == record block slot count == declared `items.Count`. That's the "no silent disparity" property, as a test rather than a hope.

I'll file it as a ledger row (#49: block delimiter `;`, header/record slot regularity; LTS space retired) and a one-liner in shard-format-notes when you call the declaration stable — or now, if you'd rather it not wait on the file.

---

# looking at rs.core.internals, would there be a way to kind of emulate the reflected params based on the json schemas and files such that they can infact act as a direct source of truth? i know this isn't powershell reflection, but i feel like parts of the pass through params idea could be adapted to work from json source

Yes — and it's a smaller step than it looks, because the mechanism in `rs.core.internals` doesn't actually depend on reflection. `New-ForwardedParamDictionary` builds a `RuntimeDefinedParameterDictionary` by iterating `Get-Command`'s parameter metadata; the dictionary itself is just `(name, type, attributes)` triples. Anything that can produce those triples can feed a `DynamicParam` block. A JSON `in.params` section can, if its vocabulary is closed.

## What it would look like

Contract side — the entry has to be data, not prose types (`"type": "Code"`, `"LeanPayload|KeepContentless"` today are half-way):

```json
"ShardQuotaBytes":     { "type": "long",   "default": 32768,  "min": 1 },
"ShardToleranceBytes": { "type": "long",   "default": 4096,   "min": 0 },
"OrderStrict":         { "type": "switch" },
"Grouping":            { "type": "string", "values": ["Flat","ByFileType","ByRootDirectory"], "default": "Flat" },
"Plan":                { "type": "object", "mandatory": true }
```

Builder side — a sibling of the existing function, ~40 lines: `type` → `[type]` (`switch` → `SwitchParameter`), `mandatory` → `ParameterAttribute.Mandatory`, `values` → `ValidateSetAttribute`, `min/max` → `ValidateRangeAttribute`, `default` → `RuntimeDefinedParameter.Value` (which _is_ how DynamicParam carries a default — the param stays out of `$PSBoundParameters`, so the tri-state the internals doc guards is preserved, and it becomes _observable_: unbound-with-default is exactly ConfigEcho's `Source = TargetDefault`). Then a stage is:

```powershell
function New-ShardPlan {
    [CmdletBinding()] param()
    DynamicParam { New-DeclaredParamDictionary -Contract "$PSScriptRoot/schema/shards.contract.json" }
    process { $p = Resolve-DeclaredParams $PSBoundParameters $PSCmdlet   # bound ∪ defaults, + Source per param
              ... }
}
```

The signature can't drift from the contract because the contract _is_ the signature — the `in.params ⊆` check `contracts.tests` does for `from:` fields becomes structural for params.

## Two payoffs beyond drift-proofing

- **The effective-config resolver falls out for free.** Payload-ledger #11 (`{Name; Value; Source = Caller | TargetDefault | …}`, deferred) is hard when defaults live in `param()` blocks — they're only reachable via AST. When defaults are JSON, `Resolve-DeclaredParams` produces the echo as a by-product: bound → `Caller`, unbound → `TargetDefault` with the declared value. That's the "declaration of consequence" machinery, and it's about ten lines once the params are data.
- **`psr.header.json` drives admissibility.** `Resolve-Layout -Columns` / `-ContentMetaFields` currently validate against the declaration _after_ binding and throw. As a `ValidateSet` built from the declaration's column names, tab-completion offers exactly what the file admits, and the error is a parameter-binding error. Same builder, different source file.

## Costs, honestly

- **Discoverability.** `Get-Help` on dynamic params is thin, and `rs.dev.signatures` (AST) goes blind. The JSON _is_ the doc, so a `Get-StageParams shards` dev verb that pretty-prints the section covers it — but it's a real trade for people reading `.psm1` files cold.
- **Body ergonomics.** No auto-bound `$ShardQuotaBytes` variables; `Resolve-DeclaredParams` can `Set-Variable` them into scope, or you read from the hashtable. Minor.
- **Vocabulary discipline.** The contracts have to give up prose in `type` for a closed grammar. That's a tightening you'd want anyway — same instinct as the psr rewrite.
- Parameter sets / positional / pipeline binding aren't modeled. The stages are all named-splat, so nothing lost today; note the boundary.

## How I'd land it

Build it for the stages that don't exist yet — `New-ShardPlan`, `Invoke-Serialize` — so nothing green goes red, and let `psr.header.json` → `Resolve-Layout`'s validate-sets be the first use on existing code (pure tightening, no signature change). Leave assemble/ingest on `param()` and add the _inverse_ check to `contracts.tests` — reflect their params and assert they match `in.params` — so both routes converge on JSON as truth, and migration is a choice per stage rather than a flag day.

Want me to write `New-DeclaredParamDictionary` + `Resolve-DeclaredParams` into internals against `shards.contract.json`'s `in.params` (tightening that section's vocabulary as I go), with a small test?

---

# yea i dont like code inconfig. its good to provide the piece,sbut the schemas right now are fill withimplementation details they shoulnd't be in the code. since the psr format schema isnt a formal json schema, we do have to parse it custom which is fine , i just realized that the way the schemas sarted proliferating idn't suit me and im still borrowing json idioms in that schema file because the semantics are clear. its a json schema like object for specifying the custom container serialization from a pscustom object ultimately. that means sources should all come from the a named element in a contract schema that interfaces with psr.header.json ( and file needs rename since its not just a header schema, its more of a container spec or pseudo-schema)

That's a cleaner cut than what's on disk, and it draws the line in the right place: **data the code reads is fine; prose about the code is not.** Under that rule the current contracts fail — `"module": "rs.core.assemble.psm1 — Invoke-Assemble(-DispatchOutput [-RunContext] …)"`, `$comment` paragraphs of doctrine, "READ BY CODE" flags — all of it is implementation narrating itself into the schema. The stripped shape has three layers, each declaring one thing:

**1. Element declarations — owned by the producer.** `rs-content_meta` declares the shape of `ContentMeta`: field names, types, nothing else. Same for every processor that attaches an element; core fields (`RelativePath`, `NodePath`, `LastWriteUtc`, `Content`) declared once by ingest. This is the container brief's own answer to "which elements become columns" — _declared by the producing processor alongside its element_ — finally given a file. The record's full shape is then the aggregate: core ∪ declared elements. No free-form dotted paths anywhere.

**2. Stage contracts — I/O shape only.** `in.params` (closed type vocabulary, defaults, values — the thing the DynamicParam builder reads), `in.<shape>` with `from:`, `out.<shape>` with typed fields. No `module`, no essays; a `note` survives only if it's a fact about the field. Everything currently in `$comment` that's _rationale_ moves to briefs/ledger; anything that's a _rule_ becomes a test.

**3. The container spec** (renamed — `psr.container.json` says both what format and what it declares; your call). Framing + the column tree; every `source` is `record.<Element>.<Field>` and must resolve against layer 1, or `plan.<Field>` against `shards.out.placement`, or `codec.*` — the one prefix the container is allowed to own, because it _is_ the codec. That resolution is a mechanical check `contracts.tests` can run: every source names a declared field; every declared-required column has a source. The spec stays a JSON-idiom pseudo-schema, custom-parsed, and that's fine — it's honest about being a serialization spec for a PSCustomObject, not a validator.

What that buys concretely: rename `CharCount` in the processor and the test fails at the container spec, not in a shard file three stages later. Add `UniqueWords` and it's a one-line element declaration plus a one-line column — no walker change. And the psr file stops needing to know PowerShell property paths at all; it names fields the way the header row does.

Two things I'd want your call on before touching files: where element declarations live — beside each processor (`processors/rs-content_meta.element.json`, ownership obvious) or pooled under `schema/elements/` (one place to look) — and whether the rename happens now or when the spec stabilizes, since `Resolve-Layout` and the tests reference the path.

---

# some of its fine in a 'description' field for descriptive purposes, but not parsing code out of json. i jsut renamed 'schemas' to 'contracts'. the psr.header.json -> psr.container-spec.jsonc, but i think i might actually go with psr.contract.jsonc and let this one be a special case jsonc while having consistent naming if it still fits in that dir for what it does

On the name — I'd keep it visibly different, not folded into `*.contract`:

- The stage contracts are `<stage>.contract.json` and share one shape (`in`/`out`, `from:`); `contracts.tests` globs `*.contract.json` and walks that shape. `psr` isn't a stage and the file has a different shape and a custom parser. Naming it `psr.contract.jsonc` buys visual consistency at the cost of promising sameness the file doesn't deliver — the next reader assumes it's another stage contract and reaches for `in`/`out`. A name that says "this one is the odd one" is the honest name.
- It _belongs_ in `contracts/` though — it's a declared boundary the code reads, sitting between the record contract and the wire. That's the "if it still fits in that dir for what it does" test, and it passes.

So `psr.container-spec.jsonc` (what you have) or shorter `psr.spec.jsonc`. Either is fine; the `.jsonc` extension is a good second signal, and I verified `ConvertFrom-Json -AsHashtable` in your pwsh already tolerates `//` comments and trailing commas, so no parser change is needed for the extension.

**Path debt from the rename** — three code sites and five test/comment sites still say `schema/`, and the container module has the old file name hardcoded:

- [rs.core.assemble.psm1:99](utils/reposnapshot/reposnapshot-v3/rs.core.assemble.psm1:99) — `$PSScriptRoot/schema/assemble.contract.json` (load-time read → **assemble is broken right now**)
- [rs.core.container.psm1:43](utils/reposnapshot/reposnapshot-v3/rs.core.container.psm1:43) — `schema/psr.header.json` (→ container broken)
- [tests/contracts.tests.ps1:103](utils/reposnapshot/tests/contracts.tests.ps1:103), [assemble.tests.ps1:120](utils/reposnapshot/tests/assemble.tests.ps1:120), [crawler.tests.ps1:120](utils/reposnapshot/tests/crawler.tests.ps1:120) — path joins
- docstring/comment mentions in assemble, container, membrane, rs-content_meta, container.tests

The two module lines are the ones that matter — the battery is red until they move. Want me to fix the path references now (mechanical, ~8 sites, no shape changes), while you keep working the spec's content?

---

# <command-name>/model</command-name>

            <command-message>model</command-message>
            <command-args>claude-sonnet-5</command-args>

---

# <local-command-stdout>Set model to claude-sonnet-5</local-command-stdout>

---

# i just renamed again to `container.spec.json` which is more fitting and with the spec being solidified, can we check for broken refs in code and tests etc

Checked empirically rather than by inspection alone — the two are worse, and differently broken, than a plain "stale path."
Confirmed both, empirically. Full sweep below — nothing fixed yet, per your ask.

## Load-bearing, and the two break differently

**`rs.core.assemble.psm1:99`** — imports "successfully" but **silently corrupts state**. `Get-Content` on the missing path errors non-terminating (no `-ErrorAction Stop`), so `$script:Contract` becomes `$null`, and `$script:CoreFields` / `$script:ExcludedFields` both resolve to **empty arrays** rather than throwing. I ran it — confirmed `Contract is null: True`, both field lists `count=0`. That's the opposite of what the module's own comment promises two lines above the call: _"Missing/unparseable file fails the import loudly rather than silently emptying the exclusion set."_ Right now it does exactly what the comment says it must not do — every entry would carry `AbsolutePath`, `SizeBytes`, `Extension`, `CreationUtc`, `FsAttributes`, `_ChainHalt` straight into the payload as elements, and the four core fields would miscount as elements too, with nothing to catch it. This is a real bug independent of the rename — `Get-Content` needs `-ErrorAction Stop` to make that comment true — the rename just tripped it today.

**`rs.core.container.psm1:43`** — imports fine (`Join-Path` doesn't check existence), fails **loudly** at first `Resolve-Layout` call, confirmed: `THREW: Resolve-Layout: declaration not found: …schema\psr.header.json`. Correct failure mode, wrong path.

## Full stale-reference inventory

**Path joins (load-bearing):**

| site                                                                                      | current (broken)                                   | needed                                                                                                                                                                                                                                                                                 |
| ----------------------------------------------------------------------------------------- | -------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [rs.core.assemble.psm1:99](utils/reposnapshot/reposnapshot-v3/rs.core.assemble.psm1:99)   | `$PSScriptRoot/schema/assemble.contract.json`      | `$PSScriptRoot/contracts/assemble.contract.json`                                                                                                                                                                                                                                       |
| [rs.core.container.psm1:43](utils/reposnapshot/reposnapshot-v3/rs.core.container.psm1:43) | `schema/psr.header.json`                           | `contracts/container.spec.jsonc`                                                                                                                                                                                                                                                       |
| [tests/assemble.tests.ps1:120](utils/reposnapshot/tests/assemble.tests.ps1:120)           | `..\reposnapshot-v3\schema\assemble.contract.json` | `…\contracts\assemble.contract.json`                                                                                                                                                                                                                                                   |
| [tests/container.tests.ps1:36](utils/reposnapshot/tests/container.tests.ps1:36)           | `schema\psr.header.json`                           | `contracts\container.spec.jsonc`                                                                                                                                                                                                                                                       |
| [tests/contracts.tests.ps1:33](utils/reposnapshot/tests/contracts.tests.ps1:33)           | `$schemaDir = …\schema`                            | `…\contracts` — this one is the highest blast radius: `Get-ChildItem` on a missing dir returns empty (confirmed), the `-ge 1` assert at [:104](utils/reposnapshot/tests/contracts.tests.ps1:104) fails, and **every stage's cross-contract check stops running**, not just container's |
| [tests/crawler.tests.ps1:120–121](utils/reposnapshot/tests/crawler.tests.ps1:120)         | `schema/crawler.contract.json`                     | `contracts/crawler.contract.json`                                                                                                                                                                                                                                                      |

**Runtime error-message strings in `rs.core.container.psm1`** (not load-bearing, but a thrown error would name the wrong file): [:211](utils/reposnapshot/reposnapshot-v3/rs.core.container.psm1:211), [:242](utils/reposnapshot/reposnapshot-v3/rs.core.container.psm1:242), [:366](utils/reposnapshot/reposnapshot-v3/rs.core.container.psm1:366).

**Stale prose only** (doc comments / `.NOTES`, cosmetic): [rs.core.assemble.psm1:51,94,161,225](utils/reposnapshot/reposnapshot-v3/rs.core.assemble.psm1:51); [rs.core.container.psm1:15,159,167](utils/reposnapshot/reposnapshot-v3/rs.core.container.psm1:15); [rs.core.membrane.psm1:15,926](utils/reposnapshot/reposnapshot-v3/rs.core.membrane.psm1:15) (membrane doesn't load its contract programmatically, so this is prose-only); [processors/rs-content_meta.ps1:6](utils/reposnapshot/reposnapshot-v3/processors/rs-content_meta.ps1:6); [tests/contracts.tests.ps1:6,101,102](utils/reposnapshot/tests/contracts.tests.ps1:6); [tests/container.tests.ps1:7](utils/reposnapshot/tests/container.tests.ps1:7); [tests/crawler.tests.ps1:118](utils/reposnapshot/tests/crawler.tests.ps1:118) (label text).

**Stale prose inside a contract file itself** — [contracts/container.contract.json:8,36](utils/reposnapshot/reposnapshot-v3/contracts/container.contract.json:8) `note`/`$comment` fields name `schema/psr.header.json` and `psr.container-spec.json`. Doesn't break parsing, but it's the exact category you're trying to get _out_ of these files.

## What I'd want to sequence in

The assemble bug (missing `-ErrorAction Stop`, or check `-not $?`/wrap in try/catch and re-throw) is worth fixing alongside the path, not deferred — otherwise the next accidental path drift reproduces a silent payload-poisoning bug instead of a loud test failure, which is a materially worse failure mode to leave sitting.

Want me to fix all of the above now — the six load-bearing paths, the assemble error-handling gap, the three error-message strings, and the stale prose (module comments + the two `container.contract.json` fields) — in one pass?

---

# fix please

Fixing in dependency order: the load-bearing paths and the assemble error-handling gap first, then the error-message strings and prose.
Before touching the container.psm1 prose sites — line 361 asserts `psr.header.json source_grammar — exactly four forms` (`entry.*`, `plan.GlobalIdx`, `codec.bytes`, `codec.text`). You've been reworking sources in the spec (`record.*` came up earlier). Checking whether the _solidified_ `container.spec.jsonc` still matches what the code expects, since a rename fix would paper over a semantic mismatch if not.
That's expected — it's `.jsonc`, not strict JSON. Reading it directly instead of parsing.
Good — and this changes what "fix" means for container.psm1. This is not the same spec `rs.core.container.psm1` was written against — root shape, source resolution, and type vocabulary all moved. A path-string fix alone would let `Resolve-Layout` open the file and then fail confusingly on content it can no longer read. Let me confirm the blast radius before doing the mechanical fixes, then draw the line clearly.
Fixing all three remaining `assemble.psm1` prose sites, then the mechanical path fixes across the rest of the tree.
Two backslash-path sites didn't take (sed escaping across Windows paths is unreliable) — fixing those precisely with exact string replacement, and confirming the rest.
Good — assemble.psm1 is fully clean (the earlier sed did apply globally there; the two lines I couldn't see in the truncated reminder are fixed). Now the two test files with backslash paths:
`contracts.tests.ps1:15` uses "schema" as a common noun, not a path — leaving it. Fixing the two real path joins:
Now `contracts.tests.ps1`'s other stale prose (line 6, 101, 102) and `container.tests.ps1` / remaining doc-comment sites:
Now `rs.core.container.psm1` — path, prose, and the three runtime error-message strings:
Now membrane's doc comments, the processor comment, and the two prose fields inside `container.contract.json`:
Now the two remaining doc-comment-only sites (membrane, content_meta processor) and the last sweep to confirm everything is clean:
Full re-sweep to confirm nothing was missed, then re-run the empirical checks from before the fix to prove assemble and the path-resolution half of container are actually repaired:
Two things to run down — a `descriptor.json` reference that may predate this whole rename, and three leftover old-filename hits my summary-echo masked. Checking both before reporting.
Fixing three more — all part of the same rename, missed in the first pass. And `descriptor.json` is separate, older debt (dissolved in commit `0988179`, unrelated to today's rename) — flagging rather than guessing a fix.
Final sweep to confirm zero stale references remain from this rename:
All fixed and verified — not just edited, actually re-run.

**Load-bearing fixes, confirmed working:**

- **`rs.core.assemble.psm1`** — path corrected _and_ the `-ErrorAction Stop` gap closed (it was failing exactly the way its own comment said it must not: silently, with `CoreFields`/`ExcludedFields` both going empty). Re-imported and checked directly: `CoreFields = [RelativePath,NodePath,LastWriteUtc,Content]`, `ExcludedFields = [AbsolutePath,SizeBytes,Extension,CreationUtc,FsAttributes,_ChainHalt]` — correct. `assemble.tests.ps1`: **59/59 green**.
- **`tests/contracts.tests.ps1`** — `$schemaDir` now points at `contracts/`; finds all 8 stage contracts. **134/134 green.**
- **`tests/crawler.tests.ps1`** — **53/53 green.**
- **`rs.core.container.psm1`** — path corrected; `Resolve-Layout` now opens and parses `container.spec.jsonc` (progressed from "declaration not found" to failing three lines deeper, inside the function body). `container.tests.ps1` still fails — **as scoped, not as a bug I introduced**: the solidified spec's shape (root keys, `$ref`-based sources, type vocabulary) has moved well past what `Resolve-Layout` reads. That's the walker rewrite (Layer 2) I flagged before touching anything — a design task, not a rename, and I held the line there rather than guessing my way through it. The `SUITE ABORTED` catch caught it correctly (0 passed, 1 failed, clean abort — the test-harness guard doing its job).

**Every stale reference found and fixed** (18 sites): the 6 load-bearing paths, 3 runtime error-message strings in container.psm1, and 9 prose/doc-comment sites across assemble, container, membrane, the content_meta processor, and three contract JSON files (`container.contract.json` ×7, `serialize.contract.json`, `rs-content_meta.contract.json`) — plus `contracts.tests.ps1`'s own comment. Final sweep for both the old dir name and old filenames: clean.

**Left alone, on purpose:**

- `container.contract.json`'s `Type: int|float|str|block` vocabulary and its `out.layout` shape — these describe what `Resolve-Layout` _actually emits today_, which is still accurate. Redesigning that contract to match the new spec belongs with the walker rewrite, not a rename pass.
- Two `schema/descriptor.json` references in `rs.core.membrane.psm1:992,1001` — checked git history: `descriptor.json` was dissolved into the per-stage contract system by an earlier commit (`0988179`), before `schema/` even became `contracts/`. Unrelated stale reference, older than today's rename. I didn't guess at a fix since I don't know which contract now covers `RelativePath`/`Extension` provenance for membrane without checking — flagging rather than touching.
- `shards.contract.json` still has old field names (`SumOvershootBytes`, missing `PackObjective`/`DeviationBytes`/etc.) — visible in the `contracts.tests.ps1` INFO output. Already identified two turns ago as its own pending chip; not part of this rename's breakage, left as-is.

So: the mechanical rename is fully done and proven by test runs, not just by inspection. The one real gap — `Resolve-Layout` vs. the solidified `container.spec.jsonc` — is a scoped, separate task whenever you want to take it on.

---

# fix the remaining stale items you discovered

Confirmed — `crawler.contract.json` declares all three (`RelativePath`, `Extension`, `SizeBytes`) under `out.file`. Fixing both comment and thrown-error string to name the real current source:
Now `shards.contract.json` against the current brief. Reading both fully to get every field right rather than patching piecemeal.
Now the `shard` shape — add `DeviationBytes` as the primary signed field and `SlackBytes` as its counterpart:
Now let's validate the JSON is well-formed and re-run the contracts suite to confirm nothing regressed:
Valid, and every field list now matches the brief exactly. Full verification pass:
Both fixed and verified clean.

**`rs.core.membrane.psm1`** — the two `schema/descriptor.json` references were older than today's rename: I checked git history and `descriptor.json` was dissolved entirely in commit `0988179` ("union register = cross-stage god-view") in favor of per-stage contracts. Confirmed `crawler.contract.json`'s `out.file` actually declares the three fields membrane's fail-fast check requires (`RelativePath`, `Extension`, `SizeBytes`), so both the comment and the thrown-error string now correctly name `contracts/crawler.contract.json out.file`. `membrane.tests.ps1`: **27/27 green**.

**`shards.contract.json`** — brought fully in line with the brief's current `§Contract`:

- `in.params` gains `PackObjective` (`FrontLoad|Even`, default `FrontLoad`, with the "no preset layer" note carried over).
- `out.plan` and `out.group`: `SumOvershootBytes` → `TotalOvershootBytes` + `MaxOvershootBytes` (overshoot-facing vs. tolerance-facing, matching the split from a few turns back), plus `TotalSlackBytes`, `MaxFillBytes`, `MinFillBytes`, `HeaderOverheadBytes`, and `PackObjective` echoed into the plan.
- `out.shard` gains `DeviationBytes` as the primary signed field, with `OvershootBytes`/`SlackBytes` now documented as derived from it (`max(0,·)` / `max(0,−·)`), consistent with the "one signed number per shard" design.
- Module docstring and `$comment` updated to mention `PackObjective`, the shape-exact strict-baseline procedure, and ledger range `#40–#48`.

Validated as parseable JSON with every field list checked against the brief programmatically (not by eye), then re-ran `contracts.tests.ps1` — **134/134 green**, still finding all 8 contracts and computing residues correctly with the new fields in place.

Everything flagged as stale in the last two turns is now resolved. The one remaining item from the audit — `Resolve-Layout` vs. the solidified `container.spec.jsonc` shape — is still open and still out of scope here, same reasoning as before: it's a design task (the walker rewrite), not a stale reference.
