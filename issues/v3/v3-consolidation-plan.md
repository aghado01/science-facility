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
6b. **Legacy `tests/colonel.tests.ps1` is stale** — targets the retired
   `rs.core.colonel.psm1` (v1) path; refresh against v2 or retire (small).
   Validation coverage now lives in `tests/colonel-validation.tests.ps1`.
6c. **rs-psstrip FrontMatter kind promotion** (design clarified by user
   2026-07-28, comment-ontology item 1): replace the `^#requires\b`
   population-exclusion text guard in the AST route with classification to a
   named `FrontMatter` kind — lexical objects filtered by kind name; text
   pattern recognition belongs to the regex fallback route only. Includes
   explicit run-splitting semantics + clean-parse preservation asserts in
   rs-psstrip.tests.ps1 (68/68 baseline).
   **Scope sharpened after reading the lineage source** (psdig
   ast-primitives — extraction recorded in comment-ontology item 1): restore
   the *partition at the parse boundary* — text match exactly once at the
   promotion site producing Derived kind objects with spliced
   `$ast.ScriptRequirements` metadata; classification consumes the Native
   stream with zero text predicates. Implemented as an interior helper
   (permitted since the Phase 3 colonel AST fix — the sequence unblocked its
   own next item); centralization **adjudicated 2026-07-28: self-contained**
   (no rs.core ast-primitives module — PS prominence in RS processing is
   contingent; script-surface generality not needed now; see the
   comment-ontology language-expansion doctrine: thoughtful-regex processors
   are the default for new languages, native AST on demand). 6c has zero
   open decisions.

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
- 2026-07-28 — **Phase 1, crawler step landed** (item 2): file entries now
  stamp the full identity contract `{AbsolutePath; RelativePath; NodePath;
  SizeBytes; LastWriteUtc}` at walk time — `RelativePath = NodePath + name`
  (zero extra derivation), one FileInfo for size + last-write, skip reason
  renamed `FileStatReadFailed` (no consumers). Path doctrine recorded in the
  crawler docstring + assemble-design (user: absolute = ingestion reads only;
  relative = artifact-facing, root-anchored, structure encoded flatly for
  LLM-reader token economy). New `tests/crawler.tests.ps1` (house harness
  style, 27 asserts) green; real-repo smoke green (108 files, 0 skipped).
  Next: ignore de-stamp (item 3) → ingest descriptor hand-off (item 1) →
  pipeline smoke (item 8).
- 2026-07-28 — **Phase 1 COMPLETE** (items 1, 3, 8 + a bonus bug). Ignore
  de-stamped (pure filter; vestigial `RootPath` param removed — no external
  callers; fail-fast guard on pre-contract graphs). Ingest dispatches
  ItemDescriptor objects verbatim; file-read copy-on-enrich now clones ALL
  input properties (descriptor-evolution-proof). New
  `tests/pipeline.smoke.tests.ps1` (harness-as-admiral, 23 asserts) green —
  **first-ever end-to-end run of the v3 pipeline** (crawl → ignore → ingest →
  colonel → file-read). First contact flushed out a latent bug beyond the
  seam: `IgnoreCompiler.GetParentPath` declared `[string]` coerced its
  `return $null` to `''`, making Prune's ancestor walk an infinite loop —
  fixed as `[object]` return with the null-contract documented (C# lineage
  returns `string?`; the PS transliteration's typed return swallowed it).
  Also normalized an accidental operator line-split in the empty-leaf prune
  predicate. Phase 1 exit criterion met. Next: Phase 2 (ignore engine pass —
  needs naming adjudication) or Phase 3 (colonel AST fix) — Phase 3 has no
  open decisions and can proceed immediately.
- 2026-07-28 — **Phase 3 COMPLETE** (item 4). Colonel processor validation is
  AST-based: top-level param block required (chain-executor's positional
  contract), parse errors surfaced, #Requires rejection unchanged; interior
  helper functions legitimate. tp-perplexity compiles into a plan for the
  first time — thread-corpus open decision 6 resolved. New
  `tests/colonel-validation.tests.ps1` (12 asserts) green; smoke (23) +
  crawler (27) re-run green. Ignore-engine candidate naming recorded (user,
  not settled): `IngestMode` / `IgnorePatterns` + `IgnoreOverridePatterns` /
  `SelectionPatterns`. CHANGELOG 2026-07-28 section added covering Phases
  1+3. Item 6b filed (legacy colonel.tests.ps1 stale, targets v1 path).
  Remaining before Phase 5: Phase 2 (awaits final naming), Phase 4
  (rs-attributes — unblocked).
- 2026-07-28 — **Phase 4 COMPLETE** (item 7): `processors/rs-attributes.ps1`
  landed. Positional doctrine sharpened with user: language-agnostic BY
  POSITION; the invariant is "after ALL content mutators" (not just
  language-specific ones) — enrich-only step, placed in the read-only tail;
  position is a profile invariant (admiral's), processor stays
  position-ignorant. No-Content contract (pass through unenriched) makes it
  safely appendable to arbitrary profiles incl. thread envelopes. Provenance
  split documented: SizeBytes = on-disk; Attributes.* = processed content.
  **LTS defect found during parity testing**: `compression_ratio` is 0 for
  every >100-char LTS entry (MemoryStream.Length read after GZipStream.Close
  disposal → null → 0; verified in the 20260723 selfie monolith).
  rs-attributes computes the real ratio (`ToArray`) — recorded as a golden-
  compare known delta in assemble-design. Tests:
  `processors/tests/rs-attributes.tests.ps1` (34 asserts — parity formulas,
  no-Content, empty content, copy-on-enrich, colonel dispatch incl. GZip
  resolution in worker runspaces) green. Next processor item: 6c
  (FrontMatter partition in rs-psstrip).
