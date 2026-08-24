# Corpus sketch — console happy path, stock Nushell as a branch

The in-engine corpus (`skills/nushell/`, served by `nu-skills`) is the
MCP product’s knowledge: new capabilities, the discipline they imply,
and enough general Nushell to operate. Canonical **stock** Nushell (the
language as shipped) is **not** deleted. It lives under a `stock/`
branch. Happy-path pages steer to the layer where it supersedes a
native workflow, and point at the stock page when the agent needs the
original concept.

Call it **stock**, not legacy or standard: it is current Nushell, not
deprecated, and it is not the console default.

Rename of the skill YAML/`skills/nushell-mcp/` is **later**. This sketch
is content + layout only. Client adapters stay thin.

## Layout

The corpus is a **directory tree**. `nu-skills list` is a listing of that
tree, not a hand-maintained topic index in `SKILL.md`. Nested dirs are
branches (dropdowns); markdown files are leaves.

```text
skills/nushell/                    # NU_SKILL_DIR; later rename
  SKILL.md                         # console orientation (not a topic catalog)
  references/
    jobs.md                        # par, jobs, xq, process capture
    search.md                      # rg wrapper
    dataspection.md
    sessions.md
    mcp.md                         # this package’s launch
    gotchas.md
    pipelines.md
    posix-cheatsheet.md
    parity.md
    file-io.md
    data-analysis.md
    advanced.md
    stock/                         # branch — Nushell as shipped
      mcp.md                       # nu --mcp with no overlay
      advanced.md                  # job spawn, complete, def extras
      posix.md                     # grep/find/where, complete, PATH prepend
      inspect.md                   # builtin inspect as passthrough
```

### `nu-skills list` — programmatic, nested, collapsed by default

Inventory is the filesystem. No YAML catalog.

```
nu-skills list                 # one level: files + dirs under references/
nu-skills list stock           # open that dropdown: children of stock/
nu-skills list --all           # every leaf, path-qualified (`stock/mcp`)
```

Default list row (closed dropdown):

```
{topic, title, kind: "page"|"branch", n: int, path}
```

- `kind: page` — a `.md` leaf; `n` is unused or 0; `nu-skills read <topic>`
- `kind: branch` — a directory; `n` is child count; `nu-skills list <topic>`
  expands it; `nu-skills read <topic>` is a generated contents table of
  that folder (title + first heading), not a second hand-written index
- `title` from the file’s first heading, or the directory name
- `topic` is the path relative to `references/`, no `.md` (`jobs`,
  `stock`, `stock/advanced`)

`--all` is the full programmatic inventory (every leaf). Search also
walks the whole tree so stock strings remain findable without expanding
dropdowns first.

Happy-path pages use a short **Stock** line, not a sermon:

> Console: `jobs spawn { … }`. Stock `job spawn` / `job recv`:
> `nu-skills read stock/advanced`.

Do not say the native command is forbidden. `^rg` and `job spawn` stay
escape hatches, documented as such.

## Product surface (what happy-path must own)

Preloaded (`config.nu`): `nu-skills`, `nu-modules`, `par`, `jobs`,
`dataspection`, `xq`, `rg`.

| Capability | Verbs | Corpus home |
|---|---|---|
| Discovery | `nu-skills list/read/search`, `nu-modules list/inspect/read/search` | index + this layout |
| Data plane | `par`, `par budget`, `par cap`, `par emit` | `jobs` |
| Handle plane | `jobs spawn/list/collect/inspect/read/fetch/stash/emit/cancel/status/policy` | `jobs` |
| Census / disclose | `shape`, `shape each`, `schema`, `spine`, `preview`, `page`, `read`, `meta stamp` | `dataspection` |
| Externals | `xq`; wrappers use `process capture` | `jobs` (xq section) |
| Search | `rg` (`^rg` hatch) | `search` |
| Session | `$history`, two failure levels, `--config` | `sessions`, `mcp` |

Not agent-facing (no new topics): `core/outcome`, `execution`, `stream`,
`failure`, `value`. Mentioned only where a page must name the rule
(`ok` vs `status`, registry owner, `stream bytes`).

Not landed: `gh`. No corpus page yet.

Vendored `argx` / `formats` / … : `nu-modules`, not the skill index.

## Steer map (stock → console → stock page)

| Agent reaches for | Happy path | Stock kept at |
|---|---|---|
| `job spawn` / `job recv` / `job kill` | `jobs spawn` / `collect` / `cancel` | `stock/advanced` |
| `par-each --threads` | `par` | `stock/advanced` (one line) |
| `^cmd \| complete` / `do { cmd } \| complete` | `xq`; `process capture` only for wrappers | `stock/advanced` |
| `grep` / `^rg` | `rg` | `stock/posix` (`where` / `find` for in-memory strings) |
| `inspect` (builtin) | `shape` | `stock/inspect` |
| `metadata` | `meta` / `meta stamp` | gotchas (already) |
| `first N` on a live unbounded pipeline | `shape` / `read` / `jobs fetch` then `page` | `stock/posix` (head/tail on a **file**) |
| PATH prepend as if always a list | split-or-list as `config.nu` | `stock/posix` |
| `nu --mcp` with no overlay | `nu --mcp --config <config.nu>` | `stock/mcp` |
| Huge `open` / `http get` dumped to the tool result | `shape` then `read` / `jobs spawn` | file-io / data-analysis stay; add a disclose line |

In-memory `where` / `find` on a table **is** still stock Nu and stays on
the happy-path posix row, next to “repo search is `rg`.”

## Per-file updates

### `SKILL.md` (index) — rewrite

YAML name can stay `nushell-agent` until the rename. Body becomes this
console’s orientation, **not** a second topic catalog (that is
`nu-skills list`):

- One paragraph: persistent `evaluate`, preloaded modules, `nu-skills`.
- Discipline in one list: implicit return; receipts before bodies;
  never cap a live unbounded pipeline; failure is data (`ok: false` in
  `$history`).
- How to open the tree: `nu-skills list` (top), `nu-skills list stock`
  (Nushell as shipped), `nu-skills read <topic>`, `nu-skills search <regex>`.
- Do not enumerate every page here; it will drift. At most name the
  console cluster (`jobs`, `search`, `dataspection`) as the product core.

### Console pages (keep, small holes only)

- **`jobs.md`** — already the composition/ownership/xq page. Fix name-map
  `jobs spawn --tag` → optional tag. Add one Stock pointer to
  `stock/advanced`. Worker wrap is already there.
- **`search.md`** — add the three-context line (in-job inline; foreground
  worker over-cap `ok: false`, wrap in `jobs spawn`). Stock `^rg` stays.
  Point posix `where`/`find` for in-list search.
- **`dataspection.md`** — `read` three-context (owner stash, in-job full
  value, worker fail-closed). Already owns `inspect` vs `shape`.
- **`sessions.md`** — keep. The `$history.0 \| first 5` example is
  **legal** (slice after store). Say so, vs banning `first` on live `rg`.
- **`gotchas.md`** — keep MCP substrate section. Interpolation / `where`
  stay here (they are still true). Builtin `inspect` already steers.

### Happy-path primers (steer, don’t empty)

- **`mcp.md`** — replace unconfigured launch with this package: pinned
  `deps/nushell`, `--config config.nu`, `NU_SKILL_DIR`, PATH split then
  `deps/cli`. Point `nu --mcp` with no overlay to `stock/mcp`.
- **`advanced.md`** — keep `def` and `try/catch`. Replace the jobs and
  `complete` blocks with one-liners to `jobs` / `xq`. Full stock
  `job spawn` / `complete` → `stock/advanced`.
- **`posix-cheatsheet.md`** — table becomes console translations:
  `2>&1` → `xq` (not `complete`); `grep` → `rg` for files, `where` for
  columns; PATH prepend → split-if-string then prepend. Extra column or
  footnote: stock equivalents in `stock/posix`.
- **`parity.md`** — PATH: “after `config.nu`, a list; if you assign a
  string, split on `char esep` first.” Stock “PATH is always a list”
  → `stock/posix`.
- **`pipelines.md`** — keep `where`/`select`/`get`. Drop “pipe to
  `to json` to save tokens” as the large-result answer; point
  `shape` / `read` / `jobs`. `first`/`last` only on already-bound
  values or `$history`. Persistence line says this MCP session, not
  “para-agent pane turns.”
- **`file-io.md`** — keep `open`/`save`. One line: large structured
  `open` is `shape` then `read`, not dump.
- **`data-analysis.md`** — keep `http` / `polars` / `query db`. Same
  disclose line. No wrapper for these.

### Nested `stock/` (the dropdown)

No hand-written catalog page. The directory **is** the branch;
`nu-skills list` shows it; `nu-skills list stock` / `read stock` are
the open state.

Move, don’t rewrite from scratch:

| Stock file | Source |
|---|---|
| `stock/mcp.md` | current `mcp.md` (`nu --mcp` with no overlay, 10KB limit) |
| `stock/advanced.md` | current `job spawn` / `complete` / extra `def` |
| `stock/posix.md` | current grep/`complete`/PATH-as-list rows |
| `stock/inspect.md` | builtin `inspect` behavior (from gotchas, expanded if needed) |

Each stock page starts with one line: “Console equivalent: `nu-skills
read <topic>`.” So the two sides point at each other.

## What we will not do

- Collapse client adapters into this corpus (they stay routing).
- Rename `nushell-agent` / `skills/nushell/` in this pass.
- Add topics for unexported core units or unlanded `gh`.
- Teach `first N` on live `rg`/`xq` anywhere.
- Pretend stock `job spawn` does not exist.
- Call stock Nushell “legacy.”

## Implementation order (when executing)

1. `nu-skills list` / `read` / `search` become tree-aware: one-level
   list, `list <branch>` expands, `list --all` every leaf, `read` of a
   directory is a generated child table, search walks `**/*.md`.
2. Create `stock/` by moving current native slices (no separate catalog
   page).
3. Rewrite index + primers to steer; patch holes on `jobs` / `search` /
   `dataspection`. Index must not re-list topics.
4. Adapter one-liner: `nu-skills list` is the console tree; `nu-skills
   list stock` is Nushell as shipped.
5. `nu-skills search "job spawn"` still hits `stock/advanced` and the
   steer line on `jobs`.

No engine behavior change. Pointed commit: `nushell-mcp: split corpus happy-path from stock Nu`.
