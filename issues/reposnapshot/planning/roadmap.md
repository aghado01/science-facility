# Reposnapshot roadmap — ahead only

Completed items move to [ledger.md](ledger.md); rulings land in
[decisions.md](decisions.md); declarations the payload owes a reader are tracked
separately in [payload-manifest-ledger.md](payload-manifest-ledger.md).

Tracks are **named, not numbered**. Ordering *within* a track is the current
recommendation, not a contract. Tracks marked independent may run in parallel.

The throughline: v3's substrate is sound and battery-green through **assemble**;
**export** is the frontier. Export phase 0 (`rs.core.container`) landed
2026-08-17; phases 1 and 2 (`rs.core.shards`, `rs.core.serialize`) are empty
module files with a complete brief behind the first. Finishing v3 is how the Node
successor gets specified (decision #2) — so at every fork, the simpler answer is
the one that does not have to be re-derived in another language.

## Track: container-spec-realignment — *blocking, immediate*

The psr declaration was restructured and renamed (`schema/psr.header.json` →
`contracts/container.spec.jsonc`, 2026-08-18), and the change has not reached the
module that reads it.

Scoped 2026-08-22: it is **five deltas, not a lookup rename**, and one of them
moves the wire. Battery reproduces **16 suites · 937 passed · 1 failed** at
`87dcb8c` (verified by running it, 2026-08-22); the shortfall is exactly
`container.tests.ps1`'s 70 asserts, which abort at load —
[rs.core.container.psm1:220](../../../utils/reposnapshot/reposnapshot-v3/rs.core.container.psm1).

1. **Column register moved** — `$decl.columns` →
   `$decl.shard_container_schema.properties`. Top-level keys are now `format ·
   name · version · description · properties · conventions ·
   shard_container_schema · invariants`.
2. **`framing` dissolved** — `encoding`/`bom` are top-level `properties`;
   `record_delimiter`/`column_separator` sit on `shard_container_schema`; the
   block's enclosure is a per-column `record_val_enclosure` + `val_separator`.
   Under #49 the quartet `FieldDelimiter · BlockOpen · BlockClose ·
   BlockDelimiter` **leaves the layout object entirely** rather than being
   renamed — the marks are items.
3. **Per-column vocabulary** — `presence` → `required` (bool), `width` →
   `record_width`, `type` → `record_type`, `fields` → nested `properties`,
   `$default_on` → per-sub-field `default: true` ordered by `val_rank`.
4. **Source binding is a `$ref` crosswalk, not a grammar string** — the four-form
   `source` read by `Resolve-SourceValue` is now `record_value.$ref` /
   `val.$ref` into the sibling contracts, and `conventions` requires the accessor
   be derived from the ref and to **fail at load** if the pointer does not
   resolve. This is new capability, not a rename, and it is the piece with no
   test behind it: `contracts.tests.ps1` explicitly excludes `container.spec.jsonc`
   from stage-contract parsing ([:102](../../../utils/reposnapshot/tests/contracts.tests.ps1)),
   so the spec is presently a document the suite does not read — decision #6's
   failure mode on #6's own subject.
5. **The wire changed** (#49) — header cells render `name: type` from item-array
   templates, rows are item lists joined by one space. `HeaderRowText`,
   `Measure-Row`'s delimiter arithmetic, and ~20 expected-string asserts in
   `container.tests.ps1` all move. Blast radius stops there: `Resolve-Layout` has
   exactly one consumer suite and shards/serialize are empty files.

A ~40-line interpreter prototype confirms the declaration is **sufficient** —
it renders the header from the spec alone, with the byte identity
`Σ items + (n−1)` checking exactly (175 = 175). Port that shape, do not
hardcode the spacing.

Exit: battery green, count recorded with the commit it was observed at; the
spec parsed and its `$ref` pointers resolved by a test that runs.

## Track: export-e2e — *the main line; assemble → shards → serialize → manifest*

1. **`rs.core.shards`** — the brief is complete and the algorithm is settled;
   the module file is empty. Policy stack, objective, and packing procedure are
   decisions #40–#48; `PackObjective`'s default is deliberately open pending the
   comparison harness on real payloads (#48). Planning is exact via `Measure-Row`
   from the container (#39), so the packer is testable on synthetic size vectors
   before any payload exists.
2. **`rs.core.serialize`** — empty module, no brief yet. Writes what shards
   planned; the container already owns row bytes and the receipt, so serialize's
   scope is the write itself plus offset provenance.
3. **`rs.core.manifest`** — 327 lines of ported LTS template/TOC code are
   present (`New-SnapshotTocModel`, `New-ShardedTocModel`, `Expand-TocTemplate`).
   Owed: reconciliation against the psr declarations and the payload-manifest
   ledger's `live` entries.

Exit gate: `shards-brief` §Exit gate, plus the comparison harness in the battery
rather than on the shipping path.

## Track: encoding-lookback (6e) — *independent, unblocked*

Filed and unblocked, not started — the one assemble-facing item the emission work
touches (#28; payload-manifest #17). The fork is **detect-or-rename**, and
everything else follows from it: either ingest actually sniffs source encoding, or
`file-read.ps1`'s constant `Encoding = 'UTF-8'` stops claiming to be a
measurement. `Encoding` rides into every entry bag and counts as a fully-present
element in `Header.Elements` though it is a run-level constant whose home is
Header. Deliberately a decide-together set with golden-test exposure, not a
drive-by. Scoped in [encoding-lookback-brief](../briefs/encoding-lookback-brief.md).

## Track: open calls owed

Each of these is recorded as owed, not answered. The live discussion lives in the
source doc; the ledgers only record that the call is outstanding.

**Decisions ledger** — #22 ops mostly non-configurable (leaning) · #42
`AllowOversizedShards` retirement (leaning) · #45 LF-only row termination,
trailing `|` dropped (leaning; propagate to `shard-container-brief`) · #46 which
address columns v3 carries (open) · #48 `PackObjective` default (open).

**Payload manifest** — #6 channels carried · #10 ignore/selection regime · #12
header `flags` block, retire vs keep · #13 `Header.Root` emission posture vs path
doctrine · #14 `git_history` enrichment · #17 the two encoding declarations. #11
effective-config resolver is deferred; #7, #9, #15 are forward work.

**User adjudications** (from the consolidation plan §F, none blocking code) —
header `flags` block · `Header.Root` posture · the tp-era envelope's
wire/arrangement fate for the thread track · admiral's hand-off form, carried-state
shape, control-flow classes, and invocation-surface duality.

## Track: side quests — *non-blocking, pick up when the main line allows*

- **Character-scan diagnostic** — filed, not started. Bidi controls are reported
  by a read-only diagnostic step rather than stripped (#11/#11b); the decision is
  already captured, so deferring the code loses nothing.
  [charscan-diagnostic-brief](../briefs/charscan-diagnostic-brief.md).
- **Structural survey elements** — SHELVED. Downstream of the writer phase giving
  payloads real addresses. PS extraction is prototyped in
  `tools/rs.dev.signatures.psm1`; the port is a **wrapper** on it, never a copy.
  [structural-survey-brief](../briefs/structural-survey-brief.md).

## Deferred

Restated so they cannot fall out. These become consumers only after the export
phase is trustworthy.

- **AST-based fragmentation** — one record per H2, semantic sub-addressing.
  Explicitly off the v3 critical path (#47); the packer contract is already
  fragmentation-agnostic, so it lands upstream without touching the export stage.
- **Admiral orchestration** and the **thread-corpus milestone**.
- **Content-class dispositions** — config-as-pointer, docs-as-own-track.
- **Shared ISS-registered helper library**; **declarative ISS composition**;
  **effective-config resolver** (consolidation §E).
- **`rs.core.numerics` beyond hashing.** Not dead code (#4), but its consumers
  thinned: `Get-PathHash` survives only as an optional `GroupSort` key, and
  `Get-ContentHash` needs its two senses separated — a **source** hash (cross-run
  identity, an enrichment processor's job) versus a hash of the **encoded span**
  (verifiable by a reader, free in the container's encode fold, but invalidated
  whenever the codec changes). The similarity family and `Get-DocStats` have no
  consumer on the critical path and are more likely the Node successor's than
  v3's. Rationale in [numerics-roadmap](../design/numerics-roadmap.md).
- **The MCP successor.** No MCP is built on v3 (#1) — agent-facing tooling becomes
  a separate Node implementation and the PowerShell tool stays CLI. Wishlist in
  `reposnapshot-v3/TODO.md`, design in [mcp-surface](../design/mcp-surface.md);
  the two overlap and have not been folded.
