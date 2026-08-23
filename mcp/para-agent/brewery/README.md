# brewery/

layout: `brewery/{package/tool/dependency}/**`

Recipes for everything para-agent depends on, first-party and third-party alike. A recipe says
**how to obtain or build** a dependency. It is tracked; what it produces is not.

Adapted from the `brewery` → `artifacts` → `packages` layout in `codex-scientiae`, localized to one
package. The three roles are the same; two of the names differ.

| Role | codex-scientiae | para-agent | Tracked? |
|---|---|---|---|
| Recipes for everything that ends up as a dependency | `brewery/{module}/` | `brewery/{tool}/` | **yes**, entirely |
| Disposable intermediates on the way from pins and recipes to payload | `artifacts/{module}/` | `build/{tool}/` | no — `README.md` only |
| Where executable dependencies live | `packages/{module}/` | `deps/bin/{tool}/`, `deps/node_modules/` | no — `README.md` only |

The pattern transfers directly; only two names change. codex-scientiae exercises it harder because
it mixes languages and mixes **first-party executables built from its own `src/`** (`doccer`,
`hdbscan` — C#) with **third-party toolchains** (`node`, `uv`). para-agent is the simpler case: no
first-party executables today, and its three shelves are all third-party. Nothing about the shape
changes if that stops being true — a first-party tool built from para-agent's `src/` would take the
same path, recipe in `brewery/{tool}/`, intermediates in `build/{tool}/`, payload released into
`deps/` under whatever shape its consumer expects.

## The rules

**A recipe holds the recipe, never the payload.** Pins, lockfiles, restore scripts, build scripts,
checksums. First-party source stays in `src/`; the recipe only says how to compile it.

**A dependency graph is pinned once for the whole package, and consumers reach into it.** There is
one canonical npm project — `brewery/node/` — and its graph is the union of everything para-agent
needs from the Node side. Nobody gets their own `{tool}/node_modules`.

The reason is not tidiness. What arrives as a dependency for one use case is usually a dependency
of some later thing that has not been built yet, and a second declaration is how one graph quietly
becomes two that drift. A consumer owns its own driver or adapter code — the thin layer that uses a
library — and does not own the library. Adding a dependency means adding it to the one recipe, not
starting a project beside your code.

Enforced by `tests/package-layout.test.js`, which fails on a second dependency declaration anywhere
in the package and on any nested `node_modules`.

**Working output goes to `build/`, never beside the source**, and every stage of one tool's work is
scoped under that tool — `build/{tool}/...`. One tool's entire working footprint is one deletable
directory. See [build/README.md](../build/README.md).

**Nothing is delivered from `build/`.** A payload other parts of para-agent actually consume is
released into `deps/`. The recipe owns that hand-off: stage under `build/{tool}/`, verify the
expected payload is present, and only then move it to its declared destination. Never point a
consumer at a path under `build/`.

**`deps/` is ignored in its entirety**, so a clean clone starts without it. Every shelf there must
therefore be reproducible from a recipe here. A shelf with no recipe is a liability, recorded below
until it has one.

**brewery and build are keyed by tool; `deps/` is keyed by how the thing is consumed.** One recipe
per dependency at `brewery/{tool}/`, its scratch at `build/{tool}/` — but the payload lands where
its consumer expects to find it, not where its recipe would have filed it. Executables go together
under `deps/bin/{tool}/`; the node graph goes to `deps/node_modules/` because that is the name
Node's resolver looks for. A recipe therefore **names its own destination** rather than deriving it
from its own directory name.

This is where para-agent departs from codex-scientiae on purpose. There, `packages/{module}/`
mirrors `brewery/{module}/` one-for-one and `Directory.Build.props` derives output paths from the
project's directory name. para-agent has few enough shelves that the mirror buys nothing, and its
consumers — `PARA_NU_BIN`, `PARA_MUX_BIN`, Node's own resolver — care about where a thing *is*, not
which recipe produced it.

## Recipes

| Shelf | Recipe | Payload | State |
|---|---|---|---|
| node | `brewery/node/` — `package.json`, `package-lock.json`, `restore-node.ps1` | `deps/node_modules` | **complete** |
| nu | — | `deps/bin/nu/` | **no recipe** — hand-deposited |
| mux | — | `deps/bin/mux/` | **no recipe** — hand-deposited |

### node

`brewery/node/package.json` declares the dependencies para-agent chooses; `package-lock.json`
records the resolved graph. These are the *pins*. They are not the package manifest — that lives at
the package root as `package.json`, because Node reads `type` and `main` by walking up from each
source file and never reaches this directory. The two files are different jobs with the same name;
keep dependency edits here and manifest edits there.

`restore-node.ps1` executes the node recipe:

1. Stage copies of `package.json` and `package-lock.json` into the install prefix — `npm ci`
   requires its manifest and lock beside the target. Those copies are ignored; edit only the
   canonical ones here.
2. `npm ci` into the prefix, with npm's download cache pointed at `build/node/npm-cache/` so routine
   restoration never rewrites the canonical lock.
3. Verify the staged lock has not drifted from the canonical lock, and fail if it has.

Third-party dependencies are resolved directly from `deps/node_modules` via `src/deps.js` without
requiring root junctions.

To move dependency versions deliberately: edit `package.json` here, regenerate the lock with npm,
review the lock diff, then run the restore recipe.

## Recipes not yet written

nu and mux were **hand-deposited** into the tree, not acquired by any recipe, so neither survives a
clean clone. This is the same category codex-scientiae records for `tectonic` and `pdfpig`: shelves
that predate the rule, kept honest by writing down the pin so it is not lost with the binary.

| Shelf | Deposited version | Upstream |
|---|---|---|
| nu | `0.114.1` | nushell GitHub releases, `nu-{version}-x86_64-pc-windows-msvc.zip` |
| mux | `tmux 3.3.7` | vendored psmux/tmux build |

Until `restore-nu.ps1` and `restore-mux.ps1` exist, the working-tree copies are the only ones —
do not delete them.

## Not yet built

The conventions above describe the shape the tree already has. What is missing is machinery, not
layout:

- **No restore script for nu and mux.** node has complete pins and a working restore script; nu and
  mux have neither.
- **`build/` is empty** — nothing routes there until a recipe exists to route.
