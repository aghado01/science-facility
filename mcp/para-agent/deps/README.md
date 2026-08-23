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
| `deps/node_modules/` | the locked dependency graph | `brewery/node/` — complete (`restore-node.ps1`) |
| `deps/bin/nu/` | nushell `0.114.1` and its plugins | none — hand-deposited |
| `deps/bin/mux/` | `tmux 3.3.7` | none — hand-deposited |

## Direct consumption

Node packages are resolved directly from `deps/node_modules` via `src/deps.js` (`createRequire`). No root junction is required or created.

`brewery/node/restore-node.ps1` materializes this shelf from the pinned recipe. Run it after a clean clone if `deps/node_modules` is absent.

**A plugin is not a dependency.** A vendored MCP — `nushell_mcp`, possibly `mdnav_v2` later — is a
plugin: a thing with its own identity, lifecycle and registration, which happens in practice to be
depended upon. It does not belong on this shelf, and the one-graph rule below does not decide its
shape. Registration is the governing concern there, not pinning; see
[visitor-mcp-registration](../../../issues/para-agent/notes/visitor-mcp-registration.md).

The distinction is easy to lose because both end up as "something para-agent needs present at
runtime". The difference is ownership: a dependency is a library this package reaches into, and a
plugin is a separate thing this package admits.

**There is one graph and everything reaches into it.** `deps/node_modules` is the whole package's
Node dependency core, pinned once by `brewery/node/`. No consumer keeps its own copy under
`{tool}/node_modules`, because what one use case needs today is usually what a later one needs too,
and a second copy is how the two start to drift. A consumer owns the driver or adapter it writes
against a library; it does not own the library.
