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
often 10–100× the surviving count. This is decisions-ledger #30 restated as a
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

**Payload boundary — `schema/descriptor.json` (2026-08-15).** The one place a
field is declared, and it is *read by code*: `rs.core.assemble` derives its
exclusion set (`scope=ingestion`) and core set (`scope=core`) from it at
import; `tests/crawler.tests.ps1` asserts the crawler stamps exactly the
`origin=crawler` fields (both directions); `tests/assemble.tests.ps1` asserts
the module's exclusion set equals the schema's. Anything not listed is an
element by default — the register declares dispositions, it does not close
the bag. To add a field: stamp it in its origin stage and add a line; forget
the line and it rides into the payload as an element, which the golden test
catches (the safe failure direction). If a writer later wants `CreationUtc`
in a tree manifest, flip its scope; the writer, not the crawler, makes that
call. `schema/assemble.schema.json` remains as documentation of the IR
macro-shape and is marked as not read by code — it defers field dispositions
to `descriptor.json` rather than repeating them (ledger #6).

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
not omission (decisions-ledger #29; admiral-orchestration §"Crawler ↔ ignore").

**Diagnostics.** `Skipped` is returned as a sibling of `Graph`, not folded into
it — the feed is already separate in substance (decisions-ledger #32). Each
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
