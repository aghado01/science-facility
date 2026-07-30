Audit all imports and dot-sourcing paths for broken references due to coping code over from powershellcore (executed 2026-07-28 — sweep in CHANGELOG: format.tests.ps1 retargeted to format-ws.ps1 (29/29); colonel.tests.ps1 retired/replaced; colonel-bench.ps1 is the sole remaining v1-era file, deferred until perf work)

write user convenience script to replace `_rs.scratch.ps1`

Update output filewriting convention to create a runstamped subdirectory with shards

make intermediate json monolith optional (DELIVERED 2026-07-29: the IR exists — `rs.core.assemble.psm1`, golden-validated; optional monolith *emission* is a writer-phase knob)

update ignore-compiler's "antisemantics" to be like ThermoMapper's repo-audit's ignore compiler where positive vs negative semantics are toggled as opposed to having positive/selective semantics toggled by executive override (IMPLEMENTED 2026-07-28 as Design v3 — `-IngestMode` on `New-IgnoreCompiler`; `issues/v3/ignore-selection-inversion.md`; names provisional/renameable)

finish v3 mvp e.g. fill in gaps between functionality of v3 and LTS

- consolidation plan EXECUTED through the IR (2026-07-29 — `issues/v3/v3-consolidation-plan.md`); remaining LTS-parity gap is the writer phase (rows/offsets/tree/shards) + item 6d

need to design handling and conventions for configuration and documentation files

- considering different output channel/format
- forward design sketched 2026-07-29 (assemble-design §Content-class dispositions): config = descriptor-only POINTER sidecar (absolute paths, at-will follow-up, not ingested by default — no read, no content); docs/markdown = their own tracks/formats (md-family, exchange envelopes); class routing at eligibility, always overridable

incorporate more general markdown processing and specialized segmentaton/sharding mode (design seeded 2026-07-29 from the mdnav concept extraction — `issues/v3/md-processor-family-design.md`: rs-mdprofile / rs-mdseg / rs-mdstrip family)

incorporate support for more languages, ideally with both regex "pseudoAST" and proper AST support (doctrine recorded 2026-07-28 — comment-ontology language-expansion: thoughtful-regex processors are the default for new languages, native AST on demand; fluid, per-language)

- PRIORITY (user, 2026-07-29): first work after v3 end-to-end completes — python, js/ts, java, others. Transfer sources exist: LTS Normalize-FileContent stage 4 carries working combined string-or-comment alternation patterns for .py (docstring-position-aware) and .js/.ts (template-literal-aware); java adapts the C-family pattern; comment-ontology kinds table already enumerates py/js directive species (coding cookie, # type:, # noqa, eslint/ts pragmas) for frontmatter handling. New strippers are descriptor-contract from birth (no tp-era debt; 6d harmonization or its outcome applies to their chains)
