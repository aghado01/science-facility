---
name: primary-agent
description: Primary supervisor agent MCP coordination primer with progressive workflow disclosure.
---

# Primary Agent Coordination Skill (Index)

`para-agent` is a multiplexed supervisor-worker MCP engine. The primary agent manages, delegates to, and scrutinizes persistent sub-agent worker panes (Nushell, Codex, AGY, Claude) across an isolated boundary.

## Topics (Progressive Disclosure)

Query specific sub-topics individually to avoid context window clutter:

- **`lifecycle`**: Session management, pane allocation (`spawn`, `status`, `list`, `kill`).
- **`execution`**: Two execution modes (`run` captured turn vs `send`/`wait`/`read` interactive TUI).
- **`scrutiny`**: Progressive disclosure, receipts, and forensic trace inspection (`scrutinize`, `log`, `body`, `find`).
- **`recipes`**: Concrete high-yield coordination workflows and patterns.

---

_Fetch a sub-topic via `skills({ name: "primary", topic: "<topic>" })` or resource `skill://para-agent/primary/<topic>`._
