# see D:\aghado01\science-facility\issues\reposnapshot\discussion\packing-strategies-details.md for some answers on my thinking about packing, quota, and headroom. still need to standardize vocabulary, but i want the intent to be clear first

Read
packing-strategies-details.md
Read it. The truncation rationale is the piece that was missing — it changes what the quota is, not just what it's called.

What the note settles
Quota governs written file bytes: header row + every record row + all delimiters and terminators. Confirms seeding the accumulator with Measure-HeaderRow and confirms the move off LTS's content-bytes-only input.
Greedy/Balanced/Loose are gone. Objective is tightest packing, not evenness. That kills the 1.1 and 0.8 constants and makes my "linear-partition to make Balanced real" suggestion moot — you don't want even shards, you want full ones.
Group containment is hard; order within a group is negotiable. Inverts LTS's implicit priority, where the sort was baked in before packing ever ran.
Flat is one group, not a special case.
Binary units throughout.
Two things follow immediately. First, "fewest shards" and "least overhead" are the same objective here — the only variable cost is one header row per shard — so tightest packing has a single unambiguous meaning. Second, since the header row is inside the quota, the header must be sized before packing starts, which is only possible if the header is per-group. Your own "Flat is logically a single group" framing resolves the circularity I flagged last turn, at no cost.

The one thing in the note that doesn't hold
Tolerance applied unconditionally is arithmetically identical to a larger quota.

Your rule reduces to: admit if cumulative + candidate ≤ target + tolerance. All three of your examples agree with that one form — the "quota remainder + headroom" phrasing is the same inequality rearranged. But if that test runs at every candidate, then every shard fills to target + tolerance, and the loop is indistinguishable from greedy with a quota of target + tolerance. Target becomes decorative; 32768/8192 is just 40960.

For tolerance to mean something, it has to be conditional — and the condition that makes it earn its name is anti-runt. Concretely: pack strictly to target; then if a group's tail shard is small, merge it back into its predecessor provided that keeps the predecessor within target + tolerance. Same numbers, same admission arithmetic, but the overshoot only ever happens to eliminate a fragment, never as routine fill. That also makes it the direct replacement for what Balanced/Loose were nominally for — smoothing the tail — except local, exact, and one rule instead of two constants.

The alternative is honest too: collapse to one number, accept that "tolerance" was a bigger quota, and drop the second knob. What I'd avoid is keeping two numbers that behave as one.

What truncation-safety does to "soft quota"
The shards brief currently says MaxShardSizeBytes is soft — oversized shards exceed it "by convention." Under your rationale that's backwards: exceeding it is precisely the failure the quota exists to prevent, because a silently truncated read makes an agent conclude things from absence. So:

The number that must sit under the reader's threshold is target + tolerance, not target. Whichever way the tolerance question lands, that's the ceiling, and it's the number worth declaring.
An oversized shard (single entry over quota, atomicity preserved) is no longer a benign convention — it's a reader hazard that has to be announced. The plan already carries IsOversized; the tree manifest should say which shards exceed the safe read size and roughly by how much. That reads like a payload-manifest-ledger entry to me — same class as #8 (offsets need their unit) and #16 (compaction notice): a declaration that stops a reader drawing a wrong conclusion.
On "work out the minimal packing"
Worth knowing before you invest in it: with order enforced, the naive loop is already optimal. If shards must be contiguous runs of the group's sequence, greedy-fill-until-it-doesn't-fit provably minimizes shard count — each greedy cut lands no earlier than any other solution's corresponding cut, by induction. There's no cleverness to add. Strict-order mode is done.

The cleverness only becomes available in flexible mode, where reordering turns it into genuine bin packing (NP-hard; first-fit-decreasing lands within ~11/9 of optimal and is fine at this n). One refinement I'd suggest: use FFD to decide membership only, then restore the group's sort order within each shard before rendering. You get the tighter packing without the payload reading in descending-size order, and global idx follows the plan as it already does.

A consequence worth noting: under Flat, the path-hash sort exists to disperse large files so no shard turns pathological. In flexible mode FFD does that job directly and better, so the hash sort collapses to a tie-break/reading-order device rather than a packing input. Flexible mode is most defensible exactly where the order is already arbitrary to a human — Flat — and least defensible under ByRootDirectory, where RelativePath order is the reason the payload reads like a directory listing.

Deferred, but flagged
The note says the quota is on "shardfile total content bytes" and then defines it as header + rows — i.e. the whole file. That's the Size/Span distinction the container brief grades (Size bounds a container, Span measures content), and it's the historic confusion site. Not renaming anything yet, just marking that this quota is a Size, and MaxBytesSpan would name it wrong.

So the fork I'd want your call on: does tolerance become conditional (anti-runt tail-merge), or does it collapse into a single quota number?

# I don't agree that headroom is tantamount to a different quota. the semantics are different because we have a specific target, with some specified tolerance above that for making packing decisions based on other settings like whether or not order is enforced. I think one of the early stages in planning should be to enumerate all of the records regardless of which shard file they are in, so that we know the dataset up front. the "schema" of the header row is fixed at run time (non-negotiables TBD + optionals like the nested "attributes" block), which determines what goes into the rows as well as the header rows themselves, with number of header rows in the dataset determined by the number of shard files that resolve. things like the length prefix are byte spans of the prefixed content block for a given row, etc. so every record (one per ingested file) should be enumerated first, and then planning can work from there. and I think we can be more creative with packing algorithm

You're right and my claim was too narrow. The equivalence only holds for a packer that admits sequentially — first thing under the bound goes in. The moment the packer optimizes, target and tolerance take genuinely different roles: target is the objective the arrangement aims at, tolerance is the feasibility bound that says what's admissible at all. Those are two different things being asked of two different numbers, and my proof collapsed them because I assumed the LTS loop shape. Enumerating up front is precisely what makes the optimizing packer possible, so the two moves in your note are the same move.

Enumerate-first, and what it buys
Restating to check I have it: fix the header schema at run time (core columns TBD + optional blocks like attributes) → that determines every row's content → measure every record exactly, one per ingested file → now you have the dataset. Packing works from that.

What that structurally changes:

Packing becomes a pure integer problem. A vector of record sizes, a header size, a target, a tolerance. No IR, no entries, no content. Which means it's testable against synthetic size vectors — [16384, 8192, 4096, …] — with no repo, no ingestion, no fixtures. That's a much better seam than the brief's five-phase inline algorithm, where packing can only be exercised end-to-end.
The measured record list becomes a real intermediate, not "references to entries." { entry; rowBytes } × N. Worth naming in the contract, because it's the thing both the packer and any diagnostics consume.
Diagnostics come free before any packing decision: size distribution, largest record, how many records individually exceed the quota. You know the shape of the problem before choosing how to solve it.
A lower bound you can measure against. With Σ known, the minimum achievable shard count is ⌈Σrecords / (capacity − header)⌉. Any packer's output can be reported against it, so packing efficiency is a measured number in the plan rather than an assertion. That's a better exit gate than "deterministic."
idx width falls out naturally rather than as a trick to break circularity — the dataset is enumerated, so EntryCount is known before anything is arranged.
One consequence worth catching now
"The schema of the header row is fixed at run time… with the number of header rows determined by the number of shard files that resolve" reads to me as: one schema per run, N identical header rows, and you just count them. If that's right it settles the question I raised two turns ago — the container brief's lean toward a per-shard header, and my per-group counter-proposal, are both off. One global schema, headerBytes a single constant, known before packing.

The cost is that it re-opens partial presence: with a global schema, an element present on 30% of entries must either become a column with an empty marker on the other 70%, or be excluded. The per-shard header was the escape from that choice, and fixing the schema per run closes it. That's a real trade and it belongs to the header/container thread, not this one — flagging it so it doesn't get lost.

Where the creativity actually lives
With the dataset known and order enforced (contiguous runs), you can solve this exactly rather than heuristically:

Minimum shard count — greedy gives it, provably, and it is tightest packing: total written bytes is Σrecords + k·header, so minimizing k minimizes overhead. Nothing to improve.
Then arrange. Among all partitions into exactly k contiguous parts, choose the one that best fits your target — minimize the largest shard, or minimize total deviation from target. Classic linear partitioning: binary-search + feasibility check, or DP over cut points. Cheap at this n.
That two-stage split is what makes your semantics real: tolerance can lower k (a wider feasibility band may admit a k-part solution that target alone wouldn't), and target shapes the arrangement within that k. Different numbers, different jobs, and the runt-tail problem dissolves without any special-casing — stage 2 redistributes it away, because k is already fixed and the mass has to go somewhere.

Flexible order is the same two stages with stage 1 becoming genuine bin packing (FFD, or exact for small groups) and stage 2 rebalancing fills. My earlier suggestion stands there: decide membership by size, then restore the group's sort order within each shard for rendering, so the payload doesn't read in descending-size order.

The fork I'd want your read on: in stage 2, is the objective minimize the largest shard (simplest, binary-searchable, compresses the distribution) or minimize deviation from target (aims at your number directly, needs DP)? They diverge when Σ sits well below k·target — minimize-max spreads evenly and undershoots target everywhere; minimize-deviation packs most shards near target and leaves the slack in one.

# why dont you look at at an example shard file and tree file to remind yourself of the LTS output shape. this is roughly what a payload will look like, starting from the shards. observe the header row in each shard is identical because its one payload and each file gets the same header . you can see in this example the optional "attributes" block with enrichment metadata as well D:\aghado01\project-snapshots\reposnapshot\reposnapshot-v3_20260422_201912_tree.md

[session failed]

[user note: here's an example of an LTS shard file, shard 0004 of payload with tree file D:\aghado01\project-snapshots\reposnapshot\reposnapshot-v3_20260422_201912_tree.md

header row: 

`idx<int> | path<str> | attributes:{char_count<int> word_count<int> whitespace_ratio<float> entropy<float>} | length<int> | content<str> |`

records
idx<int> | path<str> | attributes:{char_count<int> word_count<int> whitespace_ratio<float> entropy<float>} | length<int> | content<str> |
8 | rs.core.ignore.psm1 | {27011 1932 0.4037 4.2516} | 27898 | <content redacted for brevity> |
9 | rs.core.ingest.psm1 | {3455 275 0.3349 4.5257} | 3570 | <content redacted for brevity> |
