import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const suiteDir = path.dirname(fileURLToPath(import.meta.url));

test("authoritative manifest lists every top-level test suite exactly once with the correct runner", async () => {
  const manifest = JSON.parse(await fs.readFile(path.join(suiteDir, "test-manifest.json"), "utf8"));
  assert.equal(manifest.schema_version, 1);
  const entries = [...manifest.bounded, ...manifest.live];
  const ids = entries.map((entry) => entry.id);
  const paths = entries.map((entry) => entry.path);
  assert.equal(new Set(ids).size, ids.length, "suite ids must be unique");
  assert.equal(new Set(paths).size, paths.length, "suite paths must be unique");

  const files = (await fs.readdir(suiteDir, { withFileTypes: true }))
    .filter((entry) => entry.isFile())
    .map((entry) => entry.name);
  const discoveredNode = files
    .filter((name) => name.endsWith(".test.js"))
    .sort();
  const listedNode = entries
    .filter((entry) => entry.runner === "node-test")
    .map((entry) => entry.path)
    .sort();
  assert.deepEqual(listedNode, discoveredNode, "unlisted or stale node:test files would make the manifest false-green");

  const discoveredPowerShell = files
    .filter((name) => name.endsWith(".tests.ps1"))
    .sort();
  const listedPowerShell = entries
    .filter((entry) => entry.runner === "powershell")
    .map((entry) => entry.path)
    .sort();
  assert.deepEqual(
    listedPowerShell,
    discoveredPowerShell,
    "unlisted or stale PowerShell test files would make the manifest false-green",
  );
});
