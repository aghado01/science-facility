# mdnav — bug inventory

Living register of defects in the MCP server (`mcp/mdnav/src/`), opened 2026-09-05. One row per
defect; a row is closed by striking it through and naming the commit or decision that closed it,
never by deleting it. Evidence is a probe id from
[../reports/bug-probes-20260905.mjs](../reports/bug-probes-20260905.mjs) (run it with
`node issues/mdnav/reports/bug-probes-20260905.mjs`; every probe prints CONFIRMED with what it saw),
a file:line, or a report. Severity: **S1** wrong answer with no warning · **S2** wrong answer,
warned or recoverable · **S3** inconsistency, usability, or doc mismatch.

Sources this consolidates: [v1-codex-workdir-singleton-defect.md](../reports/v1-codex-workdir-singleton-defect.md),
[v1-claude-on-codex-workdir-report.md](../discussions/v1-claude-on-codex-workdir-report.md), the real
two-session tree at `D:\aipithicus\aipithicus-issues\Doccer\.doc-dive`, and a source audit of
`engine.ts`, `tools.ts`, `scanner.ts`, `formatting.ts` on 2026-09-05. `skills.ts` was not audited.

## A. Session identity and provenance

| # | S | Defect | Evidence |
|---|---|---|---|
| B01 | S1 | **Second mount collides with the first, silently.** `discover` never clears `docCoord`/`indices`/`sourceBuffers`; every single-group mount lands on group 0 (`assignMountIds`: `single ? 0 : gi+1`), so corpus B's `D01` *replaces* A's `D01` while A's tail survives. `coverage()` with no `docIds` then reports over both. | P1: after mounting B over a 5-doc A, ids read `D01=b1 D02=b2 D03=a3 D04=a4 D05=a5`; coverage spans 5 docs |
| B02 | S1 | **Read ledger is reset on root change; the return trip mints a new run.** `initWorkDir` clears `readsLedger` whenever the resolved root differs, and the continue-guard tests `currentRoot === root`, so A→B→A reports A at 0% with A's `reads.jsonl` unloaded on disk. *Precise condition:* only when the work-dir **root** changes — default anchoring (`<first target>/.doc-dive`) changes it for every different corpus; an explicit shared `workDir` keeps the ledger (P1 kept it because the probe passed one). | codex + claude reports; P1 |
| B03 | S1 | **Journal write has two independent selectors.** Anchor validation resolves against `this.indices` (last mount); the notebook that receives the entry is `args.workDir` → `journalRoot`. A citation resolved against B's bytes can be appended to A's notebook with a clean receipt; with a digest it is misdiagnosed as *drift* rather than an identity swap. `journal.jsonl` outlives runs, so the false citation is durable. | claude report §"Two independent selectors"; `engine.ts` `recordJournal` (`this.indices.get(p.scope)`) vs `ensureJournalRoot(args.workDir)` |
| B04 | S1 | **Id widening breaks every join that stores a rendered id.** `rekeyToCurrentWidths` re-renders ids in `indices`/`sourceBuffers` and emits a notice, but `readsLedger`, `reads.jsonl`, and `journal.jsonl` keep the old spelling, and coverage/journal join on exact string equality (`r.doc === docId`, `p.scope.toUpperCase() !== docId.toUpperCase()`). After widening, prior reads and citations vanish from coverage and `journal_read(scope)`. Triggered by any multi-group mount after a paths-mode mount, or by growth past a width. | P2: `D001` → `D00001`; bytesRead 89 → 0, cited 0, journal_read finds 0 |
| B05 | S2 | **`workDir` is advertised by 12 schemas and honoured by 4.** `index/profile/outline/marks/read/batch_read/coverage/locate` accept it and ignore it. | `types.ts` schemas vs `tools.ts` handlers; codex report |
| B06 | S2 | **`Dnnn.index.json` is write-only; there is no attach.** `run: latest` restores only `reads.jsonl`; identities are re-minted by re-scanning, so a file added or removed since shifts every later id under the journal's anchors. Also on attach, `discover` overwrites the attached run's `documents/*.index.json` with a fresh scan — the record of what the earlier session saw is lost. | `engine.ts` `discover` (writes) — no reader anywhere in `src/`; claude report §"Rehydration needs a verb" |
| B07 | S2 | **No verb to extend a corpus.** Pointing at new material means `discover` again; with a new `workDir` that forks the notebook (ids restart at `D001`, journal at `N001`); with the same root it continues but only for the *same* anchor. The real tree shows the fork: two sessions, both with `D003`, both with `N001..N003`, and `migration-residue-20260901/D008..D010` where an extension had nowhere to land. | Doccer `.doc-dive` tree; claude report §"The fork was an API gap" |
| B08 | S2 | **Journal falls back to the temp dir when nothing is mounted.** `ensureJournalRoot` with no explicit root and no `MDNAV_WORK_DIR` writes to `tmpdir()/mdnav/journal.jsonl` with no notice. | P15 |
| B09 | S2 | **The MCP has no work-dir refusal guard.** README promises mdnav refuses a work dir `discover` could see; only the CLI (`mdnav.mjs:141 assertNotDiscoverable`) implements it. | claude report §"One gap adjacent" |
| B10 | S2 | **Stale journal lock is permanent.** `acquireJournalWriteLock` uses `openSync(…, "wx")` with no age check, owner pid, or expiry; a writer that crashed leaves every later `journal_record` failing with "another writer holds the journal lock". | P12 |
| B11 | S3 | **Session stores no source bytes.** `Dnnn.index.json` carries path, sha256, spans, digests — no text. A session over scattered papers is not portable: move the papers and every anchor still parses and sorts but resolves to nothing. | claude report §"Self-containment fails earlier" |
| B12 | S3 | **Two producers, one tree, two schemas.** The CLI writes `{schema, docs:[{id,path,name}]}` inventories with no `stamp`/`workDir`/`reads.jsonl`; the MCP writes schema-2 inventories with both. Both write `LATEST`, so `run: latest` from the MCP can attach to a CLI run and inherit nothing. | Doccer tree: runs `20260901_*` are MCP, `20260902_*` are CLI (`workDir` absent) |

## B. Reference resolution

| # | S | Defect | Evidence |
|---|---|---|---|
| B13 | S1 | **Basename references resolve to the first match, silently.** `resolveDoc` matches `basename(idx.path) === docRef`; a corpus with `planning/decisions.md` and `archive/decisions.md` hands back whichever sorted first. Project-planning corpora are exactly the case (every project has `decisions.md`, `roadmap.md`, `README.md`). | P3: `read("decisions.md")` → `archive/decisions.md` as `D0101`, no mention of the other |
| B14 | S1 | **A reference that is not an id or a known path is resolved against the server's cwd.** `resolveDoc` falls through to `existsSync(docRef)` — relative to the MCP process cwd (the repo root), not the corpus — and indexes the hit on the fly into group 0, outside the inventory, never persisted. | P3b: `outline("package.json")` indexed `mcp/mdnav/package.json` as `D0001` |
| B15 | S2 | **Width tolerance is asymmetric.** Unit coordinates are tolerant (`H1`/`H01`/`H0001` all resolve, `sameCoord`); document ids are exact (`indices.has(docRef)`), so `read("D1")` fails and a journal anchor `D1:H1` warns "not indexed" for a document that is. Same root cause as B04's join. | P14 |
| B16 | S2 | **`coverage(docIds)` does not accept what every other tool accepts.** It calls `getIndex` directly, so a path or basename that works in `read`/`outline`/`locate` throws "Index for a.md is not loaded". | P7 |
| B17 | S2 | **`discover` over paths that do not exist succeeds.** Missing paths are skipped (`existsSync … continue`) with no error and no notice; only the `root` form errors on an empty result. A typo yields "1 document(s) indexed" and a coverage denominator missing the rest. | P8 |
| B18 | S3 | **`glob` is not a glob.** `matchGlob` special-cases `*.md` and `*`; anything else is `name.includes(glob without '*')`, so `*.{md,txt}` and `docs/**` silently match nothing useful while the schema calls it a "file glob pattern". | `engine.ts` `matchGlob` |

## C. Scanner and measurement fidelity

| # | S | Defect | Evidence |
|---|---|---|---|
| B19 | S1 | **YAML frontmatter is recognised and then scanned as body.** The line loop starts at the BOM offset, not after `frontmatter.end`, so the two `---` delimiters count as thematic breaks (and split the break basis), and a YAML comment `# note` becomes an H1 that outranks the document's real title. Planning docs carry frontmatter routinely. | P4: `breaks=2`, `H01 = "a yaml comment"`, `H02 = "Real"` |
| B20 | S2 | **`profile` and `marks` are not fence-aware; `outline` is.** `profileDocument` counts `# …` inside fences as headings, so the two surfaces disagree on the document's own structure — the README's 38-vs-22 example is this defect in the MCP, not only in `grep`. | P6: scanner h1=2, profile h1=4 |
| B21 | S2 | **Fence recognition in `marks`/`profile` is backtick-only and space-intolerant.** ```` ```js title="x" ````, `~~~` fences, and four-backtick fences are missed, and a missed opener mis-pairs every fence after it. The scanner's own fence state machine handles all three. | P11: 3 fences → marks 1, profile 1 |
| B22 | S2 | **`marks(kind: "paragraph")` is advertised and unsupported.** Not in the `switch`, so it falls to `new RegExp("paragraph")` and enumerates occurrences of the *word*. Any unknown kind is silently treated as a regex. | P5: 3 runs, every preview the literal word |
| B23 | S2 | **`strip: "all"` removes far less html than the inventory counts.** `scanNoise` counts every tag; `stripNoise` unwraps only `<div>`/`<span>` and deletes comments. `<details>`, `<summary>`, `<img>`, `<br>` survive, so a document flagged `html 5 KiB` reads back nearly unchanged. The CLI strips tags generally. | P13: 85 B counted, 26 B removed |
| B24 | S2 | **Same-title headings share a digest, so drift is invisible for them.** Digest is of the title text only; two `## Notes` verify against each other, and an insertion that shifts ordinals still "verifies". Every ledger-shaped document (dated `## 2026-09-05` entries, repeated `### Report`) has this shape. | P16 |
| B25 | S3 | **Segment and window digests are keyed on the whole-file sha.** `digestOf("seg:"+sha256+":"+start)` and `digestOf(sha256+":"+pos)` change on any edit anywhere in the file, so every `S`/`W` anchor drifts at once; and `outline(windows)` overwrites `idx.windows`, so windows minted for one `within` are silently replaced by the next call. | `engine.ts` `segmentsOf`, `computeWindows`, `outline` |
| B26 | S3 | **Grain reports a mean labelled as a median** (`bytes / d1`); profile's `paragraph` regex double-counts numbered-list lines and `* * *`; `list` regex claims thematic breaks written `* * *`. Measurement noise, not wrong anchors. | `engine.ts` `describeDoc`; `scanner.ts` `profileDocument` |

## D. Accounting and framing parity (MCP vs CLI vs README)

| # | S | Defect | Evidence |
|---|---|---|---|
| B27 | S1 | **Coverage counts elided bytes as read.** README: "coverage subtracts elided spans, so a unit that is 99.5% screenshot reports the ~2 KB you actually read". The CLI does (`mdnav.mjs:966`); the MCP records `elidedBytes` per read but `bytesRead`/percent use the raw span. A screenshot-heavy transcript reads 100% covered after one stripped read. | P9: read 20,046 B with 19,994 elided → coverage 20,046 B (100%) |
| B28 | S3 | **Elision accounting is inconsistent within one read.** `elidedBytes` is net of inserted marker text; link-form signed URLs and alt-text image refs elide bytes without pushing an `Elision`, so the summary's per-kind counts disagree with the total. | `scanner.ts` `stripNoise` |
| B29 | S3 | **`read` and `batch_read` default to different depths** (1 vs 2) and different strip defaults (`none` vs `all`); a request copied from one to the other behaves differently. `from/to` frames the chunk with the `from` anchor only. | `types.ts` schemas; `tools.ts` read framing |
| B30 | S3 | **`outline(within)` at the default depth returns nothing and says nothing.** `within` an H1 with `depth: 1` filters out every child. | P10 |
| B31 | S3 | **Two implementations.** `mdnav.mjs` (1.2k lines) and `src/` (4.4k) are separate engines with overlapping verbs and diverging semantics (B09, B12, B23, B27). Every repair lands in one of them. D22/D47 freeze the CLI as the oracle, which makes the MCP the only place fixes go — and means the oracle now encodes behaviour the MCP does *not* have. | this audit |

## E. What the suites do not cover

No existing suite exercises: a second mount in one process (B01–B04), width growth after reads (B04), same-basename corpora (B13), cwd-relative fallback (B14), frontmatter documents (B19), fence variants outside the scanner (B20–B21), the `paragraph` kind (B22), stripped-read coverage (B27), stale locks (B10), or the CLI-written run shape (B12). The A→B→A interleave test codex asked for is still the single most valuable addition. When these land as `.test.ts` they double as the goldens M0 needs.

## F. How the rows cluster for a fix, and where the docops mode presses

The rows are not thirty independent bugs; they are five decisions, and the project-docops use (a
long-lived session over one project's planning corpus — roadmap, decisions, registers, briefs —
spread across directories, visited across many chat turns and by more than one agent) presses on
every one of them.

1. **Session is the unit of identity, not the mount.** B01, B02, B03, B04, B06, B07, B11, B12,
   B15 are one decision: a session record (ids, widths, per-document origin + sha256 + cohort, the
   notebook) that lives beside `journal.jsonl`, with `attach` (seed ids from the record, verify
   sha, load ledgers) and `extend` (add a cohort under the existing widths) as verbs, and runs
   demoted to re-scan episodes. Roadmap M2 already plans the store/hygiene layout (D39); this is
   the same work seen from the defect side, and it should absorb the two open questions in the
   claude report (does a session pin a corpus — no, per the user's correction; capture bytes by
   default — decide there). Docops pressure: the corpus is assembled by pointing and grows every
   few turns; codex and claude both write to it; the session outlives any one process.
2. **One reference resolver.** B13, B14, B15, B16, B17, B18: every tool resolves a document
   reference through one function that is width-tolerant on `D`, refuses ambiguous basenames by
   listing the candidates, never touches the filesystem relative to the server cwd, and reports
   missing paths. Docops pressure: `decisions.md` exists in every project directory the session
   spans.
3. **Scanner is the single structural authority.** B19, B20, B21, B22, B23: `profile`/`marks`
   consume the scanner's fence map and heading list instead of re-deriving them with regexes;
   frontmatter is a region, excluded from the body scan and addressable on its own. This is what
   the v2 collectors (brief 02) do by construction — a reason to sequence brief 02 early rather
   than patch regexes. Docops pressure: every planning doc has frontmatter; `## 2026-…` ledger
   entries repeat titles (B24).
4. **Mutable documents need a different anchor discipline.** B24, B25, plus the refresh path:
   ledgers are edited by prepending under a header, which shifts every byte offset and every
   heading ordinal below the edit on every touch, so a journal citation into `decisions.md`
   rots within the day. Docops mode should anchor into stable row identity where a document has
   one (`D48`, `B13`, an RD-id) — a per-lens anchor rule rather than a scanner change — and
   digest a heading on more than its title. This is a design item for the docops brief, not a
   patch.
5. **Accounting parity is a golden question.** B27, B28, B29, B31: decide once whether coverage
   is bytes-materialised or bytes-delivered (the README and CLI say delivered), encode it in the
   M0 goldens, and let the MCP be checked against them. Until then the numbers a docops session
   reports for "how much of the roadmap have I actually read" are wrong in the direction that
   hides the gap.

Smaller and independent, safe to fix any time: B05 (drop or honour `workDir` per tool), B08,
B09, B10, B26, B30.

## G. Disposition

Added 2026-09-05 with D50. Three buckets: rows that are wrong in every mode and can be fixed and
tested in isolation now; rows the session infrastructure removes by construction (patching them
first would be work thrown away); rows that are design decisions, not defects.

**G1 — Invariant, squash now** (each fix ships with a `.test.ts` that fails before it; these
precede M0's goldens so the goldens do not freeze the wrong behavior):

| # | Fix in one line | Test |
|---|---|---|
| B19 | scan the body from `frontmatter.end`; expose frontmatter as its own region | a YAML `# comment` is not a heading; `---` delimiters are not breaks |
| B13 | basename match refuses when more than one document matches, listing candidates | two `decisions.md` → error naming both |
| B14 | drop the `existsSync(docRef)` cwd fallback; relative refs resolve against the session's roots only | `outline("package.json")` refuses |
| B15 | `D` ids width-tolerant everywhere `H` already is (`sameCoord` on the doc axis) | `read("D1")`, journal anchor `D1:H1` both resolve |
| B16 | `coverage` resolves refs through the same function as `read` | `coverage(["a.md"])` works |
| B17 | `discover` reports missing paths as an error (all missing) or a notice (some) | 3 paths, 2 missing → notice naming both |
| B27 | coverage subtracts elided spans, per README and CLI (`mdnav.mjs:966`) | stripped screenshot read → ~2 KB covered, not 100% |
| B10 | lock carries pid + timestamp; a lock older than N seconds or with a dead pid is broken with a notice | stale lock → record succeeds with notice |
| B08 | journal with no session refuses instead of writing to `tmpdir()` | `journal_record` before any mount → error naming the fix |
| B20, B21 | `profile`/`marks` take fences from the scanner's fence map | h1 counts agree; three fence variants found |
| B22 | `marks` kinds are an enum; `paragraph` implemented from the scanner's line classes; unknown kind refuses | `paragraph` returns paragraphs, `foo` errors |
| B23 | `strip: html` removes tags generally, keeping inner text (CLI parity) | `<details>`…`</details>` gone, text kept |
| B30 | `outline(within)` defaults depth to the parent's level + 1 and says when nothing is active | within an H1 lists its H2s |
| B18 | `glob` becomes a real matcher or is replaced by `extensions: string[]` | `*.{md,txt}` behaves or is rejected |

**G2 — Closed by construction in the session infrastructure** (modes brief §2–§4; do not patch
separately): B01, B02, B03, B04 (ids never re-rendered), B05 (`workDir` → `session`), B06
(`attach`), B07 (`extend`), B09 (refusal moves into the session profile), B11 (capture policy
per mode), B12 (one producer once the CLI stops writing session trees; until then, the MCP
refuses to attach to a CLI-shaped run).

**G3 — Design decisions, not defects:** B24 (what a heading digest is made of — the structure
brief's claims model decides), B25 (window and segment identity — same), B29 (defaults across
`read`/`batch_read` — brief 04), B31 (the two implementations — D22/D47 already decide: the CLI
is the oracle and receives nothing). B26 and B28 are measurement noise; fix when the scanner is
rewritten under brief 02.

## Report

2026-09-05 — opened from the two v1 reports plus a source audit and a 17-probe battery
(15 confirmed; the `from/to` asymmetry and one over-strict `paragraph` check were not
reproduced as written and are not listed). No source was changed.
