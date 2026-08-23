The layering itself is healthy and verified. The dependency cycle is gone, all seven `core/*.nu` units load, the intended agent surface is preserved, and both suites are green. I found several remaining contract issues, mostly around failure legibility rather than layering.

## Findings

1. **[P1] Addressed jobs operations still throw or erase domain failures.**

   [jobs-require-row](/D:/aghado01/science-facility/mcp/nushell-mcp/modules/jobs/mod.nu:179) throws for an unknown tag; `jobs read` and `jobs fetch` also throw while a job is running. Live checks returned process exit 1 for both `jobs read missing` and `jobs fetch missing`.

   More seriously, reading or fetching a failed job returns `null`. I verified:
   - `jobs inspect bad` → legible `{ok: false, status: failed, error: boom, ...}`
   - `jobs read bad` → nothing
   - `jobs fetch bad` → nothing

   Missing, running, failed, and cancelled are expected domain states. `jobs inspect`/`read`/`fetch` should return stamped `ok: false` records for them; only a completed row should return its payload.

2. **[P1] Generated retrieval commands are not pasteable for all valid tags.**

   Both [in-hand read](/D:/aghado01/science-facility/mcp/nushell-mcp/modules/dataspection/mod.nu:46) and [jobs read](/D:/aghado01/science-facility/mcp/nushell-mcp/modules/jobs/mod.nu:318) interpolate the tag without quoting.

   A valid tag `"my tag"` produces:

   ```nu
   jobs fetch my tag
   ```

   That is not the command required to retrieve it. Render the argument as NUON first, yielding:

   ```nu
   jobs fetch "my tag"
   ```

   Tests should include spaces, quotes, and backslashes.

3. **[P2] Unknown byte size is currently treated as safe disclosure.**

   [dataspection read](/D:/aghado01/science-facility/mcp/nushell-mcp/modules/dataspection/mod.nu:23) returns the original value when `shape.bytes == null`; [jobs read](/D:/aghado01/science-facility/mcp/nushell-mcp/modules/jobs/mod.nu:310) does likewise.

   For a closure, `shape` correctly reports serialization failure, but `read` ignores it and emits `closure_1782`. An unknown size cannot establish that disclosure fits the cap. `read` should return `ok: false` with the census error/trace. Explicit uncapped `jobs fetch` can remain the intentional escape.

4. **[P2] Several core failure records still omit `ok: false`.**

   Examples:
   - [shape failure](/D:/aghado01/science-facility/mcp/nushell-mcp/modules/core/census.nu:84)
   - [schema stats failure](/D:/aghado01/science-facility/mcp/nushell-mcp/modules/core/schema.nu:216)
   - [page failure](/D:/aghado01/science-facility/mcp/nushell-mcp/modules/core/views.nu:146)

   They carry `error`/`trace`, so they are human-legible, but `$history | shape each | where ok == false` cannot identify them reliably. `meta` also collapses a caught internal failure to `null` at [meta.nu](/D:/aghado01/science-facility/mcp/nushell-mcp/modules/core/meta.nu:42), making it indistinguishable from ordinary unstamped input.

5. **[P2] The dataspection suite can still false-green externally.**

   Its cases correctly accumulate structured failure rows, but the final failure branch at [dataspection-v1.nu](/D:/aghado01/science-facility/mcp/nushell-mcp/tests/dataspection-v1.nu:278) returns the table and exits 0. The par/jobs suite correctly signals suite failure separately.

   Preserve the structured report, then use process-level `exit 1`, or require a manifest runner that interprets `n_err`. This is test-process behavior, not a change to custom command failure semantics.

6. **[P3] Two current documents retain pre-N10 wording.**
   - [roadmap.md](/D:/aghado01/science-facility/issues/nushell-mcp/roadmap.md:125) still says `--full` retrieves the stored body.
   - The layering follow-up at [layering-v1.md](/D:/aghado01/science-facility/issues/nushell-mcp/briefs/layering-v1.md:258) records the original smoke result. That is historically accurate, but should be annotated as superseded by N10 so it is not mistaken for the current gate.

## Verified current state

- Worktree clean; `main` is three commits ahead of `origin/main`.
- Layering commit: `09fdf9a`.
- `jobs fetch` commit: `d43be53`.
- Dataspection suite: **13/13**.
- Par/jobs suite: **27/27**, including mixed-success parallel work.
- Config-loaded over-cap `read` succeeds and returns a `jobs fetch` receipt.
- All seven core units load through `nu-modules`.
- `value kind` and `failure fields` do not leak into the config-loaded agent surface.
- Config works from outside the repository cwd.
- Claude/Grok/Codex adapter copies contain no stale `--full`.
- Live proper MCP verification remains outstanding because `mcp__nushell__*` is absent from this task’s effective tool inventory.

::code-comment{title="[P1] Missing jobs must remain failure data" body="The shared resolver throws for an unknown tag, so jobs inspect/read/fetch turn an expected domain condition into an engine-level failure with no history entry. Return a resolved-state record and let each exported command emit a stamped ok:false result for missing, running, failed, and cancelled states." file="D:/aghado01/science-facility/mcp/nushell-mcp/modules/jobs/mod.nu" start=179 end=184 priority=1}

::code-comment{title="[P1] Quote generated retrieval arguments" body="Interpolating a valid tag such as `my tag` produces the non-pasteable command `jobs fetch my tag`. Serialize the tag as NUON before interpolation and test spaces, quotes, and backslashes." file="D:/aghado01/science-facility/mcp/nushell-mcp/modules/jobs/mod.nu" start=318 priority=1}

::code-comment{title="[P2] Unknown size is not safe to disclose" body="A null byte count means shape could not serialize the value, but this branch returns it as though it were under cap. Preserve the shape error and return a stamped ok:false disclosure result; only a known byte count at or below the cap should pass through." file="D:/aghado01/science-facility/mcp/nushell-mcp/modules/dataspection/mod.nu" start=23 end=25 priority=2}

::code-comment{title="[P2] Suite failures still exit successfully" body="The structured per-case failure rows are correct, but this final branch returns them with process exit 0. Keep the report and then signal test-process failure with `exit 1`, or route the suite through a manifest runner that treats n_err > 0 as failed." file="D:/aghado01/science-facility/mcp/nushell-mcp/tests/dataspection-v1.nu" start=278 end=282 priority=2}
