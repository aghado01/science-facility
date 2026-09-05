# `mdnav` adjutant mode — a standing session over a project's planning documents — design brief

**Status:** design-stage (D50). **Depends on:**
[mdnav_v2_modes-brief.md](mdnav_v2_modes-brief.md) (sessions, profiles, resolver, skills — this
brief only says what is *particular* to adjutant). **Evidence:** TeXdig `DocOps.md` (routing
table + planning discipline), the Doccer `.doc-dive` tree, `issues/mdnav/planning/*` as a live
example of the material, [../planning/bug-inventory.md](../planning/bug-inventory.md) §F.
**One-line:** *doc-dive reads a corpus; adjutant keeps one.*

## Doctrine

- **Custodian, not author.** Adjutant knows the registers, their rows, their ids, their
  discipline, and what changed. It does not decide what a decision should be. The line the
  design brief draws for the engine — measure composition, never meaning — holds here as
  *validate discipline, never content*.
- **The ledgers are the record.** In doc-dive the notebook is where knowledge accumulates; in
  adjutant the project's own registers are, and the notebook shrinks to the custodian's log of
  what it did and saw. Git remains the history; adjutant never duplicates it.
- **Stable home, growing corpus.** The session lives at the project's docops root, once, by
  name. The corpus under it grows by pointing and by cohort; it is never re-numbered.
- **Row identity over byte position.** Planning documents are edited by prepending under a
  header, so byte spans and heading ordinals below any edit move on every touch. The stable
  address in a register is its row id. Adjutant cites rows; spans are how a row is *delivered*.

## Problem (what the material actually looks like)

The user's projects already share a docops shape, written down in TeXdig's `DocOps.md` and
reproduced in `issues/mdnav/`:

| Role | Example | Row identity | Edit pattern |
|---|---|---|---|
| roadmap | `planning/roadmap.md` | `M0`…`M6`, "After —" sections | status words change; sections amended |
| decisions register | `planning/decisions.md` | `D1`…`D50` | rows appended, ascending; amendments in place with a date |
| deferred register | `planning/deferred-register.md` | `RD-01`… | rows added; resolved rows struck through, never deleted |
| bug inventory | `planning/bug-inventory.md` | `B01`… | rows added; closed rows struck through |
| TODO / next steps | `TODO.md`, `*-next-steps.md` | none stable | reconciled at phase close |
| briefs / chips | `briefs/NN-*.md`, `chips/` | file + `## Report` | a completion report appended |
| routing | `DocOps.md`, `README.md` | table rows | rows added as layout settles |
| design record | `ideation/` + `.doc-dive/journal.jsonl` | `N001`… | append-only |

Three facts about it defeat doc-dive as built:

1. **Frontmatter everywhere** (B19): every one of these files opens with YAML; today its `---`
   lines count as thematic breaks and a YAML `# comment` outranks the title.
2. **Same basenames across projects and directories** (B13): `decisions.md`, `roadmap.md`,
   `README.md` recur in every project and in archives beside them.
3. **Constant mutation** (B24/B25 and the refresh path): a citation into `decisions.md` by
   `D005:H03@ab12` is stale within a day; with same-title dated headings the digest cannot
   even say so.

And two facts about how it is used: the corpus grows by pointing across many turns (Doccer:
a second act of pointing became a second session, B07), and more than one agent writes into it
(Doccer: codex and claude, colliding `N001`s; the journal lock exists for exactly this and
never expires, B10).

## Shape

### 1. Anchor and session

`.adjutant/` at the project's **docops root** — for TeXdig that is the private issues space,
for science-facility projects `issues/<project>/`. One session per project, named by the
project (`.adjutant/session.json`, not `.adjutant/<name>/`; the directory *is* the session).
Rehydration is the default: an adjutant server started with the root attaches; there is no
"first run" that mints.

`session.json` and `journal.jsonl` are **tracked**. They are small text, shared by every agent
and machine that touches the project, and the registers they describe are tracked. `runs/**`
(scan caches, reads) is ignored. This is the one place the repo-wide `.doc-dive` ignore rule
does not carry over; the adjutant brief owns that decision.

### 2. Corpus as a manifest of roles

The session record carries `docs[{ id, origin, sha256, role, cohort }]` where `role` is one of
the table above (open vocabulary; the known roles get the known row-id grammars). Seeding:

- `attach(root)` reads the root's routing document if one exists (`DocOps.md`, `README.md`
  table) and offers its rows as the first cohort with roles inferred from the table's labels;
  otherwise the root's Markdown tree with roles inferred from path (`planning/decisions.md` →
  decisions register) and confirmed by the reader.
- `extend(paths | root, role?)` adds a cohort. Material **outside** the root is allowed
  (TeXdig's routing table points at `../aipithicus-issues/TeXdig/…`); it is recorded by origin
  and sha, and adjutant says when it cannot be reached.
- Ids are minted once at session widths and never re-rendered. A project that outgrows its
  width gets an explicit `rekey` that rewrites `session.json` and the journal in one recorded
  operation, or a new session; nothing implicit.

### 3. The ledger lens (row anchors)

For documents with a ledger role, a lens declares the row grammar as data — the shape brief 03
already gives lenses:

```json
{ "name": "decisions-register", "role": "decisions",
  "row": { "kind": "table-row", "id": "^\\| (D\\d+) \\|" } }
{ "name": "bug-inventory", "role": "bugs",
  "row": { "kind": "table-row", "id": "^\\| (B\\d+) \\|" } }
{ "name": "deferred-register", "role": "deferred",
  "row": { "kind": "table-row", "id": "^\\| (RD-\\d+) \\|", "struck": "^\\| ~~" } }
```

A row anchor is `<register>:<ROWID>@<digest>` — `decisions:D48@7c1e` — where the digest is of
the **row text**, so drift means *this row was edited* (an amendment, exactly what a custodian
wants to notice), and ordinal shift is invisible because ordinals are not in the address.
Prose documents (briefs, ideation) keep canon span anchors. The resolver returns a span for a
row anchor, so `read`, coverage, and the journal work unchanged underneath.

### 4. Verbs particular to adjutant

| Verb | Does | Refuses |
|---|---|---|
| `attach(root)` | rehydrate the session; verify every sha; report moved/missing | a root holding `.doc-dive` but no `.adjutant` (say which mode this is) |
| `extend(paths, role?)` | add a cohort under existing widths | a path already in the session (report its id instead) |
| `status(since?)` | per document: sha changed / unchanged / missing; per register: rows added, rows struck, rows amended since the last `status` by this author or since a given entry | — |
| `ledger(register, filter?)` | rows with derived state (open / struck / amended-since); counts; open items | an unknown register |
| `cite(anchor)` | resolve a row or span anchor to its current bytes and digest; say whether it drifted | — |
| `validate(register?)` | the discipline: ids monotonic and unique, struck rows still present, cross-references (`D47`, `B13`, `M2`) resolve, frontmatter well-formed, "reconcile at phase close" flags when a roadmap status moved and the TODO did not | — |
| `record(register, entry)` | **the one write:** prepend one entry under the register's header (the user's ledger rule) with a minted id, under the journal lock; returns the id and the row digest | anything else — free-form edits belong to the agent's editor |

`status`'s notion of "since" is a per-author cursor kept in the notebook (`author` is a journal
field from this brief on), so codex and claude each get "what changed since *I* last looked".

### 5. Skill

`skills/adjutant/SKILL.md` — the discipline, largely already written as TeXdig `DocOps.md`
§Planning Discipline: the roadmap is authoritative for phase state; a deferral exists only as a
register row with a trigger and an evidence anchor; every phase begins by sweeping the register;
resolved rows are struck, never deleted; agent documents carry facts and proposals, a
disposition becomes a ruling only when the owner ratifies it. Plus, from this brief: document
roles and their row grammars, when each register is touched, how to cite a row, and the
`status → ledger → validate` opening ritual for a session. References: one per register role.

## Semantics that differ from doc-dive, stated flat

| | doc-dive | adjutant |
|---|---|---|
| anchor dir | `.doc-dive/<session>/` at the first target | `.adjutant/` at the docops root |
| session count | many per corpus | one per project |
| on start | mint a run | attach |
| corpus | pointed set | manifest of roles, grows by cohort, may reach outside the root |
| addresses | `Dnnn:Hnnnn@digest` | row anchors for ledgers, spans for prose |
| tracked | nothing | `session.json`, `journal.jsonl` |
| notebook | the record | the custodian's log; the registers are the record |
| writes | none | one verb, one shape, under lock |
| skill index | doc-dive | adjutant |

## Non-goals

No judgment about planning content. No free-form writes; no edits to briefs or prose. No
replacement of git history or of the owner's ratification step. No cross-project session: a
science-facility `issues/` root with many projects is many sessions, one per project, unless
a later decision says otherwise. No CLI surface.

## Open questions (the owner's calls)

1. **Write scope.** `record` as the single write, or read-only custodian plus `validate` after
   the agent edits? The brief proposes the single write because id minting under concurrency
   is the one thing the editor cannot do safely.
2. **Byte capture.** Capture source bytes into the session (`docs/<sha>.md`) so a session is
   portable, or rely on the tracked registers being present wherever the session is? For
   adjutant the material is tracked beside the session, so capture buys little; for outward
   references (TeXdig's private space) it may.
3. **Role declaration.** Infer from the routing table and paths (proposed), or require a
   `role:` key in frontmatter? Inference is enough to start and the manifest records the result.
4. **One project or a root of projects?** `issues/` here holds many projects; is that one
   adjutant per project (proposed) or one adjutant with project as a group axis?
5. **Where cursors live.** Per-author `status` cursors in the notebook (proposed) or in an
   ignored file, so the tracked journal does not accumulate "looked" entries.

## Sequencing (what has to exist first)

1. Invariant fixes, especially B19 frontmatter, B13/B14/B15 resolution, B10 lock expiry, B27
   accounting — [bug-inventory.md §G](../planning/bug-inventory.md#g-disposition).
2. Session record + `attach`/`extend` from the modes brief (M2's store layout).
3. Ledger lens + row anchors (brief 03's lens machinery).
4. Adjutant verbs and skill; the `.adjutant` anchor and its tracking rule.
5. Run it over `issues/mdnav/` itself as the first project, with this brief's own registers as
   the fixture.

## Report

2026-09-05 — drafted. Not executable yet: the row-grammar lens format is sketched against
brief 03 and must be reconciled with it; `status`'s cursor semantics and the write verb are
proposals awaiting the owner's answers above.
