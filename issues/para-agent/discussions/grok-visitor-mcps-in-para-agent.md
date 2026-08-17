That closes the set.

| # | MCP surface | Domain | Hygienic interaction |
|---|-------------|--------|----------------------|
| 1 | **mdnav_v2** | Markdown | outline → section by address |
| 2 | **jso/TS** | JSON/JSONL | schema → path → preview |
| 3 | **reposnapshot-v3** | Code | snapshot → sub-addressed chunks |
| 4 | **nushell_mcp** | Console | nu-skills / nu-modules → typed, bounded returns |

Same contract on the shell side that you already sketched in the mdnav brief: `list → table`, `read → string`, `search → table of hits`, `inspect → signature + one doc line`, `status → record`. Index first, one item on demand, never preload. Native nushell MCP plus your skill/module layer gives Primary and Para a structured console without pasting scrollback into context.

Four substrates, one disclosure discipline, both agents equally equipped. The mediation plane stays the audit spine; the MCP surface is how they look without drowning.