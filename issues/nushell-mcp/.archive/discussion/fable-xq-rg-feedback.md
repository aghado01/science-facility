The layering and N15 remediation are healthy, but I would not consider the `xq`/`rg` rollout contract-complete yet. The green suites miss several compositional failures.

## Findings

1. **[P1] Failure-as-data is lost through `par` and `jobs spawn`.**  
   [par/mod.nu](/D:/aghado01/science-facility/mcp/nushell-mcp/modules/par/mod.nu:167) and [jobs/mod.nu](/D:/aghado01/science-facility/mcp/nushell-mcp/modules/jobs/mod.nu:239) treat every non-throwing closure as successful. A missing-binary `xq` therefore produced:

   - `par`: outer `ok: true`, nested `value.ok: false`
   - `jobs spawn`: `ok: true, status: completed, error: null`, while the stored payload had `ok: false`

   This is the central architectural issue: once custom commands correctly stop throwing, orchestration no longer recognizes their failures. I would establish one shared outcome-lifting convention—potentially `core/outcome.nu`—before rolling out more custom modules.

2. **[P1] Quarantine tags are published even when nothing was stored.**  
   [xq/mod.nu](/D:/aghado01/science-facility/mcp/nushell-mcp/modules/xq/mod.nu:75), both branches in [rg/mod.nu](/D:/aghado01/science-facility/mcp/nushell-mcp/modules/rg/mod.nu:142), and existing [jobs emit](/D:/aghado01/science-facility/mcp/nushell-mcp/modules/jobs/mod.nu:422) ignore failed stashes.

   A forced duplicate tag returned `ok: true, truncated: true, error: "duplicate tag", tag: ...`; fetching that tag returned the unrelated pre-existing payload. Tags should be allocated and returned atomically by `jobs stash`; callers should never synthesize and publish an unverified retrieval address.

3. **[P1] Registry mutation inside `par` is worker-local.**  
   The `(job id) != 0` check does not identify `par-each` workers. Two over-cap `xq` calls inside `par` both returned `xq:nu:0`, while the foreground registry remained empty. The results were irretrievable. Parallel-context quarantine ownership needs an explicit design, not merely the background-job check.

4. **[P1] Binary stdout bypasses the `xq` cap.**  
   [utf8-bytes](/D:/aghado01/science-facility/mcp/nushell-mcp/modules/xq/mod.nu:9) returns `0` whenever `str length` fails. Nushell’s `complete` can return binary streams. A three-byte binary output with cap `1` was disclosed inline as `stdout_bytes: 0`. Size strings as UTF-8, binaries by byte length, and treat unsupported types as failure data.

5. **[P2] `rg` silently erases byte-backed matches.**  
   [rg/mod.nu](/D:/aghado01/science-facility/mcp/nushell-mcp/modules/rg/mod.nu:60) only reads `path.text` and `lines.text`. Ripgrep emits `lines.bytes` for invalid UTF-8. The wrapper reported `n: 1` with `match: ""`. The closed finding shape needs an explicit binary representation or an explicit unsupported-encoding failure.

6. **[P2] `process capture` conflicts with universal `ok`.**  
   Successful records at [capture.nu](/D:/aghado01/science-facility/mcp/nushell-mcp/modules/core/capture.nu:52) omit `ok`; its catch at line 44 converts every launch failure to `not found` and drops the forwarded arguments. Running an existing directory was consequently reported as missing. Preserve the captured cause and either add `ok: true` or document a deliberate primitive-level exception.

7. **[P3] The saved review is now misleadingly current.**  
   [sol-nu-core-review.md](/D:/aghado01/science-facility/issues/nushell-mcp/discussion/sol-nu-core-review.md:1) was committed after its findings were remediated, but still presents them as current and records the old ahead/test counts. Mark it as “review basis `d43be53`, remediated by `bb9994b`” or otherwise label it historical.

## Verified

- Current HEAD: `829fde8`; clean worktree; `main` ahead of `origin/main` by 11.
- Official suites: **63/63** total—dataspection 13, par/jobs 29, xq 8, rg 13.
- Config surface is correct: `shape`, `read`, `jobs fetch`, `xq`, and `rg` exposed; `process capture` remains internal.
- Claude, Grok, and Codex adapters are synchronized.
- No files changed during review.
- A proper MCP live call remains unavailable because this task exposes no `mcp__nushell__*` tools; config-loaded Nu calls were used instead.

::code-comment{title="[P1] Lift returned domain failures" body="Every non-throwing closure is marked ok true. Custom commands intentionally return failure records instead of throwing, so par hides failures behind value.ok false. Lift the conventional returned ok field while retaining the value and continuing the batch." file="D:/aghado01/science-facility/mcp/nushell-mcp/modules/par/mod.nu" start=167 end=173 priority=1}

::code-comment{title="[P1] Preserve job payload outcome" body="The job wrapper derives success only from whether the closure throws. A returned layer record with ok false becomes an apparently successful completed job. Separate execution completion from payload outcome and expose the latter on the receipt without discarding the stored failure payload." file="D:/aghado01/science-facility/mcp/nushell-mcp/modules/jobs/mod.nu" start=239 end=244 priority=1}

::code-comment{title="[P1] Never publish a failed stash" body="On stash failure this branch retains ok true and truncated true, then publishes a tag that may address an unrelated existing payload. Registry-owned allocation should return the actual tag atomically; failure must publish no retrieval tag." file="D:/aghado01/science-facility/mcp/nushell-mcp/modules/xq/mod.nu" start=75 end=83 priority=1}

::code-comment{title="[P1] Parallel workers cannot own registry writes" body="job id remains zero inside par-each workers, but their environment mutations do not propagate. Over-cap calls consequently return duplicate irretrievable tags. Parallel execution needs an explicit non-owning context or foreground quarantine handoff." file="D:/aghado01/science-facility/mcp/nushell-mcp/modules/xq/mod.nu" start=63 end=64 priority=1}

::code-comment{title="[P1] Binary output bypasses the cap" body="complete can return binary stdout. str length then fails and this helper reports zero bytes, allowing arbitrarily large binary output inline. Measure binary values directly and fail closed for unsupported stream types." file="D:/aghado01/science-facility/mcp/nushell-mcp/modules/xq/mod.nu" start=9 end=10 priority=1}

::code-comment{title="[P2] Preserve byte-backed rg events" body="Ripgrep uses data.lines.bytes and sometimes data.path.bytes for non-UTF8 data. Defaulting missing text to an empty string creates a blank finding despite a real match. Represent the bytes explicitly or return a legible unsupported-encoding result." file="D:/aghado01/science-facility/mcp/nushell-mcp/modules/rg/mod.nu" start=60 end=69 priority=2}