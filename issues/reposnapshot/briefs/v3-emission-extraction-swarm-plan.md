# V3 emission extraction — swarm plan

> **CANCELLED 2026-08-14 (user), never dispatched.** The extraction stages need
> per-step judgment, and a verbatim port would carry LTS's structural warts
> across intact — see the conceptual decomposition that replaced this plan.
> Retained for the parts that survive cancellation: the break diagnosis, the
> airgap verification record, and the **docstring doctrine**, which still governs
> the eventual documentation pass. The wave/worker structure below is dead.

**Status:** CANCELLED · **Filed:** 2026-08-14 · **Precondition:**
commit `3b4f4e6` (LTS deps moved to `rs.lts.*`, `rs.core.template` →
`rs.core.manifest`, `rs.core.shards`/`rs.core.serialize` placeholders), the
follow-up `.ps1` → `.psm1` rename of the three v3 files, and the user's
**airgap completion** (2026-08-14: `rs.lts.numerics.psm1` copy created, all
`rs.lts.*` references repointed).

Scope is the cleanup half of the V3 sprint: **finish the LTS/v3 separation
(wirings done, identity residue outstanding), lift the `.txt` row/offset/tree
emission out of the LTS monolith into a self-contained `rs.core.manifest`, and
reconcile the docstrings of every file that overlapped LTS until this split.** Building `rs.core.shards`
and `rs.core.serialize` is *not* in scope — they stay placeholders here, and the
extraction is organized so that dividing manifest into them later is mechanical.

## What the survey established (verified in code, not recalled)

The rename left four live breaks, recorded below as the diagnosis of record.
**All four wirings were repaired by the user on 2026-08-14** (see "Airgap —
settled and verified"); the residue that survives is tracked in Wave 0.

1. **`rs.lts.sharding.psm1:43` — hard failure.**
   `Import-Module (Join-Path $PSScriptRoot 'rs.core.numerics.psm1') -ErrorAction Stop`.
   `$PSScriptRoot` is now the repo root; `rs.core.numerics.psm1` still lives in
   `reposnapshot-v3/`. The module cannot load at all, so fixing break 2 alone
   would only move the failure.
2. **`RepoSnapshotLts.psm1:21`** — imports `reposnapshot-v3\rs.core.sharding.psm1`,
   which no longer exists. Guarded by `Test-Path`, so it fails *soft* at import
   and *loud* at use: `Shard-SnapshotFile:2357` throws for any non-Flat grouping.
   Flat grouping never calls `Partition-Files`, so this break is invisible on the
   default path — the worst shape for it to have.
3. **`RepoSnapshotLts.psm1:11` and `:82`** — both resolve
   `reposnapshot-v3\rs.core.template.ps1`, renamed away. Same soft-fail; then
   `Import-TocTemplateEngine` returns `$false` and both `Get-RepoSnapshot` and
   `Shard-SnapshotFile` throw "Could not load TOC template engine." No tree
   manifest is emitted on any path.
4. **Identity residue.** `rs.lts.sharding.psm1:1325` stamps
   `module = "rs.core.sharding"` into shard metadata — a payload-visible string
   naming a module that no longer exists. `RepoSnapshotLts.psm1:2357`'s error
   text says the same.

One more fact that shapes the waves:

- **`rs.core.manifest.psm1` is a module in name only.** Its body is still the
  dot-source script: `$script:TocTemplate`, no `Export-ModuleMember`, and a
  `.NOTES` line reading "Standalone file — dot-source to use. Not a module."
  A `.psm1` with no explicit exports publishes every function, so the
  engine internals (`Resolve-TemplateValue`, `Expand-Template`) currently leak
  into the public surface by default rather than by decision.

## Airgap — settled and verified (user, 2026-08-14)

**Decision: full copy, no cross-boundary reach.** `rs.lts.numerics.psm1` now
sits beside `rs.lts.sharding.psm1` and `rs.lts.template.ps1` at the root, and
LTS reaches into `reposnapshot-v3/` for nothing. The recommendation on file was
the one-line cross-boundary path; the user took the stronger separation
deliberately — the point of this pass is that LTS and v3 stop being entangled
*before* the work starts, not that duplication is minimized.

**Verified working, not merely wired** (probe run 2026-08-14, read-only):

| scope | resolves |
|---|---|
| inside `rs.lts.sharding` | `Get-PathHash`, `Get-ContentHash`, `Get-SimHash` ✓ |
| inside `RepoSnapshotLts` | `Partition-Files`, `Expand-TocTemplate`, `New-ShardedTocModel` ✓; `Import-TocTemplateEngine` → `$true` |
| live call | `Partition-Files -GroupingStrategy Flat` succeeds, exercising the `Get-PathHash` sort |

**What this does NOT establish:** emission. `Get-RepoSnapshot` and
`Shard-SnapshotFile` were not invoked (they write artifacts), so the full-run
gate in Wave 0 stands unchanged. Dependency resolution is proven; the five
emission passes are not.

**Consequence — divergence is now intended, and must be stated in the files.**
Two copies of the numerics substrate exist. `rs.lts.numerics.psm1` is frozen and
retires with LTS; `rs.core.numerics.psm1` evolves with v3. A later reader — or
agent — encountering the duplication will otherwise "fix" it. Wave 3 owns
writing that down in both headers.

**And a standing correction about `rs.core.numerics` (user, 2026-08-14):** its
lack of consumers under `reposnapshot-v3/` is a **sequencing artifact, not
evidence of deadness.** Nothing imports it yet only because the LTS sharding
logic has not been adapted into v3 stages; `rs.core.shards` will consume it
(`Get-PathHash` for Flat ordering, content hashing for shard metadata). Do not
let any wave's inventory conclude it is vestigial — the inference is available
from the code and it is wrong.

## Docstring doctrine — the rule that makes the terseness pass safe

The v3 headers have grown to carry adjudication receipts (`rs.core.assemble.psm1`
opens with ~90 lines). Cutting them without a rule would shed the project's
"keep receipts" posture along with the bloat. The rule:

> **A docstring states the contract and points at the receipt. It does not
> restate the argument.** Inputs, outputs, invariants, ownership boundaries, and
> the one-line *what changed and why it matters here* stay. Rationale, measured
> evidence, superseded alternatives, and dated adjudication narrative move to (or
> stay in) `issues/reposnapshot/**` and `CHANGELOG.md`, referenced by path.

Receipts are not deleted — they are relocated or already duplicated. Any worker
that cannot find a receipt's home leaves the text in place and flags it rather
than dropping it.

## Swarm plan

Root integrator plus at most three workers per wave, exclusive file ownership
within a wave. Waves are strictly sequential; workers inside a wave are
concurrent and never share a file.

| Wave | Workers | Work | Exit gate |
|---|---|---|---|
| **0 — Residue & identity** | `lts-residue`, `v3-identity` | Wirings are repaired; sweep the surviving identity strings and prove emission still runs. Give the two empty placeholders real headers | LTS runs green on a **real invocation** — `Get-RepoSnapshot` plus `Shard-SnapshotFile` under both `Flat` and `ByRootDirectory` grouping, tree manifest written; `tests/run-all.ps1` battery green |
| **1 — Extraction contract** | `emission-inventory`, `contract-delta` | Read-only. Map every LTS span that moves, its eventual home, and the field-access delta between the LTS monolith entry shape and the v3 IR entry shape. Root alone writes the frozen map | A span-by-span extraction map and a field-access delta table, accepted before any port begins. No source files touched |
| **2 — Port into `rs.core.manifest`** | `manifest-port`, `manifest-harness` | Port the emission logic against the frozen map; build its suite in parallel (disjoint ownership: module vs `tests/`) | manifest emits shards + `_tree.md` from a synthetic IR with **no LTS import**; the seek contract round-trips byte-exact; LTS still green (Wave 0 gate re-run unchanged) |
| **3 — Docstring reconciliation** | `v3-headers`, `lts-headers`, `doc-crossrefs` | Apply the docstring doctrine across the files whose identity changed; reconcile the planning/design docs that name the old modules | No reference to `rs.core.sharding` or `rs.core.template` survives outside historical CHANGELOG entries; every touched file states its post-split identity in its first ten lines |

## Wave-specific requirements

### Wave 0 — `lts-residue` (owns `RepoSnapshotLts.psm1`, `rs.lts.sharding.psm1`, `rs.lts.numerics.psm1`)

Import paths at `RepoSnapshotLts.psm1:11/:21/:82` and
`rs.lts.sharding.psm1:43` are already correct and probe-verified. What survives
is three identity strings naming modules that no longer exist:

- `rs.lts.sharding.psm1:1325` — `module = "rs.core.sharding"`. This one is
  **payload-visible**: it is stamped into shard metadata, so it is a claim the
  artifact makes about its own provenance. Repoint to `rs.lts.sharding` and
  flag if any consumer keys on the old value.
- `RepoSnapshotLts.psm1:2357` — the throw text still reads "Ensure
  rs.core.sharding is imported." Misdirects anyone who hits it.
- `rs.lts.numerics.psm1:32` — header still reads `Module: rs.core.numerics`.
  The copy must name itself, or the airgap is undocumented at exactly the file
  that constitutes it.

Then prove emission, which the dependency probe did not cover: run
`Get-RepoSnapshot` and `Shard-SnapshotFile` for real under both `Flat` and
`ByRootDirectory`, into a scratch output directory, and confirm shards plus
`_tree.md` are written. Report the artifact paths.

- **Do not** touch the soft-fail `Test-Path` guards. They are what made break 2
  invisible, and hardening them is a behavior change to a frozen tool — file it
  as an observation instead.
- Constraint: LTS is frozen. Fix the identity strings, change nothing else.

### Wave 0 — `v3-identity` (owns `rs.core.manifest.psm1`, `rs.lts.template.ps1`, both placeholders)

- Convert `rs.core.manifest.psm1` to a real module: explicit
  `Export-ModuleMember` (public = `Expand-TocTemplate`, the model builders, the
  instruction-set getters; engine internals stay internal), and delete the
  now-false "Not a module / dot-source to use" note.
- Diverge the two copies' headers. `rs.lts.template.ps1` is the frozen LTS
  dependency: it keeps the "integration COMPLETE" statement, and **loses** the
  QUEUED Compaction block — that obligation is v3's and belongs only in
  `rs.core.manifest.psm1` (spec: `shard-format-notes.md` §"The Compaction
  block"; ledger #16).
- Replace both zero-byte placeholders with a header naming the concern each will
  own and an explicit "not yet implemented" line. A zero-byte `.psm1` imports
  clean and exports nothing, which reads as an accident rather than a
  placeholder.
- Do not implement anything in `shards`/`serialize`. Headers only.

### Wave 1 — `emission-inventory` (read-only)

Span-by-span map of what moves, with eventual home marked per span so Wave 2 can
lay the file out along the future split line:

| LTS span | function |
|---|---|
| `:953–1010` | `Get-EntryByteOffsets` — monolith-JSON offsets, likely **does not** transfer (the `.txt` path computes offsets inline) |
| `:1012–1083` | `Build-DirectoryTree` |
| `:1083–1161` | `Build-AsciiTree`, `Build-TreeDiagramCompact` — flag-gated views; confirm whether v3 wants them |
| `:1161–1220` | `Build-TocTree` |
| `:1228–1320` | `Get-SnapshotPathParts` / `-SiblingPath` / `-ArtifactPaths` — artifact naming convention |
| `:2288–2554` | `Shard-SnapshotFile`'s five inline passes: render · arrange · emit · measure · navigate |

For `:2288–2554`, decompose against the five-pass reading already recorded in
`discussion/opus-reposnapshotV3-LTS-updates.md:85`, and mark each pass's eventual
owner (`manifest` vs `serialize` vs `shards`) even though all land in manifest
now. That marking is the whole point — it is what makes the later split
mechanical instead of a second archaeology run.

Explicitly enumerate the **LTS-isms that must not come along**:

- The `ConvertTo-Json` content hop at `:2313` (`$cj.Substring(1, $cj.Length - 2)`).
  This is the source of the `\"` residue measured at 12% of all escapes in a
  production payload; `shard-format-notes.md` requires the v3 serializer to
  author its escaping directly, with no JSON anywhere behind it. **Root must
  adjudicate whether Wave 2 ports the escaping as-is behind a seam or stops at a
  codec hook** — see the open question below.
- `Write-Host` progress output and emoji.
- Disk-JSON input (`Get-Content | ConvertFrom-Json`) — v3's input is the
  in-memory IR.
- Sorting at serialization (`:2298`). IR order is canonical ingested order;
  arrangement is `rs.core.shards`' concern.

### Wave 1 — `contract-delta` (read-only)

Every field the ported code reads, LTS shape → v3 IR shape. Known starting set:
`$file.path` → `RelativePath`; `$file.content` → `Content`;
`$file.attributes.char_count | word_count | whitespace_ratio | entropy` →
`Attributes.*` PascalCase; `$file.attributes.size_bytes` → **`Attributes.SpanBytes`**,
which is a semantic change, not a rename (`SizeBytes` is on-disk and is excluded
from entry bags by assemble's macro-convention). Cross-check against
`rs.core.assemble.psm1`'s output contract and `schema/assemble.schema.json`.

Also report: which of these the `_tree.md` path needs (`Build-DirectoryTree`
takes a `FileSizeMap` built from `size_bytes` at `:2544` — under v3 that map has
no source unless it switches to `SpanBytes`).

### Wave 2 — `manifest-port` (owns `rs.core.manifest.psm1`)

- Port against the frozen map. Behavior-preserving on the row grammar and the
  offset arithmetic; adapted on the input contract.
- Self-containment is the deliverable: **no import of `RepoSnapshotLts.psm1` or
  `rs.lts.*` in any direction.**
- Lay the file out in the sections the Wave 1 map marks, so the eventual
  `serialize` split is a cut rather than an untangle.
- Per the user's staging call, consolidation comes first and the
  manifest/serialize boundary is iterated later — do not pre-split.
- Per `no-scripted-source-edits`: edit one file at a time with targeted edits,
  no bulk regex surgery across the port.

### Wave 2 — `manifest-harness` (owns `tests/`)

- New suite following the house harness pattern, and it must **fail loudly**:
  keep the `SUITE ABORTED` catch, and confirm the asserts actually execute
  (this repo has a recorded false-green history — `reposnapshot-test-harness-false-green`).
- The load-bearing assertion is the **seek contract**: for every emitted row,
  reading the shard file bytes at `row_content_begin..row_content_end` returns
  exactly the encoded content span, and its declared `length` matches the UTF-8
  byte count. That is the contract the whole format exists to keep, and it is
  the one an eyeball review cannot verify.
- Build a synthetic IR fixture rather than depending on a live crawl, so the
  suite tests emission in isolation.

### Wave 3 — three disjoint owners

- `v3-headers` — `reposnapshot-v3/*.psm1` whose identity or dependency set moved.
  Apply the docstring doctrine. Highest-value targets are the files that
  described a world where LTS and v3 shared modules.
- `lts-headers` — `RepoSnapshotLts.psm1`, `rs.lts.sharding.psm1`,
  `rs.lts.template.ps1`, `rs.lts.numerics.psm1`. Two jobs:
  - `rs.lts.sharding.psm1:20–34`'s DISPOSITION block is the main rewrite. Its
    "writer-phase reconciliations queued" list (ByteSpan → SpanBytes,
    ConvertTo-ShardFiles IR entry point) is **no longer this file's future** —
    those obligations followed v3 to `rs.core.shards`. Restate it as what it now
    is: a frozen LTS dependency, retired with LTS. Same for `:27`'s pointer into
    `rs.core.assemble-design.md`, which describes v3's plans, not this file's.
  - **State the intended divergence in both numerics headers.**
    `rs.lts.numerics.psm1` says it is a frozen LTS-only copy that retires with
    LTS; `rs.core.numerics.psm1` says LTS carries its own copy and this one is
    v3-exclusive, *and* that its current absence of importers is sequencing —
    `rs.core.shards` is its consumer. Both halves matter: without the first, the
    duplication reads as an accident; without the second, the module reads as
    dead code.
- `doc-crossrefs` — `AGENTS.md:76`, `planning/v3-consolidation-plan.md`,
  `design/rs.core.assemble-design.md`, `reports/lts-v3-transfer-audit.md`.
  Also correct the consolidation plan's stale §B **item 6d, which has in fact
  landed** — `processors/bag-helpers.ps1` and `tests/mutator-chain.tests.ps1`
  are in the tree, so the ISS-registered shared helper shipped with it. Leave
  CHANGELOG history untouched; it is a dated record, not a live reference.

## Open question for root adjudication (Wave 1 → 2 boundary)

**Does the port carry LTS's `ConvertTo-Json`-derived escaping, or stop at a codec
hook?** Carrying it gets a working `.txt` emitter in Wave 2 at the cost of
importing the exact residue `shard-format-notes.md` exists to eliminate — and the
seek-contract test would then pin JSON escape semantics, which the real codec
will change. Stopping at a hook leaves Wave 2's emitter incomplete until
`rs.core.serialize` has a codec. The middle path — port the emitter with escaping
behind a single injected function, defaulting to the LTS behavior and marked as
provisional — keeps Wave 2 runnable and makes the codec swap a one-function
change. **Recommended: the middle path**, with the seek-contract test written
against the *frame* (length prefix, offsets) rather than the escape alphabet, so
it survives the swap.

## Non-goals

- Implementing `rs.core.shards` or `rs.core.serialize` (headers only).
- The V3-native driver / admiral. The e2e wiring is the next sprint; this one
  ends with manifest emitting from a synthetic IR.
- The JSONL writer stranded in `rs.lts.sharding` — it migrates with the
  thread-corpus track.
- Any packing-grade or `MaxShardSizeBytes` naming change. Both are forward-only
  and land with `rs.core.shards`.
- Ledger opens (#13 `Header.Root`, #16 Compaction emission, #17 encoding, 6e).
  Wave 0 sites the Compaction *obligation* in the right file; emitting it is
  serializer-phase work.
