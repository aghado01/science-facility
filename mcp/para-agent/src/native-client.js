import { spawn } from "node:child_process";

const DEFAULT_TIMEOUT_MS = 120_000;
const DEFAULT_MAX_BUFFER_BYTES = 32 * 1024 * 1024;
const DEFAULT_TERMINATION_GRACE_MS = 1_000;

function positiveInteger(value, name) {
  if (!Number.isSafeInteger(value) || value <= 0) {
    throw new TypeError(`${name} must be a positive safe integer`);
  }
  return value;
}

function isWellFormedUnicode(text) {
  for (let i = 0; i < text.length; i++) {
    const unit = text.charCodeAt(i);
    if (unit >= 0xd800 && unit <= 0xdbff) {
      const next = text.charCodeAt(i + 1);
      if (!(next >= 0xdc00 && next <= 0xdfff)) return false;
      i++;
    } else if (unit >= 0xdc00 && unit <= 0xdfff) {
      return false;
    }
  }
  return true;
}

function errorFact(error) {
  if (!error) return null;
  return {
    name: String(error.name ?? "Error"),
    code: error.code == null ? null : String(error.code),
    message: String(error.message ?? error),
  };
}

function validateRunRequest(request) {
  if (!request || typeof request !== "object" || Array.isArray(request)) {
    throw new TypeError("run request must be an object");
  }
  if (typeof request.executable !== "string" || request.executable.length === 0) {
    throw new TypeError("executable must be a non-empty string");
  }
  if (!Array.isArray(request.args) || request.args.some((arg) => typeof arg !== "string")) {
    throw new TypeError("args must be an array of strings");
  }
  if (typeof request.prompt !== "string") {
    throw new TypeError("prompt must be a string");
  }
  if (!isWellFormedUnicode(request.prompt)) {
    throw new TypeError("prompt must be well-formed Unicode before UTF-8 encoding");
  }
  if (request.cwd !== undefined && typeof request.cwd !== "string") {
    throw new TypeError("cwd must be a string when supplied");
  }
  if (request.env !== undefined) {
    if (!request.env || typeof request.env !== "object" || Array.isArray(request.env)) {
      throw new TypeError("env must be an object when supplied");
    }
    for (const [name, value] of Object.entries(request.env)) {
      if (typeof value !== "string") throw new TypeError(`env.${name} must be a string`);
    }
  }
  for (const callback of ["onStdout", "onStderr"]) {
    if (request[callback] !== undefined && typeof request[callback] !== "function") {
      throw new TypeError(`${callback} must be a function when supplied`);
    }
  }
}

function emptyTermination() {
  return {
    requested: false,
    reason: null,
    requestedSignal: null,
    killAccepted: null,
    escalated: false,
    closed: null,
    closedAfterRequest: null,
  };
}

/**
 * Structured-CLI byte transport.
 *
 * This class deliberately does not parse output, identify events, or infer
 * application state. Callback invocation is synchronous and follows Node's
 * observed stdout/stderr event order. `meta.index` provides the shared ordering
 * witness; it does not claim an ordering stronger than the two OS pipes expose.
 */
export class ProcessNativeClient {
  constructor(options = {}) {
    this.defaultTimeoutMs = positiveInteger(
      options.defaultTimeoutMs ?? DEFAULT_TIMEOUT_MS,
      "defaultTimeoutMs",
    );
    this.maxBufferBytes = positiveInteger(
      options.maxBufferBytes ?? DEFAULT_MAX_BUFFER_BYTES,
      "maxBufferBytes",
    );
    this.terminationGraceMs = positiveInteger(
      options.terminationGraceMs ?? DEFAULT_TERMINATION_GRACE_MS,
      "terminationGraceMs",
    );
    this.children = new Set();
  }

  async run({
    executable,
    args,
    prompt,
    timeoutMs,
    signal,
    cwd,
    env,
    onStdout,
    onStderr,
  } = {}) {
    const request = { executable, args, prompt, timeoutMs, signal, cwd, env, onStdout, onStderr };
    validateRunRequest(request);
    const effectiveTimeoutMs = positiveInteger(timeoutMs ?? this.defaultTimeoutMs, "timeoutMs");
    const promptBuffer = Buffer.from(prompt, "utf8");
    const startedAt = Date.now();

    if (signal?.aborted) {
      return {
        ok: false,
        outcome: "cancelled",
        executable,
        args: [...args],
        pid: null,
        spawned: false,
        exitCode: null,
        signal: null,
        error: null,
        prompt: { bytes: promptBuffer.length, writeCompleted: false },
        stdout: Buffer.alloc(0),
        stderr: Buffer.alloc(0),
        output: {
          stdoutBytes: 0,
          stderrBytes: 0,
          capturedBytes: 0,
          maxBufferBytes: this.maxBufferBytes,
          truncated: false,
          observations: 0,
        },
        termination: emptyTermination(),
        timing: { startedAt, endedAt: startedAt, durationMs: 0 },
      };
    }

    return new Promise((resolve) => {
      let child;
      try {
        child = spawn(executable, args, {
          cwd,
          env: { ...process.env, ...(env ?? {}) },
          shell: false,
          windowsHide: true,
          stdio: ["pipe", "pipe", "pipe"],
        });
      } catch (error) {
        const endedAt = Date.now();
        resolve({
          ok: false,
          outcome: "spawn_failed",
          executable,
          args: [...args],
          pid: null,
          spawned: false,
          exitCode: null,
          signal: null,
          error: errorFact(error),
          prompt: { bytes: promptBuffer.length, writeCompleted: false },
          stdout: Buffer.alloc(0),
          stderr: Buffer.alloc(0),
          output: {
            stdoutBytes: 0,
            stderrBytes: 0,
            capturedBytes: 0,
            maxBufferBytes: this.maxBufferBytes,
            truncated: false,
            observations: 0,
          },
          termination: emptyTermination(),
          timing: { startedAt, endedAt, durationMs: endedAt - startedAt },
        });
        return;
      }

      this.children.add(child);
      const stdoutChunks = [];
      const stderrChunks = [];
      const observed = { stdout: 0, stderr: 0 };
      let capturedBytes = 0;
      let observationIndex = 0;
      let spawned = false;
      let promptWriteCompleted = false;
      let promptWriteCompletedAt = null;
      let forced = null;
      let settled = false;
      let closed = false;
      let timeoutTimer;
      let escalationTimer;
      let confirmationTimer;
      const termination = emptyTermination();

      const cleanup = ({ keepChild = false } = {}) => {
        clearTimeout(timeoutTimer);
        clearTimeout(escalationTimer);
        clearTimeout(confirmationTimer);
        signal?.removeEventListener("abort", onAbort);
        if (!keepChild) this.children.delete(child);
      };

      const makeResult = ({ outcome, code = null, childSignal = null, error = null }) => {
        const endedAt = Date.now();
        return {
          ok: outcome === "completed",
          outcome,
          executable,
          args: [...args],
          pid: child.pid ?? null,
          spawned,
          exitCode: Number.isInteger(code) ? code : null,
          signal: childSignal ?? null,
          error: errorFact(error),
          prompt: {
            bytes: promptBuffer.length,
            writeCompleted: promptWriteCompleted,
            ...(promptWriteCompletedAt ? { writeCompletedAt: promptWriteCompletedAt } : {}),
          },
          stdout: Buffer.concat(stdoutChunks),
          stderr: Buffer.concat(stderrChunks),
          output: {
            stdoutBytes: observed.stdout,
            stderrBytes: observed.stderr,
            capturedBytes,
            maxBufferBytes: this.maxBufferBytes,
            truncated: observed.stdout + observed.stderr > capturedBytes,
            observations: observationIndex,
          },
          termination: { ...termination },
          timing: { startedAt, endedAt, durationMs: endedAt - startedAt },
        };
      };

      const finish = (details) => {
        if (settled) return;
        settled = true;
        const keepChild = !closed && spawned;
        cleanup({ keepChild });
        resolve(makeResult(details));
      };

      const requestTermination = (outcome, error = null) => {
        if (forced || settled) return;
        forced = { outcome, error };
        termination.requested = true;
        termination.reason = outcome;
        termination.requestedSignal = "SIGTERM";
        try {
          termination.killAccepted = child.kill("SIGTERM");
        } catch {
          termination.killAccepted = false;
        }

        escalationTimer = setTimeout(() => {
          if (closed || settled) return;
          termination.escalated = true;
          termination.requestedSignal = "SIGKILL";
          try {
            termination.killAccepted = child.kill("SIGKILL") || termination.killAccepted;
          } catch {
            // The confirmation timer reports whether close was actually seen.
          }
          confirmationTimer = setTimeout(() => {
            if (closed || settled) return;
            termination.closed = false;
            termination.closedAfterRequest = false;
            child.stdout.destroy();
            child.stderr.destroy();
            finish({ outcome, error });
          }, this.terminationGraceMs);
        }, this.terminationGraceMs);
      };

      const onAbort = () => requestTermination("cancelled");
      signal?.addEventListener("abort", onAbort, { once: true });

      const captureChunk = (stream, callback, bucket) => (chunk) => {
        if (settled) return;
        const raw = Buffer.from(chunk);
        const streamOffset = observed[stream];
        observed[stream] += raw.length;
        const index = observationIndex++;

        if (!forced && callback) {
          try {
            callback(raw, {
              index,
              stream,
              streamOffset,
              totalObservedBytes: observed.stdout + observed.stderr,
            });
          } catch (error) {
            requestTermination("callback_failed", error);
          }
        }

        const remaining = Math.max(0, this.maxBufferBytes - capturedBytes);
        if (remaining > 0) {
          const retained = raw.subarray(0, remaining);
          bucket.push(retained);
          capturedBytes += retained.length;
        }
        if (observed.stdout + observed.stderr > this.maxBufferBytes) {
          requestTermination("max_buffer");
        }
      };

      child.stdout.on("data", captureChunk("stdout", onStdout, stdoutChunks));
      child.stderr.on("data", captureChunk("stderr", onStderr, stderrChunks));

      child.once("spawn", () => {
        spawned = true;
        child.stdin.once("finish", () => {
          promptWriteCompleted = true;
          promptWriteCompletedAt = new Date().toISOString();
        });
        child.stdin.once("error", (error) => {
          requestTermination("write_failed", error);
        });
        child.stdin.end(promptBuffer);
      });

      child.once("error", (error) => {
        if (settled) return;
        if (forced) {
          termination.closed = false;
          termination.closedAfterRequest = false;
          finish({ ...forced });
          return;
        }
        finish({ outcome: "spawn_failed", error });
      });

      child.once("close", (code, childSignal) => {
        closed = true;
        this.children.delete(child);
        termination.closed = true;
        termination.closedAfterRequest = termination.requested ? true : null;
        if (settled) return;
        if (forced) {
          finish({ ...forced, code, childSignal });
        } else {
          finish({ outcome: code === 0 ? "completed" : "nonzero", code, childSignal });
        }
      });

      timeoutTimer = setTimeout(() => requestTermination("timeout"), effectiveTimeoutMs);
    });
  }

  close() {
    for (const child of this.children) {
      try {
        child.kill("SIGKILL");
      } catch {
        // Best effort during owner shutdown.
      }
    }
  }
}
