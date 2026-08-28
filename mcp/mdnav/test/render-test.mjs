/**
 * What reaches the context stream.
 *
 * The anchor decomposition is not primarily a query convenience — it is a
 * property of the text the model reads. `D023` has to present the SAME tokens
 * in an outline, a chunk prefix, a locate hit, a coverage row, a drift warning
 * and a journal line, or self-attention cannot bind those mentions to each
 * other and the corpus graph stops being legible without a tool call.
 *
 * So this suite drives the real MCP tool handlers and asserts on the exact text
 * they emit. A fused anchor anywhere is a defect, wherever it comes from.
 */

import { join } from "node:path";
import { tmpdir } from "node:os";
import { mkdirSync, rmSync, writeFileSync } from "node:fs";

import { MdnavEngine } from "../src/engine.ts";
import { registerMdnavTools } from "../src/tools.ts";

let pass = 0, fail = 0;
const ok = (name, cond, detail) => {
  if (cond) { pass++; process.stdout.write(`  ok   ${name}\n`); }
  else { fail++; process.stdout.write(`  FAIL ${name}${detail ? `\n       ${detail}` : ""}\n`); }
};
const eq = (name, a, b) => ok(name, a === b, `expected ${JSON.stringify(b)}, got ${JSON.stringify(a)}`);

// A fused anchor in either of its two shapes. Neither may appear in any output.
const FUSED_SCOPE = /D\d{3}:[HSW]\d{4}/;
const FUSED_DIGEST = /[HSW]\d{4}@[0-9a-f]{4}/;

const corpus = join(tmpdir(), "mdnav-render-src-" + process.pid);
const wd = join(tmpdir(), "mdnav-render-wd-" + process.pid);
mkdirSync(corpus, { recursive: true });

try {
  writeFileSync(
    join(corpus, "paper.md"),
    [
      "# Paper", "", "## Abstract", "A scale-calibrated geometric median.", "",
      "> a quoted passage worth marking", "",
      "---", "", "## Method", "Horizontal tangent lifts for geodesics.", "",
    ].join("\n"),
    "utf8"
  );

  // Capture the real handlers the MCP server would register.
  const handlers = new Map();
  const engine = new MdnavEngine();
  registerMdnavTools({ tool: (name, _desc, _schema, fn) => handlers.set(name, fn) }, engine);
  const call = async (name, args) => (await handlers.get(name)(args)).content[0].text;

  const emitted = {};
  emitted.discover = await call("mdnav_discover", { paths: [corpus], workDir: wd });
  emitted.outline = await call("mdnav_outline", { docId: "D001", depth: 2 });
  emitted.marks = await call("mdnav_marks", { docId: "D001", kind: "blockquote", minBytes: 0 });
  emitted.locate = await call("mdnav_locate", { pattern: "geodesics", max: 50 });
  emitted.read = await call("mdnav_read", { docId: "D001", heading: "H0002", depth: 2, prefixFormat: true });
  emitted.drift = await call("mdnav_read", { docId: "D001", heading: "H0002@dead", depth: 2 });
  emitted.batch = await call("mdnav_batch_read", {
    requests: [{ docId: "D001", heading: "H0002", label: "abstract" }], depth: 2, prefixFormat: false,
  });
  emitted.batchPrefixed = await call("mdnav_batch_read", {
    requests: [{ docId: "D001", heading: "H0002", label: "abstract" }], depth: 2, prefixFormat: true,
  });
  emitted.segments = await call("mdnav_outline", { docId: "D001", byBreaks: true });
  emitted.record = await call("mdnav_journal_record", {
    op: "propose", concept: "C-001", body: "Scale-calibrated.", anchors: ["D001:H0002@dead"],
  });
  emitted.journal = await call("mdnav_journal_read", { limit: 100 });
  emitted.tree = await call("mdnav_journal_tree", {});
  emitted.coverage = await call("mdnav_coverage", { docIds: ["D001"], depth: 2 });
  emitted.error = await call("mdnav_read", { docId: "D001", heading: "H9999" });

  // ───────────────────────────────────────────── no emitter may fuse an anchor

  process.stdout.write("\nno emitter fuses an anchor\n");
  for (const [name, text] of Object.entries(emitted)) {
    const scope = FUSED_SCOPE.exec(text);
    const digest = FUSED_DIGEST.exec(text);
    ok(`${name} keeps every component isolated`, !scope && !digest,
      scope ? `fused scope: ${scope[0]}` : digest ? `fused digest: ${digest[0]}` : "");
  }

  // ────────────────────────────────── the same chunk presents the same tokens

  process.stdout.write("\nthe same chunk presents the same surface form everywhere\n");
  // H0002's digest, taken from the outline the model would have read first.
  const digest = /H0002 @ ([0-9a-f]{4})/.exec(emitted.outline)?.[1];
  ok("outline names the chunk with an isolated digest", digest !== undefined, emitted.outline);
  const surface = `H0002 @ ${digest}`;

  ok("the read prefix presents it identically", emitted.read.includes(surface));
  ok("the batch prefix presents it identically", emitted.batchPrefixed.includes(surface));
  ok("the batch comment tag presents it identically", emitted.batch.includes(surface));
  ok("the drift warning presents it identically", emitted.drift.includes(surface));

  const docSurface = "D001";
  for (const [name, text] of [["outline", emitted.read], ["locate", emitted.locate], ["coverage", emitted.coverage], ["journal", emitted.journal]]) {
    ok(`${name} names the document as a standalone token`,
      new RegExp(`(^|[ |])${docSurface}([ |]|$)`, "m").test(text), text.slice(0, 120));
  }

  // ──────────────────────────────────────────────────── marks stay isolated

  process.stdout.write("\nmarks stay isolated\n");
  ok("spans use an isolated range mark", emitted.marks.includes(" .. ") && !/\d\.\.\d/.test(emitted.marks));
  ok("the read prefix span does too", emitted.read.includes(" .. ") && !/\d\.\.\d/.test(emitted.read));
  ok("outline drops the brackets that would merge into the id", !/\[[HSW]\d{4}/.test(emitted.outline));
  ok("locate does not weld its line marker to the number", !/\bL\d/.test(emitted.locate));

  // ──────────────────────────────────────── provenance headers are the default

  process.stdout.write("\nprovenance headers are the default\n");
  const HEADER_RE = /D001 \| H\d{4} @ [0-9a-f]{4} \| \d+ \.\. \d+ \| \d+/;
  const plain = await call("mdnav_read", { docId: "D001", heading: "H0002", depth: 2 });
  ok("a read that asks for nothing still carries its header", HEADER_RE.test(plain), plain.slice(0, 160));
  ok("opting out per call works",
    !HEADER_RE.test(await call("mdnav_read", { docId: "D001", heading: "H0002", depth: 2, prefixFormat: false })));

  process.env["MDNAV_PREFIX"] = "off";
  ok("MDNAV_PREFIX=off silences the whole session",
    !HEADER_RE.test(await call("mdnav_read", { docId: "D001", heading: "H0002", depth: 2 })));
  delete process.env["MDNAV_PREFIX"];
  ok("and unsetting it brings them back",
    HEADER_RE.test(await call("mdnav_read", { docId: "D001", heading: "H0002", depth: 2 })));

  // A discontiguous read has no single span; labelling it with the outer bound
  // would claim the material between the units as read.
  const multi = await call("mdnav_read", { docId: "D001", headings: ["H0002", "H0003"], depth: 2 });
  const heads = multi.match(/D001 \| H\d{4} @ [0-9a-f]{4} \| \d+ \.\. \d+ \| \d+/g) ?? [];
  eq("a multi-unit read labels every span, not the outer bound", heads.length, 2);
  for (const h of heads) {
    const m = /\| (\d+) \.\. (\d+) \| (\d+)$/.exec(h);
    ok(`each header states its own span width (${h.slice(0, 22)}…)`, Number(m[3]) === Number(m[2]) - Number(m[1]), h);
  }

  // ────────────────────────────────────────── read vs cited is now arithmetic

  process.stdout.write("\nread vs cited\n");
  const fresh = new MdnavEngine();
  const h2 = new Map();
  registerMdnavTools({ tool: (n, _d, _s, fn) => h2.set(n, fn) }, fresh);
  const call2 = async (name, args) => (await h2.get(name)(args)).content[0].text;
  await call2("mdnav_discover", { paths: [corpus], workDir: join(wd, "arith") });

  const zero = (await fresh.coverage(["D001"], 2))[0];
  eq("nothing read", zero.bytesRead, 0);
  eq("nothing cited", zero.bytesCited, 0);

  // Read both sections; cite only one.
  await call2("mdnav_read", { docId: "D001", heading: "H0002", depth: 2 });
  await call2("mdnav_read", { docId: "D001", heading: "H0003", depth: 2 });
  const outline2 = await call2("mdnav_outline", { docId: "D001", depth: 2 });
  const d2 = /H0002 @ ([0-9a-f]{4})/.exec(outline2)[1];
  await call2("mdnav_journal_record", { op: "propose", body: "cited the abstract", anchors: [`D001:H0002@${d2}`] });

  const rep = (await fresh.coverage(["D001"], 2))[0];
  ok("bytes cited is a strict subset of bytes read", rep.bytesCited > 0 && rep.bytesCited < rep.bytesRead);
  eq("one entry cites this document", rep.citations, 1);
  eq("cited bytes are fully inside read bytes", rep.citedNotRead, 0);
  eq("the read-but-uncited remainder is the rest", rep.readNotCited, rep.bytesRead - rep.bytesCited);
  ok("the report surfaces the attrition diagnostic",
    (await call2("mdnav_coverage", { docIds: ["D001"], depth: 2 })).includes("read not cited"));

  // Cite a section that was never read.
  const d3 = /H0003 @ ([0-9a-f]{4})/.exec(outline2)[1];
  const fresh2 = new MdnavEngine();
  const h3 = new Map();
  registerMdnavTools({ tool: (n, _d, _s, fn) => h3.set(n, fn) }, fresh2);
  const call3 = async (name, args) => (await h3.get(name)(args)).content[0].text;
  await call3("mdnav_discover", { paths: [corpus], workDir: join(wd, "capture") });
  await call3("mdnav_read", { docId: "D001", heading: "H0002", depth: 2 });
  await call3("mdnav_journal_record", { op: "propose", body: "cited unread", anchors: [`D001:H0003@${d3}`] });
  const rep2 = (await fresh2.coverage(["D001"], 2))[0];
  ok("citing an unread span is reported as salience capture", rep2.citedNotRead > 0);
  ok("and the report says so",
    (await call3("mdnav_coverage", { docIds: ["D001"], depth: 2 })).includes("cited not read"));
  // ─────────────────────────────────────── a source that moves under the cache

  process.stdout.write("\na source that changes under us\n");
  const live = join(corpus, "live.md");
  writeFileSync(live, "# Live\n\n## Alpha\n\noriginal body\n", "utf8");
  const hS = new Map();
  const eS = new MdnavEngine();
  registerMdnavTools({ tool: (n, _d, _s, fn) => hS.set(n, fn) }, eS);
  const callS = async (n, a) => (await hS.get(n)(a)).content[0].text;

  await callS("mdnav_discover", { paths: [live], workDir: join(wd, "stale") });
  const beforeDigest = /H0002 @ ([0-9a-f]{4})/.exec(await callS("mdnav_outline", { docId: "D001", depth: 2 }))[1];

  writeFileSync(live, "# Live\n\n## Alpha RENAMED\n\ncompletely different body\n", "utf8");

  const afterRead = await callS("mdnav_read", { docId: "D001", heading: "H0002", depth: 2 });
  ok("a read after the source changed returns the CURRENT bytes", afterRead.includes("completely different body"), afterRead);
  ok("and the change is announced in-band", /changed on disk and was re-indexed/.test(afterRead));
  const afterDigest = /H0002 @ ([0-9a-f]{4})/.exec(await callS("mdnav_outline", { docId: "D001", depth: 2 }))[1];
  ok("the digest moved with the source, so drift is detectable again", beforeDigest !== afterDigest);
  ok("the notice fires once, not on every later call",
    !/changed on disk/.test(await callS("mdnav_outline", { docId: "D001", depth: 2 })));

  // ─────────────────────────────────────── elision is addressed, not hidden

  process.stdout.write("\nelision is addressed, not hidden\n");
  const noisy = join(corpus, "noisy.md");
  writeFileSync(noisy, `# Noisy\n\n![pic](data:image/png;base64,${"A".repeat(4000)})\n\ntail text\n`, "utf8");
  const hN = new Map();
  const eN = new MdnavEngine();
  registerMdnavTools({ tool: (n, _d, _s, fn) => hN.set(n, fn) }, eN);
  const callN = async (n, a) => (await hN.get(n)(a)).content[0].text;
  await callN("mdnav_discover", { paths: [noisy], workDir: join(wd, "noise") });

  const strippedOut = await callN("mdnav_read", { docId: "D001", heading: "H0001", depth: 1, strip: "all" });
  ok("the stream carries a marker where the removed span was", strippedOut.includes("mdnav elided | data-uri |"));
  ok("the marker names its byte cost", /mdnav elided \| data-uri \| \d+ B/.test(strippedOut));
  ok("the marker is not an HTML comment the html pass would eat", !strippedOut.includes("<!-- mdnav: elided"));
  ok("the read reports the total elided", /elided [\d.]+ KiB \(data-uri x1\)/.test(strippedOut));
  ok("surrounding content survives", strippedOut.includes("tail text"));
  const unstripped = await callN("mdnav_read", { docId: "D001", heading: "H0001", depth: 1, strip: "none" });
  ok("the same anchor without strip still yields the bytes", unstripped.length > strippedOut.length + 3000);
} catch (err) {
  process.stdout.write(`\n  SUITE ABORTED: ${err && err.stack ? err.stack : err}\n`);
  fail++;
} finally {
  rmSync(corpus, { recursive: true, force: true });
  rmSync(wd, { recursive: true, force: true });
}

process.stdout.write(`\n${pass} passed, ${fail} failed\n`);
process.exit(fail > 0 ? 1 : 0);
