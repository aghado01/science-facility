# mdnav_v2 plan review — sequencing, soundness, coherence (Fable, 2026-08-17)

**Scope.** `design/mdnav_v2_design-brief.md` (canon), `planning/roadmap.md`,
`planning/decisions.md` (D1–D38), `briefs/01`–`05`,
`archaelogy/figure-model-survey.md`, and
`reports/gemini-planning-briefs-design-review.md`; cross-checked against the
legacy oracle (`skills/doc-dive/mdnav/mdnav.mjs`, `test/acceptance.mjs`,
`README.md`) and, where a claim's origin mattered, the discussion transcripts
via `mdnav locate`. Read with the legacy mdnav (`discover` → `outline --comp`
→ `read --extent subtree`), work-dir outside the corpus.

**Verdict.** The decomposition is the right shape and the milestone order is
sound: goldens → standalone `SpanSet` → new table fed by ported scanners →
collector swap → containment/queries → exports/paging → framing → cold
review. The five-primitive dependency order holds, the strangler step (M2
before M3) is what makes gate 16 bisectable, and the canon/brief/roadmap/
decisions split by role is clean. **It is not yet execution-ready as
written.** There are gate straddles across phase boundaries (the exact drift
D36 was created to prevent), an unnamed corpus that gate 16 depends on, one
gate whose arithmetic is wrong, one anchor-stability promise that is false
for a common document shape, and brief 05 is still ~50 % design essay whose
gates test more than its stated P0 scope. None of it is deep; all of it is
cheap now and expensive after Chip A starts. Fix list at the end.

---

## 1. Sequencing

**Right.**
- M0 goldens before any engine code; SpanSet standalone with a bitmap oracle
  before wiring; M2 as a plumbing-only milestone with a zero golden delta;
  M3 as the only milestone allowed to move F1/F2 goldens. This isolates
  "did the plumbing change behavior" from "did the collectors change
  behavior" — the single best decision in the plan.
- Chip A = M0–M3 ending on parity is a real seam: everything after it is
  additive.
- M5a/M5b split (settled vs unsettled) is correct, and D37 removing the
  para-agent freeze as a blocker is correct.

**Change.**
- **M0 has no brief.** The golden-capture spec (which verbs, which flags,
  stdout+stderr, pinned work-dir/run, storage under `test/golden/`) exists
  only in `roadmap.md` M0. Chip A's implementer receives briefs 01+02;
  M0's spec is not in either. Worse, brief 01 §Sequencing step 2 says
  "Golden files captured here" (i.e. at M2, after SpanSet), while canon
  §Method 1 and roadmap M0 say *before any engine code*, and gate 16 says
  "captured in M0". Three statements, two positions. → Fold M0 into brief 01
  as step 0 with the full capture spec, and reword step 2 to "goldens
  re-verified byte-identical".
- **M4 (brief 03) is the largest single milestone in the plan** —
  containment + re-entry + `--enter` + relations + Selection + profiles +
  generic basis (`S`/`R`) + `read --only` + `marks --resolve` + `profile`
  census + README. Chip B then continues through 04 and 05 in the same
  chip. Recommend a hard checkpoint (report appended, goldens re-run) after
  03 before 04/05 begin — or split Chip B into B1 (03) and B2 (04+05).
- **Brief 04 says brief 05 "can run before, after, or alongside this phase
  once M4 is done."** Brief 05 says "Depends on: 04" and roadmap M5b says
  "Depends on: M5a". Fix 04's header — 05 fills in the `framed` total that
  04's plan contract leaves opaque, so 05 follows 04.
- **Roadmap M3 lists `html-block` in both L0** (state-machine, CommonMark
  1–7) **and L1** ("blockquote/list/table/`html-block` runs"). Brief 02 has
  it in L0 only. Roadmap slip; drop it from the L1 list.
- **Roadmap M3 lists "flag order" as an M3 suite addition**; the F4 fix
  (`parseArgs` whitelist) and its test (gate 13) are phase 01. Move the
  mention.

## 2. Gate straddles and gate-16 mechanics (fix before Chip A)

**2.1 Gate 3 asserts `container` correctness in phase 01**, but phase 01's
table is populated by *ported legacy scanners*, which have no nesting
concept. Either the clause is vacuous at M2 (every `container` = −1) or it
is untestable there. → Keep "column exists, −1 throughout" in 01; move
"nested claims carry the correct `container`" to 02 (where the state
machine yields regions and region-scoped rules run inside them).

**2.2 Gate 5's second clause — "under a profile with `collect-inside:
{fence: ["data-uri"]}` the URI *is* found with `container` = the fence" —
is assigned to phase 02.** Profiles land in 03 (brief 02 says so itself:
"profiles land in phase 03"). Gate 6's "at any `--enter`" has the same
shape (02 concedes "activation itself is phase 03"). → Split 5 into 5a
(survive-strip, Notes, `profile` counts — 02) and 5b (collect-inside with
container — 03), or give 02 a bare `--collect-inside fence:data-uri` flag
so the policy exists before the profile loader does. Same treatment for 6.

**2.3 The "3.5 MB real corpus" that gate 16 (and gate 8's per-document
delta report) depends on is never named** — not in canon, roadmap, M0,
brief 01, or the survey. The phrase predates the repo's first commit
(README line 43). If it cannot be located, gate 16's real-corpus clause is
unenforceable and its "list which documents changed under 8" evidence
cannot be produced. → M0 must name a path (or a reproducible substitute —
`issues/mdnav_v2/discussion/` is 270 KB and already the M6 dogfood target;
a named set of chat exports would be better) and pin it in the golden
harness. Decide now, not at M0.

**2.4 Golden determinism is unspecified.** M0 captures "stdout **and**
stderr". `discover`'s stderr carries the absolute work-dir path and the
stamp; `discover`'s stdout `Path` column is absolute; the M2 layout change
(`index/` + run dirs) alters the "indexed under …" line. Under gate 16 as
written that is an *unattributable* diff at M2 (attributable set is
5/6/9/12/8 only). → M0: normalize `<workdir>`, `<stamp>`, `<corpus>` in
captured bytes; pin `--run`; state whether stderr is gated or evidence
only; name the M2 layout change as an attributable delta if stderr is
gated.

**2.5 Gate 16 asserts four verbs** (`outline`, `read`, `coverage`,
`locate`) **but M0 captures seven** (+ `discover`, `profile`, `marks`).
Nothing says what the extra three are for. `discover` Notes and `profile`
output *do* change under 5/6/9 — attributably — so they can be gated;
say so, or say they are evidence-only.

**2.6 Ids across successive `discover` runs (gate 3, D15) vs `discover`
goldens.** With a corpus-scoped inventory, the second fixture discovered
into the same work-dir gets `D002…`, where the old binary (per-run
inventory) gives `D001…`. The golden harness must use one work-dir per
(fixture, argv) or `discover` goldens fail for structural, not behavioral,
reasons. One sentence in M0 prevents a confusing first day.

**2.7 Gate 1 says "every pre-existing test passes unchanged, except F1/F2"** —
but the hygiene section (§436–499) is *re-pointed* at the new layout in
phase 01 by the brief's own instruction. Carve it out explicitly
("re-pointed without weakening — every assertion kept, paths updated").

## 3. Soundness

**3.1 Blockquote-nested headings shift ordinals — the "anchors do not
move" promise is false for a common shape.** Today's ATX regex is
`^ {0,3}(#{1,6})…` (mdnav.mjs:387); `> # x` is *not* a heading today.
Brief 03 §4 adds the blockquote heading rule `^ {0,3}> {0,3}#{1,6}\s` on
re-entry, and ids are "ordinal over all heading claims in document order".
So every `> # x` is a **new** claim inserted into the ordinal sequence and
every later `Hnnnn` in that document shifts. Blockquoted headings are
common in chat exports (quoted user turns carrying pasted markdown). The
design session (D010:H0010) made both statements in the same paragraph
without noticing. Html-block-nested headings *are* headings today, so for
those the promise holds; for blockquote (and multi-line-comment-interior
headings, which gate 6 *removes* — a shift in the other direction) it does
not. → State it. Options: (a) accept the one-time shift, name it as a
gate-8/gate-6 delta, and require the gate-16 report to list documents whose
H-numbering moved; (b) number heading claims found only by re-entry
out-of-band (e.g. `H0007.1`) so top-level ordinals never move. (b) is
cleaner for agents' notes and for `@digest` (which warns only when titles
differ); (a) is simpler. Either way the brief must stop saying "nothing
moves".

**3.2 Fences are not prefix-parity toggles.** Brief 02 §3 says
"Toggle-defined regions (fence, `$$`) are prefix-parity over their
delimiter claims". A fence closer must be the *same char*, *≥ opener
length*, and *no info string* — so which lines are delimiters depends on
state (a `~~~` line inside an open ```` ``` ```` fence is content). Naive
XOR over `^ {0,3}(`{3,}|~{3,})` lines breaks gate 7 and gate 16 on the
first mixed-fence document. Doccer's `PrefixParity` is for symmetric
toggles; the fence matcher is a state machine that *emits* matched
delimiter pairs, after which parity is trivially satisfied and only useful
for residue. `$$` is genuinely symmetric. `<!--`/`-->` (listed under
"toggle … as a token pair") is a non-nesting *pair*, not a toggle. →
Reword §3 so an implementer does not reach for the wrong primitive; the
survey's must-survive closer rule (§264–316) is the spec.

**3.3 The `default` strip set after `html` splits.** Today
`STRIP_ALL = ['data-uri','html','signed-url']` where `html` = comment *or*
single tag (mdnav.mjs:199). v2 has `html-tag`, `html-comment`,
`html-block`. Gate 6 requires `html-comment` in `default.strip`. If
`html-block` is *also* in it, then `<div>\ntext without blank line` — the
normal shape in exported transcripts — has `text` swallowed (CommonMark
type 6 ends at the first blank line) where today only the `<div>` tag is
stripped: an unattributable golden delta. Brief 02 says "preserve
`STRIP_ALL`'s exact membership" but membership is now ambiguous. → Write
it: `default.strip = [data-uri, html-tag, html-comment, signed-url]`;
`html-block` is indexed, never stripped by `default`.

**3.4 `profile` (verb) census "over all kinds present" changes output for
every document** — today's rows are construct runs; v2 adds `link`,
`inline-code`, `html-tag`, … rows. Not in gate 16's attributable set;
`profile` isn't in gate 16's verb list either, but M0 captures it and gate 9
compares its break count. → Decide: `default` census prints today's rows,
extra kinds behind `--all` (or a profile `census` list); or name the change
as an accepted delta.

**3.5 `Snnnn` is now ambiguous.** Brief 03: boundary bases address as
`Snnnn`, region bases as `Rnnnn`. `--by break` and `--by pattern:X` both
yield `S0003` for different spans; `findHeading` resolves `S` via one
recipe today and `@digest` mismatch is a *warning*, so an agent re-reading
`D001:S0003@…` under the wrong basis gets the wrong span plus a stderr
line. Same for `R` across `--by fence` vs `--by html-block`. → Anchors
carry their basis (a basis-qualified digest at minimum; a per-basis prefix
or `S<basis>:nnnn` is more legible), or `S`/`R` resolution refuses without
`--by`.

**3.6 Three things are called "profile".** `mdnav profile D001` (census
verb), `--profile chat-export` (disposition data), `profiles/tokens/*.json`
(client token profiles, D29). Agents and users will conflate them; nothing
is built yet, so renaming the disposition (`--lens`, `--policy`,
`--disposition`) costs one find/replace today and saves confusion in every
tool description later.

**3.7 `--strip` optional-value parse rule needs the kind vocabulary at
parse time.** Brief 01: treat `--strip` as value-taking "only when the next
token is `all` or a comma-list whose every member is a known kind or
`@profile`". Kinds are open (`--rules <file>`, `custom:<id>`) and rules
load *after* `parseArgs`. → Simplest: `--strip` bare = all; a list requires
`--strip=<list>` (the `=` form already exists) — no lookahead, no
vocabulary at parse time.

**3.8 Relations "computed at query time (or cached in the sidecar)"**
(brief 03 §2b) vs D14 "views never persisted". Pick one; if cached, name
the invalidation.

**3.9 `list-item` as a region kind with "continuation lines are the
window"** (briefs 01/03) is list parsing — indentation, lazy continuation,
nesting — under a no-parser non-goal, with no gate exercising it. → Defer,
or state "line-run heuristic, no nesting, named limitation" and keep it out
of `default` re-entry.

**3.10 Smaller.** (a) `windows` are persisted in the sidecar today
(must-survive); the new `documents/Dnnn.json` description omits them. (b)
The global `$TMP/mdnav/LAST` pointer is PORT in the survey but odd for a
vendored in-process server — decide. (c) `logRead` gains `enter` alongside
`basis/depth/extent`, and `coverage`'s grain signature too — unstated. (d)
Html-block type 7 "cannot interrupt a paragraph" needs a previous-line-
blank check inside L0 (it must not wait for L1). (e) Should `inline-code`
join the default inert set for inline rules? A `` `data:…` `` span in
backticks is stripped today; changing it is a golden delta — leave `default`
alone, but the question belongs in a profile note. (f) Sidecar JSON with
every `paragraph`/`inline-code`/`link` claim may exceed source size and
make the one-shot CLI's rehydrate slower than a rescan — measure at M2 and
keep an option to not persist inline kinds.

## 4. Brief 05 — coherence

**4.1 Gate 21b's arithmetic is wrong.** "each header line's byte length ==
its char length + 1 (… incl. the 3-byte `…`/`⁂`)". `§`/`¶` are 2 bytes
→ +1; `…`/`⁂` are 3 bytes → +2. As written the gate cannot pass for the
glyphs it names. → "byte length == char length + (glyph UTF-8 bytes − 1)",
or assert `Buffer.byteLength(line) − line.length` equals the glyph's extra
bytes per sigil.

**4.2 21b mixes two framing models.** Clause 1 talks about "row bytes
excluding content" (psr single-row: content on the same physical line);
clause 2 talks about "each header line" being ASCII-plus-one-glyph (the
D18 header-line-then-content-lines model). Under the psr row the content
cell is on the header line and is arbitrarily non-ASCII. → P0 must commit
to an emitted shape (header line + raw content lines is the one compatible
with `content: raw` and gate 14; a codec single-row is the other), and 21b
must be worded for that shape.

**4.3 "P0 deliberately narrow" vs gates 21/21b.** D35's P0 = sigil, source
identity, sub-address, magnitude, content, close. Gates 21/21b additionally
require `k/N`, `span`, `content_bytes`, codec/raw round-trip, elision rows,
a header parser recovering every field. That is the full D18/D32 grammar,
not P0. Either the gates shrink to P0's fields (+ `content_bytes` for the
machine round-trip) or P0 is not narrow — say which. Related: the
illustrative rows omit the **source identity** cell D35 makes mandatory.

**4.4 Under-specified but gate-tested.** (a) Compositional addresses
(`…/elided.1`, `…/fence.2`) — gate 21 requires `read` to accept the elision
address; the grammar exists only as a bullet. (b) The key row is "declared
once per session, never per read" — a one-shot CLI invocation *is* one
read; is the key emitted as line 1 under `--sigils typographic`? 21b's
parser needs it. (c) The Report asks for "the D20 behavioral eval's
result", but D20 is a server-brief gate and there is no server at M5b.

**4.5 Duplication.** Brief 05 §"Stream framing" (12 KiB, self-described as
"ideation, not spec") and roadmap §"After — in-context atomic payload
format" carry the same sketch and the same open-questions list. Two homes
for one essay is the drift D36 was written against. → One home
(`design/payload-format-notes.md` or a canon appendix); brief 05 keeps the
P0 wrapper spec, the vocabulary table, the byte rule, and pointers; the
roadmap keeps five lines.

## 5. Coverage of the F-defects

F1, F2, F4 have numbered gates (4–7, 9, 13). **F3 (help/README/comment
drift) has none** — it is "closed for real" only by M6's human check.
Cheap structural gate: HELP's kinds list and `--strip` help text are
*generated* from the loaded rules/profile at runtime (cannot drift), and the
README's broken fence (~line 365) is fixed at M2. Add as gate 22 (phase 01
or 03).

## 6. Nits

- Survey §855–951 still says `--frame comment` / "pilcrow frames all" (D31
  renamed to `--sigils legacy-comment|typographic|none`).
- Canon lineage item 2: "only commit since: the move to `mcp/`, 8d063b8" —
  stale by `38710e0` (the move back).
- Gate 3: "5 run dirs each containing only `reads.jsonl` + `run.json`" —
  `discover` reads nothing; say `reads.jsonl` is created empty at mint or
  drop it from the assertion.
- Roadmap M2 vs brief 01: `runs prune` is in both; fine — but the `LATEST`
  file at the work-dir root should appear in the gate-3 layout assertion.
- Gemini's mermaid labels the 02→03 edge "Chip B"; Chip A ends at 02, Chip B
  = 03–05.

## 7. On the Gemini report

Accurate as a *cross-reference audit*: the gate→milestone→brief matrix is
correct, and its four watchpoints are correct restatements. It is not a
critical review: it reports zero findings and concludes "without … creating
drift", which is false on §1 (04↔05 dependency, M3 html-block double
listing), §2 (gate 3/5 straddles, unnamed corpus, gate-16 verb set), §3.1,
§3.3, and §4.1 (its own watchpoint 1 states both facts — `…`/`⁂` are 3
bytes, and 21b says +1 — without connecting them). Treat it as
confirmation that the paperwork is internally linked, not that the plan is
sound.

## 8. Fix list (in the order I would apply them)

Before Chip A:
1. Brief 01: add step 0 = M0 (full capture spec from roadmap: verbs, flags,
   stdout/stderr, `--run` pinned, normalization of `<workdir>/<stamp>/<corpus>`,
   one work-dir per (fixture, argv), storage under `test/golden/`); step 2 →
   "re-verified". Name the real corpus or its substitute. (§1, §2.3–2.6)
2. Canon gate 16: name the verb set actually gated; declare stderr scope;
   add the M2 layout change to the attributable list if stderr is gated. (§2.4–2.5)
3. Canon gate 3 / brief 01: `container` correctness → phase 02. Gate 5 → 5a
   (02) / 5b (03); gate 6's `--enter` clause → 03. Gate 1: carve out the
   hygiene re-point. (§2.1, 2.2, 2.7)
4. Brief 02: fence = state machine emitting matched delimiters (parity for
   residue only); `<!-- -->` is a pair; write `default.strip` membership
   explicitly, `html-block` excluded; decide `profile`-verb census under
   `default`. (§3.2–3.4)
5. Roadmap M3: drop `html-block` from the L1 list; move "flag order" to M2's
   list. (§1)

Before Chip B:
6. Brief 03 / D11: replace "anchors do not move" with the actual rule for
   re-entry-only headings (choose (a) or (b) in §3.1); require the gate-16
   report to list documents whose numbering moved.
7. Brief 03: basis-qualified `S`/`R` anchors (§3.5); rename the disposition
   (§3.6); relations cache vs D14 (§3.8); `list-item` deferred or bounded
   (§3.9); `logRead`/coverage grain gain `enter` (§3.10c).
8. Brief 01: `--strip` list requires `=` form (§3.7).
9. Brief 04: header — 05 follows 04; roadmap: checkpoint after 03. (§1)

Brief 05:
10. Fix 21b arithmetic; commit P0 to one emitted shape; shrink or own the
    gate scope; add source-identity cell to the sketch; specify the elision
    address grammar and key-row emission for one-shot CLI; drop the D20
    result from the Report expectation; move the essay to one home. (§4)

Any time:
11. Gate 22 for F3 (generated HELP); survey `--frame` → `--sigils`; canon
    lineage commit; gate-3 `reads.jsonl`/`LATEST` wording. (§5, §6)

I can apply items 1–11 directly to the briefs/canon/roadmap and add a D39
row for the anchor-numbering rule and a D40 for the disposition rename, on
request.
