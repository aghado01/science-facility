import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const TEST_ROOT = path.dirname(fileURLToPath(import.meta.url));
const PACKAGE_ROOT = path.resolve(TEST_ROOT, "..");
const RECIPE_DIR = path.join(PACKAGE_ROOT, "brewery", "node");

/**
 * Two files are named package.json and they do different jobs.
 *
 * The one at the package root is the manifest. Node reads `type` and `main` by walking up from
 * each source file, so it has to be there and cannot move into brewery.
 *
 * The one in brewery/node is the dependency recipe: the single canonical npm project whose graph
 * is the union of everything para-agent needs from Node, materialized once into deps/node_modules.
 *
 * These tests keep the two sets of fields from creeping back into each other, which is what
 * happened before the split and what leaves two files disagreeing about the same facts.
 */

async function readJson(...segments) {
  return JSON.parse(await readFile(path.join(...segments), "utf8"));
}

const EXACT_VERSION = /^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$/;
const RECIPE_MUST_NOT_HAVE = ["type", "main", "bin", "scripts"];
const MANIFEST_MUST_NOT_HAVE = ["dependencies", "devDependencies", "peerDependencies", "optionalDependencies"];

test("PACKAGE-LAYOUT: the root manifest declares the package and no dependencies", async () => {
  const manifest = await readJson(PACKAGE_ROOT, "package.json");

  assert.equal(manifest.type, "module", "Node resolves module type by walking up from each source file");
  assert.equal(typeof manifest.main, "string");
  assert.equal(manifest.bin["para-agent"], "src/index.js");
  assert.equal(manifest.bin["para-agent-quarantine"], "src/quarantine-admin.js");

  for (const field of MANIFEST_MUST_NOT_HAVE) {
    assert.equal(manifest[field], undefined, `${field} belongs in the brewery recipe, not the manifest`);
  }
});

test("PACKAGE-LAYOUT: the brewery recipe declares pinned dependencies and no package fields", async () => {
  const recipe = await readJson(RECIPE_DIR, "package.json");
  const names = Object.keys(recipe.dependencies ?? {});

  assert.ok(names.length > 0, "the recipe is the only place dependencies are declared");

  for (const field of RECIPE_MUST_NOT_HAVE) {
    assert.equal(recipe[field], undefined, `${field} belongs in the root manifest, not the recipe`);
  }

  for (const name of names) {
    assert.match(
      recipe.dependencies[name],
      EXACT_VERSION,
      `${name} must be pinned to one exact version, not a range`,
    );
  }
});

test("PACKAGE-LAYOUT: the lock is in step with the recipe beside it", async () => {
  const recipe = await readJson(RECIPE_DIR, "package.json");
  const lock = await readJson(RECIPE_DIR, "package-lock.json");
  const root = lock.packages[""];

  assert.equal(root.name, recipe.name, "npm ci refuses a lock whose root disagrees with its manifest");
  assert.deepEqual(root.dependencies, recipe.dependencies);

  // Every declared dependency resolved to something the lock actually records.
  for (const name of Object.keys(recipe.dependencies)) {
    const entry = lock.packages[`node_modules/${name}`];
    assert.ok(entry, `${name} is declared but absent from the lock`);
    assert.equal(entry.version, recipe.dependencies[name]);
  }
});
