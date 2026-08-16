Searched web: ""NU_MCP_" OR "NU_LIB_DIRS" nushell environment variables"

Here are the most relevant **environment variables** and **CLI flags (`args`)** for configuring `nu --mcp` cleanly for AI agents:

---

### 1. Environment Variables (`env`)

| Variable | Recommended Value | Purpose & Relevance |
| :--- | :--- | :--- |
| **`NU_MCP_OUTPUT_LIMIT`** | `"20kb"` (or `"50kb"`) | Controls the truncation threshold for `evaluate` output before routing to `$history.0`. |
| **`NO_COLOR`** | `"1"` or `"true"` | Standard cross-platform var. **Disables ANSI color escape codes** in command output, preventing token waste on `\u001b[...]` sequences. *(Prefer this over `NU_COLOR`)*. |
| **`NU_LOG_LEVEL`** | `"warn"` or `"error"` | Sets internal Nushell log verbosity. Keeps stdio/stderr clean of internal Nushell engine debug messages (`error`, `warn`, `info`, `debug`, `trace`). |
| **`NU_LOG_FILE`** | `"/path/to/nu_mcp.log"` | Redirects Nushell internal diagnostics to a log file instead of stderr. |
| **`NU_LIB_DIRS`** | `"/path/to/modules"` | Specifies directories searched by `use` and `source` so the agent can load custom `.nu` helper modules without full paths. |

> [!NOTE]
> `NU_OUTPUT_FORMAT` is not an official Nushell engine environment variable. By default, the `evaluate` tool returns native structured JSON to the MCP protocol. For formatting specific outputs, use explicit pipes inside queries (e.g., `| to json -c`).

---

### 2. Relevant CLI Flags (`args`)

In addition to `--mcp`, these flags in `"args"` optimize agent execution:

| Flag | Purpose | Why Use for Agents |
| :--- | :--- | :--- |
| **`--no-config-file`** (or **`-n`**) | Skips loading personal `config.nu` / `env.nu`. | **Ensures a clean, deterministic, fast sandbox**. Prevents interactive prompt hooks, themes, or user aliases from interfering with agent commands. |
| **`--config`** `/path/to/agent.nu` | Loads a dedicated agent config file. | Pre-loads custom agent helper commands, prelude definitions, or policies. |
| **`--env-config`** `/path/to/agent-env.nu` | Loads dedicated agent environment variables. | Configures base environment variables specifically for the MCP session. |

---

### 3. Recommended `.mcp.json` Configuration

```json
"nushell": {
  "command": "nu",
  "args": [
    "--mcp",
    "--no-config-file"
  ],
  "env": {
    "NU_MCP_OUTPUT_LIMIT": "20kb",
    "NO_COLOR": "1",
    "NU_LOG_LEVEL": "warn"
  }
}
```