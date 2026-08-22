# Nushell: Native Built-in MCP Server (`nu --mcp`)

Nushell (v0.108.0+) includes a native Model Context Protocol (MCP) server directly in the `nu` binary.

## Server Launch & Config
- **Command**: `nu --mcp` (runs stdio MCP server; supports HTTP mode if configured).
- **Client Config**: `{"command": "nu", "args": ["--mcp"]}`

## Output Handling & State Memory
- **Output Limit**: Outputs exceeding `$env.NU_MCP_OUTPUT_LIMIT` (default 10KB) are truncated.
- **History Retrieval**: Full untruncated outputs of prior evaluations are stored in `$history` (e.g. `$history.0`, `$history.1`). Census without dumping: `$history | shape each` (dataspection); `index` matches `history_index`. Then `$history.N | preview` / `schema` / `page`.
- **Data Serialization**: Pipe large tables to `to json -c` or `to text` for compact agent transmission.
- **Stream Rules**: Always use implicit return for results; bare `print` in stdio drops output. Use `print -e` for diagnostic stderr logging.
