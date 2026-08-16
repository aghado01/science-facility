---
name: nushell-agent
description: Nushell (nu) execution substrate primer with progressive topic disclosure.
---

# Nushell Agent Skill 

Nushell (`nu`) is a structured, type-aware shell substrate. Commands return native tables, records, and streams rather than raw text. It is the preferred shell for interactive, forensic and data-driven workflows. 

## Native MCP 

Nushell also ships with native built-in MCP functionality to help agents:

- **`evaluate`** (`mcp__nushell__evaluate`): Executes Nu code in a **persistent REPL** (variables, modules, `$env`, and `cd` persist across calls).
- **`list_commands`** (`mcp__nushell__list_commands`): Searches and filters available built-in and custom commands.
- **`command_help`** (`mcp__nushell__command_help`): Retrieves formatted documentation and flag signatures for a command.

## Interactive Discovery Tools
When `NU_LIB_DIRS` is configured, companion discovery modules provide structured introspection:
- **`nu-skills`**: Query skill reference topics (`nu-skills list`, `nu-skills read <topic>`, `nu-skills search <query>`).
- **`nu-modules`**: Introspect and search library modules in `NU_LIB_DIRS` (`nu-modules list`, `nu-modules inspect <mod>`, `nu-modules search <query>`).

## Important Notes
- **String Interpolation**: Use `()` → `$"($env.VAR)"` (NOT `$"{$var}"`).
- **MCP Output**: Never bare `print` in stdio MCP (returns empty). Implicitly return values or use `print -e`.
- **`where` Scope**: Bare columns only: `where a > 1 and b > 2` (chaining `$in.a and $in.b` rebinds `$in` to bool).
- **Raw Files**: `cat` is `open --raw file` (`open` parses structured data automatically).
- **Piping**: Nushell pipes structured data (tables, records) between commands, not raw text.
- **Path Handling**: Nushell handles path normalization automatically; Prefer forward-slash `/` for paths.
- **Custom Commands**: Use `def` for custom commands with type hints for better IDE support.
- **Type Coercion**: Nushell attempts automatic type coercion, but explicit casting with `as` is recommended for clarity.

## Topics 
Query specific sub-topics individually to avoid context window clutter:

- **`posix-cheatsheet`**: POSIX/Bash to Nushell command translation table (`export`, `2>&1`, `grep`, `sed`, `jq`, `tee`).
- **`pipelines`**: Structured data pipelines (`where`, `select`, `get`, `sort-by`, `to json`).
- **`file-io`**: Structured file manipulation (`open`, `save`, auto-parsing JSON/YAML/CSV/SQLite).
- **`data-analysis`**: HTTP endpoints, Polars DataFrames, SQLite, aggregations (`group-by`, `math`).
- **`advanced`**: Typed custom commands (`def`), background jobs (`job spawn`), structured errors (`try/catch`).
- **`parity`**: Cross-platform assurances (Windows/Unix), forward-slash pathing, `$env.PATH` handling.
- **`gotchas`**: Syntax edge-cases, parenthesized strings, escaping, closure scoping.
- **`mcp`**: Native `nu --mcp` launch, configuration, and stream handling.
- **`sessions`**: In-memory engine lifecycle, state persistence, scoping, and `$history` buffer slicing.

_Query inventory via `nu-skills list` or read sub-topics via `nu-skills read <topic>` (or open `references/<topic>.md`)._
