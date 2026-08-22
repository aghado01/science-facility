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
- `$history` is a bare `list<any>`: one element per **successful** `evaluate`, the element being exactly the returned value (records keep their keys; nested structure intact; never truncated). No envelope — no timestamp, command text, cwd, or error; pipeline metadata is stripped (only `span` survives).
- **Index Access**: `$history.0`, `$history.1`, … The tool result's `history_index` is the slot. Verified 2026-08-22 on nu 0.114.1:
  - **Failed evaluates leave no entry.** An error result carries no `history_index`; the next success takes the next slot. `history_index` counts successes, not evaluates.
  - **A `nothing` result is stored as `[]`** (and relayed as `[]`). `$history.N == null` is false for it; `shape` reports `list`, length 0 — correct for what is stored.
  - **Two failure levels.** An evaluate that throws is engine-level: error result, no entry. A layer verb that *catches* a failure and returns it as data (`ok: false`, `error`, maybe `trace`) is a successful evaluate with an entry — legible only through its own `ok`. Every layer record carries `ok`.
  - Census without dumping: `$history | shape each` (probe) — `index` *is* the `history_index`; `ok` is lifted, so `| where ok == false` finds caught failures.
- **Token Economy**: If output exceeds `$env.NU_MCP_OUTPUT_LIMIT` and gets truncated, slice the preserved in-memory data in the next turn without re-running:
  ```nu
  $history.0 | where status == "error" | select id message | first 5
  ```

## Session Reset
- Session state lives for the lifetime of the MCP server process. Restarting the client or MCP server resets the session to a clean default state.
