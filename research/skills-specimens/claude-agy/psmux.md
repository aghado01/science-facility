Portable psmux is just: unzip → put the folder on PATH → optional config. Here’s a clean layout that stays self-contained. [github](https://github.com/psmux/psmux/releases)

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

Extract the zip so the `.exe` files are directly in that folder (or note the real subfolder if the zip nests them). [github](https://github.com/psmux/psmux/releases)

---

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

Close and reopen Windows Terminal / VS Code terminals so they pick up the new user PATH. [github](https://github.com/psmux/psmux/releases)

**Session-only (no permanent change):**

```powershell
$env:Path = "D:\tools\psmux;" + $env:Path
```

---

## 3. Config file

psmux loads the **first** of these that exists: [github](https://github.com/psmux/psmux/blob/master/docs/configuration.md)

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

Keep config beside the binary and force it with env or `-f`: [github](https://github.com/psmux/psmux/blob/master/docs/configuration.md)

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

`PSMUX_CONFIG_FILE` / `-f` override the default search order. [github](https://github.com/psmux/psmux/blob/master/docs/configuration.md)

---

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

`send-keys` / `capture-pane -p` are supported for scripting. [reddit](https://www.reddit.com/r/PowerShell/comments/1r1b26l/psmux_native_tmux_for_powershell_split_panes/)

---

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

---

## 6. Checklist

| Step          | Done when                                                         |
| ------------- | ----------------------------------------------------------------- |
| Zip extracted | `psmux.exe` path known                                            |
| On PATH       | `Get-Command psmux` works in a **new** terminal                   |
| Config        | `Test-Path $HOME\.psmux.conf` **or** `$env:PSMUX_CONFIG_FILE` set |
| Works         | `psmux new -s test` / detach / `attach` / `kill-session`          |
| Scriptable    | `send-keys` + `capture-pane -p` return text                       |

---

## 7. Notes

- Zip install = extract + PATH; no installer required. [github](https://github.com/psmux/psmux/releases)
- Existing `.tmux.conf` is picked up automatically if no `.psmux.conf` is first in the search order. [github](https://github.com/psmux/psmux/blob/master/docs/faq.md)
- Reload config without restart: `psmux source-file $HOME\.psmux.conf` (or your portable path). [github](https://github.com/psmux/psmux/blob/master/docs/configuration.md)
- Default prefix is tmux-style **Ctrl+b** unless you change it in config. [docs](https://docs.rs/crate/psmux/0.1.0/source/README.md)

If you paste the path where you extracted the zip (and whether you use `pwsh` or Windows PowerShell), the PATH + `PSMUX_CONFIG_FILE` lines can be filled in exactly for your machine.

Yes. psmux exposes a small set of **process env vars you set**, injects **tmux-compatible vars inside panes**, and lets you **push your own vars into sessions/panes**. [github](https://github.com/psmux/psmux/blob/master/docs/configuration.md)

## Env vars you set (control psmux)

| Variable                | Effect                                                                                                                       |
| ----------------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| `PSMUX_CONFIG_FILE`     | Config path (same as `-f`) [github](https://github.com/psmux/psmux/blob/master/docs/configuration.md)                        |
| `PSMUX_DEFAULT_SESSION` | Default session name when you don’t pass one [github](https://github.com/psmux/psmux/blob/master/docs/configuration.md)      |
| `PSMUX_NO_WARM`         | `"1"` = disable warm/pre-spawned shells (`set -g warm off`) [github](https://github.com/psmux/psmux/blob/master/docs/faq.md) |
| `PSMUX_DIM_PREDICTIONS` | `"1"` = dim predictive/speculative text [github](https://github.com/psmux/psmux/blob/master/docs/configuration.md)           |

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

---

## Env vars psmux sets inside panes

When a shell runs under psmux, these appear (tmux-compatible): [github](https://github.com/psmux/psmux/blob/master/docs/faq.md)

| Variable    | Meaning                                                      |
| ----------- | ------------------------------------------------------------ |
| `TMUX`      | Session/server info (tools that check “am I in tmux?” work)  |
| `TMUX_PANE` | Pane id (`%0`, `%1`, …)                                      |
| `TERM`      | Often `xterm-256color` (or whatever `default-terminal` sets) |
| `COLORTERM` | `truecolor`                                                  |

Also related options that inject behavior (not always plain env, but pane-facing): [github](https://github.com/psmux/psmux/blob/master/docs/configuration.md)

- `claude-code-force-interactive` → can set `CLAUDE_CODE_FORCE_INTERACTIVE=1` in panes
- `env-shim` → injects a Unix-like `env` helper in PowerShell panes

---

## Env vars you inject into sessions/panes

Like tmux `set-environment`: [github](https://github.com/psmux/psmux/blob/master/docs/configuration.md)

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

Those are applied when **new** panes spawn; already-running panes keep their old env. [github](https://github.com/psmux/psmux/blob/master/docs/configuration.md)

---

## Server isolation (flag, not env)

Multiple independent servers via namespace:

```powershell
psmux -L agy new-session -s worker
psmux -L work new-session -s dev
```

Each `-L` name gets its own server/sessions. Handy so Claude’s `agy` stack doesn’t collide with your personal psmux. [github](https://github.com/psmux/psmux/blob/master/docs/faq.md)

There isn’t a documented `PSMUX_SOCKET` / `PSMUX_TMPDIR` style var in the config docs; isolation is primarily `-L` (and your normal Windows temp layout). [github](https://github.com/psmux/psmux/blob/master/docs/faq.md)

---

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

---

## Quick reference

**You expose (optional):**
`PSMUX_CONFIG_FILE`, `PSMUX_DEFAULT_SESSION`, `PSMUX_NO_WARM`, `PSMUX_DIM_PREDICTIONS` [github](https://github.com/psmux/psmux/blob/master/docs/configuration.md)

**psmux exposes in panes:**
`TMUX`, `TMUX_PANE`, `TERM`, `COLORTERM` [github](https://github.com/psmux/psmux/blob/master/docs/faq.md)

**You push into panes:**
`psmux set-environment` / `new-session -e` [github](https://github.com/psmux/psmux/blob/master/docs/configuration.md)

**Isolate servers:**
`psmux -L <name>` [github](https://github.com/psmux/psmux/blob/master/docs/faq.md)

For the Claude→agy setup, the useful trio is usually `PSMUX_CONFIG_FILE` (portable conf), `-L agy` (private server), and `set-environment -g` for things like `AGY_WORKDIR`.
