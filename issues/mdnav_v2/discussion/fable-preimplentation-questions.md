Doing the M0 knowledge-capture read now: full legacy `mdnav.mjs` and `acceptance.mjs`, then a report that a Chip A agent can cite. Reading the engine first.

Now the acceptance suite — the harness mechanics matter for M0's `MDNAV_BIN` copy.

M0 capture written and committed: [m0-legacy-capture-20260817.md](issues/mdnav_v2/reports/m0-legacy-capture-20260817.md) (`18d6b59`). It reads the whole engine and suite, doesn't repeat the survey, and adds what a rewriter needs that the survey doesn't say. Headlines:

- **The suite is not black-box.** It reads sidecar fields (`counts`, `noise.*`, `breaks.aligned`, `windows`, `headings[0].digest`…), `inventory.json`, `.doc-dive/<stamp>/inventory.json` paths, and depends on the global `$TMP/mdnav/LAST` pointer. So "copy verbatim" is right at M0/M1 and breaks at M2 by *path*. Fix: do the seam refactor (`MDNAV_BIN`, `sidecarOf`, `inventory`, `runDir`) at M0 against the old binary, prove it 130/0, then M2 only touches those helpers. And define `legacyView(doc)` — claims table → today's sidecar shape — as the thing formatters port against; "deep-equals the old sidecar" becomes a stronger M2 gate (16a) than stdout goldens.
- **Golden procedure = instrument `sh()`** with `MDNAV_GOLDEN=record|check`, normalize the two mkdtemp roots, exclude the minting hygiene section, add a battery section. No second harness. M2's expected diff is zero if `discover` keeps printing the run dir.
- **Output contract table** (row formats, stderr texts, every threshold) — the effective spec the goldens freeze.
- **Carry-over edges** the survey misses: fence closer rule (same char, ≥ len, no info); the *two* break definitions (`analyze` needs blank-before and skips frontmatter; `profile` doesn't) — so unifying makes `profile`'s break count *drop* on setext/frontmatter docs; keep-label ledger records the whole span (the real gate-12 bug at line 937); `--from/--to` never decorated; `--within` children-only.
- **Baggage table** — `die`=exit(2) from inside the engine, stdout writes in loops, per-verb `readFileSync`, `NOISE.custom` global mutation, etc., each with its v2 replacement.
- **Predicted M3 deltas on the existing fixtures**: `setext.md profile` (gate 9), and one *unattributed* one — `paper.md` if `math-block` enters the default census/composition — needing a decision before M3.
- **3.5 MB corpus struck**; the named real-doc set is `issues/mdnav_v2/discussion/`.

Now — solutions to the review's issues. Here's where I'd land on each of the ones that need a call from you; the rest are mechanical and I'd just apply.

**Needs your call:**

1. **Blockquote-nested heading ordinals (§3.1).** Two options: (a) accept the one-time shift, name it under gate 8, list affected docs; (b) number re-entry-only headings out-of-band (`H0007.1`) so top-level `Hnnnn` never move. I lean **(b)** — agents' notes and `@digest` warnings both stay meaningful, and it generalizes: any container kind that becomes re-enterable later can't renumber the spine. Cost: `findHeading` grammar gains a dotted suffix.
2. **`S`/`R` anchor ambiguity across bases (§3.5).** Cheapest sound fix: the digest recipe includes the basis (`seg:<basis>:<sha>:<start>`) *and* `findHeading` for `S`/`R` requires the basis (from `--by`, the ledger row, or a `Snnnn@dig` whose digest namespace identifies it). I'd go with **basis in the digest + refuse bare `S`/`R` without `--by`** — no new prefix grammar.
3. **"profile" triple meaning (§3.6).** Rename the disposition. Candidates: `--lens` (short, reads well: "under the chat-export lens"), `--policy`, `--disposition`. I lean **`--lens`**; `profiles/` dir → `lenses/`; token profiles keep "profile".
4. **`math-block` / extra kinds in `default` census and `--comp`.** Keep `default` output to today's kinds (extra kinds behind `profile --all` / a lens `census` list), or accept the delta and name it. I lean **keep default identical** — that's what D1 promises.
5. **P0 framing shape (§4).** Commit P0 to *header line + raw content lines* (compatible with gate 14 and `content: raw`), shrink gates 21/21b to P0's fields + `content_bytes`, add the source-identity cell, and specify `Dnnn:Hnnnn/elided.1` as the only compositional address P0 supports. The codec single-row model moves entirely to the payload-format brief. Agree?

**Mechanical (I'd just apply):** fold M0 into brief 01 as step 0 citing this report; gate 3/5/6 straddles split; gate 16 verb set + stderr scope + strike the corpus; gate 21b arithmetic; brief 04 dependency line; roadmap M3 html-block/flag-order slips; `default.strip` membership written out; fence≠parity rewording; `--strip=<list>` form; relations-cache vs D14; `list-item` bounded/deferred; ledger gains `enter`; F3 gate 22 (generated HELP); survey `--frame` naming; brief 05 essay → one home; D39/D40 rows.

Which way on 1–5?