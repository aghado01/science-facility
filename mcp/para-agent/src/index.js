#!/usr/bin/env node
/**
 * para-agent — an MCP interface for supervising agents through a terminal
 * multiplexer.
 *
 * The supervisor (any MCP-speaking agent) gets persistent, addressable panes it
 * can spawn programs into, drive, and read back. Because the multiplexer server
 * outlives every command, pane state — shell variables, cwd, a running REPL, a
 * live agent session — survives across separate supervisor turns.
 *
 * Backend is any tmux-compatible multiplexer: psmux on Windows, tmux elsewhere.
 */

import { McpServer, StdioServerTransport, z } from "./deps.js";

import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { Mux, MuxError, resolvePath, resolveNuBin } from "./mux.js";
import { waitStable, waitPattern, deltaOf, DEFAULT_DIALECT } from "./framing.js";
import { Journal } from "./journal.js";
import { runCaptured, finalizeOpenTurns, requestCancel, CAPTURE_DIALECTS } from "./capture.js";
import { getNuProfileConfig } from "./profiles.js";
import { TranscriptStore } from "./transcript.js";
import { AdapterEngine } from "./adapters.js";
import { ConversationGate } from "./conversation-gate.js";
import { isWellFormedUnicode } from "./identity.js";
import { MediatedTurnError, MediatedTurnService } from "./mediated-turn.js";
import { ProcessNativeClient } from "./native-client.js";
import { deriveConversationKey } from "./quarantine-reconciliation.js";
import { RawTraceSink } from "./raw-trace.js";

const mux = new Mux();
const adapterEngine = new AdapterEngine();
const nativeClient = new ProcessNativeClient();
const conversationGate = new ConversationGate();
const transcriptStores = new Map();

/** Last capture per target, for delta reads. */
const lastSeen = new Map();

/**
 * Workspace root, resolved once at startup.
 *
 * para-agent's working files are workspace-scoped by design: a supervisor
 * working in project X launches para-agent there, and both land in the same
 * workspace, so `<workspace>/.para-agent/` holds that project's journals and
 * transcripts and can be resumed from it. Launch cwd is that workspace by
 * convention; PARA_WORKSPACE_ROOT states it explicitly when it is not.
 *
 * Distinct from PARA_PKG_ROOT (where para-agent itself lives) — see profiles.js,
 * which passes both into the nu profile environment.
 */
const WORKSPACE_ROOT = process.env.PARA_WORKSPACE_ROOT
  ? resolvePath(process.env.PARA_WORKSPACE_ROOT)
  : process.cwd();

/**
 * One journal per session. Workspace-contextual if PARA_JOURNAL_ROOT is unset.
 */
const defaultJournalRoot = path.join(WORKSPACE_ROOT, ".para-agent", "journals");
const JOURNAL_ROOT = process.env.PARA_JOURNAL_ROOT ? resolvePath(process.env.PARA_JOURNAL_ROOT) : defaultJournalRoot;
const journals = new Map();

/** Session name out of a pane target: `agent-foo:0.1` -> `agent-foo`. */
const sessionOf = (handle) => String(handle).split(":")[0];

async function writableTranscriptFor(handle) {
  const stream = sessionOf(handle);
  if (!transcriptStores.has(stream)) {
    const store = await TranscriptStore.openWritable({ workspaceRoot: WORKSPACE_ROOT, sessionId: stream });
    transcriptStores.set(stream, store);
  }
  return transcriptStores.get(stream);
}

async function readOnlyTranscriptFor(handle) {
  return TranscriptStore.openReadOnly({ workspaceRoot: WORKSPACE_ROOT, sessionId: sessionOf(handle) });
}

function createMediatedTurnService() {
  return new MediatedTurnService({
    adapterEngine,
    storeForHandle: writableTranscriptFor,
    nativeClient,
    gate: conversationGate,
    traceSinkFactory: async ({ profile, adapter, exchangeId, store }) => new RawTraceSink({
      traceDir: path.dirname(store.traceDir),
      sessionKey: store.sessionKey,
      exchangeId,
      format: profile.native_events.format,
      adapter,
    }),
  });
}

let mediatedTurnService = createMediatedTurnService();

/** Test seam for MCP-wire verification; production uses the application service above. */
export function setMediatedTurnServiceForTesting(service) {
  if (!service || typeof service.delegate !== "function") {
    throw new TypeError("test mediation service must implement delegate()");
  }
  mediatedTurnService = service;
}

async function journalFor(handle) {
  const stream = sessionOf(handle);
  if (!journals.has(stream)) {
    journals.set(stream, await new Journal({ root: JOURNAL_ROOT, stream }).init());
  }
  return journals.get(stream);
}

const SESSION_PREFIX = process.env.PARA_SESSION_PREFIX ?? "agent-";

/** Scrollback depth used for delta reads when the caller does not set one. */
const DELTA_WINDOW_LINES = Number(process.env.PARA_DELTA_WINDOW ?? 1000);

function sanitizeName(name) {
  // tmux treats ':' and '.' as target separators, so they cannot appear in a
  // session name we intend to address later.
  return name.replace(/[^A-Za-z0-9_-]/g, "-").slice(0, 60);
}

/** Structured JSON result, plus optional raw text as a second block. */
function reply(meta, rawText) {
  const content = [{ type: "text", text: JSON.stringify(meta, null, 2) }];
  if (rawText !== undefined && rawText !== null && rawText !== "") {
    content.push({ type: "text", text: rawText });
  }
  return { content };
}

function fail(err) {
  const message = err instanceof MuxError ? err.message : String(err?.message ?? err);
  return {
    isError: true,
    content: [{ type: "text", text: JSON.stringify({ error: message }, null, 2) }],
  };
}

function failMediated(err) {
  const code = err?.code ?? "MEDIATED_TURN_FAILED";
  const message = String(err?.message ?? err);
  return {
    isError: true,
    content: [{
      type: "text",
      text: JSON.stringify({
        error: { code, message },
        ...(err?.receipt ? { receipt: err.receipt } : {}),
      }, null, 2),
    }],
  };
}

function canonicalIdentityInput(label) {
  return z.string().min(1)
    .refine(
      (value) => value === value.trim(),
      { message: `${label} must not contain leading or trailing whitespace` },
    )
    .refine(
      isWellFormedUnicode,
      { message: `${label} must be well-formed Unicode` },
    );
}

export const server = new McpServer({ name: "para-agent", version: "0.1.0" });

// ---------------------------------------------------------------------------
// Discovery
// ---------------------------------------------------------------------------

server.registerTool(
  "list",
  {
    title: "List agent sessions and panes",
    description:
      "List every session and pane in the para-agent namespace. Returns each pane's `handle` " +
      "(a fully-qualified target like `agent-foo:0.0`), the foreground command, cwd, size, and " +
      "whether its process has exited. Start here to find out what is already running.",
    inputSchema: {
      session: z.string().optional().describe("Restrict to one session. Omit to list all."),
    },
  },
  async ({ session }) => {
    try {
      const [sessions, panes] = await Promise.all([mux.listSessions(), mux.listPanes(session)]);
      return reply({
        namespace: mux.namespace,
        binary: mux.bin,
        sessions: session ? sessions.filter((s) => s.session === session) : sessions,
        panes,
      });
    } catch (err) {
      return fail(err);
    }
  }
);

server.registerTool(
  "status",
  {
    title: "Inspect one pane",
    description:
      "Query live state for a single pane: foreground command, working directory, PID, size, " +
      "scrollback depth, and whether the process has died. Cheaper than `read` when you only " +
      "need to know what a pane is doing rather than what it says.",
    inputSchema: {
      handle: z.string().describe("Pane target, e.g. `agent-foo:0.0` or a session name."),
    },
  },
  async ({ handle }) => {
    try {
      const fmt = [
        "#{session_name}", "#{window_index}", "#{pane_index}", "#{pane_id}", "#{pane_pid}",
        "#{pane_current_command}", "#{pane_current_path}", "#{pane_width}", "#{pane_height}",
        "#{pane_dead}", "#{history_size}", "#{pane_title}",
      ].join("\t");
      const raw = await mux.format(handle, fmt);
      if (raw == null) return fail(new Error(`no such pane: ${handle}`));
      const f = raw.split("\t");
      return reply({
        handle,
        session: f[0], window: Number(f[1]), pane: Number(f[2]), paneId: f[3],
        pid: Number(f[4]), command: f[5], cwd: f[6],
        width: Number(f[7]), height: Number(f[8]),
        dead: f[9] === "1", scrollbackLines: Number(f[10]), title: f[11] ?? "",
      });
    } catch (err) {
      return fail(err);
    }
  }
);

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

server.registerTool(
  "spawn",
  {
    title: "Spawn a persistent agent pane",
    description:
      "Create a detached session and return its pane handle. The session outlives this call and " +
      "every later one — its shell state, cwd and any running program persist until killed.\n\n" +
      "Two shapes:\n" +
      "  • Omit `command` to get a shell pane (defaults to Nushell with the selected profile). Drive it with `run`.\n" +
      "  • Pass `command` to launch a program directly in the pane (an interactive agent, a REPL, " +
      "a TUI). There is no shell, so `run` will not work — drive it with `send` / `wait` / `read`.",
    inputSchema: {
      name: z.string().describe("Short name for the session. Sanitized; ':' and '.' are not allowed."),
      command: z.array(z.string()).optional()
        .describe("Program and args to run instead of a shell, e.g. [\"python\",\"-i\"]."),
      shell: z.enum(["nu", "pwsh", "bash"]).default("nu").describe("Shell substrate when command is omitted (default 'nu')."),
      profile: z.enum(["para-agent", "primary-agent"]).default("para-agent")
        .describe("Nushell profile for nu shell panes: 'para-agent' (worker) or 'primary-agent' (supervisor)."),
      cwd: z.string().optional().describe("Working directory for the pane."),
      env: z.record(z.string()).optional().describe("Environment variables for the pane."),
      width: z.number().int().min(20).max(500).optional().describe("Pane width in columns (default 120)."),
      height: z.number().int().min(5).max(200).optional().describe("Pane height in rows (default 40)."),
    },
  },
  async ({ name, command, shell = "nu", profile = "para-agent", cwd, env, width, height }) => {
    try {
      const session = SESSION_PREFIX + sanitizeName(name);
      if (await mux.hasSession(session)) {
        return fail(new Error(`session '${session}' already exists — use it, or kill it first`));
      }

      let spawnCommand = command;
      let spawnEnv = { ...(env ?? {}) };

      if (!spawnCommand && shell === "nu") {
        const nuBin = resolveNuBin();
        const prof = getNuProfileConfig(profile, { workspaceRoot: cwd ?? WORKSPACE_ROOT });
        spawnCommand = [nuBin, ...prof.args];
        spawnEnv = { ...prof.env, ...spawnEnv };
      }

      const handle = await mux.newSession({
        session,
        cwd,
        env: spawnEnv,
        width: width ?? 120,
        height: height ?? 40,
        command: spawnCommand,
      });
      return reply({
        handle,
        session,
        shell: command ? null : shell,
        profile: command ? null : (shell === "nu" ? profile : null),
        mode: command ? "program" : "shell",
        hint: command
          ? "Program pane: use send/wait/read. `run` is not applicable — there is no shell prompt."
          : `Shell pane: use run for framed commands (dialect '${shell}').`,
      });
    } catch (err) {
      return fail(err);
    }
  }
);

server.registerTool(
  "kill",
  {
    title: "Destroy a session or pane",
    description:
      "Terminate a session (and everything in it) or a single pane. Irreversible — the process " +
      "and all its unsaved state are gone. Prefer letting a program exit on its own where that " +
      "is possible.",
    inputSchema: {
      handle: z.string().describe("Session name, or a pane target like `agent-foo:0.1`."),
      scope: z.enum(["session", "pane"]).default("session")
        .describe("`session` kills everything; `pane` kills only the addressed pane."),
    },
  },
  async ({ handle, scope }) => {
    try {
      const result = scope === "pane" ? await mux.killPane(handle) : await mux.killSession(handle);
      lastSeen.delete(handle);
      return reply({ handle, scope, ...result });
    } catch (err) {
      return fail(err);
    }
  }
);

// ---------------------------------------------------------------------------
// Driving a pane
// ---------------------------------------------------------------------------

server.registerTool(
  "send",
  {
    title: "Send input to a pane",
    description:
      "Deliver input without waiting for anything. Three modes:\n" +
      "  • `line` (default) — text followed by Enter. The usual way to answer a prompt.\n" +
      "  • `text` — literal text, no Enter. Use to type without submitting.\n" +
      "  • `keys` — tmux key names: Enter, Tab, Escape, Up, C-c, C-d, F1... Use for TUI navigation.\n\n" +
      "A newline inside `input` always submits the line before it — bracketed paste is unavailable, " +
      "so multi-line text is typed line by line. You cannot enter a literal newline without executing.\n\n" +
      "CAUTION on Windows/ConPTY: C-c is delivered to EVERY process sharing the console, not just " +
      "the foreground one. Prefer an application's own quit key over C-c when stopping a TUI.",
    inputSchema: {
      handle: z.string().describe("Pane target."),
      mode: z.enum(["line", "text", "keys"]).default("line"),
      input: z.string().optional().describe("Text for `line` / `text` mode. Multi-line text is pasted safely."),
      keys: z.array(z.string()).optional().describe("Key names for `keys` mode, e.g. [\"Escape\",\"Enter\"]."),
    },
  },
  async ({ handle, mode, input, keys }) => {
    try {
      if (mode === "keys") {
        if (!keys?.length) return fail(new Error("mode 'keys' requires a non-empty `keys` array"));
        await mux.sendKeys(handle, keys);
        return reply({ handle, mode, sent: keys });
      }
      if (input == null) return fail(new Error(`mode '${mode}' requires \`input\``));

      await mux.sendText(handle, input, { submit: mode === "line" });
      const lineCount = input.split(/\r?\n/).length;
      return reply({
        handle,
        mode,
        bytes: Buffer.byteLength(input),
        lines: lineCount,
        submitted: mode === "line",
        ...(lineCount > 1 && mode === "text"
          ? { warning: "Multi-line input in 'text' mode: every line but the last was still submitted." }
          : {}),
      });
    } catch (err) {
      return fail(err);
    }
  }
);

server.registerTool(
  "read",
  {
    title: "Read pane content",
    description:
      "Capture what a pane currently shows, as plain text with escape sequences already stripped.\n\n" +
      "`delta: true` returns only what is new since this tool last read the same pane — the cheap " +
      "way to follow a long-running agent without re-reading its whole transcript. A TUI that " +
      "redraws in place will report the whole screen as new, which is accurate rather than a bug.\n\n" +
      "`scrollback` reaches back into history for output that has scrolled off. Delta reads use a " +
      "scrollback window by default: the visible screen alone scrolls between reads, so diffing it " +
      "would report everything as new almost every time.",
    inputSchema: {
      handle: z.string().describe("Pane target."),
      delta: z.boolean().default(false).describe("Return only content new since the last read."),
      scrollback: z.number().int().min(0).max(50000).default(0)
        .describe("Lines of history to include above the visible screen."),
      tailLines: z.number().int().min(1).max(10000).optional()
        .describe("Return only the last N lines of the result."),
    },
  },
  async ({ handle, delta, scrollback, tailLines }) => {
    try {
      // A shell pane scrolls, so a visible-screen-only delta degenerates to
      // "everything is new". Diff over scrollback instead, where the transcript
      // really is append-only.
      const effectiveScrollback = delta && scrollback === 0 ? DELTA_WINDOW_LINES : scrollback;
      const screen = await mux.capture(handle, { scrollback: effectiveScrollback });
      let text = screen;
      let meta = { handle, scrollback: effectiveScrollback, mode: delta ? "delta" : "full" };

      if (delta) {
        const d = deltaOf(lastSeen.get(handle), screen);
        text = d.delta;
        meta = { ...meta, isFirstRead: d.isFirstRead, screenRewritten: Boolean(d.rewritten) };
      }
      lastSeen.set(handle, screen);

      if (tailLines) {
        const lines = text.split("\n");
        if (lines.length > tailLines) {
          text = lines.slice(-tailLines).join("\n");
          meta.truncatedTo = tailLines;
        }
      }
      meta.lines = text === "" ? 0 : text.split("\n").length;
      return reply(meta, text);
    } catch (err) {
      return fail(err);
    }
  }
);

server.registerTool(
  "wait",
  {
    title: "Wait for a pane to settle or match",
    description:
      "Block until a pane reaches a condition, then return its content.\n\n" +
      "  • `pattern` — wait for a regex to appear. Use when you know what the program prints when " +
      "it is ready (a prompt, a completion banner). Precise; prefer it when possible.\n" +
      "  • `stable` — wait until the screen stops changing. The only option for a TUI with no " +
      "completion signal. It is a HEURISTIC: an agent thinking silently looks identical to one " +
      "that has finished, and an animated spinner never settles at all.",
    inputSchema: {
      handle: z.string().describe("Pane target."),
      until: z.enum(["stable", "pattern"]).default("stable"),
      pattern: z.string().optional().describe("Regular expression, for `until: pattern`."),
      flags: z.string().default("m").describe("Regex flags, e.g. 'im'."),
      timeoutMs: z.number().int().min(500).max(600000).default(60000),
      stableForMs: z.number().int().min(100).max(60000).default(1000)
        .describe("How long the screen must be unchanged to count as settled."),
      pollMs: z.number().int().min(50).max(5000).default(250),
      scrollback: z.number().int().min(0).max(50000).default(0),
    },
  },
  async ({ handle, until, pattern, flags, timeoutMs, stableForMs, pollMs, scrollback }, extra) => {
    try {
      if (until === "pattern") {
        if (!pattern) return fail(new Error("`until: pattern` requires `pattern`"));
        const r = await waitPattern(mux, handle, {
          pattern, flags, timeoutMs, intervalMs: pollMs, scrollback, signal: extra?.signal,
        });
        const { screen, ...meta } = r;
        lastSeen.set(handle, screen);
        return reply({ handle, until, ...meta }, screen);
      }
      const r = await waitStable(mux, handle, {
        intervalMs: pollMs, stableForMs, timeoutMs, scrollback, signal: extra?.signal,
      });
      const { screen, ...meta } = r;
      lastSeen.set(handle, screen);
      return reply({ handle, until, ...meta }, screen);
    } catch (err) {
      return fail(err);
    }
  }
);

server.registerTool(
  "cancel",
  {
    title: "Stop what a pane is running",
    description:
      "Escalation ladder, least destructive first. Pick the lowest level that does the job.\n\n" +
      "  • `cooperative` — write a cancel-request file for a turn. Stops only commands that check " +
      "for it, kills nothing, and cannot corrupt anything. Requires `turn`. Try this first when the " +
      "command is one of ours and might cooperate.\n" +
      "  • `interrupt` — send C-c. Stops the pane's foreground program and returns its shell to a " +
      "prompt. Verified pane-scoped: a sibling pane and any other session are unaffected. The one " +
      "imprecision is that it reaches the shell as well as the program.\n" +
      "  • `terminate` — kill a specific descendant process by PID, leaving the shell alive and " +
      "reusable. Use `match` to name which one. This is the precise option when C-c is too blunt " +
      "or the program ignores it.\n" +
      "  • `kill` — destroy the pane outright. Everything in it is lost.\n\n" +
      "None of these are needed to abandon a `run` or `wait` you no longer care about — cancel that " +
      "request instead and the pane is left completely untouched.",
    inputSchema: {
      handle: z.string().describe("Pane target."),
      level: z.enum(["cooperative", "interrupt", "terminate", "kill"]).default("interrupt"),
      turn: z.number().int().min(1).optional().describe("For `cooperative`: which turn to request cancellation of."),
      match: z.string().optional()
        .describe("For `terminate`: case-insensitive substring of the process name, e.g. 'python'. Omit to terminate every descendant."),
      tree: z.boolean().default(false)
        .describe("For `terminate`: also kill the target's own children."),
    },
  },
  async ({ handle, level, turn, match, tree }) => {
    try {
      if (level === "cooperative") {
        if (turn == null) return fail(new Error("`cooperative` requires `turn` — find it with `log`"));
        const journal = await journalFor(handle);
        return reply({ handle, level, ...(await requestCancel(journal, turn)) });
      }
      if (level === "kill") {
        return reply({ handle, level, ...(await mux.killPane(handle)) });
      }
      if (level === "interrupt") {
        await mux.interrupt(handle);
        return reply({
          handle,
          level,
          sent: "C-c",
          scope: "this pane only; siblings and other sessions unaffected",
        });
      }

      const shellPid = Number(await mux.format(handle, "#{pane_pid}"));
      if (!Number.isFinite(shellPid)) return fail(new Error(`no such pane: ${handle}`));

      const descendants = await mux.listDescendants(shellPid);
      const targets = match
        ? descendants.filter((p) => p.name?.toLowerCase().includes(match.toLowerCase()))
        : descendants;

      if (!targets.length) {
        return reply({
          handle, level, shellPid, terminated: [],
          note: descendants.length
            ? `No descendant matched '${match}'. Running: ${descendants.map((d) => d.name).join(", ")}`
            : "The pane has no child processes — it is already sitting idle at its shell.",
        });
      }

      const results = [];
      for (const t of targets) {
        results.push({ pid: t.pid, name: t.name, ...(await mux.terminateProcess(t.pid, { tree })) });
      }
      return reply({
        handle, level, shellPid,
        terminated: results,
        shellSurvives: true,
        note: "The pane's shell was left running and is ready for the next command.",
      });
    } catch (err) {
      return fail(err);
    }
  }
);

// ---------------------------------------------------------------------------
// Command execution
// ---------------------------------------------------------------------------

server.registerTool(
  "run",
  {
    title: "Run a command in a shell pane",
    description:
      "Send a command to a SHELL pane, wait for it to finish, and return a RECEIPT — exit code, " +
      "size, timings — rather than the output itself. Output under 2KB comes back inline; anything " +
      "larger is captured to the journal and the receipt tells you how to fetch it. That is " +
      "deliberate: reading twenty turns should not cost twenty full outputs.\n\n" +
      "The command's output goes to a file, never through the terminal, so it is byte-exact — no " +
      "wrapping, no lost trailing whitespace, no scrollback ceiling, no size limit.\n\n" +
      "Shell state persists between calls: variables and the working directory set here are visible " +
      "to the next `run` on the same handle. Requires a pane at a shell prompt — for a pane running " +
      "a TUI or a bare REPL, use `send` + `wait` instead.\n\n" +
      "On timeout the command is NOT cancelled and the turn stays open; it closes itself once it " +
      "finishes, and `log` will show it.",
    inputSchema: {
      handle: z.string().describe("Pane target for a pane at a shell prompt."),
      command: z.string().describe("Command line to run, in the pane's own shell dialect."),
      shell: z.enum(CAPTURE_DIALECTS).default(DEFAULT_DIALECT),
      timeoutMs: z.number().int().min(1000).max(3600000).default(120000),
    },
  },
  async ({ handle, command, shell, timeoutMs }, extra) => {
    try {
      const journal = await journalFor(handle);
      const r = await runCaptured(mux, handle, journal, {
        command, shell, timeoutMs, origin: "run", signal: extra?.signal,
      });
      const { inline, ...meta } = r;
      return reply({ handle, command, stream: journal.stream, ...meta }, inline ?? undefined);
    } catch (err) {
      return fail(err);
    }
  }
);

server.registerTool(
  "exec",
  {
    title: "Headless one-shot command",
    description:
      "Run a command in a throwaway pane and return its output, then destroy the pane. Nothing " +
      "persists. Use this for a quick check where a durable session would be clutter.\n\n" +
      "The command still runs inside a real PTY, so programs that need a terminal behave " +
      "normally — the difference from `run` is lifecycle, not fidelity. When you need state to " +
      "carry across calls, use `spawn` + `run` instead.",
    inputSchema: {
      command: z.string().describe("Command line to run."),
      cwd: z.string().optional().describe("Working directory."),
      env: z.record(z.string()).optional().describe("Extra environment variables."),
      shell: z.enum(CAPTURE_DIALECTS).default(DEFAULT_DIALECT),
      timeoutMs: z.number().int().min(1000).max(3600000).default(120000),
      width: z.number().int().min(20).max(500).default(120),
      height: z.number().int().min(5).max(200).default(40),
      keepJournal: z.boolean().default(false)
        .describe("Keep the journal stream after the pane is destroyed, so the output stays fetchable."),
    },
  },
  async ({ command, cwd, env, shell, timeoutMs, width, height, keepJournal }, extra) => {
    const session = `${SESSION_PREFIX}exec-${Math.random().toString(36).slice(2, 10)}`;
    let created = false;
    try {
      const handle = await mux.newSession({ session, cwd, env: env ?? {}, width, height });
      created = true;
      const journal = await journalFor(handle);
      const r = await runCaptured(mux, handle, journal, {
        command, shell, timeoutMs, origin: "exec", signal: extra?.signal,
      });
      const { inline, ...meta } = r;
      return reply(
        {
          ephemeralSession: session, command,
          stream: keepJournal ? journal.stream : null,
          ...meta,
          // Be explicit: a large body from a discarded stream is unreachable.
          ...(inline == null && !keepJournal
            ? { warning: `Output was ${r.bytes} bytes — too large to inline — and this stream is discarded, so it cannot be fetched. Re-run with keepJournal: true to retain it.` }
            : {}),
        },
        inline ?? undefined
      );
    } catch (err) {
      return fail(err);
    } finally {
      if (created) await mux.killSession(session).catch(() => {});
      lastSeen.delete(`${session}:0.0`);
      if (!keepJournal) journals.delete(session);
    }
  }
);

// ---------------------------------------------------------------------------
// Journal — reading what happened, selectively
// ---------------------------------------------------------------------------

server.registerTool(
  "log",
  {
    title: "What happened in this session",
    description:
      "Read the session's journal. Two views:\n" +
      "  • `summary` (default) — one compact line per command: what ran, exit code, size, duration. " +
      "This is the cheap way to orient. Sixteen turns cost roughly 4KB regardless of how much output " +
      "they produced.\n" +
      "  • `records` — raw journal records from a cursor, for following a stream incrementally. " +
      "Pass `from` with the previous receipt's `cursor.next` to get only what is new.\n\n" +
      "Every response carries a receipt stating what was scanned, returned, and withheld, and names " +
      "the exact call that retrieves anything left out. Output bodies are never included — the " +
      "receipt lists them under `deferredBodies` with the `body` call that fetches each.",
    inputSchema: {
      handle: z.string().describe("Pane target or session name."),
      view: z.enum(["summary", "records"]).default("summary"),
      from: z.number().int().min(0).default(0).describe("Cursor: return records with seq >= this."),
      limit: z.number().int().min(1).max(500).default(50),
      kinds: z.array(z.enum(["turn", "out", "exit", "note"])).optional()
        .describe("Restrict to record kinds (records view only)."),
      match: z.string().optional().describe("Regex filter over command text, notes, and inlined output."),
    },
  },
  async ({ handle, view, from, limit, kinds, match }) => {
    try {
      const journal = await journalFor(handle);
      // Pull in anything typed directly into the pane, then close any turn that
      // finished after we stopped watching — so the log is accurate without the
      // supervisor having to remember to reap or drain.
      const ingested = await journal.ingestInbox();
      const settled = await finalizeOpenTurns(journal);

      if (view === "summary") {
        const { receipt, turns } = await journal.summary();
        return reply({
          ...receipt,
          ...(ingested.length ? { ingestedFromPane: ingested.length } : {}),
          ...(settled.length ? { settledOnRead: settled } : {}),
          turns: dedupeTurns(turns),
        });
      }
      const { receipt, records } = await journal.read({ from, limit, kinds, match });
      return reply({
        ...receipt,
        ...(ingested.length ? { ingestedFromPane: ingested.length } : {}),
        ...(settled.length ? { settledOnRead: settled } : {}),
        records,
      });
    } catch (err) {
      return fail(err);
    }
  }
);

server.registerTool(
  "body",
  {
    title: "Fetch one command's output",
    description:
      "Retrieve the output of a single turn, selectively. This is the only tool that returns bulk " +
      "text, so reach for it deliberately.\n\n" +
      "  • `grep` returns just the matching lines, with optional surrounding context — usually what " +
      "you actually want from a large log.\n" +
      "  • `offsetLines` / `limitLines` page through it.\n\n" +
      "The receipt always states the body's true total line count and exactly how many lines were " +
      "not returned, so a slice can never be mistaken for the whole thing.",
    inputSchema: {
      handle: z.string().describe("Pane target or session name."),
      turn: z.number().int().min(1).describe("Turn number, from `log`."),
      grep: z.string().optional().describe("Return only lines matching this regex."),
      context: z.number().int().min(0).max(20).default(0).describe("Lines of context around each grep hit."),
      offsetLines: z.number().int().min(0).default(0),
      limitLines: z.number().int().min(1).max(5000).default(200),
    },
  },
  async ({ handle, turn, grep, context, offsetLines, limitLines }) => {
    try {
      const journal = await journalFor(handle);
      await journal.ingestInbox();
      await finalizeOpenTurns(journal);
      const { receipt, text } = await journal.body(turn, { grep, context, offsetLines, limitLines });
      return reply(receipt, text);
    } catch (err) {
      return fail(err);
    }
  }
);

server.registerTool(
  "find",
  {
    title: "Search across everything this session has run",
    description:
      "Search the output of every turn at once and return matching LINES, never bodies. Use this " +
      "instead of fetching several bodies and reading them — it is the difference between a few " +
      "hundred tokens and tens of thousands.\n\n" +
      "Per-turn and total hit caps keep the result bounded; both are reported in the receipt along " +
      "with the call that retrieves what they excluded.",
    inputSchema: {
      handle: z.string().describe("Pane target or session name."),
      pattern: z.string().describe("Regular expression to search for."),
      flags: z.string().default("i"),
      from: z.number().int().min(0).default(0).describe("Only search turns at or after this seq."),
      maxHits: z.number().int().min(1).max(500).default(50),
      maxPerTurn: z.number().int().min(1).max(100).default(5),
      context: z.number().int().min(0).max(10).default(0),
    },
  },
  async ({ handle, pattern, flags, from, maxHits, maxPerTurn, context }) => {
    try {
      const journal = await journalFor(handle);
      await journal.ingestInbox();
      await finalizeOpenTurns(journal);
      const { receipt, hits } = await journal.search({ pattern, flags, from, maxHits, maxPerTurn, context });
      return reply({ ...receipt, hits });
    } catch (err) {
      return fail(err);
    }
  }
);

// ---------------------------------------------------------------------------
// Mediated dialogue and exchange scrutiny
// ---------------------------------------------------------------------------

server.registerTool(
  "quarantine_status",
  {
    title: "Inspect conversation quarantine status",
    description:
      "Read the process gate and durable recovery evidence for one exact application/handle lane. " +
      "This operation is strictly read-only: it cannot clear quarantine, acquire a writer lease, " +
      "or create a transcript.",
    inputSchema: {
      application: canonicalIdentityInput("application")
        .describe("Canonical adapter application id, such as 'claude'."),
      handle: canonicalIdentityInput("handle")
        .describe("Logical receiver seat or exclusive target handle."),
    },
  },
  async ({ application, handle }) => {
    let store = null;
    try {
      const conversationKey = deriveConversationKey({ application, handle });
      const gate = conversationGate.status(conversationKey);
      store = await readOnlyTranscriptFor(handle);
      const header = await store.readHeader();
      const durableNotices = store.getRecoveryNotices().filter(
        (notice) => notice.conversation_key === conversationKey,
      );
      const blocked = gate.active || gate.quarantined !== null || durableNotices.length > 0;
      return reply({
        found: header !== null || gate.active || gate.quarantined !== null,
        blocked,
        gate,
        durable_notices: durableNotices,
      });
    } catch (err) {
      return fail(err);
    } finally {
      await store?.close();
    }
  },
);

server.registerTool(
  "delegate",
  {
    title: "Delegate one evidence-backed agent turn",
    description:
      "Send one exact UTF-8 prompt through a verified structured-stream application adapter. " +
      "This is the only operation that creates a mediated exchange. Completion requires a " +
      "correlated receiver-native terminal event and durable transcript commit; console " +
      "send/wait/read activity is never inferred into this ledger. Non-completed turns return " +
      "an MCP error with a durable receipt and no fabricated reply.",
    inputSchema: {
      handle: canonicalIdentityInput("handle")
        .describe("Logical receiver seat or exclusive target handle; serialized per application and handle."),
      application: canonicalIdentityInput("application")
        .describe("Verified adapter application id, such as 'claude'. Unverified profiles fail closed."),
      prompt: z.string()
        .describe("One exact well-formed Unicode prompt. Control arguments do not belong in this string."),
      timeoutMs: z.number().int().min(500).max(3600000).optional()
        .describe("Native turn deadline in milliseconds. Timeout does not imply native stop unless confirmed."),
    },
  },
  async ({ handle, application, prompt, timeoutMs }, extra) => {
    try {
      const result = await mediatedTurnService.delegate({
        handle,
        application,
        prompt,
        timeoutMs,
        signal: extra?.signal,
        ...(extra?.requestId !== undefined ? { requestId: String(extra.requestId) } : {}),
      });
      return reply(result);
    } catch (err) {
      if (err instanceof MediatedTurnError || err?.receipt || err?.code) return failMediated(err);
      return failMediated(new MediatedTurnError("MEDIATED_TURN_FAILED", String(err?.message ?? err)));
    }
  }
);

server.registerTool(
  "scrutinize",
  {
    title: "Inspect exchange details (Progressive Disclosure)",
    description:
      "Inspect the internal execution trace (thinking, tool calls, and responses) of a completed exchange. " +
      "Provides progressive disclosure without cluttering the primary agent context upfront.",
    inputSchema: {
      handle: canonicalIdentityInput("handle").describe("Pane target or session name."),
      xid: z.string().optional().describe("Specific exchange ID (_xid) to scrutinize. If omitted, returns exchange summaries."),
      filter: z.enum(["all", "thinking", "tools", "failures", "summary"]).default("summary")
        .describe("Filter internal exchange records: 'summary', 'tools', 'thinking', 'failures', or 'all'."),
      step: z.number().int().min(0).optional().describe("Inspect a single specific 0-based step index."),
    },
  },
  async ({ handle, xid, filter = "summary", step }) => {
    let store = null;
    try {
      store = await readOnlyTranscriptFor(handle);
      if (!xid) {
        const [header, summaries] = await Promise.all([
          store.readHeader(),
          store.select({ kind: "summary" }),
        ]);
        return reply({
          session: sessionOf(handle),
          found: header !== null,
          exchanges: summaries,
        });
      }

      const exchange = await store.select({ kind: "exchange", exchangeId: xid });
      if (!exchange) return reply({ xid, found: false, record: null, records: [] });

      if (step !== undefined) {
        const stepRecord = await store.select({ kind: "step", exchangeId: xid, step });
        return reply({
          xid,
          found: true,
          step,
          record: stepRecord,
          trace: exchange.trace,
        });
      }

      let records;
      switch (filter) {
        case "tools":
          records = (await store.select({ kind: "records", exchangeId: xid }))
            .filter((record) => record._type === "tool_call" || record._type === "tool_result");
          break;
        case "thinking":
          records = await store.select({ kind: "records", exchangeId: xid, recordKind: "thinking" });
          break;
        case "failures":
          records = (await store.select({ kind: "records", exchangeId: xid }))
            .filter((record) => ["tool_call", "tool_result"].includes(record._type) && record.status !== "completed");
          break;
        case "summary":
          records = (await store.select({ kind: "records", exchangeId: xid })).map((record, index) => ({
            step: index,
            type: record._type,
            name: record.tool_name ?? record.phase,
            observed_at: record.observed_at,
            source: record.source ?? record.source_ref,
          }));
          break;
        case "all":
        default:
          records = await store.select({ kind: "records", exchangeId: xid });
          break;
      }

      return reply({
        xid,
        found: true,
        filter,
        status: exchange.status,
        application: exchange.application,
        model: exchange.model,
        native: exchange.native,
        trace: exchange.trace,
        delivery: exchange.delivery,
        count: records.length,
        records,
      });
    } catch (err) {
      return fail(err);
    } finally {
      await store?.close();
    }
  }
);

/** Name repeats instead of restating them — identical output is common in loops. */
function dedupeTurns(turns) {
  const seen = new Map();
  return turns.map((t) => {
    if (!t.out_hash) return t;
    if (seen.has(t.out_hash)) {
      const { out_hash, ...rest } = t;
      return { ...rest, sameOutputAsTurn: seen.get(out_hash) };
    }
    seen.set(t.out_hash, t.turn);
    return t;
  });
}

import fs from "node:fs/promises";
import { existsSync } from "node:fs";

const SKILLS_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "skills");

export async function registerNativeSkills(server) {
  if (!existsSync(SKILLS_DIR)) return;

  const skillDirs = await fs.readdir(SKILLS_DIR, { withFileTypes: true });

  for (const dir of skillDirs) {
    if (!dir.isDirectory()) continue;
    const skillName = dir.name;
    const skillRoot = path.join(SKILLS_DIR, skillName);
    const mainSkillPath = path.join(skillRoot, "SKILL.md");

    if (!existsSync(mainSkillPath)) continue;

    const mainContent = await fs.readFile(mainSkillPath, "utf8");
    const descMatch = mainContent.match(/description:\s*(.+)/i);
    const description = descMatch ? descMatch[1].trim() : `Skill primer for ${skillName}`;

    // 1. Register main skill index resource (skill://para-agent/{skillName})
    server.resource(
      `skill-${skillName}`,
      `skill://para-agent/${skillName}`,
      async (uri) => ({
        contents: [{ uri: uri.href, text: mainContent }],
      })
    );

    // 2. Register main skill prompt (slash command)
    server.prompt(
      `skill-${skillName}`,
      { description },
      async () => ({
        messages: [{ role: "user", content: { type: "text", text: mainContent } }],
      })
    );

    // 3. Scan references/ sub-directory for progressive topic disclosure
    const refsDir = path.join(skillRoot, "references");
    if (existsSync(refsDir)) {
      const refFiles = await fs.readdir(refsDir, { withFileTypes: true });
      for (const file of refFiles) {
        if (!file.isFile() || !file.name.endsWith(".md")) continue;
        const topicName = file.name.replace(/\.md$/, "");
        const topicPath = path.join(refsDir, file.name);
        const topicContent = await fs.readFile(topicPath, "utf8");

        server.resource(
          `skill-${skillName}-${topicName}`,
          `skill://para-agent/${skillName}/${topicName}`,
          async (uri) => ({
            contents: [{ uri: uri.href, text: topicContent }],
          })
        );
      }
    }
  }

  // 4. Register unified 'skills' MCP Tool with topic support
  server.registerTool(
    "skills",
    {
      title: "Query or fetch agent skills",
      description:
        "Enumerate available MCP skills or fetch a specific skill primer / sub-topic " +
        "(e.g., name: 'nu', topic: 'pipelines') for progressive disclosure context guidance.",
      inputSchema: {
        name: z.string().optional().describe("Name of the skill (e.g. 'nu'). Omit to list available skills."),
        topic: z.string().optional().describe("Sub-topic or reference file (e.g. 'pipelines', 'parity', 'posix-cheatsheet')."),
      },
    },
    async ({ name, topic }) => {
      try {
        if (!name) {
          const dirs = await fs.readdir(SKILLS_DIR, { withFileTypes: true });
          const skillsList = [];
          for (const d of dirs) {
            if (!d.isDirectory()) continue;
            const sPath = path.join(SKILLS_DIR, d.name, "SKILL.md");
            if (existsSync(sPath)) {
              const txt = await fs.readFile(sPath, "utf8");
              const m = txt.match(/description:\s*(.+)/i);
              const rDir = path.join(SKILLS_DIR, d.name, "references");
              const topics = existsSync(rDir)
                ? (await fs.readdir(rDir)).filter((f) => f.endsWith(".md")).map((f) => f.replace(/\.md$/, ""))
                : [];
              skillsList.push({
                name: d.name,
                description: m ? m[1].trim() : `Skill ${d.name}`,
                uri: `skill://para-agent/${d.name}`,
                topics,
              });
            }
          }
          return reply({ availableSkills: skillsList });
        }

        const targetPath = topic
          ? path.join(SKILLS_DIR, name, "references", `${topic}.md`)
          : path.join(SKILLS_DIR, name, "SKILL.md");

        if (!existsSync(targetPath)) {
          return fail(new Error(`skill topic '${name}/${topic ?? "index"}' not found at '${targetPath}'`));
        }

        const content = await fs.readFile(targetPath, "utf8");
        const uri = topic ? `skill://para-agent/${name}/${topic}` : `skill://para-agent/${name}`;
        return reply({ skill: name, topic: topic ?? "index", uri }, content);
      } catch (err) {
        return fail(err);
      }
    }
  );
}

// ---------------------------------------------------------------------------

export async function main() {
  // Fail loudly at startup rather than on the first tool call.
  await adapterEngine.init();
  const version = await mux.version().catch(() => null);
  if (!version) {
    process.stderr.write(
      `para-agent: could not run multiplexer binary '${mux.bin}'.\n` +
      `Set PARA_MUX_BIN to its absolute path.\n`
    );
    process.exit(1);
  }
  process.stderr.write(`para-agent: ${version.split("\n").pop()} | namespace '${mux.namespace}' | ${mux.bin}\n`);

  await registerNativeSkills(server);
  await server.connect(new StdioServerTransport());
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch((err) => {
    process.stderr.write(`para-agent: fatal: ${err?.stack ?? err}\n`);
    process.exit(1);
  });
}
