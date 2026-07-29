Audit all imports and dot-sourcing paths for broken references due to coping code over from powershellcore (executed 2026-07-28 — sweep in CHANGELOG: format.tests.ps1 retargeted to format-ws.ps1 (29/29); colonel.tests.ps1 retired/replaced; colonel-bench.ps1 is the sole remaining v1-era file, deferred until perf work)

write user convenience script to replace `_rs.scratch.ps1`

Update output filewriting convention to create a runstamped subdirectory with shards

make intermediate json monolith optional (subsumed by IR distillation — `issues/v3/lts-v3-transfer-audit.md` + `issues/v3/rs.core.assemble-design.md`)

update ignore-compiler's "antisemantics" to be like ThermoMapper's repo-audit's ignore compiler where positive vs negative semantics are toggled as opposed to having positive/selective semantics toggled by executive override (design complete 2026-07-28 — `issues/v3/ignore-selection-inversion.md` Design v2: mode dichotomy + override rescue, concept-only backport; implementation pending naming adjudication)

finish v3 mvp e.g. fill in gaps between functionality of v3 and LTS

- scoped and sequenced 2026-07-28: `issues/v3/v3-consolidation-plan.md`

need to design handling and conventions for configuration and documentation files

- considering different output channel/format

incorporate more general markdown processing and specialized segmentaton/sharding mode

incorporate support for more languages, ideally with both regex "pseudoAST" and proper AST support
