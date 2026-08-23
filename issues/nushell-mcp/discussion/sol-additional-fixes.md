The composition rearchitecture is behaviorally sound, but I found two high-priority current blockers and several landing/documentation gaps. No files were changed.

## Findings

1. **[P1] Host executables disappear from configured sessions.** [config.nu](</D:/aghado01/science-facility/mcp/nushell-mcp/config.nu:31>) prepends to a string-valued Windows `PATH`, producing `[deps/cli, "<entire semicolon-delimited PATH>"]`. Live evidence: `which git` returned empty and `xq git status` returned `not found: git`. This is pre-existing, but it blocks arbitrary `xq` use and the planned `gh` identity route.

2. **[P1] `jobs spawn` without `--tag` throws.** The flag is optional in [jobs/mod.nu](</D:/aghado01/science-facility/mcp/nushell-mcp/modules/jobs/mod.nu:271>), yet null reaches `job spawn --description`; live output was `Can't convert to string.` This directly violates failure-as-data. Worse, the agent corpus recommends tagless spawning in [jobs.md](</D:/aghado01/science-facility/mcp/nushell-mcp/skills/nushell/references/jobs.md:32>). Either return a missing-tag failure record or deliberately allocate a tag.

3. **[P2] Capture traces are lost at the public boundary.** The new `process capture` correctly preserves `trace`, but [xq/mod.nu](</D:/aghado01/science-facility/mcp/nushell-mcp/modules/xq/mod.nu:55>) and `rg` reduce that failure to `error`. A live child showed `capture_trace:true` and `xq_trace:false`. That falls short of the package’s visibility convention.

4. **[P2] The documentation landing is internally contradictory.**

   - [xq-v1.md](</D:/aghado01/science-facility/issues/nushell-mcp/briefs/xq-v1.md:16>) and [rg-wrapper-v1.md](</D:/aghado01/science-facility/issues/nushell-mcp/briefs/rg-wrapper-v1.md:17>) say hardening landed while their amendment blocks still say it is pending/not landed.
   - [jobs.md](</D:/aghado01/science-facility/mcp/nushell-mcp/skills/nushell/references/jobs.md:96>) says `findings` exists iff `truncated:false`, but the intentional worker-failure shape is `ok:false, truncated:false` with no findings.

5. **[P2] New tests violate workspace-local scratch policy.** [composition-v1.nu](</D:/aghado01/science-facility/mcp/nushell-mcp/tests/composition-v1.nu:314>) creates two directories under `$nu.temp-dir`; the binary case can also leak its directory when an assertion precedes cleanup. These should live beneath the repository’s `.codex` scratch area.

6. **[P3] The discussion-only commit needs link hygiene.** [grok-engine-fixes-plan.md](</D:/aghado01/science-facility/issues/nushell-mcp/discussion/grok-engine-fixes-plan.md:3>) contains three broken relative links. The Gemini review contains machine-specific `file:///d:/...` links and one trailing-whitespace error.

## What passed

- All five suites: **94/94 assertions**.
- Live `par` and `jobs` domain-failure composition.
- Foreground-worker and nested-job behavior for `read`, `jobs emit`, `xq`, and `rg`.
- External-cwd config smoke and internal-core non-leakage.
- Claude, Grok, and Codex adapters are synchronized.
- `main` is clean and synchronized with `origin/main`.

I would treat composition as behaviorally landed, but fix the two P1s before starting downstream query consumers. `gh-v1` also still needs to sync its declared `gh` version with the updated ambient gh version 2.98 or whatever 

::code-comment{title="[P1] Normalize inherited PATH" body="When the incoming Windows PATH is a string, prepend treats the entire semicolon-delimited value as one list entry. In the live registered MCP this makes which git empty and xq git fail. Normalize string PATH through the platform path separator before prepending deps/cli." file="D:/aghado01/science-facility/mcp/nushell-mcp/config.nu" start=31 priority=1}
::code-comment{title="[P1] Handle missing spawn tag as data" body="The tag flag is optional, but null later reaches native job spawn as the description and throws Can't convert to string. Return an explicit failure outcome or deliberately allocate a tag; current agent guidance also demonstrates jobs spawn without a tag." file="D:/aghado01/science-facility/mcp/nushell-mcp/modules/jobs/mod.nu" start=271 priority=1}
::code-comment{title="[P2] Preserve captured trace" body="process capture now returns a trace on spawn failure, but this mapping forwards only error and elapsed. The public xq failure therefore loses diagnostics that were already captured; rg has the same loss." file="D:/aghado01/science-facility/mcp/nushell-mcp/modules/xq/mod.nu" start=55 end=56 priority=2}
::code-comment{title="[P2] Reconcile landed amendment text" body="The header now says composition hardening landed, while this block still calls it pending and says there is no evidence it landed. Recast it as a landed amendment and append the corresponding local follow-up evidence; rg-wrapper-v1 has the same contradiction." file="D:/aghado01/science-facility/issues/nushell-mcp/briefs/xq-v1.md" start=16 end=23 priority=2}
::code-comment{title="[P2] Correct the envelope invariant" body="Foreground worker over-cap failure intentionally returns ok false and truncated false without findings, so findings is not present iff truncated is false. State the success-path invariant or require callers to gate findings on ok first." file="D:/aghado01/science-facility/mcp/nushell-mcp/skills/nushell/references/jobs.md" start=96 priority=2}
::code-comment{title="[P2] Keep test scratch in the workspace" body="This new test writes under the OS temporary directory, contrary to the workspace-local .codex scratch rule. It can also leave the directory behind when an assertion before cleanup fails; the byte-backed rg case repeats the same location choice." file="D:/aghado01/science-facility/mcp/nushell-mcp/tests/composition-v1.nu" start=314 priority=2}
::code-comment{title="[P3] Repair discussion links" body="These repository-prefixed targets are interpreted relative to the discussion directory, so all three links resolve to nonexistent nested paths. Use ../briefs/composition-v1.md and local discussion-relative filenames." file="D:/aghado01/science-facility/issues/nushell-mcp/discussion/grok-engine-fixes-plan.md" start=3 end=5 priority=3}