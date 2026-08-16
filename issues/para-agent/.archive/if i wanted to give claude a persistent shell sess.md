<img src="https://r2cdn.perplexity.ai/pplx-full-logo-primary-dark%402x.png" style="height:64px;margin-right:32px"/>

# if i wanted to give claude a persistent shell session, how could i go about doing that

Claude can already get a **persistent shell** in two main ways: Claude Code does it out of the box, and the Messages API lets you own a long-lived bash process yourself.[^1_1][^1_2]

## Claude Code (built-in)

In Claude Code, Bash is not one-shot. The first bash tool call starts a subprocess; later calls reuse that same process, so cwd, env vars, aliases, shell options, and files all carry forward.[^1_2]

```text
# session A
export FOO=bar && cd /tmp && pwd

# later bash call in same Claude Code session
echo $FOO && pwd   # still bar, still /tmp
```

Useful controls:

- **Allow/deny lists** in permissions so common commands auto-approve while dangerous ones stay gated[^1_2]
- **`restart`** semantics (or starting a fresh Claude session) when state is polluted[^1_1]
- **Conversation** resume with `claude -c` / `claude -r` — that restores chat history, not a frozen OS shell process after you fully exit Claude Code[^1_3]

Gotchas that matter at scale: env pollution, cwd drift, lingering background jobs (`&`), and truncated huge stdout. Prefer redirecting large output to a file and reading it.[^1_2]

## Anthropic API (you own the process)

The bash tool is a **client tool**: Claude only emits `tool_use` with a `command`; your app runs it and returns `tool_result`. Persistence is entirely on your side.[^1_1]

Minimal pattern from the docs:

```python
import subprocess, uuid

class BashSession:
    def __init__(self):
        self.process = subprocess.Popen(
            ["/bin/bash"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            start_new_session=True,
            text=True,
        )

    def execute_command(self, command: str) -> str:
        sentinel = f"__CLAUDE_BASH_DONE_{uuid.uuid4().hex}__"
        self.process.stdin.write(f"{command}\necho {sentinel}\n")
        self.process.stdin.flush()
        out = []
        for line in self.process.stdout:
            if sentinel in line:
                break
            out.append(line)
        return "".join(out)

    def restart(self):
        self.process.kill()
        self.process.wait()
        self.__init__()
```

Wire it like this:

1. Register `{"type": "bash_20250124", "name": "bash"}`.
2. On each `tool_use`, run `command` (or `restart: true`) in that session.
3. Return stdout/stderr as `tool_result` and loop while `stop_reason == "tool_use"`.[^1_1]

The API itself is stateless; only your live bash process (or a container you attach to) keeps state between HTTP turns.[^1_1]

## Stronger persistence options

| Goal | Approach |
| :-- | :-- |
| Multi-step install → edit → run in one chat | Claude Code bash, or API `BashSession` above [^1_1][^1_2] |
| Survive SSH drops / leave Claude running | Run Claude Code inside `tmux` or `screen`; detach/reattach [^1_4] |
| Survive full Claude Code exit | Files + env live on disk; re-source a setup script or use a project `CLAUDE.md` for “how to enter this env” [^1_3] |
| Isolated / safer agent shell | Long-lived Docker container or VM; exec into the same container for every tool call [^1_1] |
| Custom agent (MCP / your loop) | MCP tool or local agent that holds one PTY/bash and exposes `run` + `restart` |

## Practical recommendations

For day-to-day Claude Code work, you already have persistence inside a session—lean on that and tighten permissions rather than reinventing the shell.[^1_2]

If you are building an agent (Python/.NET, MCP, etc.), keep **one** bash (or container exec) per agent run, use a sentinel for output framing, add timeouts that kill the process group, and isolate with a container as the real security boundary—allowlists alone are tripwires, not sandboxing.[^1_1]

If you want shell state to outlive Claude process exits (e.g. a dedicated “Claude workspace” container you always attach to), say whether you prefer Docker, WSL, or bare Linux and we can sketch that layout next.
<span style="display:none">[^1_10][^1_11][^1_12][^1_13][^1_5][^1_6][^1_7][^1_8][^1_9]</span>

<div align="center">⁂</div>

[^1_1]: https://platform.claude.com/docs/en/agents-and-tools/tool-use/bash-tool

[^1_2]: https://www.youtube.com/watch?v=ggqdeOhrPwc

[^1_3]: https://aiopsschool.com/blog/mastering-claude-code-sessions-continue-resume/

[^1_4]: https://www.reddit.com/r/ClaudeCode/comments/1r6cou0/how_do_you_keep_claude_code_running_247_and/

[^1_5]: https://www.reddit.com/r/ClaudeCode/comments/1sdah6c/a_way_to_give_claude_code_persistent_memory/

[^1_6]: https://www.facebook.com/groups/claudecode/posts/1620861545729727/

[^1_7]: https://www.linkedin.com/posts/adocomplete_28-days-of-claude-api-day-19-the-bash-activity-7430505288274812928-L703

[^1_8]: https://www.producttalk.org/give-claude-code-a-memory/

[^1_9]: https://codesignal.com/learn/courses/foundation-getting-started-with-claude-code/lessons/starting-claude-code-sessions

[^1_10]: https://blog.santhoshj.com/how-to-give-claude-code-persistent-memory-across-sessions/

[^1_11]: https://www.mindstudio.ai/blog/persistent-memory-claude-code-short-long-term-scoped

[^1_12]: https://generativeai.pub/how-i-wired-persistent-memory-into-every-claude-code-session-001970318cd5

[^1_13]: https://github.com/anthropics/claude-code/issues/4319


---

# i mean giving claude agent a persistent shell to work interactively with

You want a **real interactive shell** the agent can drive—REPLs, prompts, TUIs, long-running processes—not one-shot `bash -c`. Claude Code’s built-in bash keeps cwd/env across calls, but it is still command-oriented, not a full PTY you can type into and scrape.[^2_1][^2_2]

Three practical patterns work well.

## 1. tmux as the agent’s terminal (best default)

Give Claude a private tmux session. It “types” with `send-keys` and “reads the screen” with `capture-pane`. That is the standard way agents drive interactive CLIs (python, gdb, psql, installers, etc.).[^2_3][^2_4]

```bash
SOCKET_DIR="${TMPDIR:-/tmp}/claude-tmux-sockets"
mkdir -p "$SOCKET_DIR"
SOCKET="$SOCKET_DIR/agent.sock"
SESSION=agent-shell

# create once
tmux -S "$SOCKET" new-session -d -s "$SESSION" -n shell
tmux -S "$SOCKET" send-keys -t "$SESSION":0.0 -l -- 'cd ~/work && exec bash -l'
tmux -S "$SOCKET" send-keys -t "$SESSION":0.0 Enter
```

Agent operations (via normal Bash tool or a thin skill):

```bash
# type a line (literal; no shell expansion)
tmux -S "$SOCKET" send-keys -t "$SESSION":0.0 -l -- 'python3 -q'
tmux -S "$SOCKET" send-keys -t "$SESSION":0.0 Enter

# read last ~200 lines of the pane
tmux -S "$SOCKET" capture-pane -p -J -t "$SESSION":0.0 -S -200

# Ctrl-C / Ctrl-D
tmux -S "$SOCKET" send-keys -t "$SESSION":0.0 C-c
tmux -S "$SOCKET" send-keys -t "$SESSION":0.0 C-d
```

Put the recipe in a Claude skill / `CLAUDE.md` so the agent always uses the same socket + session name and knows the poll loop: send → sleep/backoff → capture until prompt appears.[^2_3]

Why this wins for you:

- Survives Claude Code restarts if the tmux session stays up
- True interactivity (prompts, pagers, REPLs)
- You can attach yourself: `tmux -S "$SOCKET" attach -t "$SESSION"` and watch or intervene
- Easy isolation: private socket, not your personal tmux[^2_5][^2_3]


## 2. MCP PTY shell server

If you want first-class tools (`start_session`, `write`, `read`, `send_keys`) instead of teaching Claude tmux, run a node-pty MCP server and register it with Claude Code.[^2_6][^2_7][^2_8]

Examples in the wild:

- **interactive-shell-mcp** — persistent PTY + headless xterm so the agent sees a real terminal buffer[^2_6]
- **Shell Exec** — stateful shell via `node-pty` (cwd, env, background jobs, interactive cmds)[^2_7]

Sketch:

```bash
# install/run whatever PTY MCP you pick, then:
claude mcp add interactive-shell -- node /path/to/server.js
```

Claude then gets tools like “open shell”, “send input”, “read screen”, “list sessions” instead of raw tmux. Better UX for the model; one more process to run and secure.[^2_8][^2_6]

## 3. Own the agent loop (API / custom harness)

If you are not on Claude Code but building the agent yourself: keep **one PTY** (or one Docker `exec -it`) for the whole run, and expose tools that write bytes + read the buffer. Same idea as Anthropic’s bash tool, but with a real PTY and a sentinel/timeout around each turn.[^2_1]

```text
Agent tools:
  shell_open() / shell_restart()
  shell_write(text | ctrl key)
  shell_read(lines=200 | since_marker)
  shell_wait_for(regex, timeout_ms)
```

Run that PTY inside a container if you want the session to outlive the agent process and stay sandboxed.[^2_1]

## What to pick

| Need | Approach |
| :-- | :-- |
| Interactive REPL/TUI inside Claude Code today | **tmux + send-keys/capture-pane** skill [^2_3] |
| Clean tool API, multi-session PTY | **MCP node-pty server** [^2_6][^2_7] |
| Custom agent / multi-hour autonomous runs | Your harness owns one PTY or container shell [^2_1] |
| You also want to watch/intervene | tmux (attach anytime) [^2_5] |

## Minimal “ship it tonight” setup

1. Create the private tmux session once (script above).
2. Add a short skill telling Claude: always use that socket/session; never spawn ad-hoc shells for interactive work; after every `send-keys`, `capture-pane` until the prompt matches.[^2_3]
3. Optionally run Claude Code itself inside another tmux window so *your* chat also survives disconnects.[^2_5]
4. Harden: dedicated user or container, allowlist who can talk to the socket, no shared personal tmux.[^2_1]

Claude Code’s built-in bash is enough for `cd && export && make`. For “sit in a shell and work interactively,” **tmux is the reliable pattern**; **MCP PTY** is the cleaner long-term interface if you want to invest a bit more.[^2_6][^2_3]

If you say whether this is **Claude Code on your San Jose Linux/WSL box** vs a **custom agent loop**, the next step is a concrete skill file + MCP config tailored to that path.
<span style="display:none">[^2_10][^2_11][^2_12][^2_13][^2_14][^2_15][^2_16][^2_17][^2_18][^2_19][^2_20][^2_21][^2_22][^2_23][^2_24][^2_25][^2_26][^2_27][^2_28][^2_29][^2_30][^2_31][^2_32][^2_33][^2_9]</span>

<div align="center">⁂</div>

[^2_1]: https://platform.claude.com/docs/en/agents-and-tools/tool-use/bash-tool

[^2_2]: https://www.youtube.com/watch?v=ggqdeOhrPwc

[^2_3]: https://github.com/mitsuhiko/agent-stuff/blob/main/skills/tmux/SKILL.md

[^2_4]: https://mcpservers.org/agent-skills/firecrawl/tmux

[^2_5]: https://hboon.com/using-tmux-with-claude-code/

[^2_6]: https://github.com/lightos/interactive-shell-mcp

[^2_7]: https://mcpmarket.com/server/shell-exec

[^2_8]: https://lobehub.com/mcp/lightos-interactive-shell-mcp

[^2_9]: https://www.reddit.com/r/ClaudeAI/comments/1qyzolz/running_claude_as_a_persistent_agent_changed_how/

[^2_10]: https://www.facebook.com/groups/claudeaicommunity/posts/1247989420701556/

[^2_11]: https://www.youtube.com/watch?v=DpfLbBuhHOg

[^2_12]: https://aimaker.substack.com/p/how-i-turned-claude-code-into-personal-ai-agent-operating-system-for-writing-research-complete-guide

[^2_13]: https://www.producttalk.org/how-to-use-claude-code-features/

[^2_14]: https://github.com/anthropics/claude-code/issues/4319

[^2_15]: https://github.com/open-webui/open-webui/discussions/22574

[^2_16]: https://code.claude.com/docs/en/mcp

[^2_17]: https://code.claude.com/docs/en/agent-view

[^2_18]: https://www.mindstudio.ai/blog/build-openclaw-like-agent-without-openclaw

[^2_19]: https://news.ycombinator.com/item?id=48200327

[^2_20]: https://www.reddit.com/r/ClaudeAI/comments/1jf4hnt/setting_up_mcp_servers_in_claude_code_a_tech/

[^2_21]: https://www.reddit.com/r/ClaudeAI/comments/1lp9c7p/my_breakthrough_workflow_multiagent_collaboration/

[^2_22]: https://www.reddit.com/r/ClaudeCode/comments/1sdgfxg/using_claude_code_as_a_persistent_agent_%C3%A0_la/

[^2_23]: https://www.sitepoint.com/terminal-based-agent-engineering-the--claude-code--workflow/

[^2_24]: https://www.blacklanternsecurity.com/red-run/mcp-servers/

[^2_25]: https://www.youtube.com/watch?v=pHq5DcNZL8k

[^2_26]: https://okhlopkov.com/claude-code-setup-mcp-hooks-skills-2026/

[^2_27]: https://www.devas.life/i-made-a-claude-code-session-manager-for-tmux/

[^2_28]: https://www.reddit.com/r/ClaudeCode/comments/1osd9y1/anyone_else_using_tmux_as_a_bootleg_orchestration/

[^2_29]: https://www.truefoundry.com/blog/best-mcp-servers-for-claude-code

[^2_30]: https://www.linkedin.com/pulse/tmux-claude-code-macos-complete-setup-guide-jason-vertrees-8am0c

[^2_31]: https://blogs.cisco.com/ai/identifying-and-remediating-a-persistent-memory-compromise-in-claude-code

[^2_32]: https://www.reddit.com/r/ClaudeCode/comments/1t69d00/psa_claude_codes_bash_tool_runs_binzsh_on_macos/

[^2_33]: https://www.youtube.com/watch?v=nj_nVIfXRA8


---

# i actually want to do something whacky, which is have claude control and utilize agy

Whacky and very doable. You’re describing a **supervisor/worker split**: Claude Code as architect/reviewer, **`agy` (Antigravity CLI)** as the executor that burns Gemini (or other) tokens on scaffolding, search, and bulk edits. People already run that pattern; there’s even a skill for it.[^3_1][^3_2]

## Architecture

```text
You ──► Claude Code (plan, verify, gate)
              │
              ├─ headless:  agy -p "…" --dangerously-skip-permissions
              ├─ session:   agy -c / --conversation <id>
              └─ interactive TUI: tmux + send-keys into a live `agy`
                         │
                         ▼
                   agy agent (edits repo, subagents, tools)
                         │
                         ▼
                   shared workspace + AGENTS.md / git
```

Claude never “is” agy. It **drives** agy the same way it drives any interactive shell: print-mode for one-shots, or a persistent tmux pane for a real TUI session.[^3_3][^3_4]

## Mode A — Headless (reliable, start here)

`agy` has a non-interactive print mode built for scripts and outer agents:[^3_3]

```bash
# one-shot job
agy -p "Scaffold a pytest suite for src/cluster/ matching existing style. Do not commit." \
  --dangerously-skip-permissions \
  --print-timeout 15m

# resume last conversation in this cwd
agy -c -p "Fix the failures from the last run; re-run tests."

# resume a specific conversation
agy --conversation <id> -p "Continue from the open TODO list."
```

Useful flags from the real CLI help:[^3_3]


| Flag | Role |
| :-- | :-- |
| `-p` / `--print` | Single prompt, print response, exit |
| `-c` / `--continue` | Resume most recent convo |
| `--conversation` | Resume by ID |
| `--dangerously-skip-permissions` | No y/n tool prompts (needed under Claude) |
| `--print-timeout` | Cap wait (default 5m) |
| `--sandbox` | Restrict terminal |
| `-i` / `--prompt-interactive` | Seed prompt then stay in TUI |

**Claude skill sketch** (put under `.claude/skills/agy-exec/SKILL.md`):

```markdown
---
name: agy-exec
description: Delegate bulk coding/search/scaffold work to Antigravity CLI (agy).
---

You are the supervisor. agy is the worker.

When the user wants bulk implementation, multi-file search, or token-heavy
exploration, run agy headlessly instead of doing it yourself.

Protocol:
1. Write a crisp task prompt to /tmp/agy-task.md (goal, constraints, files, done-when).
2. Run:
   agy -p "$(cat /tmp/agy-task.md)" --dangerously-skip-permissions --print-timeout 15m
3. Inspect git status / diff / tests yourself.
4. Accept, amend with another agy -c -p "…", or rewrite yourself.
5. Never let agy commit or push unless the user explicitly asked.

Shared contract lives in AGENTS.md — both agents must honor it.
```

That matches the documented “Claude designs/reviews, agy executes” workflow.[^3_2]

## Mode B — Persistent interactive `agy` (the fun path)

For a long-lived agy TUI Claude can poke mid-session, park it in a **private tmux** and drive it with keystrokes + pane capture — same pattern as any interactive CLI.[^3_5][^3_4]

```bash
SOCK="${TMPDIR:-/tmp}/claude-agy.sock"
SESS=agy-worker

tmux -S "$SOCK" new-session -d -s "$SESS" -c "$PWD"
tmux -S "$SOCK" send-keys -t "$SESS" -l -- 'agy --dangerously-skip-permissions'
tmux -S "$SOCK" send-keys -t "$SESS" Enter
# wait until capture-pane shows the agy prompt, then:

# Claude "types" a goal
tmux -S "$SOCK" send-keys -t "$SESS" -l -- 'Refactor @src/tda to use the new filtration API; keep public tests green.'
tmux -S "$SOCK" send-keys -t "$SESS" Enter

# Claude "reads the screen"
tmux -S "$SOCK" capture-pane -p -J -t "$SESS" -S -300

# interrupt / approve if needed
tmux -S "$SOCK" send-keys -t "$SESS" C-c   # stop stream
tmux -S "$SOCK" send-keys -t "$SESS" y     # confirm tool, if prompts still on
```

You can attach anytime and watch the circus:

```bash
tmux -S "$SOCK" attach -t "$SESS"
```

Inside agy, Claude can also fire **async subagents** (`/agent …`) so one outer Claude turn fans out into parallel Gemini workers.[^3_6][^3_3]

## Mode C — Existing skill

If you want something off-the-shelf first:

- **[markfulton/claude-antigravity-agents](https://github.com/markfulton/claude-antigravity-agents)** — Claude Code skill that delegates coding/review/analysis/research jobs to `agy` sub-agents (save Claude tokens, second model, parallel work).[^3_1]

Install that, then layer your own tmux/session conventions on top once you hate the defaults.

## Shared brain (don’t skip this)

Both agents must share one contract or they thrash the tree:[^3_2][^3_3]

```markdown
# AGENTS.md  (repo root — agy loads this)
# also mirror key bits into CLAUDE.md

## Roles
- Claude Code: architecture, API design, review, final merge decisions
- agy: bulk edits, test scaffolding, repo search, mechanical refactors

## Hard rules
- No force-push, no secrets, no deleting .git
- Prefer small commits only when asked; default = uncommitted diff
- Run the project test command after substantive edits
- Touch only paths listed in the task prompt unless blocked

## Done-when template
agy tasks must end with: summary, files touched, commands run, open risks
```

Optional: point both at the same MCP servers / memory files so they see the same tools and project lore.[^3_3]

## Permissions and safety

Under Claude you almost always want:

```bash
agy ... --dangerously-skip-permissions
```

so agy doesn’t sit on a `y/n` prompt Claude never sees.[^3_7][^3_3]

Still sandbox the blast radius:

- Prefer `--sandbox` for exploratory jobs[^3_3]
- Dedicated git worktree or branch per agy run (`git worktree add ../wt-agy -b agy/job-…`)
- Claude reviews `git diff` before anything lands on main
- Cap `--print-timeout`; kill the tmux session if it loops
- Remember **two agents writing the same files** → use one writer at a time or separate worktrees


## Recommended “whacky but sane” setup

1. Install/auth `agy`, confirm `agy --version` and a manual `agy -p "ping"`.[^3_8]
2. Drop `AGENTS.md` + a short Claude skill (`agy-exec`).[^3_2]
3. Day-to-day: **Mode A** headless dispatch from Claude.
4. For multi-turn “pair with Gemini in a pane”: **Mode B** tmux session Claude owns.[^3_4]
5. Claude’s job after every handoff: diff, tests, accept/reject — never trust the worker blindly.[^3_2]

## Example Claude turn

```text
You (to Claude):
  Have agy implement persistent homology smoke tests for the SPC cluster
  module. You design the API surface; agy writes tests + fixtures; you review.

Claude:
  1. edits AGENTS.md / writes /tmp/agy-task.md
  2. runs agy -p "$(cat /tmp/agy-task.md)" --dangerously-skip-permissions
  3. git diff + pytest
  4. either agy -c -p "fix X" or patches itself
  5. reports back with the contract checklist
```

That’s the whole trick: **Claude keeps the steering wheel; agy is a powerful, disposable shell-resident coworker** with its own model budget and async subagents.[^3_2][^3_3]

If you want, next step can be a ready-to-drop `SKILL.md` + tmux wrapper script tailored to your repo layout (worktree path, test command, no-commit policy).
<span style="display:none">[^3_10][^3_11][^3_12][^3_13][^3_14][^3_15][^3_16][^3_17][^3_18][^3_19][^3_20][^3_21][^3_22][^3_23][^3_9]</span>

<div align="center">⁂</div>

[^3_1]: https://www.facebook.com/groups/vibecodinglife/posts/2077501029505090/

[^3_2]: https://www.reddit.com/r/ClaudeCode/comments/1ugs23i/using_the_antigravity_cli_agy_as_a_subagent/

[^3_3]: https://dev.to/arindam_1729/antigravity-cli-a-hands-on-guide-to-googles-terminal-coding-agent-5bc7

[^3_4]: https://github.com/mitsuhiko/agent-stuff/blob/main/skills/tmux/SKILL.md

[^3_5]: https://antigravity.google/docs/cli/using

[^3_6]: https://www.datacamp.com/tutorial/antigravity-cli

[^3_7]: https://dev.to/gde/using-googles-new-ai-command-line-assistant-antigravity-cli-agy-and-yolos-no-confirmation-mode-10d

[^3_8]: https://learn.arm.com/install-guides/antigravity/

[^3_9]: https://www.youtube.com/watch?v=eA9Zf2-qYYM

[^3_10]: https://aimaker.substack.com/p/how-i-turned-claude-code-into-personal-ai-agent-operating-system-for-writing-research-complete-guide

[^3_11]: https://www.reddit.com/r/google_antigravity/comments/1ubr67l/using_the_antigravity_cli_agy_as_a_subagent/

[^3_12]: https://www.youtube.com/watch?v=CvLkhGWZlvE

[^3_13]: https://www.linkedin.com/pulse/how-use-claude-computer-build-ai-agent-non-engineers-allie-k-miller-fcsie

[^3_14]: https://code.claude.com/docs/en/skills

[^3_15]: https://www.youtube.com/watch?v=UmuYiJuw3uM

[^3_16]: https://www.mindstudio.ai/blog/claude-code-computer-use-mac-setup-guide

[^3_17]: https://www.reddit.com/r/google_antigravity/comments/1p5atm8/how_to_run_antigravity_via_cli/

[^3_18]: https://discuss.ai.google.dev/t/antigravity-cli-documentation-lacks-invoke-command/146893

[^3_19]: https://antigravity.google/product/antigravity-cli

[^3_20]: https://codelabs.developers.google.com/antigravity-cli-hands-on

[^3_21]: https://www.youtube.com/watch?v=jEBjzIUn4-E\&vl=en

[^3_22]: https://www.youtube.com/watch?v=yMJcHcCbgi4

[^3_23]: https://github.com/google-antigravity/antigravity-cli


---

# i dont understand what tmux is

**tmux** is a program that runs *inside* your terminal and hosts other terminal programs. Think of it as a small window manager for the command line: sessions keep running even when you close the window or disconnect.[^4_1][^4_2]

## Everyday analogy

Without tmux:

```text
You open Terminal → run `agy` → close Terminal
→ agy dies
```

With tmux:

```text
You open Terminal → start tmux → run `agy` inside it → close Terminal
→ agy keeps running in the background
→ later you reopen Terminal and “reattach”
→ you’re back looking at the same agy, mid-conversation
```

It’s like minimizing an app instead of quitting it — except for terminal programs.[^4_3][^4_1]

## The three layers (only these matter)

| Layer | What it is | Rough GUI equivalent |
| :-- | :-- | :-- |
| **Session** | A named workspace that can detach/reattach | A saved virtual desktop |
| **Window** | A full-screen tab inside a session | A browser tab |
| **Pane** | A split region inside a window | Split editor panels |

You can ignore windows/panes at first. **Session + detach/attach** is 90% of the value.[^4_2]

## Core commands

```bash
# install (examples)
sudo apt install tmux          # Debian/Ubuntu
brew install tmux              # macOS

tmux                           # start a session (you’re “inside” tmux now)
# ... run whatever you want: agy, htop, vim, etc.

# Detach (leave things running, return to normal shell):
# press Ctrl+b, then d

tmux ls                        # list sessions
tmux attach                    # reattach to the last one
tmux attach -t myname          # reattach by name

tmux new -s agy-worker         # start a named session
tmux kill-session -t agy-worker
```

Default shortcut prefix is **Ctrl+b**. Then:

- `d` — detach
- `c` — new window
- `%` / `"` — split panes
- arrow keys — move between panes

You only need detach/attach for the Claude + agy idea.[^4_1]

## Why it came up for Claude + agy

`agy` is often an **interactive TUI** (full-screen terminal UI). Claude’s normal bash tool is great at “run this command, give me the output,” but awkward at “sit inside a live UI and keep typing.”[^4_4]

tmux gives you a **stable box** where:

1. You (or a script) start `agy` once inside a session
2. That session stays alive
3. Claude can **type into it** (`tmux send-keys`) and **read the screen** (`tmux capture-pane`)
4. You can attach yourself anytime and watch or take over
```text
┌─ your Terminal ─────────────────────┐
│  tmux session "agy-worker"          │
│  ┌───────────────────────────────┐  │
│  │  agy  (still running)         │  │
│  │  > refactor the tests...      │  │
│  └───────────────────────────────┘  │
└─────────────────────────────────────┘
         ▲                ▲
         │                │
    you attach       Claude send-keys /
    to watch         capture-pane
```

Without tmux, every time Claude’s shell call ends, an interactive `agy` would tend to die with it. With tmux, **agy is the long-lived process; Claude just pokes it.**[^4_5][^4_2]

## What tmux is *not*

- Not a remote desktop
- Not a container/VM
- Not required for headless one-shots like `agy -p "do the thing"`
- Not something you must master to use Claude + agy at all


## Do you need it?

| Goal | Need tmux? |
| :-- | :-- |
| Claude runs `agy -p "…"` once, gets text back, reviews the diff | **No** — headless mode is enough |
| Long-lived interactive agy Claude can keep talking to | **Yes** — or an MCP PTY server (same idea, different tool) |
| You want agy to survive closing the terminal / SSH drops | **Yes** |

**Bottom line:** tmux is a way to keep a terminal program alive in the background and reconnect to it later. For your whacky setup, it’s optional glue so Claude can drive a *live* `agy` session instead of only firing one-shot jobs.[^4_2][^4_1]

If you want, next we can skip tmux entirely and sketch only the headless `agy -p` skill path — that’s simpler and usually enough.
<span style="display:none">[^4_6][^4_7][^4_8][^4_9]</span>

<div align="center">⁂</div>

[^4_1]: https://www.redhat.com/en/blog/introduction-tmux-linux

[^4_2]: https://github.com/tmux/tmux/wiki/Getting-Started

[^4_3]: https://www.reddit.com/r/tmux/comments/v84prx/can_somebody_explain_to_me_why_i_would_use_tmux/

[^4_4]: https://antigravity.google/docs/cli/using

[^4_5]: https://github.com/mitsuhiko/agent-stuff/blob/main/skills/tmux/SKILL.md

[^4_6]: https://www.reddit.com/r/neovim/comments/17cb1ah/what_is_the_benefit_of_tmux_why_should_i_use_it/

[^4_7]: https://hamvocke.com/blog/a-quick-and-easy-guide-to-tmux/

[^4_8]: https://www.youtube.com/watch?v=nTqu6w2wc68

[^4_9]: https://www.youtube.com/watch?v=OGiRb7LeIIM


---

# no i want the interactive setup

Here’s a full **interactive** setup: Claude drives a live `agy` sitting inside tmux. You can watch or take over anytime.[^5_1][^5_2]

## What you’ll have

```text
You ←→ Claude Code
            │  runs helper scripts
            ▼
     tmux session "agy"
            │
            ▼
     live interactive agy (TUI stays up)
```

Claude types into agy and reads the screen. You attach to the same session when you want to look.[^5_3][^5_2]

***

## 1. Install prerequisites

```bash
# tmux
sudo apt install tmux          # Debian/Ubuntu
# brew install tmux            # macOS

# agy (if not already)
curl -fsSL https://antigravity.google/cli/install.sh | bash
agy --version
# run `agy` once manually and finish Google auth
```

Confirm both work before wiring Claude.[^5_4][^5_1]

***

## 2. Drop-in helper scripts

Put these somewhere on your `PATH` (e.g. `~/bin`) and `chmod +x` them.

### `agy-up` — start the persistent session

```bash
#!/usr/bin/env bash
set -euo pipefail

SOCK="${AGY_TMUX_SOCK:-${TMPDIR:-/tmp}/claude-agy.sock}"
SESS="${AGY_TMUX_SESS:-agy}"
WORKDIR="${AGY_WORKDIR:-$PWD}"
AGY_BIN="${AGY_BIN:-agy}"

mkdir -p "$(dirname "$SOCK")"

if tmux -S "$SOCK" has-session -t "$SESS" 2>/dev/null; then
  echo "already running: sess=$SESS sock=$SOCK"
  tmux -S "$SOCK" capture-pane -p -J -t "$SESS" -S -50
  exit 0
fi

tmux -S "$SOCK" new-session -d -s "$SESS" -c "$WORKDIR"
# skip permission prompts so Claude isn't stuck on y/n
tmux -S "$SOCK" send-keys -t "$SESS" -l -- \
  "$AGY_BIN --dangerously-skip-permissions"
tmux -S "$SOCK" send-keys -t "$SESS" Enter

# give the TUI a moment to boot
sleep 2
echo "started agy in tmux sess=$SESS"
echo "attach with: tmux -S $SOCK attach -t $SESS"
tmux -S "$SOCK" capture-pane -p -J -t "$SESS" -S -80
```


### `agy-type` — send text (optionally press Enter)

```bash
#!/usr/bin/env bash
set -euo pipefail

SOCK="${AGY_TMUX_SOCK:-${TMPDIR:-/tmp}/claude-agy.sock}"
SESS="${AGY_TMUX_SESS:-agy}"

if [[ $# -lt 1 ]]; then
  echo "usage: agy-type [-n] <text…>   # -n = don't press Enter" >&2
  exit 2
fi

ENTER=1
if [[ "${1:-}" == "-n" ]]; then
  ENTER=0
  shift
fi

TEXT="$*"
tmux -S "$SOCK" send-keys -t "$SESS" -l -- "$TEXT"
if [[ "$ENTER" -eq 1 ]]; then
  tmux -S "$SOCK" send-keys -t "$SESS" Enter
fi
```


### `agy-keys` — special keys (Ctrl-C, Escape, etc.)

```bash
#!/usr/bin/env bash
set -euo pipefail

SOCK="${AGY_TMUX_SOCK:-${TMPDIR:-/tmp}/claude-agy.sock}"
SESS="${AGY_TMUX_SESS:-agy}"

# examples: C-c  C-d  Escape  Enter  BSpace
tmux -S "$SOCK" send-keys -t "$SESS" "$@"
```


### `agy-read` — screenshot the pane

```bash
#!/usr/bin/env bash
set -euo pipefail

SOCK="${AGY_TMUX_SOCK:-${TMPDIR:-/tmp}/claude-agy.sock}"
SESS="${AGY_TMUX_SESS:-agy}"
LINES="${1:--200}"   # negative = scrollback history

tmux -S "$SOCK" capture-pane -p -J -t "$SESS" -S "$LINES"
```


### `agy-wait` — poll until screen matches a pattern

```bash
#!/usr/bin/env bash
set -euo pipefail

SOCK="${AGY_TMUX_SOCK:-${TMPDIR:-/tmp}/claude-agy.sock}"
SESS="${AGY_TMUX_SESS:-agy}"
PATTERN="${1:?usage: agy-wait <regex> [timeout_sec]}"
TIMEOUT="${2:-120}"
START=$(date +%s)

while true; do
  OUT=$(tmux -S "$SOCK" capture-pane -p -J -t "$SESS" -S -80)
  if grep -qE "$PATTERN" <<<"$OUT"; then
    printf '%s\n' "$OUT"
    exit 0
  fi
  now=$(date +%s)
  if (( now - START >= TIMEOUT )); then
    echo "timeout waiting for: $PATTERN" >&2
    printf '%s\n' "$OUT" >&2
    exit 1
  fi
  sleep 1
done
```


### `agy-down` — kill the session

```bash
#!/usr/bin/env bash
set -euo pipefail

SOCK="${AGY_TMUX_SOCK:-${TMPDIR:-/tmp}/claude-agy.sock}"
SESS="${AGY_TMUX_SESS:-agy}"

tmux -S "$SOCK" kill-session -t "$SESS" 2>/dev/null || true
echo "stopped $SESS"
```


### `agy-attach` — you watch live

```bash
#!/usr/bin/env bash
set -euo pipefail

SOCK="${AGY_TMUX_SOCK:-${TMPDIR:-/tmp}/claude-agy.sock}"
SESS="${AGY_TMUX_SESS:-agy}"

tmux -S "$SOCK" attach -t "$SESS"
```

Detach without killing agy: **Ctrl+b**, then **d**.[^5_1]

***

## 3. Claude Code skill

```bash
mkdir -p ~/.claude/skills/agy-interactive
```

`~/.claude/skills/agy-interactive/SKILL.md`:

```markdown
---
name: agy-interactive
description: Drive a persistent interactive Antigravity (agy) session via tmux helpers. Use when the user wants Claude to control agy interactively, pair with Gemini through agy, or keep a long-lived agy TUI.
---

# Interactive agy control

You supervise. agy executes inside a tmux session. Never run raw `agy` in the
foreground for multi-turn work — use the helpers below.

## Session lifecycle

```bash
agy-up                 # start once per machine/project
agy-read               # see current screen
agy-attach             # USER only — you do not need this
agy-down               # tear down when finished
```

Env overrides (optional):

- `AGY_TMUX_SOCK` (default `/tmp/claude-agy.sock`)
- `AGY_TMUX_SESS` (default `agy`)
- `AGY_WORKDIR` (default cwd when up was run)


## Talk to agy

```bash
# submit a prompt
agy-type "Implement X in src/foo; keep tests green; do not commit"

# type without Enter (partial input / menus)
agy-type -n "partial text"

# special keys
agy-keys C-c           # interrupt stream
agy-keys Escape
agy-keys Enter

# read screen (last ~200 history lines)
agy-read
agy-read -400

# wait until UI looks idle / shows a cue, then dump screen
agy-wait 'can I help|›|\$' 180
```


## Protocol every turn

1. `agy-up` if session might not exist.
2. `agy-read` — confirm you're at a prompt, not mid-generation.
3. If busy: `agy-wait` or `agy-keys C-c` only if user wants abort.
4. `agy-type` with a **self-contained** task (goal, paths, constraints, done-when).
5. Poll: `agy-wait` and/or periodic `agy-read` until agy finishes or needs you.
6. After agy stops: inspect the repo yourself (`git status`, `git diff`, tests).
7. Either accept, or send a follow-up via `agy-type`, or fix yourself.

## Task prompt quality

Every `agy-type` message should include:

- Goal (1–3 sentences)
- In-scope paths
- Out-of-scope / hard bans (no commit/push unless user asked)
- Done-when (commands that must pass)
- Ask agy to end with: summary, files touched, commands run, risks


## Safety

- Prefer a dedicated git branch or worktree before big agy jobs.
- You review diffs; agy does not merge to main.
- Do not send secrets into the pane.
- If the pane is garbled, `agy-down && agy-up` and retry.
- One writer at a time: do not edit the same files while agy is mid-task.


## Shared contract

Honor repo `AGENTS.md` / `CLAUDE.md` role split:

- You: design, verification, final decisions
- agy: bulk implementation, search, scaffolding

```

Claude loads skills from `~/.claude/skills/` (and project `.claude/skills/`).[^5_5][^5_6]

***

## 4. Optional project contract

Repo root `AGENTS.md` (agy reads this; Claude should too):[^5_7][^5_8]

```markdown
# AGENTS.md

## Roles
- Claude Code: architecture, review, merge decisions
- agy: bulk edits, scaffolding, search, mechanical refactors

## Rules
- No force-push, no secrets, no deleting .git
- Default: leave changes uncommitted
- Run the project test command after substantive edits
- Only touch paths listed in the task unless blocked

## Done-when footer
End every job with: summary | files touched | commands run | open risks
```


***

## 5. First run (manual smoke test)

In a normal terminal, from your project:

```bash
export PATH="$HOME/bin:$PATH"   # if scripts live there
cd /path/to/your/repo

agy-up
agy-read                        # should show agy TUI
agy-type "Say hello and list top-level files. Do not edit anything."
# wait a few seconds
agy-read
```

In **another** terminal:

```bash
agy-attach                      # watch live; Ctrl+b d to leave without killing
```

If that works, Claude can drive it the same way.[^5_3][^5_1]

***

## 6. How you use it with Claude

Start Claude Code in the same repo (`claude`), then something like:

```text
Load agy-interactive. Start the session if needed, then have agy
add smoke tests for module X. You design the API surface; agy
implements; you review the diff and run tests. I may agy-attach
to watch.
```

Claude should roughly:

```bash
agy-up
agy-read
agy-type "…"
agy-wait '…' 180    # or loop agy-read
git diff
pytest   # or your test cmd
```


***

## 7. Day-to-day cheatsheet

| You want… | Command |
| :-- | :-- |
| Start worker | `agy-up` |
| See what agy sees | `agy-read` |
| Send a task | `agy-type "…"` |
| Stop generation | `agy-keys C-c` |
| Watch yourself | `agy-attach` → leave with **Ctrl+b d** |
| Kill everything | `agy-down` |
| Fresh TUI | `agy-down && agy-up` |


***

## 8. Gotchas

- **`--dangerously-skip-permissions`** stops agy from blocking on y/n that Claude never answers. It also weakens guardrails — use a branch/worktree.[^5_9][^5_10]
- **Private socket** (`/tmp/claude-agy.sock`) keeps this off your personal tmux.[^5_2]
- **Garbled TUI**: full-screen apps are finicky; `agy-down && agy-up` is the reset.
- **Race conditions**: always `agy-read` before typing so you don’t interrupt mid-stream.
- **Two editors**: don’t let Claude and agy write the same files at once.

***

## 9. Minimal mental model

tmux = a box that keeps `agy` alive.
`agy-type` / `agy-read` = Claude’s keyboard and eyes.
`agy-attach` = your eyes on the same box.[^5_11][^5_2]

That’s the whole interactive setup. After the scripts are on your `PATH` and the skill is in place, run the smoke test once; if anything fails (auth, `agy` flags, pane empty), paste the output and we can tighten the wait patterns for your agy TUI prompt.
<span style="display:none">[^5_12][^5_13][^5_14][^5_15][^5_16][^5_17][^5_18][^5_19][^5_20][^5_21][^5_22][^5_23][^5_24][^5_25][^5_26][^5_27][^5_28]</span>

<div align="center">⁂</div>

[^5_1]: https://www.redhat.com/en/blog/introduction-tmux-linux

[^5_2]: https://github.com/mitsuhiko/agent-stuff/blob/main/skills/tmux/SKILL.md

[^5_3]: https://github.com/tmux/tmux/wiki/Advanced-Use/ae175537241de0f59acbd9a08bba4bb33a3c4487

[^5_4]: https://learn.arm.com/install-guides/antigravity/

[^5_5]: https://code.claude.com/docs/en/skills

[^5_6]: https://newsletter.victordibia.com/p/implementing-claude-code-skills-from

[^5_7]: https://dev.to/arindam_1729/antigravity-cli-a-hands-on-guide-to-googles-terminal-coding-agent-5bc7

[^5_8]: https://www.reddit.com/r/ClaudeCode/comments/1ugs23i/using_the_antigravity_cli_agy_as_a_subagent/

[^5_9]: https://github.com/google-antigravity/antigravity-cli/issues/36

[^5_10]: https://toolsbase.dev/en/reference/antigravity-cli-commands

[^5_11]: https://github.com/tmux/tmux/wiki/Getting-Started

[^5_12]: https://stackoverflow.com/questions/73161138/having-an-interactive-menu-when-running-a-shell-command

[^5_13]: https://www.reddit.com/r/tmux/comments/v84prx/can_somebody_explain_to_me_why_i_would_use_tmux/

[^5_14]: https://brainhack-princeton.github.io/handbook/content_pages/hack_pages/tmux.html

[^5_15]: https://researchit.las.iastate.edu/guides/pronto/interactive_computing/tmux/

[^5_16]: https://www.lenovo.com/us/en/glossary/what-is-tmux/

[^5_17]: https://man7.org/linux/man-pages/man1/tmux.1.html

[^5_18]: https://unix.stackexchange.com/questions/758811/does-tmux-run-shell-support-interactive-shell

[^5_19]: https://superuser.com/questions/1904136/why-does-tmux-send-keys-behave-differently-in-a-bash-script

[^5_20]: https://antigravity.google/docs/cli/using

[^5_21]: https://dev.to/gde/using-googles-new-ai-command-line-assistant-antigravity-cli-agy-and-yolos-no-confirmation-mode-10d

[^5_22]: https://www.youtube.com/watch?v=AybyBL6TQUA

[^5_23]: https://www.freecodecamp.org/news/how-to-build-your-own-claude-code-skill/

[^5_24]: https://stackoverflow.com/questions/58936269/tmux-run-command-in-pane-and-capture-result-in-bash-script

[^5_25]: https://www.reddit.com/r/ClaudeAI/comments/1pq0ui4/the_busy_persons_intro_to_claude_skills_a_feature/

[^5_26]: https://tao-of-tmux.readthedocs.io/en/latest/manuscript/10-scripting.html

[^5_27]: https://www.reddit.com/r/Bard/comments/1rq73bb/antigravity_constantly_asking_for_permissions_to/

[^5_28]: https://joseparreogarcia.substack.com/p/claude-code-skills-explained


---

# can i launch agy from powershell, and tmux into that

**Short answer:** You can launch `agy` from PowerShell. You **cannot** attach classic Linux `tmux` to a process that was already started outside it. The shell has to be **started inside** the multiplexer (tmux in WSL, or **psmux** on native Windows).[^6_1][^6_2][^6_3]

## How this actually works

```text
Wrong mental model:
  PowerShell → start agy → later "tmux into it"   ❌

Right model:
  multiplexer session → start agy inside it → attach / send-keys / capture-pane   ✅
```

tmux (and psmux) own the terminal. Anything you want to drive later must be born in that session.[^6_3]

***

## Your options on Windows

| Approach | Launch `agy` from PS? | Interactive drive like tmux? | Notes |
| :-- | :-- | :-- | :-- |
| **A. psmux (native)** | Yes | Yes (`send-keys`, `capture-pane`) | Closest to “tmux on PowerShell”; no WSL required [^6_1][^6_4] |
| **B. WSL + real tmux** | Via `wsl` or Windows `agy.exe` from a pane | Yes (real tmux) | Best if Claude Code also runs in WSL [^6_5] |
| **C. Bare PowerShell only** | Yes | No persistent TUI control | Fine for `agy -p "…"` one-shots only |

`agy` itself installs natively on Windows:[^6_2]

```powershell
irm https://antigravity.google/cli/install.ps1 | iex
agy --version
```


***

## Path A — Recommended if you live in PowerShell: **psmux**

psmux is a native Windows multiplexer with tmux-like commands, including automation hooks Claude needs.[^6_6][^6_1]

```powershell
winget install psmux
# or: scoop install psmux / cargo install psmux
```


### Start interactive agy inside psmux

```powershell
# create detached session and run agy in it
psmux new-session -d -s agy -c $PWD
psmux send-keys -t agy -l -- "agy --dangerously-skip-permissions"
psmux send-keys -t agy Enter

# you watch
psmux attach -t agy
# detach without killing: same idea as tmux (prefix + d; check psmux docs for prefix)
```


### Claude (or you) drive it

```powershell
psmux capture-pane -p -t agy -S -200          # read screen
psmux send-keys -t agy -l -- "implement X..." # type
psmux send-keys -t agy Enter
psmux send-keys -t agy C-c                    # interrupt
psmux kill-session -t agy
```

Same protocol as the Linux tmux helpers; swap `tmux -S …` for `psmux`.[^6_4][^6_6]

**PowerShell helper sketch** (`agy-up.ps1`):

```powershell
$sess = if ($env:AGY_SESS) { $env:AGY_SESS } else { "agy" }
if (-not (psmux has-session -t $sess 2>$null)) {
  psmux new-session -d -s $sess -c (Get-Location).Path
  psmux send-keys -t $sess -l -- "agy --dangerously-skip-permissions"
  psmux send-keys -t $sess Enter
  Start-Sleep -Seconds 2
}
psmux capture-pane -p -J -t $sess -S -80
```


***

## Path B — Real tmux via WSL

Use this if you want **actual** tmux and/or Claude Code in Linux.[^6_5]

```powershell
wsl --install   # if needed
wsl sudo apt update `&&` sudo apt install -y tmux
```

Two sub-variants:

**B1 — `agy` Linux binary inside WSL** (simplest for scripts): install agy in WSL, run everything in one Linux world.

**B2 — Windows `agy.exe` from a WSL tmux pane** (possible, path/auth quirks):

```bash
# inside WSL tmux pane
/mnt/c/Users/<You>/AppData/Local/agy/bin/agy.exe --dangerously-skip-permissions
```

People hit WSL↔Windows launcher friction with Antigravity; native Windows agy + psmux or full-Linux-in-WSL is usually less painful.[^6_7][^6_8]

From PowerShell you can still poke WSL tmux:

```powershell
wsl -e tmux -S /tmp/claude-agy.sock capture-pane -p -t agy -S -200
wsl -e tmux -S /tmp/claude-agy.sock send-keys -t agy -l -- "do the thing"
wsl -e tmux -S /tmp/claude-agy.sock send-keys -t agy Enter
```


***

## Direct answers to your question

| Question | Answer |
| :-- | :-- |
| Launch agy from PowerShell? | **Yes** — first-class on Windows [^6_2] |
| “tmux into” an already-running PS agy? | **No** — must start agy *inside* tmux/psmux [^6_3] |
| Interactive Claude control on Windows without WSL? | **Yes** — use **psmux** [^6_1] |
| Keep prior Linux script design? | Use **WSL + tmux**, run Claude there too [^6_5] |


***

## Practical recommendation for you

Given PowerShell-heavy workflow on Windows:

1. Install **agy** (Windows PS installer).[^6_2]
2. Install **psmux**.[^6_1]
3. Port the helpers to `.ps1` (`agy-up`, `agy-type`, `agy-read`, …) calling `psmux` instead of `tmux`.
4. Point the Claude skill at those scripts.
5. You: `psmux attach -t agy` to watch; Claude: `send-keys` / `capture-pane`.

If Claude Code is already living in **WSL**, flip it: do the whole stack in WSL with real tmux and Linux `agy`, and only use Windows Terminal as the UI.

***

**Bottom line:** PowerShell can start `agy` just fine. For the interactive “Claude types into a live TUI” setup, start that `agy` **inside psmux (or WSL tmux)**—not as a lone PowerShell job you try to wrap later.[^6_3][^6_1][^6_2]

If you say whether Claude Code runs in **native Windows** or **WSL**, the next message can be the exact PS1 helper set for that path only.
<span style="display:none">[^6_10][^6_11][^6_12][^6_13][^6_14][^6_15][^6_16][^6_17][^6_18][^6_19][^6_20][^6_21][^6_22][^6_9]</span>

<div align="center">⁂</div>

[^6_1]: https://github.com/psmux/psmux

[^6_2]: https://antigravity.google/docs/cli/install

[^6_3]: https://github.com/tmux/tmux/wiki/Getting-Started

[^6_4]: https://www.reddit.com/r/PowerShell/comments/1r1b26l/psmux_native_tmux_for_powershell_split_panes/

[^6_5]: https://blog.iany.me/2026/01/use-tmux-for-powershell-in-windows-terminal/

[^6_6]: https://github.com/psmux/psmux/blob/master/docs/features.md

[^6_7]: https://discuss.ai.google.dev/t/antigravity-cli-agy-on-wsl-broken-launcher-missing-scripts-manual-repair-report/110717

[^6_8]: https://itecsonline.com/post/antigravity-setup-guide

[^6_9]: https://superuser.com/questions/408874/tmux-screen-alternative-for-powershell

[^6_10]: https://www.linkedin.com/posts/uniquegodwin_terminal-powershell-tmux-activity-7433821265305665536-DRkv

[^6_11]: https://heywoodlh.io/tmux-pwsh-nologo

[^6_12]: https://community.spiceworks.com/t/psmux-native-tmux-in-windows-powershell-without-wsl/1250362

[^6_13]: https://www.reddit.com/r/google_antigravity/comments/1rkiua9/community_sdk_creator_here_we_need_to_talk_about/

[^6_14]: https://antigravity.google/docs/cli/getting-started

[^6_15]: https://github.com/google-antigravity/antigravity-cli

[^6_16]: https://codelabs.developers.google.com/antigravity-cli-hands-on

[^6_17]: https://www.youtube.com/watch?v=VlgZEMjESFk

[^6_18]: https://psmux.pages.dev/

[^6_19]: https://www.youtube.com/watch?v=v3IuGlxc3S0

[^6_20]: https://addshore.com/2026/02/google-antigravity-for-wsl/

[^6_21]: https://stackoverflow.com/questions/58936269/tmux-run-command-in-pane-and-capture-result-in-bash-script

[^6_22]: https://www.youtube.com/watch?v=YAWG7GooxXE


---

# i just downloaded portable psmux, how do i set it up for portable. i know i have to add to path and add a config file

Portable psmux is just: unzip → put the folder on PATH → optional config. Here’s a clean layout that stays self-contained.[^7_1][^7_2]

## 1. Folder layout

Pick a home that won’t move (example uses `D:\tools\psmux`):

```text
D:\tools\psmux\
  psmux.exe
  pmux.exe          # if the zip includes aliases
  tmux.exe          # often shipped as alias to psmux
  psmux.conf        # your portable config (name below)
  bin\              # optional: your agy-up.ps1 helpers later
```

Extract the zip so the `.exe` files are directly in that folder (or note the real subfolder if the zip nests them).[^7_1]

***

## 2. Add to PATH (user, permanent)

**PowerShell (current user, survives restarts):**

```powershell
$psmuxHome = "D:\tools\psmux"   # <-- your real path

# permanent user PATH
$old = [Environment]::GetEnvironmentVariable("Path", "User")
if ($old -notlike "*$psmuxHome*") {
  [Environment]::SetEnvironmentVariable(
    "Path",
    ($old.TrimEnd(';') + ";" + $psmuxHome),
    "User"
  )
}

# this window only (until you open a new terminal)
$env:Path = $psmuxHome + ";" + $env:Path

# verify
Get-Command psmux | Format-List Source
psmux -V   # or: psmux --version
```

Close and reopen Windows Terminal / VS Code terminals so they pick up the new user PATH.[^7_1]

**Session-only (no permanent change):**

```powershell
$env:Path = "D:\tools\psmux;" + $env:Path
```


***

## 3. Config file

psmux loads the **first** of these that exists:[^7_2]

1. `~/.psmux.conf` → usually `C:\Users\<You>\.psmux.conf`
2. `~/.psmuxrc`
3. `~/.tmux.conf`
4. `~/.config/psmux/psmux.conf`

### Option A — normal (simplest)

```powershell
@"
# ~/.psmux.conf
set -g mouse on
set -g history-limit 50000
set -g status on
set -g status-left "[#S] "
set -g status-right "%H:%M "
set -g allow-predictions on

# default shell = PowerShell 7 if installed, else Windows PowerShell
# adjust path if needed:
# set -g default-shell "C:/Program Files/PowerShell/7/pwsh.exe"
"@ | Set-Content -Encoding utf8 $HOME\.psmux.conf
```


### Option B — portable config next to the exe

Keep config beside the binary and force it with env or `-f`:[^7_2]

```powershell
$psmuxHome = "D:\tools\psmux"
$config    = Join-Path $psmuxHome "psmux.conf"

@"
set -g mouse on
set -g history-limit 50000
set -g status-left "[#S] "
set -g status-right "%H:%M "
set -g allow-predictions on
"@ | Set-Content -Encoding utf8 $config

# permanent for your user
[Environment]::SetEnvironmentVariable("PSMUX_CONFIG_FILE", $config, "User")

# this session
$env:PSMUX_CONFIG_FILE = $config
```

Or per invocation:

```powershell
psmux -f D:\tools\psmux\psmux.conf new -s test
```

`PSMUX_CONFIG_FILE` / `-f` override the default search order.[^7_2]

***

## 4. Smoke test

```powershell
psmux new -s test
# you're inside a session — try splitting if you want:
# prefix is Ctrl+b by default (tmux-like), then % or "

# detach: Ctrl+b, then d

psmux ls
psmux attach -t test
psmux kill-session -t test
```

Automation checks (what Claude will use later):

```powershell
psmux new-session -d -s agy -c $PWD
psmux send-keys -t agy -l -- "echo hello-from-psmux"
psmux send-keys -t agy Enter
Start-Sleep -Milliseconds 300
psmux capture-pane -p -t agy -S -50
psmux kill-session -t agy
```

`send-keys` / `capture-pane -p` are supported for scripting.[^7_3][^7_4]

***

## 5. Optional: portable “env” script

So any machine only needs one line:

`D:\tools\psmux\env.ps1`:

```powershell
$PsmuxHome = $PSScriptRoot
$env:Path = "$PsmuxHome;" + ($env:Path -replace [regex]::Escape($PsmuxHome + ";"), "")
$env:PSMUX_CONFIG_FILE = Join-Path $PsmuxHome "psmux.conf"
Write-Host "psmux ready:" (Get-Command psmux).Source
```

Then in a new shell:

```powershell
. D:\tools\psmux\env.ps1
psmux ls
```


***

## 6. Checklist

| Step | Done when |
| :-- | :-- |
| Zip extracted | `psmux.exe` path known |
| On PATH | `Get-Command psmux` works in a **new** terminal |
| Config | `Test-Path $HOME\.psmux.conf` **or** `$env:PSMUX_CONFIG_FILE` set |
| Works | `psmux new -s test` / detach / `attach` / `kill-session` |
| Scriptable | `send-keys` + `capture-pane -p` return text |


***

## 7. Notes

- Zip install = extract + PATH; no installer required.[^7_1]
- Existing `.tmux.conf` is picked up automatically if no `.psmux.conf` is first in the search order.[^7_5]
- Reload config without restart: `psmux source-file $HOME\.psmux.conf` (or your portable path).[^7_2]
- Default prefix is tmux-style **Ctrl+b** unless you change it in config.[^7_6]

If you paste the path where you extracted the zip (and whether you use `pwsh` or Windows PowerShell), the PATH + `PSMUX_CONFIG_FILE` lines can be filled in exactly for your machine.
<span style="display:none">[^7_10][^7_11][^7_12][^7_13][^7_14][^7_15][^7_16][^7_17][^7_18][^7_19][^7_20][^7_7][^7_8][^7_9]</span>

<div align="center">⁂</div>

[^7_1]: https://github.com/psmux/psmux/releases

[^7_2]: https://github.com/psmux/psmux/blob/master/docs/configuration.md

[^7_3]: https://www.reddit.com/r/PowerShell/comments/1r1b26l/psmux_native_tmux_for_powershell_split_panes/

[^7_4]: https://github.com/psmux/psmux/blob/master/docs/features.md

[^7_5]: https://github.com/psmux/psmux/blob/master/docs/faq.md

[^7_6]: https://docs.rs/crate/psmux/0.1.0/source/README.md

[^7_7]: https://github.com/psmux/psmux

[^7_8]: https://lib.rs/crates/portable-pty-psmux

[^7_9]: https://community.spiceworks.com/t/psmux-native-tmux-in-windows-powershell-without-wsl/1250362

[^7_10]: https://www.linkedin.com/posts/uniquegodwin_terminal-powershell-tmux-activity-7433821265305665536-DRkv

[^7_11]: https://winstall.app/apps/marlocarlo.psmux

[^7_12]: https://korben.info/en/psmux-native-tmux-windows-no-wsl.html

[^7_13]: https://zenn.dev/sora_biz/articles/psmux-windows-native-tmux?locale=en

[^7_14]: https://docs.rs/crate/psmux/3.3.0/source/docs/configuration.md

[^7_15]: https://github.com/orgs/tmux/discussions/4896

[^7_16]: https://dev.to/marlocarlo/stop-using-wsl-just-for-tmux-psmux-is-tmux-for-windows-natively-4hof

[^7_17]: https://crates.io/crates/psmux/0.4.4

[^7_18]: https://context7.com/websites/psmux_pages_dev

[^7_19]: https://psmux.pages.dev/

[^7_20]: https://crates.io/crates/psmux/0.3.1


---

# are there env vars i can expose for psmux

Yes. psmux exposes a small set of **process env vars you set**, injects **tmux-compatible vars inside panes**, and lets you **push your own vars into sessions/panes**.[^8_1]

## Env vars you set (control psmux)

| Variable | Effect |
| :-- | :-- |
| `PSMUX_CONFIG_FILE` | Config path (same as `-f`) [^8_1] |
| `PSMUX_DEFAULT_SESSION` | Default session name when you don’t pass one [^8_1] |
| `PSMUX_NO_WARM` | `"1"` = disable warm/pre-spawned shells (`set -g warm off`) [^8_2][^8_1] |
| `PSMUX_DIM_PREDICTIONS` | `"1"` = dim predictive/speculative text [^8_1] |

**Portable PowerShell example:**

```powershell
$psmuxHome = "D:\tools\psmux"

$env:Path = "$psmuxHome;" + $env:Path
$env:PSMUX_CONFIG_FILE = Join-Path $psmuxHome "psmux.conf"
$env:PSMUX_DEFAULT_SESSION = "agy"
$env:PSMUX_NO_WARM = "1"          # optional: snappier/simpler for scripting
# $env:PSMUX_DIM_PREDICTIONS = "1" # optional
```

**Persist for your user:**

```powershell
[Environment]::SetEnvironmentVariable("PSMUX_CONFIG_FILE", "D:\tools\psmux\psmux.conf", "User")
[Environment]::SetEnvironmentVariable("PSMUX_DEFAULT_SESSION", "agy", "User")
# reopen terminals after setx / SetEnvironmentVariable User scope
```


***

## Env vars psmux sets inside panes

When a shell runs under psmux, these appear (tmux-compatible):[^8_2][^8_1]


| Variable | Meaning |
| :-- | :-- |
| `TMUX` | Session/server info (tools that check “am I in tmux?” work) |
| `TMUX_PANE` | Pane id (`%0`, `%1`, …) |
| `TERM` | Often `xterm-256color` (or whatever `default-terminal` sets) |
| `COLORTERM` | `truecolor` |

Also related options that inject behavior (not always plain env, but pane-facing):[^8_1]

- `claude-code-force-interactive` → can set `CLAUDE_CODE_FORCE_INTERACTIVE=1` in panes
- `env-shim` → injects a Unix-like `env` helper in PowerShell panes

***

## Env vars you inject into sessions/panes

Like tmux `set-environment`:[^8_1]

```powershell
# global — all new panes, all sessions
psmux set-environment -g EDITOR nvim
psmux set-environment -g AGY_WORKDIR "D:\code\myrepo"

# session-scoped (current / targeted session)
psmux set-environment MY_VAR value
psmux set-environment -t agy FOO bar

# unset
psmux set-environment -gu MY_VAR

# inspect
psmux show-environment
psmux show-environment -g
```

**At session create:**

```powershell
psmux new-session -s agy -e "PROJECT=myapp" -e "ENV=dev" -c D:\code\myrepo
```

Those are applied when **new** panes spawn; already-running panes keep their old env.[^8_1]

***

## Server isolation (flag, not env)

Multiple independent servers via namespace:

```powershell
psmux -L agy new-session -s worker
psmux -L work new-session -s dev
```

Each `-L` name gets its own server/sessions. Handy so Claude’s `agy` stack doesn’t collide with your personal psmux.[^8_2]

There isn’t a documented `PSMUX_SOCKET` / `PSMUX_TMPDIR` style var in the config docs; isolation is primarily `-L` (and your normal Windows temp layout).[^8_2][^8_1]

***

## Portable bundle pattern

In `D:\tools\psmux\env.ps1`:

```powershell
$PsmuxHome = $PSScriptRoot
$env:Path = "$PsmuxHome;" + ($env:Path -replace [regex]::Escape("$PsmuxHome;"), "")
$env:PSMUX_CONFIG_FILE      = Join-Path $PsmuxHome "psmux.conf"
$env:PSMUX_DEFAULT_SESSION  = "agy"
# $env:PSMUX_NO_WARM       = "1"
```

Then:

```powershell
. D:\tools\psmux\env.ps1
psmux -L agy new-session -d -s agy -c $PWD
psmux -L agy set-environment -g AGY_TMUX_SESS agy
```


***

## Quick reference

**You expose (optional):**
`PSMUX_CONFIG_FILE`, `PSMUX_DEFAULT_SESSION`, `PSMUX_NO_WARM`, `PSMUX_DIM_PREDICTIONS`[^8_1]

**psmux exposes in panes:**
`TMUX`, `TMUX_PANE`, `TERM`, `COLORTERM`[^8_2]

**You push into panes:**
`psmux set-environment` / `new-session -e`[^8_1]

**Isolate servers:**
`psmux -L <name>`[^8_2]

For the Claude→agy setup, the useful trio is usually `PSMUX_CONFIG_FILE` (portable conf), `-L agy` (private server), and `set-environment -g` for things like `AGY_WORKDIR`.
<span style="display:none">[^8_10][^8_11][^8_12][^8_3][^8_4][^8_5][^8_6][^8_7][^8_8][^8_9]</span>

<div align="center">⁂</div>

[^8_1]: https://github.com/psmux/psmux/blob/master/docs/configuration.md

[^8_2]: https://github.com/psmux/psmux/blob/master/docs/faq.md

[^8_3]: https://github.com/psmux/psmux

[^8_4]: https://crates.io/crates/psmux

[^8_5]: https://crates.io/crates/psmux/0.3.1

[^8_6]: https://stackoverflow.com/questions/20701757/tmux-setting-environment-variables-for-sessions

[^8_7]: https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_environment_variables?view=powershell-7.6

[^8_8]: https://www.reddit.com/r/tmux/comments/s6osog/status_scripts_not_loading_when_i_use_environment/

[^8_9]: https://psmux.pages.dev/

[^8_10]: https://www.reddit.com/r/PowerShell/comments/1r1b26l/psmux_native_tmux_for_powershell_split_panes/

[^8_11]: https://www.reddit.com/r/it/comments/1rirre0/psmux_for_it_admins_tmux_natively_on_powershell/

[^8_12]: https://community.spiceworks.com/t/psmux-native-tmux-in-windows-powershell-without-wsl/1250362

