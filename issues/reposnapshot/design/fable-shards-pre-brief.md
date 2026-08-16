> **Record, not live guidance (2026-08-15).** The pre-brief handed to AGY for
> the LTS sharding dive; `gemini-shard-recon.md` is its output and
> `briefs/shards-brief.md` supersedes both as the working spec. Item 1 below
> (plan on `SpanBytes`, bounded by `SizeBytes`) was overturned the same day —
> planning is exact via `Measure-Row` (ledger #39).

# so does the brief for shards clearly lay out the implementation of how we get from ingestion assembly to a pre-serialization data structure, given the knobs and constraints outlined by LTS mostly-working-but-ugly implementation? have we lifted the thrice-implemented "grammar" and whatnot into a new clean workflow design?

No. Straight answer, then what's actually there.

**What the shard-container brief covers:** the *container* — header derivation from the IR, one record renderer returning bytes + positions, framing/codec by pointer to shard-format-notes, the seam with shards. It lifts the thrice-implemented grammar *conceptually* (one renderer, cursor returns positions, grouping decides membership not bytes) — but not into a workflow with named data structures, and it deliberately stops at "shards hands serialize `@{ ShardKey; Entries[]; … }`."

**What does not exist:** a `shards` brief. Nothing lays out how to get from `assemble.out` (IR: Header + Entries in canonical ingested order) to a pre-serialization plan — which entries, which shard, in what order, under which knobs. `rs.core.shards.psm1` is 0 bytes and there is no design doc named for it. What exists around it:

- `shard-format-notes.md` (832 lines) — the *format* spec, plus posture and stage-ownership calls (#26 "Attributes does not own shard planning"; `Size` vs `Span` naming grade). Not a workflow.
- `rs.core.numerics-design.md` — `Get-PathHash` for Flat ordering, content hashing for shard metadata; the *inputs* shards will consume (#4).
- `discussion/opus-reposnapshotV3-LTS-updates.md` (126 lines) — the conceptual decomposition of LTS emission that replaced the cancelled swarm plan (#5). Closest thing to a starting point.
- LTS itself: `rs.lts.sharding.psm1` (55 KB) and `Partition-Files` in the monolith — the mostly-working-but-ugly source of the knobs (grouping modes, `MaxShardSpanBytes`, anti-fragmentation, sorting/subsorting, global idx).

**What a shards brief has to contain to answer your question yes:**
1. Input: the IR shape it reads (`assemble.out.entry` core + whichever elements the policy needs — `Attributes.SpanBytes` as the planning estimate, bounded by `SizeBytes`).
2. The knob inventory *extracted from LTS*, each with: what it does, keep/rename/drop, and its `Size`-graded name (grouping mode; target shard size; overflow rule for a single entry larger than the target; anti-fragmentation / minimum fill; sort and subsort keys; stable ordering; global idx assignment; shard key/naming).
3. The plan structure — `shards.out`: `@{ Shards[] = @{ Key; GroupKey; Ordinal; Entries[] (references, ordered); PlannedSize }; IdxMap }` — declared as `schema/shards.schema.json` with `from: assemble.out.*` so the contracts suite checks it.
4. The algorithm in prose: group → order within group → pack under budget with overflow + anti-frag → assign idx → emit plan. No bytes, no I/O.
5. What must NOT come across from LTS (the two grouping programs; sorting at serialization; anything that measures serialized bytes).
6. Exit gate: same membership → identical plan across runs; every entry in exactly one shard; planned sizes ≤ Σ SizeBytes; a synthetic oversize entry gets its own shard; contracts test green.

**Cost to write it honestly:** mining LTS's sharding for the knob inventory is the untangling you named — 55 KB of PowerShell plus the monolith's `Partition-Files`, read for *what the knobs are*, not to port. That's a real read. Two ways to do it:

- Read the opus decomposition first, then the LTS *parameter surfaces and docstrings only* (not bodies)
- identify the functions that are relevant and then read those in detail 
- important to minds naming convention disparities between what is implemented in LTS and what V3 conventions have adopted, which will likely be confusing 

