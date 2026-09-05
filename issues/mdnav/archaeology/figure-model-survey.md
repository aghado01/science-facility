# Figure-model survey — legacy `skills/doc-dive/mdnav/mdnav.mjs` as read on 2026-08-17

(Read at `mcp/mdnav/mdnav.mjs`; moved back to `skills/doc-dive/mdnav/` in
`38710e0` the same day, content unchanged. v2 is built in `mcp/mdnav_v2/`.)

**Purpose.** The v2 engine is a rewrite; this document is the homework so the
rewriter never has to rediscover what the current file knows. Every function
gets a *disposition*: **PORT** (copy with intent — it is right), **ABSORB**
(its behavior becomes a claim kind, rule, or query in the new engine),
**REPLACE** (the new engine supersedes it), **FIX** (carries a known defect;
fable-review 2026-07-29 F-numbers). Behaviors the design brief does not
restate are called out as **must-survive**. Line numbers are as of commit
`8d063b8` (the move to `mcp/`); the file has not changed since.

**Baseline (2026-08-17):** 1,165 lines, single ESM file, zero deps, Node ≥ 18.
`test/acceptance.mjs`: 528 lines, 131 assert sites, **130 passed / 0 failed**
(one site is conditional). Suite spawns the binary, generates fixtures in a
temp corpus and a temp work root, and reports counts.

## Anatomy by section

| lines | section | disposition | notes / must-survive |
|---|---|---|---|
| 1–11 | header docstring: design rule (presume about the reading process, never the content), address model | PORT (verbatim into v2 header) | The design rule is the admission test for every v2 function. |
| 13–18 | imports; `SCHEMA = 2`; `LF`/`CR` | PORT; `SCHEMA` → 3 | |
| 20–27 | `warn`, `die` (exit 2), `sha256`, `digestOf` = first 4 hex of sha256(title) | PORT | `@digest` is 4 hex of the **title text**, not the span. Anchors depend on this; do not change. |
| 29–35 | `fmtBytes` (B / KiB / MiB, 2 dp), `fmtNum` (en-US grouping) | PORT | Output-format stability (goldens). |
| 37–48 | `parseArgs`: `--k v`, `--k=v`, bare `--k` = `true`, `-i`; **greedy** — any `--flag` eats a following non-`--` token | **FIX F4** — whitelist value-taking flags; `--strip` is optional-value | Real inventory: value `by depth max-depth extent from glob heading headings kind max min preview run span strip-match to truncate windows within work-dir`; boolean `comp composition help i recursive refresh`. |
| 50–58 | `intFlag(f, names, dflt)` — first present name wins, NaN dies | PORT | `depth`/`max-depth` are aliases (codex spec used `--max-depth`). |
| 60–92 | artifact roots: `stampNow` (UTC `yyyyMMdd_HHmmss`), `ARTIFACT_DIR='.doc-dive'`, `globalPtr` (`$TMP/mdnav/LAST`), `anchorFor` (dir of first target), `workRoot` precedence `--work-dir` > `$MDNAV_WORK_DIR` > `<corpus>/.doc-dive` | PORT precedence; **DROP `globalPtr`** (D39, 2026-08-17: explicit or bust — a `Dnnn` call with no work dir dies naming the override) | Precedence order is tested (suite §hygiene); the two global-`LAST` assertions are replaced, not re-pointed. |
| 94–136 | `workDir({mint, anchor})`: mint = new stamp with deterministic `-2,-3` collision suffix; non-mint follows `<root>/LATEST`, else global `LAST`; `--run <stamp>` pins; creates `documents/`; unwritable root dies naming the override; writes LATEST and global LAST | PORT mint/`-2`/`LATEST`/unwritable logic, **then re-shape** for the D39 layout (`$MDNAV_CACHE/ir/v3/<sha>.json` + work-dir `inventory.json` / `runs/<stamp>/`); no global LAST | must-survive: `-2` suffix rule; in-work-dir `LATEST` as the `--run` default; "say so and name the override" on unwritable. |
| 138–153 | `assertNotDiscoverable`: work dir inside a target's corpus must have a dot-prefixed path segment, else die with the three-line message | PORT verbatim | Tested; the message text is part of the UX. |
| 155–175 | `invPath`/`idxPath`/`readsPath`; `loadInventory` (unreadable → warn + fresh); `saveInventory`; `canonical` (realpath, fallback resolve); `nextId` (max existing `D\d+` + 1) | PORT; paths move to `index/` | must-survive: `canonical` dedupes symlinked/case-variant paths. `nextId` must read the **corpus-scoped** inventory so ids are stable across runs. |
| 177–219 | `NOISE` table: `data-uri` (whole `![](data:…)` wrapper, or bare base64 ≥ 64), `html` (comment **or** single tag), `signed-url` `{re, test, keep}` (target decides via signing params; `!` decides remedy; keep = link label), `image-ref` (opt-in, excluded from `STRIP_ALL`); `STRIP_ALL = ['data-uri','html','signed-url']` | ABSORB → `rules/core.jsonl` entries + `keep` as claim `info`; `STRIP_ALL` → the `default` profile's `strip` | must-survive: signed-url **target test** and **label keep**; image-ref opt-in; the wrapper-vs-bare data-uri distinction. |
| 221–247 | `noiseSpans(buf, from, to, kinds)`: line-scoped regex, byte offsets via `byteLength`, outer-span-wins dedupe (`sort start asc, end desc`) | **REPLACE** by the rule collector; **FIX F1** (no fence state) and multi-line comment leak; the :222 comment is false (**F3**) | must-survive: outer-span-wins dedupe (a data-uri inside an `<img>` tag). |
| 249–260 | `noiseProfile(buf)`: per-kind `{count, bytes}`; headline `ratio` counts only `STRIP_ALL` | ABSORB → census over claims filtered by profile `triage` | must-survive: ratio excludes opt-in kinds. |
| 264–316 | `LINE_KIND` (heading, blockquote, break `-{3,}|\*{3,}|_{3,}`, table, list, html line-start), `SINGLETON` (heading, break never merge), `constructRuns` (fence-aware run builder; **blank line closes a run**) | **REPLACE** by state-machine + line collectors; the run-merging semantics become the `blockquote`/`list`/`table`/`paragraph` region kinds | must-survive: **blank line breaks a run** — the regression that cost a real dive (suite §marks). Fence info = first word of the info string. |
| 318–347 | `COMP_LABEL`; `compositionOf`: noise bytes reassigned **out of** the containing run; top-3 buckets ≥ 5 %, `label##` format | PORT the presentation; compute from claims | must-survive: noise is subtracted from the construct it sits in (a unit that is one PNG must not read "prose 100 %"). |
| 349–359 | `cadence(starts, docBytes)`: needs ≥ 4 starts; median (upper), cv, span fraction | PORT (doccer's `GapCadence` was transcribed from this) | |
| 361–427 | `analyze` passes 1–2: line table with CRLF/lone-LF counts and BOM; YAML frontmatter (`---` at line 0 … `---`/`...`); fence tracking (char + len, closer must be same char, ≥ len, no info string); ATX regex (≤ 3 spaces, 1–6 `#`, closing `#`s stripped from title); setext **suspects** (reported, never promoted); thematic break = exact `---` with blank line before (**F2**); `maxLine`; **unclosed fence → warn** | ABSORB into L0/L1 collectors; F2 fixed by the shared `break` rule | must-survive: setext are *suspects* only (design choice: not promoted); ATX title normalization; `maxLine` stat; unclosed-fence warning text. |
| 429–471 | `analyze` pass 3: `Hnnnn` ids in document order; `digest`; `subtreeEnd` = next heading of level ≤ mine; **PREAMBLE** (`H0000`, level 0) when leading non-blank bytes precede the first heading; **BODY** (`H0000`) when no headings; `counts` h1..h6; `spine` (bytes of H1 lines / total); `breaks.aligned` (`aligned` / `more-h1` / `more-breaks`, null if no breaks) | PORT semantics exactly; ids now over *all* heading claims incl. nested (containment is activation, not numbering) | must-survive: `H0000` conventions; `subtreeEnd`; spine; aligned tri-state. |
| 476–488 | `buildIndex`: sidecar shape `{schema,id,path,bytes,sha256,mtimeMs,encoding,bom,newline,headings,counts,spine,breaks,maxLine,noise,setextSuspects,frontmatter,windows:[]}` | REPLACE with schema-3 doc record (adds claims table; keeps every existing field or derives it) | |
| 490–519 | `ensureIndexed`: fast path when `schema` + `bytes` match → if mtime same trust; else sha256 recheck (touch-but-identical → rewrite mtime, keep); stale → **warn** "anchors may no longer resolve"; unreadable → rebuild; **windows preserved across refresh** when sha matches; inventory append | PORT logic into `SidecarStore`/`MemoryStore` invalidation | must-survive: touched-but-identical does not rebuild; stale warning; windows survive a refresh. |
| 521–528 | `resolveDoc`: `Dnnn` (case-insensitive) or path | PORT | |
| 532–538 | `isActive` (level 0 always active, else ≤ depth); `virtualRoot` | PORT; `isActive` gains the container-transparency conjunct | |
| 540–554 | `segmentsOf`: `Snnnn`, title `SEGMENT`, digest of `seg:<sha>:<start>`, break **terminates** its segment, trailing remainder is a segment | ABSORB into generic boundary basis; keep `S` prefix and digest recipe | must-survive: break terminates (`… reply / --- / next`). |
| 556–575 | `findHeading(spec)`: tolerates `Dnnn:` prefix; `@digest` mismatch → **warn** not die; resolves W (windows), S (segments), `H0000` virtual; unknown → die naming break count for S | PORT | must-survive: mismatch is a warning; the S error names the break count. |
| 577–590 | `unitEnd` (next active heading at depth, else EOF); `spanFor` (`subtree` ignores depth; inactive unit **dies** with the "raise --depth or use --extent subtree" message) | PORT | Tested error text. |
| 592–604 | `activeAt(depth, within)`: within → **children only** (strictly inside, not the parent line); no actives → BODY; leading gap → PREAMBLE | PORT; add `enter` | must-survive: `--within` shows children only (fable review cosmetic: parent's direct body invisible — add a stderr note, don't change output). |
| 606–614 | `partitionOf({depth, by, within})`: `by breaks` refuses `--within`; no breaks → die | PORT; generalize `by` | |
| 618–628 | `logRead`: `{doc, anchors, basis, depth, extent, spans, bytes, elided, elidedSpans}`; basis inferred from anchor prefix (`S`→breaks, `W`→windows, else `d<depth>`) — **cosmetic bug**: `@span` reads log as `d<depth>` | PORT format; fix basis for `@span` (`raw`) | Ledger line shape is what `coverage` reads; keep field names. |
| 630–645 | `loadReads` (tolerant JSONL); `mergeSpans`; `coveredWithin` | REPLACE by `SpanSet.union/intersect/coverage` — same results | Gate: identical coverage numbers on goldens. |
| 649–678 | `vDiscover`: glob → regex (case-insensitive), `--recursive`, **skips dot entries**, explicit files bypass glob, dedupe by `canonical`, mints run unless `--run` | PORT | must-survive: dot-skip is the hygiene mechanism; explicit files bypass glob. |
| 684–694 | `grainOf`: units/median at depths 1–3, `n1/n2/n3~<med>` using the shallowest depth that divides | PORT | Column format is golden. |
| 696–741 | `printInventory`: columns `ID Bytes H1/H2/.. Grain Spine Notes Path`; notes `embedded= signed= html=(>1KiB) imgref= breaks=…=h1-1|≠h1-1 maxline=(>4KiB & ratio<2%) setext? frontmatter windows`; stderr: unaligned advice; ≥ 10 % noise triage naming worst + `--strip-match` hint | PORT verbatim; notes driven by profile `triage` | Every threshold here (1 KiB, 4 KiB, 2 %, 10 %) is golden. |
| 743–751 | `vIndex`: `--refresh`; mints only when given a path and no `--run` | PORT | |
| 753–805 | `vOutline`: depth 1..6; `--within`; `--preview N` (body, whitespace-collapsed, `> ` prefix); `--truncate N` (default full titles — the title *is* the turn in chat exports); `--windows` dispatch; `--by breaks`; per-unit `noise=` (>1 KiB) or `maxline=` (>4 KiB) or `[comp]`; segment titles = first non-`---` line of the segment (600-byte peek); stderr distribution line | PORT format; sources swap to claims | Golden. `noise=` label kept under `default`. |
| 809–853 | `computeWindows`: size default 8192; boundary **always after a newline**; prefer `\n\n`/`\r\n\r\n` within ± size/2 slack, else next LF however far; `UNBROKEN` flag when > 2× size; **persisted into the sidecar** (`idx.windows`); `W` ids with digest of `<sha>:<start>` | PORT; windows become a boundary basis but keep persistence and flag text | must-survive: newline-only boundaries; blob emitted whole; UNBROKEN wording. |
| 855–951 | `vRead`: modes `--from/--to` (merge, anchors `[a,b]`), `--headings a,b,c` (sorted by start, `decorate` when > 1), `--heading`, `--span a..b` (raw); `--strip all|list` + `--strip-match` (adds `custom`); validation of kinds; **warn > 64 KiB of strippable before writing**; decoration `<!-- mdnav Dnnn:Hnnnn -->`; placeholder ≥ 1 KiB `<!-- mdnav: elided <kind> <size> @s..e -->`; `keep` label written in place; ledger with elided spans; stderr summary | PORT modes/flags/thresholds; materialization becomes piece-list + framer (`--frame comment` reproduces this byte-for-byte) | must-survive: warn-before-write; ≥ 1 KiB placeholder rule; label keep; single-anchor reads undecorated **under `--frame comment`** (pilcrow frames all). |
| 953–1005 | `vCoverage`: merged reads − merged elided; `grain={basis:n}`; `--depth`/`--by` list unread/partial anchors, `brief` caps at 16; windows unread; `TOTAL`; stderr hint | PORT format; algebra swap | Golden. Cosmetic: kept citation label counted as elided — fix, note in report. |
| 1009–1045 | `vLocate`: regex per line, `-i`; anchor by binary search over actives at depth (default 6); `--max` cap 50 with cap line; snippet 160 chars; never content blocks | PORT | Golden. |
| 1047–1087 | `vProfile`: `constructRuns` aggregated by kind (heading split by level), cadence columns, `detail` = top-4 info; stderr "evenly spaced" candidates (cv < 0.6 ∧ span > 0.6, paragraphs excluded) | PORT format; census over all claim kinds | Thresholds golden. |
| 1093–1121 | `vMarks --kind`: filter runs, `--min`, `--preview` (72), containing heading, blockquote `> ` prefix stripped in preview; stderr hint to `read --span` | PORT; any kind; `--resolve` added | |
| 1123–1157 | `HELP` | PORT and **FIX F3** (`'all' = data-uri + html` omits signed-url; kinds list stale) | |
| 1159–1165 | dispatch: `VERBS` table; **no `import.meta` guard, no exports** | REPLACE: guard + named exports | |

## Test suite map (`test/acceptance.mjs`) — what each section protects

| lines | section | protects |
|---|---|---|
| 46–117 | fixtures: chat export (H1 per exchange, `---` between, multibyte, fenced heading-like text, reply with own H2), paper (1/15/22 with LaTeX, image, very long line), bare-H1 reply, noisy doc, others | Everything below is over these; v2 goldens are captured over them too. |
| 122–137 | structure: counts, ids, PREAMBLE/BODY | `analyze` pass 3 semantics |
| 139–150 | chat consistency: `aligned` / `more-h1` / `more-breaks` distinguished | tri-state |
| 152–167 | `--by breaks` basis: `Snnnn`, break terminates segment | segmentsOf |
| 169–189 | **partition invariant** (`partitionCheck`) at several depths: concatenated units == source bytes | the load-bearing test; v2 asserts it per basis and per `enter` |
| 191–198 | extents: unit vs subtree; inactive dies | spanFor |
| 200–212 | merge (`--from/--to`) and batch (`--headings`) with decoration; ids derived not assumed | vRead modes |
| 214–228 | coverage: no double count on overlapping reads | mergeSpans |
| 230–234 | locate returns anchors, capped | vLocate |
| 236–270 | windows: newline boundaries; blob emitted whole; does not swallow trailing prose | computeWindows |
| 272–372 | noise: triage notes; `--strip all` elides with placeholder; image-ref preserved; signed-url target rule + label keep; `--strip-match`; elided not counted in coverage; **warning precedes payload** | NOISE + vRead strip path; **F1 tests to be added/inverted here** |
| 374–407 | profile: even cadence candidate; no-heading doc yields none; composition per unit; HTML not mislabelled as embedded | vProfile / compositionOf |
| 409–434 | marks: **blank line breaks a run**; `read --span` reads a marked run | constructRuns regression + raw span |
| 436–499 | artifact hygiene: `.doc-dive` local; rediscovery skips it; new stamp per run; LATEST followed; refusal when visible; `--work-dir` / `$MDNAV_WORK_DIR` precedence; spread documents anchor on first | workDir / assertNotDiscoverable — **must be re-pointed at the new `index/` + run layout without weakening** |
| 500–516 | staleness: touched-but-identical keeps; changed rebuilds with warning; source never modified | ensureIndexed |
| 518–526 | error surfaces: inactive unit, unknown anchor | messages |

Gaps the July review named, still absent: fenced noise, non-`---` breaks, flag-order.

## README (`skills/doc-dive/mdnav/README.md`, 406 lines) — the second figure model

Sections and status: Design rule (keep), Address model (keep; add *enter*),
Verbs table (extend), Reading at grain (keep), Coverage in bytes (keep),
Runtime artifacts (**rewrite** for `index/` + runs), Output discipline
(keep; add REPL/budget rules), Profiling an unknown document + Telescoping
(keep), Grain signatures (keep), What it reports rather than guesses (keep),
Triage (**rewrite** the noise table as the kind table + profiles; keep the
principle text — it is good), `--strip` elides at read time (keep; add
`--only`, framing), Windowing (keep), Sidecar layout (**rewrite**), Tests
(update counts). Known defect: line ~365 broken code fence (F3).

## Known defects carried into v2 as gates

F1 fence-blind noise (+ multi-line comment leak); F2 break definitions
disagree; F3 help/README/comment drift; F4 greedy booleans; cosmetic:
`@span` ledger basis, kept-label counted as elided, `--within` hides parent
body silently. All map to brief gates 4–7, 9, 12, 13 and the F3 doc item.
