# Reposnapshot roadmap — ahead only

Completed items move to [ledger.md](ledger.md); rulings land in
[decisions.md](decisions.md); declarations the payload owes a reader are tracked
separately in [payload-manifest-ledger.md](payload-manifest-ledger.md).

Tracks are **named, not numbered**. Ordering *within* a track is the current
recommendation, not a contract. Tracks marked independent may run in parallel.

The throughline: **the export phase is complete** (2026-08-24) — assemble →
container → shards → serialize → manifest all landed and battery-green, and the
selfie fixture runs the whole path against the module's own source every
battery run, seek-verifying the payload on disk. The writer-phase LTS-parity
gap is closed. Finishing v3 is how the Node successor gets specified
(decision #2); what remains is calibration and the tracks below.

## Track: export calibration — *what the completed phase unblocks*

- **The #48 default** — the selfie prints the 4-cell harness on real data every
  battery run. First numbers (one corpus, Flat): flexible earns a shard over
  strict (Gap 0, at the bound); the shapes coincide under strict; under
  flexible, Even beats FrontLoad on both overshoot aggregates at equal count.
  Wanted before deciding: more corpora (ThermoMapper-scale, grouped) and a
  quota/tolerance sweep.
- **A user convenience entry point** — the chain is callable but only tests
  drive it end to end; `_rs.scratch.ps1`'s replacement (old TODO) is now one
  thin script over six function calls, plus the runstamped-subdirectory output
  convention (old TODO).

## Track: crawler-profile — *independent; schedule AFTER shards*

Crawler's `CreationUtc` and `FsAttributes` have no reader at any RS stage — they
are declared as pass-throughs through membrane and ingest and dropped by
assemble's exclusion list. They are **not** residue: they are free only at crawl
(one `FileInfo`, one stat — #38 clause 4), and crawler has standalone value, so
the RS pipeline's disinterest is a profile setting rather than evidence the field
is wrong. Make what crawler gathers **configurable** by field group
(`identity` always · `size` · `timestamps` · `fsattrs`), so an unused field is an
unselected option and the standalone caller is a first-class user rather than a
fork.

The cost is not in the crawler — it is that a configurable output shape makes
the **`from` graph conditional**, so `contracts.tests` must distinguish "optional
field legally absent" from "`from` does not resolve". That is the only item in
the backlog that changes what the *generic* suite accepts rather than what one
contract says, which is why it waits for shards: two moving pieces under one gate
is the avoidable mistake. Nothing in shards depends on it — `ByFileType` needs
`Extension`, which is in `identity` and always on.

Scoped in [crawler-profile-brief](../briefs/crawler-profile-brief.md).

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
`AllowOversizedShards` retirement (leaning) · #46 which address columns v3
carries (open) · #48 `PackObjective` default (open). *(#45 closed 2026-08-22 —
settled and propagated.)*

**Container brief** (reconciled 2026-08-22; buffering settled 2026-08-24 in
`rs.core.serialize` via `-Buffering PerShard|Stream` byte-identical) —
empty-content rows: the LTS `row_content_end == row_content_begin` branch is
ported and asserted, but under LeanPayload the case may be unreachable, in
which case the branch should go rather than be kept alive by its own test. Two
exit-gate items are also still unmet and now named as such: the LTS column-set
comparison, and the novel-element e2e claim.

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

- **The rollup as a callable** (#52's remaining half) — *trigger-gated, not
  scheduled*. `BuildRollups($condition)` is a private crawler method today: one
  definition, one call site, conditioned on the walked set. #52 says the definition is the
  single source of truth and a second condition is a second **call site**, never a
  second loop. So the day something wants a rollup over a different predicate —
  a manifest declaring per-directory payload sizes, a diagnostic totalling what
  the membrane discarded — the work is to lift it to a callable over
  `(atoms, condition)` and emit another layer of the same shape. **Do not do
  this speculatively**: with one condition it is indirection with no second
  caller.
  **The precondition is the trap.** A subtree rollup conditioned on the
  survivors needs
  `SizeBytes` at the call site, and `SizeBytes` is excluded at assemble — the
  atom dies before any downstream caller could exist. So the callable and the
  atom retention (`SizeBytes` → `carried`, #50) are **one change, not two**;
  picking up the callable alone gets you a function with nothing to sum. The
  discards path is already fine — `membrane.out.skipped` / `ingest.out.skipped`
  carry `SizeBytes` and `Extension`.
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
