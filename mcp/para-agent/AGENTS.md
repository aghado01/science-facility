Para-agent exists as science-facility research project but by design is meant to be stand-alone and repo-agnostic. 

## Project Layout notes

[brewery](./brewery) is where dependency pins and rehydration recipes are stored. git-tracked. 

[build](./build) is where *intermediate* build artifacts are written when something needs to be compiled or fetched and unpacked. `./build/**` is git-ignored with `./build/README.md` ignore-negated. 

[deps](./deps) houses all compiled dependencies for the para-agent MCP including all first-party and third-party packages such as the dedicated nushell binary, node_modules, and other things later. This is where pinned dependencies in brewery are deployed. `./deps/**` is git-ignored with `./deps/README.md` ignore-negated.

**brewery and build are keyed by tool; deps is keyed by how the thing is consumed.** One recipe per dependency at `brewery/{tool}`, its scratch at `build/{tool}`, but the payload lands wherever its consumer expects to find it — executables together under `deps/bin/{tool}`, and the node graph at `deps/node_modules` because that is the name Node's resolver looks for. A recipe therefore names its own destination rather than deriving it from its own directory name.

**Dependencies are pinned once for the whole package and consumers reach into the shared core.** One canonical npm project at `brewery/node` declares the union of everything para-agent needs from Node; nobody gets their own `{tool}/node_modules`. What shows up as a dependency for one use case is usually a dependency of something not built yet, so a consumer owns the driver or adapter it writes against a library and does not own the library itself. `tests/package-layout.test.js` fails on a second dependency declaration or a nested `node_modules`.

Two consequences worth knowing. `node_modules` at the package root is a directory junction onto `deps/node_modules`, because Node resolves bare specifiers by walking up from the importing file and will not look inside `deps/` — it is the one part of a working tree that cannot be derived from tracked files, and a clone without it fails on the first import. And `package.json` at the package root is the *manifest* only — `type`, `main`, `bin`, scripts — because Node reads those by walking up too; the dependency pins and lockfile are a rehydration recipe and live in `brewery/node/`. Same filename, two different jobs, deliberately separated.

[config](./config) is where config for various tools is stored and managed, with sub-directories per config's provenance. 

[resources](./resources) is where documentation assets related to dependencies and running para-agent live, with sub-directory scoping. 

[skills](./skills) is where para-agent mcp native skills are placed, organized by topic and will become increasingly integral to the runtime for planning and execution of tasks. 