# Nushell: MCP Session Lifecycle & State Persistence

The built-in MCP server (`nu --mcp`) runs a single, continuous in-memory engine process holding an active `EngineState` and `Stack` across agent tool calls.

## Persistent State (Survives Across Calls)
- **Variables**: `let dataset = (open large.json)` → `$dataset` is accessible in subsequent calls.
- **Working Directory**: `cd /path/to/project` → remains current working directory.
- **Environment**: `$env.API_TOKEN = "xyz"` → persists in `$env`.
- **Custom Definitions**: `def my-helper [] { ... }` or `use module.nu *` → remains callable.

## Scope Boundaries
- **Top-level Scope**: Any top-level `let`, `$env`, `def`, or `cd` persists in the global session state.
- **Block / Closure Scope**: Inner variables inside `do { ... }` or `each { ... }` are discarded when the block exits.

## `$history` Evaluation Buffer
- Every `evaluate` call stores its complete, untruncated return value in the `$history` table.
- **Index Access**: First call is `$history.0`, second is `$history.1`, etc.
- **Token Economy**: If output exceeds `$env.NU_MCP_OUTPUT_LIMIT` and gets truncated, slice the preserved in-memory data in the next turn without re-running:
  ```nu
  $history.0 | where status == "error" | select id message | first 5
  ```

## Session Reset
- Session state lives for the lifetime of the MCP server process. Restarting the client or MCP server resets the session to a clean default state.
