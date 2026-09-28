# pwsh_exec

A lightweight stdio MCP server that runs PowerShell code in a fresh child process
and returns a structured invocation result. The implementation is client-neutral:
multiple MCP clients can share the server and bundled PowerShell runtime while
selecting their own optional profiles. The server supervises one PowerShell
process per call; workload scheduling and domain results stay in the called
scripts.

## Runtime contract

`run_powershell` runs short commands synchronously. Long work uses
`start_powershell`, `wait_powershell`, and `cancel_powershell`.

Each call starts a new PowerShell process with `-NoProfile`; automatic user and
host profiles are never loaded. A configured or default profile is then dotted
into that process. The selected executable must be PowerShell **7.5 or newer**
(probe cached per resolved path, before profile or user code).

The executable resolver uses this order only:

1. A nonblank `MCP_POWERSHELL_EXECUTABLE` override.
2. `deps/bin/pwsh/pwsh.exe` beside the MCP server.

There is no PATH search and no user-home, drive-letter, or sibling-checkout
fallback.

| Argument            | Default | Meaning |
| ------------------- | ------- | ------- |
| `code`              | required | PowerShell to run after optional profile load |
| `cwd`               | server-start cwd | Must exist; the server never `chdir`s |
| `timeout_seconds`   | 30 | Synchronous default; covers admission, profile and user code. Must be finite and `> 0` unless `unbounded` |
| `output_directory`  | none | Caller-owned unique directory; rejected if it exists or lies under `mcp/pwsh_exec/` |
| `unbounded`         | false | Visible diagnostic opt-in; effective timeout is then JSON `null` |

`start_powershell` requires a caller-selected `timeout_seconds` (or explicit
`unbounded: true`) and an absolute, new `output_directory`. It returns a job ID
immediately. `wait_powershell(id, wait_seconds)` waits from 0 to 20 seconds without
changing the execution deadline; a completed response contains the existing
invocation result under `result`. `cancel_powershell(id)` requests cancellation;
poll until the terminal result confirms cleanup. These jobs belong to the server
and are cancelled on shutdown. At most eight jobs are active; the most recent
128 handles remain queryable, and completed evidence stays on disk.

For example, start `ltbatch -Selection full -ExecutionTimeoutSeconds 7200` with
`timeout_seconds: 7350`, then poll with `wait_seconds: 20`. Choose the outer budget
to cover script preflight, executor work, executor cleanup and result writing.
The MCP adds one separate 30-second cleanup budget after execution ends. No
universal gauntlet or test duration is imposed by the server. The synchronous
default changed from 7800 to 30 seconds; callers of longer work should use the
start/wait flow or explicitly configure both their synchronous and client budgets.

A server timeout cannot extend a shorter **client** request deadline. Short polls
allow long executions even under such a deadline. Poll cancellation leaves the
work running; cancelling `run_powershell` or calling `cancel_powershell` stops it.
Failed terminal responses set `isError`, while retaining their structured result.

The result schema is `pwsh_exec/invocation/0.1`. Fields include `outcome`
(`exited` \| `timed-out` \| `cancelled` \| `failed-to-launch`), `success` (true
only for a normal zero native exit **and** complete cleanup), `native_exit_code`
(JSON `null` when unknown; never substituted with 0), separate `stdout`/`stderr`,
`capture` accounting, requested vs effective timeout, `cleanup`, `timing_ms`,
`powershell` identity, `cwd`, and `started_utc`. Unsuccessful MCP calls still
return this payload (`structuredContent` plus compact text; `isError` when
`success` is false). Large captures use a short pointer at `output_directory`.

Native exit is the process exit code. The server does not parse stderr, look for
`Error:`, or read `$LASTEXITCODE`. Zero exit with stderr is still success.

On Windows the child is born into an owned Job Object (`KILL_ON_JOB_CLOSE`)
after `CREATE_SUSPENDED`. Timeout, MCP request cancellation, and server shutdown
stop that process tree. `Popen.kill()` of the immediate `pwsh` is not the
containment mechanism. In-memory stream retention is bounded (2 MiB combined
head/tail); durable files under `output_directory` keep the raw bytes.

The server recognizes these client-neutral configuration variables:

| Variable                    | Required | Meaning                                                                                                           |
| --------------------------- | -------- | ----------------------------------------------------------------------------------------------------------------- |
| `MCP_POWERSHELL_EXECUTABLE` | No       | Absolute executable override. The bundled PowerShell is the default.                                              |
| `MCP_POWERSHELL_PROFILE`    | No       | Absolute path to a custom profile file. Defaults to `scripts/pwsh/profile-pwsh.ps1` beside the MCP server.       |

When a profile is configured or discovered at `scripts/pwsh/profile-pwsh.ps1`, it is resolved with PowerShell's `-LiteralPath`
semantics and loaded once per tool call. Profile success-stream output is suppressed, while
functions, aliases, modules, variables, and environment changes remain
available to the requested code in that process. An explicitly configured missing or invalid profile
causes that invocation to fail instead of silently continuing. Profile diagnostics go to the
child capture, not MCP protocol stdout.

The default profile is noninteractive and project-neutral. Interactive console
furniture (history, prompt, completions) is opt-in via `MCP_POWERSHELL_INTERACTIVE=1`.
MCP invocations do not persist state between calls.

## Local runtime

The default runtime is provisioned at:

```text
deps/bin/pwsh/pwsh.exe
```

`deps/` is ignored by the repository and is a machine-local runtime artifact,
not a Python package dependency. After extracting a downloaded portable
distribution, verify its checksum and remove Windows download-zone markings
from every extracted file:

```powershell
Get-ChildItem `
  -LiteralPath '.\deps\bin\pwsh' `
  -Recurse -File |
    Unblock-File
```

Those markings can prevent built-in modules and their `.ps1xml` metadata from
loading under a sandbox even when `pwsh.exe` itself starts successfully.

## Standalone dependency layout

`pwsh_exec` owns a complete bootstrap and runtime dependency architecture:

```text
brewery/uv/
  pin.json
  restore-uv.ps1
deps/bin/uv/           # ignored verified uv executable (restore only)
deps/bin/pwsh/         # ignored bundled PowerShell
deps/python/           # ignored owned CPython; site-packages live here
.cache/uv/             # ignored download cache
.python-version        # committed interpreter pin
pyproject.toml         # committed dependency and uv-version contract
uv.lock                # committed complete dependency resolution
```

Restore rehydrates that tree on a cold machine. `uv` is the restore tool, not a
Python package and not the MCP parent. The MCP process is the owned
`python.exe`; packages are already on that interpreter's `sys.path`. There is
no project `.venv` overlay and no spawn-time `uv sync`.

The same uv version is enforced independently by `brewery/uv/pin.json` and
`[tool.uv].required-version` in `pyproject.toml`. Contract tests reject drift
between those layers.

This structure is wholly local to `pwsh_exec`. The bootstrap script does not
discover or call another project, `PDenv`, or an ambient uv/Python executable.

## Restore

From the project root, run:

```powershell
& '.\brewery\uv\restore-uv.ps1'
```

The recipe:

1. Selects the pinned artifact for the current platform.
2. Downloads it from the official uv release and verifies both the archive and
   extracted bootstrap executable SHA-256 values.
3. Restores the executable under ignored `deps/bin/uv/`.
4. Installs the pinned CPython under ignored `deps/python/` (cache under `.cache/uv/`).
5. Installs `uv.lock` into that interpreter's site-packages.
6. Writes an ignored, machine-local registration to
   `deps/registrations/pwsh_exec.json` that launches the owned `python.exe`.
7. Runs the tests with that interpreter.
8. Refreshes gitignored `mcp.local.json` registration (seeds empty `targets` if
   the file is missing) and applies that generic block onto listed local
   endpoints.

## Client configuration

Spawn is the owned interpreter. **Env is per consumer**; do not copy one block
everywhere.

Tracked generic templates live at `mcp.example.json` and `mcp.example.toml`.
They use placeholders and the default `scripts/pwsh/profile-pwsh.ps1` profile.
The TOML template allows 90 seconds per transport request, leaving room for the
30-second synchronous default and cleanup. This does not cap a started job.

Gitignored `mcp.local.json` is this machine's source of truth for generic
endpoints: resolved `registration` plus `targets[]`. Restore refreshes
`registration` from `deps/registrations` and runs
`brewery/uv/sync-mcp-local.py`. Sync overwrites `command` / `args` / generic
env on each existing target and keeps extra consumer keys (`type`,
`startup_timeout_sec`, `tool_timeout_sec`). A checkout that contains this tree
may set `relativeTo` so paths stay repo-relative; other targets get absolute
paths. Missing target files are skipped.

LaTeXAI owns separate templates using `scripts/profile.ps1`. Its resolver takes
`PERL_ROOT` / `CDXSCI_ROOT` from arguments, environment or ignored local config;
the profile derives `LATEXAI_ROOT`. Its scripts own workload budgets and its MCP
caller supplies the outer execution budget. Sync refuses that consumer profile.

Generic:

```json
{
  "mcpServers": {
    "pwsh_exec": {
      "command": "<pwsh_exec-root>/deps/python/cpython-<version>-*/python.exe",
      "args": ["-B", "<pwsh_exec-root>/server.py"],
      "env": {
        "MCP_POWERSHELL_EXECUTABLE": "<pwsh_exec-root>/deps/bin/pwsh/pwsh.exe",
        "MCP_POWERSHELL_PROFILE": "<pwsh_exec-root>/scripts/pwsh/profile-pwsh.ps1"
      }
    }
  }
}
```

Grok/Codex client deadlines live on each consumer's TOML
(`[mcp_servers.pwsh_exec] tool_timeout_sec`). They apply to individual requests,
including polls. Reconnect the MCP server after changing its source so clients
discover the added tools; restarting is not needed between jobs.

## Tests

Run from this directory:

```powershell
& '.\deps\python\cpython-<version>-*\python.exe' `
  -B -W error -m unittest discover -s tests -v
```

The suite includes dependency-pin contract tests, native supervision tests, and
an MCP stdio round trip through the owned `deps/python` interpreter. Runtime
integrations are skipped only when the corresponding restored artifacts are
absent. Optional coverage: `LATEXAI_ROOT` + `PERL_ROOT` + `CDXSCI_ROOT` for a
profile-loaded TAP failure; `MCP_POWERSHELL_7_5` for a 7.5 identity probe.

Set `PWSH_EXEC_LONG_PROBE=1` to exercise a 65-second job through short MCP
requests. Set `PWSH_EXEC_FULL_LATEXAI=1` and `LATEXAI_ROOT` for the full TAP
consumer qualification through start/wait. These longer checks are opt-in;
LaTeXAI resolves its runtimes through its profile and ignored local configuration.
`tests/run_stdio_job.py` provides the same fresh-server start/wait path for a
bounded qualification command, with explicit cwd, output directory and timeout.
