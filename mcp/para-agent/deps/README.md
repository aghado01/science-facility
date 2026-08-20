# deps/

Materialized dependency payload — the compiled and fetched things para-agent actually runs
against. First-party and third-party alike: the vendored nushell, the mux binary, `node_modules`.

**Everything here is ignored** (`deps/**`, with this file ignore-negated). A clean clone starts
without it. That is the point: every shelf must be reproducible from a recipe in
[brewery/](../brewery/README.md), and a shelf that is not is recorded there as a gap.

This file is the only tracked content under `deps/`.

## The rules

**Payload only.** No configuration, no recipes, no documentation beyond this file. Configuration
lives in `config/`; how a shelf is obtained lives in `brewery/{module}/`. A directory that holds
both a payload and the knowledge of where the payload came from cannot be deleted safely, which
defeats the purpose.

**One shelf per module, module first.** `deps/nu/`, `deps/mux/`, `deps/node/node_modules`. The
first path segment names the module, never an output kind — `deps/bin/` groups by kind and
collides across every module that ships an executable.

**Nothing is delivered here directly.** A recipe stages its work under `build/{module}/`, verifies
the payload, and only then moves it in. Consumers point at `deps/`, never at `build/`.

**Deleting a shelf must cost only the time to re-run its recipe.** If deleting it loses something,
that something was in the wrong directory.

## Shelves

| Shelf | Contents | Recipe |
|---|---|---|
| node | `node_modules` — the locked dependency graph | `brewery/node/` (pins present, restore script pending) |
| nu | vendored nushell `0.114.1` and its plugins | none yet |
| mux | vendored `tmux 3.3.7` | none yet |

## The node_modules junction

Node resolves bare specifiers — `@modelcontextprotocol/sdk`, `ajv`, `zod` — by walking up from the
importing file looking for a `node_modules` directory. It never looks inside `deps/`. So the
payload here is reached through a directory junction at the package root pointing at
`deps/node/node_modules`.

That junction is the one part of a working tree that cannot be derived from tracked files. It
belongs in the node restore recipe; until that exists it is created by hand, and a fresh clone
that skips it fails with `ERR_MODULE_NOT_FOUND` on the first import.

## Current state

The tree presently uses `deps/node_modules` and `deps/bin/{nu,mux}` — flat, grouped by kind. The
module-scoped shape above is the target; see the deviations section in
[brewery/README.md](../brewery/README.md).
