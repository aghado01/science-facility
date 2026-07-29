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
6d. **tp-era item-contract harmonization** (found 2026-07-29 during Phase 5):
   `format-ws.ps1` and `rs-psstrip.ps1` unpack `$Item.Text` and REPLACE the
   bag with an Id/Path/Text envelope — the tp-era contract, incompatible
   with the descriptor contract (`Content`, open-bag copy-on-enrich). In a
   code-track chain they would destroy identity fields. Harmonize: accept
   Content|Text, enrich-in-place instead of envelope replacement (or an
   adapter shim); decide the envelope's fate for the thread track. Blocks
   content-transform parity (strip/ws) in code-track chains and the
   comment-ontology "LTS dispatches to processors" end state.
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

> **2026-07-29: Phase 5 LANDED** — `rs.core.assemble.psm1` implemented per
> the design doc (fixed phases, open element model, lean-payload routing,
> RunContext stamping with reserved-name guard). `tests/assemble.tests.ps1`
> 53/53 including the **golden validation**: v3 IR vs live LTS monolith,
> content byte-exact by path key, attributes formula-equal, known deltas
> asserted as documented. Nine-suite battery **307/307**. LTS is no longer
> load-bearing for the code-track data model. Two latent finds en route:
> the if-expression single-element unroll (fixed in assemble's stream
> pass-through) and item 6d (tp-era Text/envelope contract vs descriptor
> contract in format-ws/rs-psstrip — filed). Remaining horizon: writers →
> admiral → thread track (+ 6d before strip/ws joins code-track chains).

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
- 2026-07-28 — **Payload doctrine recorded** (user; assemble-design §Payload
  doctrine): (a) **byte semantics, three layers never conflated** —
  SizeBytes (filesystem bookkeeping; sole consumer = pre-read eligibility) ·
  Attributes.SpanBytes (UTF-8 span of processed content; reader-navigation +
  packing semantics; landed in rs-attributes, 36 asserts green incl.
  multibyte char-vs-byte case) · rendered row `length` (writer-side encoded
  span). LTS conflated the first two (attributes.size_bytes = on-disk).
  `Partition-Files` ByteSpan property naming reconciliation queued for the
  writer phase. (b) **Lean payload, diagnostics sidecar** — failed ingests
  AND empty reads are never rendered into the payload (tree included); they
  route to a diagnostic sidecar/log with distinct reasons (read-failure
  kinds vs EmptyFile vs EmptiedByProcessing). Supersedes the earlier
  LTS-precedent default (content-less entries). Sidecar form/naming open;
  IR Skipped/Diagnostics streams are the feed. Historical note (user): the
  SizeBytes/SpanBytes distinction was a recurring assistant-confusion
  hotspot during earlier dev — filesystem vs code-analysis vs
  payload-enrichment concerns, PowerShell ingesting PowerShell; the
  three-layer doctrine is the standing disambiguation.
- 2026-07-28 — **Item 6c COMPLETE**: rs-psstrip FrontMatter partition landed.
  `_SplitCommentPopulation` interior helper (partition at parse boundary,
  Native/Derived, ScriptRequirements metadata spliced, Shebang SubKind);
  FrontMatter as named sixth kind with explicit never-strip ops case;
  run-folding flushes on non-LineComment kinds (stated run-splitter policy);
  zero frontmatter text predicates in classification; regex fallback route
  untouched (its legitimate pattern-recognition job). Suite 68 → 79 green
  (section 13: maximal-ops preservation, discriminators, run-split vs
  control, envelope stability); colonel compile + runspace dispatch
  verified. Ontology item 1 closed as fully implemented (was
  minimal-guard). Processor-work block done: Phases 3, 4, 6c all landed —
  remaining before Phase 5: Phase 2 only (awaits final naming).
- 2026-07-28 — **Phase 2 COMPLETE** (item 5). Design v3 (user): names
  adopted provisionally (`IngestMode`/`IgnorePatterns`/
  `IgnoreOverridePatterns`/`SelectionPatterns` — renameable; semantics are
  what is settled); **override collapsed into negation merge** — both
  ignore-side params are virtual root ignore sources, containers for
  positives/negations by convention, handled by the engine's existing
  merge/inheritance/annihilation machinery (no rescue layer, no prune
  special-casing; inherited canonical-gitignore constraint documented with
  the directory-negation recipe); **cross-mode params inert** (supersedes
  binding-aware throws — ergonomic mode switching); CompiledState
  regime-stamped single slot; TestPath dual truth table; RunOverrideBypass
  deleted; ExecutiveOverrides clean break. Latent bug #4 of the
  consolidation pass: Invoke-IgnoreFilter empty-leaf prune leaked
  Dictionary.Remove bool into the pipeline. New `tests/ignore.tests.ps1`
  (27); six-suite battery **205/205 green**. Unresolved tension recorded to
  admiral brief: config-driven execution will not displace direct
  bound-param invocation. **All consolidation phases complete (0–4, 6b
  pending, 6c done) — Phase 5 (rs.core.assemble) is unblocked.**
- 2026-07-28 — **Item 6b COMPLETE**: stale v1 harness `tests/colonel.tests.ps1`
  retired (its ApplyAll/KeyMatch/ResultMode API no longer exists); dispatch
  mechanics rebuilt against v2 as `tests/colonel-dispatch.tests.ps1` (20
  asserts: compile validation, index-stable ordering, Config delivery,
  serial≡parallel equivalence, _ChainHalt item-scoped skip, per-item error
  capture returning pre-step state, empty-Items envelope). Latent find #5:
  `Invoke-Plan -Items` Mandatory binding rejected `@()`, making the
  intentional count-0 early-return dead code — fixed with
  `[AllowEmptyCollection()]`. House-pattern comment pointers updated to the
  new suite. Observed, not acted: `tests/colonel-bench.ps1` is also v1-era
  stale (references removed processors/format.ps1) — refresh when perf work
  matters. **Consolidation plan fully executed: Phases 0–4, 6b, 6c all
  landed. Phase 5 (rs.core.assemble) is the sole next item.**
- 2026-07-28 — **Phase 5 scoping: LTS monolith inventory complete**
  (assemble-design §"LTS monolith inventory & v3 disposition"). Full read of
  Get-RepoSnapshot's assembly+serialization span + selfie ground truth (both
  monoliths: header+files only; flag-gated members absent; preview omitted;
  params/flags present; git_history never exercised). Key scoping facts:
  LTS sorts entries at SERIALIZATION (v3: AssemblyPolicy owns order);
  byte-offset TOC + tree.md are emission-coupled writer products
  (Get-EntryByteOffsets against live stream positions); header params block
  = ConfigEcho's ancestor; tree_diagram embeds a view in the store (removed
  from IR). Concrete IR schema drafted; entry deltas locked (binary flag
  retired to diagnostics, size_bytes → SpanBytes). New opens: flags
  retire-or-keep, Header.Root emission posture. Assemble implementation can
  begin against this inventory.
- 2026-07-28 — **TODO item 1 (broken-reference audit) executed**, prompted by
  the user questioning "why was format.ps1 removed": it never was — never
  existed here (git-verified); `format.ps1`/`rs.core.colonel.psm1` are
  PowerShellCore-era names; the processor arrived renamed `format-ws.ps1` at
  the initial commit (still stamps `Processor = 'format'`). Sweep across all
  ps1/psm1: `format.tests.ps1` retargeted to format-ws — API-identical,
  29/29 green on first run (dormant since copy-over); `colonel-bench.ps1` is
  the sole remaining v1-era file (deferred); all other hits benign (lineage
  docs, identity strings, stripping fixtures). CHANGELOG wording corrected
  ("removed" → "never copied/renamed"). Battery now seven suites, 254
  asserts.
