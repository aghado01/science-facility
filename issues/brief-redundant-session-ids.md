# Brief: redundant / multiple session IDs at the export entry point

**Status:** OPEN — captured, not actioned. Low urgency (see §4).
**Raised:** 2026-07-25, as a tangent while making `-SourceDir` optional
(see [brief-session-resolver.md](brief-session-resolver.md) §11).
**Target:** `D:\aghado01\utils\jso-jackson\claude-export\`

---

## 1. Not in question

The sentinel walk is working as designed and is **not** what this brief is about. Given one
session id, `New-ClaudeThreadManifest` resolves the whole chain that id belongs to, assembles
every constituent session, and deduplicates in the course of producing a single thread's markdown.
That behaviour is deliberate, correct, and load-bearing. Nothing here proposes changing it.

The question is narrower: what happens when the **caller supplies more than one session id**, and
those ids may or may not point into the same chain.

## 2. What the code actually does

`claude-jso-jackson.ps1`, `New-ClaudeThreadManifest`:

```powershell
# line 229-231 (comment, verbatim)
#   With -SessionIds: the first id is treated as the LEAF UUID; we return
#     the chain that terminates with it. Additional ids are ignored — chain
#     membership comes from the sentinel walk, not from the caller.

$leafTarget = $SessionIds[0]                                    # :237
...
throw "No chain found terminating with leaf UUID: $leafTarget"  # :247
```

Two consequences:

**F1 — extra ids are silently discarded.** `-SessionIds @(a, b, c)` exports `a`'s thread only.
`b` and `c` are dropped with no warning, no error, and no mention in the returned object. If `b`
names a genuinely different thread, the caller believes they exported it and did not.

**F2 — the first id must be a chain LEAF.** Passing a *prior* (a session bearing a `.jsonl.idx`
sentinel, i.e. one that was continued) throws `No chain found terminating with leaf UUID: {id}`.
Note the asymmetry with the new resolver: `Resolve-ClaudeThreadPath` will happily locate a prior
session's `.jsonl` on disk, and the manifest then rejects it. The failure is loud but the message
does not explain that the id was valid and merely wasn't a leaf.

F1 is the redundancy issue. F2 is a separate usability wart in the same code path, recorded here
because any fix touches the same lines.

## 3. Current exposure

| Caller | Passes | Exposed? |
|---|---|---|
| `Invoke-ClaudeThreadExportBatch` | `SessionIds = @($leafUuid)` — always exactly one, always a leaf, taken from `Get-ClaudeThreadPlan.LeafUuids` | No — safe by construction |
| `Invoke-ClaudeThreadExport -SessionId` | singular `[string]`, resolved via `Resolve-ClaudeThreadPath` | No for F1 (one id by type); **yes for F2** if a prior id is supplied |
| `Invoke-ClaudeThreadExport -SessionIds` | `[string[]]`, straight from the caller, unvalidated | **Yes — this is the only F1 surface** |

So F1 is reachable only by a human calling the `-SourceDir` + `-SessionIds` form directly. No
internal caller can trigger it.

## 4. Why this is low urgency

Measured 2026-07-25 across all 16 project dirs under `~/.claude/projects`:

- **216** top-level UUID-named `.jsonl` files
- **1** `.jsonl.idx` sentinel

There is currently **no chain of length ≥ 2 anywhere in the corpus**. Multi-session threads are
essentially absent from live data right now, so both F1 and F2 are latent rather than active. This
is a prevalence observation for prioritisation only — it says nothing about whether the sentinel
mechanism is right, and continuations will presumably reappear.

## 5. The architectural question (open, not decided)

If a list of distinct session ids were to be honoured, the semantics the user described are:

> a list of distinct session IDs should resolve respectively the same way a single one does […]
> process the distinct threads that are implicitly specified by the list of sessionids and not
> spuriously process the same thread from two different entry points

That implies a fan-out with chain-level deduplication:

1. resolve each id → its transcript path (and therefore its project dir)
2. map each id → the **leaf** of the chain containing it
3. dedupe on `(SourceDir, leafUuid)` — two ids in one chain collapse to one thread
4. export each surviving distinct thread exactly once

This would also fix F2 for free, since a prior id maps to its chain's leaf instead of throwing,
and it would permit ids from *different* projects in one call (each resolves its own `SourceDir`).
Cost: `Invoke-ClaudeThreadExport` would return an array rather than one result object — mitigated
in practice by PowerShell unrolling a single-element return, so existing single-thread callers
would be unaffected.

Options, for the record:

| | Behaviour on >1 id | Notes |
|---|---|---|
| **A** | Fan out + dedupe by chain leaf, as above | Matches the described intent; largest change; fixes F2 |
| **B** | Throw | Cheapest; consistent with the resolver's fail-loud doctrine (D2); turns a silent wrong answer into a loud one |
| **C** | Status quo — use the first, ignore the rest | Current. Silently returns a wrong-but-plausible result, which is precisely what D2 exists to prevent |

Status quo (C) is the only one that is clearly wrong on the project's own stated principles. B is
a two-line change that removes the hazard without settling the design question.

## 6. Direction the user favours

Preclude the issue rather than resolve it: **add a separate entry point for the agent-facing,
called-from-inside case**, distinct from the human-facing, called-from-outside entry points.

The rationale is that the two callers have genuinely different shapes, and today they share one
function only by accident:

- **Agent, from inside a thread** — always exactly one session id, always the current thread's,
  always a leaf (the live session cannot have been continued yet). Single-export mode. Discovers
  its own id from `$env:CLAUDE_CODE_SESSION_ID`.
- **Human, from outside** — bulk or selective, may name any project, may name older sessions.
  This is what `Invoke-ClaudeThreadExportBatch` and the `-SourceDir` forms are for.

Today the single-export guarantee is *situational*, not enforced: it holds because the user does
not ask agents to do bulk exports, not because anything in the signature prevents it. A dedicated
agent-facing entry point taking exactly one id would make that guarantee structural, and would
leave the multi-id question confined to the human-facing surface where F1 currently lives.

The architectural question in §5 stays open either way — it just stops being on the path of the
case that actually runs.

## 8. Session rotation on thread switch — a second, larger split (2026-07-25)

The §4 prevalence figure (1 sentinel / 216 files) was read as "multi-session threads are rare."
That reading was wrong, and the reason matters more than the original tangent.

`.jsonl.idx` sentinels *are* rare — they appear only when a thread grows long enough to be
continued. But there is a **second way a conversation splits across session files, and it leaves
no sentinel at all**: switching from one chat to another and back within a running Claude app
mints a new session id.

### 8a. Evidence

The session that produced this brief is itself an instance. Project dir
`~/.claude/projects/D--aghado01-utils-jso-jackson`:

| file | when | lines | `.idx`? |
|---|---|---|---|
| `88478329-e8f2-4427-98f1-9d6ef647cb89.jsonl` | 07-24 21:18 | 260 | **no** |
| `6322c777-de9a-4946-8bca-74d809df5b77.jsonl` | 07-25 01:03 | 601 | **no** |

One continuous conversation, no app restart, two files. Probing for anything that connects them:

- **No sentinel** on either file, so the moonwalk sees two independent chains.
  `Get-ClaudeThreadPlan` confirms: `chains=2 leaves=2 priors=0`.
- **No structural back-link.** File B mentions A's uuid 52 times, but every occurrence is inside
  nested message content — tool output quoted in the transcript. Scanning top-level record fields
  for a value equal to A's uuid returns **nothing**.
- **`leafUuid` is intra-file.** A's final record is `type=last-prompt` carrying
  `leafUuid=98fec6c8-…`, which is a record uuid *within A*. It does not appear in B.
- **`sessionId` never crosses.** Every record in A carries A's id; every record in B carries B's.
- **No `summary` or `compact_boundary` records** in B that might name a predecessor.

The only shared signal is `custom-title`: both files carry
`"Add session-id resolver to chat exporter"`. B additionally carries `"claude-chat-export"` — the
thread was renamed partway through, so even that is not stable within a single conversation.

### 8b. Consequence

`Export-ClaudeChat` (and any export keyed on the live session id) captures **only the portion of
the conversation since the most recent rotation**. Demonstrated on this very thread: exporting
`6322c777` yields 11 exchanges from 650 records, and the preceding 260 records in `88478329` are
simply absent. The output is a well-formed markdown file that silently begins mid-conversation.

This is the failure mode D2 exists to prevent — a plausible-looking wrong answer — except the tool
cannot currently detect it, because on disk there is nothing to detect.

### 8c. Why no automatic fix was attempted

`custom-title` is the only candidate link and it is not sound:

- titles are mutable mid-thread (proven above — B holds two)
- nothing prevents two unrelated threads sharing a title
- the record is not at a fixed position, so testing it means parsing whole files, not one line
  each — across a 107-file project dir that is the O(tree) cost D3 rejected

Heuristically stitching on a mutable, non-unique, expensive-to-read field would trade a *visible*
truncation for an *invisible* mis-merge. Worse failure, same class.

So the limitation is **documented rather than papered over**: in `Export-ClaudeChat`'s help, and
in `claude-export/README.md` §1 under "One limitation worth knowing", phrased so that a truncated
export is recognisable as this and not as a renderer bug.

### 8d. Rotation is frequent, not occasional (measured later the same session)

The two files in §8a were the state at 01:03. By 01:30 the same single conversation had become
**four** files, none carrying a sentinel:

| file | last write | lines | `.idx`? |
|---|---|---|---|
| `88478329…` | 07-24 21:18 | 260 | no |
| `6322c777…` | 07-25 01:24 | 680 | no |
| `9c02752c…` | 07-25 01:26 | 534 | no |
| `54204ab0…` | 07-25 01:30 | 588 | no |

Three rotations inside six minutes, without switching chats — so the §8a guess that rotation
tracks user thread-switching is wrong, and whatever triggers it is more frequent than that.

> **This subsection originally concluded that the export "captured 588 of ~2,062 records — under a
> third of the conversation." That was wrong.** It summed line counts across the four files as
> though they were disjoint segments. They are not: they are overlapping cumulative snapshots, and
> the correct figure is 100% of the conversation. See §8f, which supersedes this.

### 8f. Resolved — the files are cumulative snapshots, not segments

The user's hypothesis, and it is correct:

> each of these sessionid's files i suspect is actually a cumulative full thread history up to the
> lifetime of a given sessionid

Tested three ways on the five files this conversation produced.

**Record-identity overlap.** Extracting every record `uuid` and intersecting pairwise: 2,517
record instances resolve to **706 distinct records**, a **3.57× duplication factor**. Later files
replay earlier records under the *same* uuids — literal duplication, not re-serialisation.

**Opening prompt.** All five files share exactly one first user prompt
(`distinct first-prompts = 1`). Segments would each start somewhere different.

**Prompt sequence.** Each file's final prompt sits mid-file in the next, with later prompts
following it, and prompt counts grow monotonically 3 → 10 → 10 → 11 → 12:

| transition | last-of-previous lands at | of |
|---|---|---|
| `88478329` → `6322c777` | index 2 | 9 (7 follow) |
| `6322c777` → `9c02752c` | index 9 | 9 (at end — the interrupt case) |
| `9c02752c` → `54204ab0` | index 9 | 10 |
| `54204ab0` → `20ac496b` | index 10 | 11 |

That is precisely the shape of a cumulative history rewritten on each rotation.

**What this means for the tool — nothing is broken.** The newest snapshot is the complete one, and
the live session id *is* the newest snapshot. `Export-ClaudeChat` therefore captures the whole
conversation. Verified independently at content level: of the distinct real user prompts across
all five files, **0 are absent** from the newest. The 118 records the newest file lacks are 107
`attachment`, 3 `system`, and 8 `user` — and those 8 are interrupted turns paired with
`[Request interrupted by user]` markers, i.e. aborted attempts whose re-sent versions are present.
Nothing said in the conversation is lost.

The one real caveat is the reverse of what was first documented: exporting an **older** id gives
the conversation as of that rotation, not its final state. §8b, §8c and §8d as originally written
overstated the problem; the README and `Export-ClaudeChat` help have been corrected accordingly.

**Trigger.** Every rotation observed here coincides with a `[Request interrupted by user]` record
orphaned in the outgoing file. Four for four, which is suggestive but not conclusive — interrupts
were frequent in this session, so the correlation may be incidental.

### 8g. The actual problem — silent accretion

The export path is fine. The storage behaviour is not, and it is what the user flagged.

Measured across all of `~/.claude/projects` by grouping files on (project dir, first user prompt):

| | |
|---|---|
| transcript files with an identifiable opening prompt | 219 |
| distinct conversations they represent | **87** |
| conversations stored as more than one file | 35 |
| redundant files | **132** |
| total bytes | 357,127,895 |
| bytes if only the newest snapshot per conversation were kept | 149,690,026 |
| **redundant** | **207,437,869 — 58%** |

Worst single case: one conversation held as **24 files totalling 41.6 MB**. This conversation
alone: 5 files, 7.3 MB, 72% redundant.

Growth is quadratic in rotations — each one rewrites the entire history to date — so the cost
falls hardest on exactly the long, valuable threads. Nothing signals it to the user; the files are
UUID-named and carry no marker distinguishing a snapshot from an original. Visibility here is
incidental, a by-product of having built a tool that enumerates the directory.

Whether this is deliberate (crash-safety, resumability) or an oversight is not determinable from
the filesystem alone. It is worth reporting upstream regardless.

### 8e. Open

- Is rotation deterministic (always on thread switch) or incidental? Two data points is not a
  model. Worth watching whether the count of same-title sibling files in a project dir grows in
  step with switching.
- Is there any *other* on-disk signal — a sidecar, an app-level index outside `projects/`,
  something in `~/.claude.json` — that names the rotation? Not yet looked for, and it is the only
  thing that would make a sound fix possible.
- If a signal exists, the §5 fan-out design already accommodates it: rotation-siblings would
  resolve to one logical thread and dedupe exactly like chain members do.

## 9. Out of scope

- Any change to the sentinel walk or its dedup behaviour (§1).
- Implementing §5 option A or B — recorded, not chosen.
- Stitching rotation-siblings by `custom-title` (§8c) — rejected on evidence, not deferred.
- The `chat-export` skill that will call `Export-ClaudeChat`; belongs with the skill discussion in
  [brief-session-resolver.md](brief-session-resolver.md) §7.

## 10. Done since this brief was opened

`Export-ClaudeChat` was added to `claude-export/claude-jso-run.ps1` as the agent-facing entry
point described in §6, closing the "situational, not enforced" gap for the case that actually
runs. Signature is three parameters:

```powershell
Export-ClaudeChat [-SessionId <string>] [-OutputDir <string>] [-OutputPrefix <string>]
```

`-SessionId` defaults to `$env:CLAUDE_CODE_SESSION_ID` and is a single string, so the F1 multi-id
surface is unreachable from it by type. `SourceDir`, the project slug, `Format`, `Exclude`, and
`WorkingDir` are not exposed at all — resolved or fixed internally. Returns
`{ MarkdownPath, SessionId, ProjectName, ThreadId }` and never reads transcript content back to
the caller.

Verified: the bare agent call resolves and exports with no arguments beyond a destination; missing
session id, missing output dir, and malformed id each throw with an actionable message;
`$env:JSO_EXPORT_DIR` serves as the `-OutputDir` fallback.

`claude-export/README.md` was written to replace pointing at a personal scratch file — §1 is the
agent path, §2 the full human-facing surface, §3 how location and discovery work.

**F1 and F2 remain open on the human-facing `-SessionIds` parameter.** The new entry point routes
around them; it does not fix them.
