/**
 * Backend adapter for a tmux-compatible multiplexer.
 *
 * Deliberately speaks only the tmux command language, so the same code drives
 * psmux on Windows and real tmux on Linux/macOS. Nothing psmux-specific lives
 * here except the default binary search order.
 */

import { fileURLToPath } from "node:url";
import { execFile, spawn } from "node:child_process";
import { existsSync } from "node:fs";
import path from "node:path";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const PACKAGE_ROOT = path.resolve(__dirname, "..");

/**
 * Resolve relative or absolute path against process.cwd() and package root.
 */
export function resolvePath(targetPath) {
  if (!targetPath) return targetPath;
  if (path.isAbsolute(targetPath)) return targetPath;

  const cwdResolved = path.resolve(process.cwd(), targetPath);
  if (existsSync(cwdResolved)) return cwdResolved;

  const pkgResolved = path.resolve(PACKAGE_ROOT, targetPath);
  if (existsSync(pkgResolved)) return pkgResolved;

  return cwdResolved;
}

/** Candidate binaries, in preference order, when PARA_MUX_BIN is unset. */
const BIN_CANDIDATES = [
  process.platform === "win32" ? "tmux.exe" : null,
  process.platform === "win32" ? "psmux.exe" : null,
  "tmux",
].filter(Boolean);

/** Well-known install locations checked before falling back to PATH lookup. */
const BIN_HINTS = [
  path.join(process.cwd(), "mcp", "para-agent", "bin", "mux"),
  path.join(process.cwd(), "bin", "mux"),
  path.join(PACKAGE_ROOT, "bin", "mux"),
  process.env.PSMUX_HOME,
  process.env.PORTABLE_ROOT ? path.join(process.env.PORTABLE_ROOT, "psmux") : null,
].filter(Boolean);

function resolveBin() {
  if (process.env.PARA_MUX_BIN) return resolvePath(process.env.PARA_MUX_BIN);
  for (const dir of BIN_HINTS) {
    for (const name of BIN_CANDIDATES) {
      const full = path.join(dir, name);
      if (existsSync(full)) return full;
    }
  }
  // Fall back to bare name and let the OS resolve it via PATH.
  return BIN_CANDIDATES[0];
}

export function resolveNuBin() {
  if (process.env.PARA_NU_BIN) return resolvePath(process.env.PARA_NU_BIN);
  const nuCandidates = [
    path.join(process.cwd(), "mcp", "para-agent", "bin", "nu", "nu.exe"),
    path.join(process.cwd(), "bin", "nu", "nu.exe"),
    path.join(PACKAGE_ROOT, "bin", "nu", "nu.exe"),
    path.join(process.cwd(), "mcp", "para-agent", "bin", "nu", "nu"),
    path.join(process.cwd(), "bin", "nu", "nu"),
    path.join(PACKAGE_ROOT, "bin", "nu", "nu"),
  ];
  for (const cand of nuCandidates) {
    if (existsSync(cand)) return cand;
  }
  return "nu";
}

export class MuxError extends Error {
  constructor(message, { argv, code, stderr } = {}) {
    super(message);
    this.name = "MuxError";
    this.argv = argv;
    this.code = code;
    this.stderr = stderr;
  }
}

function defaultNamespace() {
  const base = path.basename(process.cwd()).replace(/[^A-Za-z0-9_-]/g, "-").slice(0, 30);
  return base ? `para-${base}` : "para";
}

export class Mux {
  constructor(opts = {}) {
    this.bin = opts.bin ?? resolveBin();
    // -L isolates our sessions. Workspace-contextual if PARA_MUX_NAMESPACE is unset.
    this.namespace = opts.namespace ?? process.env.PARA_MUX_NAMESPACE ?? defaultNamespace();
    this.defaultTimeoutMs = opts.defaultTimeoutMs ?? 15000;
    
    const configFile = process.env.PARA_MUX_CONFIG_FILE ?? process.env.PSMUX_CONFIG_FILE;
    const resolvedConfig = configFile ? resolvePath(configFile) : null;

    this.env = {
      ...process.env,
      ...(resolvedConfig ? { PSMUX_CONFIG_FILE: resolvedConfig } : {}),
    };
  }

  /** Prefix the namespace flag onto a command's argv. */
  argv(args) {
    return this.namespace ? ["-L", this.namespace, ...args] : [...args];
  }

  /**
   * Run one multiplexer command to completion.
   * Never throws on a non-zero exit; callers inspect `code` themselves, because
   * several commands (has-session, wait-for) use exit status as their result.
   */
  run(args, { timeoutMs = this.defaultTimeoutMs, input } = {}) {
    const argv = this.argv(args);
    return new Promise((resolve) => {
      const child = execFile(
        this.bin,
        argv,
        { timeout: timeoutMs, windowsHide: true, env: this.env, maxBuffer: 32 * 1024 * 1024 },
        (err, stdout, stderr) => {
          resolve({
            stdout: stdout ?? "",
            stderr: stderr ?? "",
            code: err ? (typeof err.code === "number" ? err.code : 1) : 0,
            timedOut: Boolean(err && err.killed),
            argv,
          });
        }
      );
      if (input !== undefined) {
        child.stdin.end(input);
      }
    });
  }

  /** Same as run(), but throws when the command fails. For commands where a
   *  non-zero exit is genuinely an error rather than a result. */
  async runOrThrow(args, opts) {
    const res = await this.run(args, opts);
    if (res.code !== 0) {
      throw new MuxError(
        `mux command failed (exit ${res.code}): ${args.join(" ")}\n${res.stderr || res.stdout}`.trim(),
        { argv: res.argv, code: res.code, stderr: res.stderr }
      );
    }
    return res;
  }

  /** Long-lived child, used for the blocking `wait-for <channel>` call. */
  spawnRaw(args) {
    return spawn(this.bin, this.argv(args), {
      windowsHide: true,
      env: this.env,
      stdio: ["ignore", "pipe", "pipe"],
    });
  }

  // ---- queries -------------------------------------------------------------

  async version() {
    const { stdout } = await this.run(["-V"]);
    return stdout.trim();
  }

  async hasSession(session) {
    const { code } = await this.run(["has-session", "-t", session]);
    return code === 0;
  }

  /** List sessions in this namespace as structured records. */
  async listSessions() {
    const fmt = "#{session_name}\t#{session_windows}\t#{session_created}\t#{session_attached}";
    const { stdout, code } = await this.run(["list-sessions", "-F", fmt]);
    if (code !== 0) return []; // no server running == no sessions
    return stdout
      .split(/\r?\n/)
      .filter(Boolean)
      .map((line) => {
        const [name, windows, created, attached] = line.split("\t");
        return {
          session: name,
          windows: Number(windows),
          createdAt: Number(created) ? new Date(Number(created) * 1000).toISOString() : null,
          attachedClients: Number(attached),
        };
      });
  }

  /** List panes for one session (or all sessions when session is omitted). */
  async listPanes(session) {
    const fmt = [
      "#{session_name}",
      "#{window_index}",
      "#{pane_index}",
      "#{pane_id}",
      "#{pane_pid}",
      "#{pane_current_command}",
      "#{pane_current_path}",
      "#{pane_width}",
      "#{pane_height}",
      "#{pane_dead}",
      "#{pane_title}",
    ].join("\t");
    const args = session
      ? ["list-panes", "-s", "-t", session, "-F", fmt]
      : ["list-panes", "-a", "-F", fmt];
    const { stdout, code } = await this.run(args);
    if (code !== 0) return [];
    return stdout
      .split(/\r?\n/)
      .filter(Boolean)
      .map((line) => {
        const f = line.split("\t");
        return {
          session: f[0],
          window: Number(f[1]),
          pane: Number(f[2]),
          paneId: f[3],
          pid: Number(f[4]),
          command: f[5],
          cwd: f[6],
          width: Number(f[7]),
          height: Number(f[8]),
          dead: f[9] === "1",
          title: f[10] ?? "",
          // Fully-qualified target, safe to pass to any -t flag.
          handle: `${f[0]}:${f[1]}.${f[2]}`,
        };
      });
  }

  /** Query format variables against a target. */
  async format(target, formatString) {
    const args = ["display-message", "-p"];
    if (target) args.push("-t", target);
    args.push(formatString);
    const { stdout, code } = await this.run(args);
    return code === 0 ? stdout.replace(/\r?\n$/, "") : null;
  }

  // ---- pane I/O ------------------------------------------------------------

  /**
   * Capture pane content as plain text.
   * `scrollback` reaches N lines back into history; 0 captures only what is
   * currently visible. Without -e, escape sequences are already stripped.
   */
  async capture(target, { scrollback = 0, joinWrapped = false } = {}) {
    const args = ["capture-pane", "-p", "-t", target];
    if (scrollback > 0) args.push("-S", `-${scrollback}`);
    if (joinWrapped) args.push("-J");
    const { stdout, code, stderr } = await this.run(args);
    if (code !== 0) {
      throw new MuxError(`capture-pane failed for ${target}: ${stderr || stdout}`.trim(), { code });
    }
    // Pane rows are space-padded to the pane width; trim the padding.
    return stdout.replace(/\r/g, "").split("\n").map((l) => l.replace(/\s+$/, "")).join("\n");
  }

  /** Send text with no key-name parsing (so "Enter" arrives as the word Enter). */
  async sendLiteral(target, text) {
    await this.runOrThrow(["send-keys", "-t", target, "-l", text]);
  }

  /** Send tmux key names, e.g. ["Enter"], ["C-c"], ["Up","Up"]. */
  async sendKeys(target, keys) {
    await this.runOrThrow(["send-keys", "-t", target, ...keys]);
  }

  /**
   * Send a line and submit it, in ONE process invocation.
   *
   * Each psmux CLI call costs ~65ms, essentially all of it process spawn, so
   * doing this as two calls wastes an entire round trip per command. A literal
   * trailing newline does not submit (measured), but the CLI accepts `;`-
   * chained commands, which does.
   */
  async sendLine(target, text) {
    await this.runOrThrow([
      "send-keys", "-t", target, "-l", text,
      ";",
      "send-keys", "-t", target, "Enter",
    ]);
  }

  /**
   * Send text to a pane, byte-exact, one line at a time.
   *
   * set-buffer + paste-buffer would be the natural path for multi-line input,
   * and is what bracketed paste is for. It cannot be used here: psmux 3.3.7's
   * set-buffer strips every quote character from its argument — `say "hi" and
   * 'bye'` arrives as `say hi and bye` — and paste-buffer delivered only the
   * first line of multi-line content. send-keys -l, by contrast, is byte-exact
   * for quotes, backslashes, `$`, braces and backticks.
   *
   * Consequence: a newline in `text` is always a submit. There is no way to
   * enter a literal newline into a pane without executing the line before it.
   */
  async sendText(target, text, { submit = true } = {}) {
    const lines = text.split(/\r?\n/);
    for (let i = 0; i < lines.length; i++) {
      if (lines[i] !== "") await this.sendLiteral(target, lines[i]);
      const isLast = i === lines.length - 1;
      if (!isLast || submit) await this.sendKeys(target, ["Enter"]);
    }
  }

  // ---- lifecycle -----------------------------------------------------------

  async newSession({ session, cwd, width, height, env = {}, command }) {
    const args = ["new-session", "-d", "-s", session];
    if (width) args.push("-x", String(width));
    if (height) args.push("-y", String(height));
    if (cwd) args.push("-c", cwd);
    for (const [k, v] of Object.entries(env)) args.push("-e", `${k}=${v}`);
    if (command && command.length) args.push("--", ...command);
    await this.runOrThrow(args);
    return `${session}:0.0`;
  }

  async killSession(session) {
    const { code, stderr, stdout } = await this.run(["kill-session", "-t", session]);
    return { ok: code === 0, detail: (stderr || stdout).trim() };
  }

  async killPane(target) {
    const { code, stderr, stdout } = await this.run(["kill-pane", "-t", target]);
    return { ok: code === 0, detail: (stderr || stdout).trim() };
  }

  // ---- synchronization -----------------------------------------------------

  // There is deliberately no wait-for wrapper here.
  //
  // tmux's `wait-for <channel>` blocks until another client signals it, which
  // would make command completion an event rather than a poll. psmux 3.3.7
  // accepts the command and returns immediately — measured at 84ms and 97ms
  // against a signal deliberately sent at 1500ms, both with and without a
  // prior `-L` lock — so it cannot be used to synchronize. Completion
  // detection lives in framing.js and polls for an end marker instead.
  //
  // If a later psmux implements blocking waits, runFramed() can switch back to
  // an event without any change to the tool surface.

  /** True once the pane's process has exited. */
  async isDead(target) {
    return (await this.format(target, "#{pane_dead}")) === "1";
  }

  // ---- cancellation --------------------------------------------------------
  //
  // Measured scope of a C-c sent to a pane (psmux 3.3.7, Windows 11):
  //   - it stops that pane's foreground child and returns the shell to a prompt
  //   - a sibling pane in the SAME window is unaffected
  //   - another session is unaffected (separate server process)
  // So the ConPTY "reaches every process sharing the console" caveat is scoped
  // to one pane, not to the machine. Cross-pane propagation is not a risk; the
  // only imprecision is that it hits the shell as well as the program.
  //
  // For precision within a pane, terminate a specific descendant by PID
  // instead. Verified: killing the child left the shell alive with the same
  // pane_pid, not dead, and accepting new commands.

  /** Send C-c to a pane. Pane-scoped; siblings and other sessions are safe. */
  async interrupt(target) {
    await this.sendKeys(target, ["C-c"]);
  }

  /** Every descendant process of `rootPid`, breadth-first. */
  async listDescendants(rootPid) {
    const table = await this.processTable();
    const byParent = new Map();
    for (const p of table) {
      if (!byParent.has(p.ppid)) byParent.set(p.ppid, []);
      byParent.get(p.ppid).push(p);
    }
    const out = [];
    const queue = [Number(rootPid)];
    const seen = new Set(queue);
    while (queue.length) {
      for (const child of byParent.get(queue.shift()) ?? []) {
        if (seen.has(child.pid)) continue; // defensive against cycles
        seen.add(child.pid);
        out.push(child);
        queue.push(child.pid);
      }
    }
    return out;
  }

  /** {pid, ppid, name} for every process on the machine. */
  async processTable() {
    if (process.platform === "win32") {
      const script =
        "Get-CimInstance Win32_Process | " +
        "Select-Object ProcessId,ParentProcessId,Name | ConvertTo-Json -Compress";
      for (const exe of ["pwsh", "powershell"]) {
        const res = await execExternal(exe, ["-NoProfile", "-NonInteractive", "-Command", script]);
        if (res.code !== 0 || !res.stdout.trim()) continue;
        try {
          const rows = JSON.parse(res.stdout);
          return (Array.isArray(rows) ? rows : [rows]).map((r) => ({
            pid: Number(r.ProcessId),
            ppid: Number(r.ParentProcessId),
            name: r.Name,
          }));
        } catch {
          /* try the next interpreter */
        }
      }
      throw new MuxError("could not enumerate processes (no usable pwsh/powershell)");
    }

    const res = await execExternal("ps", ["-eo", "pid=,ppid=,comm="]);
    if (res.code !== 0) throw new MuxError(`ps failed: ${res.stderr}`);
    return res.stdout
      .split("\n")
      .map((l) => l.trim())
      .filter(Boolean)
      .map((l) => {
        const [pid, ppid, ...rest] = l.split(/\s+/);
        return { pid: Number(pid), ppid: Number(ppid), name: rest.join(" ") };
      });
  }

  /** Terminate one process by PID, leaving its parent shell alone. */
  async terminateProcess(pid, { tree = false } = {}) {
    if (process.platform === "win32") {
      const args = ["/PID", String(pid), "/F"];
      if (tree) args.push("/T");
      const res = await execExternal("taskkill", args);
      return { ok: res.code === 0, detail: (res.stderr || res.stdout).trim() };
    }
    try {
      process.kill(pid, tree ? "SIGKILL" : "SIGTERM");
      return { ok: true, detail: "" };
    } catch (err) {
      return { ok: false, detail: String(err?.message ?? err) };
    }
  }
}

/** Run a non-multiplexer binary. Never throws; callers inspect `code`. */
function execExternal(bin, args, { timeoutMs = 20000 } = {}) {
  return new Promise((resolve) => {
    execFile(
      bin,
      args,
      { timeout: timeoutMs, windowsHide: true, maxBuffer: 32 * 1024 * 1024 },
      (err, stdout, stderr) =>
        resolve({
          stdout: stdout ?? "",
          stderr: stderr ?? "",
          code: err ? (typeof err.code === "number" ? err.code : 1) : 0,
        })
    );
  });
}
