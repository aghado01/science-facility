# nushell-mcp — package notes for agents and contributors

nushell-mcp is a science-facility research project meant to be
stand-alone: a persistent, agent-facing Nushell console on top of
`nu --mcp`, and later a visitor MCP inside para-agent. Specs live in
`issues/nushell-mcp/` (roadmap, briefs, notes, planning); this file is the
package-level rules.

## Layout

- `config.nu` — **single owner of the layer's layout.** Launchers pass
  `--config` (plus identity, when the host lands) and nothing else.
  Sets `NU_LIB_DIRS`, `NU_SKILL_DIR`, prepends `deps/cli` to PATH,
  preloads the modules. Order: `nu-skills`, `nu-modules`, `par`,
  `jobs`, `dataspection`, `xq`, `rg` — runtime services, access façade, then externals.
  Overlay preload is not DI into module bodies
  ([layering-v1](../../issues/nushell-mcp/.archive/briefs/layering-v1.md)).
- `modules/` — Nu-native modules. `modules/core/*.nu` are dependency
  file units (`census`, `meta`, `value`, `failure`, `outcome`, `execution`, `stream`, …); `par`/`jobs`
  import those, never `dataspection/mod.nu`. `dataspection` is the
  façade (`read` + `export use` of core). Overlay order is still
  `par`, `jobs`, `dataspection`, then `xq`, `rg`.
- `skills/nushell/` — the reference corpus (`SKILL.md` +
  `references/*.md`) agents read through `nu-skills`.
- `deps/` — vendored binaries, gitignored except `README.md`:
  `deps/cli` (rg, fd, jq, …) on PATH; `deps/nushell` the pinned engine
  (`.mcp.json` launches it). `brewery/` holds recipes.
- `tests/` — child `nu -n` suites, one file per brief
  (`nu -n mcp/nushell-mcp/tests/<brief>.nu`). Layering also requires a
  `nu --config config.nu` smoke (`read` over cap). A test prints a
  results table; a suite that cannot run must say so, never report green.
- `dev/` — module outtakes and inspiration; nothing here is loaded.
- `host/` — (planned) the thin TypeScript session host.

Specs: `issues/nushell-mcp/` — `roadmap.md` (sequence), `briefs/` (active
specs), `.archive/briefs/` (landed/superseded specs), `notes/`
(vocabulary, launch surface), `planning/decisions.md` (rulings),
`planning/ledger.md` (landed work). Briefs are the specs; do not restate
them in the decisions file.

## Duty cycle — landing a toolset change

Every addition or change to the toolset walks the same stations; skip
a station consciously, never silently.

1. **Brief** — file or amend in `issues/nushell-mcp/briefs/` (Rule 2);
   the brief is the spec and receives the follow-up report on landing.
2. **Code** — module + `main` docstring, standards per Rules 3–4c;
   field names checked against `notes/vocabulary.md` **before** coding —
   a new sense amends vocabulary, then sweeps (Rule 7).
3. **Config** — `config.nu` preload (order matters; single layout
   owner) and `.mcp.json` launcher env when the launch surface changes.
   Deployment values live in config; docs explain what a knob *means*,
   never its number.
4. **Corpus** — pointed guidance for the new capability; if it
   supersedes a native form, relegate that **slice** to
   `references/appendix/` (origin stem, one home per form) with
   dual-surface cross-pointers both ways (Rule 1).
5. **Satellite** — update `skills/satellite/SKILL.md` when routing
   changes, **and deploy verbatim** to the client installs
   (`~/.claude` / `~/.grok` / `~/.codex` `skills/nushell-mcp/`).
   The deploy is its own step — and the historically missed one.
6. **Tests** — suite per brief in `tests/`; corpus changes must pass
   the skills-corpus link-integrity gate (topics and hrefs); smoke
   `nu --config config.nu`.
7. **Paper trail** — follow-up report on the brief, ledger entry,
   roadmap status.
8. **When applicable** — vendored binary into `deps/cli` + brewery
   recipe; note drift owed to the served server instructions (aligned
   only at fork rebuild).

## Rules

1. **Documented, not encoded — and not landed until documented.**
   Verbs name the dispatch; shapes, error stances, and idioms live in
   the `main` docstring (`help <verb>`), in `skills/nushell/references/*.md`,
   and in the client adapters (`~/.claude/skills/nushell-mcp`,
   `~/.grok/skills/nushell-mcp`, `~/.codex/skills/nushell-mcp`).
   A landing updates the docstring, the corpus page, and those adapters
   **in the same change**. A landing that supersedes a native workflow
   (or changes as-shipped behavior) relegates the native slice to
   `skills/nushell/references/appendix/` (filed by origin stem) with
   cross-pointers in the same change. Appendix membership grows only
   this way. A module without its reference entry is not landed.
2. **Briefs are the spec.** Work from `issues/nushell-mcp/briefs/<x>.md`;
   amend in place, do not fork. Append a **Follow-up report** entry on
   landing: outcome, tests run, deviations.
3. **Closed shapes.** Receipts, envelopes, and rows have closed column
   sets. Native fields never leak. `bytes` has one definition
   (NUON-serialized UTF-8 length, computed once) — in `dataspection`
   once it lands; never re-derive it.
4. **Receipts before bodies.** One tool result carries at most one
   payload. Anything withheld names the call that retrieves it.
   `read` is the only verb that may decline, and when it declines it
   names the retrieval (`jobs fetch` + tag as NUON) — the disclosure ladder is
   `shape` (always fits) → `read` (if it fits) → `preview`/`page`
   (bounded). Over-cap in-hand `read` stashes through `jobs stash`; it is
   `--env`. `jobs read` is the same cap for an addressed payload; `jobs fetch`
   is the path that returns the stored body. Other dataspection commands
   stay pure. Cap is `par cap`.
4b. **Portable verbs.** A verb means one thing wherever it appears,
   and takes a noun domain when it addresses a stored or named thing:
   `jobs inspect`, `nu-modules read`, `meta stamp`. Commands acting on
   a value **in hand** are flat, because the value arrives by pipe
   rather than by address. `jobs inspect` is **not** `jobs read | shape`:
   inspect discloses nothing; jobs keeps its own receipt and calls
   `shape` on the stored payload internally.
4a. **`ok` is universal at outcome boundaries; failure is data.** Every
   operation result, receipt, envelope, and outcome row carries
   `ok: bool`. Arbitrary payload records, findings, census/budget
   records, and `meta` sub-records are not outcomes and do not acquire
   `ok` merely because they are records. A verb that catches an error
   returns `ok: false` + `error` (short) — and `trace` where it captured
   one — instead of throwing. Know the two failure levels: an evaluate
   that *throws* leaves no `$history` entry (engine-level); a caught
   failure is a *successful* evaluate with a `history_index`
   (domain-level), legible through its own `ok: false`. `shape each`
   lifts `ok` so `$history | shape each | where ok == false` finds them.
   Composition through `par`/`jobs` is specified in
   [composition-v1](../../issues/nushell-mcp/briefs/composition-v1.md).
4c. **The registry owns retrieval addresses.** Generated tags are
   allocated by `jobs` in the foreground mutation that stores the
   payload. A caller publishes `tag` only after storage succeeds; a
   background job or parallel worker never claims that a local
   `$env.JOBS` mutation persisted. Context behavior and stream
   measurement are specified in
   [composition-v1](../../issues/nushell-mcp/briefs/composition-v1.md).
5. **Never cap a live pipeline** (`first N`, `head`) — slice `$history`
   or `jobs fetch` afterward. This is the MCP's own rule; the modules
   exist to make obeying it easy.
6. **Writes follow** `issues/nushell-mcp/notes/write-conventions-v1.md`:
   state under `.nushell-mcp/`, scratch under `artifacts/nushell-mcp/`,
   never OS temp, ISO stamps on run dirs.
7. **Vocabulary.** Term senses live in
   `issues/nushell-mcp/notes/vocabulary.md` — read it before naming a
   field. The rule: quote a foreign name verbatim and attributed
   (`history_index` is nushell's tool-result field), never adopt it as
   our concept's name (ours is `index`). Never prefix a field with its
   container. Standing pairs: *payload quarantine* (ours) vs *commit
   quarantine* (para-agent's), always qualified; *rg module* vs
   *ripgrep* (the binary in `deps/cli`); `meta.verb` (producing
   command) vs `kind` (journal record / page unit / rg finding).
8. **Stay in scope.** This package is one MCP user's console
   experience, plus its own embedding surface (`notes/launch-surface.md`
   — what a host may vary). Integration design — how a host mediates
   between a bare shell and an MCP-wrapped console, what adapters that
   needs — belongs to that host, in `issues/para-agent/`. Do not design
   it here, and do not add a dependency on it.
9. **Inherit from the process, don't look up.** `$nu.current-exe` for
   the engine binary (never `^nu`), `path self` for layout (never cwd),
   `$nu.os-info` for the OS. A host varies only the audited launch
   surface in `issues/nushell-mcp/notes/launch-surface.md`; the layer
   names no host concept (no `PARA_NU_BIN`, no pane, no mux). Modules
   never hunt for a binary — `config.nu`'s `deps/cli` prepend is the
   one mechanism.
10. **No Nu semantics outside Nu.** The host (when it exists) is
   transport, journal, identity, policy. If a feature needs the host to
   understand a value, it is a Nu verb.
11. **Edit source with the editor, not scripts.** One file at a time,
   targeted edits; no bulk regex surgery.
