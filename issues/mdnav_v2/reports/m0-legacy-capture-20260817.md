# M0 — legacy capture: what the old engine knows, what carries, what doesn't

**Status:** M0 result (knowledge capture) · **Read:** full
`skills/doc-dive/mdnav/mdnav.mjs` (1,165 lines) and `test/acceptance.mjs`
(528 lines) on 2026-08-17, both at `38710e0` · **Companion:** the
function-by-function dispositions are in
[../archaeology/figure-model-survey.md](../archaeology/figure-model-survey.md);
this report does not repeat them. It records what a rewriter needs that the
survey does not state: how the suite is actually coupled to the old
implementation, the exact output contract the goldens will freeze, the
behaviors that must carry with their non-obvious edges, the conventions that
must *not* carry, the golden-capture procedure, and the deltas M3 will
produce on the existing fixtures — predicted now so they are attributed, not
discovered.

**On the "3.5 MB real corpus":** it appears once, in the legacy README (line
43, present since the initial commit) and nowhere else — no path, no name.
Treat it as an unsourced claim and strike it from gate 16. The golden set is
the suite's generated fixtures (§3); the named real-document set for the M3
delta report and the M6 dogfood is `issues/mdnav_v2/discussion/` (8 files,
~270 KB, already containing the ugly shapes: 82-H2 transcript, chat exports
with `breaks≠h1-1`, frontmatter, HTML, no-heading docs).

---

## 1. The suite is not black-box — consequences for "copy verbatim"

`acceptance.mjs` spawns the binary, but it also **reads the work-dir
directly**:

| suite helper / assertion | reads | lines |
|---|---|---|
| `idxOf(id)` | `<wroot>/fixed/documents/<id>.index.json` — fields `counts.h1..h3`, `newline`, `headings[0].title`, `headings[0].digest`, `setextSuspects.length`, `breaks.aligned`, `breaks.count`, `windows[]` (`wid,start,end`), `maxLine.bytes`, `noise['data-uri'].bytes`, `noise.html.count`, `noise.ratio`, `noise['image-ref'].count`, `noise.bytes`, `noise['signed-url'].count` | 125, 129–150, 240–270, 290–338, 508, 516 |
| `inv`, `inv2`, per-fixture lookups | `<wroot>/fixed/inventory.json` → `docs[].{id,name,path}` | 126, 148, 252, 289, … |
| `loadLedger()` | `<wroot>/fixed/reads.jsonl` (and `rmSync` of it between coverage tests) | 26, 163, 216, 358 |
| hygiene | `<corpus>/.doc-dive/LATEST`; `<corpus>/.doc-dive/<stamp>/inventory.json` exists; `docs.every(!path.includes('.doc-dive'))`; `docs.length === 1` after rediscovery | 446–458 |
| hygiene | `outline D001` **with no `--work-dir` and cwd = tmpdir** must succeed → the global `$TMP/mdnav/LAST` pointer is load-bearing | 461, 483 |
| hygiene | `--work-dir <corpus>/notes` refused with text `where 'discover' can see them`; `<corpus>/.scratch` accepted; `--work-dir <proj>/.claude/doc-dive` leaves `<library>/.doc-dive` absent; `$MDNAV_WORK_DIR` → `<proj>/envdir/LATEST` exists | 465–488 |

Every other call goes through `sh()` which appends `--work-dir <wroot>
--run fixed` — so all suite reads/indexes land in one pinned run, and ids
accumulate across the suite's `discover .` + eleven `index <file>` calls in
one inventory (D001…D0NN in call order).

**Consequences.**

1. "Copy `acceptance.mjs` verbatim with a configurable binary" is right for
   M0/M1 and wrong at M2: the layout change (`index/inventory.json`,
   `index/documents/Dnnn.json`, run dirs holding only `reads.jsonl` +
   `run.json`) invalidates `idxOf`, the inventory lookups, and hygiene
   assertions 448/452/458 by *path*, not by behavior. Do the seam refactor
   **at M0, against the old binary**, so it is proven behavior-neutral by
   the goldens before any engine code exists: introduce `MDNAV_BIN`,
   `sidecarOf(id)`, `inventory()`, `runDir(root, stamp)`; replace the three
   hygiene path assertions with "the run dir exists" / "the corpus-scoped
   inventory lists only the source". Suite must still print `130 passed, 0
   failed`. M2 then changes only those helpers. (Gate 1's "unchanged" is
   satisfied in spirit — every assertion kept — and the carve-out is
   explicit.)
2. The schema-3 document record must **expose every schema-2 field the suite
   reads** (§4 lists them), either stored or derived. The clean way is one
   function, `legacyView(doc)`, that projects the claims table into exactly
   today's sidecar shape; port every formatter against that shape (they are
   PORT verbatim in the survey) and serialize it as the schema-2-compatible
   half of the sidecar. Then M2's strongest assertion is not stdout goldens
   but: *for every fixture, `legacyView(doc)` deep-equals the old sidecar
   minus `schema`/`mtimeMs`.* Recommend adding this as gate **16a** (M2).
3. ~~The global `LAST` pointer must survive in the CLI.~~ **Superseded the
   same day by D39:** the global `$TMP/mdnav/LAST` pointer is dropped;
   work-dir resolution is explicit or bust (`--work-dir` > `$MDNAV_WORK_DIR`
   > path-anchored default only when the call carries a path). The two
   suite assertions at lines 461/483 are replaced by "a `Dnnn` call with no
   work dir dies naming the override". Likewise the "sidecar layout" in item
   2 is now the D39 layout (content-addressed IR under `$MDNAV_CACHE`;
   inventory + `runs/<stamp>/` under the work dir), and the seam in item 1 is
   `--json` on `discover`/`index` (D40) rather than a filesystem helper —
   the suite asks the binary, not the disk.

## 2. Golden capture — procedure

The suite already *is* a deterministic call sequence against pinned paths.
Do not build a second harness; **instrument `sh()`**:

- `MDNAV_GOLDEN=record` → every `sh()` call appends
  `{n, argv, stdout, stderr, code}` to `test/golden/suite.jsonl` (stdout as
  base64 when `binary`); `MDNAV_GOLDEN=check` → compares and reports the
  first differing call by index and argv. Same file for the old binary and
  the new; a check run under `MDNAV_BIN=<v2>` *is* gate 16.
- **Normalize before compare:** the two `mkdtemp` roots (`root` appears in
  the `Path` column and in error text; `wroot` in `indexed under …`) →
  `<ROOT>` / `<WROOT>`. Nothing else in the suite's pinned calls is
  time-varying. The hygiene section (`raw()`, mints real stamps) is
  **excluded** from goldens — its assertions are behavioral and stay in the
  suite.
- **Extra battery** (appended as a final suite section, also through
  `sh()`, so it is recorded the same way): for each base fixture — `outline`
  at depths 1–3, `--by breaks` where breaks exist, `--comp`, `--windows
  2048`; `read --heading` of each depth-1 unit with and without `--strip
  all`; `read --from/--to` of the first two units; `coverage --depth 2`;
  `locate 'the' --depth 2`; `profile`; `marks --kind fence|blockquote|table|
  list|paragraph`. Plus the *real-document set* (§0) run through the same
  battery, so the M3 delta report has real shapes to point at.
- **What is gated:** stdout bytes always; stderr after normalization; exit
  code. `discover` prints column widths computed over the *whole call's*
  rows (line 719–723), so goldens are per call, never per document.
- **Storage:** `mcp/mdnav_v2/test/golden/suite.jsonl` (+ `battery.jsonl`),
  captured once against `MDNAV_BIN=skills/doc-dive/mdnav/mdnav.mjs`,
  committed. Recapture is a deliberate act with a named reason (a gate that
  inverts).
- Under this design, **M2's expected diff is zero** — provided v2 keeps
  printing the *run dir* in `discover`'s "indexed under" line (today
  `<wroot>/fixed`), which it should: that is the provenance the reader wants.

## 3. Fixtures the goldens run over (what each exercises)

`chat.md` (CRLF; 5 H1 exchanges + `---`; fenced `# comment`; reply H2;
multibyte), `paper.md` (1/15/22; `$$` math blocks; `![figure](./fig.png)`
image-refs; a 1.6 KB single line), `preamble.md`, `headingless.md`,
`deep-start.md` (first heading H2), `corrupt-chat.md` (`more-h1`),
`setext.md` (2 suspects), `unlabelled.md` (`more-breaks`, 2 breaks),
`blob.md` (12 KB unbroken line + multibyte tail), `noisy.md` (`<div>`,
`<img …/>`, 4 KB data-URI, `<`/`>` in prose), `remote-img.md`, `signed.md`
(2 presigned + 1 permalink), `huge-img.md` (200 KB data-URI), `cadence.md`
(12 turns, fence×12, blockquote×3), `htmlish.md`, `quotes.md`. Absent, and
therefore **not** protected by goldens: frontmatter, multi-line HTML
comments, `***`/`___` breaks, non-`---` setext, fenced noise, nested `>
#`, `<details>`, footnotes, link-refs, `~~~` fences, mixed fence chars,
tabs, BOM. Every one of these needs a new fixture in the phase that
introduces its kind — none can be a silent behavior.

## 4. The output contract (what the goldens freeze)

Row formats — reproduce byte-for-byte; the suite regex-matches most:

| verb | stdout row | notes |
|---|---|---|
| `discover`/`index` | `ID    Bytes  H1/H2/..  Grain d1/d2/d3  Spine  Notes  Path` header, then `${id.padEnd(5)} ${bytes.padStart(wB)}  ${lv.padEnd(wL)}  ${grain.padEnd(wG)}  ${spine.padStart(wS)}  ${notes.padEnd(wN)}  ${path}`; blank; `${n} document(s) indexed under ${wd}` | widths = max over rows (min 5/8/5/5); `lv` = `h1/h2/…/h6` with trailing `/0`s stripped; `spine` only when h1 ≥ 2 else `—`; `Notes` column omitted entirely if every note is empty |
| `outline` | `[${hid}@${digest}] ${lvl}  unit=${fmtBytes.padEnd(9)} subtree=${fmtBytes.padEnd(9)}${flag} ${title}` | `lvl` ∈ `H1`…`H6`, `--` (H0000), `S ` , `W `; flag = `  [comp]` if `--comp`, else `  noise=X(N%)` if STRIP_ALL bytes in unit > 1024, else `  maxline=X` if longest line > 4096, else empty; `--preview N` adds `          > ${text}` (reads `bodyStart..+N*4` bytes, collapses whitespace, slices N chars, `…` if longer) |
| `outline --windows` | `[${wid}@${digest}] W   unit=${fmtBytes.padEnd(9)} bytes ${s}..${e}` + `  UNBROKEN — no line break to split on` when size > 2×requested | |
| `read` | literal bytes; `--headings` with > 1 span prepends `<!-- mdnav ${id}:${hid} -->\n` per span; elision ≥ 1024 B writes `<!-- mdnav: elided ${kind} ${fmtBytes} @${s}..${e} -->` (no newline); kept label written in place | `--from/--to` is one span → **never decorated**; single `--heading` undecorated |
| `coverage` | `${id}  ${bytes.padStart(9)} / ${total.padStart(9)} B  ${pct.padStart(5)}%  reads=${n.padStart(3)}  grain={${basis:count …}}[  elided=X]  ${basename}`; then `      unread @depth${d} (${n}): ${≤16 ids}[ … +${k} more]` / `      partial …` / `      complete @depth${d}`; `      unread windows: …`; `TOTAL  ${cov} / ${tot} B  ${pct}%` | `@breaks` when `--by breaks`; grain key is the ledger's `basis` (`d1`, `breaks`, `windows`) |
| `locate` | `${id}:${hid}@${digest}  L${line}  ${text.trim().slice(0,160)}`; `${id}  … capped at ${cap} matches (raise with --max)` | anchor = deepest active heading (default depth 6) at or before the line start, PREAMBLE included |
| `profile` | `\n${id}  ${basename}  ${fmtNum(bytes)} B\n\n  construct      runs      bytes      %   median gap      cv   detail\n` then `  ${kind.padEnd(13)}${n.padStart(5)}${bytes.padStart(11)}${pct.padStart(7)}%${median.padStart(13)}${cv.padStart(8)}   ${info}` | rows sorted by bytes desc; heading rows keyed `heading h${level}`; `detail` = top-4 `${info||'·'}×${n}`; `—` when cadence null (< 4 starts) |
| `marks` | `${start.padStart(8)}..${end.padEnd(8)} ${fmtBytes.padStart(9)} ${lines.padStart(3)}L  ${(id:hid|id:—).padEnd(12)} [${info}] ${preview}` ; `(no ${kind} runs[ of N+ bytes])` | preview = first `N*4` bytes, `^ {0,3}>[ \t]?` stripped per line, whitespace collapsed, `N` chars, default 72; containing heading excludes H0000 |

stderr texts the suite matches (keep verbatim): `does not match current
heading digest`, `does not match current segment digest`, `not active at
depth`, `index is stale (source changed) — rebuilding`, `where 'discover'
can see them`, `carries ${X} of embedded data or HTML markup`, `Re-run with
--strip all`, `evenly spaced across the document: ${kinds}`, `unclosed code
fence — headings after it were treated as fenced content`, `no thematic
breaks to partition on`, `--to anchor precedes --from anchor`, `--strip
expects all or a comma list of: …`, `--span expects <start>..<end> in
bytes`, `is outside 0..${bytes}`. Exit code 2 on every `die`.

Thresholds and constants (all golden): placeholder ≥ 1024 B; `noise=` >
1024; `html=` note > 1024; `maxline=` > 4096 (`discover` additionally
requires `noise.ratio < 0.02`); triage stderr ≥ 10 %; read-warn > 65,536 B
of STRIP_ALL bytes; bare base64 ≥ 64 chars; `brief` list cap 16; `locate`
cap 50, snippet 160; `marks` preview 72; segment title = first non-empty,
non-`---` line in a 600-byte peek; setext suspect text 120 chars; window
default 8192, slack size/2, `UNBROKEN` > 2×; cadence needs ≥ 4 starts,
candidate = cv < 0.6 ∧ span > 0.6, paragraphs excluded; composition top-3
≥ 5 %, label `${name}${round(pct)}`; digest = first 4 hex of
sha256(title); segment digest of `seg:${sha}:${start}`; window digest of
`${sha}:${start}`; stamp `yyyyMMdd_HHmmss` UTC, collision `-2`, `-3`;
`fmtBytes` B / KiB / MiB 2 dp; `fmtNum` en-US grouping; `grainOf` →
`${n1}/${n2}/${n3}~${fmtBytes(med) minus space and 'iB'}` using the
shallowest depth with > 1 unit.

## 5. Carry-over — behaviors and their non-obvious edges

Grouped by area; the survey names most of these, this adds the edges a
rewrite would otherwise get wrong.

**Lines and bytes.** Line table from `indexOf(LF)`; content end excludes a
trailing CR; `newline` = `mixed|CRLF|LF` from counts; BOM detected and
recorded but **not skipped** for offsets (byte 0 is the BOM). Every offset
is a byte offset; text is decoded per line for recognition only.

**Headings.** ATX `^ {0,3}(#{1,6})(?:[ \t]+(.*?))?[ \t]*$`; title = group 2
with trailing ` #+` stripped and trimmed (so `#` alone is a heading with an
empty title, digest of `""`); **scan starts after frontmatter**; lines
inside a fence skipped; `subtreeEnd` = start of the next heading with level
≤ mine (O(n²) today — make it a stack). `H0000` synthesized in *two* places
today (sidecar `headings[0]` when preamble/body; `virtualRoot()` in
`activeAt`/`findHeading`) — one source in v2. `counts` exclude level 0.
`spine.bytes` = Σ (bodyStart − headingStart) over H1 lines.

**Fences (both trackers, identical rule).** Opener `^ {0,3}(`{3,}|~{3,})(.*)$`
when not in a fence — *any* info string; closer requires **same char, length
≥ opener, empty info**. Everything else while open is content, including
fence-looking lines of the other char. Unclosed → warn once, headings after
it are content. `constructRuns` records fence info = first whitespace-
delimited word.

**Breaks — the two definitions the goldens encode (F2).** `analyze`: exact
`---` (trimmed) **and** previous line blank (or first line after
frontmatter). `constructRuns`/`profile`: `^ {0,3}(-{3,}|\*{3,}|_{3,})\s*$`
with **no** blank-line condition and **no** frontmatter skip. So a setext
`----` underline is a `break` run to `profile` and a setext suspect to
`analyze`; frontmatter `---` lines are `break` runs to `profile`. The v2
shared rule (brief 01) takes `constructRuns`' character set and `analyze`'s
blank-before condition — so `profile`'s break count *drops* on setext-ish
and frontmatter docs and rises on `***`/`___` docs. Both directions are
gate-9 deltas; predict them (§7).

**Segments.** Break **terminates** its segment (`ends` = byte after the
break line); trailing remainder is a segment; `--within` refused with `--by
breaks`; no breaks → die. Ids `S0001…`, title `SEGMENT` in the sidecar but
the *outline row* title is the first real line (600-byte peek).

**Activation and extents.** `isActive` = level 0 or level ≤ depth;
`--within X` returns **children strictly inside X's subtree** — X's own
heading line and direct body are *not* a unit (the July cosmetic; add a
stderr note in v2, do not change output); no actives → one BODY; leading
gap → PREAMBLE unit. `--extent subtree` ignores depth; `unit` on an inactive
heading dies. `spanFor(unit)` end = next active heading at depth or EOF.

**Windows.** Boundary is always after a newline; prefer `\n\n` /
`\r\n\r\n` inside ± size/2 of the target, else the next LF however far;
`within` restricts to a subtree; **persisted into the sidecar** and
**preserved across a rebuild when sha matches**; `Notes` shows `windows xN`.
Windows are addressable by `--heading Wnnnn` and count in coverage.

**Anchors.** `findHeading` accepts `Dnnn:Hnnnn@dig`, `Hnnnn`, lowercase;
resolves H, then W (from sidecar windows), then S (recomputed), then virtual
`H0000`; digest mismatch → **warn**; unknown S → die naming the break count.
`--span a..b` bypasses anchors, logs anchor `@a..b`.

**Noise (today's inline kinds).** Regexes and `test`/`keep` closures at
lines 193–213 carry over as `rules/core.jsonl` entries + `info`. Edges:
`data-uri` wrapper form `![alt](data:…)` vs bare `data:…;base64,` ≥ 64;
`html` = single-line comment *or* single tag; `signed-url` matches every
`[]()`/`![]()`/bare URL and the **target test** decides (`X-Amz-*`,
`X-Goog-Signature`, `Signature=`/`sig=` ≥ 16 chars); **keep** = link label
for `[label](signed)`, empty for `![]`; `image-ref` excludes `data:` and is
opt-in. `noiseSpans` is **line-scoped** (the F1 cause) and **outer-span-wins**
after `sort(start asc, end desc)`; `vRead` additionally skips any span
starting before the write cursor. `--strip-match` compiles into a global
`custom` kind. `--strip` bare = `all` = STRIP_ALL; a list is validated
against NOISE keys; `custom` is added when `--strip-match` is present even
without `--strip`.

**Keep-label accounting (gate 12's actual bug).** When a `keep` label is
written, `elided += size − keepBytes` (correct) but `elidedSpans` gets the
**whole** span (line 937) — so `coverage` subtracts bytes the reader did
see. Fix = record the elided *sub-span* (or the label bytes) in the ledger.

**Warn-before-write.** Unstripped reads compute STRIP_ALL bytes over the
spans first and warn on stderr when > 64 KiB, *before* the first stdout
write. Stripped reads never nag.

**Ledger.** `{doc, anchors, basis, depth, extent, spans, bytes, elided,
elidedSpans}`; basis inferred from `anchors[0][0]` (`S`→`breaks`,
`W`→`windows`, else `d${depth}`) — so `--span` reads log `d1` (cosmetic;
v2 passes basis explicitly, `raw`). `coverage` = `merge(spans) −
merge(elidedSpans)` per doc; `grain=` histogram over `basis`.

**Composition (`--comp`).** Noise bytes are subtracted from the construct
run that contains them and re-added under their own label (`data`, `html`,
`link`, `img`) — a one-PNG unit reads `[data99]`, never `[prose100]`.
`COMP_LABEL` maps `paragraph→prose fence→code blockquote→quote list→list
table→tbl html→html heading→head break→rule`.

**Runs (`constructRuns`).** `LINE_KIND` precedence: heading, blockquote,
break, table, list, html; `heading`/`break` never merge; a blank line
**closes** the current run (the regression the suite guards); fence lines
extend a fence run; everything else is `paragraph`. Note `- - -` is `list`
here (break requires contiguous chars) and `1) item` is `list`.

**Profile.** Aggregates runs by kind (headings split by level by re-parsing
the first 12 bytes); `cadence` over run starts; even-candidate rule; `detail`
histogram of fence infos.

**Sidecar invalidation.** Fast path: `schema` matches ∧ `bytes === size` ∧
`mtimeMs` equal → trust; else sha256 → if equal, rewrite mtime and keep;
else warn "stale" and rebuild, **preserving `windows`** when the new sha
equals the old. Unreadable sidecar → rebuild. `nextId` = max existing + 1
(never reused). Inventory entry matched by canonical path.

**Discover.** Glob → case-insensitive regex; default `*.md`; **top-level
directory contents are always visited, subdirectories only with
`--recursive`**; dot entries skipped at every level; explicit file targets
bypass the glob; dedupe by `realpath`; die on zero matches; mints unless
`--run`. `--recursive` is presence-tested (`!== undefined`), which is why the
greedy parser turns `discover --recursive .` into "needs at least one file"
(gate 13).

**Work dir.** Precedence `--work-dir` > `$MDNAV_WORK_DIR` > `<anchor>/.doc-dive`
where anchor = directory of the *first* target; non-mint verbs follow
`<root>/LATEST`, and with no root at all follow `$TMP/mdnav/LAST`; `--run
<stamp>` selects (and creates) a run dir; unwritable → die naming the
override; the refusal guard requires a dot segment in the path *relative to
the corpus*, backslashes normalized.

## 6. Baggage — do not carry (and what replaces it)

| today | why it must not carry | v2 |
|---|---|---|
| Three scanners (`analyze`, `constructRuns`, `noiseSpans`) with three notions of extent, run per verb | The F1/F2/F3 cause; every verb re-reads and re-scans | One claims table per doc, built once, verbs are queries (canon) |
| `NOISE` object of mixed shapes (`RegExp` \| `{re,test,keep}`), `NOISE.custom` **mutated globally** by `--strip-match`, `STRIP_ALL` array | Hard-coded binary; global mutable state | `rules/core.jsonl` + `keep`/`test` as rule `info`; `default` profile owns the strip set; `--strip-match` = one-off rule |
| Line-scoped noise scan | Cannot see multi-line constructs; blind to fences | Region-scoped rule execution over `Total \ inert` |
| `analyze` returns structure **and** stats (`spine`, `aligned`, `maxLine`, `newline`, `bom`) from one pass | Couples what should be independent queries | Stats are cheap queries over claims + line table; the *output* keeps the same fields via `legacyView` |
| `die` = `process.exit(2)` from anywhere, incl. inside `analyze` and `findHeading`; `warn` writes stderr from inside the scanner | Un-importable; a server cannot exit; residue (unclosed fence) is a fact, not a side effect | Engine throws `MdnavError{code, message}` and returns residue; the CLI shim maps to exit 2 + the same stderr text |
| Verbs `process.stdout.write` inside loops; formatting interleaved with computation | No piece list → no `--only`, no plan, no framing | Verbs return rows / a piece list; one presenter writes; `legacy-comment` framer reproduces today byte-for-byte |
| Every verb `readFileSync(idx.path)` itself | Repeated IO; server can't own buffers | `Corpus` holds buffers; CLI opens-queries-closes |
| `ensureIndexed` = read + invalidate + build + window-preserve + inventory mutation + sidecar write, in one function | Untestable seams | Store interface (`MemoryStore`/`SidecarStore`) with a `get(path)`; invalidation policy separate |
| Per-run `documents/*.index.json` + per-run `inventory.json`; pretty-printed JSON | Accretion (D15); ids per run; ~3× bytes | Corpus-scoped `index/`, compact columnar; run dirs hold only ledger + `run.json` |
| `computeWindows` writes the sidecar directly from a verb | Verb mutating the index | Windows are a persisted partition owned by the store |
| `logRead` inferring basis from the anchor prefix | Wrong for `--span`; wrong for generic bases | Basis (and `enter`) passed explicitly |
| `H0000` synthesized in two places | Drift risk | One `virtualUnits(doc, depth, within)` |
| `parseArgs` greedy value-taking | F4 | Whitelist (brief 01) |
| Hand-written `HELP` listing kinds | F3 | Kinds/strip lists rendered from the loaded rules + profile |
| `subtreeEnd` O(n²) | Fine at 82 headings, silly at 5,000 | Stack |
| `activeAt` recomputed per call in `grainOf` ×3, `outline`, `coverage`, `locate` | Cheap today; a server memoizes | Memoize by `(digest, depth, enter, within)` |

Conventions that *do* carry although they look like baggage: the
`<!-- mdnav … -->` comment sigil (it is the CLI default forever); `--depth`/
`--max-depth` alias; `-i`; `--k=v`; single-file zero-dep; stderr for
everything diagnostic; the exact `die` messages.

## 7. Predicted golden deltas at M3 (so they are attributed, not discovered)

On the suite's own fixtures, under `default`, after the collector swap:

| fixture | verb | delta | attribute to |
|---|---|---|---|
| `setext.md` | `profile` | `break` row disappears (today 2 runs from setext underlines; unified rule requires blank-before) | gate 9 |
| any fixture with frontmatter (none today; add one) | `profile` | frontmatter `---` no longer `break` runs | gate 9 |
| `paper.md` | `profile`, `outline --comp` | **if** `math-block` becomes a census/composition kind: paragraph bytes drop, a `math-block` row / label appears | **unattributed** — decide before M3: keep `default` census/composition to today's kinds (extra kinds behind a flag or profile list), or name it |
| `noisy.md`, `htmlish.md` | all | none expected — `<div …>` / `<img …/>` become html-block *and* html-tag claims; `default` strips only html-tag → same bytes | — |
| `chat.md` `paper.md` `preamble.md` `headingless.md` `deep-start.md` `corrupt-chat.md` `unlabelled.md` `blob.md` `remote-img.md` `signed.md` `huge-img.md` `cadence.md` `quotes.md` | `outline`, `read`, `coverage`, `locate` | none | — |

On the real-document set (`issues/mdnav_v2/discussion/`): expect `discover`
Notes changes where multi-line comments exist (`html=` grows — gate 6),
`profile` break counts on the transcript with `breaks=38` (gate 9), and
`Hnnnn` renumbering wherever `> # …` occurs (gate 8 — see the plan review
§3.1; the report must list them).

## 8. Corrections and additions to the survey

- §855–951: `--from/--to` is *never* decorated (one span); only `--headings`
  with > 1 span decorates. `--frame comment` naming is stale (`--sigils
  legacy-comment`, D31).
- §177–219: `noise` in the sidecar is `noiseProfile(buf)` over the whole doc
  at index time with *all* kinds; `Notes` and `ratio` come from the sidecar,
  not recomputed — under v2 this is the census over claims filtered by the
  profile's `triage`, serialized into `legacyView.noise`.
- §264–316: `constructRuns` does **not** skip frontmatter and its `break`
  has no blank-before condition (§5 above) — the second half of F2.
- §592–604: `activeAt(within)` excludes the parent's own line/body — stated
  as "children only", but note the consequence: `read --heading X --extent
  unit` and `outline --within X` cover different byte sets by design.
- §618–628: `--span` reads log basis `d${depth}` (survey says so) — and
  `depth` defaults to 1 there, so the ledger claims a grain that was never
  used.
- §436–499 (hygiene) additionally depends on the **global `LAST` pointer**
  (line 461/483) — must-survive in the CLI.
- Missing from the survey: `intFlag` first-name-wins; `--preview` reads
  `N*4` bytes; `marks` `containing()` excludes H0000; `discover` visits
  top-level dir contents without `--recursive`; `outline --windows` requires
  `--within` to be a *heading* anchor (`findHeading`), so windows can nest
  under a unit but not under a segment.

## 9. What M0 delivers, restated

1. `mcp/mdnav_v2/test/acceptance.mjs` = legacy suite + `MDNAV_BIN` +
   `sidecarOf`/`inventory`/`runDir` seams + `MDNAV_GOLDEN=record|check` in
   `sh()` + the extra battery section; **130/0 against the old binary**.
2. `test/golden/suite.jsonl`, `battery.jsonl` captured against the old
   binary with `<ROOT>`/`<WROOT>` normalization; committed.
3. This report (the knowledge capture) + the survey (dispositions).
4. The predicted-delta table (§7) handed to the M3 implementer as the list
   of diffs that *may* appear and the one that needs a decision first.
