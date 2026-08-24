# skills-corpus v1 — console happy path, stock Nushell in the appendix

**Status:** landed 2026-08-23 · **Home:**
`mcp/nushell-mcp/skills/nushell` (corpus) +
`mcp/nushell-mcp/modules/nu-skills` (tree-aware serving).
**Sources:** [grok sketch](../discussion/grok-nushell-skills-inventory.md),
[gemini notes](../discussion/gemini-nushell-skills-inventory-notes.md),
third-party review 2026-08-23 (folded in; rulings inline).
**Depends on:** nothing unlanded — corpus content + one module.
**No engine behavior change.** **Not this brief:** YAML/dir renames,
`gh` corpus page, fork rebuild (server instructions — see the deferred
tension below), satellite content beyond one routing line.

Treat this file as the v1 spec. Amend; do not fork.

## Problem

- The topic catalog is hand-maintained in three places — the SKILL.md
  Topics list, the `main` docstring, the `read` docstring — and drifts
  on every landing. Inventory should be the filesystem.
- Primer pages predate the console and teach what the product now
  supersedes: posix-cheatsheet answers `2>&1` with `do { cmd } |
  complete` where the console answer is `xq`; parity teaches
  PATH-is-always-a-list where `config.nu` itself handles the Windows
  string case; pipelines.md caps first-run `ls` pipelines against THE
  RULE, sells `to json -c` as the large-result answer, and names
  para-agent pane turns (decoupled per roadmap doctrine).
- Stock Nushell must stay findable and legitimate. It is the current
  language, not a deprecated one; the console supersedes *workflows*,
  not the language. Call it **stock** — never legacy, never standard.

## Shape

The corpus is a directory tree. Nested dirs are branches (dropdowns);
markdown files are leaves. `nu-skills list` is a listing of that tree,
not a second catalog.

```text
skills/nushell/                    # NU_SKILL_DIR; rename is later
  SKILL.md                         # console orientation, not a topic catalog
  references/
    jobs.md            search.md          dataspection.md
    sessions.md        mcp.md             gotchas.md
    pipelines.md       posix-cheatsheet.md parity.md
    file-io.md         data-analysis.md   advanced.md
    appendix/                      # branch — displaced slices, filed by origin (see membership)
      mcp.md                       # bare nu --mcp launch (from mcp.md)
      advanced.md                  # job spawn/recv/kill, complete (from advanced.md)
      posix-cheatsheet.md          # grep-on-files, head/tail-on-file rows
      parity.md                    # PATH-is-always-a-list, as shipped
      inspect.md                   # builtin inspect passthrough (no origin page — own leaf)
```

**Membership — relegation of conflicts, not a Nushell textbook.** A
slice moves to `appendix/` iff teaching it up front would conflict with
the console: either a **landed module supersedes the workflow**
(`job spawn` → `jobs`, `| complete` → `xq`, grep-shaped file search →
`rg`, builtin `inspect` → `shape`), or the **packaged deployment
changes the as-shipped behavior** (bare launch vs `--config`,
PATH-as-list vs split-if-string). The language itself — `def`,
`try/catch`, `where` / `select` / `get`, `open` / `save`,
interpolation, the idioms — is the console's language: happy path, no
stock counterpart. **The unit of relegation is the slice** — a row, a
block, a claim — never the document: the modules intervene at specific
points, and everything around those points stays where it is. No
happy-path page is relegated wholesale — the cheatsheet keeps most of
its rows, `advanced` keeps `def` and `try/catch`; `mcp.md` is the
degenerate case where the intervened slice happens to be nearly the
whole page. Membership is a **moving target** that tracks the
module surface: it grows only when a landing supersedes something
(that landing owes the relegation — see landing obligations), never
by taxonomizing bare Nushell in advance.

The branch is the corpus's **appendix**: back-matter the happy path
footnotes into, where relegated forms stay alive, citable, and
findable (search walks the whole tree) instead of dying. The branch
name is *position*; content identity lives one level down: **each
page is named for the origin document its slices were displaced
from** — `appendix/advanced` holds what left `advanced.md`, nothing
more — so the pairing is guessable in both directions and each
displaced slice lands beside the context it left. The name never
claims the origin document itself; the page opens by saying so
("Displaced from `advanced`; console: `nu-skills read jobs`").
Material with no single origin page gets its own small leaf
(`appendix/inspect`); a tiny page is honest, not a problem
(`appendix/parity` is one claim). **One native form has one appendix
home**: a form displaced from several origins (`| complete` left both
`advanced.md` and the cheatsheet) gets the home with the fullest
exposition (`appendix/advanced`), and every other footnote points
there — never a duplicate section. The
category word **stock** survives where it informs — in page titles
and in the happy-path footnote labels ("Stock `job spawn`: …") —
naming what today's occupants *are*: current Nushell as shipped, not
deprecated. A future relegation that is not stock material files the
same way, by origin stem, under its own label. An appendix is not an
attic: what the console retires outright is deleted, not relocated
(the `to json -c` strip below) — only forms that remain true and
occasionally needed earn a footnote and a page here.

Both sides point at each other: every appendix page opens with one
line naming what it was displaced from and the console page that
supersedes it, and every happy-path page that supersedes a native
workflow carries one short **Stock** footnote naming the form's one
appendix home. Steer, never ban: `^rg`, `job spawn`, and
`| complete` remain documented escape hatches.

## `nu-skills` v2 — tree-aware serving

| Verb | Contract |
|---|---|
| `nu-skills list` | one level of `references/`: leaf rows + branch rows |
| `nu-skills list <branch>` | children of `references/<branch>/` |
| `nu-skills list --all` | every leaf, path-qualified |
| `nu-skills read <topic>` | leaf → file content; branch → **generated** markdown table of its children (same columns as list, rendered as a string — preserves the `nothing -> string` contract); no hand-written branch index anywhere |
| `nu-skills search <regex>` | walks `references/**/*.md`; rows `{topic, line, content}` |
| `nu-skills status` | anchored root + **recursive** leaf count (today it counts only top level) |

Row shape (closed):

```
{topic: string, title: string, kind: string, n: int, size: filesize, path: string}
```

Rulings, each deliberate:

- **`kind` is `leaf | branch`** — not `page`. `page` is a portable
  dataspection verb with its own `kind` unit sense (`rows | lines |
  chars`); reusing the word as a row value invites exactly the
  collision vocabulary.md retired with `meta.kind → meta.verb`. The
  tree language of this brief is already leaves and branches. This is
  a **fourth local closed set** for `kind` — amend vocabulary.md's
  "Collisions kept" list on landing.
- **`n`**: direct child count for a branch; `0` for a leaf. Closed
  shapes do not have "unused" columns.
- **`size` stays** (dropped in the sketch): it is the selectivity
  signal token economy wants before a `read`. Leaf → file size;
  branch → sum of leaf sizes beneath it (what opening the whole
  dropdown would cost). It is named `size` as `ls` provides it —
  **never `bytes`**, which has one reserved NUON definition. `modified`
  is dropped.
- **`topic` is the path relative to `references/`, no `.md`, forward
  slashes on every platform** (`jobs`, `appendix`, `appendix/advanced`).
  Windows `ls`/`path parse` yield backslashes — normalize at
  derivation, and in `search` rows, or nested topics are unaddressable.
  Bare stems must not collide: `mcp` and `appendix/mcp` are distinct
  topics everywhere, including search results.
- `read` tolerates a trailing `.md` (`appendix/mcp.md` → `appendix/mcp`).
- Bare `nu-skills` / `read index` / `read root` still return SKILL.md.
- The unknown-topic error lists the `--all` inventory, not the
  top level.
- The `main` and `read` docstrings stop enumerating topics ("see
  `nu-skills list`") — they are the same drifting catalog this brief
  deletes from SKILL.md.
- Before the shape change, check `nu-skills list` consumers for
  old-column dependence (the satellite references no columns; nothing
  else is known to consume it).

## THE RULE — one wording everywhere

The served server instructions and AGENTS.md Rule 5 are the same rule:
**never cap a pipeline on its first run** — bounded or not (`ls **/*
| first 20` is in the served BAD list) — and **slicing a stored value
is always lawful** (`$x`, `$history.N`, `jobs fetch t | page`).

Corpus wording matches that boundary exactly. The gemini note's
"encouraged: `ls | sort-by size -r | first 5`" is **rejected** — that
is a first-run pipeline; the lawful idiom is
`let files = (ls | sort-by size -r)` then `$files | first 5`. The
sketch's steer-map phrase "live unbounded pipeline" is tightened to
"first-run pipeline" for the same reason. sessions.md's
`$history.0 | … | first 5` stays and says explicitly why it is legal.

## Corpus edits

### Steer map (stock → console → appendix page)

| Agent reaches for | Happy path | Appendix |
|---|---|---|
| `job spawn` / `recv` / `kill` | `jobs spawn` / `collect` / `cancel` | `appendix/advanced` |
| `par-each --threads` | `par` | `appendix/advanced` |
| `^cmd \| complete` / `do { cmd } \| complete` | `xq`; `process capture` for wrappers only | `appendix/advanced` |
| `grep` / `^rg` | `rg` (files); `where` / `find` (in-memory) | `appendix/posix-cheatsheet` |
| builtin `inspect` | `shape` | `appendix/inspect` |
| `metadata` | `meta` / `meta stamp` | gotchas (already) |
| `first N` on a first-run pipeline | bind or store, then slice; `shape` / `read` / `jobs fetch` + `page` | `appendix/posix-cheatsheet` (head/tail on a **file**) |
| PATH prepend as if always a list | split-if-string then prepend, as `config.nu` does | `appendix/parity` |
| bare `nu --mcp` | this package: pinned engine + `--config` | `appendix/mcp` |
| huge `open` / `http get` dumped inline | `shape` then `read` / `jobs spawn` | file-io / data-analysis disclose lines |

In-memory `where` / `find` on a table is stock Nu **and** happy path;
it stays on the posix row next to "repo search is `rg`."

### Per-file

- **`SKILL.md`** — rewrite as console orientation: one paragraph
  (persistent `evaluate`, preloaded modules, `nu-skills`); the
  discipline as one list (implicit return; receipts before bodies;
  THE RULE as worded above; failure is data — `ok: false` in
  `$history`); how to open the tree (`list`, `list appendix`, `read`,
  `search`). **No topic enumeration** — at most name the console core
  (`jobs`, `search`, `dataspection`). YAML `name: nushell-agent` stays
  until the rename.
- **`jobs.md`** — keep; fix name-map `parfeval` → `jobs spawn`
  (`--tag` optional; receipt carries allocated `spawn:<n>`); one Stock
  pointer to `appendix/advanced`; the `par cap` line names the resolution
  order without the literal terminal constant (cap by meaning).
- **`search.md`** — keep; add the three-context line (in-job inline;
  foreground worker over cap is `ok: false`, wrap in `jobs spawn`).
  `^rg` hatch stays; point `where`/`find` for in-memory.
- **`dataspection.md`** — keep; `read` three-context (owner stash,
  in-job full value, worker fail-closed).
- **`sessions.md`** — keep; state that slicing `$history` is lawful
  and why (stored value, not a first run).
- **`gotchas.md`** — keep whole, including the MCP-substrate section.
- **`mcp.md`** — rewrite as **this package's** launch: pinned
  `deps/nushell` engine, `--config config.nu` as the single layout
  owner, `NU_SKILL_DIR`, `deps/cli` PATH prepend (split-if-string).
  **Cap by meaning, not by number**: the corpus explains what
  `NU_MCP_OUTPUT_LIMIT` *is* — the inline truncation threshold; a
  truncated tool result loses nothing (`$history` holds the full
  value); the resolved inline cap is `par cap` — and never states a
  literal value. The number is deployment config (`.mcp.json`) and is
  discoverable live (`$env.NU_MCP_OUTPUT_LIMIT`). The same philosophy
  runs up the chain: jobs.md keeps documenting `par cap`'s resolution
  *order* (explicit `max_inline_bytes`, else the process's
  `NU_MCP_OUTPUT_LIMIT`, else a coded last-resort default) but drops
  the literal terminal constant. The constant itself is an
  implementation smell — should be a shipped `policy.json` default
  under the deployment override, or required-and-fail-closed — parked
  in the roadmap for a par amendment, not this brief. Point bare
  launch at `appendix/mcp`.
- **`advanced.md`** — keep `def` and `try/catch`; jobs and `complete`
  blocks become one-liners to `jobs` / `xq` with the Stock footnote.
- **`posix-cheatsheet.md`** — stays whole; only the intervened rows
  change. `2>&1` row → `xq`, footnote to `appendix/advanced`
  (`complete`'s one home); grep row → `rg` for files, `where` / `find`
  for columns, displaced file-grep forms to `appendix/posix-cheatsheet`;
  head/tail-on-file rows likewise; PATH-prepend row → split-if-string,
  footnote to `appendix/parity`. Every other row — env vars, subshell,
  path-exists, jq, try/ignore, exit code, raw read, sed, tee — is
  timeless parity and does not change.
- **`parity.md`** — PATH: "after `config.nu`, a list; if you assign a
  string, split on `char esep` first" (config.nu is the proof). The
  unconditional PATH-is-a-list claim moves to `appendix/parity`.
- **`pipelines.md`** — keep `where`/`select`/`get`; **fix the
  examples**: `ls | select … | first 5` and `ls | sort-by size -r |
  first 10` become bind-then-slice. Drop "pipe to `to json` to save
  tokens" as the large-result answer; point `shape` / `read` / `jobs`.
  Persistence line says *this MCP session*, not para-agent pane turns.
- **`file-io.md`** / **`data-analysis.md`** — keep `open`/`save`/
  `http`/`polars`; one disclose line each (large structured value is
  `shape` then `read`, not a dump). No wrappers for these.

### Appendix moves — move, then strip

Create `appendix/` from current native slices. A move is not a
verbatim copy: **appendix pages describe as-shipped behavior, not
stale advice, and carry no overlay references.**

| Appendix file | Source | Strip on move |
|---|---|---|
| `appendix/mcp.md` | current `mcp.md` | the `$history \| shape each` census line (dataspection is overlay — it stays on the console side, sessions.md already has it); the `to json -c` transmission advice (retired, not relocated); the literal "default 10KB" (cap by meaning — the page says outputs over `$env.NU_MCP_OUTPUT_LIMIT` truncate, full value in `$history`, no number) |
| `appendix/advanced.md` | current `job spawn` / `complete` blocks | the extra `def` material — nothing supersedes `def`; it stays in `advanced.md` (membership rule) |
| `appendix/posix-cheatsheet.md` | displaced cheatsheet rows: grep-on-files, head/tail-on-file | the `2>&1` / `complete` native form (one home: `appendix/advanced`); the PATH row's native form (home: `appendix/parity`) |
| `appendix/parity.md` | parity.md's unconditional PATH-is-a-list claim (+ the cheatsheet PATH row's native form) | — |
| `appendix/inspect.md` | builtin `inspect` passthrough (from gotchas, expanded as needed) | — |

Each opens with the console-equivalent line. No hand-written branch
catalog page — the directory is the branch.

## Server instructions — known tension, deferred

The pinned `deps/nushell/nu.exe` serves session-start MCP instructions
written before the overlay existed: they teach `cmd | complete` then
`$history.N` slicing as the external-command pattern and name no
`par`/`jobs`/`xq`/`rg`/`dataspection`. They agree with this brief on
THE RULE and on `$history`; they disagree on the externals default
(`complete` vs `xq`) — and they are the highest-authority text an
agent sees, before any corpus read.

This brief does not contradict them: `| complete` stays legitimate
stock, steered not banned. **Owed, deferred:** align the served
instructions with the console surface at the next fork rebuild
(brewery) — name `xq` / `rg` / `nu-skills` once preloaded. Until then
the tension is documented here and nowhere else.

## Tree

```
mcp/nushell-mcp/modules/nu-skills/nu-skills.nu   # tree-aware list/read/search/status
mcp/nushell-mcp/skills/nushell/SKILL.md          # orientation rewrite
mcp/nushell-mcp/skills/nushell/references/*.md   # per-file edits above
mcp/nushell-mcp/skills/nushell/references/appendix/ # new branch (5 leaves)
mcp/nushell-mcp/skills/satellite/SKILL.md        # one routing line (below)
mcp/nushell-mcp/tests/skills-corpus-v1.nu        # suite (below)
issues/nushell-mcp/notes/vocabulary.md           # 4th local `kind` set
```

Implementation order: (1) `nu-skills` tree-aware + tests; (2) create
`appendix/` by move-and-strip; (3) rewrite SKILL.md + primers, patch the
`jobs`/`search`/`dataspection` holes; (4) satellite line + deploy;
(5) vocabulary amendment.

## Tests (`nu -n mcp/nushell-mcp/tests/skills-corpus-v1.nu`)

Point `NU_SKILL_DIR` at the repo corpus. Derive expected counts from
the filesystem (`glob **/*.md` under `references/`) — never hard-code
a leaf count that breaks on the next page.

- `list`: top-level rows only; closed row shape; `kind` ∈
  `leaf | branch`; `appendix` row has `kind: branch`, `n` == its child
  count; no duplicate topics.
- `list appendix`: exactly the appendix leaves, path-qualified topics.
- `list --all`: length == filesystem leaf count; every topic uses
  forward slashes.
- `read jobs`; `read appendix/mcp`; `read appendix/mcp.md` (tolerated);
  `read appendix` → generated markdown table string naming each child;
  bare `nu-skills` → SKILL.md.
- `search`: a string that exists only in an appendix page returns an
  `appendix/…` forward-slash topic; `search "job spawn"` hits **both**
  `appendix/advanced` and the steer line on `jobs`.
- `status`: recursive leaf count.
- Unknown topic: error message lists the `--all` inventory.
- **Link integrity**: scan every corpus page for
  `nu-skills read <t>` / `nu-skills list <t>` mentions; each resolves
  against the tree. This mechanically enforces the bi-directional
  pointers.
- Smoke: `nu --config mcp/nushell-mcp/config.nu -c "nu-skills list | length"`
  loads clean.

The suite prints a results table; if it cannot run it says so — never
green by omission.

## Exit gate

One `evaluate`: `nu-skills list` shows `appendix` as a branch row with
a truthful child count. A second: `nu-skills search "job spawn"` returns
rows in both `jobs` (steer line) and `appendix/advanced`. Grep the
package: **no hand-maintained topic enumeration survives** — not in
SKILL.md, not in either docstring, not in the satellite.

## Landing obligations (AGENTS.md rules 1–2)

- Docstrings, corpus pages, and the satellite updated **in the same
  change** as the module.
- Satellite (`skills/satellite/SKILL.md` — the single source of truth)
  gains one routing line: "`nu-skills list` is the console tree;
  `nu-skills list appendix` holds the superseded forms, filed by
  origin topic." Deploy verbatim to
  the client installs (`~/.claude`, `~/.grok`, `~/.codex`
  `skills/nushell-mcp`). It stays an orientation adapter — no corpus
  duplication.
- vocabulary.md: add the fourth local `kind` closed set
  (`nu-skills list` row, `leaf | branch`).
- AGENTS.md Rule 1 gains the relegation clause: a landing that
  supersedes a native workflow (or changes as-shipped behavior)
  relegates the native slice to `appendix/` (filed by origin stem)
  with cross-pointers **in the same change**. Appendix membership
  grows only this way.
- Follow-up report appended here: outcome, tests run, deviations.

## Non-goals (v1)

- Renaming `nushell-agent` / `skills/nushell/` (later; `config.nu`
  anchoring makes it cheap).
- Topics for unexported core units or unlanded `gh`.
- Collapsing the satellite into the corpus, or fattening it beyond
  routing.
- Teaching `first N` on any first-run pipeline, anywhere.
- Pretending stock `job spawn` / `| complete` / `^rg` do not exist, or
  calling stock Nushell "legacy."
- Engine or fork changes; the server-instructions rebuild (deferred
  above).
- Any module change outside `nu-skills`; any cap-semantics change.

## Follow-up report (landed 2026-08-23)

- **Outcome**: Landed. Upgraded `nu-skills` to tree-aware discovery (`list`, `list <branch>`, `list --all`, generated markdown for `read <branch>`, and recursive search). Created `skills/nushell/references/appendix/` with 5 origin-filed slices (`mcp.md`, `advanced.md`, `posix-cheatsheet.md`, `parity.md`, `inspect.md`). Rewrote `SKILL.md` to orientation/discipline/discovery mechanics. Refined primers with bi-directional stock/console cross-pointers. Synchronized `skills/satellite/SKILL.md`, `vocabulary.md` (4th `kind` closed set), and `AGENTS.md` Rule 1 (relegation clause).
- **Tests run**: `nu -n mcp/nushell-mcp/tests/skills-corpus-v1.nu` (8/8 passed, including closed row shapes, dynamic child counts, generated tables, extension tolerance, normalized forward-slash search, and corpus link integrity). Full regression test suite battery passed 100% (88 tests total across `composition-v1`, `dataspection-v1`, `par-jobs-v1`, `rg-v1`, `xq-v1`). Smoke tested clean with `nu --config mcp/nushell-mcp/config.nu`.
- **Deviations**: None.

