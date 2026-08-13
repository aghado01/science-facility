**Yes — this is a natural next layer on top of the refactor skill (and the rest of `skills/`).**

The current model forces agents to either:

- load the whole `SKILL.md` + cards (context cost), or
- make multiple file/GitHub reads to find the right card.

A dedicated “skill help desk” MCP (or MCP + hooks) can collapse that into one or two targeted calls while preserving the selective-loading discipline we already encoded in the skill itself.

### What already exists in the repo that points the way

- **`mcp/mdnav`** is the strongest foundation. It is deliberately structure-aware, zero-assumption, and optimized for selective byte-span reads of markdown corpora. Skills are _exactly_ the kind of structured corpus it was built for (`##` groups, `###` cards, clear delimiters). You already get `discover`, `outline`, `read --heading / --from/--to / --headings`, `locate`, coverage, and profile for free.
- Skills currently live as static files under `skills/`. There is no dedicated skill MCP yet (`.mcp.json` only registers `para-agent`).
- The new `skills/refactor/` cards were deliberately written with progressive disclosure in mind: load the matrix or a single card, not the whole catalog.

### Two complementary approaches

#### 1. Skill Help-Desk MCP (explicit, low-tool-call surface)

A thin MCP server (could wrap or extend mdnav) that exposes a small, stable tool surface:

| Tool                                            | Purpose                                                                         | Typical cost                              |
| ----------------------------------------------- | ------------------------------------------------------------------------------- | ----------------------------------------- |
| `list_skills`                                   | names + one-line descriptions                                                   | ~50–100 tokens total                      |
| `get_skill(name)`                               | returns only `SKILL.md` (or a section)                                          | low                                       |
| `search_skills(query)` / `search_smells(query)` | BM25 or simple keyword over cards                                               | returns ranked card names + short signals |
| `get_card(skill, name)`                         | e.g. `get_card("refactor", "Long Method")` or `get_technique("Extract Method")` | single card only                          |
| `matrix_lookup(smell)`                          | returns the primary techniques list                                             | tiny                                      |
| `outline_skill(name)`                           | structural outline so the agent can choose which sections to pull               | very cheap                                |

This is the pattern used by several emerging “skills MCP” projects (skills-mcp, local-skills-mcp, agent-skills-mcp, etc.): progressive disclosure — names first, full content on demand. The agent never has to open the raw files itself.

Because the cards are already cleanly delimited, an mdnav-backed implementation can materialize _exactly_ the byte spans needed and nothing more.

#### 2. Hooks / context-routing layer (automatic)

Inspired by context-mode’s hook model (preToolUse, postToolUse, sessionStart, afterAgentResponse) and Serena’s contexts/modes:

- On session start or before certain tool classes (edit, generate, review), a lightweight classifier or keyword matcher inspects the current task / open files / recent diff.
- It injects only the relevant skill summary or card(s) into the system prompt or a side channel.
- Example triggers for the refactor skill: long methods, nested conditionals, “extract”, “smell”, “duplicate”, parameter lists > 3–4, type-code switches, etc.

This removes the need for the agent to _decide_ to call the help desk at all for common cases. The explicit MCP tools remain available for deliberate lookup.

You can combine both: the MCP is the durable, inspectable surface; hooks are the automatic accelerator.

### Design recommendations grounded in science-facility style

- **Stay zero-assumption about content** (mdnav’s core rule). The MCP should never invent relevance; it only surfaces structure and literal spans.
- **Progressive disclosure by default**. Never dump a whole techniques.md unless asked.
- **Address model compatibility**. Prefer mdnav-style anchors (`Dnnn:Hnnnn`) or simple skill+card names so the same coordinates work for coverage tracking and re-reading.
- **Language/idiom awareness** can live in the skill cards themselves (we already noted dataclasses/TypedDict preference); the MCP just delivers the right card.
- **Composition with existing MCPs**. A skill MCP can sit beside para-agent and mdnav; it does not need to own sessions or terminal state.
- **Optional FTS5 / simple index**. For multi-skill corpora a small SQLite FTS index (as context-mode does) makes `search_smells("long method OR nested conditional")` cheap and accurate. For a handful of skills, pure structural outline + keyword is enough.

### Suggested minimal first cut

1. Stand up a thin MCP that:
   - discovers `skills/*/SKILL.md` (+ optional `smells.md` / `techniques.md`),
   - exposes `list_skills`, `get_skill`, `get_card`, `matrix_lookup`,
   - re-uses mdnav under the hood for the actual reads (or implements the same span model).
2. Register it in `.mcp.json`.
3. Add a short note in AGENTS.md / the refactor SKILL.md pointing agents at the help-desk tools instead of raw file reads.
4. Later: add a Claude-Code / Cursor-style hook that does automatic injection for high-frequency smells.

This keeps the skill files themselves as the single source of truth (easy to prune, version, and share) while making them _usable_ without burning context or tool-call budget.

Would you like me to:

- sketch the exact tool schema + a minimal Node/Python MCP skeleton that wraps the existing `skills/refactor/` cards,
- or explore the hook-based auto-routing path in more detail (including how it would interact with mdnav or para-agent),
- or look at how MarkBrain / prior project-snapshots handled similar routing ideas?
