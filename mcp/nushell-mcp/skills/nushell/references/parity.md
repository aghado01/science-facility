# Nushell: Cross-Platform Parity & Pathing

## OS Abstraction & Native Utilities
Utilities behave identically across Windows, macOS, and Linux:
- File & Directory ops: `ls`, `cp`, `mv`, `mkdir`, `rm`, `find`, `pwd`
- Process & System ops: `ps`, `sys`, `open`

## Path Handling
- **Forward Slashes:** `/` is uniform across all OS environments (`"mcp/nushell-mcp/bin"`).
- **Path Helpers:**
  - Join paths: `path join` (e.g. `["foo" "bar"] | path join`)
  - Expand paths: `"~/file" | path expand`
  - Current script directory: `path self`
  - Path exists check: `("file.txt" | path exists)`

## Environment Variables (`$env`) & PATH
- Global environment lives in `$env`.
- In this console after `config.nu` executes, `$env.PATH` is a list. If assigning an external environment variable or raw host string, split on `char esep` first to prevent collapsing entries on Windows:
  ```nu
  let dirs = if ($raw | describe) =~ "list" { $raw } else { $raw | split row (char esep) }
  $env.PATH = ($dirs | prepend "/custom/bin" | uniq)
  ```

> Stock unconditional PATH-as-list: [`nu-skills read appendix/parity`](appendix/parity.md).
