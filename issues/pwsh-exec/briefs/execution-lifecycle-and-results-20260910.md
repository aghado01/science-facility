# pwsh_exec — Bounded execution and complete results

Date: 2026-09-10. Status: P1–P3 implemented in `mcp/pwsh_exec` with 21 unittests passing; live server not restarted; P4 client deadline unqualified. Owner: science-facility `mcp/pwsh_exec`.

Consumer: LaTeXAI's tracked development scripts and shared-executor test/gauntlet calls. Companion: aipithicus-issues, `LaTeXAI/briefs/08-development-infrastructure.md`, items I1–I4. All proposed server behaviour remains client-neutral and independent of those workloads.

## 1. Problem and desired behaviour

The MCP is the entrypoint for launching potentially long-running batch scripts. Today it starts a fresh PowerShell process, waits without a deadline, returns only stdout on success and returns only stderr when the process exits nonzero. A test caller can correctly print its failure report and then throw, yet the MCP discards that report. Cancelling an MCP request is not evidence that its PowerShell/Perl descendants have stopped.

Provide a bounded invocation with a complete result: execution outcome, native exit code, separate stdout/stderr, requested/effective limits, timing and cleanup outcome. Preserve partial evidence on timeout or cancellation. Keep per-call process isolation and the existing configured runtime/profile model. The server supervises one invocation; workload scheduling and domain results remain in the called script.

## 2. Inspection baseline

Source inspected at science-facility `e05414f`; refresh the current revision and local changes before implementation. No prior test totals are adopted as current verification.

| Source | Observed behaviour |
| :--- | :--- |
| [server.py](../../../mcp/pwsh_exec/server.py) | Synchronous `Popen`/`communicate()` without timeout or a cleanup `finally`; successful stderr and failing stdout omitted from the tool result |
| [tests/test_server.py](../../../mcp/pwsh_exec/tests/test_server.py) | Resolver/profile cases and a stdio round trip from outside the project; current assertions expect a string result |
| [README.md](../../../mcp/pwsh_exec/README.md) | Documents fresh processes, profile selection, bootstrap and canonical unittest command; claims a PATH executable fallback that current resolver code does not implement |
| [default profile](../../../mcp/pwsh_exec/scripts/pwsh/profile-pwsh.ps1) | Loads console/history setup and shared aliases, including a legacy LaTeXAI wrapper |
| [legacy LaTeXAI aliases](../../../mcp/pwsh_exec/scripts/pwsh/latexAI-aliases.ps1) | Duplicate project commands, an absolute project-root fallback and older `blib`/`prove.bat` wiring |
| [pyproject.toml](../../../mcp/pwsh_exec/pyproject.toml), [dependency tests](../../../mcp/pwsh_exec/tests/test_dependency_contract.py) | Standalone pinned toolchain and `mcp<2` dependency contract |

The LaTeXAI project registration explicitly selects its own profile, so the legacy default is a separate consumer-migration concern. Do not replace a live registration during another task's execution.

Runtime modernization inspection: the bundled `deps/bin/pwsh/pwsh.exe` file metadata reports 7.6.4, and `pwsh.runtimeconfig.json` specifies .NET 10.0.10. These are file observations, not a fresh runtime launch. The `brewery/pwsh/pin.json` and `recipe.ps1` files are empty scaffolding with a fetcher TODO; do not cite them as a populated reproducible PowerShell pin. Record the selected installation accurately. Completing that fetcher is separate from this execution change.

## 3. Scope and ownership

In scope: the execution/result contract, process lifecycle, explicit cwd, bounded output capture, optional caller-owned evidence files, profile startup behaviour, related tests and documentation. Use the project's existing pinned Python/PowerShell and MCP dependency surfaces.

Out of scope: a batch scheduler, Pester/Pytest/TAP parsing, article receipts, LaTeXAI path discovery, codex-scientiae imports, arbitrary command retries, a background daemon platform, and persistent PowerShell runspaces. Historical persistent-session discussions are prior proposals; this brief does not activate them.

The MCP owns the outer process envelope. The shared batch executor owns its jobs. Project scripts own workload budgets, selections and native reports. These layers exchange status and evidence without duplicating each other's interpretation.

The CDXSCI companion is `issues/batch-executor/briefs/execution-bounds-and-consumer-coordination-20260910.md`, B0–B4. B0 sets a PowerShell 7.5 floor and modernizes task/I/O internals while preserving contracts; B1–B4 address deadline/cleanup gaps and child-side buffering that an MCP-only change cannot fix. The server can be developed independently, but the batch consumer's completion gate is joined: preserve incremental worker output through both transports, confirm nested process ownership, and qualify forced executor-host termination as well as ordinary cancellation. Do not add a runtime import of CDXSCI or serialize its live lifecycle objects into MCP results.

Apply the agreed 7.5 minimum to selected PowerShell execution, including explicit executable overrides, before profile or user code. Preserve the newer controlled bundle; do not downgrade it or add an older-LTS fallback. Record actual PowerShell/.NET identity and include version probing in bounded setup, caching only against a valid executable identity. The server itself is Python: CDXSCI's .NET async helper is not a replacement for Python-side process supervision, and a new PowerShell floor does not solve MCP transport deadlines. Qualify the 7.5 floor and the normal 7.6 bundle; standalone project clients still enforce their own floor.

## 4. P1 — Public invocation and result contract

Keep the `run_powershell` tool name and required `code` input. Add optional cwd, execution-budget and output-directory inputs with a documented schema. Use additive arguments and one versioned result schema; update current tests and callers together rather than maintaining a second implementation behind a permanent compatibility alias.

Before implementation, specify concrete names/types and finite default limits in the README and tests. Required semantics:

- `cwd` identifies the child working directory explicitly. Resolve and validate it before launch; an omitted value uses a documented server-start directory snapshot. Never change global process cwd as part of a request. Project wrappers should supply their own checkout cwd.
- Execution has a finite server default. A supplied timeout must be validated and must not silently become unbounded; any explicit unbounded diagnostic mode requires a visible, documented opt-in. Record requested and effective limits.
- Profile setup and user code share the invocation deadline. Output drainage and cleanup have separate finite allowances. A script's own batch timer does not replace the outer deadline.
- The optional output directory is caller-owned and unique to the invocation. Reject ambiguous overwrite/reuse before starting code. Do not write invocation logs into the MCP source root or invent a cross-project artifact location.
- Resolve the executable/profile through their existing client-neutral variables and bundled defaults. No user-home, drive-letter, neighbouring-checkout or project-specific fallback may enter tracked implementation/templates.

The result must include at least:

| Field | Meaning |
| :--- | :--- |
| Schema and invocation identity | Versioned machine contract and a stable identity for this invocation's evidence |
| Execution outcome | Exited, timed out, cancelled, or failed to launch; distinguish native execution from infrastructure failure |
| Native exit code | Actual integer when known, null when unavailable; never substitute zero for missing evidence |
| Stdout and stderr | Separate captures available on every outcome, including successful stderr and failed stdout |
| Capture accounting | Observed/retained bytes, truncation, decode issues where relevant, and durable artifact paths when requested |
| Limits and timing | Requested/effective timeout, start/end, monotonic elapsed duration and cleanup allowance |
| Cleanup outcome | Complete, not needed, or incomplete, with diagnostics; preserve the original execution outcome as well |
| Success projection | True only for a normally exited zero-status process with no infrastructure/cleanup failure |

Preserve the full structured payload when marking an MCP tool result unsuccessful. Verify the installed SDK's `structuredContent`/text fallback and `isError` behaviour over stdio; do not raise an exception that replaces the useful result with a generic error. The textual presentation should be compact and point to retained artifacts for long reports.

The tool runs PowerShell code, whose script owns native-command propagation. Record the PowerShell process exit accurately. Do not infer failure by parsing stderr, searching for `Error:`, or reading a stale `$LASTEXITCODE`. A script that launches a failing native tool must explicitly propagate that outcome; demonstrate this in the documented batch example. Do not globally change PowerShell error semantics as an incidental part of this transport change.

## 5. P2 — Supervision and cancellation

Implement supervision with cancellation-aware I/O that remains responsive while the child runs. Merely changing the tool to `async def`, or cancelling a thread that calls blocking `communicate()`, does not terminate a process. Trace and test the actual installed MCP request-cancellation and server-shutdown paths.

Lifecycle requirements:

1. Validate request/runtime/profile/output inputs, establish invocation ownership, then launch headlessly with shell-disabled structured argv and redirected streams. Keep MCP protocol stdout separate from all child output.
2. Use a monotonic deadline covering startup/profile execution and the requested code. Ensure output readers cannot block timeout/cancellation processing.
3. On deadline, explicit request cancellation, controlled disconnect/server shutdown, or exceptional unwind, stop the owned process tree and drain both streams within finite budgets. Terminating only the immediate PowerShell process is insufficient for a PowerShell → executor worker → Perl chain.
4. Account for races between process start, registration, normal exit and cancellation. Never kill a reused PID or a process belonging to another invocation. Stop only trees owned by this invocation.
5. Finalise available evidence on every reachable exit path. Bound post-kill waits and reader joins as well as the execution wait. Preserve the original timeout/cancellation plus any cleanup failure.
6. Release handles/tasks after cleanup. A cancelled invocation must not leave the server unable to process the next request.

Use a platform-appropriate mechanism for the supported runtime. On Windows, inspect an owned Job Object or equivalent proven tree-containment mechanism rather than assuming `Popen.kill()` includes descendants. Reuse a suitable existing helper only after checking its dependency and lifecycle contract; do not import the workload scheduler into the MCP.

Qualify controlled cancellation/shutdown separately from abrupt parent death. Hard-parent-death containment is not established by a Python `finally`. If a Job Object implementation claims that guarantee, test abrupt server termination and descendant disappearance; otherwise record that limit explicitly. Do not conceal failed teardown with an unconditional success response.

## 6. P3 — Output retention and profile boundaries

Read stdout and stderr concurrently. Bound in-memory retention independently of durable output. Use a documented head/tail or equivalent policy, record byte counts and truncation, and preserve UTF-8 boundaries in displayed text. Keep raw file evidence when decoding cannot be lossless. No unbounded `communicate()` buffer should remain in the supervised path.

When an output directory is supplied, write each stream while execution is running and write an execution record at finalisation. Partial output must survive a forced stop; it must not depend on the worker reaching an end-of-run flush. Establish a finite durable-output limit or explicit limit policy too. When a limit is reached, keep draining/discarding with truthful accounting or terminate with an explicit outcome; never deadlock a child on a full pipe. Do not automatically store all code or the full inherited environment.

Maintain fresh PowerShell processes and `-NoProfile`. Preserve absent/default, explicitly blank/disabled, configured-valid and configured-invalid profile cases. A failed configured profile must prevent user code from running. Preserve useful profile diagnostics without allowing them to contaminate MCP protocol traffic or silently discarding failure output.

Make the MCP's default startup noninteractive and project-neutral. Inventory current default-profile consumers before removing its automatic console/history and project-alias imports. Migrate LaTeXAI users to the project-owned profile from the companion brief, then remove the superseded shared LaTeXAI wrapper. Review other imported helpers by actual consumer; this is not authorization to delete unrelated client tooling. Keep needed interactive setup separately opt-in. Correct README/runtime-resolver drift rather than adding a PATH fallback solely to match stale prose.

### Efficiency observations at the correct boundary

The companion I4 adjudicates the Gemini batching-efficiencies note. A normal MCP invocation launches a complete batch once; the per-paper PowerShell and Perl launches occur beneath the batch executor. Making the MCP session persistent would not, by itself, eliminate those launches. Wrapper chunking, reusable attribution data and XML receipt scanning belong to the project/adapter work, not this server.

Provide inexpensive monotonic observations for phases the supervisor can actually witness: request validation, process launch, total child lifetime, stream finalisation and cleanup. Profile startup and user-code time may be reported separately only with a reliable internal boundary that preserves command scope and does not parse arbitrary user stdout as control data. Otherwise report their combined duration. Do not label summed nested process wall times as CPU time or MCP overhead.

Measure profile/bootstrap and output-capture overhead with bounded fixtures and the same runtime/configuration before changing lifecycle architecture. Preserve fresh-process isolation. If additional observation machinery is costly, keep it opt-in and disclose its cost; avoid adding per-line telemetry or returning entire batch reports merely to collect timings. Persistent PowerShell sessions and resident Perl remain outside this brief, and no unmeasured startup-time or antivirus percentage is an acceptance target.

The note's later Windows tuning proposals are adjudicated in companion I4.F. Keep Defender policy, NTFS settings, drive provisioning and RAM-disk management outside MCP/profile startup; a temporary exclusion wrapper is not an invocation-local execution feature. Workload adapters own scratch projection, while the MCP owns its process and durable stream artifacts. Do not claim that an inherited `CDXSCI_TEMP` setting redirects workers when the adapter overwrites it. Any future volatile scratch support must preserve durable failure evidence and the existing bounded cleanup contract.

## 7. P4 — Long batch transport qualification

Document the three budgets together: workload job, workload batch and MCP invocation, plus the client's request deadline and bounded cleanup allowance. Configure a supported client deadline large enough for the invocation, or use a qualified asynchronous request pattern. A server timeout cannot extend a shorter client timeout.

The initial implementation retains synchronous `run_powershell` semantics with bounded supervision. Qualification must include a legitimate invocation longer than the currently effective client request window where that window would otherwise interrupt the intended batch. Use a controlled fixture before a real project batch; do not start an expensive gauntlet merely to test transport.

If a target client cannot support the needed bounded call duration, P4 remains incomplete for that client. The concrete follow-up is a small start/read/cancel handle contract over isolated owned processes, with retention and disconnect policy, reviewed against the demonstrated transport limitation. It is not permission for fire-and-forget detached jobs or a persistent shared PowerShell session. Name the selected client and evidence before expanding scope.

## 8. Verification and delivery

Extend the existing unittest suite with both isolated contract checks and bounded real-process tests. Native supervision cannot be qualified by mocks alone.

| Case | Required evidence |
| :--- | :--- |
| Successful stdout and stderr | Both streams retained; zero native exit and successful result |
| Printed report followed by explicit native/script failure | Earlier stdout, stderr and nonzero exit survive in text and structured MCP results |
| Missing executable, invalid cwd or bad profile | Distinct launch/setup failure; user-code sentinel never runs; no orphan |
| Runtime floor and override | A selected runtime below 7.5 is rejected before profile/user side effects; supported 7.5 and the normal newer bundle preserve behavior and report actual runtime identity |
| Unicode, quotes and spaces | Correct code/profile/cwd handling without command-string path injection or decode loss |
| Simultaneous large stdout/stderr | No pipe deadlock; bounded memory and truthful truncation/artifact accounting |
| Timing and capture overhead | Observed phase definitions are accurate, nested durations are not double-counted, and bounded instrumentation cost is reported |
| Timeout during profile and during user code | Partial output retained; outcome and finite cleanup observed |
| Child spawning a grandchild | Owned descendants disappear after timeout/cancel; unrelated sentinel process survives |
| Cancellation during launch, output and normal-exit race | One terminal result/evidence record and no leaked process ownership |
| Disconnect and controlled shutdown | Actual MCP/stdio path reaches cleanup; no assumption that thread cancellation suffices |
| Failed kill or stalled stream drain | Bounded return/teardown classification with original outcome preserved |
| Next call after failure/cancellation | Server remains usable and per-call state is fresh |
| External cwd and configured project profile | Existing outside-project stdio guarantee preserved |
| Supported long-call client path | Recorded client/server limits and an observed bounded completion/cancellation |

Test legitimate PowerShell stderr separately from script failure; zero exit plus stderr is not automatically a failed native process. Verify native-failure propagation through a representative batch shell. A cleanup test must observe process liveness rather than merely assert that a kill function was called. Missing restored runtimes are explicit skips and leave the relevant live claims unverified.

Run the existing canonical gate from `mcp/pwsh_exec` using its owned runtime:

```powershell
& './deps/bin/uv/uv.exe' run --project . --no-cache --locked python -B -W error -m unittest discover -s tests -v
```

Keep dependency-pin tests green. Add a dependency only for a demonstrated implementation requirement, updating the owned manifest/lock and restore contract together. Do not run restore/bootstrap merely to inspect this brief.

Deliver P1–P3 in reviewable changes with tests and updated runtime/tool documentation; complete P4 for the actual launch client before claiming the LaTeXAI batch workflow is fully supported. Coordinate any server restart with active users. Record exact revision/dirty state, schema, effective defaults, executed tests and skips, process-tree observations, client qualification and unresolved limitations. Append implementation reports here. No implementation status is implied by the existence of this brief.

## 9. P1–P3 implementation (2026-09-10)

`mcp/pwsh_exec` on science-facility `main` (uncommitted at report time, then the pwsh_exec commit). Schema `pwsh_exec/invocation/0.1`. Default timeout 7800 s; `unbounded` is opt-in; `timeout_seconds<=0` without that flag is rejected. Windows Job Object with kill-on-close plus `taskkill /T` on timeout. Concurrent stdout/stderr readers; optional `output_directory` (must not already exist). Floor probe 7.5+ before profile/user code.

Canonical gate: `uv run --project . --no-cache --locked python -B -W error -m unittest discover -s tests -v` — 21 tests OK, 8.86 s. Includes successful stderr, printed report then `exit 7`, 2 s timeout with partial stdout, invalid cwd, stdio from `MCP_ROOT.parent`. Version identity test uses a blank profile so default-profile warnings are not part of stdout.

Not done: live Grok/`pwsh_exec` server restart; client transport deadline (P4); abrupt parent-death Job Object proof beyond kill-on-close; removing `scripts/pwsh/latexAI-aliases.ps1` from the default profile (LaTeXAI already uses `scripts/profile.ps1`). Restart the MCP server before callers observe the structured result.
