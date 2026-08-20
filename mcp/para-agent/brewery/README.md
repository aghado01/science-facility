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
| node | `brewery/node/` — `package.json`, `package-lock.json` | `deps/node_modules` + root junction | pins present, **restore script not written** |
| nu | — | `deps/bin/nu/` | **no recipe** — hand-deposited |
| mux | — | `deps/bin/mux/` | **no recipe** — hand-deposited |

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

nu and mux were **hand-deposited** into the tree, not acquired by any recipe, so neither survives a
clean clone. This is the same category codex-scientiae records for `tectonic` and `pdfpig`: shelves
that predate the rule, kept honest by writing down the pin so it is not lost with the binary.

| Shelf | Deposited version | Upstream |
|---|---|---|
| nu | `0.114.1` | nushell GitHub releases, `nu-{version}-x86_64-pc-windows-msvc.zip` |
| mux | `tmux 3.3.7` | vendored psmux/tmux build |

Until `restore-nu.ps1` and `restore-mux.ps1` exist, the working-tree copies are the only ones —
do not delete them.

node is not in this table: its pins are present and complete, and only the restore script is
missing. Its payload is reproducible from `package-lock.json` today by hand.

## Not yet built

The conventions above describe the shape the tree already has. What is missing is machinery, not
layout:

- **No restore script for any shelf.** node has complete pins and no script; nu and mux have
  neither.
- **The root `node_modules` junction is made by hand.** It belongs in the node recipe as step 4.
  A clone without it fails on the first import with `ERR_MODULE_NOT_FOUND`.
- **`build/` is empty** — nothing routes there until a recipe exists to route.
