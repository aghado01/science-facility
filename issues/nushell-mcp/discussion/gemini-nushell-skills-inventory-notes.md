Viewed grok-nushell-skills-inventory.md:1-222
Listed directory science-facility
Listed directory skills
Listed directory mcp
Listed directory nushell-mcp
Listed directory skills
Listed directory nushell
Listed directory references
Viewed AGENTS.md:1-126
Viewed SKILL.md:1-50
Listed directory modules
Viewed mod.nu:1-3
Viewed nu-skills.nu:1-118
Searched for "nushell-mcp"
Listed directory .claude
Viewed roadmap.md:1-215
Viewed mcp.md:1-14
Viewed advanced.md:1-18
Viewed posix-cheatsheet.md:1-19
Viewed parity.md:1-21
Viewed pipelines.md:1-24
Viewed file-io.md:1-15
Viewed data-analysis.md:1-16
Viewed gotchas.md:1-17
Viewed sessions.md:1-29
Viewed jobs.md:1-128
Viewed search.md:1-37
Viewed dataspection.md:1-88
Listed directory tests
Listed directory discussion
Viewed config.nu:1-60

Here is a detailed review of the proposed plan in [grok-nushell-skills-inventory.md](file:///d:/aghado01/science-facility/issues/nushell-mcp/discussion/grok-nushell-skills-inventory.md).

---

# Architecture & Plan Review: Nushell Skills Inventory

## 1. Executive Summary & Verdict

The plan to **split the reference corpus into a Console Happy Path and a nested `stock/` branch** is sound, elegant, and directly aligns with the package doctrine in [AGENTS.md](file:///d:/aghado01/science-facility/mcp/nushell-mcp/AGENTS.md) and [roadmap.md](file:///d:/aghado01/science-facility/issues/nushell-mcp/roadmap.md).

Key architectural wins:
- **Preserves Stock Nushell as Canonical**: Naming the branch `stock/` (rather than "legacy" or "deprecated") ensures agents recognize un-augmented Nushell as valid, current language syntax while establishing the console's discipline as the default REPL happy path.
- **Filesystem-as-Catalog**: Eliminates hardcoded topic catalogs in [SKILL.md](file:///d:/aghado01/science-facility/mcp/nushell-mcp/skills/nushell/SKILL.md) that inevitably drift, moving topic discovery to a tree-aware [nu-skills.nu](file:///d:/aghado01/science-facility/mcp/nushell-mcp/modules/nu-skills/nu-skills.nu).
- **Bi-directional Cross-Pointers**: Happy-path pages guide agents toward `par`, `jobs`, `dataspection`, `xq`, and `rg` with lightweight pointers to `stock/*`, while `stock/*` pages open with pointers back to their console equivalents.

Below is an analysis of the plan, covering steering accuracy, engine ergonomics, and recommended refinements.

---

## 2. Steering & Accuracy Assessment

To avoid incorrectly steering agents or generating false constraints, the guidance in specific topics needs precise nuance:

### A. Pipeline Bounding (`first N` vs. Live Streams)
* **The Risk**: An agent might over-generalize "never cap a live pipeline" into a rule that `first N` or `last N` is forbidden everywhere in Nushell.
* **Accurate Guidance**: 
  - **Forbidden**: Capping unbounded live external streams or process pipelines (e.g., `^rg pat | first 5` or `open huge_stream | first 5`) because it breaks stream accounting and bypasses payload quarantine.
  - **Encouraged**: Capping or slicing **already-bound / in-memory collections** (e.g., `$history.0 | first 5`, `ls | sort-by size -r | first 5`, or `$findings | first 10`).
  - *Action in Plan*: Ensure [sessions.md](file:///d:/aghado01/science-facility/mcp/nushell-mcp/skills/nushell/references/sessions.md) and [pipelines.md](file:///d:/aghado01/science-facility/mcp/nushell-mcp/skills/nushell/references/pipelines.md) explicitly state this distinction.

### B. Structured I/O & Large Payloads (`open` / `http get`)
* **The Risk**: Agents might think `open` is deprecated in favor of a custom wrapper.
* **Accurate Guidance**:
  - `open` and `http get` remain the standard Nushell commands for structured data.
  - For large or unknown outputs, agents should apply the disclosure ladder: check shape (`open data.json | shape`), read boundedly (`open data.json | read`), or quarantine in the background (`jobs spawn { open data.json }`), rather than dumping multi-megabyte objects directly into the MCP evaluation result.
  - *Action in Plan*: Keep [file-io.md](file:///d:/aghado01/science-facility/mcp/nushell-mcp/skills/nushell/references/file-io.md) and [data-analysis.md](file:///d:/aghado01/science-facility/mcp/nushell-mcp/skills/nushell/references/data-analysis.md) centered on standard `open`/`save`/`http`/`polars`, adding a concise 1-2 line disclosure steering note.

### C. Search Division of Labor (`rg` vs. `^rg` vs. `where` / `find`)
* **The Risk**: Confusing filesystem text search with in-memory structured filtering.
* **Accurate Guidance**:
  - **Repository / filesystem search**: Use the wrapped `rg` (structured JSON events / spine) or `^rg` (raw text escape hatch).
  - **In-memory table / list filtering**: Use standard Nushell `where` or `find`.
  - *Action in Plan*: Keep `where` and `find` on [posix-cheatsheet.md](file:///d:/aghado01/science-facility/mcp/nushell-mcp/skills/nushell/references/posix-cheatsheet.md) and [pipelines.md](file:///d:/aghado01/science-facility/mcp/nushell-mcp/skills/nushell/references/pipelines.md); keep [search.md](file:///d:/aghado01/science-facility/mcp/nushell-mcp/skills/nushell/references/search.md) focused strictly on ripgrep execution.

### D. Process Execution (`xq` vs. `complete` vs. `process capture`)
* **The Risk**: Agents reaching for `do { cmd } | complete` and getting uncontrolled stdout/stderr floods in tool results.
* **Accurate Guidance**:
  - Console default for externals is `xq <cmd> ...` (census, output capping, automated stashing over cap).
  - `process capture` (in `core/capture.nu`) is for wrapper authors needing raw streams.
  - Stock `do { cmd } | complete` is documented under `stock/advanced.md` and `stock/posix.md`.

### E. Builtin `inspect` vs. `shape`
* **The Risk**: Builtin `inspect` is a passthrough that prints to the terminal (non-existent under stdio MCP) and returns input unmodified, causing immediate token flood.
* **Accurate Guidance**:
  - `dataspection`'s `shape` is the census tool (`$x | shape`).
  - Native `inspect` is explained in `stock/inspect.md` as a terminal debug passthrough.

---

## 3. Engine & `nu-skills` Module Review

The proposed `nu-skills` CLI enhancements are clean. Here are technical requirements to guarantee cross-platform stability:

| Feature | Proposed Contract | Implementation Nuance |
|---|---|---|
| `nu-skills list` | 1-level listing of `references/` | Rows: `{topic: string, title: string, kind: "page"\|"branch", n: int, path: string}`. For branch, `topic` is `"stock"`, `kind: "branch"`, `n: <child-count>`. |
| `nu-skills list <branch>` | Children of `references/<branch>/` | e.g. `nu-skills list stock` returns rows for `stock/advanced`, `stock/mcp`, `stock/posix`, `stock/inspect`. |
| `nu-skills list --all` | Recursive leaf listing | Every leaf `.md` file path-qualified (e.g. `jobs`, `stock/advanced`). |
| `nu-skills read <topic>` | Markdown content | - Leaf (e.g. `jobs` or `stock/mcp`): returns file content.<br>- Branch (e.g. `stock`): returns a **generated Markdown table string** of its children (preserves the `nothing -> string` output contract).<br>- Path normalization: Tolerate trailing `.md` if passed (`stock/mcp.md` -> `stock/mcp`). |
| `nu-skills search <pattern>` | Search across `**/*.md` | `topic` returned must be normalized relative to `references/` with forward slashes on all platforms (`stock/advanced`). |

---

## 4. Planned Reference Matrix

```text
skills/nushell/
├── SKILL.md                            # Orientation, discipline, discovery mechanics (no static catalog)
└── references/
    ├── [Console Happy Path]
    │   ├── jobs.md                     # par, jobs, xq, process capture  --> Stock: stock/advanced
    │   ├── search.md                   # rg wrapper, spine on truncate   --> Stock: ^rg / find
    │   ├── dataspection.md             # shape, schema, spine, read, etc. --> Stock: stock/inspect
    │   ├── sessions.md                 # persistent REPL, $history, ok
    │   ├── mcp.md                      # nushell-mcp package setup       --> Stock: stock/mcp
    │   ├── gotchas.md                  # syntax traps, substrate gotchas
    │   ├── pipelines.md                # structured data pipelines       --> Stock: stock/posix
    │   ├── posix-cheatsheet.md         # console translations (xq, rg)   --> Stock: stock/posix
    │   ├── parity.md                   # platform parity, PATH handling  --> Stock: stock/posix
    │   ├── file-io.md                  # open/save + large file discipline
    │   ├── data-analysis.md            # http/polars/sqlite + disclosure
    │   └── advanced.md                 # custom defs, try/catch          --> Stock: stock/advanced
    └── stock/                          # Canonical Nushell (as shipped)
        ├── mcp.md                      # bare nu --mcp (no overlay, 10KB) --> Console: nu-skills read mcp
        ├── advanced.md                 # job spawn/recv/kill, complete   --> Console: nu-skills read jobs
        ├── posix.md                    # grep/find, complete, PATH list  --> Console: nu-skills read posix-cheatsheet
        └── inspect.md                  # builtin inspect passthrough     --> Console: nu-skills read dataspection
```

---

## 5. Verification & Test Plan (When Executing)

When ready to implement, verification should include:

1. **New Test Suite**: Create [tests/skills-v1.nu](file:///d:/aghado01/science-facility/mcp/nushell-mcp/tests/skills-v1.nu) (or equivalent `nu -n` test suite):
   - `nu-skills list` returns top-level pages + `stock` branch row with correct count.
   - `nu-skills list stock` lists the 4 stock leaves.
   - `nu-skills list --all` returns all 16 leaves.
   - `nu-skills read stock` returns a valid generated markdown table string.
   - `nu-skills read stock/advanced` (and with `.md`) returns the file content.
   - `nu-skills search` successfully finds matches in both root references and nested `stock/` references, verifying forward-slash topic format across Windows and Linux.
2. **Corpus Link Integrity Check**:
   - Automated scan verifying that all `nu-skills read <target>` links across all `.md` files resolve to existing pages.
3. **Smoke Test with `config.nu`**:
   - Verify `nu --config mcp/nushell-mcp/config.nu` loads cleanly without errors.

---

## 6. Conclusion

The plan in [grok-nushell-skills-inventory.md](file:///d:/aghado01/science-facility/issues/nushell-mcp/discussion/grok-nushell-skills-inventory.md) is ready for execution whenever you decide to proceed. The distinction between stock Nushell and augmented console capabilities is clean, preserving full stock knowledge while guiding agents toward high-discipline MCP interaction patterns.