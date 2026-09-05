/**
 * Journal ledger suite.
 *
 * The two checks that matter most are the ones a single-process test can miss:
 * ids must be minted from what the FILE holds (not an in-memory counter), and a
 * rehydrated ledger must derive exactly the statuses the live session showed.
 * Everything else follows from those.
 */

import { join } from "node:path";
import { tmpdir } from "node:os";
import { mkdirSync, rmSync, writeFileSync, readFileSync, existsSync } from "node:fs";

import { MdnavEngine } from "../src/engine.ts";
import {
  formatJournalEntry,
  formatJournalReceipt,
  formatSourceChunkPrefix,
  formatChunkClose,
  closeChunk,
  formatAnchorList,
  formatAnchorString,
  canonicalAnchor,
  formatCompactStamp,
  parseAnchor,
  escapeBody,
  renderJournalTree,
  JOURNAL_HEADER,
} from "../src/formatting.ts";

let pass = 0,
  fail = 0;
const ok = (name, cond, detail) => {
  if (cond) {
    pass++;
    process.stdout.write(`  ok   ${name}\n`);
  } else {
    fail++;
    process.stdout.write(`  FAIL ${name}${detail ? `\n       ${detail}` : ""}\n`);
  }
};
const eq = (name, a, b) =>
  ok(name, a === b, `expected ${JSON.stringify(b)}, got ${JSON.stringify(a)}`);
function throws(name, fn, match) {
  try {
    fn();
    ok(name, false, "expected a throw, got a value");
  } catch (err) {
    ok(name, !match || match.test(err.message), `message was: ${err.message}`);
  }
}

const corpus = join(tmpdir(), "mdnav-journal-src-" + process.pid);
const wd = join(tmpdir(), "mdnav-journal-wd-" + process.pid);
mkdirSync(corpus, { recursive: true });

try {
  writeFileSync(
    join(corpus, "paper.md"),
    [
      "# Paper",
      "",
      "## Abstract",
      "A scale-calibrated geometric median.",
      "",
      "## Method",
      "Horizontal tangent lifts.",
      "",
    ].join("\n"),
    "utf8",
  );

  const engine = new MdnavEngine();
  await engine.discover([corpus], { workDir: wd });
  const anchorUnit = (await engine.outline("D001", { depth: 2 }))[1];
  const goodAnchor = `D001:${anchorUnit.id}@${anchorUnit.digest}`;

  // ────────────────────────────────────────────────────────────── recording

  process.stdout.write("\nrecording\n");
  const n1 = engine.recordJournal({
    op: "propose",
    concept: "C-001",
    body: "Median is scale-calibrated.",
    anchors: [goodAnchor],
  });
  const n2 = engine.recordJournal({
    op: "refine",
    concept: "C-001",
    refs: ["N001"],
    body: "Only under bounded curvature.",
  });
  const n3 = engine.recordJournal({
    op: "adopt",
    concept: "C-001",
    refs: ["N002"],
    body: "Adopted for the tracker.",
    anchors: [goodAnchor, "code:grassmann.py"],
  });

  eq("ids are minted in sequence", [n1, n2, n3].map((r) => r.entry.id).join(","), "N001,N002,N003");
  eq(
    "body bytes are measured, not guessed",
    n1.entry.bytes,
    Buffer.byteLength("Median is scale-calibrated.", "utf8"),
  );
  eq("a valid anchor draws no complaint", n1.anchorWarnings.length, 0);
  ok(
    "the timestamp is an ISO instant, comparable with the read ledger",
    /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/.test(n1.entry.ts) && n1.entry.ts.endsWith("Z"),
  );

  throws(
    "a ref to an entry that does not exist is refused",
    () => engine.recordJournal({ op: "refine", refs: ["N404"], body: "x" }),
    /does not exist/,
  );

  const stale = engine.recordJournal({
    op: "note",
    body: "cited from memory",
    anchors: [`D001:${anchorUnit.id}@dead`],
  });
  ok(
    "an already-stale citation is flagged at write time",
    stale.anchorWarnings.some((w) => /has changed under this anchor/.test(w)),
  );
  const unknownDoc = engine.recordJournal({
    op: "note",
    body: "elsewhere",
    anchors: ["D099:H0001@aaaa"],
  });
  ok(
    "an anchor into an unindexed document is flagged",
    unknownDoc.anchorWarnings.some((w) => /not indexed in this session/.test(w)),
  );
  eq(
    "a non-mdnav anchor is kept verbatim without complaint",
    engine.recordJournal({ op: "note", body: "see the code", anchors: ["code:grassmann.py"] })
      .anchorWarnings.length,
    0,
  );

  // ───────────────────────────────────────────────────────────── the receipt

  process.stdout.write("\nreceipts stay compact\n");
  const receipt = formatJournalReceipt(n3.entry);
  ok(
    "the receipt names the entry and its cost",
    receipt.includes("N003 (+") && receipt.includes(" B)"),
  );
  ok(
    "it names where the entry attached",
    receipt.includes("adopt") && receipt.includes("N002") && receipt.includes("C-001"),
  );
  ok(
    "it carries the anchors",
    receipt.includes(formatAnchorString(goodAnchor)) && receipt.includes("code : grassmann.py"),
  );
  ok("and it never echoes the body", !receipt.includes("Adopted for the tracker"));
  ok("the whole receipt is shorter than the body it acknowledges", receipt.length < 200);

  // ──────────────────────────────────────────────────────── derived statuses

  process.stdout.write("\nstatus is derived from children\n");
  const live = engine.resolveJournal();
  const statusOf = (id) => live.find((e) => e.id === id).status;
  eq("a refined proposal reads as refined", statusOf("N001"), "refined");
  eq("an adopted refinement reads as adopted", statusOf("N002"), "adopted");
  eq("a leaf entry stays active", statusOf("N003"), "active");
  ok(
    "the parent's own record was never rewritten",
    JSON.parse(readFileSync(engine.journalPath(), "utf8").split("\n")[0]).status === undefined,
  );

  // ─────────────────────────────────────────────────────────────── filtering

  process.stdout.write("\nfiltering\n");
  eq("by concept", engine.readJournal({ concept: "C-001" }).length, 3);
  eq(
    "by derived status",
    engine
      .readJournal({ concept: "C-001", status: "active" })
      .map((e) => e.id)
      .join(","),
    "N003",
  );
  eq(
    "by op",
    engine
      .readJournal({ op: "propose" })
      .map((e) => e.id)
      .join(","),
    "N001",
  );
  eq(
    "limit keeps the most recent",
    engine
      .readJournal({ limit: 2 })
      .map((e) => e.id)
      .join(","),
    "N005,N006",
  );

  // ────────────────────────────────────────────────── traversing the anchor graph

  process.stdout.write("\nanchor components are separately traversable\n");
  eq(
    "by scope — every entry citing a document",
    engine
      .readJournal({ docId: "D001" })
      .map((e) => e.id)
      .join(","),
    "N001,N003,N004",
  );
  eq(
    "by scope — a non-mdnav namespace is a scope too",
    engine
      .readJournal({ docId: "code" })
      .map((e) => e.id)
      .join(","),
    "N003,N006",
  );
  // N001 and N003 cite this unit at its live digest; N004 cites it at a stale
  // one. Asking for the unit finds all three — that edge is only reachable
  // because the digest is a separate component and not baked into the id.
  eq(
    "by unit — every version of one chunk, whatever the digest",
    engine
      .readJournal({ anchor: `D001:${anchorUnit.id}` })
      .map((e) => e.id)
      .join(","),
    "N001,N003,N004",
  );
  eq(
    "by unit — a bare unit id matches without naming its scope",
    engine
      .readJournal({ anchor: anchorUnit.id })
      .map((e) => e.id)
      .join(","),
    "N001,N003,N004",
  );
  eq(
    "by unit pinned to one version",
    engine
      .readJournal({ anchor: `D001:${anchorUnit.id}@dead` })
      .map((e) => e.id)
      .join(","),
    "N004",
  );
  eq(
    "by content identity — every chunk cited at one digest",
    engine
      .readJournal({ digest: "dead" })
      .map((e) => e.id)
      .join(","),
    "N004",
  );
  eq(
    "and the live digest picks out the citations that are still current",
    engine
      .readJournal({ digest: anchorUnit.digest })
      .map((e) => e.id)
      .join(","),
    "N001,N003",
  );
  eq(
    "components compose with the other filters",
    engine
      .readJournal({ anchor: anchorUnit.id, op: "propose" })
      .map((e) => e.id)
      .join(","),
    "N001",
  );
  eq(
    "a scope match does not leak across documents",
    engine.readJournal({ anchor: `D099:${anchorUnit.id}` }).length,
    0,
  );

  eq(
    "an anchor parses into its three components",
    JSON.stringify(parseAnchor("D014:H0003@a1b2")),
    JSON.stringify({ raw: "D014:H0003@a1b2", scope: "D014", unit: "H0003", digest: "a1b2" }),
  );
  eq(
    "a non-digest tail stays part of the unit",
    parseAnchor("url:https://x.dev/a@b").unit,
    "https://x.dev/a@b",
  );

  // ──────────────────────────────────────────────────── survives a restart

  process.stdout.write("\nthe notebook outlives the process\n");
  const restarted = new MdnavEngine();
  await restarted.discover([corpus], { workDir: wd });
  const n7 = restarted.recordJournal({ op: "note", body: "after a restart" });
  eq("a fresh engine continues the id sequence", n7.entry.id, "N007");

  const rehydrated = restarted.resolveJournal();
  eq("rehydration recovers every entry", rehydrated.length, 7);
  eq(
    "and derives the same statuses the live session showed",
    ["N001", "N002", "N003"].map((id) => rehydrated.find((e) => e.id === id).status).join(","),
    ["N001", "N002", "N003"].map(statusOf).join(","),
  );

  ok(
    "the notebook sits at the .doc-dive root, not inside a stamped run",
    existsSync(join(wd, "journal.jsonl")) && restarted.journalPath() === join(wd, "journal.jsonl"),
  );

  // ────────────────────────────────────────────────────────────────── merges

  process.stdout.write("\nmerges\n");
  const merged = restarted.recordJournal({
    op: "supersede",
    concept: "C-001",
    refs: ["N003", "N007"],
    body: "One statement replaces both.",
  });
  eq("an entry may reconcile two parents", merged.entry.refs.length, 2);
  const afterMerge = restarted.resolveJournal();
  eq(
    "both parents are superseded",
    ["N003", "N007"].map((id) => afterMerge.find((e) => e.id === id).status).join(","),
    "superseded,superseded",
  );

  const tree = renderJournalTree(afterMerge.filter((e) => e.concept === "C-001"));
  ok("the tree charts lineage", /N001 \| propose/.test(tree) && /└─|├─/.test(tree));
  ok("a merge is labelled as one", tree.includes("(merge of N003, N007)"));
  eq(
    "and the merged node is expanded exactly once",
    (tree.match(/N008 \| supersede/g) || []).length - (tree.match(/↩ shown above/g) || []).length,
    1,
  );

  // ───────────────────────────────────────────────────── concurrent writers

  process.stdout.write("\nconcurrent writers\n");
  const writerA = new MdnavEngine();
  const writerB = new MdnavEngine();
  writerA.readJournal({ workDir: wd });
  writerB.readJournal({ workDir: wd });
  const fromA = writerA.recordJournal({ workDir: wd, op: "note", body: "writer A" });
  const fromB = writerB.recordJournal({ workDir: wd, op: "note", body: "writer B" });
  eq("a stale peer reloads before minting", `${fromA.entry.id},${fromB.entry.id}`, "N009,N010");
  const persistedIds = readFileSync(writerA.journalPath(wd), "utf8")
    .trim()
    .split("\n")
    .map((line) => JSON.parse(line).id);
  eq("separate writers leave globally unique ids", new Set(persistedIds).size, persistedIds.length);

  const lockPath = `${writerA.journalPath(wd)}.lock`;
  writeFileSync(lockPath, "held", "utf8");
  throws(
    "an active writer lock fails loudly",
    () => writerA.recordJournal({ workDir: wd, op: "note", body: "must retry" }),
    /another writer.*retry/,
  );
  rmSync(lockPath, { force: true });

  // ──────────────────────────────────────────────────── token boundary marks

  process.stdout.write("\nmarks are isolated on both sides\n");
  const line = formatJournalEntry(afterMerge.find((e) => e.id === "N003"));
  eq("the ledger has nine fields", line.split(" | ").length, 9);
  ok("no field separator is ever unpadded", !/[^ ]\|/.test(line) && !/\|[^ ]/.test(line));
  ok("list items are separated by an isolated mark", line.includes(" ; "));
  ok(
    "an empty field is held open by a placeholder",
    formatJournalEntry(afterMerge.find((e) => e.id === "N007")).includes(" | - | "),
  );
  eq("the header names the same nine fields", JOURNAL_HEADER.split(" | ").length, 9);

  const prefix = formatSourceChunkPrefix("D023", "H0006@e5f6", [8420, 9860]);
  // The address is ONE field: ` | ` separates fields, the operators join the
  // components within one.
  eq("a chunk prefix reads as address then span", prefix, "D023 : H0006 @ e5f6 | 8420 .. 9860 |");
  eq(
    "the address is a single field, not two columns",
    prefix.split(" | ")[0],
    "D023 : H0006 @ e5f6",
  );
  ok("it opens the content field and stops there", prefix.endsWith(" |"));
  ok("no length is emitted — nothing downstream can count bytes", !/\| \d+ \|$/.test(prefix));
  eq(
    "a label sits between the address and the span",
    formatSourceChunkPrefix("D023", "H0006@e5f6", [8420, 9860], "abstract"),
    "D023 : H0006 @ e5f6 | abstract | 8420 .. 9860 |",
  );

  eq(
    "a block closes by repeating its address",
    formatChunkClose("D023", "H0006@e5f6"),
    "| D023 : H0006 @ e5f6",
  );
  eq(
    "so the content ends up bracketed by its own anchor",
    closeChunk("body\n", "D023", "H0006@e5f6"),
    "body\n| D023 : H0006 @ e5f6",
  );
  eq(
    "and a block not ending in a newline still gets its own line",
    closeChunk("body", "D023", "H0006@e5f6"),
    "body\n| D023 : H0006 @ e5f6",
  );
  ok("the range mark is isolated", prefix.includes(" .. "));
  ok("the identity mark is isolated", prefix.includes(" @ ") && !/[^ ]@|@[^ ]/.test(prefix));

  eq(
    "an anchor decomposes into addressable components",
    formatAnchorString("D014:H0003@a1b2"),
    "D014 : H0003 @ a1b2",
  );
  eq(
    "a namespaced anchor decomposes the same way",
    formatAnchorString("code:grassmann.py"),
    "code : grassmann.py",
  );
  eq("an anchor with no scope stays whole", formatAnchorString("H0003"), "H0003");
  eq(
    "anchors join as isolated items, each itself decomposed",
    formatAnchorList(["D014:H0003@a1b2", "code:x.py"]),
    "D014 : H0003 @ a1b2 ; code : x.py",
  );
  ok(
    "no containment mark is ever unpadded",
    !/[^ ]:|:[^ ]/.test(formatAnchorList(["D014:H0003@a1b2", "code:x.py"])),
  );
  eq("an empty anchor list still occupies its field", formatAnchorList([]), "-");
  eq(
    "stamps render compact and explicitly UTC",
    formatCompactStamp("2026-08-28T19:45:30.123Z"),
    "20260828_194530Z",
  );

  eq(
    "a multi-line body flattens with isolated break marks",
    escapeBody("first line\n\nsecond line"),
    "first line \\n \\n second line",
  );
  ok(
    "every break mark has a space on both sides",
    !/[^ ]\\n/.test(escapeBody("a\nb")) && !/\\n[^ ]/.test(escapeBody("a\nb")),
  );
  ok(
    "a body keeps its own pipes — it is the terminal field",
    escapeBody("a | b").includes("a | b"),
  );

  // ──────────────────────────────────── one address, however it is written
  //
  // The stream prints anchors spaced and the skill tells the reader to quote
  // them exactly, so the spaced form is the one that comes back. It has to
  // arrive at the same components, the same stored value, and the same
  // filters as the compact form — anything else makes the two instructions
  // contradict each other.

  process.stdout.write("\nan address is the same address however it arrives\n");

  const spaced = formatAnchorString(goodAnchor);
  ok("the stream prints anchors spaced", spaced.includes(" : ") && spaced.includes(" @ "));

  eq(
    "the spaced form parses to the same components as the compact one",
    JSON.stringify(parseAnchor(spaced)),
    JSON.stringify({ ...parseAnchor(goodAnchor), raw: spaced }),
  );
  eq("rendering an already-spaced anchor changes nothing", formatAnchorString(spaced), spaced);
  ok(
    "no containment or identity mark is ever doubled",
    !/ {2}[:@]|[:@] {2}/.test(formatAnchorString(spaced)),
  );

  eq(
    "components, the compact string and the spaced string canonicalize alike",
    [
      canonicalAnchor({ scope: "D001", unit: anchorUnit.id, digest: anchorUnit.digest }),
      canonicalAnchor(goodAnchor),
      canonicalAnchor(spaced),
    ].join(" "),
    [goodAnchor, goodAnchor, goodAnchor].join(" "),
  );
  eq(
    "a component anchor with no digest keeps its scope and unit",
    canonicalAnchor({ scope: "code", unit: "grassmann.py" }),
    "code:grassmann.py",
  );

  const staleParts = { scope: "D001", unit: anchorUnit.id, digest: "dead" };
  const staleFused = `D001:${anchorUnit.id}@dead`;

  const byParts = restarted.recordJournal({
    op: "note",
    body: "cited by components",
    anchors: [staleParts],
  });
  ok(
    "an anchor given as components is checked like any other",
    byParts.anchorWarnings.some((w) => /has changed under this anchor/.test(w)),
  );
  eq("and is stored in the one canonical form", byParts.entry.anchors[0], staleFused);

  const bySpaced = restarted.recordJournal({
    op: "note",
    body: "quoted exactly as the stream printed it",
    anchors: [formatAnchorString(staleFused)],
  });
  ok(
    "quoting the spaced form is checked too, not filed unchecked as vocabulary",
    bySpaced.anchorWarnings.some((w) => /has changed under this anchor/.test(w)),
  );
  eq("and it too is stored canonical", bySpaced.entry.anchors[0], staleFused);

  const byUnit = restarted.readJournal({ anchor: { unit: anchorUnit.id }, op: "note" });
  ok("a component filter finds those entries", byUnit.length > 0);
  eq(
    "and a bare string still reads its lone component as the unit",
    restarted
      .readJournal({ anchor: anchorUnit.id, op: "note" })
      .map((e) => e.id)
      .join(","),
    byUnit.map((e) => e.id).join(","),
  );
  // The same token, read as the edge it was given as: `H0002` names no scope,
  // so as a scope it matches nothing — while the bare string still finds it as
  // a unit. Components say which edge is meant; a string leaves it to be guessed.
  ok(
    "given as components, a scope filter is a scope filter and nothing else",
    restarted.readJournal({ anchor: { scope: "D001" } }).length > 0 &&
      restarted.readJournal({ anchor: { scope: anchorUnit.id } }).length === 0 &&
      restarted.readJournal({ anchor: anchorUnit.id }).length > 0,
  );
  eq(
    "scope is the name for it; docId still answers to it",
    restarted
      .readJournal({ scope: "code" })
      .map((e) => e.id)
      .join(","),
    restarted
      .readJournal({ docId: "code" })
      .map((e) => e.id)
      .join(","),
  );
} catch (err) {
  process.stdout.write(`\n  SUITE ABORTED: ${err && err.stack ? err.stack : err}\n`);
  fail++;
} finally {
  rmSync(corpus, { recursive: true, force: true });
  rmSync(wd, { recursive: true, force: true });
}

process.stdout.write(`\n${pass} passed, ${fail} failed\n`);
process.exit(fail > 0 ? 1 : 0);
