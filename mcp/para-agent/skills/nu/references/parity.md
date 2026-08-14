# Nushell: Cross-Platform Parity & Pathing

## OS Abstraction & Native Utilities
Utilities behave identically across Windows, macOS, and Linux:
- File & Directory ops: `ls`, `cp`, `mv`, `mkdir`, `rm`, `find`, `pwd`
- Process & System ops: `ps`, `sys`, `open`

## Path Handling
- **Forward Slashes:** `/` is uniform across all OS environments (`"mcp/para-agent/bin"`).
- **Path Helpers:**
  - Join paths: `path join` (e.g. `["foo" "bar"] | path join`)
  - Expand paths: `"~/file" | path expand`
  - Current script directory: `path self`
  - Path exists check: `("file.txt" | path exists)`

## Environment Variables (`$env`)
- Global environment lives in `$env`.
- `$env.PATH` is a structured list, not a colon/semicolon delimited string.
  - Append to PATH: `$env.PATH = ($env.PATH | append "/custom/bin")`
  - Prepend to PATH: `$env.PATH = ($env.PATH | prepend "/custom/bin")`
