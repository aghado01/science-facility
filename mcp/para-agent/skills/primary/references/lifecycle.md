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

The response states the actual `handle`, `session`, and whether the pane is a shell or program.

## Inspect

`status`:

```json
{
  "handle": "agent-worker-1:0.0"
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
  "handle": "agent-worker-1:0.0",
  "level": "interrupt"
}
```

Call that object with `cancel`. Destroy an entire session only when its state is no longer needed:

```json
{
  "handle": "agent-worker-1",
  "scope": "session"
}
```

Call that object with `kill`. Destruction is irreversible; it is distinct from cancelling observation of a `run` or `wait` request.
