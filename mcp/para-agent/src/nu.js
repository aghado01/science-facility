import { execFile } from "node:child_process";
import path from "node:path";
import { resolveNuBin, resolvePath } from "./mux.js";
import { getNuProfileConfig } from "./profiles.js";

export class NuEngine {
  constructor(opts = {}) {
    this.bin = opts.bin ?? resolveNuBin();
    this.cwd = opts.cwd ?? process.cwd();
  }

  /**
   * Evaluate a Nushell pipeline script string against optional input JSON data.
   * Returns parsed JSON result or raw string output.
   */
  async eval(script, inputData = null) {
    const profile = getNuProfileConfig("backend", { workspaceRoot: this.cwd });

    const inputNu = inputData !== null
      ? `'${Buffer.from(JSON.stringify(inputData)).toString("base64")}' | decode base64 | decode utf-8 | from json | `
      : "";

    const wrappedScript =
      `try {\n` +
      `  let __r = (${inputNu}${script})\n` +
      `  $__r | to json\n` +
      `} catch { |err|\n` +
      `  $"{'__nu_error__': '($err.msg)'}"\n` +
      `}\n`;

    return new Promise((resolve, reject) => {
      execFile(
        this.bin,
        [...profile.args, "-c", wrappedScript],
        {
          cwd: this.cwd,
          windowsHide: true,
          env: {
            ...process.env,
            ...profile.env,
            LANG: "en_US.UTF-8",
          },
          maxBuffer: 32 * 1024 * 1024,
        },
        (err, stdout, stderr) => {
          if (err && !stdout) return reject(err);
          const rawOutput = (stdout ?? "").trim();
          if (!rawOutput) return resolve(null);
          try {
            const parsed = JSON.parse(rawOutput);
            if (parsed && parsed.__nu_error__) {
              return reject(new Error(`Nushell error: ${parsed.__nu_error__}`));
            }
            resolve(parsed);
          } catch {
            resolve(rawOutput);
          }
        }
      );
    });
  }

  close() {
    // No-op for process-per-query engine mode
  }
}
