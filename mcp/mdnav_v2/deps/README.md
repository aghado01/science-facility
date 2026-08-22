# deps/

The dependency payload — the fetched things mdnav actually runs against.

**Everything here is ignored** (`deps/**`, with this file ignore-negated). A clean clone starts
without it. That is the point: every shelf must be reproducible from a recipe in
[brewery/](../brewery/README.md). This file is the only tracked content under `deps/`.

**Payload only.** No configuration, no recipes, no documentation beyond this file. A directory
holding both a payload and the knowledge of where it came from cannot be deleted safely, which
defeats the purpose.

## Shelves

| Path | Contents | Recipe |
|---|---|---|
| `deps/node_modules/` | the locked dependency graph — `typescript`, `@types/node`, and the one matching `@typescript/typescript-{platform}` | `brewery/node/` — complete |

## Direct consumption
 
Node tools and test gates resolve from `deps/node_modules` directly (e.g. `node deps/node_modules/typescript/bin/tsc --noEmit` and `"typeRoots": ["./deps/node_modules/@types"]` in `tsconfig.json`). No root junction is required or created.
 
`brewery/node/restore-node.ps1` materializes this shelf from the pinned recipe. Run it after a clean clone if `deps/node_modules` is absent.
