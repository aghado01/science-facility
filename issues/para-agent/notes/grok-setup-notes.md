Yes. Grok can discover shared material from a central directory you point it at, without reading Claude’s or Cursor’s homes. That is a different mechanism from the compatibility scan we just turned off.

The lever is per-app opt-in to a hub, not GROK_HOME and not “scan ~/.claude.” GROK_HOME relocates Grok’s entire private tree (auth, sessions, logs). That is the wrong knob for sharing.

What Grok can actually point elsewhere

┌────────────────┬──────────────────┬────────────────────────────────────────────────────────────────────────────┐
│ Kind           │ Extra path       │ How                                                                        │
│                │ outside the      │                                                                            │
│                │ workspace?       │                                                                            │
├────────────────┼──────────────────┼────────────────────────────────────────────────────────────────────────────┤
│ Skills         │ Yes              │ [skills] paths = ["D:/aghado01/science-facility/skills"] in ~/.grok/       │
│                │                  │ config.toml. Recursive walk of SKILL.md trees. ignore / disabled for       │
│                │                  │ leftovers.                                                                 │
├────────────────┼──────────────────┼────────────────────────────────────────────────────────────────────────────┤
│ Plugins        │ Yes              │ [plugins] paths = [...], plus --plugin-dir for a session.                  │
├────────────────┼──────────────────┼────────────────────────────────────────────────────────────────────────────┤
│ MCP            │ Explicit only    │ No “scan this folder for servers.” You name each server in ~/.grok/config  │
│                │                  │ .toml ([mcp_servers.*]) or in a project .mcp.json / .grok/config.toml,     │
│                │                  │ with command/args aimed at the hub’s implementation (as this repo already  │
│                │                  │ does for para-agent).                                                      │
├────────────────┼──────────────────┼────────────────────────────────────────────────────────────────────────────┤
│ Standing       │ Only via Grok’s  │ Always-on: $GROK_HOME/rules/ (default ~/.grok/rules/). There is no [rules] │
│ instructions   │ own rules dir    │ paths. Junction/symlink that folder at the hub, or put files there.        │
├────────────────┼──────────────────┼────────────────────────────────────────────────────────────────────────────┤
│ Agents /       │ Partial          │ ~/.grok/agents/, [agent] definition = "/abs/path.md", GROK_AGENT. No extra │
│ personas       │                  │ agent-directory list.                                                      │
├────────────────┼──────────────────┼────────────────────────────────────────────────────────────────────────────┤
│ Hooks          │ Partial          │ ~/.grok/hooks/*.json, hooks in config.toml, /hooks-add <path>.             │
└────────────────┴──────────────────┴────────────────────────────────────────────────────────────────────────────┘

science-facility is already the hub you described (skills/, mcp/, a short AGENTS.md). The missing piece is each client independently listing that hub, instead of one client eating another’s ~/.… tree.

Discovery vs lookup (this is the token part)

Pointing [skills] paths at D:\aghado01\science-facility\skills will put those skills in every Grok session’s skill listing (name + description, always). That is useful and also a standing cost.

Do not point it at the whole of science-facility, or at research/skills/ — Grok walks recursively.

You already measured this on Claude: the expensive part is eager listings and MCP schemas, not the files sitting on disk. Shared corpus + on-demand (mdnav / a skill help-desk MCP) is cheaper than auto-registering every skill on every harness.

A clean split:

• Always-on, tiny: Grok-only standing rules in ~/.grok/rules/ (commits-on-main, no unsolicited subagents, scratch policy). App-specific. Do not reuse ~/.claude/Claude.md.
• Shared, opt-in listing: a few SKILL.md packages under science-facility/skills, each app that wants them adds its own extra-paths.
• Shared, on demand: the rest of the corpus, reached through MCP when needed.

Hub-and-spoke, not reach-in

science-facility/          ← source of truth
  skills/                  ← SKILL.md packages
  mcp/                     ← server implementations
  instructions/            ← optional shared prose (not auto-loaded by Grok)

~/.grok/config.toml        ← Grok opt-in: skills.paths, mcp_servers
~/.claude/…                ← Claude opt-in only
~/.cursor/…                ← Cursor opt-in only
~/.codex/…                 ← Codex opt-in only

Each app’s config names the hub. None of them should scan another app’s home. Junctions are fine where a tool has no extra-path (Grok rules/agents).

Claude does not have Grok’s [skills] paths. Its usual extra-dir setting (additionalDirectories) is sandbox/read access, not skill discovery. For Claude, the honest pointer is a junction under ~/.claude/skills/<name> → science-facility/skills/<name>, or a plugin. Codex already has its own ~/.codex/skills/ (chat-export, nu) and ~/.codex/AGENTS.md.

What is still leaking besides Grok compat

Grok compat is off. Remaining cross-talk, from this machine:

┌───────────────┬────────────────────────────────────────────────────────────────────────────────────────────────┐
│ App           │ Silent ingest worth cleaning                                                                   │
├───────────────┼────────────────────────────────────────────────────────────────────────────────────────────────┤
│ Grok (this    │ Still loads 16 permission rules from ~/.claude/settings.json. Compat cells do not gate that.   │
│ session +     │ Repo-root Claude.md still loads as a generic project file.                                     │
│ inspect)      │                                                                                                │
├───────────────┼────────────────────────────────────────────────────────────────────────────────────────────────┤
│ Claude        │ Global ~/.claude/Claude.md; ~/.claude.json MCP (filesystem, fetch, git, pwsh_exec); settings   │
│               │ .json enabledMcpjsonServers (para-agent, pwsh_exec, nushell); enableWorkflows: true while the  │
│               │ global file forbids subagents; permissions that explicitly allow ~/.cursor, ~/.codex, ~/.      │
│               │ gemini.                                                                                        │
├───────────────┼────────────────────────────────────────────────────────────────────────────────────────────────┤
│ Cursor        │ ~/.cursor/mcp.json is the same four generic servers.                                           │
├───────────────┼────────────────────────────────────────────────────────────────────────────────────────────────┤
│ Codex         │ Separate tree (AGENTS.md, skills, plugins including Superpowers). Not what Grok was reading,   │
│               │ but it is a third copy of “global agent policy.”                                               │
└───────────────┴────────────────────────────────────────────────────────────────────────────────────────────────┘

Generic MCPs (filesystem / fetch / git) are the classic silent cost: they are not in this repo’s .mcp.json, they live in Claude+Cursor user configs, and Grok was inheriting Claude’s copies.

Recommended Grok wiring (when you want it)

[skills]
paths = ["D:/aghado01/science-facility/skills"]
# ignore = ["D:/aghado01/science-facility/skills/doc-dive"]  # drafts

# MCP: name servers here if they should follow you across repos.
# Keep project-only servers in that repo's .mcp.json.

I have not added that yet. Listing brief-execution, context-hygiene, karpathy, refactor on every Grok session is a product choice, not a default.

Natural next slices, in order:

1. Write a short ~/.grok/rules/ file with Grok-native standing policy (strip Claude-only bits: MEMORY, nushell-mcp, pwsh_exec-for-Claude).
2. Decide which science-facility/skills are always-listed vs lookup-only, then set [skills] paths.
3. Audit Claude settings.json / .claude.json and Cursor mcp.json the same way: disable reach-in, register hub servers only where that app needs them.