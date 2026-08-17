Read all three: shards-brief.md (issues/reposnapshot/briefs/shards-brief.md), shard-container-brief.md
  (issues/reposnapshot/briefs/shard-container-brief.md), rs.core.manifest.psm1
  (utils/reposnapshot/reposnapshot-v3/rs.core.manifest.psm1), plus the codec SPEC and assemble.schema.json to check the
  claims against.

  The split is right and the central move — one layout function, Measure-Row/Render-Row derived from one Format-Row →
  pieces — is what makes the "plan = file" gate possible at all. Below is what I found that doesn't hold yet.

  Contradictions to resolve before code

  1. Per-shard headers reintroduce the circularity you just killed.
  The container brief leans (c) per-shard header (:102 (issues/reposnapshot/briefs/shard-container-brief.md:102)). The
  shards brief packs with Measure-Row(entry, header, idxWidth) where header is the derived header, one per plan (:32
  (issues/reposnapshot/briefs/shards-brief.md:32)).

  Under per-shard headers, row size depends on the shard's column set → column set depends on membership → membership
  depends on row size. Under ByFileType this is benign (the group is homogeneous and decided in phase 1). Under Flat —
  the default — membership is path-hash dispersion, so it's genuinely circular.

  The invariant that fixes it: the header a row is measured against must be knowable before packing. That makes it a
  per-group header, not per-shard — decided at phase 1, rendered into every shard file of that group. Under ByFileType
  you get (c)'s entire benefit; under Flat it degrades to corpus-wide, which is precisely the case where partial
  presence still needs an (a)-or-(b) answer. So the three-way choice isn't three-way: it's (c) where grouping permits,
  with a declared fallback. This also settles the container brief's open call "header per shard vs per run".

  2. Packing = Balanced can breach the quota the exit gate asserts.
  Gate: every non-oversized shard's PlannedSizeBytes ≤ MaxShardSizeBytes (:186
  (issues/reposnapshot/briefs/shards-brief.md:186)). Balanced flushes at target × 1.1, target = Σ / ⌈Σ / max⌉ (:106
  (issues/reposnapshot/briefs/shards-brief.md:106)). Take Σ = 1.9·max: ⌈1.9⌉ = 2, target = 0.95·max, threshold =
  1.045·max. The LTS constant and the new gate are incompatible. Either clamp the effective quota to min(target×1.1,
  max) or scope the gate to Greedy/Loose.

  3. "Core columns always" contradicts the LTS-parity gate — and the lean-row doctrine.
  Container brief: core = RelativePath, NodePath, LastWriteUtc, Content (:64
  (issues/reposnapshot/briefs/shard-container-brief.md:64)). Its own gate: "Header derived from a real IR reproduces the
  LTS column set" (:193 (issues/reposnapshot/briefs/shard-container-brief.md:193)). The observed LTS grammar is idx |
  path | [attributes] | length | content — no NodePath, no LastWriteUtc. Two extra columns on every row, and NodePath is
  the directory portion of RelativePath, i.e. redundant by derivation. That's hard to square with the doctrine that
  made attributes opt-in because per-row metadata fragments a reader's attention.

  Specification holes

  - Row terminator T is still open. Measure-Row's formula ends · T · NL (:30
  (issues/reposnapshot/briefs/shards-brief.md:30)), but shard-format-notes §"Row termination — to confirm in spec" (:36
  (issues/reposnapshot/design/shard-format-notes.md:36)) has three candidate emissions unresolved. An open format
  question sits inside the exact-measurement formula, and it's in neither brief's open calls.
  - Measure-Content's arithmetic is signed, not "inflation". Stated as GetByteCount + line-break inflation − stripped
  controls (:44 (issues/reposnapshot/briefs/shards-brief.md:44)). Per-terminator UTF-8 deltas: LF/CR/VT/FF +1, CRLF 0,
  NEL 0, LS/PS U+2028/9 −1 (3 bytes → 2). Deflation exists. Also worth stating the C0 partition explicitly, since TAB
  and VT/FF are C0 exceptions to rule 3.
  - "Two functions, one table, cannot disagree" is an aspiration, not a construction. Same table, two code paths, still
  divergeable. Make the shared unit a per-character decision returning replacement length, so the only difference is sum
  vs append — and add the differential property test Measure-Content(c) == GetByteCount(Encode-Content(c)).
  - The header row isn't in the packing accumulator. PlannedSizeBytes includes Measure-HeaderRow (:147
  (issues/reposnapshot/briefs/shards-brief.md:147)) but packing starts cumulative += Measure-Row from zero — every shard
  overshoots by one header row. Seed cumulative = Measure-HeaderRow, and apply the same to the oversized test.
  - Fixed-width idx is a container decision made in a planning brief, and it's payload-visible. 0007 | path instead of 7
  | path diverges from LTS's grammar and from shard-format-notes. It's the right call — unpadded means the plan only
  bounds the file — but state it as a requirement shards places on the container, and record the trade rather than
  presenting it as free.
  - The receipt has no schema and no owner. It appears once, as a sketch: @{ Header; Rows[] with offsets; ByteLength }
  (:158 (issues/reposnapshot/briefs/shard-container-brief.md:158)). In a three-spec set whose thesis is the receipt is
  the only source of positions, it's the least-specified artifact. No serialize.schema.json, no manifest.schema.json —
  only assemble/crawler/ingest/membrane exist.

  Manifest, checked against the receipt

  - ColumnHeader is misidentified. The container brief says the derived header object feeds "the tree manifest's
  ColumnHeader" (:68 (issues/reposnapshot/briefs/shard-container-brief.md:68)). Today ColumnHeader is the offset table's
  schema — name<TAB>shard_index<TAB>row_offset<TAB>… (:301
  (utils/reposnapshot/reposnapshot-v3/rs.core.manifest.psm1:301)) — not the payload column set. Those are different
  declarations. If the tree should also declare the shard grammar (it should — it's the exclusive entrypoint), that's a
  new block, and under per-group headers it's N declarations, not one string.
  - shard_index name collision. The manifest column must identify which file to seek; the plan's IdxMap.ShardIndex is
  position within a shard (:93 (issues/reposnapshot/briefs/shards-brief.md:93)), which is useless for seeking. Same
  name, two meanings, silent wrong payload.
  - Stale doctrine in the QUEUED note (:33–44 (utils/reposnapshot/reposnapshot-v3/rs.core.manifest.psm1:33)): still
  calls Compaction a "cipher key" and cites "the LF/CRLF distinction the codec's preserve stance exists to maintain."
  Both were retired — notice-not-key, normalize-not-preserve.
  - Instructions are wrong for a sharded payload: "Seek to row_offset in the .json file" (:221
  (utils/reposnapshot/reposnapshot-v3/rs.core.manifest.psm1:221)). There is no JSON anywhere in v3.
  - Dead surface: New-SnapshotTocModel + Get-MonolithInstructionSet serve the JSON monolith that assemble's IR replaced.
  WriteMetadataBlock and ExcludedShardBlocks are model fields the template never reads (:286
  (utils/reposnapshot/reposnapshot-v3/rs.core.manifest.psm1:286)) — and ExcludeShardBlocks is a knob the shards brief
  relocates to serialize.
  - SummaryLine is caller-formatted and its documented example (Strategy: Auto | MaxShardSizeKB: 2048) names a dropped
  knob and a renamed one. It should be built from shards.out.plan.
  - Results contract (.Path, .Files) needs rewriting against shards.out.shard + the receipt. Also: the file is .psm1
  with no Export-ModuleMember, while its own .NOTES says "Standalone file — dot-source to use. Not a module."

  Sequencing

  rs.core.container is a dependency of both stages, has no stub (only shards and serialize are 0-byte), and its name is
  an open call in both briefs while both bodies assume it. Close that first — it's load-bearing.

  Then move the headline gate down a level. "Plan = file" is currently deferred to pipeline.smoke "once serialize
  exists" (:180 (issues/reposnapshot/briefs/shards-brief.md:180)), which means shards can land fully green without its
  central property ever being exercised. At the container level you can assert Measure-Row(e) ==
  Render-Row(e).Bytes.Length with no serialize stage at all — same property, testable immediately, and it's the kind of
  gate that catches the header-row and terminator issues above rather than deferring them.

  Want me to fold the accepted items into the two briefs and open a manifest brief for the audit list?

> yea there's still alot of confusion so i guess we'll need to take this one thing at a time. the design briefs clearly
  don't fully capture intent or points where i want to retain aspects of LTS design. Lets unpack the packing question

● Before I frame anything, let me go to the LTS source rather than the recon's summary of it.

  Searched for 1 pattern, read 1 file (ctrl+o to expand)

● Went to the source — Partition-Files in rs.lts.sharding.psm1:250–609 (utils/reposnapshot/rs.lts.sharding.psm1:250).
  The ground truth changes the shape of this question considerably.

  The three packing strategies are one algorithm with one number

  Greedy, Balanced, and Loose are the same sequential first-fit loop, triplicated ~75 lines each. Walk the group's files
  in order, accumulate, flush when the next file would breach a threshold. The only thing that differs across the three
  branches is the threshold:

  ┌────────────────────────────────────────────────────────────┬────────────────────────────────────────────────────┐
  │                                                            │                  flush threshold                   │
  ├────────────────────────────────────────────────────────────┼────────────────────────────────────────────────────┤
  │ Greedy (:416                                               │ maxSpan                                            │
  │ (utils/reposnapshot/rs.lts.sharding.psm1:416))             │                                                    │
  ├────────────────────────────────────────────────────────────┼────────────────────────────────────────────────────┤
  │ Balanced (:504–508                                         │ min(target × 1.1, maxSpan), target = groupTotal /  │
  │ (utils/reposnapshot/rs.lts.sharding.psm1:504))             │ ⌈groupTotal / maxSpan⌉                             │
  ├────────────────────────────────────────────────────────────┼────────────────────────────────────────────────────┤
  │ Loose (:535 (utils/reposnapshot/rs.lts.sharding.psm1:535)) │ maxSpan × 0.8                                      │
  └────────────────────────────────────────────────────────────┴────────────────────────────────────────────────────┘

  Everything else — oversized handling, flush-and-restart, the MaxFilesPerShard check, the tail flush — is copy-pasted
  identically three times.

  Correction to what I said last turn: I claimed Balanced could breach MaxShardSizeBytes and contradict the exit gate.
  That's wrong about LTS — line 505 checks wouldExceedMax as a second conjunct, so Balanced is bounded by max too.
  What's actually true is narrower and still matters: shards-brief:106 (issues/reposnapshot/briefs/shards-brief.md:106)
  transcribes Balanced as "flushes at target×1.1" and drops the max backstop. Implement the brief literally and you get
  the breach; implement LTS and you don't. It's a transcription loss in the brief, not a defect in LTS.

  Two things the docstring claims that the code doesn't do

  - "Balanced: Best-fit with load balancing" (:258 (utils/reposnapshot/rs.lts.sharding.psm1:258)) — there is no best-fit
  anywhere in the file. Best-fit requires multiple open shards and a search for the tightest fit; there is only ever
  one open shard, $currentShard. Balanced is first-fit with a lower threshold.
  - "Loose: Conservative packing with 20% headroom" — this one is accurate.

  And best-fit was never available, which I think is the substantive point: order is load-bearing here. Phase 2
  deliberately arranges entries — path-hash for Flat (:311 (utils/reposnapshot/rs.lts.sharding.psm1:311)), RelativePath
  within group for ByFileType/ByRootDirectory (:329 (utils/reposnapshot/rs.lts.sharding.psm1:329), :349
  (utils/reposnapshot/rs.lts.sharding.psm1:349)). Any real bin-packing algorithm reorders by size and destroys that
  arrangement. So given a fixed order, the only lever for evenness is where you cut — which is exactly what the
  threshold does. The docstring describes an algorithm that would have contradicted the stage above it.

  Incidentally this closes one of the brief's open calls: Flat-by-Get-PathHash and grouped-by-RelativePath are both
  confirmed against source, as is .root forced to index 0 (:353 (utils/reposnapshot/rs.lts.sharding.psm1:353)) and
  ByFileType's first-observed key order (via [ordered], despite the comment claiming a sort).

  Two real defects worth not porting

  1. Packing input is content bytes, not row bytes. $file.ByteSpan or GetByteCount($file.Content) (:376
  (utils/reposnapshot/rs.lts.sharding.psm1:376)) — the idx, path, delimiters, attributes block, length prefix and
  terminator are all unbudgeted. So LTS systematically undercounts, in one direction: real shard files are always larger
  than MaxShardSizeKB, and by more the smaller the average file. That's the concrete cash value of moving to
  Measure-Row.
  2. Accumulation is in KB as doubles. $currentSizeKB += $fileSizeKB (:437
  (utils/reposnapshot/rs.lts.sharding.psm1:437)), compared against $maxSpanBytes / 1KB. Float drift across thousands of
  files, and boundary behavior that isn't reproducible. The brief's "bytes, no KB" rename fixes the naming; the thing
  that actually matters is accumulating in long bytes.

  Also worth knowing: MaxFilesPerShard defaults to 1000 in the module (:279
  (utils/reposnapshot/rs.lts.sharding.psm1:279)) but the production call site passes 100000 (RepoSnapshotLts.psm1:2360
  (utils/reposnapshot/RepoSnapshotLts.psm1:2360)) — i.e. it's disabled in practice. The brief took the call-site value
  as the default.

  So the decisions

  The reframe is: there is one packing algorithm, and the question is what governs its cut points. Which leaves you
  these forks:

  1. Do the three names survive? They're a vocabulary, not three implementations. Keeping Greedy | Balanced | Loose as a
  knob over one parameterized loop is entirely defensible — it's a user-facing surface with three understood meanings.
  The alternative is exposing the threshold directly (a fill fraction) and dropping the names. What I'd push back on
  either way: don't port three loops.
  2. Does Balanced stay a heuristic, or become real? If order is fixed, "minimize the largest shard over contiguous
  runs" is exactly solvable — binary-search the threshold, O(n log n), no reordering, no magic 1.1. That would make
  Balanced mean what its name says while respecting phase 2. Keeping the 1.1 heuristic is fine too, but then it should
  be described as "a lower cut threshold derived from an estimated shard count," not load balancing.
  3. Does the quota now mean row bytes? The brief says yes, and that's the right call, but note it silently changes what
  an existing 2048 means to anyone who tuned it — shards will hold fewer files at the same number.
  4. Header row in or out of the budget? Still open from last turn, and now more concrete since the header may be
  per-group.

  Which of those do you want to take first — or is there an aspect of the LTS design you're trying to retain that I
  haven't hit?



what is 32kb in exact bytes?  i.e.   237
