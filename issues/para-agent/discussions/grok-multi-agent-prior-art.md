Here’s a structured map of the multi-agent landscape relative to your claim.

### Dominant patterns (not your shape)

| Pattern | Examples | What it is |
|---------|----------|------------|
| **Role-based software teams** | MetaGPT, ChatDev, CrewAI, AgentMesh | Peers (PM / Architect / Coder / Reviewer) collaborate on a task. Flat or SOP hierarchy, not “assistant *of* a coding assistant.” |
| **Orchestrator → ephemeral workers** | Classic Claude Code subagents, many Cursor setups | Primary dispatches a worker with clean context; worker returns a summary and dies. Task-scoped, not long-lived identity. |
| **Conversation/mesh agents** | AutoGen, AgentVerse | Agents message each other until a stop condition. Peer dialogue, not privilege asymmetry for audit. |
| **Persistent *memory*, single agent** | agentmemory, selective persistent memory papers, Always-On Agents survey | Durable state across sessions for one agent (or shared workspace memory). Not multiple persistent agent seats under a primary. |
| **Long-running harnesses** | Anthropic “Effective Harnesses,” Cursor planners/workers/judges | Same coding agent woken repeatedly, or planner/worker/judge roles with shared files. Persistence is of *work*, not of dedicated para identities. |

### Near misses (partial overlap)

**Claude Code (2026 trajectory)**  
Subagents can be resumed, run in background, and (recently) nested; pinned background sessions survive idle time. Agent teams are experimental. This is the closest *product* move toward persistent workers under a primary — but still inside one vendor’s runtime, same-provider, and not designed as cross-provider paras with a mediation ledger and on-demand scrutiny of full para transcripts.

**Society Agent (TechRxiv 2026)**  
Persistent supervisors + ephemeral workers, hierarchical org model, evolving file-based knowledge. Organizational simulation (company/department), not “coding primary with dedicated persistent assistants.”

**“Remember When It Matters” memory agent**  
A separate memory agent runs *alongside* an action agent and injects reminders. Parallel observer, not a delegated coding para with its own thread and tools.

**Cross-agent delegation plugins** (e.g. Claude → Codex/Cursor workers)  
Task handoff to another product’s agent. Closer to “other coding agents as workers,” but usually job-scoped jobs + status/result, not long-lived para threads the primary can re-enter and audit.

### What the literature emphasizes instead

- Role specialization and SOP workflows  
- Context isolation for subtasks (fresh window → summary back)  
- Long-horizon *single*-agent continuity via memory/compaction  
- Team scaling vs time scaling (shared vs decentralized memory)  
- Governance of persistent *state* (permissions, provenance, rollback)

Almost none frame the core object as: **a coding primary that owns a set of long-lived assistants, each with independent thread identity and resume semantics, across providers, with a mediation plane that preserves atomic prompt↔reply while allowing privileged audit.**

### Where your shape still stands out

| Dimension | Common literature/product | Your para-agent model |
|-----------|---------------------------|------------------------|
| Lifetime | Task or session | Persistent seats across days |
| Relation | Peers, or orchestrator→disposable worker | Primary *has* paras (privilege asymmetry) |
| Memory | Shared store or single-agent memory | Per-para thread + mediation transcript |
| Provider | Homogeneous | Cross-provider (Claude, Codex, Agy, Grok, …) |
| Audit | Logs / final summary | On-demand scrutiny of para tool calls & reasoning without firehose |
| Cadence | Often free-form multi-agent chat | Atomic prompt↔reply; infrastructure retains the rest |

**Bottom line:** The field is full of multi-agent coding systems, persistent memory, hierarchical supervisors, and (increasingly) resumable subagents. The specific relational model — persistent assistant *of* a coding assistant, with independent long-lived threads, cross-provider seats, and mediated on-demand audit — does not show up as a named, standard pattern. Claude’s recent subagent/resume work is the nearest industrial cousin; it still doesn’t cover the full shape you’re building.