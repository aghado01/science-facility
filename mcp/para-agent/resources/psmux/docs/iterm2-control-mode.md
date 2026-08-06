# Using psmux with iTerm2 (`tmux -CC` integration)

iTerm2's [tmux integration](https://iterm2.com/documentation-tmux-integration.html)
treats `tmux -CC` as a wire protocol. Each tmux window becomes a native
iTerm2 tab, panes become native iTerm2 split panes, scrollback is local,
and the connection survives network drops.

`psmux` ships full `-CC` support, so the same workflow works against a
Windows host running `psmux.exe`. This document shows how to set it up.

---

## Quick start

On the **macOS** machine running iTerm2:

```sh
stty raw -echo -isig
ssh -T user@windows-host 'C:/path/to/psmux.exe -CC'
```

That's it. iTerm2 detects the DCS opener emitted by psmux and switches
into tmux gateway mode automatically. You'll see your shell prompt
appear in a fresh native iTerm2 tab.

To detach (return iTerm2 to a normal terminal), press `Esc` in the
gateway-mode tab; psmux continues running and you can re-attach later.

---

## Why each flag is needed

### `stty raw -echo -isig`

Puts your **local** macOS TTY into raw mode *before* launching SSH.
iTerm2 sends a `\x03` (Ctrl-C) byte the moment it enters tmux gateway
mode. With the default cooked TTY, the `ISIG` flag would convert that
byte to `SIGINT` and kill the SSH process before the gateway handshake
ever happens. The `-echo` and `raw` flags also stop the local TTY
from corrupting the byte stream.

### `ssh -T`

Disables remote PTY allocation. Without `-T`, OpenSSH for Windows
wraps psmux's stdio in a **ConPTY** (`FILE_TYPE_CHAR`), and ConPTY
silently consumes the DCS escape sequences (`\x1bP1000p ... \x1b\`)
that the tmux-CC protocol depends on, plus injects its own cursor
positioning sequences between protocol lines. With `-T` the channel
is plain pipes (`FILE_TYPE_PIPE`) and every byte is preserved.

### `psmux -CC` (no extra arguments)

`-CC` is "control mode, no echo": the same flag real tmux uses.
psmux automatically:

1. Spawns a background server if none is running.
2. Creates a numbered session (`0`, `1`, `2`, …) the way tmux does
   when invoked bare.
3. Connects to the server, authenticates, and switches stdin/stdout
   into the tmux control protocol.

You can pass `new-session -A -s NAME` if you want a stable named
session, but it isn't required.

---

## Drop-in tmux replacement

Anywhere a workflow uses `tmux -CC`, replace it with `psmux -CC`:

| Real tmux command         | psmux equivalent          |
| ------------------------- | ------------------------- |
| `tmux -CC`                | `psmux -CC`               |
| `tmux -CC new -A -s work` | `psmux -CC new -A -s work`|
| `tmux -CC attach -t work` | `psmux -CC attach -t work`|

iTerm2's "**Session → tmux → New tmux Window**" / "**Attach to tmux
Session**" menu items work the same way once you've launched any of
these from a profile command.

---

## Configuring an iTerm2 profile

For a one-click experience:

1. `iTerm2 → Settings → Profiles → +` (new profile).
2. **General → Command → Custom Shell**:
   ```sh
   /bin/sh -c "stty raw -echo -isig; ssh -T user@windows-host 'C:/path/to/psmux.exe -CC'"
   ```
3. Save. Open a new tab with this profile and iTerm2 enters tmux
   integration mode immediately.

---

## What works

- ✅ Multiple tmux windows → multiple iTerm2 tabs.
- ✅ `split-window` / `split-pane` → native iTerm2 splits.
- ✅ Cmd-T (new tmux window/tab), Cmd-D (split), Cmd-W (kill pane), etc.
  When you press Cmd-T in a tmux-attached pane, iTerm2 prompts
  **"New tmux Tab / Use Default Profile / Cancel"**: picking
  *New tmux Tab* opens a new native tab backed by a fresh tmux
  window via `new-window -PF '#{window_id}'`.
- ✅ Drag-resizing the native iTerm2 window resizes all panes
  inside it. iTerm2 sends `refresh-client -C w,h` (on attach) and
  `resize-window -x w -y h -t @N` (on every drag) and psmux
  applies the viewport and target-window geometry separately, then emits
  `%layout-change` so the splits repaint.
- ✅ Typing `exit` (or otherwise terminating the shell) in a pane
  removes that split natively in iTerm2. psmux diffs window state
  on every reap cycle and emits `%layout-change` /
  `%window-pane-changed` (or `%window-close` for the last pane in
  a window) so iTerm2 stays in sync.
- ✅ Native iTerm2 scrollback, copy-mode (⌘F find), Touch Bar, tab
  reordering, all work because iTerm2 renders the panes locally.
- ✅ Keyboard input including Enter, Tab, Backspace, arrow keys,
  Ctrl chords, function keys, and Alt sequences.
- ✅ ANSI escape sequences (cursor moves, colors, mouse reporting,
  bracketed paste) round-trip correctly to the shell.
- ✅ Reconnecting after network drop: re-run the SSH command and
  iTerm2 re-attaches to the live psmux session.

---

## Known quirks

### First prompt of a new pane appears at the top

When iTerm2 first opens a tmux pane (initial connection or a fresh
Cmd-T tab), the first shell prompt is rendered at the **top** of
the pane. After you press Enter once, the next prompt jumps to the
**bottom** and subsequent output behaves normally.

This is intrinsic ConPTY behaviour, not a psmux bug. ConPTY starts
the Windows console buffer with the cursor at row 0; pwsh prints
its first prompt there. `capture-pane` faithfully reports a single
row of content, so iTerm2 paints it at the top. Once the shell
emits its first newline, ConPTY's normal scroll-region behaviour
takes over and the prompt settles at the bottom of the visible
region. Real tmux running against pwsh through ConPTY shows the
same thing.

---

## Troubleshooting

### `Detached` immediately after `** tmux mode started **`

Almost always one of:

1. **Forgot `stty raw -echo -isig`**: iTerm2's `\x03` was caught by
   the local TTY and converted to SIGINT.
2. **Used `ssh -t` instead of `ssh -T`**: ConPTY ate the DCS bytes.
3. **Wrong path to psmux.exe**: use forward slashes inside the SSH
   single-quoted command: `'C:/Users/you/psmux.exe -CC'`.

### Inspecting the protocol log

psmux writes a verbose dump of every CC command and `%output` to
`%USERPROFILE%\.psmux\cc_debug.log` on the Windows side. Tail it:

```sh
ssh user@windows-host 'Get-Content -Wait $env:USERPROFILE\.psmux\cc_debug.log'
```

Look for:
- `unknown command:` psmux didn't recognize a CC command iTerm2
  sent. Please open an issue with the line.
- `FATAL:` control-mode bootstrap failed (port file missing,
  auth rejected, etc.).
- `IN  (N bytes):` a hex dump of bytes iTerm2 sent.
- `OUT (N bytes):` a quoted dump of bytes psmux sent back.

### Arrow keys / function keys printing literal characters

Fixed in psmux ≥ 3.4 (commit referenced from issue #261). If you
see `[A` instead of recall-previous-command, you're on an older
build, pull, rebuild, redeploy.

### Garbled output after attaching

Make sure the macOS-side `stty` setup runs **before** SSH and that
the iTerm2 profile isn't re-cooking the TTY (e.g. don't add
`stty sane` to your `.zprofile`).

---

## Implementation notes (for contributors)

These are the pieces of psmux that make iTerm2's `tmux -CC` happy:

- **`run_control_mode`** in `src/main.rs`: TCP/AUTH client +
  CONTROL_NOECHO handshake + raw-mode setup + stdin `\r→\n`
  translation + `cc_debug.log`.
- **iTerm CC command surface** in `src/server/connection.rs`:
  - `phony-command` and `copy-mode` compatibility handlers.
  - `send` alias for `send-keys` (iTerm uses the short form).
  - `0xNN` hex codepoint argument decoding (every iTerm keystroke).
  - Combined short-flag clusters where the **last** char takes a
    value: `new-window -PF '#{window_id}'`,
    `capture-pane -peqJN -t %1 -S -1000`, `send -lt %1 X` etc.
    Parsed by `cli::has_short_flag` and the cluster-tail branch
    of `cli::extract_flag_value`.
  - `refresh-client -C` tracks each control client's default and
    per-window viewport. `resize-window -x w -y h -t @N` changes only
    the target window, switches it to manual sizing, resizes its PTYs,
    and emits `%layout-change`.
  - Top-level `;` command separation with a queue (one
    `%begin/%end` pair per sub-command).
  - **Send-coalescing**: consecutive `send`/`send-keys` sub-commands
    on a single input line are merged into one PTY write so VT
    sequences like `\x1b[A` arrive atomically. Without this,
    PSReadLine in pwsh times out between the ESC and the
    `[A` and prints them as literal characters.
- **`%subscription-changed`** format in `src/control.rs`: uses `:`
  separator (iTerm requires colon, not dash).
- **Pane-death notifications** in `src/server/mod.rs` reap loop,   snapshots `(window_id, active_pane_id, leaf_count)` per window
  before `tree::reap_children`, then diffs after to emit
  `%layout-change` / `%window-pane-changed` / `%window-close` /
  `%session-window-changed` to control-mode clients. Without this,
  shells that exit naturally (`exit` in pwsh) leave dead splits
  visible in iTerm2 forever.
- **ConPTY raw mode** in `src/main.rs`: when stdin is a console
  handle (e.g. `ssh -t`), clear `ENABLE_PROCESSED_INPUT |
  ENABLE_LINE_INPUT | ENABLE_ECHO_INPUT` and set
  `ENABLE_VIRTUAL_TERMINAL_INPUT`; on stdout set
  `ENABLE_VIRTUAL_TERMINAL_PROCESSING |
  DISABLE_NEWLINE_AUTO_RETURN`. This makes the `ssh -t` path also
  work, though `ssh -T` is preferred.
