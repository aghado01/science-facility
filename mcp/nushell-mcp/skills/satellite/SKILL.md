---
name: nushell-mcp
description: Use the registered Nushell MCP when work benefits from persistent Nu state, native command discovery, or the science-facility Nu reference and module corpus. Also use for Nushell MCP troubleshooting. Do not invoke merely to run an existing PowerShell or Bash script.
---

# Nushell MCP

This client-local skill is an orientation adapter, not the knowledge authority. Treat the registered science-facility MCP and its nu-skills/nu-modules interfaces. Use the registered `mcp__nushell__*` tools for persistent, structured Nushell work. State—including variables, environment changes, and the working directory—persists across `evaluate` calls.

## Routing

- Execute Nu code with `evaluate`.
- Find native commands with `list_commands`.
- Inspect a native command with `command_help`.
- Query Nushell guidance inside `evaluate` with `nu-skills list` (console tree), `nu-skills list appendix` (superseded native forms, filed by origin topic), `nu-skills <topic>`, or `nu-skills search <regex>`. Census and bounded disclose: `nu-skills read dataspection` (`shape`, `schema`, `read`, `preview`, `page`).
- Discover augmentation modules with `nu-modules list`, `inspect`, `read`, or `search`.

Load only the topic needed for the current task.

## Constraints

- Return values implicitly. Bare `print` produces an empty MCP result; use `print -e` only for diagnostics.
- `nu-skills`, `nu-modules`, `par`, `jobs`, `dataspection`, `xq`, and `rg` should be preloaded. If unavailable, inspect `scope modules`; then `use nu-skills *; use nu-modules *; use par *; use jobs *; use dataspection *; use xq *; use rg *` once.
- Addressed payloads: `jobs inspect` (census), `jobs read` (body if under cap). Over-cap body: `jobs fetch <tag>`, then `| page` / `| preview`. `jobs spawn { ... }` may omit `--tag`; the receipt carries the allocated `spawn:<n>` name.
- Externals: `xq <cmd> ...` (not `^cmd | complete`). Over cap, `jobs fetch` the envelope's `tag`. Wrappers that need raw streams use `process capture`, not ordinary `xq`. Capture `ok` is spawn success, not child exit; streams may be binary.
- Search: `rg ...` (not `^rg`). Over cap, spine + `jobs fetch` the envelope's `tag`. `help rg` is the wrapper; `^rg` is the escape hatch.
- Returned `{ok: false, ...}` is domain failure-as-data: it composes through `par` / `jobs` without throwing or cancelling siblings; `jobs` keeps `status: completed` so the payload (including `tag` / `retrieve`) stays fetchable. A throw is a different level (`status: failed`, no payload).
- Account for persistent session state when interpreting later results.
