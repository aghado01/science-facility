In Antigravity IDE, a `.ignore` file impacts the agent’s context across three distinct layers:

---

### 1. Agent Search Tools (`grep_search` / `rg`) — **Filtered Out**
When the agent executes codebase-wide searches (e.g., using `grep_search`, which runs `ripgrep` under the hood):
* **Files matching `.ignore` are skipped entirely.**
* Match snippets from those files are **never returned in the tool output**, keeping large generated files, minified bundles, or noise out of the agent's active prompt/context window.

---

### 2. Proactive & Passive Context Gathering (Autocomplete & Indexing) — **Excluded**
Antigravity IDE runs background indexing and semantic retrieval to feed context into:
* **Antigravity Tab (Autocomplete & Supercomplete)**
* **Workspace context indexing** (for symbol resolution and relevant code retrieval)

Because the IDE indexer utilizes `ripgrep`-compatible traversal rules, entries in `.ignore` are treated as invisible to the passive context-gathering engine.

---

### 3. Direct Tool Operations (`view_file`, `list_dir`) — **Not a Hard Block**
It is important to note the difference between **search exclusion** and **hard access control**:

* **`.ignore` does not prevent targeted reads**: If the agent (or the user via an `@file` mention) explicitly requests a file by its exact path using `view_file` or `read_file`, the IDE will still read the file.
* **To enforce hard blocks**: If you want to strictly prevent the agent from ever reading a sensitive file even if requested by name, use a `PreToolUse` lifecycle hook in [`.agents/hooks.json`](file:///C:/Users/azrie/.gemini/antigravity-ide/builtin/skills/agy-customizations/docs/hooks.md) or specify the restriction in [`.agents/rules/` / `AGENTS.md`](file:///D:/aghado01/science-facility/AGENTS.md).

---

### Summary Matrix

| Context Source | Respects `.ignore`? | Result |
| :--- | :---: | :--- |
| **`grep_search` / `rg`** | **Yes** | Results from ignored files are omitted from prompt context |
| **Autocomplete / Background Indexer** | **Yes** | Excluded from semantic context & prompt synthesis |
| **Explicit file read (`view_file`)** | **No** | Agent can still read if given the specific path |
| **Workspace Rules (`AGENTS.md`)** | **No** | Rule discovery walks directory trees directly |