# para-agent

An MCP server that exposes terminal multiplexer sessions as a supervisory interface, so one agent can spawn, drive, and observe other programs — including other agents — in persistent panes.

Supervisor-agnostic: any MCP-speaking client can use it. Backend-agnostic: it speaks only the tmux command language, so it runs on [psmux](https://github.com/psmux/psmux) on native Windows and on real tmux elsewhere.

**Status: draft (0.1.0).** The tool surface is exercised end to end over the MCP wire protocol against psmux 3.3.7 — see [Verified behavior](#verified-behavior). Treat the ergonomics as provisional.

## Why this exists

An MCP tool call is a fresh process every time. Shell state does not survive between calls, so an agent driving a shell normally cannot set a variable in one turn and read it in the next.

A multiplexer server is a daemon that outlives every command sent to it. Panes therefore keep their shell variables, working directory, environment, and any running program across separate supervisor turns. That turns a stateless tool surface into a genuinely persistent interactive console.

## Install

```bash
npm install
```

Then register it with your MCP client. `PARA_MUX_BIN` should be an absolute path — it makes the server immune to the multiplexer not being on `PATH`, which matters on Windows where a `PATH` registered after the client launched is invisible to it.

```json
{
  "mcpServers": {
    "para-agent": {
      "command": "node",
      "args": ["D:\\aghado01\\science-facility\\mcp\\para-agent\\src\\index.js"],
      "env": {
        "PARA_MUX_BIN": "C:\\Users\\azrie\\PDenv\\psmux\\psmux.exe",
        "PARA_MUX_NAMESPACE": "para",
        "PSMUX_CONFIG_FILE": "C:\\Users\\azrie\\PDenv\\psmux\\psmux.conf",
        "PSMUX_NO_WARM": "1"
      }
    }
  }
}
```

| Variable | Default | Purpose |
|---|---|---|
| `PARA_MUX_BIN` | `psmux.exe` / `tmux`, searched under `PSMUX_HOME` and `$PORTABLE_ROOT/psmux` | Multiplexer binary |
| `PARA_MUX_NAMESPACE` | `para` | `-L` namespace, isolating agent sessions from your own |
| `PARA_SESSION_PREFIX` | `agent-` | Prefix applied to every session name |
| `PARA_DELTA_WINDOW` | `1000` | Scrollback depth used for delta reads |

The `-L` namespace matters: agent sessions live in their own server namespace, so `list` never sees your interactive sessions and `kill` cannot reach them.

## Tools

| Tool | Purpose |
|---|---|
| `list` | Enumerate sessions and panes, with handles |
| `status` | Live state for one pane — command, cwd, PID, size, scrollback depth, dead flag |
| `spawn` | Create a persistent detached session; returns a handle |
| `send` | Deliver input — a line, raw text, or named keys |
| `read` | Capture pane content, optionally only what is new since the last read |
| `wait` | Block until the pane matches a regex, or until it stops changing |
| `run` | Run a command in a shell pane; returns a receipt, output captured to the journal |
| `exec` | Headless one-shot in a throwaway pane, destroyed afterwards |
| `log` | What has run in this session — summaries, or raw records from a cursor |
| `body` | Fetch one turn's output, sliced or grepped |
| `find` | Search across every turn's output, returning lines |
| `cancel` | Stop what a pane is running — cooperative, interrupt, terminate, or kill |
| `kill` | Destroy a session or a single pane |

A handle is a fully-qualified tmux target: `agent-foo:0.0` (`session:window.pane`).

## Context economy

The supervising agent's context is the scarce resource, so the read path is built around three rules: default to summaries, defer bodies, and never omit silently.

`run` returns a **receipt** — exit code, byte and line counts, timings — not the output. Anything under 2KB is inlined anyway; anything larger is journalled and the receipt names the call that fetches it. Measured: a `log` summary covering five turns, one of which produced a 25,905-byte body, is **1,218 bytes**. A `find` across every turn returned five hits in **483 bytes**.

Every read carries a receipt stating what was scanned, returned and withheld, and each withheld entry names a concrete retrieval call. `complete: true` is the single thing a consumer must check. Deferred bodies are reported separately and do **not** flip it — see [the contract](contract/CONSOLE-CONTRACT.md#receipts) for why.

Reach for `find` before `body`: searching every turn at once costs hundreds of tokens, fetching a few bodies to read them yourself costs tens of thousands.

## The two execution models

Which one applies depends on what is running in the pane, and getting it wrong is the most common way to misuse this server.

**Line-oriented — a shell prompt.** Use `run`. The command is written to a per-turn wrapper script which the pane dot-sources; the wrapper tees output to a file and drops a `.done` sentinel carrying the exit code, duration and cwd. **The output never passes through the terminal**, so it is byte-exact: no wrapping, no width truncation, no lost trailing whitespace, no scrollback ceiling, no size limit.

Two details are load-bearing. The command is base64-encoded inside the wrapper — not for escaping, since `send-keys -l` is byte-exact, but for isolation: an encoded payload cannot contain a brace that closes the wrapper's own `try`/`finally` early. And the wrapper *dot-sources* rather than invoking with `&`, so the command runs in the pane's own scope and `$x = 1` or `cd` survive to the next turn.

**Full-screen — a TUI, a REPL, an interactive agent.** `run` does not apply; there is no prompt to return to and no exit code. Use `send` to deliver keystrokes and `wait` to decide when the program has responded:

- `wait until: pattern` when you know what the program prints when it is ready. Precise — prefer it.
- `wait until: stable` when you do not. This is a **heuristic**: an agent thinking silently is indistinguishable from one that has finished, and an animated spinner never settles at all.

## Cancellation

Stopping things separates into two independent questions, and conflating them is how supervisors accidentally kill work they meant to keep.

**Stopping the observation.** Cancel the MCP request. `run`, `wait` and their poll loops honour the request's `AbortSignal`, return promptly, and **never touch the pane** — whatever was running still is. Use this whenever the supervisor simply stops caring about the answer. Verified: after cancelling a `run` mid-flight, the pane's `ping` was still running.

**Stopping the work.** Use `cancel`, which is an escalation ladder:

| Level | Effect | Survives |
|---|---|---|
| `interrupt` | C-c to the pane | Shell survives; siblings and other sessions untouched |
| `terminate` | Kill a named descendant by PID | Shell survives with the same PID, pane stays usable |
| `kill` | Destroy the pane | Nothing |

Propagation is narrower than the ConPTY documentation implies. Measured: C-c sent to one pane stopped its foreground program while a sibling pane's process kept running, and a second session was entirely unaffected. Each pane gets its own ConPTY, so the "reaches every process sharing the console" caveat is scoped to a single pane. The only real imprecision is that C-c hits the pane's shell as well as the program — which is why `terminate` exists, for when you need to end one child and keep the shell.

## Verified behavior

Against psmux 3.3.7 on Windows 11, via the MCP wire protocol (21/21) and against the internals directly (30/32; the two failures are the trailing-whitespace and sliding-window limitations documented below, both since accounted for):

- Sessions and their live shell state survive across separate processes — a variable set in one tool call reads back in the next.
- Working directory persists; `cd` in one `run` affects the next.
- Native exit codes are captured (`cmd /c exit 3` → `exitCode: 3`).
- 300 lines of output recovered intact from scrollback, first and last row correct.
- Hostile payloads round-trip exactly: embedded quotes, shell metacharacters, backslashes, braces, marker lookalikes (`PARA-lookalike ec=99`), and non-ASCII.
- A command crafted to break the frame (`Write-Output 'a' } catch { } finally { ...`) fails cleanly inside the wrapper and leaves the pane usable.
- Timeouts return promptly and report that the command is still running.
- `exec` leaves no session behind.
- Completion detection overhead is roughly 0.5–0.9s on top of the command's own runtime.

## Limitations

These are properties of the platform, not bugs in this server. Several were established by direct measurement.

**`wait-for` does not block.** tmux's `wait-for <channel>` blocks until signalled, which would make command completion an event. psmux 3.3.7 returns immediately — measured at 84ms and 97ms against a signal deliberately sent at 1500ms, with and without a prior `-L` lock. Completion is therefore detected by polling, which is where the 0.5–0.9s overhead comes from. If a later psmux implements blocking waits, `runFramed` can switch back without any change to the tool surface.

**`set-buffer` strips quote characters.** `say "hi" and 'bye'` arrives as `say hi and bye`, and `paste-buffer` delivered only the first line of multi-line content. Bracketed paste is therefore unavailable, and `send` types multi-line input line by line instead. **Consequence: a newline always submits.** There is no way to enter a literal newline into a pane without executing the line before it. `send-keys -l`, which everything here is built on, is byte-exact.

**Trailing whitespace is unrecoverable — from `read`, not from `run`.** Pane rows are space-padded to the pane width, so anything captured *from the pane* comes back trimmed and hard-wrapped. This is why `run` bypasses the pane entirely. It applies to `read` and `wait`, which are the tools for panes that have no shell to journal.

**`capture-pane` cannot see the alternate screen.** ConPTY consumes the SMCUP/RMCUP switches before psmux sees them, so `alternate_on` is always false and capture always reflects the primary buffer. Reading a full-screen TUI may return the wrong buffer entirely, and there is no reliable way to detect that this has happened. After a TUI exits, allow 4–6 seconds for the screen to settle before trusting a capture.

**`C-c` reaches a pane's shell, not just its foreground program.** `GenerateConsoleCtrlEvent` goes to every process sharing a console. Measurement shows that console is per-pane, not global — a sibling pane and other sessions are unaffected — so the blast radius is one pane. Within that pane it is still imprecise, hitting the shell alongside the program. Use `cancel level: terminate` when you need to end one child and keep the shell, or the application's own quit key when it has one.

**Delta reads anchor on content, not position.** `capture-pane -S -N` is relative to the pane's current bottom, so the window slides as output arrives. `read delta:true` finds the previous read's tail inside the new capture and returns what follows. A TUI that redraws in place has no stable anchor and is reported as `rewritten` — accurate, since on a redraw nothing is genuinely new.

**One server per session.** psmux runs a separate server process per session, unlike tmux's single multi-session server. Cross-session operations still work, but a control-mode client sees exactly one session.

## Interactive capture (optional)

`run` journals what para-agent dispatches. To also journal what a human — or an agent driving a REPL through `send` — types straight into a pane, load the capture module in that pane:

```powershell
Import-Module <repo>\mcp\para-agent\capture\ParaConsole.psm1 -Force
Initialize-ParaConsole -StreamDir <journalRoot>\streams\<session>
```

It hooks `prompt` for command metadata and uses `Start-Transcript` sliced by byte offset for output. The transcript matters: an `Out-Default` proxy is the obvious choice and the wrong one, because `Write-Host` writes to the host rather than the pipeline and a proxy silently misses it. Verified — `Write-Host` output is captured.

Records go to `inbox.jsonl`, not to the journal directly. The journal is single-writer by design (para-agent assigns `seq`, which is what makes gap-free integer cursors possible), so the shell hands over unsequenced envelopes and `log`/`body`/`find` drain them on read. Turns dispatched by `run` are recognised and skipped, so nothing is double-counted.

## Latency

Measured, and worth recording because the intuitive culprit was wrong. A trivial command took 473ms end to end while the shell reported executing it in **5ms**. The cost was not execution, not psmux, and not polling — it was the ~450-character wrapper being *typed* into the pane, because PSReadLine re-renders and re-highlights the entire input line on every keystroke, so latency scaled with wrapper length.

Three fixes, in order of payoff:

| Change | Saved |
|---|---|
| Wrapper moved to a file; pane types a ~60-char dot-source line | ~290ms |
| `send-keys` + `Enter` chained into one psmux invocation (each spawn costs ~65ms) | ~62ms |
| cwd cached per pane and refreshed from each sentinel, instead of querying before every dispatch | ~101ms |

473ms → **165ms median**, and detection is `existsSync` plus an `fs.watch` accelerator rather than a psmux round trip. A related bug the benchmark exposed: the wait loop had been calling `pane_dead` on every poll — a ~58ms round trip every 25ms — so pane-death is now checked on a 2s cadence instead.

## Security

This server executes arbitrary commands with the privileges of the user running the MCP client. It is a remote-code-execution surface by design — that is the feature.

The `-L` namespace confines it to its own sessions, and per-tool permissions are narrower than the shell equivalent: allowlisting `mcp__para-agent__read` grants only reading, whereas a `Bash(psmux:*)` rule would grant every psmux subcommand including `send-keys` into any pane. Prefer allowlisting individual tools over the whole server.

Content read from a pane is untrusted input. A program running in a supervised pane can print text designed to look like instructions to whatever agent reads it.

## Not yet implemented

**Server-initiated messages.** Everything here is request/response: the supervisor asks, para-agent answers. The server never speaks first, so it cannot announce "the agent you spawned just finished" — the supervisor has to come back and `wait` or `read`. MCP does allow a server to emit progress and log notifications during a long call, and those would let `wait` stream intermediate output instead of returning one lump at the end. Neither is wired up yet. Note the protocol ceiling: a server can *notify*, but it cannot *call* the client, so genuine push-driven supervision needs the supervisor to be sitting in a wait.

**Control-mode transport.** psmux implements tmux control mode (`-CC`) with `%begin`/`%end` framing and `%output` notifications, plus a `dump-state` command returning full session state as JSON including screen contents. That is a genuinely better substrate than polling `capture-pane`: streaming output instead of snapshots, and structured state instead of scraped text. It needs a long-lived client process per session and careful lifecycle handling, so it is deferred. `Mux.spawnRaw` exists as the seam for it.
