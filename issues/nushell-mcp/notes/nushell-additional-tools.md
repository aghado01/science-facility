# Additional tools — ideation capture (2026-08-21)

**Status:** captured conversation, not a spec. Superseded where it
conflicts with filed briefs: `xq` → [xq-v1](../briefs/xq-v1.md);
`hist`/`shape`/`peek`/`cap` → [inspect-v1](../briefs/inspect-v1.md)
(there is no `hist` module — `$history | shape each` is the idiom);
`console` → [session-host-v1](../briefs/session-host-v1.md).
Still unclaimed: `jobs spill`. Terminology here predates
[vocabulary.md](vocabulary.md).

---

Let me ground this in what the layer already exposes before suggesting what's missing.

Here's my read, anchored on the layer as it stands (nu-skills/nu-modules for discovery, par/jobs for dispatch and quarantine, `$history` as the native store, and — I notice — `.mcp.json` now launching the pinned `deps/nushell/nu.exe`). I'll rank by how much each closes a real gap in the console vision rather than list everything plausible.

**1. `xq` — execute-and-quarantine, the primitive rg is actually a special case of.** Every external the agent runs (`cargo build`, `pytest`, `git log`, `fd`, `jq`) has the same flood problem rg has, and the same answer: `complete`, census, inline under cap, stash over cap. `{ok, exit_code, elapsed, stdout_bytes, stderr_bytes, stdout?, stderr?, tag?}` — streams kept separate, stash by tag when over `max_inline_bytes`. Build this first and the rg wrapper becomes `xq` + JSON-event parse + spine, and fd/jq/jj need no wrappers at all. It also composes with `jobs spawn { xq cargo build }` for non-blocking. This is the highest-leverage thing missing, and the rg brief's text mode is really `xq` trying to get out.

**2. `hist` — census over `$history`.** `$history` is the store the whole MCP leans on, yet it has no receipt surface: the only way to see what's in it is to dump it. `hist list` → receipt table (index, type, length, bytes, first ~80 chars); `hist shape N`; `hist page N --size 50 --at 200`. Plus a generic `shape` for any value (type, length, columns with types, bytes, null counts) — `jobs inspect` does this for registry rows; agents want it for everything. "Skeletal metadata first" is currently true only for jobs payloads; this makes it true for the console's main store.

**3. `console` — one orientation call.** An agent arriving in a persistent session wants to know where it is: cores/ceiling/inflight, history depth, registry rows, output cap, deps versions, engine version, loaded modules. Today that's five calls. One record, receipts only, lets the skill say "run `console` first."

**4. `peek` — line windows with numbers.** The rg drill idiom `open $file | lines | slice 118..126` works but is ceremony and loses line numbers. `peek file.nu 120 -C 5` → `{file, total_lines, bytes, lines: [{n, text}]}`. Generic; mdnav_v2 owns the markdown-structural version.

**5. `cap` — export the inline-cap resolver.** `par emit` already resolves `max_inline_bytes` vs `NU_MCP_OUTPUT_LIMIT` privately. Exporting `cap` (and `fits $value`) lets any wrapper or an agent check "will this flood?" before returning. Tiny.

**6. `jobs spill <tag> --to <path>` — explicit export to disk.** The vision says "big payloads written to file"; the registry is in-engine only. An explicit spill (nuon/json/csv) hands a result to another tool or agent. This is the first write the layer would do, so it's where the persistence doctrine bites: caller names the path, no generic filenames, nothing ambient.

What I'd _not_ build: per-tool wrappers for fd/jq/jj/delta (covered by `xq`), a notes/plan store (agents bring their own), anything that auto-promotes or guesses. The sprawl test for any new verb: is it a discipline primitive, or a consumer of one?

My recommendation is to brief `xq` and `hist`+`shape` first — `xq` because rg should be built on it rather than before it, and `hist` because it's the cheapest fix to the largest blind spot.
