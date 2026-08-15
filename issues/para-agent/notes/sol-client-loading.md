Yes—that is the correct separation.

| Surface              | Invocation                                          | Terminal            | Protocol                                       |
| -------------------- | --------------------------------------------------- | ------------------- | ---------------------------------------------- |
| Pane interaction     | Nu launches `^agy`                                  | ConPTY/TTY required | Interactive TUI                                |
| `delegate` mediation | Node launches `agy.exe` directly with `shell:false` | Pipes; no TTY       | Explicit `--print --output-format stream-json` |

The governing rule should be: invocation mode is explicit and owned by para-agent, never inferred from ambient shell behavior or TTY detection.

The abstractions should remain composable rather than becoming one profile per client/shell/application combination:

- Surface policy: pane versus delegated mediation.
- Shell profile: Nu/PowerShell/Bash syntax and interactive launch conventions. Relevant only to panes.
- Application adapter: AGY/Claude/Codex executable, fixed arguments, stdin framing, structured events, and terminal evidence. Relevant to `delegate`.
- MCP-host environment binding: executable resolution, inherited environment, credential/config visibility, and readiness checks for Codex, Claude, Antigravity, etc.
- Invocation receipt: records which policies were selected, resolved binary/version, stdio topology, and readiness result—without exposing secrets or host filesystem topology publicly.

For AGY specifically:

- Pane policy should require a PTY and use explicit Nu external-command syntax, `^agy`.
- Delegate policy should forbid shell mediation and require direct `agy.exe --print --output-format stream-json ...`.
- A cheap delegated readiness probe can use `/model`; we verified that this path returns valid stream JSON, exits 0, and consumes zero tokens.
- If credentials/config are unavailable to the actual MCP host, delegation should fail quickly with a typed readiness error instead of allowing AGY’s 60-second interactive OAuth fallback to hang a headless call.

Our earlier sandbox failure was a diagnostic-harness confounder: the Codex command sandbox could not read `~/.gemini/config`. Outside that sandbox, AGY print mode worked, and the representative MCP processes we inspected run as your interactive Windows account. No ACL modification occurred or is presently justified.

This gives the AGY issue a useful architectural outcome: make launch topology, shell involvement, and interaction mode first-class policy so Nu—or any future shell—cannot silently select application semantics.

# User notes

Need to think about child process inheritance
Certain ambient overrides for PATH and certain client specific env vars potentially
hygienic way to store client specific adaptations in a central source of truth, but not necessarily json
