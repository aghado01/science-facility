# skills-corpus v1 — console happy path, stock Nushell as a branch

**Status:** filed 2026-08-23 · **Home:**
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
    stock/                         # branch — Nushell as shipped
      mcp.md                       # bare nu --mcp, no overlay
      advanced.md                  # job spawn/recv/kill, complete, def extras
      posix.md                     # grep/find/where, complete, PATH-as-list
      inspect.md                   # builtin inspect passthrough
```

Both sides point at each other: every stock page opens with one line —
"Console equivalent: `nu-skills read <topic>`." — and every happy-path
page that supersedes a native workflow carries one short **Stock** line
naming the stock page. Steer, never ban: `^rg`, `job spawn`, and
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
  slashes on every platform** (`jobs`, `stock`, `stock/advanced`).
  Windows `ls`/`path parse` yield backslashes — normalize at
  derivation, and in `search` rows, or nested topics are unaddressable.
  Bare stems must not collide: `mcp` and `stock/mcp` are distinct
  topics everywhere, including search results.
- `read` tolerates a trailing `.md` (`stock/mcp.md` → `stock/mcp`).
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

### Steer map (stock → console → stock page)

| Agent reaches for | Happy path | Stock kept at |
|---|---|---|
| `job spawn` / `recv` / `kill` | `jobs spawn` / `collect` / `cancel` | `stock/advanced` |
| `par-each --threads` | `par` | `stock/advanced` |
| `^cmd \| complete` / `do { cmd } \| complete` | `xq`; `process capture` for wrappers only | `stock/advanced` |
| `grep` / `^rg` | `rg` (files); `where` / `find` (in-memory) | `stock/posix` |
| builtin `inspect` | `shape` | `stock/inspect` |
| `metadata` | `meta` / `meta stamp` | gotchas (already) |
| `first N` on a first-run pipeline | bind or store, then slice; `shape` / `read` / `jobs fetch` + `page` | `stock/posix` (head/tail on a **file**) |
| PATH prepend as if always a list | split-if-string then prepend, as `config.nu` does | `stock/posix` |
| bare `nu --mcp` | this package: pinned engine + `--config` | `stock/mcp` |
| huge `open` / `http get` dumped inline | `shape` then `read` / `jobs spawn` | file-io / data-analysis disclose lines |

In-memory `where` / `find` on a table is stock Nu **and** happy path;
it stays on the posix row next to "repo search is `rg`."

### Per-file

- **`SKILL.md`** — rewrite as console orientation: one paragraph
  (persistent `evaluate`, preloaded modules, `nu-skills`); the
  discipline as one list (implicit return; receipts before bodies;
  THE RULE as worded above; failure is data — `ok: false` in
  `$history`); how to open the tree (`list`, `list stock`, `read`,
  `search`). **No topic enumeration** — at most name the console core
  (`jobs`, `search`, `dataspection`). YAML `name: nushell-agent` stays
  until the rename.
- **`jobs.md`** — keep; fix name-map `parfeval` → `jobs spawn`
  (`--tag` optional; receipt carries allocated `spawn:<n>`); one Stock
  pointer to `stock/advanced`.
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
  discoverable live (`$env.NU_MCP_OUTPUT_LIMIT`). Scope: this rule
  covers deployment values; a module's own documented resolution
  chain (`par cap`'s fallback order on jobs.md) is spec, not a
  deployment fact, and stays. Point bare launch at `stock/mcp`.
- **`advanced.md`** — keep `def` and `try/catch`; jobs and `complete`
  blocks become one-liners to `jobs` / `xq` with the stock pointer.
- **`posix-cheatsheet.md`** — rows become console translations:
  `2>&1` → `xq` (not `complete`); `grep` → `rg` for files, `where` /
  `find` for columns; PATH prepend → split-if-string; head/tail-on-file
  points `stock/posix`. Footnote: stock equivalents in `stock/posix`.
- **`parity.md`** — PATH: "after `config.nu`, a list; if you assign a
  string, split on `char esep` first" (config.nu is the proof). The
  unconditional PATH-is-a-list claim moves to `stock/posix`.
- **`pipelines.md`** — keep `where`/`select`/`get`; **fix the
  examples**: `ls | select … | first 5` and `ls | sort-by size -r |
  first 10` become bind-then-slice. Drop "pipe to `to json` to save
  tokens" as the large-result answer; point `shape` / `read` / `jobs`.
  Persistence line says *this MCP session*, not para-agent pane turns.
- **`file-io.md`** / **`data-analysis.md`** — keep `open`/`save`/
  `http`/`polars`; one disclose line each (large structured value is
  `shape` then `read`, not a dump). No wrappers for these.

### Stock moves — move, then strip

Create `stock/` from current native slices. A move is not a verbatim
copy: **stock pages describe stock behavior, not stale advice, and
carry no overlay references.**

| Stock file | Source | Strip on move |
|---|---|---|
| `stock/mcp.md` | current `mcp.md` | the `$history \| shape each` census line (dataspection is overlay — it stays on the console side, sessions.md already has it); the `to json -c` transmission advice (retired, not relocated); the literal "default 10KB" (cap by meaning — the page says outputs over `$env.NU_MCP_OUTPUT_LIMIT` truncate, full value in `$history`, no number) |
| `stock/advanced.md` | current `job spawn` / `complete` / extra `def` material | — |
| `stock/posix.md` | current grep / `complete` / PATH-as-list / head-tail rows | — |
| `stock/inspect.md` | builtin `inspect` passthrough (from gotchas, expanded as needed) | — |

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
mcp/nushell-mcp/skills/nushell/references/stock/ # new branch (4 leaves)
mcp/nushell-mcp/skills/satellite/SKILL.md        # one routing line (below)
mcp/nushell-mcp/tests/skills-corpus-v1.nu        # suite (below)
issues/nushell-mcp/notes/vocabulary.md           # 4th local `kind` set
```

Implementation order: (1) `nu-skills` tree-aware + tests; (2) create
`stock/` by move-and-strip; (3) rewrite SKILL.md + primers, patch the
`jobs`/`search`/`dataspection` holes; (4) satellite line + deploy;
(5) vocabulary amendment.

## Tests (`nu -n mcp/nushell-mcp/tests/skills-corpus-v1.nu`)

Point `NU_SKILL_DIR` at the repo corpus. Derive expected counts from
the filesystem (`glob **/*.md` under `references/`) — never hard-code
a leaf count that breaks on the next page.

- `list`: top-level rows only; closed row shape; `kind` ∈
  `leaf | branch`; `stock` row has `kind: branch`, `n` == its child
  count; no duplicate topics.
- `list stock`: exactly the stock leaves, path-qualified topics.
- `list --all`: length == filesystem leaf count; every topic uses
  forward slashes.
- `read jobs`; `read stock/mcp`; `read stock/mcp.md` (tolerated);
  `read stock` → generated markdown table string naming each child;
  bare `nu-skills` → SKILL.md.
- `search`: a string that exists only in a stock page returns a
  `stock/…` forward-slash topic; `search "job spawn"` hits **both**
  `stock/advanced` and the steer line on `jobs`.
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

One `evaluate`: `nu-skills list` shows `stock` as a branch row with a
truthful child count. A second: `nu-skills search "job spawn"` returns
rows in both `jobs` (steer line) and `stock/advanced`. Grep the
package: **no hand-maintained topic enumeration survives** — not in
SKILL.md, not in either docstring, not in the satellite.

## Landing obligations (AGENTS.md rules 1–2)

- Docstrings, corpus pages, and the satellite updated **in the same
  change** as the module.
- Satellite (`skills/satellite/SKILL.md` — the single source of truth)
  gains one routing line: "`nu-skills list` is the console tree;
  `nu-skills list stock` is Nushell as shipped." Deploy verbatim to
  the client installs (`~/.claude`, `~/.grok`, `~/.codex`
  `skills/nushell-mcp`). It stays an orientation adapter — no corpus
  duplication.
- vocabulary.md: add the fourth local `kind` closed set
  (`nu-skills list` row, `leaf | branch`).
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
