import { spawnSync } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { describe, expect, it } from "vitest";

// Node strips types; it does not check them. `pnpm typecheck` is the gate, and this suite
// keeps that gate inside `pnpm test` so a green test run always implies a clean tree.

const packageRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const tsc = join(packageRoot, "node_modules", "typescript", "bin", "tsc");

function runTsc(project: string): { status: number | null; diagnostics: string } {
  const result = spawnSync(process.execPath, [tsc, "-p", project, "--pretty", "false"], {
    cwd: packageRoot,
    encoding: "utf8",
  });
  if (result.error) throw result.error;
  return { status: result.status, diagnostics: `${result.stdout}${result.stderr}`.trim() };
}

describe("typecheck gate", () => {
  it("src typechecks clean under tsconfig.json", () => {
    const { status, diagnostics } = runTsc("tsconfig.json");
    expect(diagnostics, "tsc reported diagnostics").toBe("");
    expect(status).toBe(0);
  });

  it("tests and config typecheck clean under tsconfig.tests.json", () => {
    const { status, diagnostics } = runTsc("tsconfig.tests.json");
    expect(diagnostics, "tsc reported diagnostics").toBe("");
    expect(status).toBe(0);
  });
});
