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

## The node_modules junction

Node resolves bare specifiers by walking up from the importing file looking for a `node_modules`
directory. It never looks inside `deps/`. So the payload here is reached through a directory
junction at the package root pointing at `deps/node_modules`.

`brewery/node/restore-node.ps1` creates it. To repair it by hand, from the package root:

```powershell
New-Item -ItemType Junction -Path node_modules -Target (Resolve-Path deps\node_modules)
```

A junction rather than a symlink, because it needs no elevation on Windows.

It is easy to lose — an `npm install` run anywhere in the package can replace it, leaving the
payload intact and unreachable. In para-agent that happened on 2026-08-19 and took the whole suite
red. Here the first assertion in [tests/typecheck.test.ts](../tests/typecheck.test.ts) checks for it
by name and says what to run, so the symptom reports itself instead of surfacing as
`ERR_MODULE_NOT_FOUND` on an unrelated import.
