import { spawn } from "node:child_process";
import { resolveNuBin } from "./mux.js";
import { getNuProfileConfig } from "./profiles.js";

const NU_PROTOCOL = "para-agent.nu.v1";
const DEFAULT_TIMEOUT_MS = 30_000;
const DEFAULT_MAX_BUFFER_BYTES = 32 * 1024 * 1024;
const ERROR_DETAIL_LIMIT = 4096;

function boundedText(value, limit = ERROR_DETAIL_LIMIT) {
  const text = String(value ?? "");
  return text.length <= limit ? text : `${text.slice(0, limit)}...`;
}

function errorEnvelope(code, message, { exitCode = 1, stderr, signal } = {}) {
  const error = {
    code,
    message: boundedText(message),
  };
  if (stderr) error.stderr = boundedText(stderr);
  if (signal) error.signal = signal;
  return {
    protocol: NU_PROTOCOL,
    ok: false,
    error,
    exit_code: Number.isInteger(exitCode) && exitCode !== 0 ? exitCode : 1,
  };
}

export class NuExecutionError extends Error {
  constructor(envelope, options = {}) {
    super(JSON.stringify(envelope), options);
    this.name = "NuExecutionError";
    this.code = envelope.error.code;
    this.exitCode = envelope.exit_code;
    this.envelope = envelope;
  }
}

function executionError(code, message, details = {}, cause) {
  return new NuExecutionError(errorEnvelope(code, message, details), cause ? { cause } : undefined);
}

function inputExpression(script, hasInput) {
  return hasInput
    ? `($__para_input | do {\n${script}\n  })`
    : `(do {\n${script}\n  })`;
}

function errorArm() {
  return (
    `} catch { |err|\n` +
    `  { protocol: "${NU_PROTOCOL}", ok: false, error: { code: "NU_RUNTIME", message: $err.msg }, exit_code: 1 } | to json --raw | print\n` +
    `  exit 1\n` +
    `}`
  );
}

function structuredProgram(script, hasInput) {
  const input = hasInput ? "  let __para_input = ($in | from json)\n" : "";
  return (
    `try {\n` +
    input +
    `  let __para_value = ${inputExpression(script, hasInput)}\n` +
    `  { protocol: "${NU_PROTOCOL}", ok: true, value: $__para_value } | to json --raw\n` +
    errorArm()
  );
}

function rawProgram(script, hasInput) {
  const input = hasInput ? "  let __para_input = ($in | from json)\n" : "";
  return `try {\n${input}  ${inputExpression(script, hasInput)}\n${errorArm()}`;
}

function parseJson(text) {
  try {
    return JSON.parse(text);
  } catch {
    return null;
  }
}

/**
 * Process-per-query Nushell provider.
 *
 * `script` is trusted provider source. All caller-controlled values belong in
 * `inputData`, which is serialized once and delivered through stdin. Public MCP
 * handlers must use a typed query provider rather than constructing `script`.
 */
export class NuEngine {
  constructor(opts = {}) {
    this.bin = opts.bin ?? resolveNuBin();
    this.cwd = opts.cwd ?? process.cwd();
    this.profileName = opts.profileName ?? "backend";
    this.timeoutMs = opts.timeoutMs ?? DEFAULT_TIMEOUT_MS;
    this.maxBufferBytes = opts.maxBufferBytes ?? DEFAULT_MAX_BUFFER_BYTES;
    this.env = opts.env ?? {};
    this.children = new Set();
  }

  /** Strict structured evaluation. A successful call always returns parsed JSON. */
  async eval(script, inputData = null, options = {}) {
    return this.evalStructured(script, inputData, options);
  }

  /** Strict structured evaluation. Raw stdout is never accepted as success. */
  async evalStructured(script, inputData = null, options = {}) {
    return this.#execute("structured", script, inputData, options);
  }

  /** Explicit raw-text evaluation. This is the only API that returns raw stdout. */
  async evalRaw(script, inputData = null, options = {}) {
    return this.#execute("raw", script, inputData, options);
  }

  async #execute(mode, script, inputData, options) {
    if (typeof script !== "string" || script.trim() === "") {
      throw executionError("NU_INVALID_SCRIPT", "Nushell source must be a non-empty string");
    }

    const timeoutMs = options.timeoutMs ?? this.timeoutMs;
    const maxBufferBytes = options.maxBufferBytes ?? this.maxBufferBytes;
    const signal = options.signal;
    if (!Number.isFinite(timeoutMs) || timeoutMs <= 0) {
      throw executionError("NU_INVALID_OPTION", "timeoutMs must be a positive finite number");
    }
    if (!Number.isSafeInteger(maxBufferBytes) || maxBufferBytes <= 0) {
      throw executionError("NU_INVALID_OPTION", "maxBufferBytes must be a positive safe integer");
    }
    if (signal?.aborted) {
      throw executionError("NU_CANCELLED", "Nushell evaluation was cancelled before launch");
    }

    const hasInput = inputData !== null && inputData !== undefined;
    let inputBytes = Buffer.alloc(0);
    if (hasInput) {
      try {
        inputBytes = Buffer.from(JSON.stringify(inputData), "utf8");
      } catch (err) {
        throw executionError("NU_INPUT_SERIALIZATION", "Input data is not JSON serializable", {}, err);
      }
    }

    const profile = getNuProfileConfig(this.profileName, { workspaceRoot: this.cwd });
    const program = mode === "structured"
      ? structuredProgram(script, hasInput)
      : rawProgram(script, hasInput);
    const args = [
      ...profile.args,
      ...(hasInput ? ["--stdin"] : []),
      "--no-newline",
      "-c",
      program,
    ];

    return new Promise((resolve, reject) => {
      let child;
      try {
        child = spawn(this.bin, args, {
          cwd: this.cwd,
          windowsHide: true,
          env: {
            ...process.env,
            ...profile.env,
            ...this.env,
            LANG: "en_US.UTF-8",
          },
          stdio: ["pipe", "pipe", "pipe"],
        });
      } catch (err) {
        reject(executionError("NU_SPAWN", `Could not launch Nushell: ${err.message}`, {}, err));
        return;
      }

      this.children.add(child);
      const stdout = [];
      const stderr = [];
      let capturedBytes = 0;
      let forcedError = null;
      let settled = false;

      const cleanup = () => {
        clearTimeout(timer);
        signal?.removeEventListener("abort", onAbort);
        this.children.delete(child);
      };

      const settleReject = (err) => {
        if (settled) return;
        settled = true;
        cleanup();
        reject(err);
      };

      const terminate = (err) => {
        if (forcedError) return;
        forcedError = err;
        child.stdin.destroy();
        child.kill("SIGKILL");
      };

      const onData = (bucket) => (chunk) => {
        if (forcedError) return;
        capturedBytes += chunk.length;
        if (capturedBytes > maxBufferBytes) {
          terminate(executionError(
            "NU_MAX_BUFFER",
            `Nushell output exceeded ${maxBufferBytes} bytes`,
          ));
          return;
        }
        bucket.push(chunk);
      };

      const onAbort = () => terminate(executionError("NU_CANCELLED", "Nushell evaluation was cancelled"));
      const timer = setTimeout(
        () => terminate(executionError("NU_TIMEOUT", `Nushell evaluation exceeded ${timeoutMs}ms`)),
        timeoutMs,
      );

      signal?.addEventListener("abort", onAbort, { once: true });
      child.stdout.on("data", onData(stdout));
      child.stderr.on("data", onData(stderr));
      child.once("error", (err) => {
        settleReject(executionError("NU_SPAWN", `Could not launch Nushell: ${err.message}`, {}, err));
      });
      child.once("close", (code, childSignal) => {
        if (settled) return;
        const stdoutText = Buffer.concat(stdout).toString("utf8");
        const stderrText = Buffer.concat(stderr).toString("utf8");

        if (forcedError) {
          settleReject(forcedError);
          return;
        }

        if (code !== 0) {
          const emitted = parseJson(stdoutText.trim());
          if (emitted?.protocol === NU_PROTOCOL && emitted.ok === false && emitted.error) {
            emitted.exit_code = Number.isInteger(code) && code !== 0 ? code : 1;
            settleReject(new NuExecutionError(emitted));
          } else {
            settleReject(executionError(
              "NU_PROCESS_FAILURE",
              stderrText || stdoutText || "Nushell exited without an error envelope",
              { exitCode: code, stderr: stderrText, signal: childSignal },
            ));
          }
          return;
        }

        if (mode === "raw") {
          settled = true;
          cleanup();
          resolve(stdoutText);
          return;
        }

        const emitted = parseJson(stdoutText);
        if (emitted?.protocol !== NU_PROTOCOL || emitted.ok !== true || !("value" in emitted)) {
          settleReject(executionError(
            "NU_INVALID_JSON",
            "Nushell did not emit the structured success envelope",
            { stderr: stderrText },
          ));
          return;
        }

        settled = true;
        cleanup();
        resolve(emitted.value);
      });

      child.stdin.on("error", () => {
        // Early process failure is reported by the `error` or `close` handler.
      });
      child.stdin.end(inputBytes);
    });
  }

  close() {
    for (const child of this.children) {
      child.stdin.destroy();
      child.kill("SIGKILL");
    }
    this.children.clear();
  }
}
