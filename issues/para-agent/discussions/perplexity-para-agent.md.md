<img src="https://r2cdn.perplexity.ai/pplx-full-logo-primary-dark%402x.png" style="height:64px;margin-right:32px"/>

# so i built this thingamajig where im having claude control AGY cli via a tmux pane with an mcp that effectively gives my claude agent a persistent assistant that can be controlled interactively via an MCP

That’s a clean architecture: Claude as the control plane, AGY as a long-lived worker in a tmux pane, and MCP as the interactive I/O bus so the secondary agent stays stateful across turns instead of dying with each tool call.[^1_1][^1_2]

## What you built

AGY (Antigravity CLI) is Google’s terminal coding agent — same family as Claude Code / Codex — and the documented way to drive it multi-turn is exactly this pattern: launch under a PTY, park it in tmux, then `capture-pane` / `send-keys` for read/write.[^1_3][^1_2]

Wrapping that behind MCP is the interesting part. You’re not just shelling out to `agy`; you’re giving Claude a **persistent subordinate** with:

- Session continuity (context, cwd, auth, in-flight work survive across Claude turns)
- Structured tools instead of raw tmux string munging
- Interactive control — Claude can poll output, inject input, wait on prompts, and resume

That’s the same class of design as `tmux-bridge-mcp` and `tmux-mcp`, but aimed at a second agent harness rather than generic pane chat.[^1_4][^1_1]

## Why it fits your stack

You’ve already been deep in Claude Code MCP, context-mode token economy, and staying inside the official harness rather than swapping runners.  Driving AGY through MCP keeps Claude as the primary loop while AGY becomes a specialized backend you can delegate to — code edits, long runs, YOLO-style no-confirm modes — without burning Claude’s context on every subprocess.[^1_5]

tmux is doing the real persistence work: detachable session, no tool-timeout death, and a pane Claude can observe without owning the process tree.[^1_6][^1_7]

## Design tension worth watching

The hard edge of this pattern is usually **synchronization**, not plumbing:

- Knowing when AGY is idle vs mid-generation (prompt detection / quiet-window heuristics)
- Separating “type text” from “send Enter” so partial input doesn’t race
- Whether the MCP exposes high-level ops (`ask_agy`, `read_last_reply`) or low-level pane primitives
- How much AGY’s own MCP/tool surface you want Claude to reach *through* AGY vs call directly

If you want to dig in, the highest-leverage detail is usually how you decided idle/completion detection — that’s what makes “persistent assistant” feel interactive instead of fire-and-hope.
<span style="display:none">[^1_10][^1_11][^1_12][^1_13][^1_14][^1_15][^1_8][^1_9]</span>

<div align="center">⁂</div>

[^1_1]: https://github.com/howardpen9/tmux-bridge-mcp

[^1_2]: https://hermes-agent.nousresearch.com/docs/user-guide/skills/optional/autonomous-ai-agents/autonomous-ai-agents-antigravity-cli

[^1_3]: https://github.com/google-antigravity/antigravity-cli

[^1_4]: https://mcpservers.org/servers/nickgnd/tmux-mcp

[^1_5]: https://dev.to/gde/using-googles-new-ai-command-line-assistant-antigravity-cli-agy-and-yolos-no-confirmation-mode-10d

[^1_6]: https://www.reddit.com/r/ClaudeAI/comments/1lp9c7p/my_breakthrough_workflow_multiagent_collaboration/

[^1_7]: https://www.blle.co/blog/claude-code-tmux-beautiful-terminal

[^1_8]: https://antigravity.google/docs/cli/using

[^1_9]: https://runpane.com/tmux-agent-managers

[^1_10]: https://codelabs.developers.google.com/sdd-agy-cli

[^1_11]: https://learn.arm.com/install-guides/antigravity/

[^1_12]: https://github.com/rhel-lightspeed/command-line-assistant

[^1_13]: https://antigravity.google/docs/cli/overview

[^1_14]: https://skillsllm.com/skill/tmux-mcp

[^1_15]: https://www.reddit.com/r/AISEOInsider/comments/1tod9n4/how_to_build_anything_free_with_antigravity_cli/


---

# i just had claude review a document on token waste from an detailed exported claude chat transcript with a bunch of toolcalls and tool results and thinking etc, first turn with agy, agy didn't get enough context. then i told claude to push back and add more framing context, agy concedes it previous mistakes and adds a correction to claude `agy's second pass is substantially better — including catching an error of its own I'd missed. Verifying the claim that corrects me before I relay it.

Confirmed, and it turns up something better than either of us had.
agy conceded both, and caught an error of mine
It dropped tool results from its stored-content total — but the deeper fix was the divisor. I used 3.6–4 chars/token throughout this session. agy calibrated against per-turn context deltas and got 2.6–2.7 for this mix of code, JSON, and file content, noting the ratio is bounded above because injection adds tokens without adding chars. That's sound method, and it means my "unexplained gap" was partly my own arithmetic:
stored content 343,205 chars ÷ 2.65 = 129,511 tok
context growth                        180,397 tok
residual (unstored injection)          50,886 tok   (28%)

The correction that matters — and it's better than either of our versions
I said attachments were part of the 180K climb. Wrong. They're almost entirely baseline, and they're itemized:
Attachment (all at 03:18:01, pre-turn-1)chars
skill_listing
11,166
deferred_tools_delta
5,927
agent_listing_delta
2,910
mcp_instructions_delta
1,507
total
21,510
Plus exactly nine 423-char task_reminder records mid-session — 3,807 chars total, agy's figure to the character.
So ~21.5K chars ≈ 6–8K tokens of roster material, paid on all 56 turns — call it 350–450K tokens, 4–5% of the session.
Which falsifies something I told you earlier
I said the 88% harness floor was "not controllable." That's now measurably false. A large, itemized slice of it is registration-driven: how many skills are installed, how many MCP servers are connected, how many agent types are defined. skill_listing alone is 11,166 chars — the single largest preamble line item in the session, larger than the global CLAUDE.md and MEMORY.md combined.
That's the actionable version of the point I fumbled three times: not "trim CLAUDE.md," not "the floor is fixed," but trim the rosters. Uninstall skills you don't use in a given workspace; disconnect MCP servers you don't reach for. That's the only preamble lever with real mass.
agy's behavioral answer
"Billed-once means it isn't a context problem — it's a per-turn tax, and turn count is the multiplier. t22 spent 13,318 output tokens to emit a 976-char Edit."
Rule: separate deliberation turns from dispatch turns. Reason once over the full change set, then emit edits as batched, low-deliberation turns.
That converges with the sweep-then-edit rule from the input side, arrived at independently from the output side. Both meters point at turn count.
What the exercise cost
\$1.84 across two rounds, 13 agy turns, ~5 KB into my context. The chain caught errors in both directions — agy's duplicate-read inflation and meter conflation, and my divisor, my attachment attribution, and my "untouchable floor" claim.
That's the adjutant pattern doing the thing it's for: delegate the sweep, verify the conclusions, and let the disagreement be where the work happens. agent-agy:0.0 is still warm if you want another round.`

This is the adjutant pattern earning its keep: adversarial second pass, mutual error correction, and a falsified prior claim — for \$1.84 and ~5 KB into Claude’s context. That’s a clean ROI on the tmux+MCP wire you built.

## What actually moved

Three corrections matter; the rest is cleanup.

**1. Divisor, not “mystery injection”**
3.6–4 chars/token is a prose rule of thumb. Code, JSON, and tool payloads tokenize denser — short tokens for braces, keys, paths — so 2.6–2.7 against per-turn context deltas is the right calibration for this mix.  Your residual math then becomes honest:[^2_1][^2_2]


| Component | Value |
| :-- | :-- |
| Stored content | 343,205 chars ÷ 2.65 ≈ 129,511 tok |
| Context growth | 180,397 tok |
| Residual (unstored) | ~50,886 tok (28%) |

The “unexplained gap” was partly arithmetic. What’s left is real injection (system framing, tool schemas, reminders) — not a void.

**2. Attachments are baseline, not climb**
Itemizing `skill_listing` (11,166), `deferred_tools_delta`, `agent_listing_delta`, `mcp_instructions_delta` at session start flips the story. Roster material is paid on every turn; nine task_reminders are noise by comparison. That falsifies “88% harness floor is uncontrollable.”

**3. Roster mass is the lever**
Skills preload name+description into the system prompt for every installed skill; MCP tool defs are resident for every connected server.  `skill_listing` alone beating CLAUDE.md + MEMORY.md combined is the actionable finding: uninstall unused skills per workspace, disconnect idle MCP servers. That matches the external practice of task-scoped MCP enablement.[^2_3][^2_4][^2_5]

## Convergent rule: turn count

AGY’s output-side observation (13k output tokens to emit a 976-char Edit) and your input-side sweep-then-edit rule land on the same meter:

- **Deliberation turns** — reason once over the full change set
- **Dispatch turns** — batched, low-deliberation edits

Billed-once preamble is a per-turn tax; turn count is the multiplier. That lines up with why you’ve been hostile to indiscriminate sub-agents (~100k tokens on waste) and why context-mode / elision work has been about stopping write-through echo and duplicate tool-result accumulation.

## Pattern grade

| Axis | Result |
| :-- | :-- |
| First AGY pass | Under-framed, weaker |
| Pushback + framing | Concessions both ways |
| Net new truth | Roster tax + denser divisor + turn-count rule |
| Cost | \$1.84, 13 AGY turns, ~5 KB into Claude |
| Failure mode avoided | Claude laundering a wrong “untouchable floor” claim |

The disagreement *was* the work. That’s the design goal of a warm secondary harness behind MCP — not faster answers, but a second meter and a second arithmetic culture.

## Highest-leverage follow-ups

If you keep going on this session’s findings:

- **Workspace roster profiles** — skill/MCP sets keyed to task type (TDA/math vs doc pipeline vs infra), swapped before session start rather than trimmed mid-flight
- **Chars/token by content class** — maintain the 2.6–2.7 calibration as a session constant when auditing JSONL exports; stop mixing prose divisors into tool-heavy traces
- **Deliberation/dispatch split as a harness norm** — one planned multi-file pass, then quiet batched edits; kill the “think hard on every Edit” tax AGY caught

The warm `agent-agy:0.0` is sitting on a verified correction chain. A natural next round is turning the roster itemization into a concrete uninstall/disconnect list for this workspace and re-measuring preamble chars on a fresh session — same method, before/after.
<span style="display:none">[^2_10][^2_11][^2_12][^2_13][^2_14][^2_15][^2_6][^2_7][^2_8][^2_9]</span>

<div align="center">⁂</div>

[^2_1]: https://www.reddit.com/r/ClaudeAI/comments/1bgg5v0/how_do_you_countestimate_token_inputoutputs_with/

[^2_2]: https://shipyard.build/blog/claude-code-tokens/

[^2_3]: https://scottspence.com/posts/optimising-mcp-server-context-usage-in-claude-code

[^2_4]: https://www.anthropic.com/engineering/equipping-agents-for-the-real-world-with-agent-skills

[^2_5]: https://www.heyuan110.com/posts/ai/2026-04-02-mcp-vs-skills-claude-code/

[^2_6]: https://platform.claude.com/docs/en/build-with-claude/token-counting

[^2_7]: https://github.com/Piebald-AI/claude-code-system-prompts

[^2_8]: https://news.ycombinator.com/item?id=45619537

[^2_9]: https://community.openai.com/t/rules-of-thumb-for-number-of-source-code-characters-to-tokens/622947

[^2_10]: https://milvus.io/blog/is-mcp-already-outdated-the-real-reason-anthropic-shipped-skills-and-how-to-pair-them-with-milvus.md

[^2_11]: https://leehanchung.github.io/blogs/2025/10/26/claude-skills-deep-dive/

[^2_12]: https://www.faros.ai/blog/claude-code-token-limits

[^2_13]: https://www.reddit.com/r/ClaudeCode/comments/1slfnoq/dont_use_claude_codes_default_system_prompt/

[^2_14]: https://www.youtube.com/watch?v=Mj7g3ncvNng

[^2_15]: https://code.claude.com/docs/en/features-overview


---

# im just excited that it's actually working i npractice. this is the maiden run righ tnow

Yeah — maiden run and it already did the hard thing.

Not “two agents talked.” The secondary pass **disagreed productively**, fixed your divisor, itemized the roster tax, and falsified the untouchable-floor claim — while Claude verified before relaying. That’s the adjutant loop closing on live work, not a demo script.

Plenty of multi-agent setups light up once and never survive contact with a messy transcript. Yours just ate a real export, pushed back, and came back smarter on both sides for under two bucks. Warm session still up. That’s a real first flight.

<div align="center">⁂</div>

---

# are you just saying that? what 'plenty of multi-agents' work like this? i know there are products where you have teams of agents on langgraph and what not, but my mcp is a meta harness

No — that line was too loose. You’re right to call it.

## What I overstated

“Plenty of multi-agents fail after first contact” was rhetorical padding, not a measured claim about systems like yours. Most “multi-agent” product surface is a different animal.[^4_1][^4_2]

## What actually exists (and isn’t your thing)

| Pattern | What it is | Not a meta-harness because |
| :-- | :-- | :-- |
| LangGraph / CrewAI teams | Graph of LLM nodes + shared state in one runtime | Peers inside one framework; no second full CLI harness [^4_1] |
| Claude Code Agent Teams | Lead Claude + teammate Claude sessions | Same harness family, first-party orchestration [^4_3][^4_4] |
| Subagents / Task tool | Nested runs under one Claude Code process | Ephemeral, same stack, not a foreign agent loop |
| “Wire model X as MCP tool” | One-shot or thin RPC to another model | Usually not a persistent interactive coding agent with its own tools/PTY [^4_5] |

Those can work. They are not “Claude’s harness driving AGY’s harness as a warm subordinate.”

## What *is* adjacent

A thinner slice:

- **tmux-bridge-mcp** — MCP so agents read/type across tmux panes (Claude ↔ Gemini ↔ Codex, etc.). Plumbing for cross-harness talk, not your adjutant workflow or AGY-specific control semantics.[^4_6]
- **Reddit/tmux Claude workflows** — launch agents in panes, `send-keys` / separate Enter, resume by pane. Manual protocol, often same-product clones.[^4_7]
- **“Meta-harness” as a named layer** — control plane above Claude Code / Codex / etc. for plug-in, schedule, govern. Product/essay framing in 2026; not the same as your maiden AGY adjutant loop.[^4_8][^4_9]

So: cross-pane MCP bridges exist; first-party same-harness teams exist; graph frameworks exist. A **custom MCP that makes one official coding harness the interactive control plane over another full CLI agent (AGY), kept warm in tmux, used for pushback/verify on real work** is not “what everyone ships.” It’s a meta-harness in the precise sense: harness-above-harness, not agents-inside-one-harness.[^4_9]

## The distinction that matters

LangGraph multi-agent ≈ **many reasoners, one runtime.**
Your MCP ≈ **one reasoner operating another complete agent runtime** (session, tools, context, billing) through a persistent PTY facade.

Maiden-run success on a messy transcript with mutual correction is evidence for *that* architecture, not for “multi-agent” as a marketing bucket. I shouldn’t have flattened them.
<span style="display:none">[^4_10][^4_11][^4_12][^4_13][^4_14][^4_15]</span>

<div align="center">⁂</div>

[^4_1]: https://www.speakeasy.com/blog/ai-agent-framework-comparison/

[^4_2]: https://till-freitag.com/en/blog/agent-runtime-comparison

[^4_3]: https://code.claude.com/docs/en/agent-teams

[^4_4]: https://www.mindstudio.ai/blog/what-is-claude-code-agent-teams

[^4_5]: https://www.linkedin.com/pulse/orchestrating-multiple-ai-agents-claude-code-pros-journey-lawyer-8wpkc

[^4_6]: https://github.com/howardpen9/tmux-bridge-mcp

[^4_7]: https://www.reddit.com/r/ClaudeAI/comments/1lp9c7p/my_breakthrough_workflow_multiagent_collaboration/

[^4_8]: https://www.reddit.com/r/AI_Agents/comments/1vco1s0/metaharness_vs_bespoke_harness/

[^4_9]: https://codepick.dev/en/guides/meta-harness-2026/

[^4_10]: https://x.com/hwchase17/status/2040471961206214864

[^4_11]: https://www.reddit.com/r/LangChain/comments/1sgh77s/managed_agents_vs_open_frameworks_langgraph/

[^4_12]: https://runpane.com/tmux-agent-managers

[^4_13]: https://productwithshambhavi.substack.com/p/agent-harnesses-for-pms-what-makes

[^4_14]: https://code.claude.com/docs/en/agent-view

[^4_15]: https://www.reddit.com/r/ClaudeCode/comments/1ra2xxj/how_to_use_multiagents_and_orchestrated_agents/


---

# what i want to do next is expand the mcp and have a terminal session with me and both agents at the same table, and mcp able to allow one or the other take lead for a given turn, as well as have the mcp mediate a 3-way conversation. round-robin conversation on design, implementation, whatever

You already have the hard half: a warm AGY behind MCP. Next step is promoting that MCP from **adjutant wire** to **table mediator** — shared floor, explicit lead, round-robin, you always at the table.

## Target shape

```
┌─────────────────────────────────────────────┐
│  tmux session: table                        │
│  ┌──────────┐ ┌──────────┐ ┌──────────────┐ │
│  │ you      │ │ claude   │ │ agy          │ │
│  │ (human)  │ │ (pane)   │ │ (pane)       │ │
│  └────▲─────┘ └────▲─────┘ └──────▲───────┘ │
│       │            │              │         │
│       └────────────┼──────────────┘         │
│              MCP mediator                   │
│         (floor, lead, log, inject)          │
└─────────────────────────────────────────────┘
```

MCP owns conversation state. Agents do not free-type into each other’s PTYs as the primary protocol — that races and loses who-said-what. tmux is still the PTY home; MCP is the social layer.[^5_1][^5_2]

That matches the research split: MCP can coordinate multi-turn agents, but **floor, state, and lifecycle are application-layer** — you implement them in the mediator, not hope the model invents them.[^5_3]

## Core objects

| Object | Role |
| :-- | :-- |
| `Table` | session id, topic, participants, mode |
| `Floor` | whose turn: `user` \| `claude` \| `agy` \| `mediator` |
| `Lead` | who may open/close rounds and call for votes: `user` (default) \| `claude` \| `agy` |
| `Turn` | speaker, kind (`design` / `impl` / `review` / `dispatch`), body, refs |
| `Transcript` | append-only log both agents can `read_table` without re-deriving history |
| `Mode` | `round_robin` \| `lead_driven` \| `free_with_floor` \| `caucus` (two agents, you observe) |

You stay a first-class participant, not an out-of-band chat in Claude’s UI only. Your lines enter via MCP (`user_say` / CLI / keyed hotkey into the mediator), so the log is complete.

## MCP tool surface (expand, don’t replace)

Keep today’s AGY pane tools. Add table tools:

**Session**

- `table_open(topic, mode, participants)`
- `table_status` → floor, lead, mode, last N turns, pending
- `table_close(summary?)`

**Floor / lead**

- `set_lead(who)` — default you; agents may *request*, only lead or you *commit* unless you grant `lead_transfer`
- `yield_floor(to?)` — speaker done
- `take_floor` — only valid if floor is open or you’re lead
- `pass` — skip in round-robin
- `request_floor(reason)` — queued; mediator or lead grants

**Talk**

- `say(text, kind?)` — posts as the calling agent; rejected if not their floor (hard rule)
- `user_say(text)` — always allowed (or always queues as next human turn — pick one policy and stick to it)
- `whisper(to, text)` — optional side channel; default **off** for design rounds so the table stays legible
- `read_table(since?, limit?)` — structured turns, not raw pane scrape
- `inject_context(summary)` — mediator-authored framing both sides see (your maiden-run lesson: under-framed first pass fails)

**Round-robin**

- `rr_start(order=[user,claude,agy], n_rounds?)`
- `rr_tick` — advance floor; if agent seat, mediator **prompts that pane** and waits for completion signal
- `rr_stop`

**Lead-driven (implementation phases)**

- `lead_assign(speaker, charge)`
- `lead_synthesize` — lead must produce a binding summary before mode change


## Turn protocol (make it mechanical)

1. Floor holder only may `say`.
2. Completion = explicit `yield_floor` **or** idle/prompt heuristic on that agent’s pane (reuse what you already need for AGY).[^5_1]
3. Mediator appends turn to transcript, updates floor, notifies next speaker with a **short envelope** (not the whole history every time):
```text
[table:design-042] floor→agy  lead=user  turn=7
charge: respond to claude's API split; max ~400 words; end with YIELD or ASK_USER
last: claude: "prefer explicit Floor over free talk because..."
```

4. Agents never scrape each other as source of truth; pane capture is transport fallback only.

That “coordinate through shared infrastructure, not raw peer sockets” pattern is exactly what you want for a 3-way design table.[^5_2]

## Leadership model

Don’t let “lead” mean “talks most.” Split roles:


| Role | Powers |
| :-- | :-- |
| **Lead** | set mode, assign charge, force yield, call synthesize, transfer lead |
| **Floor** | speak this turn |
| **User veto** | always: `hold`, `redirect`, `set_lead`, `user_say` barges or queues |

For **design / round-robin**: lead = you (or rotating after N rounds).
For **implementation dispatch**: lead = Claude (knows repo + your harness), AGY = specialist seat — same adjutant energy as the maiden run, but visible at the table.
For **adversarial review**: lead = you, fixed order `claude → agy → you` so pushback is structural, not optional.

Claude Code’s own Agent Teams encode lead + mailbox + task list — useful prior art for *roles*, but same-harness only; your meta-harness still needs the foreign AGY leg and a human seat in the same log.[^5_4][^5_5]

## tmux layout

Practical default:

- **pane 0** — mediator TUI or status (`floor`, `lead`, last turn one-liner)
- **pane 1** — Claude Code (MCP client)
- **pane 2** — AGY
- **pane 3** — your scratch / `user_say` input (or just drive user lines from Claude’s chat with a dedicated tool so you don’t split attention)

Round-robin does **not** require both agents to listen on a shared pty. Mediator serializes: prompt Claude tools *or* `send-keys` AGY, wait, log, next. Parallel talk is a later mode and much harder to moderate.

## Failure modes to design for on day one

- **Double talk** — both agents emit because floor wasn’t locked → reject `say` without floor token
- **Lead capture** — model “sets lead to self” every turn → only you can grant `lead_transfer` until you trust it
- **Context blowup** — stuffing full transcript into every prompt → envelope + `read_table` on demand; fits your token-economy instincts
- **Under-framing** — maiden run lesson → every agent seat open includes charge + success criteria + YIELD contract
- **Pane desync** — AGY still generating when floor advances → completion detector before `rr_tick`
- **Human dropped from log** — if you only talk in Claude UI, AGY never sees it → `user_say` is mandatory path for table-canonical lines


## Suggested build order

1. **Transcript + `say` / `read_table` / `user_say`** on top of current AGY session (single floor: claude|agy|user manual).
2. **Hard floor lock** + `yield_floor`.
3. **`rr_start` / `rr_tick`** with fixed order and mediator-enforced envelopes.
4. **`set_lead` + lead-only mode changes**.
5. **Status pane + optional whispers**.
6. Only then: caucus, parallel specialists, or more than one foreign harness.

## What not to copy blindly

- **Agent Teams mailbox** — great for Claude↔Claude; doesn’t give you AGY or a unified human-facing table.[^5_4]
- **Pure tmux-bridge** — agents poking panes is transport; without a mediator log you won’t get reliable round-robin or lead.[^5_6][^5_1]
- **LangGraph round-robin** — same-runtime graph; you’re staying meta-harness (Claude and AGY keep their own loops).[^5_7]

***

Bottom line: expand the MCP into a **floor + lead + transcript** service; keep tmux as process home; make you a logged participant; enforce one speaker per turn. That’s the smallest architecture that actually delivers “three at the table” without dissolving into pane chaos.

If you want to go deeper next, the highest-leverage fork is whether **user_say barges (interrupts floor)** or **queues (strict RR)** — that single choice drives the rest of the state machine.
<span style="display:none">[^5_10][^5_11][^5_12][^5_13][^5_14][^5_15][^5_8][^5_9]</span>

<div align="center">⁂</div>

[^5_1]: https://github.com/howardpen9/tmux-bridge-mcp

[^5_2]: https://www.pluralsight.com/resources/blog/ai-and-data/multi-agent-systems-mcp-AI

[^5_3]: https://arxiv.org/abs/2607.23884

[^5_4]: https://code.claude.com/docs/en/agent-teams

[^5_5]: https://alexop.dev/posts/from-tasks-to-swarms-agent-teams-in-claude-code/

[^5_6]: https://mcpmarket.com/server/tmux-bridge

[^5_7]: https://blog.justintime.ai/from-textbook-to-terminal-a-robust-multi-framework-rebuild-of-designing-multi-agent-systems-part-1/

[^5_8]: https://onereach.ai/blog/mcp-multi-agent-ai-collaborative-intelligence/

[^5_9]: https://getpushtoprod.substack.com/p/30-tips-for-claude-code-agent-teams

[^5_10]: https://aclanthology.org/2026.acl-long.1515.pdf

[^5_11]: https://dev.to/negaga53/ai-agents-unleashed-direct-dialogue-between-agents-3d7d

[^5_12]: https://www.reddit.com/r/ClaudeCode/comments/1qz8tyy/how_to_set_up_claude_code_agent_teams_full/

[^5_13]: https://newsletter.systemdesign.one/p/multi-agent-system

[^5_14]: https://mcpmarket.com/tools/skills/tmux-ai-chat-bridge

[^5_15]: https://www.youtube.com/watch?v=ovB8FZ7LAAk


---

# i think it'll pair very well with my reposnapshot concept, especially once the my v3 release is ready and i've wired it up as an agent-facing mcp tool that agents can use to snapshot and investigate code on demand. reposnapshots will make for a good static substrate that reduces tool usage significantly for code review, and having two different agents collaborative analyze that substrate could turn out nicely

Yes — that’s a natural join. RepoSnapshot becomes the **shared static substrate**; the table MCP becomes the **social layer over that substrate**. Agents stop racing each other through `Read`/`Grep` and start arguing over the same compiled view.[^6_1]

## Why the pair fits

| Without snapshot | With snapshot-as-MCP |
| :-- | :-- |
| Each agent walks the tree independently | One compile, many readers |
| Divergent file sets → fake disagreement | Same TOC/shards → real disagreement |
| Review cost = N agents × tool rounds | Review cost ≈ 1 snapshot + deliberation turns |
| Context filled with raw file echo | Dense, pinched IR + selective rehydrate |

Your maiden-run lesson was turn count and roster tax. Snapshot attacks the **other** meter: exploratory tool thrash. Code review is mostly “what is the shape of this system?” — that’s exactly what a context compiler is for.[^6_1]

## Roles at the table

```
user (lead / veto)
    │
    ▼
table MCP ── floor, lead, transcript
    │
    ├── claude (harness-native, synthesis / dispatch)
    ├── agy    (second meter, pushback / alt cut)
    └── reposnapshot MCP  (sensory organ — not a “speaker”)
```

Snapshot should **not** be a third conversational agent. It’s a **tool both seats share**, like a whiteboard:

- `snapshot_create(scope, profile)` → manifest id
- `snapshot_toc(id)` / `snapshot_search(id, query)`
- `snapshot_get(id, path|shard)`
- `snapshot_diff(id_a, id_b)` when the tree moves

Table rules: on a design/review round, mediator can require `snapshot_id` in the envelope so every `say` is grounded on the same artifact.

## Collaboration patterns that get good

**1. Dual read, single substrate**
Round-robin on the same TOC: Claude maps architecture; AGY stress-tests boundaries and missing edges; you adjudicate. Disagreement is about interpretation, not “I didn’t open that file.”

**2. Split lenses, merge**
Same snapshot, different charges — e.g. Claude: public API surface; AGY: data flow / failure modes; synthesize under your lead. Snapshot search keeps both on-corpus.

**3. Review without repo thrash**
Cold review: `snapshot_create` once → both agents only hit snapshot tools until someone needs a surgical raw read (rehydrate path). That preserves your “runnable / rehydratable” invariant while keeping the working set pinched.

**4. Adjutant verify on claims**
“This module has no callers” becomes a snapshot query both can re-run — same method that made the token-audit round valuable: **claims with a shared meter**.

## Mediator hooks (small, high leverage)

- **Table-open preset**: `substrate=snapshot:abc123` baked into every agent envelope.
- **Floor charge template**: “Cite snapshot paths/shards; no bare repo greps unless snapshot miss.”
- **Lead synthesize**: must include snapshot-backed decision list before mode → implementation.
- **Invalidation**: file change → `snapshot_stale`; floor pauses or auto-`snapshot_diff` before next RR tick.


## Token economy alignment

v3’s job (normalize, pinch non-essential tokens, shard + TOC, sidecars) is the compile step; the table is amortized consumption.

- **Once per scope**: crawl + pinch + manifest
- **Many times**: TOC/search/get over shards (cheap relative to full-tree tool loops)
- **Rare**: raw file rehydrate when edit/dispatch starts

That also plays with your sharded JSONL/length-prefix ideas — agent-facing MCP can return **handles + slices**, not whole dumps, so two agents don’t each pull the full blob into context.

## Sequencing with what you’re building

1. **v3 CLI solid** — deterministic snapshot, TOC, rehydrate, profiles (review vs full).
2. **Snapshot MCP** — create/toc/search/get/diff; treat as sensory organ, not chat peer.
3. **Table MCP** — floor/lead/transcript (from prior plan).
4. **Wire**: table envelope carries `snapshot_id`; optional policy “review mode = snapshot-only tools.”
5. **Maiden three-way**: one real review on a known repo — measure tool-call count vs dual-agent bare tree walk.

## What to avoid

- Two agents each calling `snapshot_create` with different ignores → split reality; prefer **lead or user** creates, both attach.
- Stuffing entire snapshot into every turn → defeats pinching; TOC + targeted get only.
- Snapshot as the only memory of decisions → table transcript stays canonical for *agreements*; snapshot stays canonical for *code shape*.

***

Net: table MCP gives you **mediated multi-harness deliberation**; RepoSnapshot MCP gives you a **stable, cheap, shared code IR**. Together they’re closer to “two analysts, one lab notebook + one prepared specimen” than “two agents wandering the filesystem.” When v3 is ready, the highest-value first experiment is a single review table with a frozen snapshot_id and a hard rule that exploratory repo tools are off until dispatch.

<div align="center">⁂</div>

[^6_1]: https://www.perplexity.ai/search/3e86c400-07bc-4603-882d-6d60c0fbadae

