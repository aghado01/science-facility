---
name: nushell-agent
description: Nushell (nu) execution substrate primer with progressive topic disclosure.
---

# Nushell Agent Skill

Nushell (`nu`) is a structured, type-aware shell substrate. When running under the science-facility augmented console, `evaluate` provides a **persistent REPL** (variables, modules, `$env`, and `cd` persist across calls) with preloaded runtime services: `nu-skills`, `nu-modules`, `par`, `jobs`, `dataspection`, `xq`, and `rg`.

## Console Discipline

- **Implicit Return**: Return values implicitly or use `print -e` for diagnostic stderr. Bare `print` in stdio MCP returns empty.
- **Receipts Before Bodies**: One tool result carries at most one payload. Anything withheld names the call that retrieves it (`jobs fetch <tag>`).
- **THE RULE (Pipeline Capping)**: Never cap a pipeline on its first run (do not `ls | ... | first 5` or `^rg ... | head`). Store or bind the data first (`let files = (ls | sort-by size -r); $files | first 5`). Slicing an already-stored or bound value is always lawful (`$x`, `$history.N`, `jobs fetch <tag> | page`).
- **Failure is Data**: Every layer result carries `ok: bool`. Caught failures return `ok: false` as data in a successful evaluate with a `$history` entry. Uncaught engine throws produce error results with no `$history` entry.
- **Core Modules**:
  - `jobs`: Handle plane (`jobs spawn`, `list`, `collect`, `inspect`, `read`, `fetch`, `cancel`), `par` data plane, and `xq` execute-and-quarantine.
  - `search`: Wrapped `rg` returning structured findings, JSON summary, and spine on truncation (`^rg` escape hatch).
  - `dataspection`: Census and disclosure ladder on a value in hand (`shape`, `schema`, `spine`, `read`, `preview`, `page`, `meta`).

## Topic Discovery (`nu-skills`)

The reference corpus is served dynamically from the filesystem:

- **List Top Level**: `nu-skills list` (shows top-level pages and the `appendix` branch).
- **List Appendix**: `nu-skills list appendix` (superseded native forms, filed by origin document).
- **List All Leaves**: `nu-skills list --all` (every leaf, path-qualified).
- **Read Topic or Branch**: `nu-skills read <topic>` (e.g. `nu-skills read jobs`, `nu-skills read appendix`, `nu-skills read appendix/advanced`).
- **Search References**: `nu-skills search <regex>` (searches all topics across root and appendix).
