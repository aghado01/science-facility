# mdnav — substrate register

Things that surfaced while designing a *mode* but belong to the shared engine and server: the
general enhancements and patches to circle back on **before** building mode functionality
proper. Opened 2026-09-05 during adjutant design (D50/D51). Mutation policy: **register** —
rows added; a row is struck through with the commit or decision that landed it, never deleted.
Swept at the start of every mode build.

Columns: **origin** is the mode discussion that raised it; **applies to** says which existing
surface it changes; **state** is `open` · `in brief <name>` · `landed <ref>`.

| # | Item | Why it is general, not modal | Origin | Applies to | State |
|---|---|---|---|---|---|
| S-01 | **Per-author journals**: `journals/<author>.jsonl`, each agent appends only to its own; ids carry the author (`codex:N012`) | Codex and Claude already collided in one doc-dive journal (`N001` twice, Doccer tree); removes the write lock for the common case (B10) | adjutant, cross-author | journal store, `journal_*` verbs | open |
| S-02 | **Signed, chained entries**: `author`, Ed25519 signature over canonical JSON, `prev` hash per journal; keys in the user profile, public keys in `session.json`; verify states verified / unsigned / bad | Authorship as a verified fact rather than a claim; tamper-evidence is what makes "agents may maintain each other's journals" safe; works for doc-dive investigations shared across agents | adjutant, signing | journal store, `journal_read` | open |
| S-03 | **Maintenance is append-only by construction**: `retarget` (old anchor → new, reason) and `synthesize` (refs across authors) as ops in the maintainer's own journal; readers resolve through the retarget chain | Drift, re-keyed ids, renumbered rows become auditable events instead of silent fixes — the honest answer to B04/B24-class breakage in every mode | adjutant | journal ops, anchor resolution | open |
| S-04 | **Checkpoints and segments**: a signed `checkpoint` entry summarizes derived state; earlier entries move to `journals/<author>.NNNN.jsonl`, still chained; readers load from the last checkpoint and page | Accretion on disk must never become accretion in context; status is already derived, so a snapshot is legitimate | adjutant, mass | journal store, `journal_read` defaults | open |
| S-05 | **Sync cursors and the handoff entry**: per-author cursor per other journal; one signed entry per session stating what was done / proposed / to look at next; the next agent's briefing starts from it, never replays it | The turn protocol between agents is the same one para-agent wants between supervisor and worker | adjutant, cross-author | journal ops; para-agent trajectory | open |
| S-06 | **Ratification by signature**: an `adopt`/`reject` in the owner's journal is a ruling, in an agent's journal a proposal; derived status reads `adopted, ruled` vs `adopted by codex, unratified` | Enforces the DocOps rule ("a disposition becomes a ruling only when the owner ratifies") by who signed, in any mode with a notebook | adjutant, signing | status derivation | open |
| S-07 | **Entry lens**: a document is addressable as entries (table row, heading section, list item, dated entry, file-with-report) with an id and a digest of the entry text; spans underneath | Chat exports are entries too (turns); registers are the forcing case, transcripts the second | adjutant, structure | lenses (brief 03), resolver | open |
| S-08 | **Mutation policy as a document attribute**: `log` · `register` · `declaration`; drives what `validate` checks and how refresh notices are worded | Doc-dive corpora also contain living documents whose edits are not drift | adjutant, mass | index metadata, refresh path | open |
| S-09 | **State plane / history plane**: default delivery is a bounded projection of current state with an anchor per line; history is entered per entry, backward, by verb | Cognitive mass applies to agents; the budgeted-projection rule is the design brief's own doctrine applied to state rather than material | adjutant, mass | delivery contract (brief 04) | open |
| S-10 | **Derived changelog from snapshot diff**: the entry-level diff between syncs, carried in the sync entry, is the side ledger; never hand-written | Retired changelogs elsewhere for the same reason; doc-dive's "changed on disk" notice is the degenerate case | adjutant, mass | refresh notices, sync | open |
| S-11 | **Session record, `attach`, `extend`, ids never re-rendered** | Already canon in the modes brief §2; listed so the sweep sees it | modes | engine store (M2) | in brief modes §2 |
| S-12 | **One resolver, refuses ambiguity** | Already canon in the modes brief §4 | modes | every verb | in brief modes §4 |
| S-13 | **Invariant defects G1** | Wrong in every mode; goldens must not freeze them | inventory | see [bug-inventory.md §G](bug-inventory.md#g-disposition) | open |
| S-14 | **Tool descriptions constant across modes and sessions** | The framing-ablation invariant (D30/D37) applies to the whole surface | modes | `tools.ts` registration | in brief modes §3 |

## Owner calls pending (answers land as decisions, then rows above move)

| # | Question | Leaning recorded in discussion |
|---|---|---|
| Q-01 | Author identity granularity: product (`claude-code`, `codex`, `gemini`, `aipithicus`) with session id as an unsigned field, or per instance? | product |
| Q-02 | Are unsigned entries allowed? | allowed, marked, reported by `validate` when the session has declared authors |
| Q-03 | Does the decisions register become rulings-in-force (terse rows, `amends`/`supersedes` links, history derived) rather than an audit trail carried in the rows? | proposed; owner's to make |
| Q-04 | Is checkpoint segmentation acceptable for signed journals? | yes |
| Q-05 | Is the derived ledger's blind spot (a change made and reverted between syncs is visible only in git) acceptable? | yes |
| Q-06 | One process with many sessions, or one server per project fixed by argument? | per project first |

## Report

2026-09-05 — opened with fourteen rows and six pending calls, harvested from the adjutant
design discussion.
