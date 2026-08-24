# Stock Nushell: Builtin `inspect` Command

Displaced from `gotchas`; console equivalent: [`nu-skills read dataspection`](../dataspection.md).

Nushell includes a built-in `inspect` command designed for interactive terminal debugging.

## Behavior
- `inspect` prints a formatted debug view of its input to the terminal output stream.
- It returns its input value **unchanged** (passthrough).

## MCP Substrate Note
Under stdio MCP (`nu --mcp`), an interactive terminal stream does not exist. Calling `$data | inspect` passes the entire `$data` payload unmodified into the pipeline return, which will flood the MCP tool result. In the augmented console, use `dataspection`'s `shape` (`$data | shape`) for a true, bounded census.
