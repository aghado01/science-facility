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
| S-07 | **Entry lens**: a document is addressable as entries (table row, heading section, list item, dated entry, file-with-report) with an id and a digest of the entry text; spans underneath | Chat exports are entries too (turns); registers are the forcing case, transcripts the second | adjutant, structure | lenses (brief 03), resolver | in brief 03 as the pattern basis — needs the id capture (S-17) |
| S-08 | **Mutation policy as a document attribute**: `log` · `register` · `declaration`; drives what `validate` checks and how refresh notices are worded | Doc-dive corpora also contain living documents whose edits are not drift | adjutant, mass | index metadata, refresh path | open |
| S-09 | **State plane / history plane**: default delivery is a bounded projection of current state with an anchor per line; history is entered per entry, backward, by verb | Cognitive mass applies to agents; the budgeted-projection rule is the design brief's own doctrine applied to state rather than material | adjutant, mass | delivery contract (brief 04) | in brief 04 — `status` (coverage + residue as a record), paged tables, and the over-budget *plan* are the mechanisms; the briefing is a `status` variant |
| S-10 | **Derived changelog from snapshot diff**: the entry-level diff between syncs, carried in the sync entry, is the side ledger; never hand-written | Retired changelogs elsewhere for the same reason; doc-dive's "changed on disk" notice is the degenerate case | adjutant, mass | refresh notices, sync | open |
| S-11 | **Session record, `attach`, `extend`, ids never re-rendered** | Already canon in the modes brief §2; listed so the sweep sees it | modes | engine store (M2) | in brief modes §2 |
| S-12 | **One resolver, refuses ambiguity** | Already canon in the modes brief §4 | modes | every verb | in brief modes §4 |
| S-13 | **Invariant defects G1** | Wrong in every mode; goldens must not freeze them | inventory | see [bug-inventory.md §G](bug-inventory.md#g-disposition) | open |
| S-14 | **Tool descriptions constant across modes and sessions** | The framing-ablation invariant (D30/D37) applies to the whole surface | modes | `tools.ts` registration | in brief modes §3 |
| S-15 | **One `Corpus` per session, a session registry in the server.** Brief 01 §Stores ("a server holds one `Corpus` for its lifetime") and brief 04 (`createMdnavTools({ corpus, session, framing })`, singular) carry the singleton forward | Without this, bug inventory G2 reopens under v2 exactly as it stands today | brief review 2026-09-05 | brief 01 §Stores, brief 04 §Export/§Vendoring | open — amendment notes placed (D52) |
| S-16 | **D39's investigation record is the session record.** `inventory.json` schema 3 gains `widths`/`addressing`, `cohorts`, `authors[{name,pubkey}]`; per-author journals sit beside it; `run.json` stays per run. One name: `session.json`, or `inventory.json` grown — decide once | Brief 01 already requires "ids appear in agents' notes and must come back identical after restart" but gives no mechanism beyond re-scan; seeding from the record is that mechanism (S-11) | brief review | brief 01 §Layout | open |
| S-17 | **Pattern basis with an id capture** = the entry lens. Brief 03 §5 already cuts a node with `--by pattern:<re>` and addresses pieces `H0002/S3`; adding a capture group that names the piece (`H0002/r:D48`) makes register rows addressable by their own id instead of by ordinal | S-07 turns out to be a small extension of planned work, not a new mechanism; the same capture serves transcript turns and dated entries | brief review | brief 03 §5 basis; D41 path grammar (a code for captured ids); brief 05 address grammar | open |
| S-18 | **Session in the source identity.** Brief 05's row grammar has one `<source identity>` cell (`D002:H0108@fa8a`); with several sessions open it must carry the session (`doccer-renovation:D003:H00@30e7`) — the modes brief §3 rule | Already implied by brief 05's interleaving problem ("each chunk sufficiently self-identifying") | brief review | brief 05, atomic payload brief | open |
| S-19 | **Signing stays zero-dep.** Ed25519 via `node:crypto` only; keys as files | Brief 04 §Vendoring: "the engine stays single-file zero-dep" — S-02 must not break it | brief review | S-02 | noted |

## Owner calls pending (answers land as decisions, then rows above move)

| # | Question | Leaning recorded in discussion |
|---|---|---|
| Q-01 | Author identity granularity: product (`claude-code`, `codex`, `gemini`, `aipithicus`) with session id as an unsigned field, or per instance? | product |
| Q-02 | Are unsigned entries allowed? | allowed, marked, reported by `validate` when the session has declared authors |
| Q-03 | Does the decisions register become rulings-in-force (terse rows, `amends`/`supersedes` links, history derived) rather than an audit trail carried in the rows? | proposed; owner's to make |
| Q-04 | Is checkpoint segmentation acceptable for signed journals? | yes |
| Q-05 | Is the derived ledger's blind spot (a change made and reverted between syncs is visible only in git) acceptable? | yes |
| Q-06 | One process with many sessions, or one server per project fixed by argument? | per project first |
| Q-07 | What is a heading digest made of? Brief 01 fixes it as title text only, so same-title siblings (`## Notes`, dated `## 2026-…` entries) share a digest and an ordinal shift still "verifies" (B24). Options: title + level + path-local ordinal (stable under D41 paths, blind to body edits); title + first N bytes of body (flags body edits — signal for mutable documents, noise for prose); leave as is and rely on path addressing | none recorded; affects brief 01 §2 `digest[]` and every anchor ever written |
| Q-08 | Name collision: brief 05's example already labels an exchange row `adjutant` (para-agent's persona vocabulary). Is the mdnav mode meant to be *what that persona runs*, or does one of them need another name? | — |

## Report

2026-09-05 — opened with fourteen rows and six pending calls, harvested from the adjutant
design discussion.
