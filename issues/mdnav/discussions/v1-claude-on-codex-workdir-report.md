---
format: Structural
exported_at: 2026-09-03T12:31:23.4987551Z
exchanges: 6
user_label: Aipithicus
sessions:
  - f984db1d
models:
  - claude-opus-5
exclude:
  - thinking
  - synthetic
  - timestamps
  - session-markers
  - exchange-markers
  - tool-calls
  - tool-results
  - subagents
---

# so some feedback on mdnav mcp D:\aghado01\science-facility\issues\mdnav_v1\codex-feedback.md

I'll read the feedback file.
Verified the claims against the source, and reproduced the defect.

## What holds up

**Resolution order** — correct as documented ([engine.ts:205](mcp/mdnav/src/engine.ts:205)): explicit → `MDNAV_WORK_DIR` → `<anchor>/.doc-dive`. mdnav never defaulted to `.codex`. There's a fourth tier codex didn't mention: `tmpdir()/mdnav` when there's no anchor at all — that's the one that can silently orphan state.

**Singleton engine** — [index.ts:15](mcp/mdnav/src/index.ts:15), one instance for the process lifetime.

**Advertised-but-ignored `workDir`** — 12 schemas declare it, 4 handlers honor it (discover, and the journal trio via `resolveJournal`/`ensureJournalLoaded`). `index`/`profile`/`outline`/`marks`/`read`/`batch_read`/`coverage`/`locate` drop it on the floor.

## What codex understated

I mounted a 5-doc corpus A, read from it, then mounted a 2-doc corpus B (repro in scratchpad, `repro.mjs`):

```
[mount A]  D01 a1.md  D02 a2.md  D03 a3.md  D04 a4.md  D05 a5.md
[mount B]  D01 b1.md  D02 b2.md

[coverage, no docIds]      D01 D02 D03 D04 D05   ← five docs, two corpora
[what ids resolve to]      D01→Beta 1  D02→Beta 2  D03→Alpha 3  D04→Alpha 4  D05→Alpha 5
```

Two things worse than "inherited numbering":

1. **It's collision with silent overwrite, not inheritance.** `assignMountIds` maps every single-group mount onto group 0, docs 1..n, and `discover` never clears `docCoord`/`indices`/`sourceBuffers`. B's `D01` *replaces* A's `D01` in the index map; A's tail survives. `coverage()` with no `docIds` then reports a percentage over a denominator spanning two studies.

2. **The read ledger is destroyed on interleave.** A→B→A returns A at 0% over material already read. `initWorkDir` clears `readsLedger` on every root change, and the return trip mints a *new* run because the continue-guard tests `currentRoot === root` — which the detour broke. A's first-run `reads.jsonl` sits on disk, unloaded. That is exactly the fragmentation the "continuing run" notice at [engine.ts:230](mcp/mdnav/src/engine.ts:230) was written to prevent.

## One gap adjacent to the `.codex` incident

README:98 says mdnav "**refuses** a work dir placed inside the corpus where `discover` could see it." That guard exists only in the CLI — `assertNotDiscoverable` at [mdnav.mjs:141](mcp/mdnav/mdnav.mjs:141). The MCP server has no equivalent. `src/` (3.9k lines) and `mdnav.mjs` (1.2k lines) are separate implementations, which is why codex's CLI workaround is sound — but it also means a repair to one leaves the other untouched.

## On its repair list

Item 2 ("rehydrate inventory, indexes") assumes a loader that doesn't exist: `Dnnn.index.json` is **write-only** — written at [engine.ts:392](mcp/mdnav/src/engine.ts:392) and [1332](mcp/mdnav/src/engine.ts:1332), never read back. Since `discover` re-scans anyway, cheaper to key in-memory state by root and re-scan on switch, rehydrating only `reads.jsonl` and the journal (both of which do have loaders).

Item 3 is a real fork rather than a fix: for `read`/`outline`/`profile`, `workDir` has no meaning the doc id doesn't already carry. I'd remove it from the eight read-path tools rather than implement per-call remounting.

Item 4's sharp form: `coverage()` with no `docIds` should refuse when more than one root is mounted, not sum across them.
Good — it's the same disease one layer down, and the connection is sharper than I'd have guessed before reading the journal write path.

## The dovetail

e2d0560 established: **the frame is the claim.** An address in corpus vocabulary promises the bytes are re-readable, digest-checkable, and countable in coverage. Skill text lost the frame because it could keep none of those promises — "findable in the stream without being citable in the journal."

The multi-mount defect breaks the same promise from the other side. The address survives intact and keeps looking citable; the *referent* moves. `D03` names Alpha 3 at 14:00 and Beta 3 at 14:05, in one process, with nothing in the stream marking the transition.

And the engine already states the invariant it's violating, at [engine.ts:52](mcp/mdnav/src/engine.ts:52):

> …a journal anchor recorded as D001:H0002 then silently points at a different document, which no amount of digest checking can catch because the digest belongs to the wrong file too.

That comment defends the invariant *per path* — `docCoord` never reassigns a path. But the journal stores the **rendered id**, and nothing enforces injectivity there. Two paths, two coordinates, one rendered `D03`.

## Two independent selectors in one journal write

This is the part that bears directly on authorship provenance. When `recordJournal` runs:

- **Which corpus `D03` resolves against** = `this.indices` — whichever mount ran last.
- **Which notebook receives the entry** = `args.workDir` → `ensureJournalRoot` ([engine.ts:918](mcp/mdnav/src/engine.ts:918)).

Nothing ties them. You can append to A's notebook a citation that resolved against B's bytes, and the receipt comes back clean. The anchor validation at [engine.ts:1003](mcp/mdnav/src/engine.ts:1003) checks against the contaminated map — so a bare anchor passes silently, and an anchor *with* a digest gets diagnosed as **drift** ("the source moved under the citation") when it's actually an identity swap. Wrong diagnosis, and the remedy it implies — re-read the anchor — hands you Beta's bytes under A's note. `journal.jsonl` sits at the root and outlives runs, so that false citation is durable.

## Where I think the crux is

[engine.ts:186](mcp/mdnav/src/engine.ts:186) says group 0 is "reserved for anything read from outside the mount." But `assignMountIds` writes `single ? 0 : gi + 1` — every *single-group* mount takes group 0. That's the overload that lets two corpora share a numbering space, and it follows directly from the deliberate choice above it: "a constant coordinate is not information, it is width."

That reasoning is correct for a session that mounts once. It assumes the group axis is a property of **the corpus**. For injectivity across a process that can mount twice, it has to be a property of **the session** — mounts take group ≥ 1 always, a second mount lands on group 2, `rekeyToCurrentWidths` announces the widening loudly, and the citation graph stays injective without any per-root state machinery.

So before picking a repair shape, the question I'd want settled is the one your provenance thread is already about: **is `Dnn` a session-local handle or a citable identity?** Right now it's typed as both — the outline hands it out as a handle, the journal stores it as an identity. If it's an identity, the mount has to be *in* the id (or in the entry beside it), and the group-axis decision is the cheap way to get there. If it's a handle, then the journal was never entitled to store it bare, and the fix is on the write side — an entry records the mount root alongside the anchor, so provenance is self-describing and a later reader can verify rather than trust.

Which of those two do you take `Dnn` to be?

---

# i think there's need for session-level provenance for sure, so that addresses are well-posed, but we need to think about how to enforce boundaries will allowing for rehydration into existing sessions or even enabling/mediating concurrent views over multiple sessions by a user. look at this doc-dive folder with 2 separate mdnav sessions by codex `"D:\aipithicus\aipithicus-issues\Doccer\.doc-dive"`. each one has a journal above a runstamped directory containing the artifacts for that session. but these two sessions were also part of the same interactive chat thread on a related subject. i might want to look at the same subjects with claude and the mcp should allow for claude to drop in and rehydrate the context of either session because the artifacts and journals are internally consistent.

Read both sessions. The evidence is better than my repro — you already have the failure on disk, and it's the exact one.

## What the two journals show

Both sessions cite `D003`, with well-formed, digest-carrying anchors:

| | session | `D003` is | cited as |
|---|---|---|---|
| N005/N006/N008/N009/N016/N019 | doccer-renovation | `notes/sol-texdig-doccer-gaps.md` | `D003:H00@30e7` |
| N001/N002 | hybrid-interval-literature | `notes/grok-doccer-andrikopoulos.md` | `D003:H01@ca14` |

Both verify. Each is internally consistent — you're right about that, and `documents/` matches the citations in both. But internal consistency is the *only* consistency there is, and **nothing in the anchor records the frame it's consistent with.** The digest doesn't rescue it either: check `D003:H00@30e7` against the other session and you get a *drift* warning — "the source moved under the citation" — for what is actually a different document. Wrong diagnosis, and the remedy it implies (re-read the anchor) hands you the wrong text.

The journal ids collide the same way: both sessions have `N001`, `N002`, `N003`.

And `migration-residue-20260901/` holds `D008/D009/D010.index.json` pointing at `planning/decisions.md`, `roadmap.md`, `status-registry.md` — which are already `D005/D006/D007` in that same session's inventory. So you have both failure directions in one tree: **one id → two documents** (across sessions), and **one document → two ids** (within one). Injectivity broken both ways. I left that directory alone; its mtimes are minutes old and codex may still be in there.

## You've already invented the missing layer

```
<corpus>/.doc-dive/<session-name>/
    journal.jsonl        ← the notebook: durable, outlives runs
    LATEST
    <runstamp>/          ← an indexing episode: inventory.json, documents/, reads.jsonl
```

That is not the documented shape — [README.md:88](mcp/mdnav/README.md:88) says `.doc-dive/<runstamp>/`, with one journal per *corpus*. You got the session layer by passing a nested `workDir`, and it's the better model: a corpus hosts many lines of inquiry, and the notebook belongs to the inquiry, not the directory. It should be first-class — `discover(session: "doccer-renovation")` — rather than something you spell out by hand each time.

## What "well-posed" has to mean

The session is the frame, so the frame has to be *in the record*. Three places, and I think they're separable:

**In the entry, not the anchor.** `D003:H00@30e7` stays a fixed-width atom — that discipline is worth keeping (9333029) and qualifying every anchor with a session name would wreck it. Instead the journal entry carries `session` and `corpusRoot`, and the address is well-posed as the *pair*. Existing journals can be back-filled from their containing directory, since the layout already encodes it.

**Content identity as the cross-session join.** Every `Dnnn.index.json` already carries `sha256`. That's the key that makes concurrent views compose: `doccer-renovation:D005` and some future session's `D002` are provably the same file without changing the address scheme at all. You don't need content-addressed ids — you need the ids to *resolve* through content identity when more than one frame is open.

**On the wire.** This is the mirror of 49cbe92. The skill marquee strips the field mark so a segment is findable-but-not-citable; a corpus emission with two frames open needs the opposite — it announces the session so it's citable-and-unambiguous. `doccer-renovation | D003 | H00 · 30e7`.

## Rehydration needs a verb that doesn't exist

Today `run: latest` restores only `reads.jsonl`. The `documents/*.index.json` files are **write-only** — nothing in `src/` ever reads one back. So "drop in on codex's session" currently means re-running discover and *hoping* the re-scan reproduces the same ids. It happens to, because sorting is deterministic — until a file is added or removed, at which point every id after it shifts and all twenty journal anchors silently repoint. That's precisely the failure [engine.ts:52](mcp/mdnav/src/engine.ts:52) claims to prevent.

The fix is an **attach** that is the inverse of discover: read `inventory.json` → seed `docCoord`/`indices` from the *recorded* ids rather than re-minting them, load `reads.jsonl` and `journal.jsonl`, and verify each document's `sha256` against disk. Then rehydration is exact by construction, and the sha check earns its keep by telling you on arrival exactly which documents moved since codex recorded them — real drift, correctly diagnosed, because identity is no longer in question.

## Concurrency splits into two problems

**Comparative reads** are easy once frames exist: mount several sessions, every emission frame-marked, and refuse the ambiguous operations rather than resolving them silently. `coverage()` with no `docIds` currently sums across whatever's mounted — that should error with two frames open, not produce a percentage over a mixed denominator.

**Concurrent writes** are the harder one, and it's where your authorship thread bites. `mintJournalId` takes max+1 from the *in-memory* ledger, so codex and Claude appending to one `journal.jsonl` both mint `N021`. The line-level appends won't tear, but the ids will. Which suggests the atom should carry its author rather than the file arbitrating — and that's something you want recorded anyway, given that these journals already mix codex's reading with `conversation:` and `code:` anchors that no digest can check.

## Where I'd want your read

Three things I don't want to decide for you:

1. **Does a session name pin a corpus?** Right now `.doc-dive/<session>/` sits under one corpus by locality, but `discover` takes arbitrary `paths` and both your inventories have `root: undefined` — session 1 spans `ideation/`, `notes/`, `planning/`. So the session, not the root, is the real unit. Should attach re-verify that the recorded paths still resolve, and refuse if the set changed?

2. **Are the two sessions you showed me one investigation or two?** They came from one chat thread on a related subject and share a corpus. If a session can *reference* another — the way journal entries reference each other with `refs` — then cross-session provenance is a first-class edge rather than something a reader reconstructs. That seems more in keeping with the notebook's existing design than mounting both flat.

3. **How much does the author belong in the atom?** Entry-level field, or in the id itself. The field is cheaper; the id is what survives being quoted out of context — which is the whole argument the frame work rests on.

---

# yea but you are conflating 'corpus' with the locality. when i initalized those mdnav sessions i pointed to a few papers. in any given session the corpus is not well localized, so each session needs to preserve the provenacne of its source materials internally. the location of a .doc-dive folder does not mean the folder it's sitting in is necessarily its entire corpus. portability and self-containment are important her

---

# [Request interrupted by user]

---

# to answer your question, those to sessions were two mdnav sessions invoked during a chat, with each one pointing to different "corpus" materials on a related subject. which makes sense because the sessions occured at different turns in the conversation, in which i followed up the first one with pointing to some new materials that engaged mdnav

That reframes it. Corpus is a *set assembled by pointing*, and the two sessions are one investigation — same subject, same thread, second act of pointing at a later turn.

Which means the real defect is upstream of everything I've been describing: **mdnav has no verb for "add this to what I'm already studying."**

## The fork was an API gap, not a decision

Your second turn wanted to extend the corpus. The only available move was `discover` again, and naming a different `workDir` mints a whole new notebook. So a follow-up became a fork:

- ids restart at `D001` → `D003` now names two documents
- journal ids restart at `N001` → three entries in a second lineage instead of `N021`–`N023` continuing the first
- coverage denominators split, and the twenty-entry argument in session 1 can't reference the three new ones

Nothing about the material required that. Your two sets don't overlap by a single file — session 1 is 7 docs across `ideation/`, `notes/`, `planning/`; session 2 is 3 more in `notes/`. Extend them into one session and the new ones are simply `D008`–`D010`, one journal, one lineage, no collision anywhere.

Which is what `migration-residue-20260901/` contains: `D008/D009/D010`. The id space *did* continue past `D007` — the shape an extension takes. It just had nowhere legitimate to land, and bound to documents that already had ids.

There's a half-built version of this already: [engine.ts:222](mcp/mdnav/src/engine.ts:222) makes re-discovery *continue* the current run rather than fragment coverage — the notice even says so. But it only fires when the resolved root matches, so it can never fire for the case that matters, which is pointing at material somewhere else.

## Self-containment fails earlier than I thought

I checked what a session actually persists. `Dnnn.index.json` holds `path`, `sha256`, `bytes`, `mtimeMs`, encoding, headings with digests and spans, breaks, noise, windows — the complete structural map. **It holds no text.** `D003.index.json` describes a 1468-byte document without carrying any of those 1468 bytes.

So a session today records where material was on one machine and what shape it had. Move it, or move the papers, and every anchor in the journal still *parses* and still *sorts*, but not one of them can be resolved to a quote. For a corpus of scattered papers — which is exactly your case — the session isn't portable in any sense that matters.

Given mdnav's thesis is *don't load the whole document into context*, capturing source bytes on disk costs nothing against that principle: disk isn't context. It's what makes the audit trail an audit trail rather than a set of coordinates into someone else's filesystem. Keyed by `sha256`, it also gives you the cross-session join for free — two sessions that touched the same paper agree on it by content, whatever ids they each handed out.

## What the provenance record has to hold

Following your correction, provenance is **per document**, not per session, and locality is incidental:

- **Origin** — kind and locator (`file:D:\...\notes\x.md`, and the journals already show `code:`, `conversation:` as sibling kinds), recorded *as of* the moment it joined.
- **Identity** — `sha256`, already computed. The path is a hint; the hash is the document.
- **Cohort** — which act of pointing brought it in. That's your turn boundary, preserved as data instead of as a directory fork. Coverage can then still answer "how much of what I had before I added these" without splitting the notebook.

And a structural consequence: `inventory.json` currently lives in the **run** directory, so document identity is a property of an indexing episode. Under your model it's a property of the **session** — ids, id-scheme widths, origins, cohorts belong beside `journal.jsonl`, and runs go back to being what their name says: episodes of re-scanning.

That also settles the anchoring default. `<first target>/.doc-dive` derives the notebook's location from whichever paper you happened to name first — arbitrary when the corpus has no root, which is the normal case for you. The notebook's home is a choice about where *your work* lives, not a fact about the material.

Two things I'd still want your call on:

1. **Capture bytes by default, or on request?** Always-capture makes every session self-contained but duplicates material you already own; on-request means portability is something you have to remember to ask for, and you'd usually remember too late.

2. **Does extending re-open a closed session, or is there a boundary worth keeping?** Your two acts of pointing were minutes apart in one thread. If you came back a week later on the same subject, is that the same session growing, or a new one that *references* the first?

---

# <command-message>chat-export</command-message>
<command-name>/chat-export</command-name>
<command-args>to science-facility/issues/mdnav</command-args>
