# Stock Nushell: Native Built-in MCP Server (`nu --mcp`)

Displaced from `mcp`; console equivalent: [`nu-skills read mcp`](../mcp.md).

Canonical Nushell includes a native Model Context Protocol (MCP) server directly in the `nu` binary.

## Server Launch & Config
- **Command**: `nu --mcp` (runs stdio MCP server; supports HTTP mode if configured).
- **Client Config**: `{"command": "nu", "args": ["--mcp"]}`

## Output Handling & State Memory
- **Output Limit**: Outputs exceeding `$env.NU_MCP_OUTPUT_LIMIT` are truncated.
- **History Retrieval**: Full untruncated outputs of prior successful evaluations are stored in `$history` (e.g. `$history.0`, `$history.1`).
- **Stream Rules**: Always use implicit return for results; bare `print` in stdio drops output. Use `print -e` for diagnostic stderr logging.
