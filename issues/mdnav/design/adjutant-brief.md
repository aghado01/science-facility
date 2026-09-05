# `mdnav` adjutant mode — a reconciliation protocol over a project's planning documents — design brief (r2)

**Status:** design-stage (D50, reshaped by D51). r1 is archived at
[.archive/adjutant-brief-r1-20260905.md](.archive/adjutant-brief-r1-20260905.md); it was a
reading protocol with different settings, and the use case is not a reading problem.
**Depends on:** [mdnav_v2_modes-brief.md](mdnav_v2_modes-brief.md) (substrate: sessions,
resolver, per-author signed journals, skills) and
[../planning/substrate-register.md](../planning/substrate-register.md) (what adjutant raised
that is general — built first). **Evidence:** TeXdig `DocOps.md`, the Doccer `.doc-dive` tree,
`issues/mdnav/planning/*` as live material, [../planning/bug-inventory.md](../planning/bug-inventory.md).
**One-line:** *doc-dive lets an agent traverse material it has never seen; adjutant lets an
agent act correctly on a project it has not looked at since last week.*

## Doctrine

- **Custodian, not author.** Adjutant knows the registers, their entries, their ids, their
  discipline, and what changed. It never decides what a decision should be: *validate
  discipline, never content*, the design brief's measurement rule applied to planning.
- **The ledgers are the record; git is the history.** The project's registers are where
  knowledge accumulates. Adjutant duplicates neither; it derives.
- **State first, history by verb.** The default delivery is a bounded projection of what is
  true and what is on the table, with an anchor on every line. Chronology is entered per
  entry, backward, only when a question needs it. Cognitive mass is a cost for agents as much
  as for files.
- **Append only where the sequence is the meaning.** Journals accrete, behind checkpoints.
  Registers grow by rulings. Declarations mutate and stay bounded. History for the last two is
  derived from entry-level diffs, never written into them.
- **Entry identity over byte position.** Planning documents are edited by prepending, so every
  offset and ordinal below an edit moves on every touch. The stable address is the entry id;
  spans are how an entry is delivered.
- **Writes stay with the editor.** Edits happen out of band in every agent's own tools.
  Adjutant reserves ids, observes, verifies, and attributes; it does not mediate prose.

## Document model

A project's docops is a set of **registers**, each declared with the question it answers, a
**mutation policy**, and an **entry lens** (substrate S-07, S-08). The declaration is data in
`session.json`; the known roles ship with defaults.

| Role | Question it answers | Policy | Entry lens | Id grammar | Status markers |
|---|---|---|---|---|---|
| roadmap | where are we | declaration | heading section | `M0`…, "After —" | `planned` · `in progress` · `done <date>` · `deferred` |
| decisions | what is settled | register | table row | `D\d+` | *(proposed …)*, *(amends Dn)*, struck |
| deferred | what is parked, what wakes it | register | table row | `RD-\d+` | struck = resolved, with pointer |
| bugs | what is broken | register | table row | `B\d+` | struck = closed, with ref |
| substrate | what generalizes | register | table row | `S-\d+`, `Q-\d+` | state column |
| briefs / chips | what is executable | register (file-per-entry) | file with `## Report` | `NN-*.md` | report present = complete |
| next-steps / TODO | what is queued | declaration | list item | none | checkbox / struck |
| routing | where things are | declaration | table row | none | — |
| journals | how we got here | log | jsonl entry | `author:N\d+` | derived (S-06) |

Three consequences of the policy column:

- `validate` checks per policy: chain intact for a log; ids monotonic and unique, struck rows
  still present, cross-references resolving, for a register; only well-formedness for a
  declaration.
- Refresh notices are worded per policy: an edited declaration is *change*, not *drift*; an
  edited register row is an *amendment* and names the row; an edited log entry is *bad*.
- A document declared without a lens degrades to a declaration: visible in the briefing, not
  entry-addressable. That is the cost of setup, stated.

**Entry anchors.** `<register>:<ID>@<digest>` — `decisions:D48@7c1e`, `bugs:B13@a0c2`,
`roadmap:M2@…`. The digest is of the entry text, so drift means *this entry was edited*. The
resolver returns a span for an entry anchor, so `read`, coverage, and the journal work
unchanged underneath. Prose (briefs, ideation, discussions) keeps canon span anchors.

## Two planes

**State plane.** The session holds a **snapshot**: for every register, every entry's id, digest,
and derived state (open · ruled · proposed by *author* · struck · amended since *cursor*). It is
bounded by the number of live entries, not by time, and it is replaced in place on every sync.
The **briefing** is assembled from the snapshot by asking each register its question, in the
order of the table above, with a bounded projection each:

```
roadmap    | M2 in progress | M0 done 2026-09-08 | moved since you: M0
decisions  | 51 rows | 49 ruled | 2 proposed awaiting ruling: D30 fable, D50 claude
deferred   | 3 parked | 1 trigger now met: RD-07
bugs       | 31 rows | 14 open in G1 | closed since you: B19 (c0ffee), B13 (…)
briefs     | 06-adjutant executable | 02 report added since you
validation | 1 unsigned entry in journals/codex | 0 malformed
```

Every line carries an entry anchor. Only the rows the agent's role must act on come in full:
entries proposed by others and awaiting its ruling, triggers now met, reservations it holds
that are unconfirmed. The briefing is budgeted the way reads are budgeted today, and nothing in
it is a replay: handoff entries older than the last checkpoint are not loaded, because the
snapshot supersedes them.

**History plane.** `history(entry)` assembles one entry's amendment chain, from the derived
changelog (S-10), journal citations, retargets (S-03), and git attribution, and stops. When
chronological analysis is the actual question — how D22 became D47, why M2 was re-scoped —
the derived changelog and the journals are ledger-shaped documents, and the doc-dive telescope
(profile, outline, read, coverage) applies to them unchanged. The original capability is kept
whole for the case that wants it and off the critical path for the case that does not.

## The turn protocol

The workflow is a turn between agents, not a reading plan.

1. **Orient.** `sync` — rescan the registers, diff entries against the snapshot, merge with
   what other authors' journals say since my cursors, return the briefing. The sync entry the
   agent's journal receives carries the diff it observed; the union of sync entries *is* the
   derived changelog (S-10).
2. **Act.** The agent edits registers and declarations with its own editor. Where it needs an
   id, `reserve(register)` hands out the next one, recorded with author and expiry in the
   session; two agents never both take `D52`.
3. **Reconcile.** A second `sync` confirms reservations were consumed or reports them lapsed,
   runs `validate`, and flags entries two authors touched between syncs — a row in the
   changefeed, not a lock error.
4. **Hand off.** One signed journal entry: what was done, what is proposed, what the next
   agent should look at. The only accretion that carries synthesis; the next briefing starts
   from it.

The same shape serves para-agent between supervisor and worker, which is why the mechanics
live in the substrate (S-05) and this brief only orders them.

## Collaboration mechanics consumed from the substrate

Not restated; see the modes brief §7 and the substrate register. Adjutant relies on: per-author
signed chained journals (S-01, S-02); `retarget`/`synthesize` as append-only maintenance
(S-03); checkpoints (S-04); cursors and the handoff (S-05); ratification by signature (S-06),
which is how "a disposition becomes a ruling only when the owner ratifies it" is enforced by
who signed rather than by anyone remembering the rule. Attribution of register edits comes
from **git blame per entry**; uncommitted changes show as *working tree, unattributed*.

## Verbs

| Verb | Does | Refuses |
|---|---|---|
| `attach(root)` | rehydrate the session from `session.json`; verify shas; report moved / missing; load journals from their last checkpoints | a root holding `.doc-dive` but no `.adjutant` — says which mode this is |
| `extend(paths \| root, role?)` | add registers or prose as a cohort under existing widths; infer role from the routing document or path, record the result | a path already in the session (reports its id) |
| `sync(since?)` | the briefing; records a sync entry carrying the observed diff; advances cursors | — |
| `entries(register, filter?)` | entries with derived state; counts; open items; by author / since cursor / state | an unknown register |
| `cite(anchor)` | resolve an entry or span anchor to current bytes and digest; say whether it drifted and through which retargets | — |
| `history(entry)` | the amendment chain for one entry, backward, with authors | — |
| `reserve(register)` | the next id, held for this author until consumed or expired | a register without an id grammar |
| `validate(register?)` | the per-policy discipline, plus: reservations unconfirmed, unsigned entries, references to struck rows, roadmap status moved without the queue reconciled | — |
| `checkpoint()` | substrate op (S-04); listed because the adjutant skill schedules it at phase close | — |

No `record`. r1's write verb is replaced by `reserve` plus confirmation at the next `sync`.

## Anchor, session, tracking

`.adjutant/` at the project's **docops root** — TeXdig's private issues space, or
`issues/<project>/` here. The directory *is* the session; one per project, named by it.
Rehydration is the default: there is no first run that mints.

```
.adjutant/
  session.json          authors[{name,pubkey}], registers[{role, path, policy, lens, cohort}],
                        docs[{id, origin, sha256, cohort}], reservations[], snapshot{register→{id→digest,state}}
  journals/<author>.jsonl (+ .NNNN segments)     tracked
  runs/<stamp>/         scan caches, reads       ignored
```

`session.json` and `journals/` are **tracked**: small text, shared by every agent and machine,
describing registers that are themselves tracked. `runs/**` is ignored. The repo-wide
`.doc-dive` ignore rule does not carry over; this brief owns that decision. The snapshot is
inside `session.json`, so a sync that changed nothing writes nothing.

## Skill

`skills/adjutant/SKILL.md`. Most of it exists as TeXdig `DocOps.md` §Planning Discipline: the
roadmap is authoritative for phase state; a deferral exists only as a register row with a
trigger and an evidence anchor; every phase begins by sweeping the register; resolved rows are
struck, never deleted; agent documents carry proposals, the owner ratifies. Added here: the
document model and its roles; the turn protocol as the session ritual (`sync` → act →
`sync` → hand off); how to cite an entry; that a ruling is read from its row before it is
acted on, however good the briefing looks; `checkpoint` at phase close. References: one per
register role, each a page.

## What is reused, what is new

| Reused unchanged | Reused with a new plan over it | New to adjutant |
|---|---|---|
| spans, frames, byte budgets, the resolver, `read`/`outline`/`coverage`/`locate` on prose and on the ledger-shaped history documents | anchors as agent memory (now entry anchors); the telescope (now the history plane); notices (now per-policy) | the document model (roles, policies, lenses as data); the snapshot and the briefing; `sync`/`entries`/`history`/`reserve`/`validate`; the `.adjutant` anchor and its tracking rule; the skill |

Everything in the "new" column that turned out to be general already moved to the substrate
register; if a later item does, it moves too.

## Non-goals

No judgment about planning content. No writes beyond `reserve`. No replacement of git as
history or of the owner's ratification. No cross-project session (one adjutant per project,
pending Q-06 and the group-axis question). No CLI surface. No inline Markdown parsing beyond
what the entry lenses declare.

## Open questions (owner's calls, tracked as Q-rows in the substrate register)

Q-01 identity granularity · Q-02 unsigned policy · Q-03 the decisions register as
rulings-in-force with derived history · Q-04 checkpoint segmentation · Q-05 the derived
ledger's blind spot · Q-06 one process or one per project. Adjutant-specific and not yet
listed there: whether a science-facility `issues/` root is many sessions or one with a
project axis, and whether role inference from the routing document is enough or a frontmatter
`role:` key is required.

## Sequencing

1. Invariant fixes — [bug-inventory.md §G1](../planning/bug-inventory.md#g-disposition),
   especially B19 frontmatter, B13–B17 resolution, B10 lock, B27 accounting.
2. Substrate register sweep — S-01…S-10 built as general engine/server work with their own
   tests; owner calls Q-01…Q-06 landed as decisions.
3. Session record, `attach`, `extend` (modes brief §2; M2's store layout).
4. Entry lenses and entry anchors (brief 03's lens machinery, S-07).
5. Snapshot, `sync`, briefing budgets, `entries`, `history`, `reserve`, `validate`.
6. `.adjutant` anchor, tracking rule, the skill; dogfood on `issues/mdnav/` with this brief's
   own registers as the fixture.

## Report

2026-09-05 — r2, rewritten from a reading protocol into a reconciliation protocol after the
discussion on cognitive mass, mutation policies, and cross-author signing. Not executable:
lens declarations are sketched against brief 03 and must be reconciled with it; the briefing
format above is illustrative; every substrate item it leans on is still `open`.
