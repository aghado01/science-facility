# Session Lifecycle & Pane Allocation

Sessions are persistent multiplexer resources. The default server prefix is `agent-`, but deployments may override it; always use returned handles rather than constructing them.

## Spawn

Shell pane:

```json
{
  "name": "worker-1",
  "shell": "nu",
  "profile": "para-agent"
}
```

Program pane:

```json
{
  "name": "python-repl",
  "command": ["python", "-i"],
  "width": 120,
  "height": 40
}
```

Use the `handle` returned by `spawn`; do not derive it from the requested name. The current receipt also identifies the session and whether the pane is a shell or program.

## Inspect

`status`:

```json
{
  "handle": "<returned-handle>"
}
```

`list`:

```json
{}
```

Use `status` when you need process state without pane text. Use `read` only when screen content matters.

## Stop work or destroy a resource

Interrupt the foreground work while retaining the pane:

```json
{
  "handle": "<returned-handle>",
  "level": "interrupt"
}
```

Call that object with `cancel`. Destroy an entire session only when its state is no longer needed:

```json
{
  "handle": "<returned-session>",
  "scope": "session"
}
```

Call that object with `kill`. Destruction is irreversible.

Cancelling the MCP request only stops observation and leaves pane work running. To affect the work, escalate deliberately: `cancel` with `cooperative` for a turn that checks its cancel file, `interrupt` for pane-scoped C-c, `terminate` for a selected descendant while retaining the shell, and `kill` only to destroy the pane. Session destruction remains a separate `kill({ scope: "session" })` decision.
