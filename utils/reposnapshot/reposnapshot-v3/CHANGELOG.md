# Changelog 

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