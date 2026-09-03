You remembered the convention correctly. Today’s `.codex` placement was my mistake: I explicitly supplied that path after over-applying the generic scratch-directory instruction. Mdnav itself never defaulted there.

The intended resolution order is:

1. Explicit `workDir`.
2. Process-wide `MDNAV_WORK_DIR`.
3. `<first corpus target>\.doc-dive`.

That is documented in [README.md](</D:/aghado01/science-facility/mcp/mdnav/README.md:86>) and implemented in [engine.ts](</D:/aghado01/science-facility/mcp/mdnav/src/engine.ts:205>). The current MCP registration has no `MDNAV_WORK_DIR` override.

There is, however, a genuine MCP defect behind the migration trouble:

- The server owns one singleton engine.
- Switching artifact roots resets journal state but does not reset or reload document identities, indexes, or buffers.
- Consequently, the second corpus inherited the first corpus’s numbering—our observed `D004–D010` contamination.
- Although most MCP schemas advertise `workDir`, the handlers for index/profile/outline/read/batch/coverage/locate do not actually apply it. Compare [types.ts](</D:/aghado01/science-facility/mcp/mdnav/src/types.ts:406>) with [tools.ts](</D:/aghado01/science-facility/mcp/mdnav/src/tools.ts:111>) and [tools.ts](</D:/aghado01/science-facility/mcp/mdnav/src/tools.ts:234>).

So an MCP user can select the initial anchor, but cannot yet safely interleave multiple anchored sessions in one server process.

For this investigation I will now enforce:

- Never place mdnav state under `.codex`.
- Use `D:\aipithicus\aipithicus-issues\Doccer\.doc-dive` exclusively.
- Always pass the concrete artifact root and run stamp.
- Until the MCP defect is repaired or the server restarts, use the CLI’s explicit `--work-dir`/`--run` path for corpus operations rather than switching the singleton MCP engine between the two studies.

The permanent repair should:

1. Key engine state by normalized artifact root plus run.
2. Rehydrate inventory, indexes, identities, and read ledger when selecting a run.
3. Make every tool’s root selector effective—or remove the misleading argument.
4. Fail on ambiguous omitted roots instead of using whichever corpus was mounted last.
5. Add an A → B → A interleaving test proving identity, coverage, and journal isolation.
6. Strengthen the agent instruction to: “Mdnav artifacts are durable investigation state, not scratch; never place them under `.codex`.”

I have not changed mdnav source or configuration yet.