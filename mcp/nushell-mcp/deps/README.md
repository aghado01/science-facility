# deps — vendored binaries for the nushell-mcp layer

Gitignored (`deps/**`, this README excepted). A local cache, not a
distribution: populate by hand, pin by putting the file here.

## cli/

Prepended to `$env.PATH` by `config.nu` when present, so the MCP child
resolves these before anything on the host PATH. Wrappers (e.g. the
`rg` module) call `^name` and fail closed if the binary is missing —
they never hunt for it.

| binary | version (2026-08-21) | used by |
|---|---|---|
| `rg.exe` | ripgrep 14.1.1 | `rg` wrapper (rg-wrapper-v1) |
| `fd.exe` | 10.2.0 | — |
| `jq.exe` | 1.7.1 | — |
| `fzf.exe` | — | — |
| `jj.exe` | — | — |
| `delta.exe` | — | — |

## nushell/

`nu.exe` 0.114.1 + bundled plugins. Not on PATH; a pinned engine for
experiments (`deps/nushell/nu.exe --mcp --config ../../config.nu`) when
the host `nu` moves. Matches the host build today.

Refresh policy: bump the table when you replace a file. No auto-update.
