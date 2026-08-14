# Execution Modes

`para-agent` provides two execution modes depending on whether the target pane runs a structured shell or an interactive program.

---

## Mode A: Turn-by-Turn Structured Execution (`run`)

Use `run` against **shell panes** (e.g. `nu`). Each turn executes with byte-exact framing, automatic duration timing, exit code capture, and transcript journaling.

```json
run({
  "handle": "para-worker-1:0.0",
  "command": "cargo test -- --nocapture",
  "timeoutMs": 60000
})
```

### Turn Receipt Properties
* **`code`**: Integer exit code (`0` = success).
* **`ok`**: Boolean success flag.
* **`duration_ms`**: Measured command runtime in milliseconds.
* **`inline`**: Captured output text (if <= inlining threshold).
* **`bytes` / `lines`**: Total output volume.
* **`out_hash`**: SHA-256 slice for deduplication.

---

## Mode B: Interactive / TUI Program Execution (`send`, `wait`, `read`, `capture`)

Use these tools when a pane was spawned with `command: [...]` (an interactive CLI, TUI, or REPL where no shell is present).

### 1. `send`
Injects keystrokes or input text into the target pane.
```json
send({ "handle": "para-tui:0.0", "text": "y", "enter": true })
```

### 2. `wait`
Polls pane output until a regex pattern appears or until the screen stabilizes.
```json
wait({
  "handle": "para-tui:0.0",
  "forPattern": "Selection complete",
  "stableMs": 500,
  "timeoutMs": 10000
})
```

### 3. `read`
Fetches the incremental delta of text produced since the last read.
```json
read({ "handle": "para-tui:0.0" })
```

### 4. `capture`
Takes a full snapshot of the pane screen or scrollback buffer.
```json
capture({ "handle": "para-tui:0.0", "startLine": -100 })
```
