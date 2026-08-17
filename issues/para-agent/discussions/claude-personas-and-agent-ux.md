---
format: Structural
exported_at: 2026-08-13T18:38:10.2392586Z
exchanges: 18
user_label: Aipithicus
sessions:
  - dc220ba6
models:
  - claude-fable-5
  - claude-sonnet-5
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

# can you dump your para-agent usage notes in memory to a report in `D:\aghado01\science-facility\issues\para-agent`, i want to digest lessons learn and details of how its been working so i can make some updates to the project

I'll pull together the para-agent notes from memory and write the report. Let me read the relevant memory files first.
Memory gathered. Now I'll check the target directory and write the report there.
Done — the report is at `D:\aghado01\science-facility\issues\para-agent\reports\agy-usage-report-20260813_100903.md`, built from everything banked in memory (the `agy-adjutant-pattern` file plus the cross-references in the TeXdig, procurement, and worker-tier memories).

Structure, for your digest pass:

- **§1–2 Charter and mechanics** — agy's role as the primary's cross-examiner, and the full turn pattern that works today (prompt-file-as-argument, JSON receipt parsing, resume chain, short-timeout detach + poll `log`, redirects for byte-exact artifacts).
- **§3 Engagement ledger** — the four engagements to date with session IDs, costs ($2.42–$7.15), turn counts, wall times, and outcomes. Notable: two engagements where every spot-checked claim was exact.
- **§4 Operational lessons** — the nine concrete gotchas: stdin pipe dies in the npm shim, fresh program-spawns die instantly (standing pane only), `wait until:pattern` is unusable for headless turns, Write-granted turns put the payload in the deposit file not stdout, journals survive kills, gemini isn't installed.
- **§5 Triage doctrine** — why verify-or-probe stays mandatory, with the three recorded misses (one refuted claim, one overstated risk, one over-compressed-prompt misread) and the observation that agy's failure mode is _unfound context_, not fabrication.
- **§6 Project-update candidates** — the friction points recast as things the para-agent project could fix: headless completion signaling, program-spawn session holding, prompt delivery, structured receipts, backend configurability, and a blessed deposit-path convention. That section is probably your starting point for the updates.

---

# yea once i settle some of the more low-level mechanics and infrastructure, im going to introduce persona profiles and skills as well as expanded MCP capabilities that borrow from other projects like reposnapshot and mdnav potentially

That sequencing makes sense — the §6 friction points (completion signaling, spawn holding, receipts) are all plumbing that persona profiles and skills would sit on top of, so settling them first means the higher layers don't inherit the workarounds. And the borrows fit naturally from where I sit as the driver: mdnav-style navigation would matter for how agy reads large briefs and how I digest its deposits without pulling whole files into context, and reposnapshot-flavored capability would give reviewer turns a stable view of the repo instead of racing live edits — which touches the multi-agent-concurrency problem too.

One observation from the driver's seat that bears on persona profiles: the "persona" so far has lived entirely in the per-turn prompt plus the tool grant (read-only reviewer vs. Write-granted depositor). If profiles capture that pairing — stance plus tool surface plus deposit convention — that's the part that's currently re-ceremonied every turn.

Let me bank the roadmap note so future sessions know this direction:
Banked. The memory now carries the report location and the mechanics-first-then-personas/skills/MCP-borrows sequencing, so whichever session picks up the para-agent work starts from that plan rather than rediscovering it.

---

# i was thinking for something like mdnav, which is currently more of just a CLI that an agent can use, once i mature it into an MCP, i would want to be able to import that MCP programmatically in the para-agent MCP context, rather than rolling everything into para-agent in some cases because the 'other' mcps can and should stand on their own outside of para-agent, even if many things fit naturally into para-agent

That composition instinct matches what I've seen from the driver's seat, and it's worth noting there are actually two distinct seams where an imported mdnav-MCP would land, and they pull in different directions:

One is the **worker's toolset** — agy's headless claude turns can already be handed an `--mcp-config` at invocation, so once mdnav is an MCP, a reviewer turn could mount it directly without para-agent knowing anything about it. That path costs para-agent zero integration work and is the purest version of "mdnav stands on its own" — para-agent just passes a config through.

The other is **para-agent's own context** — para-agent acting as an MCP client to sibling MCPs and re-exposing or internally using their capabilities. That's where the programmatic import you're describing earns its keep, and it fits para-agent's own artifacts, not just the workers': journals and deposits are exactly the large-markdown-navigation problem mdnav solves. Today when agy leaves a 400-line deposit, I read the whole file into context; a para-agent that could route `body`/`read` through mdnav-style TOC and span addressing would fix that on the driver side, where a worker-side mount can't reach.

The stand-alone principle keeps both seams open, which is the real argument for it — if mdnav got rolled into para-agent, the first seam disappears entirely: nothing outside para-agent could use it, and the codex reading lanes already depend on mdnav living independently. The one thing the composition route does introduce that absorption wouldn't is a lifecycle question — para-agent inherits a dependency on another server being up, versioned compatibly, and discoverable — which lands back in your "settle the low-level mechanics first" sequencing, since that discovery/registration story is infrastructure, not persona-layer.

---

# well this also points to part of the backend coordination. like i would want to ensure that mdnav is available on both sides, in a coordinated fashion as part of a default config with a section for "shared mcps" or somesuch

That framing resolves the coordination problem at the right layer — the failure mode to avoid is the two seams drifting: the worker turn gets handed an `--mcp-config` pointing at one mdnav while para-agent's own client mounts another version or path, and now agy and the driver are navigating the same deposit with different capabilities. A single "shared MCPs" section makes the config the one authority and turns both seams into projections of it — para-agent generates the worker's `--mcp-config` fragment from the same entries it mounts itself, so availability on both sides is coordinated by construction rather than by discipline.

Two things from the field notes that section would naturally absorb:

- **The probe lesson (L1).** The gemini assumption failed because nothing checked what was actually installed. A shared-MCP declaration is the natural home for a startup or per-spawn health probe — declared-but-unreachable becomes a loud, early error on both sides instead of a mid-turn surprise inside a $5 review.
- **The receipt surface (§6.4).** If the shared section is what gets projected into a worker turn, the turn receipt can record which shared MCPs (and versions) were mounted for that engagement. That gives triage provenance for free — "agy said X about the doc's structure" reads differently when you know which mdnav it was reading through.

It also composes cleanly with the persona layer you're planning: personas would then reference shared MCPs by name rather than carrying their own mount details, which keeps the stance/tool-grant pairing declarative and leaves paths, versions, and health as the config's problem — consistent with your mechanics-first sequencing, since the shared section is pure infrastructure the personas later just point into.

---
