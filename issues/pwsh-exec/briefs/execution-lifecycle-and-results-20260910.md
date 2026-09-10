# pwsh_exec — Bounded execution and complete results

Date: 2026-09-10. Status: ready to launch; implementation unstarted on the current tree. Owner: science-facility `mcp/pwsh_exec`. Scheduling for this file is the launch of P1–P4 below. Do not treat git history `f0e095b` as the working source.

Operational path (this is why LaTeXAI registers the server):

**client → `pwsh_exec` → LaTeXAI `scripts/profile.ps1` → `ltbatch` / `lgauntlet` → CDXSCI executor**

The server supervises one PowerShell process. Workload scheduling and domain results stay in the called scripts. The server must not import codex-scientiae or parse TAP/receipts. LaTeXAI scripts must not treat a textual `Error:` prefix as a process contract.

Companions: aipithicus-issues `LaTeXAI/briefs/08-development-infrastructure.md` (I1–I4; native waits already in the child), CDXSCI `issues/batch-executor/briefs/execution-bounds-and-consumer-coordination-20260910.md` (B0–B4 landed at `15b064ca`). All proposed server behaviour remains client-neutral.

## 0. Launch constraints

Start from **current** `mcp/pwsh_exec/server.py` on science-facility `main` (`1d66256`, same `communicate()` / `Error:` + stderr contract as `e05414f`). Refresh HEAD and local changes before editing.

Do **not** cherry-pick, revert-the-revert, or copy `f0e095b` (`feat(pwsh_exec): bounded invocation result contract`). That commit was an out-of-order LaTeXAI-session implementation and was reverted as `1d66256`. History may be read as a discarded sketch; the tests and public names below are the contract if they differ from that sketch.

Do not edit LaTeXAI scripts or CDXSCI executor sources in this flight. Do not reload a live `pwsh_exec` server until its consumers are idle; after landing, coordinate the restart so LaTeXAI `.mcp.json` still names `scripts/profile.ps1`.

LaTeXAI already migrated off the bundled default profile. P3 may retire `scripts/pwsh/latexAI-aliases.ps1` from the default profile after a consumer inventory; that is not a prerequisite for P1–P2.

## 1. Problem and desired behaviour

The MCP is the entrypoint for LaTeXAI batch scripts. Today it starts a fresh PowerShell process, waits without a deadline, returns only stdout on success and returns only stderr when the process exits nonzero. A TAP caller can print its failure report and then throw; the MCP discards that report. Cancelling an MCP request is not evidence that PowerShell → executor worker → Perl descendants have stopped.

Provide a bounded invocation with a complete result: execution outcome, native exit code, separate stdout/stderr, requested/effective limits, timing and cleanup outcome. Preserve partial evidence on timeout or cancellation. Keep per-call process isolation and the existing configured runtime/profile model.

## 2. Inspection baseline

Refresh these paths at implementation HEAD. No prior test totals are current verification.

| Source | Observed behaviour |
| :--- | :--- |
| [server.py](../../../mcp/pwsh_exec/server.py) | Synchronous `Popen`/`communicate()` without timeout or a cleanup `finally`; successful stderr and failing stdout omitted; tool is `run_powershell(code: str) -> str` |
| [tests/test_server.py](../../../mcp/pwsh_exec/tests/test_server.py) | Resolver/profile cases and a stdio round trip from outside the project; assertions expect a **string** result |
| [README.md](../../../mcp/pwsh_exec/README.md) | Fresh processes, profile selection, bootstrap, canonical unittest command; claims a PATH executable fallback the resolver does not implement |
| [default profile](../../../mcp/pwsh_exec/scripts/pwsh/profile-pwsh.ps1) | Console/history setup and shared aliases, including [legacy LaTeXAI aliases](../../../mcp/pwsh_exec/scripts/pwsh/latexAI-aliases.ps1) (absolute project-root fallback, older `blib`/`prove.bat`) |
| [pyproject.toml](../../../mcp/pwsh_exec/pyproject.toml), [dependency tests](../../../mcp/pwsh_exec/tests/test_dependency_contract.py) | Standalone pinned toolchain and `mcp<2` |

LaTeXAI registration (gitignored `.mcp.json`, keep `.mcp.example.json` in agreement by hand) already sets:

- `MCP_POWERSHELL_EXECUTABLE` → bundled `deps/bin/pwsh/pwsh.exe`
- `MCP_POWERSHELL_PROFILE` → `<LATEXAI_ROOT>/scripts/profile.ps1`
- `PERL_ROOT`, `CDXSCI_ROOT`, `LATEXAI_ROOT`

Loading that profile does not require `CDXSCI_ROOT`; `ltbatch` / `lgauntlet` do. Wrappers should pass `cwd` as the LaTeXAI checkout. The server must not discover those roots itself.

Bundled `pwsh.exe` metadata reports 7.6.4 / .NET 10.0.10 (file observation). `brewery/pwsh/` is empty scaffolding; do not cite it as a pin. Preserve the newer bundle; do not downgrade or add an older-LTS fallback.

## 3. Scope and ownership

In scope: execution/result contract, process lifecycle, explicit cwd, bounded output capture, optional caller-owned evidence files, profile startup behaviour, tests and documentation. Use the existing pinned Python/PowerShell and `mcp<2`.

Out of scope: a batch scheduler, TAP/Pester/Pytest parsing, article receipts, LaTeXAI path discovery, CDXSCI imports, retries, a background daemon, persistent PowerShell runspaces, Defender/NTFS/RAM-disk policy.

| Layer | Owns | Does not own |
| :--- | :--- | :--- |
| This server | One child `pwsh`, argv, cwd, outer deadline, both streams, native exit, cleanup of **that** tree | TAP, receipts, job scheduling, `CDXSCI_ROOT` |
| LaTeXAI scripts | Profile, aliases, selections, Perl/kpsewhich, policy budgets, TAP/gauntlet workers | Executor internals, MCP result schema |
| CDXSCI executor (`15b064ca`) | Plan, workers, job/batch timeouts, write isolation, job-object containment **inside** the batch | MCP transport, LaTeXAI package policy |

CDXSCI B0–B4 are implemented and qualified on a 7.6.4 host plus a 7.5.5 child. That does **not** replace Python-side supervision of the outer `pwsh`. Do not import the executor or serialize its live objects into MCP results. Nested process ownership still has to be confirmed: MCP Job Object (or equivalent) around the PowerShell the server started, executor Job Object around its workers. An MCP timer alone does not finish CDXSCI cleanup or incremental worker transport.

Apply the 7.5 floor to the selected PowerShell executable, including overrides, **before** profile or user code. Qualify 7.5 and the normal 7.6 bundle; record actual PS/.NET identity. Cache version probes only against a resolved executable path.

## 4. P1 — Public invocation and result contract

Keep the tool name `run_powershell` and required `code: str`. Additive optional arguments; one versioned result schema; update tests together. No permanent compatibility alias for the old string/`Error:` result.

### Inputs

| Name | Type | Default | Semantics |
| :--- | :--- | :--- | :--- |
| `code` | string | required | PowerShell to run after optional profile load |
| `cwd` | string or omit | server-start cwd snapshot | Validate as an existing directory **before** launch. Never `os.chdir` the server. LaTeXAI wrappers pass the checkout |
| `timeout_seconds` | number or omit | **7800** | Must be `> 0` unless `unbounded` is true. Covers profile + user code. Does not silently become unbounded |
| `output_directory` | string or omit | none | Caller-owned, unique; **reject if it already exists**. Write streams while running and `result.json` at finalisation. Not under `mcp/pwsh_exec/` |
| `unbounded` | bool | false | Visible diagnostic opt-in only |

**7800 s** is the test-batch envelope: LaTeXAI `scripts/policy.psd1` Test `WaitTimeoutSeconds` 7200 plus 600 s for drainage/cleanup. A gauntlet through this MCP must pass `timeout_seconds` ≥ 28800 + cleanup (Gauntlet `WaitTimeoutSeconds`). Record requested vs effective. Profile setup shares the invocation deadline. Drainage/cleanup have separate finite allowances (default cleanup **30 s**). A script's own batch timer does not replace this outer deadline.

Resolve executable/profile only through `MCP_POWERSHELL_EXECUTABLE`, `MCP_POWERSHELL_PROFILE`, and bundled defaults. No user-home, drive-letter, sibling-checkout or LaTeXAI-specific fallback in tracked code or templates.

### Result (`pwsh_exec/invocation/0.1`)

| Field | Meaning |
| :--- | :--- |
| `schema`, `id` | Versioned contract and this invocation's identity |
| `outcome` | `exited` \| `timed-out` \| `cancelled` \| `failed-to-launch` |
| `success` | True only for normally exited zero native status **and** complete cleanup |
| `native_exit_code` | Integer when known, JSON `null` otherwise; never substitute 0 |
| `stdout`, `stderr` | Separate captures on every outcome, including successful stderr and failed stdout |
| `capture` | Observed/retained bytes, truncation, decode replacement, durable paths when requested |
| `timeout_seconds_requested`, `timeout_seconds_effective` | Effective is `null` only when `unbounded` |
| `cleanup` | `complete` \| `not-needed` \| `incomplete`, plus diagnostics; keep the original `outcome` |
| `timing_ms` | Monotonic elapsed; optional validation/launch/drain/cleanup splits if they are real boundaries |
| `powershell` | Executable path, PS version, .NET description, profile path or null |
| `cwd`, `started_utc` | Child working directory and start time |

Preserve the full structured payload when the MCP tool result is unsuccessful. Verify `mcp<2` stdio `structuredContent` / text fallback / `isError`; do **not** raise an exception that replaces the payload with a generic error. Text may be compact JSON or a short pointer at `output_directory` for large captures.

Record the PowerShell process exit. Do not infer failure by parsing stderr, searching for `Error:`, or reading a stale `$LASTEXITCODE`. A script that launches a failing native tool must propagate that outcome itself. Demonstrate with a profile-loaded TAP failure (`ltbatch` or `scripts/test-run.ps1` on `scripts/tests/tap/fail.t` from the LaTeXAI checkout) **and** a tiny non-project `Write-Output 'report'; exit 7`. Do not globally change `$ErrorActionPreference` as part of this transport change.

## 5. P2 — Supervision and cancellation

Cancellation-aware I/O while the child runs. `async def` wrapping blocking `communicate()`, or cancelling that thread, is not process termination. Trace the **installed** MCP request-cancellation and server-shutdown paths.

1. Validate inputs, take ownership, launch headlessly with shell-disabled argv and redirected streams. MCP protocol stdout stays separate from child output.
2. Monotonic deadline over profile + user code. Output readers must not block timeout/cancellation.
3. On deadline, request cancel, controlled disconnect/shutdown, or unwind: stop the **owned process tree** and drain both streams within the cleanup budget. Killing only the immediate `pwsh` is insufficient for PowerShell → executor worker → Perl.
4. Races among start, registration, normal exit and cancel: never kill a reused PID or another invocation's process.
5. Finalise available evidence on every exit path. Bound post-kill waits and reader joins. Keep the original timeout/cancel plus any cleanup failure.
6. Release handles. The next request must still work.

Windows: an owned Job Object (kill-on-job-close) or an equivalent **tested** tree mechanism; `Popen.kill()` is not enough. `taskkill /T` may assist timeout but is not the hard-parent-death story. Do not import CDXSCI's native helper into this Python server. Qualify controlled cancel/shutdown separately from abrupt parent death; a Python `finally` does not prove Job Object kill-on-close. If you claim that guarantee, test abrupt server death and descendant disappearance; otherwise disclose the limit. Never report `success` when teardown is incomplete.

## 6. P3 — Output retention and profile boundaries

Read stdout and stderr concurrently. Bound in-memory retention (document head/tail; a 2 MiB combined cap is acceptable if accounted). Preserve UTF-8 boundaries; keep raw files when decode is lossy. No unbounded `communicate()` on the supervised path. When a durable limit is hit, drain/discard with truthful accounting or stop with an explicit outcome; do not deadlock on a full pipe. Do not automatically store `code` or the full environment.

Profiles: keep `-NoProfile` plus explicit load. Preserve absent/default, blank/disabled, configured-valid and configured-invalid. A bad configured profile must block user code. Profile diagnostics must not hit MCP protocol stdout.

Default profile: inventory consumers, then make default startup noninteractive and project-neutral. **LaTeXAI already uses `scripts/profile.ps1`.** After inventory, remove `latexAI-aliases.ps1` from the default profile; keep other helpers only if something still consumes them. Interactive console furniture stays opt-in. Fix the README PATH-fallback claim; do not add PATH search just to match stale prose.

A normal MCP call launches **one** batch. Per-paper PowerShell/Perl processes are under the executor. Persistent MCP sessions would not remove those. Do not add per-line telemetry or return entire batch JSON merely for timings. Defender/NTFS/RAM-disk stay out of profile startup. `CDXSCI_TEMP` inherited from MCP env is not a substitute for adapter scratch projection.

## 7. P4 — Long batch transport qualification

Document together: LaTeXAI job timeout, LaTeXAI batch wait, MCP `timeout_seconds`, **this client's** request deadline, and cleanup. A server timeout cannot extend a shorter client timeout.

Launch client for this flight: the Grok Build registration that loads this server with LaTeXAI `.mcp.json`. Name the measured client request window in the implementation report. Qualification needs a legitimate invocation longer than that window if the window would otherwise cut the batch; use a controlled sleep/TAP hang fixture before a real gauntlet.

If this client cannot hold the needed duration, P4 is incomplete **for Grok** and the follow-up is a small start/read/cancel handle over isolated owned processes — not fire-and-forget and not a persistent shared `pwsh`. Do not claim LaTeXAI batches are fully MCP-supported until P4 is evidenced for this client.

## 8. Verification and delivery

Extend the existing unittest suite. Native supervision cannot be qualified by mocks alone. Update string-result assertions; do not keep a second implementation.

| Case | Required evidence |
| :--- | :--- |
| Successful stdout and stderr | Both streams; zero native exit; `success` true |
| Printed report then `exit 7` | Stdout, stderr, nonzero exit in structured result |
| LaTeXAI TAP failure through project profile | `scripts/test-run.ps1 -Path scripts/tests/tap/fail.t` (or `ltbatch`) from LaTeXAI cwd with `scripts/profile.ps1`; failure report not dropped |
| Missing executable, invalid cwd, bad profile | Distinct launch failure; user sentinel never runs; no orphan |
| Runtime floor | Selected PS below 7.5 rejected before profile/user code; 7.5 and bundled 7.6 report identity |
| Unicode, quotes, spaces | code/profile/cwd without path injection or decode loss |
| Simultaneous large stdout/stderr | No deadlock; bounded memory; truthful truncation |
| Timeout during profile and during user code | Partial output; finite cleanup |
| Child spawns grandchild | Owned descendants gone after timeout/cancel; unrelated sentinel survives |
| Cancel during launch, output, exit race | One terminal record; no leaked ownership |
| Disconnect / controlled shutdown | Actual MCP/stdio path reaches cleanup |
| Failed kill or stalled drain | Bounded return; original outcome preserved; `success` false |
| Next call after failure/cancel | Server usable; fresh per-call state |
| External cwd + configured project profile | Existing outside-project stdio case still holds |
| Supported long-call client path | Recorded Grok/client vs server limits; bounded completion or explicit P4 gap |

Zero exit plus stderr is not a failed native process. Cleanup tests must observe process liveness, not only that kill was invoked. Missing restored runtimes are skips.

Canonical gate, from `mcp/pwsh_exec`:

```powershell
& './deps/bin/uv/uv.exe' run --project . --no-cache --locked python -B -W error -m unittest discover -s tests -v
```

Keep dependency-pin tests green. Add a dependency only for a demonstrated need, with lock/restore updated together.

Deliver P1–P3 as reviewable `mcp/pwsh_exec` changes plus README/tests; complete P4 for this Grok registration before calling LaTeXAI batches fully MCP-supported. Coordinate server restart with idle LaTeXAI consumers. Append the implementation report here: revisions, schema, effective defaults, tests/skips, process-tree observations, client window, remaining limits.

## Implementation report (2026-09-10)

Status: P1–P3 landed on current `main` (`ffdd932` baseline, not `f0e095b`). Client windows set 2026-09-10 (this session); live `pwsh_exec` was **not** restarted — Grok/Codex pick up `tool_timeout_sec` from config, env/profile only after a spawn.

- **Revisions:** `mcp/pwsh_exec/{server,invocation,windows_job}.py`; default profile noninteractive; README PATH-fallback claim removed; unittest suite extended. Canonical gate: 47 tests, 0 skips in this run (optional TAP and 7.5 env were set).
- **Schema:** `pwsh_exec/invocation/0.1`. Tool remains `run_powershell`. Additive args: `cwd`, `timeout_seconds`, `output_directory`, `unbounded`. MCP `CallToolResult` with `structuredContent` + compact text; `isError` iff `success` is false. No string/`Error:` alias.
- **Defaults:** `timeout_seconds` 7800; cleanup 30 s; in-memory capture 2 MiB combined head/tail; PS floor 7.5 (major.minor). Executable/profile only from `MCP_POWERSHELL_*` and bundled paths.
- **Identity:** bundled child 7.6.4 / .NET 10.0.10; `MCP_POWERSHELL_7_5` 7.5.5 qualified. Below-floor rejected before user code (probe mock of 7.4.6). Windows PowerShell 5.1 was not used as a native probe (host failed to load).
- **Process tree:** Windows Job Object, `CREATE_SUSPENDED` then assign then resume, `KILL_ON_JOB_CLOSE`. Timeout and cancel reap grandchildren; unrelated sentinel survives. Abrupt parent `os._exit` (helper, no Python `finally`) kills the job child. MCP `notifications/cancelled` kills the owned `pwsh`; mcp 1.29 still replies `Request cancelled` (JSON-RPC error) rather than the structured payload — evidence is in `output_directory` when requested.
- **Profile inventory:** LaTeXAI already uses `scripts/profile.ps1`. `latexAI-aliases.ps1` removed from the default profile (file kept, unused). Console furniture / dotnet aliases / completions only if `MCP_POWERSHELL_INTERACTIVE=1`.
- **LaTeXAI TAP:** `scripts/test-run.ps1 -Path scripts/tests/tap/fail.t` from the LaTeXAI checkout with `scripts/profile.ps1`; failure report retained; native exit nonzero.
- **Client window (P4):** Configured 2026-09-10. science-facility Grok/Codex/`.mcp.json`: **8400 s** (7800+600). LaTeXAI Grok/Codex/`.mcp.json`: **29400 s** (gauntlet 28800+600), profile still `scripts/profile.ps1`. Grok honors timeout on `.grok/config.toml` (overrides `.mcp.json` for this name). Codex honors `.codex/config.toml` `tool_timeout_sec` (default was 60 s). Qualification of a hang longer than the old 6000 s window was not re-run. Restart the MCP process when consumers are idle so env matches disk.
- **Remaining:** idle-consumer restart. Nested MCP-job vs executor-job still needs a joined fixture (CDXSCI note). Do not import the executor. `unbounded` is diagnostic only. Stale personal Claude/Cursor `pwsh_exec` copies (`.venv/Scripts/uv.exe`) were not updated.
