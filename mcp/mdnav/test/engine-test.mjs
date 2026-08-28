/**
 * Integration verification for MdnavEngine.
 */

import assert from "node:assert";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { writeFileSync, mkdirSync, rmSync } from "node:fs";

// Import engine from src
import { MdnavEngine } from "../src/engine.ts";

const testDir = join(tmpdir(), "mdnav-engine-test-" + Date.now());
mkdirSync(testDir, { recursive: true });

try {
  // 1. Create sample markdown files
  const doc1 = join(testDir, "paper1.md");
  writeFileSync(
    doc1,
    `# Geometric Medians on Riemannian Manifolds

## Abstract
This paper introduces a scale-calibrated geometric median.

## 1. Introduction
High dimensional representations often lie on submanifolds.

### 1.1 Background
Riemannian gradient descent converges under mild curvature conditions.

## 2. Main Theorem
Theorem 1 states that the breakdown point is 0.5.
`,
    "utf8"
  );

  const doc2 = join(testDir, "paper2.md");
  writeFileSync(
    doc2,
    `# Subspace Tracking

## Abstract
We study principal angles and Grassmannian distance metrics.

## 1. Methods
Using horizontal tangent lifts for geodesics.
`,
    "utf8"
  );

  const engine = new MdnavEngine();

  // Test 1: Discover
  const inv = await engine.discover([testDir], { glob: "*.md" });
  assert.strictEqual(inv.docs.length, 2, "Should discover 2 documents");
  console.log("✓ discover passed: found 2 documents");

  // Test 2: Profile
  const profile = await engine.profile("D001");
  assert(profile.length > 0, "Profile should return construct rows");
  console.log("✓ profile passed: found constructs:", profile.map((p) => p.construct).join(", "));

  // Test 3: Outline
  const outline = await engine.outline("D001", { depth: 2 });
  assert.strictEqual(outline.length, 4, "Outline depth 2 should return 4 units");
  console.log("✓ outline passed: units:", outline.map((u) => u.title).join(" | "));

  // Test 4: Read Heading Unit
  const readRes = await engine.read("D001", { heading: "H0002" });
  assert(readRes.text.includes("This paper introduces a scale-calibrated"), "Read should contain abstract body");
  console.log("✓ read passed");

  // Test 5: Batch Read across multiple documents
  const batchRes = await engine.batchRead([
    { docId: "D001", heading: "H0002", label: "Paper 1 Abstract" },
    { docId: "D002", heading: "H0002", label: "Paper 2 Abstract" },
  ]);
  assert.strictEqual(batchRes.length, 2, "Batch read should return 2 entries");
  assert(batchRes[0].text.includes("scale-calibrated"), "Paper 1 abstract text should match");
  assert(batchRes[1].text.includes("Grassmannian"), "Paper 2 abstract text should match");
  console.log("✓ batchRead passed across multiple documents!");

  // Test 6: Coverage
  const cov = await engine.coverage(["D001"]);
  assert(cov[0].bytesRead > 0, "Coverage should record reads");
  console.log(`✓ coverage passed: ${cov[0].percent}% read`);

  // Test 7: Locate
  const hits = await engine.locate("breakdown point");
  assert.strictEqual(hits.length, 1, "Locate should find 1 hit");
  assert.strictEqual(hits[0].docId, "D001");
  console.log("✓ locate passed:", hits[0]);

  console.log("\nALL ENGINE TESTS PASSED!");
} finally {
  rmSync(testDir, { recursive: true, force: true });
}
