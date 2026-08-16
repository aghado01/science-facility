# Changelog 

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