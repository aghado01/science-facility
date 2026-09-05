# `mdnav` — modes over one engine: sessions, anchors, skills, run modes — design brief

**Status:** design-stage canon (D38 sense: amended, not forked; becomes executable briefs later).
**Filed:** 2026-09-05 (D50). **Companion:** [adjutant-brief.md](adjutant-brief.md), the first
specialized mode and the case that forced this document. **Evidence:**
[../planning/bug-inventory.md](../planning/bug-inventory.md) (B01–B31, probe battery),
[../discussions/v1-claude-on-codex-workdir-report.md](../discussions/v1-claude-on-codex-workdir-report.md),
the two-session tree at `D:\aipithicus\aipithicus-issues\Doccer\.doc-dive`, TeXdig's `DocOps.md`.
**One-line:** *doc-dive is one way of using the engine, not the engine; the server has to hold
several ways at once without any of them leaking into another.*

## Doctrine (what this brief adds to canon; everything in the design brief stands)

- **The engine has no mode.** Scanning, span algebra, claims, stores, the resolver, the ledgers
  are mode-agnostic. A mode is a *profile* laid over them: where its state lives, how its corpus
  is assembled, what an anchor means in it, which verbs it exposes, which skill it serves, what
  is tracked. Two modes never share code paths that branch on a mode name; they share an engine
  and differ in profile.
- **The session is the unit of identity.** Not the mount, not the run, not the process. Ids,
  widths, origins, cohorts, and the notebook belong to a session record; a run is a re-scan
  episode inside it. Every emission that names a document names it *within* a session, and when
  more than one session is open the session is in the frame.
- **Refuse ambiguity; never resolve it silently.** Two sessions open and no session named:
  refuse. Two documents with one basename: refuse and list them. A reference that is not an id,
  a recorded path, or a corpus-relative path: refuse. Doc-dive's tolerance for "whatever was
  mounted last" is the root of half the inventory.
- **Skills are mode doctrine, served by the mode.** `mdnav_skills` already serves doc-dive's
  discipline; each mode brings its own skill root, and the active session decides which one is
  the index.
- **Run mode is orthogonal to mode.** stdio MCP, CLI one-shot, embedded library (para-agent),
  and the framing-ablation configuration are ways of *running* the engine. Any mode runs under
  any of them.
- **A mode is a document model plus a workflow over a shared substrate.** *(added 2026-09-05,
  D51.)* The substrate — spans, frames, budgets, anchors, the resolver, sessions, per-author
  signed journals — is common. A mode contributes how its material is modelled (doc-dive: a
  corpus of spans; adjutant: registers of entries with mutation policies) and the workflow an
  agent runs over it (doc-dive: the telescope — profile, outline, read, cite; adjutant: orient,
  act, reconcile, hand off). What surfaces during mode design and turns out to be substrate is
  harvested into [../planning/substrate-register.md](../planning/substrate-register.md) and
  built **before** the mode.

## Problem

`mcp/mdnav` was written for one use: point at a fixed set of documents (papers, exports), read
them under a byte budget, keep a notebook of what was learned. Everything about it assumes one
corpus per process, artifacts anchored at the first target, and material that does not change
while it is being read. Practice has moved:

1. **Corpora are assembled by pointing, across turns and across agents.** The Doccer tree shows
   one investigation forked into two sessions because a second act of pointing had no verb to
   land in (B07), and codex and claude sharing one tree with colliding `N001`s and `D003`s.
2. **A new use has emerged: custodianship of a project's planning documents** — roadmap,
   decisions register, deferred register, bug inventory, briefs, chips — edited daily by
   prepending, cited by row id, curated by more than one agent. That use inverts doc-dive on
   locality (stable home), mutability (constant edits), and authorship (shared record). See
   [adjutant-brief.md](adjutant-brief.md).
3. **The server already hosts more than one surface** (the corpus verbs, the journal, the
   served skill, the framing ablation) with no structure separating them, so each addition has
   been wired through the same singleton and the same `workDir` argument that eight tools
   accept and ignore (B05).

Patching the singleton for adjutant would leave doc-dive with the same defects and leave the
third mode, whatever it is, to repeat the exercise.

## Shape

### 1. Mode profile

A mode is data the server holds, not a class hierarchy:

| Field | doc-dive | adjutant |
|---|---|---|
| `anchorDir` | `.doc-dive` | `.adjutant` |
| `sessionKind` | investigation: named or stamped, many per corpus, ephemeral by default | standing: one per project, named by the project, rehydrated on every start |
| `documentModel` | a corpus of spans; documents are what was pointed at | registers of entries, each with a question it answers, a mutation policy (`log` · `register` · `declaration`) and an entry lens |
| `corpusRule` | pointed: `discover(root \| paths)` seeds it; `extend` adds cohorts | declared: registers → paths, seeded from the root and its routing document, extended by cohort; references outward allowed |
| `anchorLens` | span anchors `Dnnn:Hnnnn@digest` (canon) | entry anchors `register:ID@digest` for registers; span anchors for prose |
| `workflow` | the telescope: profile → outline → read → cite; coverage as the audit | the turn: orient (`sync` briefing) → act (editor + `reserve`) → reconcile (`sync`, `validate`) → hand off (one signed entry) |
| `delivery` | material under a byte budget | state plane first (bounded projection, anchor per line); history per entry, backward, by verb |
| `verbs` | the corpus verbs + journal | corpus verbs + journal + `sync`, `entries`, `cite`, `history`, `reserve`, `validate` — no write verb |
| `skillRoot` | `skills/doc-dive` | `skills/adjutant` |
| `tracked` | nothing (`.doc-dive/**` ignored) | `session.json`, `journals/*.jsonl` tracked; `runs/**` ignored |
| `refuses` | a work dir `discover` could see (B09) | a `.doc-dive` run offered as a session; any write beyond `reserve` |

A third profile is a row in this table, not a branch in the engine. Candidates already visible:
a *comparative* profile (several sessions open read-only, every frame session-marked, no
notebook) and the *embedded* profile para-agent will want (no anchor dir; the host supplies the
store).

### 2. Session record (shared by every mode — this is the infra)

```
<anchorDir>/<session>/
  session.json        mode, name, created, widths, authors[{ name, pubkey }], cohorts[],
                      docs[{ id, origin, sha256, role?, policy?, cohort }]
  journals/<author>.jsonl        one per author, signed and chained (S-01, S-02)
  journals/<author>.NNNN.jsonl   archived segments behind a checkpoint (S-04)
  LATEST              the run in progress
  runs/<stamp>/       re-scan episodes: documents/*.index.json, reads.jsonl
```

*(Amended 2026-09-05, D51: the single `journal.jsonl` becomes per-author signed chains; see
§7 and the substrate register S-01–S-06.)*

- `session.json` is the inverse of `discover`: `attach` seeds `docCoord`/widths from the
  *recorded* ids, verifies each `sha256` against disk, loads `reads.jsonl` and the journal, and
  reports which documents moved. Ids are minted at session widths and **never re-rendered**;
  a corpus that outgrows its width is a new session or an explicit, recorded re-key (closes B04
  by construction, not by mapping).
- `extend` adds documents as a new cohort under the existing widths and appends to
  `session.json`; it never mints a new notebook (closes B07).
- `origin` is kind + locator (`file:`, later `url:`/`code:`), and `sha256` is the identity; a
  session is portable to the extent its origins resolve, and byte capture (`docs/<sha>.md`) is
  a per-mode policy decision, off for doc-dive, open for adjutant.
- Doc-dive adopts this record too. Its existing `.doc-dive/<stamp>/` layout becomes
  `.doc-dive/<session>/runs/<stamp>/`, which is the shape the Doccer tree already has by hand.

### 3. Sessions in the server

- Every tool takes `session` (a name) in place of `workDir`. With exactly one session open it
  defaults; with several it is required and its absence is refused; the journal's target is the
  session, so anchor validation and notebook selection are one selector (closes B03, B05).
- Several sessions may be open in one process, keyed by name; each owns its own
  `indices`/buffers/ledgers (closes B01, B02). `coverage()` with no `docIds` scopes to the
  session, never sums across.
- With more than one session open, every frame carries the session as a leading field
  (`doccer-renovation | D003 | H00 · 30e7`, the mirror of the skill marquee's *findable, not
  citable* rule): citable **and** unambiguous.
- Mode-specific verbs are registered at startup and *enabled* only while a session of that
  mode is open (the SDK's `RegisteredTool.enable/disable` with `listChanged`); where a client
  ignores `listChanged`, the verb refuses with the reason. Tool descriptions are context, so the
  common verbs keep their names and descriptions across modes — the framing-ablation argument
  (D30/D37) applies to the whole surface.

### 4. One resolver

A single `resolveRef(session, ref)` behind every tool: session id (width-tolerant on `D` as it
already is on `H`), corpus-relative path, absolute recorded path; basename only when unique,
else refuse with the candidates; never the server cwd (closes B13–B16, B18 by making `glob` a
real matcher or removing it).

### 5. Skills

`skills/<mode>/SKILL.md` plus references, served as today. The active session's mode is the
default `index`; `mdnav_skills({ topic: "adjutant" })` reaches the other. The doc-dive skill is
unchanged. The trigger skill stays cross-client glue.

### 6. Run modes (orthogonal)

| Run mode | Entry | Notes |
|---|---|---|
| stdio MCP | `src/index.ts` | the primary surface; one process, many sessions |
| CLI | `mdnav.mjs` | legacy oracle, frozen (D22/D47); not extended with modes |
| embedded | `createMdnavTools(engine, profile)` from a `server.ts` split out of `index.ts` | what para-agent vendors; the "server.ts brief" in the roadmap |
| ablation | `MDNAV_FRAME*` env | unchanged; sessions and modes must not leak into tool descriptions |

### 7. Collaboration mechanics (shared; added 2026-09-05, D51)

Raised by adjutant, general to every mode with a notebook. Detail and state in
[../planning/substrate-register.md](../planning/substrate-register.md) S-01–S-06; summarized:

- **One journal per author**, ids carrying the author (`codex:N012`); an agent appends only to
  its own file, so the write lock is needed only for `session.json`.
- **Entries are signed and chained.** `author`, an Ed25519 signature over the canonical entry,
  and the previous entry's hash. Keys in the user profile per author identity; public keys in
  `session.json`. `journal_read` reports verified / unsigned / bad per entry and per chain.
- **Maintenance never rewrites.** Editing another author's entry breaks its signature, which
  is the intended outcome; `retarget` and `synthesize` are ops in the maintainer's own journal
  that target entries elsewhere, and readers resolve anchors through the retarget chain.
- **Cursors and handoff.** Each author keeps a cursor per other journal; `sync` returns what
  moved since; one signed handoff entry per session is the only accretion that carries
  synthesis. Status is derived over the union of journals, never stored.
- **Checkpoints.** A signed `checkpoint` folds derived state; earlier entries segment out, still
  chained; readers load from the last checkpoint and page.
- **Ratification by signature.** The owner is an author; an owner-signed verdict is a ruling,
  an agent-signed one a proposal, and derived status says which.

## Non-goals

Everything in canon's non-goals. Added: no mode may change what a byte span *means*; row anchors
resolve *to* spans, they do not replace them. No mode makes semantic judgments about its
material (adjutant validates discipline, never content). The CLI is not taught modes. No
cross-session write: a session appends to its own notebook only; referencing another session
is an anchor with a session scope, not a shared file.

## Where this meets the roadmap

- **M2 (D39 store/hygiene layout)** *is* §2 of this brief seen from the engine side; the session
  record replaces the "investigation work-dir" wording there. Amend M2's deliverable list when
  this brief is promoted.
- **Brief 03 lenses (D44)** carry the row-anchor rule for adjutant as a lens, no scanner change.
- **Brief 04 REPL contract** gains `session` as a parameter of every verb and the session field
  in the frame.
- **The `server.ts` brief** gains the embedded profile and the `enable/disable` registration.
- **Invariant fixes first.** [bug-inventory.md §G](../planning/bug-inventory.md#g-disposition)
  lists the rows that are wrong in every mode and patchable now; they precede the session infra
  because the goldens M0 captures must not freeze them.

## Candidate exit gates (numbered into the master list when promoted)

- **A→B→A.** Two sessions in one process: identities, coverage, and journals isolated; the
  return trip reports the same coverage it left with.
- **Attach is exact.** A session rehydrated from `session.json` yields the recorded ids without
  re-minting; a moved file is reported as moved, not renumbered.
- **Extend is continuous.** A cohort added later takes the next ids at the same width; the
  notebook continues; coverage can be scoped to a cohort.
- **Ambiguity refuses.** Two sessions open and none named; two `decisions.md` and a basename
  ref; a ref that only resolves against the server cwd — each refuses with candidates or reason.
- **Modes do not cross.** An `.adjutant` session offered to doc-dive verbs, or a `.doc-dive`
  run offered to adjutant verbs, is refused by name.
- **Skill follows session.** `mdnav_skills()` with an adjutant session open lists adjutant as
  the index; with none open, doc-dive.
- **Descriptions are constant.** The tool list's descriptions are byte-identical across modes
  and sessions (the ablation invariant).
- **Chains verify.** An entry edited in place reports bad; a deleted entry breaks the chain
  behind it; a checkpointed journal verifies across its segments; an unsigned entry is marked,
  not hidden.
- **Maintenance is traceable.** After a `retarget`, the old anchor resolves through the chain
  and `history(entry)` shows who moved it and why.

## Open questions (decide before promotion)

1. **One process or one per project?** Multi-session in one process is the general answer, but
   a Claude Code `.mcp.json` is per repo and could register one adjutant server per project
   with the session fixed by argument. Both fit the profile model; the second is simpler to
   ship first.
2. **Byte capture policy** per mode (see adjutant brief §open questions).
3. **Session scope in journal anchors:** entry field only, or a scope prefix in the anchor when
   citing across sessions (`doccer-renovation:D003:H00@30e7`)? The frame work argues for the
   atom; the width discipline argues for the field.
4. **Author identity granularity and the unsigned policy** — substrate register Q-01, Q-02.

## Report

2026-09-05 — drafted from the bug inventory and the two-session evidence; no code changed.
Needs the design pass the owner asked for before any of it is executed: the profile table is
a proposal of *dimensions*, the third and fourth modes are placeholders, and §3's dynamic tool
enabling is unverified against the clients in use.
