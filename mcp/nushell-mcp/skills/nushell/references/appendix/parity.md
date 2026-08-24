# Stock Nushell: As-Shipped PATH Handling

Displaced from `parity`; console equivalent: [`nu-skills read parity`](../parity.md).

In canonical Nushell as shipped, `$env.PATH` is specified to be unconditionally a structured list of strings rather than a delimited string.

## List Manipulation
- **Append**: `$env.PATH = ($env.PATH | append "/custom/bin")`
- **Prepend**: `$env.PATH = ($env.PATH | prepend "/custom/bin")`

## Context
Under certain MCP hosts and Windows launch environments, ambient `PATH` strings may arrive un-split. The console's `config.nu` splits string-based PATHs on `char esep` before prepending dependencies.
