# Changelog 

## 2026-08-24 — station settled: pad-breaks (rs-whitespace) prepares, the codec purely substitutes

The mark-spacing story reached its final shape, the user's original
architecture: **the encoder is a pure substitution** — one terminator becomes
the one two-character symbol `\n`, nothing else (`CodecMark`, 2 bytes; the
same-day codec-side spacing detour reverted) — and the wire's regular mark
environment is **content preparation**: rs-whitespace's new **`pad-breaks`**
op (defaults, runs last, succeeding `ensure-trailing-space` under #20) inserts
one space between any solid character and an adjacent newline, both
directions, via two symmetric zero-width insertions. Everything falls out of
the lookarounds uncoded: consecutive terminators stay ADJACENT — a blank line
encodes as the canonical **`\n\n`** (user: for the record), not a
space-separated pair; the document-final break takes no trailing space (the
end of a content block separates from nothing); indented lines keep
indentation as their own separation; idempotent. Three stations, never
crossed: rs-whitespace shapes content whitespace · the codec substitutes
symbols · the row join spaces row items (#49).

Full-pipeline hex trace of the probe file confirms the wire:
`function Probe { \n    'x' \n\n    'y' \n } \n` — every mark
whitespace-flanked, blank run adjacent, final clean; written bytes == codec
output. `rs-whitespace.tests` §6b rewritten for pad-breaks (+ tripwire: the
op must stay in the defaults, since nothing downstream fails without it —
measure and render stay self-consistent even when the wire is wrong);
`container.tests` codec section back to bare-substitution expectations.
Battery **23 · 1393 · 0**.

## 2026-08-24 — the break mark is an OBJECT: codec owns its spacing; #20 relocated

SPEC rule 1 amended (user): within the encoding operation the span is a list
of objects — line segments and break marks — with **regular single-space
joins**, so every mark sits in a ` \n ` environment: `line one \n line two`.
A blank line is an empty segment → the doubled join `a \n  \n b` (the row's
empty-marker convention), which is also what keeps split-on-` \n ` a clean
decode. **The criterion is tokenization regularity**: an encoded symbol must
tokenize identically in every context in the reader's tokenizer;
context-dependent merging (`\nFunction`, the `]|` class) is the defect itself,
and cost is a price, never a counter-argument. `CodecBreak` → ` \n ` (4
bytes); `Measure-ContentSpan` delta 4 − own width. Two separate operations,
one principle: the codec spaces objects inside the span; the row join spaces
items in the row (#49); neither reaches into the other.

**`ensure-trailing-space` left the rs-whitespace defaults** (#20 relocated,
op still available opt-in): it was the LEFT half of this spacing, expressed
at the wrong station — a configurable content op two stages upstream. Both
failure modes were caught on full-pipeline hex traces through colonel, not
synthetic entries: a subset op list had silently shipped unspaced marks
(`\nfunction`), and with the codec join live, both stations running
double-spaced the wire (`{  \n `). After the relocation the trace shows
` \n ` uniform, single-station. Source-literal `\n` stays unspaced — the #8
ambiguity narrows to sources containing literally ` \n `.

`container.tests` updated to the object mark (+ a blank-line doubled-join
assert, 78 → 79); every other suite derives from the codec and passed
unchanged — including the on-disk seek contracts in serialize/selfie.
Battery **23 · 1388 · 0**.

## 2026-08-24 — rs.core.user: the convenience entry point

`rs.core.user.ps1` — point `-Root` at a directory, get a complete payload:
one script over the six stage calls (crawl → membrane → ingest → assemble →
layout → plan → serialize → manifest), importing the rs.core modules by
relative path (psd1 packaging stays the follow-on). **Output convention:**
`<OutRoot>/{runstamp}/<leaf>_sNNN.txt + <leaf>_tree.md`, default OutRoot =
`<Root>/.snapshot` — the house convention, snapshots UNDER the crawled tree,
protected by the MEMBRANE rather than a writer guard: Ignore semantics
excludes `.snapshot/` via IgnoreDefaults (plus the usual gitignore rule via
sentinels); Selection excludes it by pattern discipline, negations available.
Same-second reruns get suffixed run dirs. Ergonomics: `-SelectionPatterns`
flips the membrane to Selection; `-PsStrip` adds the comment stripper;
`-Columns` drives both the layout and whether rs-content_meta joins the
chain; `-PassThru` returns IR/Layout/Plan/Receipt for tooling. RunContext
(RunStamp, Root, GeneratorVersion, ConfigEcho) rides into the IR header and
the tree's provenance.

`tests/user.tests.ps1` (12): complete payload from one call; the `.snapshot`
default; **a rerun over the same root ingests the same entries — the
membrane, not a guard, keeps the payload out of the next crawl** (verified,
not asserted); collision suffixing; Selection + PsStrip with the stripped
span seek-verified from the written bytes. Battery **23 · 1387 · 0**.

## 2026-08-24 — rs.core.manifest reconciled: New-Manifest — THE EXPORT PHASE IS COMPLETE

The 327-line LTS port becomes the contract's module: a **pure formatter over
precomputed facts**. Offsets and byte lengths come verbatim from serialize's
receipt (nothing recovered post hoc — the LTS regex offset recovery is the
counterexample this module exists to not be); keys/groups/classes from the
plan shards, joined by Key with `PlannedSizeBytes` cross-checked against
`ByteLength` (belt and braces; mismatch = inputs from different runs, throws);
the psr header row VERBATIM from the layout (one declaration, third sink);
provenance from RunContext, never hardcoded. Every declaration the
payload-manifest ledger owes a reader is a **model field**: offset unit (#8),
compaction notice — a notice, not a cipher key (#16/#10) — emission encoding
(#17), oversized hazards with "read whole" reasons, format identity. The
Handlebars-lite engine survives; the LTS-shaped model builders and the stale
"cipher key" QUEUED note are gone (LTS is served by rs.lts.template.ps1 at
root — airgap #3 verified, nothing imports across). Writes ONE file, UTF-8 no
BOM, LF only, byte-deterministic.

`tests/manifest.tests.ps1` (23): declarations on the written file, every
receipt row's offsets verbatim in the TocTree, directory indentation, payload
lines, hazards present/absent, provenance verbatim, byte-identical re-render,
and the cross-check firing on a tampered receipt. The selfie now writes the
tree beside its shards and verifies every row and shard leaf is declared —
the fixture emits a COMPLETE payload. Battery **22 · 1375 · 0**.

**assemble → container → shards → serialize → manifest all landed.** The
writer-phase LTS-parity gap — rows, offsets, shards, tree — is closed.

## 2026-08-24 — the SELFIE fixture: the pipeline snapshots its own source

`tests/selfie.tests.ps1` (23) — root `reposnapshot-v3/`, **Selection** semantics
for `*.ps1`/`*.psm1`, the real chain (file-read → rs-whitespace → rs-psstrip →
rs-content_meta), then layout (gidx + content_meta) → `New-ShardPlan`
(ByFileType) → `Invoke-Serialize` → the bytes read back. PowerShell ingesting
PowerShell, on purpose. A **living fixture**: every assertion is an invariant
or checked against ground truth recomputed in-suite (an independent directory
walk) — never a golden count, so the corpus tracks the code. On today's tree:
27 files → 8 shards → 269,301 bytes; membrane survivors equal the independent
walk exactly; ContentMeta at full presence; the seek contract verified for
every row of the real payload; no raw CR on disk.

Section 5 is the **#48 harness on real data**, printed every battery run —
first numbers (Flat, working defaults): flexible earns a shard over strict
(9 → 8, Gap 0, provably tight); the two shapes coincide under strict on this
corpus; under flexible, Even beats FrontLoad on both overshoot aggregates
(TotO 7157 vs 8485, MaxO 2415 vs 3742) at equal shard count. One corpus, one
grouping — a data point, not the default decision. Battery **21 · 1350 · 0**.

## 2026-08-24 — rs.core.serialize landed: Invoke-Serialize (export phase 2)

Coded straight against `serialize.contract.json` — no brief, deliberately.
The only stage that writes shard files: header + rows per shard via the
container's `Build-HeaderRow`/`Build-Row` (bytes pre-encoded; no encoding
layer here), `<ShardStem>_<Key>.txt` (no stem → `<Key>.txt`), offsets recorded
from the writer's cursor as the receipt. **The plan = file gate lives here and
throws**: written length ≠ `PlannedSizeBytes` is an error, as is
`Σ ByteLength ≠ TotalPlannedSizeBytes`. `-Buffering PerShard|Stream`, same
bytes either way. Receipt: per shard Key/Path/ByteLength/EntryCount/
IsOversized/Rows; `Encoding = 'utf-8'` for the manifest (#17). Nothing flows
back into the plan.

`tests/serialize.tests.ps1` (14): full chain Resolve-Layout → New-ShardPlan →
Invoke-Serialize → read the bytes back — plan = file on disk; **the seek
contract on disk** (bytes at `[RowContentBegin..RowContentEnd]` ==
`ConvertTo-ContentSpan(Content)`, every row); no BOM, no raw CR from CRLF
sources; header occupies `[0, HeaderBytes)`; offsets chain to EOF; gidx rows
open with the assigned padded value; buffering modes byte-identical; oversized
written whole; the gate fires on a tampered plan; empty plan. Battery
**20 · 1327 · 0**. The export path assemble → container → shards → serialize
now runs memory-to-disk; manifest reconciliation is the remaining phase.

## 2026-08-24 — rs.core.shards complete: New-ShardPlan (the stage shell)

Export phase 1 lands whole. `New-ShardPlan(-Entries -Layout [-Grouping]
[-GroupSort] [-OrderStrict] [-PackObjective] [-ShardQuotaBytes]
[-ShardToleranceBytes] [-MaxFilesPerShard] [-ShardStem])` wraps the packer
core with stages 1–3 and the global half of 7–8: enumerate + group (`Flat` /
`ByFileType` reading the **carried** `Extension`, lowercased, `'.noext'` —
never re-derived, #50 / `ByRootDirectory` first path segment, `'.root'`
first), nominal order per `GroupSort` (`PathAsc` ordinal; `PathHash` via
numerics `Get-PathHash`, composite tie-break so even an unstable sort cannot
produce two orders), **measure once** per record via `Measure-Row`, call
`New-BinAssignment` per group, then global `Ordinal`s, `Key`s (width =
max(3, digits(ShardCount)) — the D3 literal never existed in code), gidx
0..N−1 in final reading order (`IdxMap`), and plan/groups/shards/idxmap per
the contract. The plan holds entry **references** (indices) and echoes the
resolved knobs including `ShardStem` and `MaxFilesPerShard`. Group order is
ordinal-sorted keys (`.root` first under ByRootDirectory). Nested imports:
container (Measure-Row), numerics (Get-PathHash).

`tests/shards-plan.tests.ps1` (33) runs against the REAL layout
(`Resolve-Layout` over `container.spec.jsonc`) — and asserts **plan = file by
construction ahead of serialize**: `Build-HeaderRow` + Σ `Build-Row` bytes
equals every shard's `PlannedSizeBytes`, both without and with gidx (measure
uses the stand-in, render the assigned value, same width). Also: carried-tier
boundary throw, group containment, `.root` unsuffixed, hash order verified
against `Get-PathHash` directly, oversized pass-through, 1000-shard key width
`s0001…s1000`, empty plan, grouped/flexible/Even determinism by serialized
comparison. Battery **19 · 1313 · 0**.

## 2026-08-24 — rs.core.shards: packer core landed (New-BinAssignment)

Export phase 1 begins with its pure inner layer: `New-BinAssignment(-Sizes
-HeaderBytes -ShardQuotaBytes [-ShardToleranceBytes] [-OrderStrict]
[-PackObjective] [-MaxFilesPerShard])` — stages 4–7 of the cascade over ONE
group's size vector in nominal order. Zero I/O, zero entries, zero layout;
deterministic throughout (#44). Classify pins overflow (#42) and computes the
ceiling-anchored, count-capped lower bound; strict baseline is greedy
contiguous at quota, with tolerance engaging the shapes (#48) — `FrontLoad` as
maximal quota prefixes forced past quota only by feasibility, `Even` as exact
lexicographic min-max linear partition (binary search + cut-point DP);
flexible runs FFD (never worse than strict, tie keeps order), tolerance-bounded
bin elimination, and an LPT shape pass for `Even`; sequence orders bins by
first nominal index with the minimum-fill non-oversized bin moved to the tail.
Aggregates exclude oversized shards; every shard's own `DeviationBytes` stays
signed and true.

**Implementation falsified the brief's FrontLoad sketch**: greedy-at-quota +
whole-bin adjacent merge cannot always reach `k_min` — on `(7,4,6,5)` at
capQ 10 / capC 13 no adjacent pair fits under the ceiling, yet `k_min = 2`
needs a cut moved inside a bin (`[7,4][6,5]`). The forward construction
computes the same shape directly; brief §Algorithm amended, and the vector is
a named test case.

`tests/shards-packer.tests.ps1` (220): the exit gate's synthetic-vector list —
guards, bands, overflow mid-sequence, the LB roadmap counterexample, both
shapes brute-forced against all contiguous partitions, the shape-disagreement
vector, elimination, count-cap binding, determinism by serialized comparison —
plus a 4-cell comparison mini-harness (shape × OrderStrict, one dataset, table
printed) asserting ShardCount is shape-invariant and the oversized shard is
identical in every cell. Every assignment passes a 9-point invariant battery.
The stage shell `New-ShardPlan` (enumerate/group/measure over real entries,
plan emission per the contract) is what remains. Battery **18 · 1280 · 0**.

## 2026-08-24 — rollup vocabulary: `Scope` → `Condition`; root-scope claims rewritten

A rollup is an aggregation **conditioned on a slice of the data** — nothing
about it is "scoping". The layer field renames `Scope` → **`Condition`**
(module, contract, tests); `BuildRollups($scope)` → `BuildRollups($condition)`.
Two independent axes, now stated wherever the layer is described: the
**condition** (which atoms — the WHERE; `'walked'` here, survivors or discards
would be other layers) and the **grouping** (`ByNode` — the GROUP BY). "Root"
is on neither: `ByNode['']` is merely the row whose group is the whole slice,
which is why `FileCount` equals it (an identity of the grouping) while
`DirectoryCount` — a node count over the structure — does not. Conflating the
axes is precisely what produced yesterday's off-by-self; the module docstring
still carried the false "run-level counts are the same aggregation at root
scope" claim and is fixed with the rename. AGENTS §Recalculating,
module-notes, #52, roadmap, and crawler-profile-brief follow (the brief also
loses a stray disposition bullet and its stale "rollups ride field groups"
line). Battery **17 · 1060 · 0**.

## 2026-08-23 — crawler: subtree rollups become a keyed layer, not node fields

Ledger #52. A rollup is metadata *about* the graph, never a property *of* a
node — it is computed by walking a node's descendants, so writing it back onto
the node it summarises is a denormalisation. `SubtreeDirCount` /
`SubtreeFileCount` / `SubtreeBytes` leave `out.node` for **`out.rollups`** =
`@{ Scope; ByNode[NodePath] }`, a sibling of `Graph` exactly as `Skipped`
already was. `RollUp()` (mutated nodes in place) became `BuildRollups($scope)`
(returns a layer); `NewNode` is structure only.

`Scope` is the layer's identity — `'walked'` here, meaning every file the crawl
saw before the membrane rejects any of it. A survivors-scope answer is a second
layer of the same shape over a different predicate, not a repair of this one, so
neither can impersonate the other and no per-field scope labelling is needed.

Two things stop needing explanation. **Membrane no longer "drops" rollups** —
it rebuilds nodes as structure and emits no layer, so there is nothing to strip
(the residue `crawler.out.node − membrane.out.node = {Files, Subtree*}` is now
just `{Files}`). And the crawler's run-level counts stop looking like a
different kind of thing from the per-node ones: they were already siblings of
`Graph`, and the per-node case was the lone exception.

**An off-by-self got pinned in the process.** `FileCount` genuinely is this
aggregation at root scope, but `DirectoryCount` counts graph **nodes including
root** (`== Graph.Count == ByNode[''].SubtreeDirCount + 1`) while
`SubtreeDirCount` counts **descendants excluding self**. Both relations are now
asserted — the suite caught it against a contract note claiming they were equal.
`crawler.tests` 53 → 59; the shape check now skips `$`-prefixed contract
metadata. Battery **17 · 1060 · 0**.

## 2026-08-23 — assemble gains a `carried` tier; shards read-ahead fixes

**`out.entry` has four tiers, not three** (#50): `core` · **`carried`** ·
`exclude` · `elements`. Carried = on the entry for downstream stages, **not**
counted in `Header.Elements`, never a wire column unless `container.spec.jsonc`
names one. `Extension` moves `exclude` → `carried`: it was stamped at crawl,
carried intact through membrane and ingest, destroyed here, then re-derived by
shards from `RelativePath` for `ByFileType` — two derivations of one fact that
must agree, and they diverge on a trailing-dot leaf. `rs.core.assemble` reads
the new key and skips carried names when counting Elements; `assemble.tests`
gains 5 asserts (carried kept, value verbatim, uncounted, module set = contract
set, tiers disjoint). `contracts.tests`' resolver learned that a register may be
a **name list** (`carried`/`exclude`) as well as a field register, so
`shards.in.entry.Extension { from: assemble.out.entry.carried }` resolves.

**Shards contract corrections found by the read-ahead**, all pre-code:
`group.LowerBound` re-anchored at the **ceiling** and given the count cap —
a quota-anchored bound can exceed the achievable count, so `ShardCount ≥
LowerBound` would have failed on a correct optimal plan (header 100, quota 1000,
tol 500, rows [700,700,500] → LB 3, achievable 2) — mass conservation scoped to
non-oversized shards on **both** sides (unscoped it reads −3900 against a true
100 as soon as one oversized shard exists); `OvershootBytes` no longer claims to
be both `max(0, Deviation)` and `0 for Oversized`; `Key` width derived from
`ShardCount` with a floor of 3 instead of a hardcoded `D3`; `plan` echoes
`ShardStem` (serialize needs it and had no route to it) and `MaxFilesPerShard`.

Battery **17 · 1054 · 0**.

## 2026-08-22 — rs.core.container realigned: the module is the declaration's interpreter

`Resolve-Layout` reads the restructured spec: register from
`shard_container_schema.properties` in `col_position` order; `required` (bool),
`record_type`, `record_width`, nested sub-fields in `val_rank` order with
`default: true` as the default set. Header cells render from the **item-array
templates** — scope resolves against the column being rendered with ascent to
the schema, `${cells}` splices, and computed forms resolve *before*
interpolation. Every column and sub-field binds through `Resolve-RefAccessor`,
which walks the `$ref` into its target contract and **throws at load** if the
pointer is dangling; the four accessor shapes (`entry.*`, `plan.GlobalIdx`,
`codec.bytes`, `codec.text`) are now derived, not declared.

The framing quartet (`FieldDelimiter · BlockOpen · BlockClose ·
BlockDelimiter`) is **gone**, not renamed — under #49 the marks are items.
`Framing` now carries `Encoding · Bom · RecordDelimiter · ColumnSeparator
(one char) · ItemJoin · EmptyMarker`. `Format-Row` returns `Items` (flat, marks
included, through content_bytes; the separator before content and the span
itself are `Build-Row`'s, so `Items -join ItemJoin` is exactly the prefix whose
last byte is `RowMetaEnd`). `Measure-Row` is `Σ item bytes + (n−1) joins +
terminator`. `FloatPrecision` → `DoublePrecision`; types `float`/`str` →
`double`/`string`. `container.contract.json` and `serialize.contract.json`
notes follow.

**New suite `tests/container-spec.tests.ps1` (34)** — the `record_pattern`
strings had no reader anywhere (decision #6's failure mode on #6's own
subject). It parses the spec, walks all 11 `$ref`s, checks `col_position` /
`val_rank` are total, and closes the round trip: rows the module renders
*through the templates* are validated against the spec's *own patterns*, across
all four on/off configurations, with the pattern interpolator written
independently of the module's. Added to `run-all`.

`container.tests.ps1` rewritten for the item model, 70 → **78** asserts (new:
the `$ref`-derived accessors, enclosure/separator as column properties, the
resolved width reaching the wire, the `#49` byte identity stated independently
of the implementation, and no doubled space in a full header). Battery
**17 · 1049 · 0**.

## 2026-08-22 — container.spec.jsonc v0.5: interpreter contract amended, two bugs caught by running it

Audit pass over the whole declaration, driven by rendering rows from the spec
and running its own `record_pattern`s against them. Wire unchanged from v0.4;
what changed is what an interpreter must do, so an interpreter written against
v0.4 would be wrong — hence the bump.

- **Leader `record_pattern` bound was wrong**: `{2,3}` → **`{1,3}`**. Cells
  before `content_bytes` are path (required) + gidx and content_meta (optional),
  so the required-only layout has 1, not 2 — the pattern silently rejected the
  minimum legal row. **Pre-existing**, inherited from the pre-restructure spec.
- **Scope rule stated**: a `*_template` / `*_pattern` is evaluated in the scope
  of the thing it renders or validates, never the object it is written on, and
  `${prop}` **ascends** to `shard_container_schema` when not found locally. Both
  directions were unspecified and both occur — the header templates live on the
  schema but resolve against a column; `content_meta.record_pattern` lives on a
  column and reaches up for `${item_join}`.
- **Resolution order stated**: computed forms resolve **before** interpolation.
  Interpolating first yields `^[0-9]{digits(EntryCount)}$` for gidx, which
  matches nothing — caught by making that exact mistake in the prototype.
- **`empty_marker` corrected**: under the join an empty value is a zero-length
  *item*, surfacing as a doubled space rather than as nothing — the defect is
  observable on the wire, where a tight separator would have hidden it as `||`.
- `item_join` added to the UNPREFIXED tier roster; `${cells}` documented as the
  second computed form.

Verified: spec parses; header renders from the declaration alone with byte
identity `Σ items + (n−1)` = 175 = 175; every column `record_pattern` resolves
and matches its rendered value across all four on/off configurations.

## 2026-08-22 — psr wire settled: rows are item lists joined by one space (decision #49)

`container.spec.jsonc` → **v0.4**. `item_join: " "` is the whole spacing rule: a
row is a list of items — values, keys (a key carries its trailing colon), and
the marks `|` `[` `]` `,` — joined by exactly one space; a sub-grammar
(`int(4)`, the encoded content span) renders itself first and enters as ONE
item. Header now reads `gidx: int(4) | path: string | content_meta: [
line_mean: double , … ] | content_bytes: int | content: string`. The
`*_template` keys became **item arrays** (`["${name}:", "${record_type}"]`) and
no longer carry spacing; `${cells}` splices. `record_pattern`s updated for the
join on both the leader and the `content_meta` cell; the element class
deliberately still admits spaces so a future string sub-field stays expressible.
Two invariants added. **No padding property, by design** — padding is what the
join does, so the framing quartet (`FieldDelimiter · BlockOpen · BlockClose ·
BlockDelimiter`) leaves `rs.core.container` rather than being renamed, and row
bytes become `Σ item bytes + (n−1) + terminator`, exact by construction.
Measured before choosing: the spacing costs +0.046% tokens on a real 4.6 MB
payload and removes the `]|` merge that tight `|` produced in 102/102 rows.
Declaration verified sufficient by a throwaway interpreter that renders the
header from the spec alone (byte identity 175 = 175). **The module is not yet
realigned** — battery stays 16 · 937 · 1; see roadmap
§container-spec-realignment, now scoped as five deltas.

## 2026-08-17 — rs.core.container landed (psr layout, codec, header/row pair)

`rs.core.container.psm1` — export phase 0. `Resolve-Layout(-Header
[-Declaration] [-Columns] [-MetaFields])` reads `schema/psr.header.json`
(admissible superset × run config × EntryCount → gidx width) and returns the
layout object three stages consume; validates admissibility, the two order
invariants (content last, content_bytes before it), and warns — never decides —
on ContentMeta presence from `Header.Elements`. Codec: ONE compiled regex rule
table, two functions — `ConvertTo-ContentSpan` materializes, `Measure-ContentSpan` counts
(whole-string UTF-8 width ± per-match deltas; exact against encode incl.
surrogates); SPEC rules 1–4 (all terminators → `\n`, backslash never doubled,
C0/DEL stripped, TAB literal). `Format-Row` is the one layout function
(pieces, content never materialized); `Measure-Row` sums, `Build-Row` builds
bytes and returns the receipt (0-based, inclusive ends, `RowContentEnd ==
RowContentBegin` when empty — LTS convention kept); header-row pair. Fixed
widths are plan-time bounds — overflow throws. UTF-8 no BOM, LF only.
`psr.header.json`: `source` tightened to a four-form grammar READ BY CODE
(`entry.<path>` · `plan.GlobalIdx` · `codec.bytes` · `codec.text`); `ws_ratio`
moved before `entropy` (declaration order = wire order; LTS parity).
`tests/container.tests.ps1` (70) added to run-all; includes the value walk of
every source against a real rs-content_meta entry (contracts check #5, in
its natural home). Functions at the boundary, PSCustomObject layout —
per-char work is regex, per-row overhead negligible. Verbs are approved and
paired: `ConvertTo-ContentSpan` / `Measure-ContentSpan` (the span as written /
its byte width), `Build-Row` / `Build-HeaderRow` (bytes + receipt; serialize
writes) — the brief's Render-/Encode- wording renamed 2026-08-17 so no
-DisableNameChecking is needed anywhere. Battery 16 · 1007 · 0.

## 2026-08-17 — processors: rs-attributes → rs-content_meta

Renamed after the psr `content_meta` block it feeds; suite, chain keys,
run-all roster, sibling comments, AGENTS.md, live briefs, ledger 11b follow;
metrics untouched. Stale "SpanBytes is the packing input" comment corrected
(ledger #39). **Element renamed too:** `Attributes` → `ContentMeta` in memory —
one concept, three casings (wire `content_meta` · in-memory `ContentMeta` ·
processor `rs-content_meta`); psr `source` paths, contract notes, tests,
AGENTS.md byte-semantics section, ledger #26 note follow. Battery
15 · 937 · 0. See processors/CHANGELOG.md.

## 2026-08-17 — processors: format-ws → rs-whitespace

Rename to say the lane (code ingestion, not markdown; ledger #21). Processor
tag, test suite name, chain keys, `run-all` roster, and source comments follow;
transforms untouched. Whitespace normalization stated as a code-lane
requirement — `lf` is what lets `rs.core.container`'s codec (SPEC rules 1–4,
in the container, not a processor) count on LF-only content. Battery
15 · 936 · 0. See processors/CHANGELOG.md.

## 2026-08-17 — export contracts minted: container, shards, serialize, manifest

`schema/{container,shards,serialize,manifest}.contract.json` — the four export
stages declared before their code exists (build-against-absent rule), so the
from-graph across export is checked now: `container.out.layout` is a `from`
target in shards, serialize, and manifest (computed once, three sinks —
checkable, not a discipline); `shards.out.{plan,shard,placement}` in serialize
and manifest; `serialize.out.{receipt,shardreceipt,row}` in manifest;
`assemble.out.entry.core` in shards and serialize. Plan holds entry references,
embeds nothing upstream (`Header` dropped from `shards.out.result`; brief
aligned). RunContext stays an opaque param (admiral has no contract).
`contracts.tests`: `from` may now name a nested register one level down
(`<stage>.out.<shape>.<register>`), symmetrical with the walk. Manifest's
contract is what the LTS-template copy must become; declarations owed to the
reader (offset unit, encoding, compaction notice, oversized hazards, format
identity) are model fields. Battery 15 suites · 936 pass · 0 fail (contracts
67 → 134).

## 2026-08-16 — stage contracts renamed `*.schema.json` → `*.contract.json`

`schema/{assemble,crawler,ingest,membrane}.contract.json` (git mv). The files
are contracts; "schema" was doing double duty with the payload column set
(ledger #34) — now `schema/` holds contracts plus the one payload declaration
(`psr.header.json`), and the name says which is which. `contracts.tests`
globs `*.contract.json`; assemble's import-time load path, membrane docstrings,
assemble/crawler tests, AGENTS.md, module-notes, briefs, ledger #33 updated.
History (CHANGELOG-old, discussions, archived briefs, recon) left as written.
Battery: 15 suites, 869 pass, 0 fail.

## 2026-08-16 — psr header-row declaration (`schema/psr.header.json`); no row schema

Container spec named **psr** (piped snapshot rows); `.txt` stays as a reader
accommodation. `schema/psr.header.json` declares the admissible column
superset — `gidx<int:N> | path | content_meta:{…} | content_bytes | content` —
with framing (LF, no trailing `|`, UTF-8 no BOM), types, wire-name map
(`source`), invariants, and the reason there is no row declaration: rows are
the resolved header projected onto an entry, rendered and measured from the
same layout object. `attributes` → `content_meta` (noun; metadata about the
content span, paired with `content_bytes`); `length` → `content_bytes` (exact
byte width of the encoded span). Deliberately not `*.schema.json` (stage
contracts; ledger #34). shard-container-brief: new section; per-shard-header
leaning superseded by one header per run (partial presence → empty marker per
row). Ledger #45/#46 apply.

## 2026-08-15 — shards brief: planning is exact (Measure-Row from rs.core.container); doctrine narrowed

`briefs/shards-brief.md` adopts `design/gemini-shard-recon.md` (LTS knob roster,
pathology, five-phase algorithm) with corrections (three-segment `from`;
residues are facts; `SizeBytes` is excluded and not needed). Key change: shard
packing plans on `Measure-Row(entry, header, idxWidth)` — exact, computed
forward from the one layout function in a new `rs.core.container` dependency
(`Format-Row` → pieces; `Measure-Row`/`Render-Row`; `Measure-Content`/
`Encode-Content` over one codec table; fixed-width idx). AGENTS "planning is
not measurement" narrowed to *planning never reads written bytes; offsets stay
the writer's receipt*; ledger #39; #26/#27 stand. shard-container-brief seam
and shape updated to match. Anti-frag knob, packing constants, Flat sort key,
layout module name recorded as open calls.

## 2026-08-15 — Docket housekeeping: shard-container brief; dead briefs archived; ledger #33–38; stale pointers swept

`briefs/shard-container-brief.md` merges `schema-derivation` + `row-grammar`
under the payload vocabulary *header row · record row · framing* — "schema"
now means stage contract only; "row grammar" retired (the header row IS the
grammar; rows render from it). Container DNA named (CSV header + positional
records; JSONL self-documenting store; LPAC-style length-prefix framing;
informal columnar-SQL kinship); the coordination problem stated (configurable
row fields → header and rows from one declaration; LTS's ugly solution
enumerated as what must not come across); seam with `rs.core.shards`
(membership/order vs bytes) drawn. Five briefs archived to `briefs/.archive/`
with a README (the two merged; stage-appended-attributes SUPERSEDED;
old-tree-reconciliation DONE; swarm-plan CANCELLED). Decisions ledger gains
#33–38 for today's calls (per-stage contracts; schema-vs-header vocabulary;
module names vs pipeline vocabulary; membrane/GlobCompiler/GlobSemantics;
blacklist outside glob semantics; crawler free-at-vantage). All 14 remaining
`issues/v3/` pointers → `issues/reposnapshot/{design,planning,reports,discussion}/`.
Battery 15 · 869 · 0.

## 2026-08-15 — filter → membrane; pipeline vocabulary is admiral's, module names say what they implement

`rs.core.filter.psm1` → `rs.core.membrane.psm1`; `Invoke-Filter` → `Invoke-Membrane`;
`schema/filter.schema.json` → `membrane.schema.json` (`stage: membrane`; ingest
`from` refs follow); `tests/filter.tests.ps1` → `membrane.tests.ps1`. A membrane
is selectively permeable — selection, implicit (sentinels) or explicit (globs),
under either GlobSemantics, plus the hard exclusions — which says more than
"filter". Pipeline vocabulary *Discover → Membrane → Ingestion → Assembly →
Export* recorded in admiral-orchestration §"Pipeline vocabulary" and AGENTS.md:
it belongs to admiral's wrappers; atomic modules keep implementation names
(crawler implements discovery; shards + serialize + manifest implement export).
Battery 15 · 869 · 0.

## 2026-08-15 — Stage rename: ignore → filter; IgnoreCompiler → GlobCompiler; Regime/IngestMode → GlobSemantics

"Ignore" is a semantics, not a stage. `rs.core.ignore.psm1` → `rs.core.filter.psm1`;
`IgnoreCompiler` → `GlobCompiler` (semantics-neutral, as the C# descendant names it);
`New-IgnoreCompiler` → `New-GlobCompiler`; `Invoke-IgnoreFilter` → `Invoke-Filter`;
`Test-PathIgnored` → `Test-PathExcluded`; `-IngestMode` + `CompiledState.Regime`
→ one name, `GlobSemantics` / `.Semantics` (values `Ignore|Selection` unchanged;
pattern params unchanged). `schema/ignore.schema.json` → `filter.schema.json`
(`stage: filter`; ingest's `from` refs follow); `tests/ignore.tests.ps1` →
`filter.tests.ps1`. The hard extension blacklist is co-located with `Invoke-Filter`
and its purpose stated in place: an unconditional eligibility guard OUTSIDE glob
semantics — reposnapshot has no business ingesting binary blobs under either
semantics; a data list awaiting a run-config home. Historical docs keep old names;
`reports/ignore-semantics-update.md` carries a naming-update note. Battery
15 · 869 · 0 (identical counts — pure rename).

## 2026-08-15 — Ignore docstring slimmed; semantics doc stands alone

`rs.core.ignore` module docstring reduced to stages + regime-at-the-rim +
pointers. Its inline in/out examples were stale (pre-`Extension`) —
`schema/ignore.schema.json` is the tested truth. Semantics moved to
`issues/reposnapshot/reports/ignore-semantics-update.md` (carved out of the
backport report by the user; header/provenance added, cross-linked both ways).
`design/module-notes.md §rs.core.ignore` added. Battery 15 · 869 · 0.

## 2026-08-15 — Changelog cut-off 

- Froze old changelog and initialized new one starting from last change in previous copy
- because agents editing files can't help but read the entire file twice and this is a problem. 

## 2026-08-15 — Per-stage I/O contracts under `schema/`; cross-stage relations as set ops

`schema/{crawler,ignore,ingest,assemble}.schema.json` — each stage declares
`{ stage, in, out }` as field registers under named shapes. A field may carry
`from: "<stage>.out.<shape>"` (taken verbatim from upstream). New
`tests/contracts.tests.ps1` is generic over that convention: every `from`
resolves (input ⊆ upstream output, per field — 51 refs today), and join
residues are printed as INFO (`X.out.S − {fields any Y.out.* declares from
X.out.S}` = what is reachable only via `Y.out ⋈ X.out` on the retained
upstream). Probe: renaming an upstream field fails both downstream refs with
the upstream field list in the detail.

Assemble is not privileged: `assemble.schema.json` is now a real contract
(`in.bag` = what it reads; `out.entry` = core + elements − exclude), and the
module reads its OWN `out.entry.core` / `out.entry.exclude` at import — nothing
upstream's. The prior JSON-Schema-formatted prose (a schema in filename only;
nothing read it) is replaced; its Header/Diagnostics notes survive as `note`
fields. `crawler.tests` asserts descriptor/node/result shapes == `crawler.out.*`
exactly; `assemble.tests` asserts module lists == contract.

`schema/descriptor.json` (added earlier today) removed — a union register plus
assemble's projection in one file was the cross-stage god-view the per-stage
model avoids; its rows decomposed into `crawler.out.file`, `ingest.out.bag`
(file-read origins), and `assemble.out.entry.exclude`.

Battery: 15 suites · 869 passed · 0 failed.