# build/

Working output, scoped by tool: `build/{tool}/...`. One tool's entire working footprint is one
deletable directory.

**Everything here is ignored** (`build/**`, with this file ignore-negated). Nothing is ever
delivered from here — a recipe stages its work under `build/{tool}/`, verifies the payload, and
only then moves it into [deps/](../deps/README.md). Consumers point at `deps/`, never at a path
under `build/`.

Deleting anything here must cost only the time to re-run the recipe that produced it. If deleting
it loses something, that something was in the wrong directory.

## Stages

| Path | Contents | Produced by |
|---|---|---|
| `build/node/npm-cache/` | npm's download cache, kept out of the user profile so restoration is self-contained | `brewery/node/restore-node.ps1` |
