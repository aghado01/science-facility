# Execution Paths

`para-agent` has three deliberately separate paths.

## Mediated turn: `delegate`

Use `delegate` when the reply and provenance must come from a verified native structured stream.

```json
{
  "handle": "review-seat",
  "application": "claude",
  "prompt": "Review the boundary and return the two highest-risk findings.",
  "timeoutMs": 120000
}
```

Call this object with `delegate`. The prompt is one exact UTF-8 string; controls are separate. A successful result requires a correlated receiver-native terminal event and durable terminal commit. Failed, interrupted, and timed-out exchanges return an MCP error with a receipt and no fabricated reply.

## Captured shell turn: `run`

Use `run` only against a shell pane. Output bypasses terminal capture and is recorded in the Console Journal.

```json
{
  "handle": "para-worker-1:0.0",
  "command": "cargo test -- --nocapture",
  "shell": "nu",
  "timeoutMs": 60000
}
```

The receipt reports `code`, `ok`, `outcome`, `duration_ms`, output size, hash, completeness, and a retrieval call when the body is deferred. A timeout abandons observation; it does not stop the command.

## Interactive console: `send`, `wait`, `read`

Use these for a pane spawned with `command`, where there is no shell prompt or native mediation adapter.

```json
{
  "handle": "agent-repl:0.0",
  "mode": "line",
  "input": "2 + 2"
}
```

```json
{
  "handle": "agent-repl:0.0",
  "until": "pattern",
  "pattern": "4",
  "timeoutMs": 10000
}
```

```json
{
  "handle": "agent-repl:0.0",
  "delta": true,
  "scrollback": 1000
}
```

Call the objects with `send`, `wait`, and `read` respectively. Prefer `wait` with `until: "pattern"`; `until: "stable"` is explicitly heuristic. Multi-line `send` input is linewise console typing, so it is not a valid transport for a mediated prompt.
