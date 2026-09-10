# pwsh_exec

A lightweight stdio MCP server that runs PowerShell code in a fresh child process and
returns its UTF-8 output. The implementation is client-neutral: multiple MCP
clients can share the server and bundled PowerShell runtime while selecting
their own optional profiles.

## Runtime contract

The server exposes one tool:

- `run_powershell(code: str) -> str`

Each tool call starts a new PowerShell process with `-NoProfile`; automatic
user and host profiles are never loaded.

The executable resolver uses this order:

1. A nonblank `MCP_POWERSHELL_EXECUTABLE` override.
2. `deps/bin/pwsh/pwsh.exe` beside the MCP server.
3. `pwsh` and then `powershell` from `PATH`.

The server recognizes these client-neutral configuration variables:

| Variable                    | Required | Meaning                                                                                                           |
| --------------------------- | -------- | ----------------------------------------------------------------------------------------------------------------- |
| `MCP_POWERSHELL_EXECUTABLE` | No       | Absolute executable override. The bundled PowerShell is the default.                                              |
| `MCP_POWERSHELL_PROFILE`    | No       | Absolute path to a custom profile file. Defaults to `scripts/pwsh/profile-pwsh.ps1` beside the MCP server.       |

When a profile is configured or discovered at `scripts/pwsh/profile-pwsh.ps1`, it is resolved with PowerShell's `-LiteralPath`
semantics and loaded once per tool call. Profile output is suppressed, while
functions, aliases, modules, variables, and environment changes remain
available to the requested code in that process. An explicitly configured missing or invalid profile
causes that invocation to fail instead of silently continuing.

Profiles should be noninteractive: avoid prompts, PSReadLine configuration,
and console history setup. MCP invocations are not interactive console
sessions and do not persist state between calls.

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
deps/bin/uv/           # ignored verified uv executable
.python-version        # committed interpreter pin
pyproject.toml         # committed dependency and uv-version contract
uv.lock                # committed complete dependency resolution
```

The same uv version is enforced independently by `brewery/uv/pin.json`, the
exact `uv` dependency and `[tool.uv].required-version` in `pyproject.toml`, and
the resolved `uv` package in `uv.lock`. Contract tests reject drift between
those layers.

This structure is wholly local to `pwsh_exec`. The bootstrap script does not
discover or call another project, `PDenv`, or an ambient uv/Python executable.
It uses uv's normal shared cache and managed-Python storage only as disposable
upstream storage; neither is treated as project-owned source or configuration.

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
4. Installs the exact interpreter from `.python-version` through that uv binary.
5. Runs the tests.
6. Writes an ignored, machine-local registration to
   `deps/registrations/pwsh_exec.json`.

## Client configuration

All clients launch through the uv executable located in `deps/bin/uv/uv.exe`. The generated
`deps/registrations/pwsh_exec.json` contains resolved paths for this
checkout and can be copied into a client's MCP configuration. Its shape is:

```json
{
  "mcpServers": {
    "pwsh_exec": {
      "command": "<pwsh_exec-root>/deps/bin/uv/uv.exe",
      "args": [
        "run",
        "--project",
        "<pwsh_exec-root>",
        "--no-cache",
        "--locked",
        "<pwsh_exec-root>/server.py"
      ],
      "env": {
        "MCP_POWERSHELL_PROFILE": "C:/path/to/this-client/mcp-profile.ps1"
      }
    }
  }
}
```

Omit `MCP_POWERSHELL_PROFILE` to use the default `scripts/pwsh/profile-pwsh.ps1` profile (if present). Set
`MCP_POWERSHELL_EXECUTABLE` only when deliberately overriding the bundled
runtime.

## Tests

Run from this directory:

```powershell
& '.\deps\bin\uv\uv.exe' `
  run --project . --no-cache --locked python -B -W error `
  -m unittest discover -s tests -v
```

The suite includes dependency-pin contract tests and an MCP stdio round trip
through `deps/bin/uv/uv.exe`. Runtime integrations are skipped only when the
corresponding restored artifacts are absent.
