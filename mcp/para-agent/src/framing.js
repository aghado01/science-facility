/**
 * Turning a pane into something an agent can reason about.
 *
 * Two problems, two strategies:
 *
 *   Line-oriented panes (a shell prompt). We bracket the command with unique
 *   markers and poll for the closing one, then slice the transcript between
 *   them. See runFramed().
 *
 *   Full-screen panes (a TUI agent). There is no completion signal at all, and
 *   on ConPTY we cannot even reliably detect that we are on the alternate
 *   screen. The only honest primitive is "the screen stopped changing".
 *   See waitStable().
 *
 * Two measured facts about psmux 3.3.7 shape this file:
 *
 *   `send-keys -l` is byte-exact. Double quotes, backslashes, `$`, braces and
 *   backticks all arrive intact, so nothing here needs to escape for transport.
 *
 *   `wait-for` never blocks, so completion cannot be an event. Polling for the
 *   end marker costs roughly 100-900ms of detection latency on top of the
 *   command's own runtime.
 */

import { randomBytes } from "node:crypto";

/**
 * Sleep that wakes early if `signal` aborts.
 *
 * Aborting only ends OUR observation of the pane. It never touches the pane,
 * and the command inside keeps running — that separation is the point: the
 * supervisor can abandon a wait it no longer cares about without disturbing
 * the agent it is supervising. Use the `cancel` tool to affect the pane itself.
 */
const sleep = (ms, signal) =>
  new Promise((resolve) => {
    if (signal?.aborted) return resolve();
    const t = setTimeout(resolve, ms);
    signal?.addEventListener("abort", () => { clearTimeout(t); resolve(); }, { once: true });
  });

/**
 * Shell dialects for command framing.
 *
 * The caller's command is base64-encoded before it is embedded. Transport is
 * already lossless, so this is not about escaping — it is about isolation. An
 * encoded payload cannot contain a brace, a quote or a newline that would
 * terminate the wrapper's own try/finally early, so no command the supervisor
 * writes can break the frame around it.
 *
 * Two further constraints on every template:
 *   1. The joined marker literal must NOT appear in the line as typed, or the
 *      echoed input matches before any output exists. Hence the concatenation:
 *      the pane echoes `'PARA'+'B1a2b'` but prints `PARAB1a2b`.
 *   2. Markers must be printed on their own line, so pane wrapping can never
 *      split one across a row boundary.
 */
export const DIALECTS = {
  pwsh: {
    label: "PowerShell 7+ / Windows PowerShell",
    encode: (command) => Buffer.from(command, "utf8").toString("base64"),
    compose({ payload, begin, end, nonce }) {
      return (
        `Write-Host ('${begin.head}'+'${begin.tail}'); ` +
        `try { Invoke-Expression ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('${payload}'))) } ` +
        `catch { Write-Host ('PARA-ERR: ' + $_.Exception.Message) } ` +
        // $LASTEXITCODE is null until some native command has run; report that
        // as 'none' rather than coercing a fresh pane's first command to 0.
        `finally { $__paEc = $(if ($null -eq $LASTEXITCODE) { 'none' } else { $LASTEXITCODE }); ` +
        `Write-Host ('${end.head}'+'${end.tail}'+' ec=' + $__paEc) }`
      );
    },
  },
  bash: {
    label: "bash / sh / zsh",
    encode: (command) => Buffer.from(command, "utf8").toString("base64"),
    compose({ payload, begin, end }) {
      return (
        `echo ${begin.head}''${begin.tail}; ` +
        `eval "$(printf %s '${payload}' | base64 --decode)"; ` +
        `__pa_e=$?; ` +
        `echo ${end.head}''${end.tail} ec=$__pa_e`
      );
    },
  },
};

export const DEFAULT_DIALECT = process.platform === "win32" ? "pwsh" : "bash";

function makeMarkers() {
  const nonce = randomBytes(4).toString("hex");
  return {
    nonce,
    begin: { head: "PARA", tail: `B${nonce}`, literal: `PARAB${nonce}` },
    end: { head: "PARA", tail: `E${nonce}`, literal: `PARAE${nonce}` },
  };
}

/**
 * Run a command in an existing shell pane and return only that command's
 * output, plus its exit code.
 *
 * On timeout the command is NOT cancelled — it keeps running in the pane. The
 * result says so rather than presenting a partial snapshot as the answer.
 */
export async function runFramed(
  mux,
  target,
  { command, shell = DEFAULT_DIALECT, timeoutMs = 120000, scrollback = 5000, pollMs = 100, signal } = {}
) {
  const dialect = DIALECTS[shell];
  if (!dialect) {
    throw new Error(
      `unknown shell dialect '${shell}'; expected one of ${Object.keys(DIALECTS).join(", ")}`
    );
  }

  const { nonce, begin, end } = makeMarkers();
  const line = dialect.compose({
    payload: dialect.encode(command),
    begin,
    end,
    nonce,
  });

  const startedAt = Date.now();
  await mux.sendLiteral(target, line);
  await mux.sendKeys(target, ["Enter"]);

  // Poll the visible screen only — the end marker is the last thing printed,
  // so it cannot have scrolled away while we are the only writer.
  let complete = false;
  let died = false;
  let cancelled = false;
  while (Date.now() - startedAt < timeoutMs) {
    await sleep(pollMs, signal);
    if (signal?.aborted) {
      cancelled = true;
      break;
    }
    let visible;
    try {
      visible = await mux.capture(target, { scrollback: 0 });
    } catch {
      died = true;
      break;
    }
    if (visible.includes(end.literal)) {
      complete = true;
      break;
    }
    if (await mux.isDead(target)) {
      died = true;
      break;
    }
  }

  const elapsedMs = Date.now() - startedAt;
  // Let the final marker line settle into the buffer before the full capture.
  if (complete) await sleep(50);

  const screen = await mux.capture(target, { scrollback }).catch(() => "");
  const sliced = sliceBetween(screen, begin.literal, end.literal);

  return {
    output: sliced.output,
    exitCode: sliced.exitCode,
    complete: complete && sliced.framed,
    timedOut: !complete && !died && !cancelled,
    paneDied: died,
    cancelled,
    elapsedMs,
    note: buildNote({ complete, died, cancelled, sliced, scrollback }),
  };
}

function buildNote({ complete, died, cancelled, sliced, scrollback }) {
  if (died) return "The pane's process exited while the command was running. Output is whatever was captured before it died.";
  if (cancelled) {
    return (
      "Observation cancelled. The command was NOT stopped — it is still running in the pane. " +
      "Output below is a partial snapshot. Use the `cancel` tool if you meant to stop the command itself."
    );
  }
  if (!complete) {
    return (
      "Timed out. The command is STILL RUNNING in the pane — it was not cancelled. " +
      "Output below is a partial snapshot. Use `read` or `wait` to follow it, or `send` the " +
      "application's own quit key to stop it."
    );
  }
  if (!sliced.framed) {
    return (
      `Completed, but the opening marker was not found within ${scrollback} lines of scrollback. ` +
      "Output was longer than that, or the command cleared the screen. Retry with a larger " +
      "`scrollback` to recover the full transcript."
    );
  }
  return undefined;
}

/** Extract the text between the begin and end markers of the most recent run. */
function sliceBetween(screen, beginLiteral, endLiteral) {
  const b = screen.lastIndexOf(beginLiteral);
  if (b === -1) {
    // No opening marker: fall back to whatever precedes the closing one.
    const e = screen.lastIndexOf(endLiteral);
    if (e === -1) return { output: tail(screen, 200), exitCode: null, framed: false };
    return { output: tail(screen.slice(0, e), 200), exitCode: parseExit(screen, e), framed: false };
  }

  const afterBegin = b + beginLiteral.length;
  const e = screen.indexOf(endLiteral, afterBegin);
  if (e === -1) {
    return { output: trimEdges(screen.slice(afterBegin)), exitCode: null, framed: false };
  }
  return {
    output: trimEdges(screen.slice(afterBegin, e)),
    exitCode: parseExit(screen, e),
    framed: true,
  };
}

/** Read `ec=N` off the end-marker line. 'none' means the shell had no exit code to report. */
function parseExit(screen, endIndex) {
  const nl = screen.indexOf("\n", endIndex);
  const endLine = nl === -1 ? screen.slice(endIndex) : screen.slice(endIndex, nl);
  const m = endLine.match(/ec=(-?\d+|none|)\s*$/);
  if (!m || m[1] === "" || m[1] === "none") return null;
  return Number(m[1]);
}

const trimEdges = (s) => s.replace(/^\r?\n/, "").replace(/\r?\n\s*$/, "");

function tail(text, lines) {
  const arr = text.split("\n");
  return arr.slice(Math.max(0, arr.length - lines)).join("\n");
}

/**
 * Wait until the pane stops changing.
 *
 * The only completion signal available for a full-screen TUI, and a heuristic:
 * an agent thinking silently looks identical to one that has finished, and an
 * animated spinner never settles at all. `stableForMs` trades false positives
 * against latency.
 */
export async function waitStable(
  mux,
  target,
  { intervalMs = 250, stableForMs = 1000, timeoutMs = 60000, scrollback = 0, signal } = {}
) {
  const startedAt = Date.now();
  let previous = null;
  let unchangedSince = null;

  while (Date.now() - startedAt < timeoutMs) {
    if (signal?.aborted) break;
    const screen = await mux.capture(target, { scrollback });
    const now = Date.now();
    if (screen === previous) {
      unchangedSince ??= now;
      if (now - unchangedSince >= stableForMs) {
        return { stable: true, timedOut: false, cancelled: false, waitedMs: now - startedAt, screen };
      }
    } else {
      previous = screen;
      unchangedSince = null;
    }
    await sleep(intervalMs, signal);
  }

  const cancelled = Boolean(signal?.aborted);
  return {
    stable: false,
    timedOut: !cancelled,
    cancelled,
    waitedMs: Date.now() - startedAt,
    screen: previous ?? (await mux.capture(target, { scrollback })),
    note: cancelled
      ? "Observation cancelled. The pane was not touched and whatever was running still is."
      : "Pane never settled. It may be animating (spinner, progress bar) or still producing output.",
  };
}

/** Wait until pane content matches a regular expression. */
export async function waitPattern(
  mux,
  target,
  { pattern, flags = "", intervalMs = 250, timeoutMs = 60000, scrollback = 0, signal } = {}
) {
  const re = new RegExp(pattern, flags);
  const startedAt = Date.now();

  while (Date.now() - startedAt < timeoutMs) {
    if (signal?.aborted) break;
    const screen = await mux.capture(target, { scrollback });
    const match = screen.match(re);
    if (match) {
      return {
        matched: true,
        timedOut: false,
        cancelled: false,
        match: match[0],
        groups: match.slice(1),
        waitedMs: Date.now() - startedAt,
        screen,
      };
    }
    await sleep(intervalMs, signal);
  }

  const cancelled = Boolean(signal?.aborted);
  return {
    matched: false,
    timedOut: !cancelled,
    cancelled,
    waitedMs: Date.now() - startedAt,
    screen: await mux.capture(target, { scrollback }),
    ...(cancelled
      ? { note: "Observation cancelled. The pane was not touched and whatever was running still is." }
      : {}),
  };
}

/**
 * Return only the content that is new since the previous read of this target.
 *
 * A plain prefix diff is not enough. `capture-pane -S -N` is anchored to the
 * pane's current bottom, so the window slides down as output arrives and the
 * new capture almost never starts with the old one. Instead we anchor on the
 * tail of the previous read and return whatever follows it, which survives the
 * window sliding by an arbitrary number of lines.
 *
 * A TUI that redraws in place has no stable anchor and reports `rewritten` —
 * accurate rather than a bug, since on a redraw nothing is genuinely "new".
 */
export function deltaOf(previous, current) {
  if (previous == null) return { delta: stripTrailingBlanks(current), isFirstRead: true };
  if (current === previous) return { delta: "", isFirstRead: false };

  // Cheap path: the window did not slide.
  if (current.startsWith(previous)) {
    return { delta: stripTrailingBlanks(current.slice(previous.length)), isFirstRead: false };
  }

  // Sliding path: find the previous read's tail inside the current capture.
  const prevLines = previous.split("\n");
  let end = prevLines.length;
  while (end > 0 && prevLines[end - 1].trim() === "") end--; // ignore pane padding

  for (const k of [24, 12, 6, 3, 2]) {
    const start = Math.max(0, end - k);
    if (end - start < 2) continue;
    const anchor = prevLines.slice(start, end).join("\n");
    if (!anchor.trim()) continue;
    const idx = current.lastIndexOf(anchor);
    if (idx !== -1) {
      return {
        delta: stripTrailingBlanks(current.slice(idx + anchor.length).replace(/^\r?\n/, "")),
        isFirstRead: false,
        anchorLines: k,
      };
    }
  }

  return { delta: stripTrailingBlanks(current), isFirstRead: false, rewritten: true };
}

const stripTrailingBlanks = (s) => s.replace(/(\r?\n\s*)+$/, "");
