# Primary Agent Workflows & Recipes

Each fenced object is the argument object for the named tool.

## Captured shell task

`spawn`:

```json
{
  "name": "build-agent",
  "shell": "nu",
  "profile": "para-agent"
}
```

`run`:

```json
{
  "handle": "agent-build-agent:0.0",
  "command": "npm test",
  "shell": "nu",
  "timeoutMs": 120000
}
```

`kill`:

```json
{
  "handle": "agent-build-agent",
  "scope": "session"
}
```

## Auditable agent turn

Use a verified adapter rather than driving the client through pane text.

```json
{
  "handle": "security-review",
  "application": "claude",
  "prompt": "Audit the SQL boundary. Return two findings and cite the files inspected.",
  "timeoutMs": 180000
}
```

Call with `delegate`, then use the returned exchange ID with `scrutinize` if the bounded receipt indicates relevant native records or omissions.

## Interactive REPL

`spawn`:

```json
{
  "name": "repl",
  "command": ["python", "-i"]
}
```

`send`:

```json
{
  "handle": "agent-repl:0.0",
  "mode": "line",
  "input": "import math; math.sqrt(256)"
}
```

`wait`:

```json
{
  "handle": "agent-repl:0.0",
  "until": "pattern",
  "pattern": "16\\.0",
  "timeoutMs": 10000
}
```

`read`:

```json
{
  "handle": "agent-repl:0.0",
  "delta": true,
  "scrollback": 1000
}
```

## Diagnose a failed shell command economically

`find`:

```json
{
  "handle": "agent-worker:0.0",
  "pattern": "FAILED|ERROR",
  "context": 2,
  "maxHits": 20
}
```

Use `body` only for the turn(s) named by the search receipt. Use `scrutinize` instead only when diagnosing a `delegate` exchange.
