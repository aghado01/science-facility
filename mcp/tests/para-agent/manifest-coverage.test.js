import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const suiteDir = path.dirname(fileURLToPath(import.meta.url));

test("authoritative manifest lists every top-level node:test suite exactly once", async () => {
  const manifest = JSON.parse(await fs.readFile(path.join(suiteDir, "test-manifest.json"), "utf8"));
  assert.equal(manifest.schema_version, 1);
  const entries = [...manifest.bounded, ...manifest.live];
  const ids = entries.map((entry) => entry.id);
  const paths = entries.map((entry) => entry.path);
  assert.equal(new Set(ids).size, ids.length, "suite ids must be unique");
  assert.equal(new Set(paths).size, paths.length, "suite paths must be unique");

  const discovered = (await fs.readdir(suiteDir, { withFileTypes: true }))
    .filter((entry) => entry.isFile() && entry.name.endsWith(".test.js"))
    .map((entry) => entry.name)
    .sort();
  const listed = entries
    .filter((entry) => entry.runner === "node-test")
    .map((entry) => entry.path)
    .sort();
  assert.deepEqual(listed, discovered, "unlisted or stale test files would make the manifest false-green");
});
