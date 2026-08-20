# brewery/

layout: `brewery/{tool}/**`

Recipes for everything mdnav depends on. A recipe says **how to obtain or build** a dependency.
It is tracked; what it produces is not.

Same three roles as para-agent's [brewery](../../para-agent/brewery/README.md), which states the
doctrine in full and is the canonical write-up — recipes here, disposable intermediates in
[build/](../build/README.md), payload in [deps/](../deps/README.md). This file records only what is
true of *this* package.

## The rules, in short

- **A recipe holds the recipe, never the payload.** Pins, lockfiles, restore scripts, checksums.
- **One dependency graph, pinned once.** `brewery/node/` is the only npm project in this package.
  No consumer gets its own `node_modules`.
- **Nothing is delivered from `build/`.** Stage there, verify, then release into `deps/`.
- **`deps/` is ignored in its entirety**, so every shelf must be reproducible from a recipe here.

## Recipes

| Shelf | Recipe | Payload | State |
|---|---|---|---|
| node | `brewery/node/` — `package.json`, `package-lock.json`, `restore-node.ps1` | `deps/node_modules` + root junction | **complete** |

There is one shelf and it has no gaps: pins, lock, and a restore script that runs end to end. That
is a deliberate departure from para-agent, whose node recipe has complete pins and no script, and
whose junction is made by hand. Starting empty is the only cheap moment to close that.

### node

`brewery/node/package.json` declares what mdnav chooses; `package-lock.json` records the resolved
graph. These are the *pins*. They are not the package manifest — that lives at the package root,
because Node reads `type` by walking up from each source file and never reaches this directory. Two
files, same name, different jobs; keep dependency edits here and manifest edits there.

`restore-node.ps1` stages the pins into the install prefix, runs `npm ci` with npm's cache pointed
at `build/node/npm-cache`, verifies the staged lock did not drift from the canonical one, and
junctions `node_modules` at the package root onto `deps/node_modules`. Run it after a clean clone,
and again if the junction is ever lost.

To move versions deliberately: edit `package.json` here, regenerate with
`npm install --package-lock-only` in this directory, review the lock diff, then re-run the script.

**The payload is platform-specific; the recipe is not.** TypeScript 7 is a native compiler shipped
as per-platform optional dependencies. The lock names all twenty; exactly one installs. A lock
committed on Windows restores correctly on Linux — do not prune the entries that look unused.

## What is pinned, and why so little

| Package | Version | Why |
|---|---|---|
| `typescript` | 7.0.2 | `tsc --noEmit` is the [typecheck gate](../tests/typecheck.test.ts). Node strips types; it does not check them, so without this the annotations are documentation that can lie |
| `@types/node` | 26.2.0 | the standard-library surface mdnav actually calls (`node:fs`, `node:path`, `node:test`) |

Both are dev-time only. **mdnav has no runtime dependencies and should acquire none casually** — the
engine is span arithmetic over bytes, and the doctrine (canon D5) is that doccer is a reference to
port from, never a dependency to call. A runtime dependency appearing here is a design change, not
a convenience, and belongs in the decisions register.
