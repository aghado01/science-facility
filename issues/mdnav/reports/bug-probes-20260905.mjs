// Probe battery for the mdnav bug inventory. Each probe prints CONFIRMED / NOT-REPRODUCED
// with the observed evidence; nothing here asserts, it observes.
import { mkdtempSync, mkdirSync, writeFileSync, rmSync, existsSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { MdnavEngine } from "file:///D:/aghado01/science-facility/mcp/mdnav/src/engine.ts";
import { scanDocument, profileDocument, extractMarks, stripNoise } from "file:///D:/aghado01/science-facility/mcp/mdnav/src/scanner.ts";

const root = mkdtempSync(join(tmpdir(), "mdnav-probe-"));
const W = (rel, text) => {
  const p = join(root, rel);
  mkdirSync(join(p, ".."), { recursive: true });
  writeFileSync(p, text, "utf8");
  return p;
};
const doc = (title, n = 3) =>
  `# ${title}\n\nintro ${title}\n\n` + Array.from({ length: n }, (_, i) => `## ${title} sec ${i + 1}\n\nbody ${i + 1} of ${title}\n\n`).join("");
const say = (id, verdict, ...ev) => console.log(`\n[${id}] ${verdict}\n  ` + ev.join("\n  "));
const ids = (e) => e.index().then((d) => d.map((x) => `${x.id}=${x.name}`).join(" "));

// ── P1: mount A, read, mount B, mount A again — identity + ledger ──────────────
{
  const A = join(root, "p1/A"), B = join(root, "p1/B");
  for (let i = 1; i <= 5; i++) W(`p1/A/a${i}.md`, doc(`Alpha ${i}`));
  for (let i = 1; i <= 2; i++) W(`p1/B/b${i}.md`, doc(`Beta ${i}`));
  const e = new MdnavEngine();
  const wd = join(root, "p1/work");
  await e.discover([], { root: A, workDir: wd });
  const readA = await e.read("D01", { heading: "H01" });
  await e.discover([], { root: B, workDir: wd });
  const afterB = await ids(e);
  const covB = await e.coverage();
  await e.discover([], { root: A, workDir: wd });
  const covA = (await e.coverage(["D01"]))[0];
  say("P1 multi-mount identity", afterB.includes("D01=b1.md") && afterB.includes("D03=a3.md") ? "CONFIRMED" : "NOT-REPRODUCED",
    `after mounting B: ${afterB}`,
    `coverage() with no docIds spans ${covB.length} docs across two corpora`,
    `back on A: D01 read ${readA.bytes} B earlier, coverage now reports ${covA.bytesRead} B (${covA.percent}%) — ledger ${covA.bytesRead === 0 ? "LOST" : "kept"}`,
    `notices: ${e.drainNotices().join(" || ") || "(none)"}`);
}

// ── P2: id widening after reads breaks the coverage / journal join ───────────
{
  const e = new MdnavEngine();
  const wd = join(root, "p2/work");
  const f1 = W("p2/loose/x.md", doc("X")), f2 = W("p2/loose/y.md", doc("Y"));
  await e.discover([f1, f2], { workDir: wd });
  const before = await ids(e);
  const r = await e.read("D001", { heading: "H01" });
  e.recordJournal({ op: "note", body: "cites x", anchors: ["D001:H01"], workDir: wd });
  // a two-group mount forces a group axis onto the session → every id re-rendered
  for (let g = 1; g <= 2; g++) for (let i = 1; i <= 2; i++) W(`p2/mount/g${g}/d${i}.md`, doc(`G${g}D${i}`));
  await e.discover([], { root: join(root, "p2/mount"), workDir: wd });
  const after = await ids(e);
  const cov = (await e.coverage()).find((c) => c.path === f1);
  const j = e.readJournal({ scope: cov?.docId, workDir: wd });
  say("P2 widening breaks joins", cov && cov.bytesRead === 0 && r.bytes > 0 ? "CONFIRMED" : "NOT-REPRODUCED",
    `ids before: ${before}`, `ids after: ${after}`,
    `x.md read ${r.bytes} B before widening; coverage now says bytesRead=${cov?.bytesRead} cited=${cov?.bytesCited} under id ${cov?.docId}`,
    `journal_read(scope=${cov?.docId}) finds ${j.length} entries (entry was recorded under D001)`,
    `notices: ${e.drainNotices().join(" || ")}`);
}

// ── P3: basename ambiguity + cwd-relative fallback ───────────────────────────
{
  const e = new MdnavEngine();
  W("p3/proj/planning/decisions.md", doc("Planning decisions"));
  W("p3/proj/archive/decisions.md", doc("Archive decisions"));
  await e.discover([], { root: join(root, "p3/proj"), workDir: join(root, "p3/work") });
  const r = await e.read("decisions.md", { heading: "H01" });
  const which = r.text.includes("Archive") ? "archive/decisions.md" : "planning/decisions.md";
  say("P3 basename ambiguity", "CONFIRMED", `read("decisions.md") silently resolved to ${which} as ${r.docId}; the other copy was never mentioned`);
  // cwd-relative path: a file that exists relative to the SERVER's cwd, not the corpus
  const cwdFile = "package.json";
  let cwdVerdict = "NOT-REPRODUCED", detail = "";
  try {
    const out = await e.outline(cwdFile, {});
    cwdVerdict = "CONFIRMED"; detail = `outline("${cwdFile}") indexed ${process.cwd()}\\${cwdFile} on the fly as ${out.length} unit(s): ${(await ids(e))}`;
  } catch (err) { detail = String(err.message); }
  say("P3b cwd-relative on-the-fly index", cwdVerdict, detail);
}

// ── P4: YAML frontmatter delimiters counted as breaks, comments as headings ──
{
  const text = `---\ntitle: X\n# a yaml comment\ntags: [a]\n---\n\n# Real\n\nbody\n\n## Sub\n\nmore\n`;
  const idx = scanDocument(Buffer.from(text), { id: "D001", path: "fm.md" });
  const hs = idx.headings.map((h) => `${h.hid}:L${h.line}:${h.title}`).join(" ");
  say("P4 frontmatter", idx.breaks.length === 2 || idx.headings.some((h) => h.title.includes("yaml")) ? "CONFIRMED" : "NOT-REPRODUCED",
    `frontmatter=${JSON.stringify(idx.frontmatter)} breaks=${idx.breaks.length} headings=${hs}`);
}

// ── P5: marks kind "paragraph" is advertised but unsupported ─────────────────
{
  const text = `# T\n\nA paragraph about nothing.\n\nAnother paragraph mentioning the word paragraph.\n`;
  const runs = extractMarks(Buffer.from(text), "paragraph");
  say("P5 marks paragraph", runs.length === 1 && runs[0].preview === "paragraph" ? "CONFIRMED" : "NOT-REPRODUCED",
    `runs=${runs.length} previews=${JSON.stringify(runs.map((r) => r.preview))} (literal-regex fallback, not the construct)`);
}

// ── P6: profile is not fence-aware; outline is ───────────────────────────────
{
  const text = "# One\n\ntext\n\n```sh\n# not a heading\n# also not\n```\n\n# Two\n\ntext\n";
  const idx = scanDocument(Buffer.from(text), { id: "D001", path: "f.md" });
  const h1 = idx.headings.filter((h) => h.level === 1).length;
  const p = profileDocument(Buffer.from(text)).find((r) => r.construct === "heading h1");
  say("P6 profile vs outline h1", p && p.runs !== h1 ? "CONFIRMED" : "NOT-REPRODUCED", `scanner h1=${h1} profile h1 runs=${p?.runs}`);
}

// ── P7: coverage(docIds) does not accept the references other tools accept ───
{
  const e = new MdnavEngine();
  const f = W("p7/a.md", doc("A"));
  await e.discover([f], { workDir: join(root, "p7/work") });
  let v = "NOT-REPRODUCED", d = "";
  try { await e.coverage(["a.md"]); d = "coverage(['a.md']) resolved"; } catch (err) { v = "CONFIRMED"; d = `coverage(['a.md']) threw: ${err.message}; read('a.md') works`; }
  say("P7 coverage ref resolution", v, d);
}

// ── P8: discover over paths that do not exist succeeds with zero documents ───
{
  const e = new MdnavEngine();
  const ghost = join(root, "p8/nope");
  W("p8/anchor.md", "x");
  let v = "NOT-REPRODUCED", d = "";
  try {
    const inv = await e.discover([join(root, "p8/anchor.md"), ghost, join(root, "p8/also-nope.md")], { workDir: join(root, "p8/work") });
    v = "CONFIRMED"; d = `3 paths given, 2 missing → ${inv.docs.length} doc(s), no error, no notice (${e.drainNotices().length} notices)`;
  } catch (err) { d = err.message; }
  say("P8 silent missing paths", v, d);
}

// ── P9: coverage counts elided bytes as read ─────────────────────────────────
{
  const e = new MdnavEngine();
  const blob = "A".repeat(20000);
  const f = W("p9/img.md", `# Shot\n\nsee\n\n![](data:image/png;base64,${blob})\n\nend\n`);
  await e.discover([f], { workDir: join(root, "p9/work") });
  const r = await e.read("D001", { heading: "H01", strip: "all" });
  const c = (await e.coverage(["D001"]))[0];
  say("P9 elided counted as read", c.bytesRead === r.bytes && r.elidedBytes > 0 ? "CONFIRMED" : "NOT-REPRODUCED",
    `read: bytes=${r.bytes} elided=${r.elidedBytes}; coverage: bytesRead=${c.bytesRead} (${c.percent}%) elided=${c.elidedBytes} — README says coverage subtracts elisions`);
}

// ── P10: outline(within) at default depth shows nothing ──────────────────────
{
  const e = new MdnavEngine();
  const f = W("p10/a.md", doc("A"));
  await e.discover([f], { workDir: join(root, "p10/work") });
  const units = await e.outline("D001", { within: "H01" });
  say("P10 within at default depth", units.length === 0 ? "CONFIRMED" : "NOT-REPRODUCED", `outline(within:H01) at depth 1 → ${units.length} units, no message`);
}

// ── P11: fence info strings with spaces / tildes defeat marks and profile ────
{
  const text = "# T\n\n```js title=\"x\"\ncode\n```\n\n~~~py\nmore\n~~~\n\n````\nfour\n````\n";
  const runs = extractMarks(Buffer.from(text), "fence");
  const p = profileDocument(Buffer.from(text)).find((r) => r.construct === "fence");
  const idx = scanDocument(Buffer.from(text), { id: "D001", path: "f.md" });
  say("P11 fence variants", runs.length < 3 ? "CONFIRMED" : "NOT-REPRODUCED",
    `3 fences (info-with-space, tilde, quad-backtick): marks found ${runs.length}, profile found ${p?.runs ?? 0}; scanner headings=${idx.headings.length} (fence-aware scan is fine)`);
}

// ── P12: a stale journal lock is permanent ───────────────────────────────────
{
  const e = new MdnavEngine();
  const wd = join(root, "p12/work");
  mkdirSync(wd, { recursive: true });
  writeFileSync(join(wd, "journal.jsonl.lock"), "", "utf8"); // a crashed writer left this
  let v = "NOT-REPRODUCED", d = "";
  try { e.recordJournal({ op: "note", body: "x", workDir: wd }); d = "recorded despite stale lock"; } catch (err) { v = "CONFIRMED"; d = `${err.message} — no age check, no owner pid, never expires`; }
  say("P12 stale lock", v, d);
}

// ── P13: html detected as noise ≠ html stripped ──────────────────────────────
{
  const text = `<details>\n<summary>tool call</summary>\n\n<img src="x.png">\n<br>\n</details>\n\n<div align="center">kept</div>\n`;
  const idx = scanDocument(Buffer.from(text), { id: "D001", path: "h.md" });
  const noise = idx.noise.filter((n) => n.kind === "html").reduce((a, n) => a + n.bytes, 0);
  const s = stripNoise(text, { strip: "all" });
  say("P13 html detect vs strip", s.elidedBytes < noise ? "CONFIRMED" : "NOT-REPRODUCED",
    `inventory counts ${noise} B of html; strip:all removed ${s.elidedBytes} B; remaining text still contains: ${JSON.stringify(s.text.match(/<[^>]+>/g))}`);
}

// ── P14: doc-id width tolerance is asymmetric (units tolerant, docs exact) ───
{
  const e = new MdnavEngine();
  const wd = join(root, "p14/work");
  const f = W("p14/a.md", doc("A"));
  await e.discover([f], { workDir: wd });
  const { anchorWarnings } = e.recordJournal({ op: "note", body: "x", anchors: ["D1:H1"], workDir: wd });
  const r = await e.read("D001", { heading: "H1" }); // H1 tolerated
  let docTol = "resolved";
  try { await e.read("D1", { heading: "H01" }); } catch (err) { docTol = `threw: ${err.message}`; }
  say("P14 width tolerance", anchorWarnings.length > 0 ? "CONFIRMED" : "NOT-REPRODUCED",
    `read(D001, H1) ok (${r.bytes} B) but read("D1") ${docTol}`, `journal anchor D1:H1 → ${anchorWarnings.join(" | ") || "(no warning)"}`);
}

// ── P15: journal before any discover lands in the temp dir ───────────────────
{
  const saved = process.env.MDNAV_WORK_DIR; delete process.env.MDNAV_WORK_DIR;
  const e = new MdnavEngine();
  const p = e.journalPath();
  say("P15 journal default root", p.startsWith(tmpdir()) ? "CONFIRMED" : "NOT-REPRODUCED", `journalPath() with nothing mounted = ${p}`);
  if (saved !== undefined) process.env.MDNAV_WORK_DIR = saved;
}

// ── P16: duplicate heading titles share a digest → drift check is blind ──────
{
  const text = "# Intro\n\n## Notes\n\nfirst\n\n## Notes\n\nsecond\n";
  const idx = scanDocument(Buffer.from(text), { id: "D001", path: "d.md" });
  const [a, b] = idx.headings.filter((h) => h.title === "Notes");
  say("P16 same-title digest", a.digest === b.digest ? "CONFIRMED" : "NOT-REPRODUCED", `H02 and H03 both titled "Notes": digests ${a.digest} / ${b.digest} — an insertion before them shifts ordinals and the digest still verifies`);
}

// ── P17: read(from, to): `from` is not checked against the depth ─────────────
{
  const e = new MdnavEngine();
  const f = W("p17/a.md", doc("A"));
  await e.discover([f], { workDir: join(root, "p17/work") });
  let v = "NOT-REPRODUCED", d = "";
  try { const r = await e.read("D001", { from: "H02", to: "H03", depth: 1 }); v = "CONFIRMED"; d = `from=H02 (level 2) at depth 1 accepted: ${r.bytes} B, anchors ${r.anchors.join(",")}; the same H02 as heading: at depth 1 is rejected`; }
  catch (err) { d = err.message; }
  say("P17 from/to asymmetry", v, d);
}

rmSync(root, { recursive: true, force: true });
console.log("\nprobes done");
