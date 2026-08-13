Understood — mining for transferable discipline, not preserving the `ctx_*` product surface.

The useful standalone ideas under the context-mode material:

**1. Context is the scarce resource**
Anything that can produce unbounded or large output should not land raw in the conversation. Prefer a path that returns only findings.

**2. Capture fully, filter later**
If you truncate or narrow _before_ the data is durable (head, early filters, “just the first 20 lines”), the rest is gone. Capture complete output somewhere queryable; narrow downstream. Same principle as not discarding evidence before you know what questions you’ll ask.

**3. Always surface findings explicitly**
If analysis happens off-context (sandbox, subprocess, separate file), the only thing that enters the session is what you print. No print = wasted work. Prefer concrete IDs, paths, counts, and values over dumps.

**4. Don’t double-load**
Data already present in the conversation should not be re-injected as a parameter “to index” or re-process. Use what’s there, or write it out once and work from the durable copy.

**5. Right tool / language for the job**
Shell for simple pipes and native tools. JS/Python when structure or parsing gets non-trivial. Don’t stay in Bash once you’re embedding `python -c` or long `jq` chains.

**6. Batch related questions**
When the same corpus will answer several questions, ask them together instead of sequential re-reads.

**7. Edit boundary**
Analysis paths (sandbox, extract, summarize) are for reading. Files you will change still go through normal read/edit tools so you keep fidelity and control.

**8. Uncertainty default**
When output size is unknown, assume it may be large and choose the protective path.

---

These are independent of any particular MCP. They map cleanly onto general agent hygiene (and onto mdnav-style selective reading, para-agent’s receipt model, etc.).

I can rewrite the distilled skill as **standalone context-hygiene / large-output guidelines** with no `ctx_*` vocabulary — same density as the karpathy draft. Want that as the next file under `skills/` (e.g. `skills/context-hygiene/` or folded into brief-execution / AGENTS.md), or keep iterating on the extracted principles first?
