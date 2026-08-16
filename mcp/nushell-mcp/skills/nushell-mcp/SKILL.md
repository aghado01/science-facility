---
name: nushell-mcp
description: Claude-side adapter for the nushell MCP — nushell's native `nu --mcp` server plus the augmentation layer (config.nu, custom modules, reference corpus, nu-skills/nu-modules) under science-facility/mcp/nushell_mcp. Nu usage primer with progressive topic disclosure.
---

# Nushell MCP Adapter

Nushell (`nu`) is a structured, type-aware shell substrate. Commands return native tables, records, and streams rather than raw text. It is the preferred shell for interactive, forensic and data-driven workflows.

This skill is the **Claude-side adapter**: it makes the external system legible to this harness. It is not the reference corpus — that lives with the MCP and is queried through it (see Interactive Discovery Tools). Three layers:

1. **Native server** — `nu --mcp`, baked into the nushell binary. `.mcp.json` key `nushell` → tools `mcp__nushell__*`.
2. **Augmentation layer** — `science-facility/mcp/nushell_mcp/`: `config.nu` (loaded via `--config`), custom modules, the reference corpus, and the `nu-skills` / `nu-modules` introspection commands. Host-agnostic; travels with the MCP.
3. **This adapter** — pointers + Claude ergonomics for 1 and 2.

## Native MCP 

Nushell ships with native built-in MCP functionality to help agents:

- **`evaluate`** (`mcp__nushell__evaluate`): Executes Nu code in a **persistent REPL** (variables, modules, `$env`, and `cd` persist across calls).
- **`list_commands`** (`mcp__nushell__list_commands`): Searches and filters available built-in and custom commands.
- **`command_help`** (`mcp__nushell__command_help`): Retrieves formatted documentation and flag signatures for a command.

## Discovery Commands (preloaded)
The MCP is launched with `--config ./mcp/nushell_mcp/config.nu`, which preloads two introspection modules into the persistent session. Call them directly inside `evaluate` — no `use`, no reading files by path. Verify with `scope modules | get name` (expect `nu-skills`, `nu-modules`); if absent (server started without the config), `use nu-skills *; use nu-modules *` once and it persists.

### `nu-skills` — the nushell reference corpus, on demand
The augmentation layer ships its own nushell reference corpus and serves it through this command. The inventory is derived live from the corpus, so **`nu-skills list` is authoritative**, not this file.

| Command | Returns |
|---|---|
| `nu-skills` | the corpus index (its SKILL.md) |
| `nu-skills list` | table of topics: `topic`, `title`, `size`, `modified` |
| `nu-skills <topic>` / `nu-skills read <topic>` | one topic's full markdown |
| `nu-skills search <regex>` | `topic` / `line` / `content` hits across all topics |
| `nu-skills status` | anchored corpus path, topic count |

What kind of material is in there (as of writing): POSIX/Bash→nu translation, structured pipelines and token economy, structured file I/O, data analysis (HTTP/Polars/SQLite), advanced scripting (typed `def`, `job spawn`, `try/catch`), cross-platform parity and pathing, LLM syntax gotchas, the native `nu --mcp` server, and MCP session lifecycle / `$history` slicing. Fetch one topic when a task touches that area; don't preload the corpus.

### `nu-modules` — the module library, on demand
Introspects every module on `NU_LIB_DIRS` (the layer's `modules/` dir plus any user dirs).

| Command | Returns |
|---|---|
| `nu-modules list` | `module` / `type` / `commands` / `path` |
| `nu-modules inspect <mod>` | exported commands with signature + doc line |
| `nu-modules read <mod>` | raw source of the module entrypoint |
| `nu-modules search <regex>` | `module` / `line` / `content` / `file` hits |
| `nu-modules status` | lib dirs, module count, total commands |

## Important Notes
- **String Interpolation**: Use `()` → `$"($env.VAR)"` (NOT `$"{$var}"`).
- **MCP Output**: Never bare `print` in stdio MCP (returns empty). Implicitly return values or use `print -e`.
- **`where` Scope**: Bare columns only: `where a > 1 and b > 2` (chaining `$in.a and $in.b` rebinds `$in` to bool).
- **Raw Files**: `cat` is `open --raw file` (`open` parses structured data automatically).
- **Piping**: Nushell pipes structured data (tables, records) between commands, not raw text.
- **Path Handling**: Nushell handles path normalization automatically; Prefer forward-slash `/` for paths.
- **Custom Commands**: Use `def` for custom commands with type hints for better IDE support.
- **Type Coercion**: Nushell attempts automatic type coercion, but explicit casting with `as` is recommended for clarity.

Deeper treatment of any of these lives in the corpus — `nu-skills gotchas`, `nu-skills pipelines`, etc.
