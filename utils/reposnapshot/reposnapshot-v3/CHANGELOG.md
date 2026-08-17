# Changelog 

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