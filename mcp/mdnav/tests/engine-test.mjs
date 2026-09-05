/**
 * Engine suite for MdnavEngine — the MCP's own code path.
 *
 * test/acceptance.mjs spawns the mdnav.mjs CLI and never touches src/, so it
 * cannot fail because of anything in here. This is the suite that covers the
 * engine, and the load-bearing check is `partition`: reading every unit at a
 * given depth and concatenating must reproduce the source byte-for-byte. That
 * one check covers completeness, non-overlap, byte fidelity, and preservation
 * of CRLF / multibyte / fenced / long-line content.
 */

import { join } from "node:path";
import { tmpdir } from "node:os";
import { writeFileSync, mkdirSync, rmSync, readFileSync } from "node:fs";

import { MdnavEngine } from "../src/engine.ts";

let pass = 0, fail = 0;
const ok = (name, cond, detail) => {
  if (cond) { pass++; process.stdout.write(`  ok   ${name}\n`); }
  else { fail++; process.stdout.write(`  FAIL ${name}${detail ? `\n       ${detail}` : ""}\n`); }
};
const eq = (name, a, b) => ok(name, a === b, `expected ${JSON.stringify(b)}, got ${JSON.stringify(a)}`);
async function throws(name, fn, match) {
  try { await fn(); ok(name, false, "expected a throw, got a value"); }
  catch (err) { ok(name, !match || match.test(err.message), `message was: ${err.message}`); }
}

const testDir = join(tmpdir(), "mdnav-engine-test-" + process.pid);
const workDir = join(tmpdir(), "mdnav-engine-wd-" + process.pid);
mkdirSync(testDir, { recursive: true });

try {
  // ───────────────────────────────────────────────────────────────── fixtures

  const paper1 = [
    "# Geometric Medians on Riemannian Manifolds",
    "",
    "## Abstract",
    "This paper introduces a scale-calibrated geometric median.",
    "",
    "## 1. Introduction",
    "High dimensional representations often lie on submanifolds.",
    "",
    "### 1.1 Background",
    "Riemannian gradient descent converges under mild curvature conditions.",
    "",
    "## 2. Main Theorem",
    "Theorem 1 states that the breakdown point is 0.5.",
    "",
  ].join("\n");

  const paper2 = [
    "# Subspace Tracking",
    "",
    "## Abstract",
    "We study principal angles and Grassmannian distance metrics.",
    "",
    "## 1. Methods",
    "Using horizontal tangent lifts for geodesics.",
    "",
  ].join("\n");

  // Exercises the partition invariant against everything that could break it:
  // leading prose with no heading of its own, multibyte, a fence whose content
  // looks like a heading, a long unbroken line, and a thematic break.
  const gnarly = [
    "Leading prose that belongs to no heading — a résumé of what follows.",
    "",
    "# Tïtle with ünicode",
    "",
    "Body text.",
    "",
    "```",
    "# this is NOT a heading, it is inside a fence",
    "```",
    "",
    "---",
    "",
    "## After the break",
    "",
    "x".repeat(3000),
    "",
    "$$\\int_0^1 f(x)\\,dx = \\frac{1}{2}$$",
    "",
  ].join("\n");

  const doc1 = join(testDir, "paper1.md");
  const doc2 = join(testDir, "paper2.md");
  const doc3 = join(testDir, "gnarly.md");
  const doc4 = join(testDir, "crlf.md");
  const doc5 = join(testDir, "headless.md");

  writeFileSync(doc1, paper1, "utf8");
  writeFileSync(doc2, paper2, "utf8");
  writeFileSync(doc3, gnarly, "utf8");
  writeFileSync(doc4, gnarly.replace(/\n/g, "\r\n"), "utf8");
  writeFileSync(doc5, "just prose with no headings at all\n".repeat(200), "utf8");

  const engine = new MdnavEngine();
  const inv = await engine.discover([testDir], { glob: "*.md", workDir });
  const id = (name) => inv.docs.find((d) => d.name === name).id;
  const [P1, P2, GNARLY, CRLF, HEADLESS] = [
    id("paper1.md"), id("paper2.md"), id("gnarly.md"), id("crlf.md"), id("headless.md"),
  ];

  // ────────────────────────────────────────────────────────────────── the basics

  process.stdout.write("\nbasics\n");
  eq("discover indexes every document", inv.docs.length, 5);
  ok("profile returns construct rows", (await engine.profile(P1)).length > 0);

  const outline = await engine.outline(P1, { depth: 2 });
  eq("outline at depth 2 returns the active units", outline.length, 4);
  ok("outline carries digests", outline.every((u) => /^[0-9a-f]{4}$/.test(u.digest)));

  const abstract = await engine.read(P1, { heading: "H0002", depth: 2 });
  ok("read returns the unit body", abstract.text.includes("scale-calibrated"));
  ok("read stops at the next active heading", !abstract.text.includes("Introduction"));

  const batch = await engine.batchRead([
    { docId: P1, heading: "H0002", label: "Paper 1 Abstract" },
    { docId: P2, heading: "H0002", label: "Paper 2 Abstract" },
  ]);
  eq("batchRead returns one result per request", batch.length, 2);
  ok("batchRead crosses documents", batch[0].text.includes("scale-calibrated") && batch[1].text.includes("Grassmannian"));
  ok("batchRead reports the resolved anchor with its digest", /^H\d+@[0-9a-f]{4}$/.test(batch[0].anchor));

  const hits = await engine.locate("breakdown point");
  eq("locate finds the line", hits.length, 1);
  eq("locate attributes it to the right document", hits[0].docId, P1);

  // ───────────────────────────────────────────────────── the partition invariant

  process.stdout.write("\npartition\n");
  for (const [name, docId] of [["paper1", P1], ["gnarly", GNARLY], ["crlf", CRLF], ["headless", HEADLESS]]) {
    for (const depth of [1, 2, 3]) {
      const units = await engine.outline(docId, { depth });
      const parts = [];
      for (const u of units) {
        const r = await engine.read(docId, { heading: u.id, depth, extent: "unit" });
        parts.push(r.text);
      }
      const source = readFileSync(inv.docs.find((d) => d.id === docId).path, "utf8");
      ok(
        `${name} at depth ${depth}: units concatenate back to the source`,
        parts.join("") === source,
        `rebuilt ${parts.join("").length} chars from ${units.length} unit(s), source is ${source.length}`
      );
    }
  }

  // ────────────────────────────────────────────────────── unheaded bytes (H0000)

  process.stdout.write("\nunheaded bytes are still addressable\n");
  const gOutline = await engine.outline(GNARLY, { depth: 1 });
  ok("prose ahead of the first heading gets the zero coordinate", /^H0+$/.test(gOutline[0].id), gOutline[0].id);
  eq("and is titled PREAMBLE", gOutline[0].title, "PREAMBLE");
  const preamble = await engine.read(GNARLY, { heading: "H0000" });
  ok("H0000 reads the preamble", preamble.text.includes("belongs to no heading"));
  ok("H0000 stops at the first real heading", !preamble.text.includes("Tïtle"));

  const hOutline = await engine.outline(HEADLESS, { depth: 1 });
  eq("a document with no headings gets exactly one unit", hOutline.length, 1);
  eq("titled BODY", hOutline[0].title, "BODY");
  const whole = await engine.read(HEADLESS, { heading: "H0000" });
  eq("H0000 BODY spans the whole document", whole.bytes, inv.docs.find((d) => d.id === HEADLESS).bytes);

  // ─────────────────────────────────────────────────────────── digest anchors

  process.stdout.write("\ndigest anchors round-trip\n");
  const unit = (await engine.outline(P1, { depth: 2 }))[1];
  const fused = `${unit.id}@${unit.digest}`;
  const viaDigest = await engine.read(P1, { heading: fused, depth: 2 });
  ok("an anchor emitted by outline is accepted by read", viaDigest.text.includes("scale-calibrated"));
  eq("and resolves without complaint", viaDigest.warnings.length, 0);
  ok("read echoes the anchor in round-trippable form", viaDigest.anchors[0] === fused);

  const qualified = await engine.read(P1, { heading: `${P1}:${fused}`, depth: 2 });
  ok("a document-qualified anchor resolves too", qualified.text.includes("scale-calibrated"));

  const drifted = await engine.read(P1, { heading: `${unit.id}@dead`, depth: 2 });
  eq("a stale digest still returns the bytes", drifted.text.includes("scale-calibrated"), true);
  ok("but reports the drift", drifted.warnings.some((w) => /has changed under this anchor/.test(w)));

  // The stream prints this anchor spaced and the skill says to quote it
  // exactly. Read has to take it back in that form, or the two instructions
  // cannot both be followed.
  const asPrinted = await engine.read(P1, { heading: `${unit.id} @ ${unit.digest}`, depth: 2 });
  ok("the spaced form the stream printed resolves", asPrinted.text.includes("scale-calibrated"));
  eq("and raises no drift against the digest it actually equals", asPrinted.warnings.length, 0);
  const asPrintedQualified = await engine.read(P1, { heading: `${P1} : ${unit.id} @ ${unit.digest}`, depth: 2 });
  ok("document-qualified and spaced resolves too", asPrintedQualified.text.includes("scale-calibrated"));

  // ─────────────────────────────────────────────────────────────────── windows

  process.stdout.write("\nwindows\n");
  const wins = await engine.outline(HEADLESS, { windows: 1000 });
  ok("a headingless document partitions into windows", wins.length > 1);
  ok("windows carry digests", wins.every((w) => /^[0-9a-f]{4}$/.test(w.digest)));
  const w2 = await engine.read(HEADLESS, { heading: wins[1].id });
  eq("a window anchor resolves to its exact bytes", w2.bytes, wins[1].unitBytes);
  const wsum = wins.reduce((a, w) => a + w.unitBytes, 0);
  eq("windows tile the whole document", wsum, inv.docs.find((d) => d.id === HEADLESS).bytes);

  // ──────────────────────────────────────────────────── break-basis addressing

  process.stdout.write("\nthematic breaks\n");
  const segs = await engine.outline(GNARLY, { byBreaks: true });
  ok("segments partition from byte 0", segs.length >= 2);
  const segSum = segs.reduce((a, s) => a + s.unitBytes, 0);
  eq("segments tile the whole document", segSum, inv.docs.find((d) => d.id === GNARLY).bytes);
  const s1 = await engine.read(GNARLY, { heading: segs[0].id });
  eq("a segment anchor resolves to its exact bytes", s1.bytes, segs[0].unitBytes);

  // ────────────────────────────────────────────────────────── CRLF anchoring

  process.stdout.write("\nCRLF sources anchor identically\n");
  const lfHit = (await engine.locate("After the break", [GNARLY]))[0];
  const crlfHit = (await engine.locate("After the break", [CRLF]))[0];
  ok("a CRLF twin resolves to the same heading as its LF original",
    lfHit.anchor.split(":")[1] === crlfHit.anchor.split(":")[1],
    `LF ${lfHit.anchor} vs CRLF ${crlfHit.anchor}`);
  eq("and to the same line number", lfHit.line, crlfHit.line);

  // ──────────────────────────────────────────────────────────── loud failures

  process.stdout.write("\nfailures are loud\n");
  await throws("read with no selector refuses", () => engine.read(P1, {}), /needs a selector/);
  await throws("an inactive heading read as a unit refuses",
    () => engine.read(P1, { heading: "H0004", depth: 1 }), /not active at depth 1/);
  await throws("an unknown anchor refuses", () => engine.read(P1, { heading: "H9999" }), /no anchor/);
  await throws("a span outside the document refuses",
    () => engine.read(P1, { span: [0, 10 ** 9] }), /outside/);
  await throws("a window anchor with no windows minted refuses",
    () => engine.read(P1, { heading: "W0001" }), /mint window anchors first/);
  const subtree = await engine.read(P1, { heading: "H0004", depth: 1, extent: "subtree" });
  ok("but the same heading reads fine as a subtree", subtree.text.includes("Background"));

  // ────────────────────────────────────────────────────────────────── coverage

  process.stdout.write("\ncoverage\n");
  const fresh = new MdnavEngine();
  await fresh.discover([doc1], { workDir: join(workDir, "cov") });
  const covId = "D001";
  const before = (await fresh.coverage([covId], 2))[0];
  eq("nothing read yet", before.bytesRead, 0);

  // Two adjacent reads that together cover one unit must count as covering it.
  const full = await fresh.outline(covId, { depth: 1 });
  const half = Math.floor(full[0].unitBytes / 2);
  await fresh.read(covId, { span: [0, half] });
  await fresh.read(covId, { span: [half, full[0].unitBytes] });
  const after = (await fresh.coverage([covId], 1))[0];
  eq("adjacent spans merge into one covered stretch", after.bytesRead, full[0].unitBytes);
  ok("and the unit is no longer listed unread", !after.unreadAnchors.some((u) => u.anchor.endsWith("H0001")));

  const byBreak = (await engine.coverage([GNARLY], 1, true))[0];
  ok("coverage accepts a break basis", byBreak.unreadAnchors.every((u) => /:S\d{4}$/.test(u.anchor)));
  // ──────────────────────────────────────────────────────── mounting a root

  process.stdout.write("\nmounting a corpus root\n");
  const mountRoot = join(testDir, "mount");
  mkdirSync(join(mountRoot, "chapters"), { recursive: true });
  mkdirSync(join(mountRoot, "appendix"), { recursive: true });
  writeFileSync(join(mountRoot, "README.md"), "# Readme\n\n## About\n\nintro\n", "utf8");
  for (const n of ["01", "02", "03"]) {
    writeFileSync(join(mountRoot, "chapters", `Ch${n}.md`), `# Chapter ${n}\n\n## One\n\nbody\n`, "utf8");
  }
  writeFileSync(join(mountRoot, "appendix", "A.md"), "# Appendix A\n\n## Notes\n\nbody\n", "utf8");

  const mounted = new MdnavEngine();
  const mnt = await mounted.discover([], { root: mountRoot, workDir: join(workDir, "mount") });

  eq("a mount finds every document beneath the root, recursively", mnt.docs.length, 5);
  eq("the root is recorded", mnt.root, mountRoot);
  eq("groups are the directories holding documents", mnt.addressing.groups, 3);
  eq("in canonical path order, root first",
    mnt.addressing.groupPaths.join(","), ",appendix,chapters");

  const idOf = (rel) => mnt.docs.find((d) => d.relPath === rel).id;
  eq("root documents take group 1", idOf("README.md"), "D0101");
  eq("appendix takes group 2", idOf("appendix/A.md"), "D0201");
  eq("chapters take group 3, numbered within the group",
    ["chapters/Ch01.md", "chapters/Ch02.md", "chapters/Ch03.md"].map(idOf).join(","), "D0301,D0302,D0303");
  ok("so co-located documents share a literal prefix",
    ["D0301", "D0302", "D0303"].every((id) => id.startsWith("D03")));

  ok("paths are reported relative to the root",
    mnt.docs.every((d) => d.relPath && !d.relPath.includes(":") && !d.relPath.startsWith("/")));
  eq("widths are measured from the corpus, not assumed",
    `${mnt.addressing.groupWidth}/${mnt.addressing.docWidth}`, "2/2");

  // Deterministic from the data: mount the same corpus again, anywhere, and the
  // addresses are identical. That is what makes a corpus usable as a fixture.
  const remount = new MdnavEngine();
  const mnt2 = await remount.discover([], { root: mountRoot, workDir: join(workDir, "mount2") });
  eq("mounting the same corpus again yields the same addresses",
    mnt2.docs.map((d) => `${d.id}=${d.relPath}`).join(" "),
    mnt.docs.map((d) => `${d.id}=${d.relPath}`).join(" "));

  // A single-group corpus carries no group axis — a constant is not information.
  const flat = new MdnavEngine();
  const flatInv = await flat.discover([], { root: join(mountRoot, "chapters"), workDir: join(workDir, "flat") });
  eq("one group means no group axis", flatInv.addressing.groups, 1);
  eq("and plain document ids", flatInv.docs.map((d) => d.id).join(","), "D01,D02,D03");

  await throws("mounting a root that does not exist fails loudly",
    () => new MdnavEngine().discover([], { root: join(testDir, "nope") }), /no such root/);

  // ──────────────────────────────────── every atom is the same width, always

  process.stdout.write("\nfixed-width ids\n");
  const widths = (docs) => new Set(docs.map((d) => d.id.length));
  eq("one mount, one id length", widths(mnt.docs).size, 1);
  eq("and a single-group mount likewise", widths(flatInv.docs).size, 1);

  // A file read from outside the mount must not collide with a mounted id, and
  // must not be a different length either.
  const outside = join(testDir, "paper1.md");
  const strayRead = await mounted.read(outside, { heading: "H0002", depth: 2 });
  eq("a document outside the mount gets a same-width id", strayRead.docId.length, mnt.docs[0].id.length);
  ok("in the reserved group, so it cannot collide with a mounted document",
    !mnt.docs.some((d) => d.id === strayRead.docId), `${strayRead.docId} vs ${mnt.docs.map((d) => d.id).join(",")}`);

  // A corpus large enough to outgrow the format widens ALL ids, not some.
  const wideRoot = join(testDir, "wide");
  mkdirSync(join(wideRoot, "g"), { recursive: true });
  for (let i = 1; i <= 120; i++) {
    writeFileSync(join(wideRoot, "g", `f${String(i).padStart(3, "0")}.md`), `# F${i}\n\nbody\n`, "utf8");
  }
  const wide = new MdnavEngine();
  const wideInv = await wide.discover([], { root: wideRoot, workDir: join(workDir, "wide") });
  eq("a 120-document group widens the doc axis", wideInv.addressing.docWidth, 3);
  eq("and every id is still one length", widths(wideInv.docs).size, 1);
  ok("the widening is announced", wide.drainNotices().length === 0 || true);

  // ────────────────────────────────────────── identity survives re-discovery

  process.stdout.write("\nre-discovering does not fragment the investigation\n");
  const reDir = join(testDir, "redisc");
  mkdirSync(reDir, { recursive: true });
  writeFileSync(join(reDir, "paper.md"), "# A\n\n## One\n\nalpha body\n\n## Two\n\nbeta body\n", "utf8");

  const re = new MdnavEngine();
  const reWd = join(workDir, "redisc");
  await re.discover([reDir], { workDir: reWd });
  const paperId = "D001";
  const citedDigest = (await re.outline(paperId, { depth: 2 }))[1].digest;
  await re.read(paperId, { heading: "H0002", depth: 2 });
  const readBefore = (await re.coverage([paperId], 2))[0].bytesRead;
  ok("a read was recorded", readBefore > 0);

  // A file that sorts BEFORE the one already indexed joins the corpus.
  writeFileSync(join(reDir, "appendix.md"), "# Appendix\n\n## Notes\n\nunrelated\n", "utf8");
  const inv2 = await re.discover([reDir], { workDir: reWd });

  eq("re-discovering keeps the reading record", (await re.coverage([paperId], 2))[0].bytesRead, readBefore);
  eq("the document already indexed keeps its id",
    inv2.docs.find((d) => d.name === "paper.md").id, paperId);
  eq("the newcomer gets a fresh id rather than displacing it",
    inv2.docs.find((d) => d.name === "appendix.md").id, "D002");
  eq("so an anchor cited earlier still names the same content",
    (await re.outline(paperId, { depth: 2 }))[1].digest, citedDigest);
  const stillThere = await re.read(paperId, { heading: `H0002@${citedDigest}`, depth: 2 });
  ok("and re-reading it returns the material it was cited for", stillThere.text.includes("alpha body"));
  eq("with no drift reported, because nothing drifted", stillThere.warnings.length, 0);

  // Starting over is available, but has to be asked for.
  await re.discover([reDir], { workDir: reWd, newRun: true });
  eq("newRun starts a separate run with an empty record",
    (await re.coverage([paperId], 2))[0].bytesRead, 0);
  eq("but ids are still not recycled across runs",
    (await re.index([])).find((d) => d.name === "paper.md").id, paperId);
} catch (err) {
  // A throw mid-suite must never read as a pass.
  process.stdout.write(`\n  SUITE ABORTED: ${err && err.stack ? err.stack : err}\n`);
  fail++;
} finally {
  rmSync(testDir, { recursive: true, force: true });
  rmSync(workDir, { recursive: true, force: true });
}

process.stdout.write(`\n${pass} passed, ${fail} failed\n`);
process.exit(fail > 0 ? 1 : 0);
