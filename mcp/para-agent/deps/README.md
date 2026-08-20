# deps/

Where para-agent's executable dependencies live — the fetched and compiled things it actually runs
against. Third-party and first-party alike, though today all three shelves are third-party: the
vendored nushell, the mux binary, and `node_modules`. A first-party executable built from
para-agent's own `src/` would land here the same way, by the same route.

**Everything here is ignored** (`deps/**`, with this file ignore-negated). A clean clone starts
without it. That is the point: every shelf must be reproducible from a recipe in
[brewery/](../brewery/README.md), and a shelf that is not is recorded there as a gap.

This file is the only tracked content under `deps/`.

## The rules

**Payload only.** No configuration, no recipes, no documentation beyond this file. Configuration
lives in `config/`; how a shelf is obtained lives in `brewery/{tool}/`. A directory that holds
both a payload and the knowledge of where the payload came from cannot be deleted safely, which
defeats the purpose.

**Laid out by how a thing is consumed, not by which recipe produced it.** Executables live together
under `deps/bin/{tool}/`; the node graph lives at `deps/node_modules/` because that is the name
Node's resolver looks for. `brewery/` and `build/` are the ones keyed by tool — a recipe names its
destination here rather than deriving it from its own directory name.

**Nothing is delivered here directly.** A recipe stages its work under `build/{tool}/`, verifies
the payload, and only then moves it in. Consumers point at `deps/`, never at `build/`.

**Deleting a shelf must cost only the time to re-run its recipe.** If deleting it loses something,
that something was in the wrong directory.

## Shelves

| Path | Contents | Recipe |
|---|---|---|
| `deps/node_modules/` | the locked dependency graph | `brewery/node/` — pins present, restore script pending |
| `deps/bin/nu/` | nushell `0.114.1` and its plugins | none — hand-deposited |
| `deps/bin/mux/` | `tmux 3.3.7` | none — hand-deposited |

## The node_modules junction

Node resolves bare specifiers — `@modelcontextprotocol/sdk`, `ajv`, `zod` — by walking up from the
importing file looking for a `node_modules` directory. It never looks inside `deps/`. So the
payload here is reached through a directory junction at the package root pointing at
`deps/node_modules`.

That junction is the one part of a working tree that cannot be derived from tracked files. It
belongs in the node restore recipe; until that exists it is created by hand, and a fresh clone
that skips it fails with `ERR_MODULE_NOT_FOUND` on the first import.
