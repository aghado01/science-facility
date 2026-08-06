# Mouse Over SSH

psmux has first-class mouse support over a normal SSH pseudo-terminal when the
server runs Windows 11 build 22523 or newer. On Windows 10 and earlier Windows
11 builds, use the included client wrapper to bypass ConPTY.

## Compatibility

| Client → Server | Keyboard | Mouse | Command |
|---|:---:|:---:|---|
| Any OS → Windows 11 build 22523+ | ✅ | ✅ | Normal `ssh` |
| macOS/Linux → Windows 10 | ✅ | ✅ | `scripts/psmux-ssh.sh` |
| Any OS → Windows 10 with a normal SSH PTY | ✅ | ❌ | ConPTY consumes mouse VT bytes |
| Local Windows 10/11 | ✅ | ✅ | Run psmux normally |

## Windows 10 client wrapper

Copy `scripts/psmux-ssh.sh` to the macOS or Linux client, then run:

```sh
sh psmux-ssh.sh --session work -- user@windows-host

# A named psmux socket/namespace:
sh psmux-ssh.sh --socket project --session work -- user@windows-host

# SSH options are passed through after `--`:
sh psmux-ssh.sh --session work -- -p 2222 user@windows-host
```

For a persistent one-command client, copy both scripts to the client and run
the installer once:

```sh
sh install-psmux-win.sh --host user@windows-host \
  --psmux C:/Users/user/.cargo/bin/psmux.exe

psmux-win -s work
psmux-win -L project -s work
```

The installer writes only `~/.local/bin/psmux-win` and
`${XDG_CONFIG_HOME:-~/.config}/psmux-win/config`. Existing copies are backed
up with a timestamp before replacement. It does not edit SSH configuration.

The remote `psmux` executable must be on `PATH`. The wrapper:

1. saves the local terminal state and switches it to raw mode;
2. enables xterm button/drag reporting and SGR coordinates locally;
3. runs `ssh -T`, which gives psmux direct stdin/stdout pipes instead of a
   Windows pseudoconsole;
4. attaches to the requested session; and
5. disables mouse reporting and restores the exact saved terminal state after
   normal exit, failure, disconnect, `HUP`, `INT`, or `TERM`.

Do not add `-t` or `-tt`. Allocating a remote PTY puts ConPTY back in the byte
path and recreates the Windows 10 limitation.

To test a not-yet-installed build, select its remote executable explicitly:

```sh
sh psmux-ssh.sh --session work \
  --psmux C:/path/to/psmux.exe -- user@windows-host
```

## Byte-level cause

With a normal interactive SSH session, Windows OpenSSH hosts the remote process
inside ConPTY. On Windows 10, ConPTY consumes output DEC private-mode sequences
such as `ESC[?1000h`, `ESC[?1002h`, and `ESC[?1006h`; the SSH client therefore
never tells its terminal to report the wheel. Even if those modes are enabled
separately on the client, Windows 10 ConPTY also consumes the inbound SGR wheel
report (for example `ESC[<64;10;5M`) before psmux can parse it.

There is no SSH terminal-mode negotiation flag for xterm mouse reporting, and a
server process inside ConPTY cannot access sshd's pseudoconsole pipes. `ssh -T`
is the supported OpenSSH mechanism that omits the remote PTY. In this mode the
existing psmux VT pipe reader receives keyboard and SGR mouse bytes directly,
and psmux queries terminal size with XTWINOPS (`ESC[18t`).

The build gate for normal SSH PTYs remains in place: forcing mouse registration
through old ConPTY versions is not a safe server-only workaround (issue #457).
