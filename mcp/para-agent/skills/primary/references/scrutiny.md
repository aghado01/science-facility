# Progressive Disclosure & Scrutiny

`para-agent` enforces strict context window conservation. Work performed by sub-agents is durably committed to JSONL transcripts, allowing the primary agent to inspect execution traces on demand without upfront context bloat.

---

## The Progressive Disclosure Ladder

| Level | Content Returned | Primary Token Cost | Tool Call |
| :--- | :--- | :---: | :--- |
| **0** | Conversational Reply | ~50–150 tokens | Default turn response |
| **1** | Turn Receipt (`_xid`, tool count, duration) | ~30 tokens | Attached to turn output |
| **2** | Filtered Record Slice (tools, thinking, errors) | ~100–300 tokens | `scrutinize({ handle, xid, filter })` |
| **3** | Single Micro-Step Deep Inspection | Targeted | `scrutinize({ handle, xid, step })` |

---

## The `scrutinize` Tool

Inspects the structured `.jsonl` transcript of an active or past session via `NuEngine`:

```json
// 1. List all exchange summaries for a session
scrutinize({ "handle": "para-worker:0.0" })

// 2. Inspect all tool calls in an exchange
scrutinize({ "handle": "para-worker:0.0", "xid": "xid-001", "filter": "tools" })

// 3. Inspect internal reasoning / thinking trace
scrutinize({ "handle": "para-worker:0.0", "xid": "xid-001", "filter": "thinking" })

// 4. Surface only failing steps or errors
scrutinize({ "handle": "para-worker:0.0", "xid": "xid-001", "filter": "failures" })

// 5. Deep forensic inspection of a specific micro-step index
scrutinize({ "handle": "para-worker:0.0", "xid": "xid-001", "step": 3 })
```

---

## Log & Body Search Tools

For traditional shell output and bulk stdout retrieval:

* **`log`**: Summary of commands executed in the session.
  ```json
  log({ "handle": "para-worker:0.0", "view": "summary" })
  ```
* **`body`**: Selective retrieval of turn output (supports `grep`, `context`, `offsetLines`).
  ```json
  body({ "handle": "para-worker:0.0", "turn": 4, "grep": "FAIL" })
  ```
* **`find`**: Regex search across all turns simultaneously returning matching lines.
  ```json
  find({ "handle": "para-worker:0.0", "pattern": "error:\\[E0" })
  ```
