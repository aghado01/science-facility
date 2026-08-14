---
name: primary
description: Coordinate persistent worker consoles and evidence-backed mediated agent turns through para-agent. Use when supervising shell panes, interactive clients, delegated turns, or their bounded journals and transcripts.
---

# Primary Agent Coordination

Choose the operation by the evidence you need:

- Use `delegate` for one auditable prompt/reply turn through a verified structured-stream adapter. This is the only path that creates a mediated exchange.
- Use `run` for byte-exact captured command output in a persistent shell pane. Its output belongs to the Console Journal, not the mediated transcript.
- Use `send`, `wait`, and `read` for an interactive program or TUI. Screen stability is heuristic and never proves an agent turn completed.

Preserve the boundaries: a participant is not an application, an application is not a model, and pane output is not receiver-native provenance. Treat model, reasoning, tools, replies, and terminal state as authoritative only when the selected adapter maps them from correlated native events.

Fetch only the topic needed:

- **`lifecycle`**: Session management, pane allocation, cancellation, and destruction (`spawn`, `status`, `list`, `cancel`, `kill`).
- **`execution`**: Mediated delegation, captured shell turns, and interactive console operations.
- **`scrutiny`**: The separate mediated transcript and Console Journal disclosure paths.
- **`recipes`**: Contract-valid coordination examples.

_Fetch a sub-topic via `skills({ name: "primary", topic: "<topic>" })` or resource `skill://para-agent/primary/<topic>`._
