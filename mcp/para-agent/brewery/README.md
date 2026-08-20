# brewery/

layout: `brewery/{package/tool/dependency}/**`

Recipes for everything para-agent depends on, first-party and third-party alike. A recipe says
**how to obtain or build** a dependency. It is tracked; what it produces is not.

Adapted from the `brewery` → `artifacts` → `packages` layout in `codex-scientiae`, localized to one
package. The three roles are the same; two of the names differ.

| Role | codex-scientiae | para-agent | Tracked? |
|---|---|---|---|
| Recipes — how to obtain a thing | `brewery/{module}/` | `brewery/{module}/` | **yes**, entirely |
| Regenerable working output | `artifacts/{module}/` | `build/{module}/` | no — `README.md` only |
| Payload consumers point at | `packages/{module}/` | `deps/{module}/` | no — `README.md` only |

## The rules

**A recipe holds the recipe, never the payload.** Pins, lockfiles, restore scripts, build scripts,
checksums. First-party source stays in `src/`; the recipe only says how to compile it.

**Working output goes to `build/`, never beside the source**, and every stage of one module's work
is scoped under that module — `build/{module}/...`. One module's entire working footprint is one
deletable directory. See [build/README.md](../build/README.md).

**Nothing is delivered from `build/`.** A payload other parts of para-agent actually consume is
released to `deps/{module}/`. The recipe owns that hand-off: stage under `build/{module}/`, verify
the expected payload is present, and only then move it into `deps/{module}/`. Never point a
consumer at a path under `build/`.

**`deps/` is ignored in its entirety**, so a clean clone starts without it. Every shelf there must
therefore be reproducible from a recipe here. A shelf with no recipe is a liability, recorded below
until it has one.

**The first path segment names a module, never an output kind.** `deps/nu/`, not `deps/bin/nu/` —
`bin` is a kind, and a kind at the first segment collides across every module that emits one.

## Recipes

| Shelf | Recipe | Payload | State |
|---|---|---|---|
| node | `brewery/node/` — `package.json`, `package-lock.json` | `deps/node/node_modules` | pins present, **restore script not written** |
| nu | — | `deps/nu/` | **no recipe** |
| mux | — | `deps/mux/` | **no recipe** |

### node

`brewery/node/package.json` declares the dependencies para-agent chooses; `package-lock.json`
records the resolved graph. These are the *pins*. They are not the package manifest — that lives at
the package root as `package.json`, because Node reads `type` and `main` by walking up from each
source file and never reaches this directory. The two files are different jobs with the same name;
keep dependency edits here and manifest edits there.

A restore recipe must do four things, the last of which has no codex-scientiae counterpart:

1. Stage copies of `package.json` and `package-lock.json` into the install prefix — `npm ci`
   requires its manifest and lock beside the target. Those copies are ignored; edit only the
   canonical ones here.
2. `npm ci` into the prefix, so routine restoration never rewrites the canonical lock. Point npm's
   download cache at `build/node/npm-cache/`.
3. Verify the staged lock has not drifted from the canonical lock, and fail if it has.
4. **Link `node_modules` at the package root to the payload.** Node resolves bare specifiers by
   walking up from the importing file looking for a `node_modules` directory, and it will not look
   inside `deps/`. A directory junction at the package root is what makes the deployed payload
   reachable, and it is the one step a fresh clone cannot derive from the files alone.

To move dependency versions deliberately: edit `package.json` here, regenerate the lock with npm,
review the lock diff, then run the restore recipe.

## Recipes not yet written

These shelves were fetched as finished binaries and vendored, so none survives a clean clone. They
are re-obtainable from upstream at the versions in use, recorded here so the pin is not lost with
the binary.

| Shelf | Vendored version | Upstream |
|---|---|---|
| nu | `0.114.1` | nushell GitHub releases, `nu-{version}-x86_64-pc-windows-msvc.zip` |
| mux | `tmux 3.3.7` | vendored psmux/tmux build; see `deps/bin/mux/README.md` |
| node (payload) | resolved from `package-lock.json` | npm registry |

Until `restore-nu.ps1` and `restore-mux.ps1` exist, the working-tree copies are the only ones —
do not delete them.

## Current deviations

This file states the target shape. Where the tree differs today:

- Payload is at `deps/bin/{nu,mux}` and `deps/node_modules`, grouped by kind rather than by module.
  Target is `deps/nu/`, `deps/mux/`, `deps/node/node_modules`. Moving it means repointing the
  binary hints in `src/mux.js` and the `PARA_*_BIN` entries in the repository `.mcp.json`.
- `node_modules` at the package root is currently a hand-made junction. It belongs in the node
  restore recipe.
- `build/` is empty and nothing routes to it yet.
