# nushell-mcp — package notes for agents and contributors

nushell-mcp is a science-facility research project meant to be
stand-alone: a persistent, agent-facing Nushell console on top of
`nu --mcp`, and later a visitor MCP inside para-agent. Specs live in
`issues/nushell-mcp/` (roadmap, briefs, notes); this file is the
package-level rules.

## Layout

- `config.nu` — **single owner of the layer's layout.** Launchers pass
  `--config` (plus identity, when the host lands) and nothing else.
  Sets `NU_LIB_DIRS`, `NU_SKILL_DIR`, prepends `deps/cli` to PATH,
  preloads the modules.
- `modules/` — Nu-native modules loaded into the engine (`par`, `jobs`,
  `argx`, `nu-skills`, `nu-modules`, …). Contracts live in docstrings.
- `skills/nushell/` — the reference corpus (`SKILL.md` +
  `references/*.md`) agents read through `nu-skills`.
- `deps/` — vendored binaries, gitignored except `README.md`:
  `deps/cli` (rg, fd, jq, …) on PATH; `deps/nushell` the pinned engine
  (`.mcp.json` launches it). `brewery/` holds recipes.
- `tests/` — child `nu -n` suites, one file per brief
  (`nu -n mcp/nushell-mcp/tests/<brief>.nu`). A test prints a results
  table; a suite that cannot run must say so, never report green.
- `dev/` — module outtakes and inspiration; nothing here is loaded.
- `host/` — (planned) the thin TypeScript session host.

## Rules

1. **Documented, not encoded — and not landed until documented.**
   Verbs name the dispatch; shapes, error stances, and idioms live in
   the `main` docstring (`help <verb>`), in `skills/nushell/references/*.md`,
   and in the Claude-side adapter skill (`~/.claude/skills/nushell-mcp`).
   A landing updates all three **in the same change**. A module without
   its reference entry is not landed.
2. **Briefs are the spec.** Work from `issues/nushell-mcp/briefs/<x>.md`;
   amend in place, do not fork. Append a **Follow-up report** entry on
   landing: outcome, tests run, deviations.
3. **Closed shapes.** Receipts, envelopes, and rows have closed column
   sets. Native fields never leak. `bytes` has one definition
   (NUON-serialized UTF-8 length, computed once) — in `probe` once it
   lands; never re-derive it.
4. **Receipts before bodies.** One tool result carries at most one
   payload. Anything withheld names the call that retrieves it.
4a. **`ok` is universal; failure is data.** Every record the layer
   returns carries `ok: bool`. A verb that catches an error returns
   `ok: false` + `error` (short) — and `trace` where it captured one —
   instead of throwing. Know the two failure levels: an evaluate that
   *throws* leaves no `$history` entry (engine-level); a caught failure
   is a *successful* evaluate with a `history_index` (domain-level),
   legible only through its own `ok: false`. `shape each` lifts `ok`
   so `$history | shape each | where ok == false` finds them.
5. **Never cap a live pipeline** (`first N`, `head`) — slice `$history`
   or `jobs read` afterward. This is the MCP's own rule; the modules
   exist to make obeying it easy.
6. **Writes follow** `issues/nushell-mcp/briefs/write-conventions-v1.md`:
   state under `.nushell-mcp/`, scratch under `artifacts/nushell-mcp/`,
   never OS temp, ISO stamps on run dirs.
7. **Vocabulary.** *payload quarantine* (ours) vs *commit quarantine*
   (para-agent's) — always qualified. *rg module* vs *ripgrep* — the
   binary is in `deps/cli`, the module wraps it.
8. **No Nu semantics outside Nu.** The host (when it exists) is
   transport, journal, identity, policy. If a feature needs the host to
   understand a value, it is a Nu verb.
9. **Edit source with the editor, not scripts.** One file at a time,
   targeted edits; no bulk regex surgery.
