# PowerShell Exec MCP

A small stdio MCP server that runs PowerShell code in a fresh child process and
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
2. `bin/PowerShell-7.6.4-win-x64/pwsh.exe` beside the MCP server.
3. `pwsh` and then `powershell` from `PATH`.

The server recognizes these client-neutral configuration variables:

| Variable | Required | Meaning |
| --- | --- | --- |
| `MCP_POWERSHELL_EXECUTABLE` | No | Absolute executable override. The bundled PowerShell is the default. |
| `MCP_POWERSHELL_PROFILE` | No | Absolute path to one profile file that is explicitly dot-sourced before the requested code. |

When a profile is configured, it is resolved with PowerShell's `-LiteralPath`
semantics and loaded once per tool call. Profile output is suppressed, while
functions, aliases, modules, variables, and environment changes remain
available to the requested code in that process. A missing or invalid profile
causes that invocation to fail instead of silently continuing.

Profiles should be noninteractive: avoid prompts, PSReadLine configuration,
and console history setup. MCP invocations are not interactive console
sessions and do not persist state between calls.

## Local runtime

The default runtime is provisioned at:

```text
bin/PowerShell-7.6.4-win-x64/pwsh.exe
```

`bin/` is ignored by the repository and is a machine-local runtime artifact,
not a Python package dependency. After extracting a downloaded portable
distribution, verify its checksum and remove Windows download-zone markings
from every extracted file:

```powershell
Get-ChildItem `
  -LiteralPath '.\bin\PowerShell-7.6.4-win-x64' `
  -Recurse -File |
    Unblock-File
```

Those markings can prevent built-in modules and their `.ps1xml` metadata from
loading under a sandbox even when `pwsh.exe` itself starts successfully.

## Python dependency layout

This directory is a normal uv project:

- `pyproject.toml` declares the MCP dependency contract.
- `uv.lock` locks the complete Python dependency graph and is versioned.
- `.venv/` is the ignored, project-local environment materialized by uv.
- uv's cache remains in uv's normal per-user cache location; it is disposable
  package/download state, not an MCP-owned project dependency.

Do not redirect uv's shared cache into this project or a client-specific
namespace. Create or refresh the local environment from this directory with:

```powershell
& 'C:\Users\azrie\PDenv\PyenvPython\pyenv-win-3.12.6\versions\3.12.6\Scripts\uv.exe' `
  sync --locked
```

## Client configuration

After `uv sync --locked` provisions `.venv`, all clients can launch the same
project environment and bundled PowerShell directly. This launch path does not
invoke uv or touch its cache. Only the optional profile path needs to vary by
client:

```json
{
  "mcpServers": {
    "powershell-exec": {
      "command": "D:/aghado01/science-facility/mcp/powershell-exec/.venv/Scripts/python.exe",
      "args": [
        "-B",
        "D:/aghado01/science-facility/mcp/powershell-exec/server.py"
      ],
      "env": {
        "MCP_POWERSHELL_PROFILE": "C:/path/to/this-client/mcp-profile.ps1"
      }
    }
  }
}
```

Omit `MCP_POWERSHELL_PROFILE` for a profile-free client. Set
`MCP_POWERSHELL_EXECUTABLE` only when deliberately overriding the bundled
runtime.

## Tests

Run from this directory:

```powershell
& '.\.venv\Scripts\python.exe' `
  -B -m unittest discover -s tests -v
```

The integration tests automatically exercise the bundled runtime when it is
installed; otherwise those tests are skipped.

## Provenance and license

This implementation derives from
[`dfinke/mcp-powershell-exec`](https://github.com/dfinke/mcp-powershell-exec)
and retains its MIT license and original copyright notice. See [LICENSE](LICENSE).
