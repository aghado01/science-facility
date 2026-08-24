# Agent-facing porcelain — the overlay track

**Status:** discussion, 2026-08-23 — design fleshed in-session; feeds
`nu-git-v1` and `nu-gh-v1` briefs (not yet filed). **Amends context
of:** [briefs/gh-v1.md](../briefs/gh-v1.md). **Related:**
[notes/module-prefixing.md](../notes/module-prefixing.md) (parked;
this track adds rationale there), [roadmap](../roadmap.md) step 6.

## The distinction

Human porcelain compresses keystrokes and eyeballs (aliases,
completions, pretty tables). Agent porcelain compresses
**disclosure**: what it costs to learn the shape of a payload before
deciding which slice to read. The overlay re-implements porcelain's
**output contract**, never its **input surface** — raw `git`/`gh`
stay the mutation and escape surface, zero-curation, per gh-v1.

The one genuinely new mechanism: **turn stream-shaped CLI output into
row-shaped data at capture time.** Everything downstream exists —
`where`/`group-by`, `rg` over captures, `par` predicates, the
disclosure ladder, quarantine, `meta stamp`. Each domain module is a
parser + a receipt + occasional derived views. Derived views are pure
functions over the captured payload — never re-run the underlying
command to page it.

Wrap plumbing, not porcelain: `status --porcelain=v2`,
`diff --numstat`, `log --format` with explicit terminators,
`gh --json`. Never parse pretty output (the `»¦«` delimiter trick in
`dev/modules-inspo` is the fragile version of what plumbing gives for
free).

## When a view earns its place

Raw CLI through `xq` is already the product unless at least one holds:

1. payload large or unbounded (diffs, run logs, histories)
2. native output text-shaped, not row-shaped (diff bodies, blame)
3. the useful unit is a sub-address (file, hunk, review thread, step)
4. a multi-call join agents repeat (PR state + checks + threads)

`gh repo view --json name` fails all four — no wrap. `git diff` on a
real branch passes all four.

## Read-side only (hard rule)

Curate queries, never mutations. Writes (`commit`, `push`,
`pr create`, branch deletion) stay verbatim CLI: curated write-verbs
hide argv from the journal and take on safety semantics this layer
must not own. Detection/query logic from mutating inspo tools ports
as pure queries returning tables; the mutation stays an explicit raw
command against that table.

## Naming

Two populations, structurally different:

- **Shadowing wrappers keep the external's exact name.** `gh` and
  `rg` work *because* they shadow the binary — transparency is the
  product. They can never carry a prefix; they are structurally
  exempt from the parked prefixing decision (rationale recorded in
  [notes/module-prefixing.md](../notes/module-prefixing.md)).
- **Overlay packages must not shadow** `git`/`gh`, so they need their
  own names. Working names: **`nu-git`**, **`nu-gh`** — read as
  "git, the data-first way", consistent with
  `nu-skills`/`nu-modules`, and compatible with either outcome of the
  parked decision. Preloaded un-splatted (`use nu-git`), so the agent
  surface is `nu-git diff`, `nu-gh pr` — the name itself advertises
  overlay vs raw at every call site.

## Packages

### `gh` — unchanged ([briefs/gh-v1.md](../briefs/gh-v1.md))

Identity substrate. v1 scope untouched; brief amended with overlay
positioning and one open point (identity combinator, below).

### `nu-git` v1 — first overlay brief (to file)

Local-only: no gh dependency, no auth, no vendored `gh.exe`. Consumes
`core/capture` + dataspection (the rg precedent), plus a new shared
core unit for patch rows. Candidate surface — grammar and field names
decided at brief time against AGENTS.md rule 4b and
[notes/vocabulary.md](../notes/vocabulary.md):

- `nu-git diff` — receipt first (`--numstat`/`--summary`: files ×
  adds/dels/renames/binary, near-free, no body generated); body on
  request → captured once, parsed to hunk rows, stashed over cap,
  paged by `file:hunk` address
- `nu-git status` — `--porcelain=v2 --branch` → one record: branch,
  ahead/behind, staged/unstaged/untracked counts, conflicts
- `nu-git log` — `--format` plumbing → closed-shape table; analysis
  is Nu (`where`, `group-by`), not flag combinatorics
- `nu-git range` — `git range-diff` → table (commit pairs, status:
  equal/reworded/modified/added/dropped)
- `nu-git branches` — branch table (age, merged-into-default,
  tracking) — the pure-query port of the branch-cleanup / branch-age
  inspo

### `nu-gh` v1 — after gh-v1 lands (to file)

Consumes the `gh` module (identity composes underneath — never raw
`^gh`) + the patch-rows core unit:

- `nu-gh pr` — the review receipt: one record joining title / state /
  checks rollup / review decision / files census / thread count;
  threads and per-file diff are opt-in pages
- `nu-gh pr diff` — patch rows, same shape as `nu-git diff`
- `nu-gh runs` / run receipt — jobs × steps × status × duration; step
  logs paged from quarantine (`gh run view --log` is the most
  context-hostile payload on the gh surface)
- issues: probably nothing in v1 — `gh issue list --json` through xq
  already behaves; discussions/notifications (GraphQL-only porcelain
  gaps in gh itself) are v2 candidates if the aipithicus
  project-management workflow materializes

### `core/patch.nu` — one hunk-row definition

Patch text → rows is shared by `nu-git diff` and `nu-gh pr diff`: one
closed row shape, defined once (the `bytes` precedent), specified in
nu-git-v1 and referenced by nu-gh-v1. Working shape: file-level rows
(path, status, adds, dels) and hunk-level rows (file, hunk index,
header, adds, dels, body) — final columns pass vocabulary.md.

## Dependency chain (wrappers-over-wrappers, justified)

capture → xq → gh → nu-gh, and capture (+ patch unit) → nu-git. The
chain is legitimate because each layer adds exactly one named concern
— capture: measurement; xq: terminal envelope + quarantine; gh:
identity; nu-git/nu-gh: domain views — and no layer re-implements a
lower one's semantics (the host thinness rule, applied inside Nu).
The alternative — teaching xq about diffs — smears domain knowledge
into a primitive, against layering-v1. Domain augmentation lives in
well-contained domain packages; primitives stay generic.

## Open points

- **Identity combinator.** nu-gh's parsing views want capture
  semantics, but identity injection lives in the gh module, which
  terminates in ordinary xq. If envelope + `jobs fetch` + parse
  proves clunky for big payloads, the shape is an exported combinator
  on gh (run a closure under the resolved identity env; token stays
  interior; hygiene rules unchanged) — never a token-returning
  export. Decide in nu-gh-v1; amend gh-v1.
- **Working names** `nu-git`/`nu-gh` pending the parked prefixing
  decision; nothing else here depends on the outcome.
- **Determinism.** A worktree diff receipt taken now and rows
  captured later can disagree (the tree moved). Inherent; the brief
  documents it rather than papering over (the gh-v1 "outside a repo"
  stance).

## Sequencing

nu-git-v1 first: local-only, highest-frequency payload, and it forces
the one new mechanism (parse-at-capture + sub-addressed paging over a
stash) that every later view reuses. nu-gh-v1 after gh-v1 lands.
Sibling of roadmap step 6 (query tools on the envelope): step 6 is
views over *envelope* results; this is views over *captured CLI
payloads*.

## Inspo disposition (`dev/modules-inspo` git, gitv2)

Mine: `git age` (branch table), the log-parse-to-table instinct
(rebuilt on `--format` plumbing), branch-cleanup's merged-detection
logic (as pure query). Discard: alias surfaces (keystroke economy is
a human concern; costs an agent legibility), completions (TTY
affordance — agent discovery is the corpus), interactive prompts
(destructive intent belongs in argv), mutation conveniences (`gpp!`,
cleanup's delete loop).
