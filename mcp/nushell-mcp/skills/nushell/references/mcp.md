# Nushell MCP Package & Augmented Console Launch

This package runs a persistent Nushell REPL with science-facility extensions on top of `nu --mcp`.

## Package Launch & Layout
- **Single Layout Owner**: `config.nu` configures the layer. Launchers pass `--config <path-to-config.nu>` and require no ambient environment setup.
- **Engine Binary**: Launches via pinned binary in `deps/nushell/` (configured in `.mcp.json`).
- **Dependencies**: `config.nu` anchors `NU_SKILL_DIR`, configures `NU_LIB_DIRS`, and prepends vendored CLI binaries (`deps/cli/`) to `$env.PATH` (splitting string-formatted PATHs if needed).
- **Preloaded Services**: `nu-skills`, `nu-modules`, `par`, `jobs`, `dataspection`, `xq`, and `rg`.

## Output Handling & Token Economy
- **Inline Output Limit**: Outputs exceeding `$env.NU_MCP_OUTPUT_LIMIT` are truncated inline. A truncated result loses nothing: the full untruncated value is preserved in `$history`.
- **Cap Resolution**: The inline cap is resolved dynamically via `par cap` (checking `$env.NU_PAR.max_inline_bytes`, then `$env.NU_MCP_OUTPUT_LIMIT`, then system default).
- **Census Before Retrieval**: Use `dataspection`'s `shape` (`$history | shape each` or `$val | shape`) to inspect structure and byte size before requesting data.
- **Disclose Ladder**: Drill into stored values using `preview` (bounded leaf preview), `page` (bounded slice), or `read` (returns value if under cap, else stashes).
- **Stream Rules**: Always return values implicitly. Bare `print` in stdio MCP drops output; use `print -e` for diagnostic stderr logging.

> Stock bare `nu --mcp` launch without overlay: `nu-skills read appendix/mcp`.
