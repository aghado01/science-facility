# LTS ↔ v3 transfer audit

**Status:** scoping · **Filed:** 2026-07-22

## Provenance (why this audit exists)

The v3 modules were authored first; improvements were then **backported into the LTS
monolith** and v3 went stale (user, 2026-07-22 — this is how rs-psstrip fell behind its
own LTS descendant). Consequence: **LTS is not authoritative.** Not everything in LTS is
intended to transfer to v3, and backporting blurred which behaviors are design vs
monolith convenience. Every candidate transfer needs an intent re-evaluation first.

Per capability, the decision is one of: **transfer to v3** · **LTS-only convenience**
(dies with the monolith) · **retire**.

## Inventory — LTS surface vs v3 counterpart

| Capability | LTS (RepoSnapshotLts.psm1) | v3 counterpart | Direction / status |
|---|---|---|---|
| Comment stripping | `Normalize-FileContent` stage 4 — token walk (2026-07-22 fix); cs/py/js combined alternation scan | `rs-psstrip` (kind ops + masking + auto-route, ahead of LTS as of 2026-07-22), `rs-csstrip` | **Resolved both sides.** End state: LTS dispatches to processors (comment-ontology). rs-csstrip should adopt LTS's combined-alternation technique (superior to span regexes for cs/js) — evaluate. |
| Whitespace/normalize | `Normalize-FileContent` stages 1–3 | `format-ws` (richer op vocabulary) | v3 forward; check stages 1–3 for behaviors format-ws lacks (NBSP→space, region markers → `region-markers` kind). |
| Ignore/selection | `Get-GitIgnoredPaths`, `Read-GitIgnoreRules`, `Convert-GitIgnoreGlobToRegex`, `Build-GitIgnoreMatcher`, `Find-ExternalIgnoreRules`, `Normalize-PatternArray`, `New-PathInclusionTester` | `rs.core.ignore` (IgnoreCompiler: inheritance walk, exception domination, override bypass, regex cache) | v3 is the design forward. Audit LTS for semantics v3 lacks: external ignore rules, `SelectionOverrides` behavior; TODO's "antisemantics" toggle redesign lands here. |
| Binary/content filter | `Test-IsBinaryFile`, `Get-FilteredFiles`, `Filter-Content` (has the `-ExpandProperty Count -gt 0` bug) | `file-read` NUL guard; `Invoke-IgnoreFilter` size/ext blacklist | v3 forward; decide whether content-pattern filtering (`Filter-Content`) survives at all or retires. |
| Preview/byte offsets | `New-ContentAndPreview`, `Get-EntryByteOffsets` (UTF-8 byte-accurate — the seek contract) | none yet | **Transfer to v3** with the sharding writer; the byte-offset contract is load-bearing for the MCP fetch API. |
| Tree/TOC rendering | `Build-DirectoryTree`, `Build-AsciiTree`, `Build-TreeDiagramCompact`, `Build-TocTree`, `Import-TocTemplateEngine` | `rs.core.template.ps1` (handlebars-lite, TOC models) | Overlapping; verify whether LTS already loads rs.core.template (Import-TocTemplateEngine) and consolidate renderers in v3. |
| Sharding/output | `Shard-SnapshotFile`, `Get-ShardedRepoSnapshot` (.txt shards + `*_tree.md`, escaped rows) | `rs.core.sharding` (older 3.1 gen: JSONL/piped + toc + manifest) | **Format decision pending** (TODO: make json monolith optional; runstamped subdir convention). LTS's txt+tree format is the agent-proven one; v3 module likely needs rewrite-to-format, not transfer. |
| Orchestration | inline sequential + serialized-function parallel runspaces | `rs.core.colonel.v2` (ISS plan compile, chain executor, worker budget) | Colonel forward; LTS path retires when v3 pipeline is whole. |
| Path utilities | `Resolve-RelPath`, `Norm-Path`, `Get-SnapshotPathParts`, `Get-SnapshotSiblingPath`, `Get-SnapshotArtifactPaths` | crawler `ToNodePath`; sharding `Get-NormalizedPath`, `ConvertTo-RelativePath` | Consolidate into one v3 home (internals?); currently three dialects of path normalization. |

## Known cross-cutting items

- Instruction template drift: sharded instructions still say "seek to row_offset in the
  .json file" for .txt shards (visible in selfie tree.md).
- `Filter-Content` bug is live in LTS whenever include patterns/indicators are used.
- Subaddressing (extent linearization → composite chunks) will sit on the v3 side and
  is a *new* capability, not a transfer — but the shard-row/tree conventions it extends
  are currently defined by LTS output. Format decision above gates it.

## Work log

_(append findings/results here)_
