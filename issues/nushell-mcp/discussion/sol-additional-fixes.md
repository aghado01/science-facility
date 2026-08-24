# Additional composition hardening review

**Snapshot:** 2026-08-23. This is historical review evidence; consult the
current implementation, briefs, and planning ledger for standing status.
No files were changed during the review.

The composition rearchitecture was behaviorally sound, but the review found
two high-priority blockers and several landing/documentation gaps.

## Findings at review time

1. **[P1] Host executables disappeared from configured sessions.**
   [config.nu](../../../mcp/nushell-mcp/config.nu) prepended `deps/cli` to a
   string-valued Windows PATH without first splitting it.
2. **[P1] `jobs spawn` without `--tag` threw.**
   [jobs/mod.nu](../../../mcp/nushell-mcp/modules/jobs/mod.nu) passed null to
   native `job spawn --description` instead of allocating a registry tag.
3. **[P2] Capture traces were lost at the public boundary.**
   [xq/mod.nu](../../../mcp/nushell-mcp/modules/xq/mod.nu) and the rg module
   reduced captured failures to a short error.
4. **[P2] Landing documentation contradicted itself.**
   [xq-v1](../briefs/xq-v1.md), [rg-wrapper-v1](../briefs/rg-wrapper-v1.md),
   and the [jobs reference](../../../mcp/nushell-mcp/skills/nushell/references/jobs.md)
   disagreed about landing status and failure-envelope invariants.
5. **[P2] Tests wrote scratch under the OS temporary directory.**
   [composition-v1.nu](../../../mcp/nushell-mcp/tests/composition-v1.nu)
   bypassed the package [write conventions](../notes/write-conventions-v1.md).
6. **[P3] Discussion links were not repository-relative.**
   [grok-engine-fixes-plan.md](grok-engine-fixes-plan.md) and the Gemini
   review contained broken or machine-specific targets.

## Evidence at review time

- All five suites passed: **94/94 assertions**.
- Live `par` and `jobs` domain-failure composition passed.
- Foreground-worker and nested-job behavior passed for `read`, `jobs emit`,
  `xq`, and `rg`.
- External-cwd config smoke and internal-core non-leakage passed.
- Claude, Grok, and Codex adapters were synchronized.

The recommendation was to remediate the two P1s before downstream query
consumers. `gh-v1` was left for a separate design review.
