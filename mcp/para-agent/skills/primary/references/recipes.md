# Primary Agent Workflows & Recipes

---

## Recipe 1: Spawning an Agent Worker & Running a Task

```json
// Step 1: Spawn a persistent Nushell worker pane
spawn({ "name": "build-agent", "shell": "nu", "profile": "para-agent" })

// Step 2: Execute command turn
run({
  "handle": "para-build-agent:0.0",
  "command": "npm test"
})

// Step 3: Check status if long-running
status({ "handle": "para-build-agent:0.0" })

// Step 4: Cleanup when done
killSession({ "session": "para-build-agent" })
```

---

## Recipe 2: Driving an External Agent CLI (`agy`, `codex`, `claude`)

```json
// Step 1: Spawn Nushell pane
spawn({ "name": "agy-runner" })

// Step 2: Dispatch external agent command
run({
  "handle": "para-agy-runner:0.0",
  "command": "agy run 'Audit sql queries in db/'"
})

// Step 3: Inspect tool traces if needed
scrutinize({
  "handle": "para-agy-runner:0.0",
  "filter": "tools"
})
```

---

## Recipe 3: Driving Interactive TUI / REPL Processes

```json
// Step 1: Spawn process directly
spawn({ "name": "repl", "command": ["python", "-i"] })

// Step 2: Send input
send({ "handle": "para-repl:0.0", "text": "import math; math.sqrt(256)", "enter": true })

// Step 3: Wait for output to settle
wait({ "handle": "para-repl:0.0", "stableMs": 300 })

// Step 4: Read incremental response
read({ "handle": "para-repl:0.0" })
```

---

## Recipe 4: Diagnosing Failures without Token Waste

```json
// 1. Identify failure from receipt code != 0
run({ "handle": "para-worker:0.0", "command": "pytest" })
// Receipt shows code: 1, ok: false

// 2. Search specifically for failing lines across turns
find({ "handle": "para-worker:0.0", "pattern": "FAILED", "context": 2 })

// 3. Or scrutinize exchange failure records
scrutinize({ "handle": "para-worker:0.0", "filter": "failures" })
```
