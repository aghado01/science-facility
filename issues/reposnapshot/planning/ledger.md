# Reposnapshot ledger — completed

Newest first. Evidence pointers are to commits, changelog entries, briefs, and
runner output. Counts are recorded **with the commit they were observed at** —
never as standing claims, and never hand-copied from prose.

Rulings live in [decisions.md](decisions.md); what remains lives in
[roadmap.md](roadmap.md).

- **2026-08-22 — container realigned onto the declaration; the spec became
  executable**: `rs.core.container` is now the declaration's interpreter — column
  register from `shard_container_schema.properties` in `col_position` order,
  `required`/`record_type`/`record_width`/`val_rank` vocabulary, header cells
  rendered from the item-array templates with scope ascent and computed forms
  resolved first, and every column bound by a `$ref` crosswalk that **fails at
  load** on a dangling pointer. The framing quartet (`FieldDelimiter ·
  BlockOpen · BlockClose · BlockDelimiter`) left the layout object rather than
  being renamed — under #49 the marks are items, so `Format-Row` returns a flat
  item list and row bytes are `Σ items + (n−1) + terminator`. `FloatPrecision`
  → `DoublePrecision` (the type is `double`; `properties.double_precision`).
  New suite `tests/container-spec.tests.ps1` (34) is the first reader the
  `record_pattern`s have ever had: it walks every `$ref`, and validates rows the
  module rendered **through the templates** against the spec's **own patterns**,
  across all four on/off configurations — the two sides written independently,
  so agreement is evidence. That round trip caught both defects it was built
  for (roadmap-scoped, now fixed): a leader bound of `{2,3}` that rejected the
  required-only layout, inherited from the pre-restructure spec; and an
  unspecified resolution order rendering gidx's pattern as
  `^[0-9]{digits(EntryCount)}$`. Battery at this commit: **17 suites · 1049
  passed · 0 failed** — verified by running `tests/run-all.ps1`. Arithmetic:
  937 (the standing green) + 78 (container, realigned and extended from 70) +
  34 (the new spec suite) = 1049.

- **2026-08-22 — psr wire settled (#49)**: a row is a list of items joined by
  exactly one space — values, keys carrying their colon, and the marks `|` `[`
  `]` `,`; a sub-grammar renders itself first and enters as one item.
  `container.spec.jsonc` v0.4 → v0.5 (`item_join`, templates as item arrays,
  `${cells}` splice, scope and resolution-order rules stated, `empty_marker`
  corrected, leader bound `{2,3}` → `{1,3}`). Chosen on declaration and
  interpreter simplicity, not economy: measured on a real 4.6 MB payload the
  spacing costs **+0.046%** tokens against fully tight, and removes the `]|`
  merge tight `|` produced in **102/102** rows. `cd89673`, `3e05f8e`.

- **2026-08-19 — planning canon minted** (this tier): `decisions-ledger.md`
  renamed `decisions.md`, `roadmap.md` and this ledger seeded from the
  consolidation plan's work log, the changelog, and the code arc. The
  consolidation plan moved to [../reports/](../reports/) with a superseded header —
  it was executed through Phase 5 on 2026-07-29 and had been carrying a live
  status registry, a work log, and a forward plan in one document.
  Battery at `87dcb8c`: **16 suites · 937 passed · 1 failed** — verified by
  running `tests/run-all.ps1`, not copied from prose. The single failure is
  `container.tests.ps1` aborting at load against the restructured
  `container.spec.jsonc`; 937 + its 70 asserts = the 1007 recorded at the
  container landing, so nothing else regressed.

- **2026-08-18 — psr container spec restructured and renamed**
  (`8f7df98` → `2e83f71` → `1c9b12b` → `87dcb8c`): `schema/psr.header.json` became
  `contracts/container.spec.jsonc`, gaining a property-tier convention block,
  interpolation grammar (`${prop}`, `${col.prop}`, `digits(EntryCount)`), and
  `$ref` pointers into the source-of-truth contracts. The column register moved
  under `shard_container_schema`. **`rs.core.container` has not been realigned to
  the new shape** — first item on the roadmap.

- **2026-08-18 — packing objective resolved as a shape** (#48): `PackObjective =
  FrontLoad | Even`, both implemented; least-overshoot demoted from a value to an
  invariant both shapes honor; the per-shard primitive is signed `DeviationBytes =
  PlannedSizeBytes − quota`, with overshoot, slack, and `Class` derived from it and
  the clamp never stored. This closed the 08-16 "strict + tolerance" open call —
  its two candidate procedures turned out to be the two shapes, not two routes to
  one. Also settled: no preset/profile layer over the packing knobs (#40).

- **2026-08-17 — `rs.core.container` landed** (`a2e63dd`, verbs approved
  `c2e2a65`): export phase 0. `Resolve-Layout` resolves the run's psr layout from
  the declaration × run config × `EntryCount`; the codec is one compiled regex
  rule table behind `ConvertTo-ContentSpan` / `Measure-ContentSpan` (whole-string
  UTF-8 width ± per-match deltas, exact against encode including surrogates);
  `Measure-Row` / `Build-Row` and the header-row pair make row bytes and the
  offset receipt one layout function. SPEC rules 1–4, UTF-8 no BOM, LF only, fixed
  widths as plan-time bounds that throw on overflow. `tests/container.tests.ps1`
  (70). Battery at that commit: **16 · 1007 · 0**.

- **2026-08-17 — naming reached the wire** (`fe0ab27`, `5a7495a`, `1c405ec`):
  `format-ws` → `rs-whitespace` (the name says its code lane), `rs-attributes` →
  `rs-content_meta` (after the psr block it feeds), element `Attributes` →
  `ContentMeta` — one concept, three casings by convention. Decision #26 stands
  unchanged through the rename.

- **2026-08-17 — export contracts minted** (`f230558`): container, shards,
  serialize, manifest; `contracts.tests` extended to accept nested-register
  `from` pointers.

- **2026-08-16 — contract vocabulary settled** (`c17e799`, `6ed9165`, `0988179`,
  `43fa943`): per-stage I/O contracts under `schema/` with cross-stage relations
  as set operations, then renamed `*.schema.json` → `*.contract.json` because
  "schema" was doing double duty with the payload column set (#33/#34). The
  short-lived union register `descriptor.json` was dissolved — it was the god-view
  the contract split exists to avoid. psr header-row declaration added; **no row
  schema, and there must not be one** — a record row IS the header projected.

- **2026-08-16 — stage renamed `ignore` → `membrane`** (`9236681`, `0f77412`):
  `IgnoreCompiler` → `GlobCompiler`; `-IngestMode` and `CompiledState.Regime`
  collapsed to one name `GlobSemantics` (#36). A membrane is selectively
  permeable and permeability is the membrane's property; "ignore" was a semantics,
  not a stage. Pure rename, 869 asserts on both sides. Pipeline vocabulary
  (*Discover → Membrane → Ingestion → Assembly → Export*) recorded as the
  admiral's, with module names left saying what they implement (#35).

- **2026-08-16 — docket housekeeping** (`7d6d594`, `dac5510`): `shard-container-brief`
  minted, merging `schema-derivation-brief` and `row-grammar-brief` (both archived);
  "row grammar" retired. Shards brief established that planning is **exact**,
  computed forward from `Measure-Row` (#39), narrowing the AGENTS rule "planning is
  not measurement" to *planning never reads written bytes*. Decisions #33–#38 filed.

- **2026-08-15 — the codec and whitespace decisions closed out** (#7–#25):
  round-trip demoted to an ingestion ideal, `\` never self-escaped, EOLs normalize
  rather than preserve, compaction demoted from cipher key to notice. Bidi controls
  ruled **not** strippable and reassigned to a diagnostic step (`8efc094`) — the
  Trojan Source framing was overstated, since the divergence needs a renderer in the
  path and there is none. Crawler began stamping what is free at its vantage
  (`c967c61`), which replaced the stage-append mechanism with a criterion (#31/#38).

- **2026-07-29 — Phase 5 landed: `rs.core.assemble`** (consolidation plan item 9):
  fixed phases, open element model, lean-payload routing, RunContext stamping with
  a reserved-name guard. `tests/assemble.tests.ps1` 53/53 **including golden
  validation** — v3 IR against a live LTS monolith, content byte-exact by path key,
  attributes formula-equal, known deltas asserted as documented. Nine-suite battery
  at that checkpoint: **307/307**. LTS stopped being load-bearing for the code-track
  data model. Two latent finds en route: the if-expression single-element unroll,
  and item 6d (tp-era envelope contract vs descriptor contract).

- **2026-07-29 — three docstring audits** (processors, stage modules, planning
  docs): v1 API remnants purged fleet-wide, per-processor item contracts declared —
  which is what made the 6d fault line visible in the docs rather than only in code.

- **2026-07-28 — consolidation Phases 0–4 executed**: doc alignment; the identity
  seam (crawler stamps the full identity contract at walk time, ignore de-stamps,
  ingest passes descriptors, smoke test proves the chain); the ignore engine pass to
  Design v3; the colonel AST fix; `rs-attributes` as the tail-step contract. All
  §A bugs and all §C capability gaps closed.

- **2026-07-28 — LTS/v3 airgap taken as a full copy** (#3): `rs.lts.sharding` /
  `rs.lts.template` / `rs.lts.numerics` at root, with LTS reaching into
  `reposnapshot-v3/` for nothing. The recommendation on file was a one-line
  cross-boundary path; the stronger separation was taken deliberately so the two
  stop being entangled *before* the work starts. **The two numerics copies will
  diverge, and that is intended.**
