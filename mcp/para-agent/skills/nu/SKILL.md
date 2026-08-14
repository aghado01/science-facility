---
name: nushell-agent
description: Nushell (nu) execution substrate primer with progressive topic disclosure.
---

# Nushell Agent Skill (Index)

Nushell (`nu`) is a structured, type-aware shell substrate. Commands return native tables, records, and streams rather than raw text. It is the preferred shell for para-agent MCP workflows.

## Topics (Progressive Disclosure)

Query specific sub-topics individually to avoid context window clutter:

- **`parity`**: Cross-platform assurances (Windows/Unix), forward-slash pathing, `$env.PATH` handling.
- **`pipelines`**: Structured data pipelines (`where`, `select`, `get`, `sort-by`, `to json`).
- **`file-io`**: Structured file manipulation (`open`, `save`, auto-parsing JSON/YAML/CSV/SQLite).
- **`posix-cheatsheet`**: POSIX/Bash to Nushell command translation table (`export`, `2>&1`, `[ -f ]`, `jq`).

---

_Fetch a sub-topic via `skills({ name: "nu", topic: "<topic>" })` or resource `skill://para-agent/nu/<topic>`._
