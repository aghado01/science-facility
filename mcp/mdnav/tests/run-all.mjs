#!/usr/bin/env node
/**
 * Runs every suite and aggregates. One suite passing must never stand in for
 * another: acceptance.mjs drives the mdnav.mjs CLI and never touches src/, so
 * it cannot report on the engine or the journal at all; and the typecheck is
 * the only thing that makes the annotations under src/ load-bearing at all.
 *
 * tests/test-manifest.json is the declarative list; this file is the runner.
 */

import { spawnSync } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));

// [label, argv] — argv is passed to `node` verbatim, so `.test.ts` suites run
// under --test while the legacy self-reporting `.mjs` suites run as scripts.
const SUITES = [
  ["typecheck   (gate 0 — tsc --noEmit over src/ and tests/*.ts)", ["--test", join(here, "typecheck.test.ts")]],
  ["acceptance  (CLI — mdnav.mjs)", [join(here, "acceptance.mjs")]],
  ["engine      (MCP — src/engine.ts)", [join(here, "engine-test.mjs")]],
  ["journal     (MCP — ledger + formatting)", [join(here, "journal-test.mjs")]],
  ["frame-matrix(MCP — ablation manipulation check)", [join(here, "frame-matrix-test.mjs")]],
  ["render      (MCP — what reaches the stream)", [join(here, "render-test.mjs")]],
  ["skills      (MCP — serving the discipline)", [join(here, "skills-test.mjs")]],
];

let failed = 0;
const summary = [];

for (const [label, argv] of SUITES) {
  process.stdout.write(`\n${"─".repeat(72)}\n${label}\n${"─".repeat(72)}\n`);
  const r = spawnSync(process.execPath, argv, { stdio: "inherit" });
  const code = r.status ?? 1;
  if (code !== 0) failed++;
  summary.push(`${code === 0 ? "PASS" : "FAIL"}  ${label}`);
}

process.stdout.write(`\n${"═".repeat(72)}\n${summary.join("\n")}\n`);
process.stdout.write(failed === 0 ? "\nall suites green\n" : `\n${failed} suite(s) failed\n`);
process.exit(failed > 0 ? 1 : 0);
