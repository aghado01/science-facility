# pwsh_exec

A lightweight stdio MCP server that runs PowerShell code in a fresh child process
and returns a structured invocation result. The implementation is client-neutral:
multiple MCP clients can share the server and bundled PowerShell runtime while
selecting their own optional profiles. The server supervises one PowerShell
process per call; workload scheduling and domain results stay in the called
scripts.

## Runtime contract

The server exposes one tool, `run_powershell`. Required argument: `code`.
Optional arguments: `cwd`, `timeout_seconds`, `output_directory`, `unbounded`.

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
| `timeout_seconds`   | 7800 | Covers profile + user code. Must be `> 0` unless `unbounded` |
| `output_directory`  | none | Caller-owned unique directory; rejected if it exists or lies under `mcp/pwsh_exec/` |
| `unbounded`         | false | Visible diagnostic opt-in; effective timeout is then JSON `null` |

7800 s is the test-batch envelope (LaTeXAI Test `WaitTimeoutSeconds` 7200 plus 600 s
drainage). A gauntlet must pass a longer `timeout_seconds`. Cleanup after timeout
or cancel has a separate 30 s budget. A script's own batch timer does not replace
this outer deadline. A server timeout cannot extend a shorter **client** request
deadline (Grok Build default `tool_timeout_sec` is 6000).

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

## Client configuration

All clients launch the owned interpreter under `deps/python/`. The generated
`deps/registrations/pwsh_exec.json` contains resolved paths for this
checkout and can be copied into a client's MCP configuration. Its shape is:

```json
{
  "mcpServers": {
    "pwsh_exec": {
      "command": "<pwsh_exec-root>/deps/python/cpython-<version>-*/python.exe",
      "args": [
        "-B",
        "<pwsh_exec-root>/server.py"
      ],
      "tool_timeout_sec": 8400,
      "env": {
        "MCP_POWERSHELL_PROFILE": "C:/path/to/this-client/mcp-profile.ps1"
      }
    }
  }
}
```

Grok and Codex honor `tool_timeout_sec` on their TOML registrations (Grok:
`.grok/config.toml` `[mcp_servers.pwsh_exec]`; Codex: `.codex/config.toml`).
Grok's default is 6000 s; Codex's default is 60 s. Neither `.mcp.json` extra
field nor the server default can extend a shorter client deadline.

```toml
[mcp_servers.pwsh_exec]
command = "<pwsh_exec-root>/deps/python/cpython-<version>-*/python.exe"
args = ["-B", "<pwsh_exec-root>/server.py"]
startup_timeout_sec = 30
tool_timeout_sec = 8400

[mcp_servers.pwsh_exec.env]
MCP_POWERSHELL_PROFILE = "C:/path/to/this-client/mcp-profile.ps1"
```

Omit `MCP_POWERSHELL_PROFILE` to use the default `scripts/pwsh/profile-pwsh.ps1` profile (if present). Set
`MCP_POWERSHELL_EXECUTABLE` only when deliberately overriding the bundled
runtime.

Client windows:

| Workload | `tool_timeout_sec` | Why |
| -------- | ------------------ | --- |
| Generic / TAP test batch | 8400 | Server default 7800 plus 600 s drainage |
| LaTeXAI gauntlet | 29400 | Policy `WaitTimeoutSeconds` 28800 plus 600 s drainage |

## Tests

Run from this directory:

```powershell
& '.\deps\python\cpython-<version>-*\python.exe' `
  -B -W error -m unittest discover -s tests -v
```

The suite includes dependency-pin contract tests, native supervision tests, and
an MCP stdio round trip through `deps/bin/uv/uv.exe`. Runtime integrations are
skipped only when the corresponding restored artifacts are absent. Optional
coverage: `LATEXAI_ROOT` + `PERL_ROOT` + `CDXSCI_ROOT` for a profile-loaded TAP
failure; `MCP_POWERSHELL_7_5` for a 7.5 identity probe.
