# Module notes — rationale and history displaced from docstrings

Docstrings state the contract; this file holds the *why*, the history, and the
deferred items that used to sit in module headers. One section per module,
same name as the file. When a docstring is slimmed, its exposition lands here
rather than being deleted. Nothing here is enforced — see AGENTS.md §"How to
read the design docs".

---

## rs.core.crawler

**Stamping rule (2026-08-15).** The crawler stamps everything that is free at
its vantage point: no extra syscall, no file read. It already holds a
`FileAttributes` value and a `FileInfo` per file and the whole graph in memory,
so `Extension`, `CreationUtc`, `FsAttributes` and per-node subtree rollups cost
nothing beyond what the walk was doing. Facts that cost a read — encoding,
binary sniff, hashes — belong to later stages, because the crawler walks
everything ignore is about to discard (`.git`, `node_modules`, build output),
often 10–100× the surviving count. This is decisions ledger #30 restated as a
criterion so it applies to fields nobody has named yet.

Fields exist for later consumers even when the next stage does not use them.
Ignore reads `$f.Extension` (since 2026-08-15; it used to re-derive with
`[Path]::GetExtension`) and fails fast if a descriptor lacks it, the same way
it already did for `RelativePath` — measure once at the vantage, read
downstream.

**Naming.** `FsAttributes`, not `Attributes`: `Attributes` is the rs-attributes
element (`Attributes.SpanBytes`) and the two must not collide once a descriptor
reaches an entry bag.

**One record, four names.** "Descriptor" (on `Graph[].Files`), "item"
(`$Item` in a processor), "bag"/"result" (in and out of the chain), and
"entry" (in the IR) are the *same record* at four points. Nothing declares
its fields in code; each stage clones it (`Copy-Bag`, a single `[ordered]`
cast over all keys) and adds. So a crawler field reaches assemble untouched,
and until 2026-08-15 the only field list anywhere was assemble's hardcoded
exclusion — knowledge of "which fields are ingestion-side" lived at the end of
the line, not with the field.

**Stage contracts — `schema/<stage>.contract.json` (2026-08-15).** Each stage
declares `{ stage, in, out }` as field registers under named shapes
(`crawler.out.file`, `ignore.in.node`, `ingest.out.bag`, `assemble.out.entry`,
…). A field may carry `from: "<stage>.out.<shape>"` — taken verbatim from
that upstream shape. That one convention makes the cross-stage relations set
operations, checked generically by `tests/contracts.tests.ps1` (knows no stage
by name): every `from` resolves (input ⊆ upstream output, per field), and the
**join residues** are printed — for each `Y.in ← X.out.S`, the fields of
`X.out.S` no `Y.out.*` declares `from` it, i.e. reachable downstream only by
`Y.out ⋈ X.out` on the retained upstream output (the orchestrator holds both).
Today's residues: `crawler.out.node − ignore.out.node = {Files, Subtree*}`;
`ignore.out.node` reaches nothing in ingest (flattening); `ingest.out.bag −
assemble.out.entry.core = exclude ∪ {Encoding, ReadError}` with the landing
open. Contracts prime a stage's semantics: assemble is not privileged —
`assemble.in.bag` names what it *reads* (RelativePath, Content, SizeBytes,
ReadError, _ChainHalt) and `assemble.out.entry` says what an entry *is* (core
+ elements − exclude); the module reads its own contract at import for the
`core` and `exclude` lists, nothing upstream's. `crawler.tests` asserts the
crawler's descriptor/node/result shapes equal `crawler.out.*` exactly;
`assemble.tests` asserts the module's lists equal its contract. Anything not
listed in an open shape is an element — contracts declare, they do not close
the bag. To add a field: stamp it, add it to the origin's `out`, add `from`
lines where it passes through, and (if it must not reach the payload) add it to
`assemble.out.entry.exclude`; forget the last and it rides in as an element,
which the golden test catches. A short-lived `descriptor.json` union register
(2026-08-15, one day) was replaced by this decomposition — a cross-stage
god-view read by assemble is what the per-stage model avoids.

**Rollups are on-disk, pre-filter.** `SubtreeDirCount` / `SubtreeFileCount` /
`SubtreeBytes` describe what is on disk under a node, computed in a
deepest-first pass over the graph after the walk. Ignore rebuilds nodes with
its own field set, so rollups do not ride through the filtered graph — and
should not, since post-filter they would be stale. They are crawler-output
facts; the orchestrator retains crawler output and hands them to whichever
consumer (shards, tree manifest) wants them.

**Path doctrine — store vs view, applied to paths.**
- `AbsolutePath` exists for unambiguous ingestion-side reads; it never appears
  in rendered snapshot artifacts.
- `RelativePath` is the artifact-facing identity: root-anchored, forward
  slashes, no leading slash. The snapshot is anchored to a root; the hierarchy
  is represented flatly and the nested structure is encoded in `RelativePath`
  alone — minimal tokens for an LLM reader that needs repository structure,
  not system locations.
- `NodePath` (directory portion, trailing `/`; root = `''`) is the graph key,
  duplicated onto file entries so descriptors remain self-standing after the
  graph is flattened for dispatch.
- All identity fields are stamped at walk time from data the walk already
  holds — `RelativePath = NodePath + name`, zero extra derivation. Downstream
  stages filter and enrich but never re-derive identity (ignore is a pure
  filter; processors copy-on-enrich). Resolved 2026-07-28; before that, ignore
  stamped `RelativePath` onto crawler objects (admiral-orchestration residue #1).

**Greedy crawl.** Ignore config does not live in the crawler; crawl everything,
filter afterwards. `New-FileSystemCrawler` takes only `-RootPath` by decision,
not omission (decisions ledger #29; admiral-orchestration §"Crawler ↔ ignore").

**Diagnostics.** `Skipped` is returned as a sibling of `Graph`, not folded into
it — the feed is already separate in substance (decisions ledger #32). Each
directory is its own failure domain; each entry's attribute read and each
file's stat are isolated so one bad entry does not lose the directory.

**Deferred (from the old `.TODO` block, kept for the record):**
- Split into a walk class and a graph class — maybe. Cosmetic.
- A separate diagnostics method rather than the sibling property. Cosmetic
  (#32).
- Optional max-depth parameter relative to root.
- Stage-appended attributes generalization (`.TODO` bullet 3) — landed as the
  stamping rule above plus the open-bag descriptor; the separate brief is
  superseded by that rule.

---

## rs.core.membrane (was rs.core.ignore, briefly rs.core.filter, 2026-08-15)

**Renamed 2026-08-15** — "ignore" is a *semantics*, not a stage. The stage is
a **membrane**: it decides which crawled files pass through — selection,
implicit (sentinels) or explicit (globs), under either semantics, plus the
hard exclusions. "Filter" was the first pick and lasted an hour; membrane says
*selectively permeable, and permeability is a property of the membrane, not
of the thing passing*, which is the design. Its dependency, the five-stage
compile machinery, is `GlobCompiler` (semantics-neutral — the C# descendant
in ThermoMapper's repo-audit already used `GlobCompiler` / `GlobSemantics`).
Names, old → new: `rs.core.ignore.psm1` → `rs.core.membrane.psm1`;
`IgnoreCompiler` → `GlobCompiler`; `New-IgnoreCompiler` → `New-GlobCompiler`;
`Invoke-IgnoreFilter` → `Invoke-Membrane`; `Test-PathIgnored` →
`Test-PathExcluded` ("ignored" was wrong
under Selection); `-IngestMode` param **and** `CompiledState.Regime` → one name,
`GlobSemantics` / `CompiledState.Semantics`, values `Ignore | Selection`
(unchanged, so `SelectionPatterns` etc. don't churn). Two names for one value
was the smell; "regime" was opaque; `IngestMode` had borrowed the
orchestrator's vocabulary for a stage param — admiral maps its `mode:` onto
`-GlobSemantics`. `IgnoreDefaults` / `IgnorePatterns` /
`IgnoreOverridePatterns` / `SelectionPatterns` / `SentinelFileNames` keep
their names: they name their own semantics correctly. Historical reports and
ledger entries keep the names of their day.

**The extension blacklist stands outside glob semantics — deliberately.**
reposnapshot has no business ingesting blobs of binary; a Selection run for
`*` must still not pull in a `.png`. So it is an unconditional eligibility
guard (with `MaxSizeBytes`) applied by `Invoke-Filter` before any glob test,
on the crawler-stamped `Extension`, and it does not invert with
`GlobSemantics`. It is data — a plain list — sitting in code because no
run-config system exists yet; the code path is already the additive
`-ExtensionBlacklist` param, so when admiral's config projection lands it
becomes `defaults.membrane.extensionBlacklist` in a one-line change. Co-located
with `Invoke-Membrane` (not the compiler) and declared in `membrane.contract.json`
so a reader finds it where the guard runs. Do not "unify" it into a glob
source.

Semantics have their own document: `reports/ignore-semantics-update.md`
(Ignore / Selection, Design v3, reconciliation with the code — carved out of
the backport report 2026-08-15; written with the pre-rename names).
Contract: `schema/membrane.contract.json`. Docstrings slimmed 2026-08-15; the
inline input/output examples were stale (pre-`Extension`) and are replaced by
the schema, which is tested.

**Reads `$f.Extension`** (since 2026-08-15) rather than re-deriving; fails
fast on a descriptor lacking `RelativePath` or `Extension` — the crawler
contract, checked at the boundary. Node rollups from `crawler.out.node` are
not carried (see contracts residue); the membrane rebuilds nodes with
`{ NodePath; AbsolutePath; NodeDepth; Files; CompiledState }`.
