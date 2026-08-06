# Windows Use Cases

Native tmux on Windows is not just "splits and tabs." Because psmux runs a **real background server** that keeps your shells, panes, and running processes alive independently of any window, it unlocks a set of workflows that Windows Terminal tabs, plain PowerShell windows, and Task Manager simply cannot do.

This page collects practical, Windows focused scenarios. Every example uses commands that ship with psmux today. Use `psmux`, `pmux`, or `tmux` interchangeably.

## The core idea: a detached server that outlives your window

Most of these scenarios rest on one property: a psmux session lives inside a **server process**, not inside your terminal window. Start something detached, close every window, log off, and the process keeps running. Attach later from any terminal to see it live.

```powershell
# Start a session in the background (no window opens)
psmux new-session -d -s work

# ...do other things, close terminals, even sign out...

# Later, from any terminal, jump back in exactly where it was
psmux attach -t work
```

That single idea (a durable server you attach to and detach from) is what makes the rest of this page possible on Windows.

---

## 1. Run background services at boot, before you log in

**The scenario:** You want an OpenVPN tunnel, an SSH reverse tunnel, a syncthing daemon, or a local dev backend to come up automatically when the machine boots, before anyone signs in. Later, after you log in, you want to *see* it (its live log, its status, its prompts) instead of guessing whether it worked.

A plain scheduled task can start a process, but it runs invisibly in the background with no console you can inspect. psmux fixes that: start the process inside a **detached psmux session**, then attach to that same session after login to watch it live, read its output, and even interact with it.

### Step 1: Create a startup script

`C:\scripts\start-vpn.ps1`:

```powershell
# Start (or reuse) a detached psmux session that hosts the VPN
psmux has-session -t vpn 2>$null
if ($LASTEXITCODE -ne 0) {
    psmux new-session -d -s vpn -n tunnel -- openvpn --config C:\vpn\client.ovpn
}
```

Running the command *inside* a psmux pane (rather than as a bare background process) means its stdout, its status messages, and any interactive prompts are captured in a live terminal you can attach to.

### Step 2: Register it with Task Scheduler

Create a task that runs at startup, under **your own user account**, with "Run whether user is logged on or not" checked. Running as your user (not `SYSTEM`) is important: the psmux server writes its discovery files to `~\.psmux\`, so keeping the server in your profile is what lets you attach to it after you log in.

```powershell
# Run once, elevated, to register the task
$action  = New-ScheduledTaskAction -Execute "pwsh.exe" `
    -Argument "-NoProfile -WindowStyle Hidden -File C:\scripts\start-vpn.ps1"
$trigger = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERNAME" -LogonType S4U -RunLevel Highest

Register-ScheduledTask -TaskName "psmux-vpn" -Action $action `
    -Trigger $trigger -Principal $principal
```

### Step 3: After login, attach and watch

```powershell
# See the tunnel come up, read its log, respond to prompts
psmux attach -t vpn

# Or just peek at the last 40 lines without attaching
psmux capture-pane -p -t vpn:tunnel -S -40
```

The same pattern works for anything that should be "always on but occasionally watched": a local database, a message broker, a self hosted service, a scheduled backup job, a mining or rendering process, or an SSH tunnel that keeps a port forwarded.

> **Tip:** Pair this with `set -g remain-on-exit on` so that if the service crashes, the pane stays open showing its final output instead of vanishing. You can then `respawn-pane -k` to restart it in place.

---

## 2. Long jobs that survive logout, lock, and RDP disconnects

**The scenario:** You kick off a multi hour build, a large `robocopy` mirror, a dataset download, a database migration, or a model training run. On a laptop you close the lid; on a server you disconnect your Remote Desktop session. Normally, closing the window (or dropping RDP) can take the process down with it.

Run it inside psmux and it keeps going. RDP disconnects, sign outs, and closed terminals do not touch the psmux server.

```powershell
# Start the long job detached
psmux new-session -d -s build -- pwsh -c "cargo build --release; Write-Host DONE"

# Disconnect RDP, go home, come back tomorrow...

# Reattach and check on it
psmux attach -t build
```

This is the classic reason Linux admins live in tmux, and it applies just as much to Windows servers you reach over RDP or SSH. The job is anchored to the server, not to your session.

> **Note:** psmux sessions survive RDP disconnects and SSH drops, but a full machine **reboot** stops the server. To restore your window and pane layout across reboots, use the [psmux-resurrect and psmux-continuum plugins](plugins.md).

---

## 3. A one command operations dashboard

**The scenario:** You want a single command that lays out a live monitoring cockpit: CPU and memory on top, network below, and a tail of a log file beside them. On Windows this normally means juggling several separate windows.

A short script builds the whole layout at once. This pairs beautifully with the [related psmux tools](../README.md#related-projects) `pstop` (a Windows htop) and `psnet` (a live network monitor).

`C:\scripts\dashboard.ps1`:

```powershell
psmux new-session -d -s dash -n monitor -- pstop
psmux split-window  -t dash:monitor -h -- psnet
psmux split-window  -t dash:monitor -v -c "C:\logs" -- pwsh -c "Get-Content app.log -Wait -Tail 20"
psmux select-layout -t dash:monitor tiled
psmux attach -t dash
```

Now `pwsh C:\scripts\dashboard.ps1` gives you an instant, reproducible ops view. Detach with `Prefix + d` and the monitors keep running in the background; reattach any time.

You can drive it entirely from scripts too:

```powershell
# Add a fourth pane later without touching the mouse
psmux split-window -t dash:monitor -v -- pwsh -c "Get-Content C:\logs\error.log -Wait"

# Broadcast the same command to every pane (great for fleets of shells)
psmux setw synchronize-panes on
psmux send-keys "cd C:\project" Enter
psmux setw synchronize-panes off
```

---

## 4. Administer Windows servers over SSH with persistent sessions

**The scenario:** You SSH into a Windows box (Windows now ships an OpenSSH server) to run maintenance. Halfway through a long operation your connection drops. Without a multiplexer, your work dies with the connection.

Install psmux on the server, and every remote session becomes durable:

```powershell
# On the remote Windows host, over SSH:
psmux new-session -A -s admin      # attach if it exists, otherwise create

# Connection drops? Reconnect and run the same command to land back where you were.
psmux new-session -A -s admin
```

The `-A` flag means "attach or create," so a single command is safe whether or not the session already exists. Combined with psmux's [full mouse over SSH support](mouse-ssh.md), you get a real multiplexer experience on remote Windows servers, the same way tmux serves Linux admins.

---

## 5. Run and watch AI coding agents in parallel

This is where native tmux on Windows shines for modern workflows. AI CLI agents (Claude Code, the `pi` agent, opencode, aider, Codex CLI, Gemini CLI, and others) are long running, interactive terminal programs. psmux is purpose built to host them: give each agent its own visible pane, run several at once, and script their input and output.

### First class Claude Code agent teams

psmux has dedicated support for Claude Code. When Claude runs inside a psmux session, its teammate agents spawn into **separate visible panes** instead of hiding in process, so you can watch every agent work.

```powershell
psmux new-session -s work
claude                       # ask Claude to create a team; panes appear per teammate
```

No configuration required. Full details, including the two agent systems and how to steer Opus toward visible panes, are in the [Claude Code guide](claude-code.md).

### Run several different agents side by side

Because each agent is just a program in a pane, you can run a whole bench of them at once and compare:

```powershell
psmux new-session -d -s agents -n claude   -- claude
psmux new-window  -t agents -n opencode    -- opencode
psmux new-window  -t agents -n aider       -- aider
psmux new-window  -t agents -n pi          -- pi
psmux attach -t agents
```

Cycle through them with `Prefix + n` / `Prefix + p`, or split them into one tiled window to watch them simultaneously. Each keeps its own scrollback and state.

### Script and supervise agents programmatically

psmux gives you a scripting handle on any agent's terminal. You can feed input with `send-keys` and read what the agent produced with `capture-pane`, which turns a psmux server into a lightweight harness for driving interactive agents from PowerShell:

```powershell
# Send a prompt into a running agent pane
psmux send-keys -t agents:aider "refactor the auth module" Enter

# Read back what it printed (the last 200 lines)
psmux capture-pane -p -t agents:aider -S -200

# Log everything an agent does to a file for later review
psmux pipe-pane -t agents:claude -o "pwsh -c 'Add-Content C:\logs\claude.log'"
```

This is the same capability that makes psmux the substrate for tools like the Claude Code teammate system: a durable, scriptable place to run interactive processes and observe them. If you build your own automation on top of Windows tmux, [libtmux and control mode](integration.md) give you Python and IDE grade hooks into the same server.

> **Tip:** Keep an agent alive but detached so it can churn on a long task while you do other work. Start it with `new-session -d`, then attach only when you want to check in or answer a prompt.

---

## 6. Reproducible development environments in one command

**The scenario:** Every time you start work on a project you open the editor, a build watcher, a dev server, and a log tail. That is four windows to arrange by hand.

Script the whole project layout once and launch it with a single command:

`C:\scripts\dev-myapp.ps1`:

```powershell
$proj = "C:\Projects\myapp"
psmux new-session  -d -s myapp -n edit  -c $proj -- nvim
psmux new-window   -t myapp   -n server -c $proj -- pwsh -c "npm run dev"
psmux new-window   -t myapp   -n build  -c $proj -- pwsh -c "cargo watch -x build"
psmux split-window -t myapp:build -v -c $proj -- pwsh -c "Get-Content .\dev.log -Wait"
psmux select-window -t myapp:edit
psmux attach -t myapp
```

`pwsh C:\scripts\dev-myapp.ps1` now boots your entire workspace, in the right directories, running the right commands, in seconds. Detach when you step away; the dev server and watcher keep running. This is the Windows equivalent of the tmuxinator / tmuxp project workflows Linux developers rely on.

---

## 7. Drive interactive Windows programs from scripts

**The scenario:** You need to automate a program that expects an interactive console (a REPL, an installer prompt, a database shell, an SSH session that asks a question). Plain redirection does not work with programs that talk to the console directly. Because psmux hosts each program in a real ConPTY, you can script it as if a human were typing.

```powershell
# Start a Python REPL detached
psmux new-session -d -s repl -- python

# Feed it statements
psmux send-keys -t repl "import platform; print(platform.system())" Enter
Start-Sleep -Milliseconds 200

# Read the answer back
psmux capture-pane -p -t repl -S -5

# Clean up
psmux kill-session -t repl
```

This pattern (send input, wait, capture output) lets you build unattended flows around tools that were never designed to be scripted, all on native Windows without WSL. The same `send-keys` plus `capture-pane` loop is how psmux's own test suite drives real interactive programs.

---

## 8. Capture and log everything a scheduled job does

**The scenario:** A nightly job runs unattended and you want a durable, timestamped record of exactly what happened on screen, not just its exit code.

`pipe-pane` mirrors a pane's output to a file or command in real time:

```powershell
# Start the job in a detached pane
psmux new-session -d -s nightly -- pwsh -c "C:\scripts\backup.ps1"

# Mirror everything the pane prints to a dated log file
psmux pipe-pane -t nightly -o "pwsh -c 'Add-Content C:\logs\backup-$(Get-Date -Format yyyyMMdd).log'"
```

Combined with hooks, you can react to events automatically. For example, flash the status bar or fire a notification when a monitored pane goes silent or a process dies:

```powershell
psmux set-hook -g pane-died "display-message 'A job pane exited'"
psmux set-hook -g alert-silence "run-shell -b 'C:\scripts\notify.ps1'"
```

See the [Scripting guide](scripting.md) for the full hook catalog, format variables, and every command referenced on this page.

---

## Why this needs a multiplexer (and not just tabs)

| Capability | Windows Terminal tabs | psmux |
|------------|:---------------------:|:-----:|
| Process survives closing the window | No | Yes |
| Process survives logout / RDP disconnect | No | Yes |
| Start a job before login, watch it after | No | Yes |
| Attach and detach from a running session | No | Yes |
| Script pane input and read pane output | No | Yes |
| One command rebuilds a whole layout | No | Yes |
| Broadcast one command to many shells | No | Yes |
| Live output logging with `pipe-pane` | No | Yes |
| Event hooks (pane died, silence, activity) | No | Yes |

Windows Terminal draws windows. psmux runs a **server**. That difference is the whole point, and it is what brings the decades of tmux driven Linux and macOS workflows to native Windows.

## Related reading

| Topic | Description |
|-------|-------------|
| [Scripting & Automation](scripting.md) | Every command used above, plus hooks, targets, and format variables |
| [Claude Code Agent Teams](claude-code.md) | Deep dive on running AI agents in visible panes |
| [Developer Integration](integration.md) | Python (libtmux), control mode, and IDE integration |
| [Warm Sessions](warm-sessions.md) | How psmux makes session and pane creation near instant |
| [Mouse Over SSH](mouse-ssh.md) | Full mouse support on remote Windows servers |
| [Plugins & Themes](plugins.md) | psmux-resurrect and psmux-continuum for save/restore across reboots |
