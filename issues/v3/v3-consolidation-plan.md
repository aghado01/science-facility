# v3 consolidation plan — shore up before breaking ground

**Status:** active plan · **Filed:** 2026-07-28

**Doctrine (user):** shore up the gaps, bugs, and follow-ups in existing
reposnapshot v3 code *before* breaking new ground. The next-stage work
(rs.core.assemble) waits until the pipeline it sits on is sound.

This doc is the canonical sequenced plan; design detail lives in the
cross-referenced docs. Update phase status here as work lands.

## Doc-alignment audit (2026-07-28 — applied)

- `ignore-selection-inversion.md`: dangling "v1 … below" reference fixed (v1
  was replaced in place; its record lives in the work log).
- Transfer-audit inventory (Ignore/selection row): now points at the completed
  Design v2 + reconciliation.
- `TODO.md`: antisemantics item marked design-complete with pointer;
  monolith-optional item marked subsumed by IR distillation; MVP-gaps item
  points here.
- Admiral brief open question 2 (RelativePath enrichment home) marked resolved
  → crawler output contract (ItemDescriptor).
- Remaining consistent set: admiral brief (mission, thinness, code/config,
  through-line, wrapper mechanism, ingest reframe, residues, control-flow
  opens) · transfer audit (inventory + session work log) · assemble seed
  (contracts, decomposition, golden validation) · inversion doc (lineage,
  Design v2, reconciliation, cautions).

## Open-items inventory

### A. Bugs / live breaks (fix first)

1. **Ingest→processor Items seam** — `Invoke-Ingest` passes AbsolutePath
   strings; processors expect descriptor objects; every chained item
   `_ChainHalt`s. (transfer-audit work log; assemble-design ItemDescriptor.)
2. **Crawler missing identity/stat fields** — no `RelativePath`, no
   `LastWriteUtc` on file entries; both free at walk time. (ItemDescriptor.)
3. **Ignore stamps RelativePath** — enrichment inside a filter stage; hidden
   dependency. De-stamp once crawler stamps. (admiral residue #1.)
4. **Colonel processor validation rejects interior helpers** — regex at
   `rs.core.colonel.v2.psm1` ReadProcessorScript kills tp-perplexity
   (`_MaskByRegex`). AST fix: reject only a single wrapping
   FunctionDefinitionAst / missing top-level param block.

### B. Refactors — design settled, code pending

5. **Ignore/selection Design v2** (`ignore-selection-inversion.md`): mode-aware
   rim over neutral core; regime-stamped `CompiledState`; override rescue;
   prune policy; config surface with binding-aware coherence validation.
   *Blocked only by naming adjudication (user):* `-Mode` values;
   `OverridePatterns` / `SelectionPatterns`; `ExecutiveOverrides` shim vs
   clean break.
6. **Crawler diagnostics split** (crawler's own TODO) — separate diagnostics
   feed from graph result. Optional rider on Phase 1; cosmetic.

### C. Capability gaps (LTS parity, pre-assemble)

7. **rs-attributes.ps1** — tail-step processor: entry metrics + binary flag;
   compute-by-default, emission is a writer knob. (transfer-audit disposition.)
8. **Pipeline smoke test / harness-as-admiral** — end-to-end
   crawl→ignore→ingest→file-read over this repo, exercising the
   build-against-absent-admiral contracts.

### D. New ground (after consolidation)

9. **rs.core.assemble** (name pending) per design seed: DispatchOutput +
   RunContext + AssemblyPolicy → IR; code-track adapter; golden data-to-data
   validation vs a fresh LTS monolith JSON.

### E. Explicitly deferred (unchanged)

Preview processor · Filter-Content retire decision · tree model home · all
writers/serializers · admiral implementation (brief keeps accruing) · thread
adapter + corpus first milestone · mutation-ownership doctrine beyond
copy-on-enrich (waits for admiral state design) · subaddressing.

### F. Adjudications needed from the user (grouped for one sitting)

- Ignore engine: mode/param naming; shim vs clean break (unblocks Phase 2).
- Assemble: module name; entry field naming (LTS snake_case vs PascalCase);
  thread-track global idx semantics (unblocks Phase 5 design finalization).
- Admiral (no code blocked): hand-off form; carried-state shape; control-flow
  classes/DAG representation.

### Out of repo (courtesy)

- ThermoMapper repo-audit `GatherScatter` dead-cache defect (cache never
  populated; result assignment inside miss branch) — flagged for a separate
  session in that repo.

## Sequenced phases

- **Phase 0 — doc alignment.** Done this pass (see audit above).
- **Phase 1 — identity seam unit** (items 1–3; optional rider 6).
  Crawler stamps `RelativePath` + `LastWriteUtc` → ignore de-stamps →
  `Invoke-Ingest` passes descriptors → smoke test (item 8) proves the chain
  end-to-end. Un-breaks the pipeline; retires admiral residues #1/#4.
- **Phase 2 — ignore engine pass** (item 5). Needs the naming adjudication
  first. Implements Design v2 per the reconciliation touch list; tests both
  modes, override rescue, coherence validation. Composes with Phase 1's
  de-stamping (same module; either order).
- **Phase 3 — colonel AST fix** (item 4). Small, independent; test =
  tp-perplexity compiles into a plan. Can interleave with any phase.
- **Phase 4 — rs-attributes** (item 7). Tail-step contract; tests follow
  processors/tests house pattern.
- **Phase 5 — rs.core.assemble** (item 9). The gate back to new ground:
  design-seed contracts + golden validation. Entered only when Phases 1–4
  leave the substrate sound.
- **Horizon (unchanged):** writers → admiral → thread-corpus milestone.

## Work log

- 2026-07-28 — Filed; Phase 0 applied.
