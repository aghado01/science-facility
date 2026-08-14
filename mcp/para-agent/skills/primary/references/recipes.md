# Primary Agent Workflows & Recipes

Each fenced object is the argument object for the named tool.

## Contents

- Captured shell task
- Auditable agent turn
- Interactive REPL
- Economical failure diagnosis

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
  "handle": "<returned-handle>",
  "command": "npm test",
  "shell": "nu",
  "timeoutMs": 120000
}
```

`kill`:

```json
{
  "handle": "<returned-session>",
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

Call with `delegate`, then use `receipt.exchange_id` with `scrutinize` if the bounded receipt indicates relevant native records or omissions. A non-completed call is an MCP error whose payload still carries the durable receipt and does not carry a reply.

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
  "handle": "<returned-handle>",
  "mode": "line",
  "input": "import math; math.sqrt(256)"
}
```

`wait`:

```json
{
  "handle": "<returned-handle>",
  "until": "pattern",
  "pattern": "16\\.0",
  "timeoutMs": 10000
}
```

`read`:

```json
{
  "handle": "<returned-handle>",
  "delta": true,
  "scrollback": 1000
}
```

## Diagnose a failed shell command economically

`find`:

```json
{
  "handle": "<returned-handle>",
  "pattern": "FAILED|ERROR",
  "context": 2,
  "maxHits": 20
}
```

Use `body` only for the turn(s) named by the search receipt. Use `scrutinize` instead only when diagnosing a `delegate` exchange. The `wait` response already contains its matching screen; the later delta `read` is for output produced after that response.
