#!/usr/bin/env node
/**
 * Runs every suite and aggregates. One suite passing must never stand in for
 * another: acceptance.mjs drives the mdnav.mjs CLI and never touches src/, so
 * it cannot report on the engine or the journal at all.
 */

import { spawnSync } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));

const SUITES = [
  ["acceptance  (CLI — mdnav.mjs)", "acceptance.mjs"],
  ["engine      (MCP — src/engine.ts)", "engine-test.mjs"],
  ["journal     (MCP — ledger + formatting)", "journal-test.mjs"],
  ["frame-matrix(MCP — ablation manipulation check)", "frame-matrix-test.mjs"],
  ["render      (MCP — what reaches the stream)", "render-test.mjs"],
  ["skills      (MCP — serving the discipline)", "skills-test.mjs"],
];

let failed = 0;
const summary = [];

for (const [label, file] of SUITES) {
  process.stdout.write(`\n${"─".repeat(72)}\n${label}\n${"─".repeat(72)}\n`);
  const r = spawnSync(process.execPath, [join(here, file)], { stdio: "inherit" });
  const code = r.status ?? 1;
  if (code !== 0) failed++;
  summary.push(`${code === 0 ? "PASS" : "FAIL"}  ${label}`);
}

process.stdout.write(`\n${"═".repeat(72)}\n${summary.join("\n")}\n`);
process.stdout.write(failed === 0 ? "\nall suites green\n" : `\n${failed} suite(s) failed\n`);
process.exit(failed > 0 ? 1 : 0);
