/**
 * File-mediated command capture.
 *
 * The pane is no longer the data path. A captured command tees its output to a
 * file and drops a `.done` sentinel when it finishes, so:
 *
 *   - the body is byte-exact — no wrapping, no width truncation, no lost
 *     trailing whitespace, no scrollback ceiling, no size limit
 *   - completion is a file appearing, so detection costs an existsSync rather
 *     than a psmux round trip
 *   - exit codes are read from the sentinel instead of smuggled out through an
 *     echoed marker line
 *
 * The pane still shows everything, because the tee passes output through. It is
 * just for human eyes now.
 *
 * What `run` returns by default is a *receipt*, not the output. A supervisor
 * reading twenty turns should pay for twenty one-line descriptions, and reach
 * for a body only when it decides it wants one.
 */

import fs from "node:fs/promises";
import { existsSync, watch } from "node:fs";
import path from "node:path";

const sleep = (ms, signal) =>
  new Promise((resolve) => {
    if (signal?.aborted) return resolve();
    const t = setTimeout(resolve, ms);
    signal?.addEventListener("abort", () => { clearTimeout(t); resolve(); }, { once: true });
  });

const psPath = (p) => `'${p.replace(/'/g, "''")}'`;

/**
 * Last known working directory per pane.
 *
 * Asking psmux for `#{pane_current_path}` before every dispatch cost ~101ms —
 * the single largest slice of per-command latency. Instead we pay it once per
 * pane and then keep it current from each turn's own sentinel, which reports
 * the cwd it finished in. That is also the cwd the next command dispatches
 * from, so a command that changes directory self-corrects the cache.
 */
const cwdCache = new Map();

/**
 * Wait for the sentinel file to appear.
 *
 * fs.watch fires ~11ms after the write versus ~35ms for a 50ms poll, but it
 * silently misses events on some filesystems, so a poll runs alongside it as a
 * floor rather than as the primary mechanism.
 *
 * Pane-death is checked on a much slower cadence deliberately: it is a psmux
 * round trip at ~58ms, and checking it every poll turned the wait loop into a
 * spawn-per-25ms treadmill that cost more than the command being watched.
 */
async function awaitSentinel(donePath, { timeoutMs, signal, pollMs = 25, deadCheckMs = 2000, isDead }) {
  if (existsSync(donePath)) return "completed";

  const dir = path.dirname(donePath);
  const base = path.basename(donePath);
  const startedAt = Date.now();

  let watcher = null;
  let hit = false;
  const onHit = () => { hit = true; };
  try {
    watcher = watch(dir, (_event, filename) => {
      if (!filename || filename === base) { if (existsSync(donePath)) onHit(); }
    });
  } catch {
    // Watching is an accelerator, never a requirement.
  }

  try {
    let lastDeadCheck = Date.now();
    while (Date.now() - startedAt < timeoutMs) {
      await sleep(pollMs, signal);
      if (signal?.aborted) return "cancelled";
      if (hit || existsSync(donePath)) return "completed";
      if (Date.now() - lastDeadCheck >= deadCheckMs) {
        lastDeadCheck = Date.now();
        if (await isDead()) {
          // The sentinel may have landed in the same window the pane died.
          return existsSync(donePath) ? "completed" : "died";
        }
      }
    }
    return "timeout";
  } finally {
    try { watcher?.close(); } catch { /* already closed */ }
  }
}

/**
 * Wrapper dialects.
 *
 * The wrapper lives in a FILE and the pane is only asked to dot-source it.
 * That matters far more than it looks: typing the wrapper inline cost ~390ms
 * for a command the shell then executed in 5ms, because PSReadLine re-renders
 * and re-highlights the whole input line on every keystroke, so latency scaled
 * with wrapper length. Writing the wrapper to disk (sub-millisecond) and typing
 * ~60 characters instead of ~450 removes almost all of it.
 *
 * The command is still base64-encoded inside the file. Not for escaping —
 * send-keys is byte-exact and a file needs no quoting at all — but for
 * isolation: an encoded payload cannot contain a brace that closes the
 * wrapper's own try/finally early.
 *
 * Dot-sourcing is load-bearing in both places. `& scriptblock` would run the
 * caller's command in a child scope, so `$x = 1` or `cd` would not survive to
 * the next turn; `.` runs it in the pane's own scope, which is what makes a
 * persistent session persistent.
 *
 * `finally` writes the sentinel unconditionally, so a command that throws
 * still reports rather than reading as a hang.
 */
const DIALECTS = {
  nu: {
    ext: "nu",
    invoke: (scriptPath) => `source '${scriptPath}'`,
    script: ({ payload, outPath, donePath }) =>
      `let __para_s = (date now)\n` +
      `let __para_payload = ('${payload}' | decode base64 | decode utf-8)\n` +
      `let __pa_f = ($env.TEMP? | default '/tmp' | path join $'para_exec_($__para_s | into int).nu')\n` +
      `$__para_payload | save -f $__pa_f\n` +
      `let __para_res = (try { source $__pa_f; { code: ($env.LAST_EXIT_CODE? | default 0), ok: true } } catch { |err| { code: 1, ok: false, err: $err.msg } })\n` +
      `rm -f $__pa_f\n` +
      `let __para_dur = (((date now) - __para_s) / 1ms | into int)\n` +
      `{\n` +
      `    code: $__para_res.code,\n` +
      `    ok: $__para_res.ok,\n` +
      `    cwd: (pwd),\n` +
      `    duration_ms: __para_dur,\n` +
      `    outcome: 'completed'\n` +
      `} | to json -c | save -f '${donePath}'\n`,
  },

  pwsh: {
    ext: "ps1",
    invoke: (scriptPath) => `. ${psPath(scriptPath)}`,
    script: ({ payload, outPath, donePath }) =>
      // $LASTEXITCODE persists across commands, so a cmdlet that runs no native
      // process would otherwise inherit the previous turn's code and report it
      // as its own. Clearing it means null genuinely means "no exit code".
      `$global:LASTEXITCODE = $null\n` +
      `$__paraS = Get-Date\n` +
      `$__paraOk = $true\n` +
      `$__paraC = $null\n` +
      `try {\n` +
      `    . ([scriptblock]::Create([Text.Encoding]::UTF8.GetString(` +
      `[Convert]::FromBase64String('${payload}')))) *>&1 |\n` +
      `        Out-String -Stream | Tee-Object -FilePath ${psPath(outPath)} -Encoding utf8\n` +
      `    $__paraOk = $?\n` +
      `    $__paraC = $LASTEXITCODE\n` +
      `} catch {\n` +
      `    $__paraOk = $false\n` +
      `    $_.Exception.Message | Tee-Object -FilePath ${psPath(outPath)} -Append -Encoding utf8\n` +
      `} finally {\n` +
      // cwd rides along in the sentinel so no separate psmux query is needed
      // before the next dispatch.
      `    [IO.File]::WriteAllText(${psPath(donePath)}, (@{\n` +
      `        code = $__paraC\n` +
      `        ok = $__paraOk\n` +
      `        cwd = (Get-Location).Path\n` +
      `        duration_ms = [int]((Get-Date) - $__paraS).TotalMilliseconds\n` +
      `        outcome = 'completed'\n` +
      `    } | ConvertTo-Json -Compress))\n` +
      `}\n`,
  },

  bash: {
    ext: "sh",
    invoke: (scriptPath) => `. '${scriptPath}'`,
    // NOTE: piping into tee runs the command in a subshell, so unlike the pwsh
    // path, shell state does NOT survive between turns here. Documented rather
    // than silently differing.
    script: ({ payload, outPath, donePath }) =>
      `__para_s=$(date +%s%3N)\n` +
      `{ eval "$(printf %s '${payload}' | base64 --decode)"; } 2>&1 | tee '${outPath}'\n` +
      `__para_c=\${PIPESTATUS[0]}\n` +
      `printf '{"code":%s,"ok":%s,"cwd":"%s","duration_ms":%s,"outcome":"completed"}' ` +
      `"$__para_c" "$([ "$__para_c" -eq 0 ] && echo true || echo false)" "$PWD" ` +
      `"$(( $(date +%s%3N) - __para_s ))" > '${donePath}'\n`,
  },
};

export const CAPTURE_DIALECTS = Object.keys(DIALECTS);

/**
 * Run a command in a shell pane, capturing it to the journal.
 *
 * Resolves as soon as the sentinel appears. On timeout the turn is deliberately
 * left OPEN rather than closed with a fabricated exit — the command is still
 * running, and `finalizeOpenTurns` will close it correctly whenever it finishes.
 */
export async function runCaptured(
  mux,
  target,
  journal,
  { command, shell = "pwsh", timeoutMs = 120000, origin = "run", pollMs = 25, signal } = {}
) {
  const dialect = DIALECTS[shell];
  if (!dialect) {
    throw new Error(`unknown capture dialect '${shell}'; expected one of ${CAPTURE_DIALECTS.join(", ")}`);
  }

  const cacheKey = `${mux.namespace}/${target}`;
  let cwd = cwdCache.get(cacheKey);
  if (cwd === undefined) {
    // Paid once per pane, then kept current from each sentinel.
    cwd = await mux.format(target, "#{pane_current_path}").catch(() => null);
    cwdCache.set(cacheKey, cwd);
  }

  const { turn, seq, outPath, donePath, cancelPath } = await journal.openTurn({
    cmd: command, cwd, shell, origin,
  });

  const payload = Buffer.from(command, "utf8").toString("base64");
  const scriptPath = journal.turnPath(turn, dialect.ext);
  await fs.writeFile(scriptPath, dialect.script({ payload, outPath, donePath }), "utf8");

  const startedAt = Date.now();
  // One psmux invocation, and a short line — both matter, see DIALECTS.
  await mux.sendLine(target, dialect.invoke(scriptPath));
  const dispatchedAt = Date.now();

  const outcome = await awaitSentinel(donePath, {
    timeoutMs,
    signal,
    pollMs,
    isDead: () => mux.isDead(target),
  });
  const settledAt = Date.now();
  const elapsedMs = settledAt - startedAt;

  if (outcome === "completed") {
    let done = {};
    try {
      done = JSON.parse(await fs.readFile(donePath, "utf8"));
    } catch {
      await journal.note("sentinel present but unreadable", { turn });
    }
    if (done.cwd) cwdCache.set(cacheKey, done.cwd);

    const out = await journal.recordOutput({ turn, bodyPath: outPath });
    await journal.recordExit({
      turn,
      code: done.code ?? null,
      ok: done.ok ?? false,
      duration_ms: done.duration_ms ?? elapsedMs,
      outcome: "completed",
    });
    return {
      turn, seq, outcome: "completed",
      code: done.code ?? null,
      ok: done.ok ?? false,
      duration_ms: done.duration_ms ?? elapsedMs,
      bytes: out.bytes, lines: out.lines, out_hash: out.out_hash,
      inline: out.text ?? null,
      retrieve: out.text != null ? null : `body(turn: ${turn})`,
      complete: true,
      // Observability: where the wall clock actually went, every call.
      timings: {
        dispatchMs: dispatchedAt - startedAt,
        waitMs: settledAt - dispatchedAt,
        recordMs: Date.now() - settledAt,
        totalMs: Date.now() - startedAt,
        shellReportedMs: done.duration_ms ?? null,
      },
    };
  }

  // Not finished. Record what we know, close nothing, and say so plainly.
  await journal.note(`observation ended before completion: ${outcome}`, { turn, elapsedMs });
  return {
    turn, seq, outcome,
    code: null, ok: false, duration_ms: elapsedMs,
    complete: false,
    turnStillOpen: true,
    timings: { dispatchMs: dispatchedAt - startedAt, waitMs: settledAt - dispatchedAt, totalMs: elapsedMs },
    note:
      outcome === "cancelled"
        ? "Observation cancelled. The command was NOT stopped and is still running in the pane. The turn stays open; it will close itself once it finishes."
        : outcome === "died"
          ? "The pane's process exited before the command reported. Any partial output is in the turn file."
          : "Timed out watching for completion. The command is STILL RUNNING and was not cancelled. The turn stays open and will close itself once it finishes.",
    retrieve: `read(turn: ${turn}) to check, or cancel(level: 'terminate') to stop it`,
    cancelPath,
  };
}

/**
 * Close any turn whose command finished after we stopped watching.
 *
 * Called before reads, so a turn that timed out or was abandoned settles itself
 * the next time anyone looks, rather than staying open forever or requiring the
 * supervisor to remember to reap it.
 */
export async function finalizeOpenTurns(journal) {
  const { turns } = await journal.summary();
  const open = turns.filter((t) => t.outcome == null);
  const closed = [];

  for (const t of open) {
    const donePath = journal.turnPath(t.turn, "done");
    if (!existsSync(donePath)) continue;
    let done = {};
    try {
      done = JSON.parse(await fs.readFile(donePath, "utf8"));
    } catch {
      continue;
    }
    const out = await journal.recordOutput({ turn: t.turn, bodyPath: journal.turnPath(t.turn, "out") });
    await journal.recordExit({
      turn: t.turn,
      code: done.code ?? null,
      ok: done.ok ?? false,
      duration_ms: done.duration_ms ?? null,
      outcome: "completed",
    });
    closed.push({ turn: t.turn, code: done.code ?? null, bytes: out.bytes, lines: out.lines });
  }
  return closed;
}

/** Request cooperative cancellation of a turn. Advisory — never a guarantee. */
export async function requestCancel(journal, turn, reason = "supervisor requested") {
  const p = journal.turnPath(turn, "cancel");
  await fs.writeFile(p, JSON.stringify({ ts: new Date().toISOString(), reason }), "utf8");
  return {
    turn,
    cancelPath: p,
    cooperative: true,
    note:
      "Cancellation requested. This only stops commands that check for it. " +
      "Nothing was killed — escalate with cancel(level: 'terminate') if the command ignores the request.",
  };
}
