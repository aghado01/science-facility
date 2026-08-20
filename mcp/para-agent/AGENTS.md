Para-agent exists as science-facility research project but by design is meant to be stand-alone and repo-agnostic. 

## Project Layout notes

[brewery](./brewery) is where dependency pins and rehydration recipes are stored. git-tracked. 

[build](./build) is where *intermediate* build artifacts are written when something needs to be compiled or fetched and unpacked. `./build/**` is git-ignored with `./build/README.md` ignore-negated. 

[deps](./deps) is not yet implemented but it or something like it will house all compiled dependencies for the para-agent MCP including all first-party and third-party packages such as the dedicated nushell binary, node_modules, and other things later. This is where pinned dependencies in brewery are intended to be deployed once consolidation happens `./deps/**` is git-ignored with `./deps/README.md` ignore-negated. 

[config](./config) is where config for various tools is stored and managed, with sub-directories per config's provenance. 

[resources](./resources) is where documentation assets related to dependencies and running para-agent live, with sub-directory scoping. 

[skills](./skills) is where para-agent mcp native skills are placed, organized by topic and will become increasingly integral to the runtime for planning and execution of tasks. 