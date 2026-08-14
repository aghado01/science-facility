# Session Lifecycle & Pane Allocation

The primary agent coordinates sub-agent worker processes via isolated, persistent tmux panes managed by `para-agent`.

## Tools

### 1. `spawn`
Creates a detached, persistent multiplexer session. The session and its environment outlive individual tool calls.

```json
// Shell Worker Pane (Default: Nushell with para-agent profile)
spawn({ "name": "worker-1", "shell": "nu", "profile": "para-agent" })

// Program / TUI Pane (Runs binary directly, no shell)
spawn({ "name": "agy-runner", "command": ["agy"] })
```

* **`name`**: Short session identifier. Automatically prefixed as `para-<name>`.
* **`shell`**: `nu` (preferred default), `pwsh`, or `bash`.
* **`profile`**: Nushell profile — `para-agent` (worker) or `primary-agent` (supervisor).
* **`cwd`**: Optional working directory (defaults to workspace root).
* **Returns**: `{ "handle": "para-worker-1:0.0", "status": "ready" }`.

---

### 2. `status`
Inspects live pane state without reading scrollback text. Zero context cost.

```json
status({ "handle": "para-worker-1:0.0" })
```
* **Returns**: `pid`, `command`, `cwd`, `dead` (boolean exit flag), `scrollbackLines`, `width`, `height`.

---

### 3. `list`
Enumerates all active sessions, windows, and panes within the workspace multiplexer.

```json
list({})
```
* **Returns**: Array of active sessions and attached pane handles.

---

### 4. `kill` / `killSession`
Terminates a specific pane or kills an entire session and all associated processes.

```json
killSession({ "session": "para-worker-1" })
```
