/**
 * Skill-serving suite.
 *
 * The load-bearing check is `isolation`: serving the skill corpus must leave the
 * reader's investigation untouched. The skill files are Markdown sitting beside
 * the engine, and the cheap way to serve them would be to mount them — which
 * would mint `Dnnn` ids for them, put them in the inventory, and count their
 * bytes in the coverage arithmetic of a corpus that never contained them.
 * Everything else here is behaviour; that one is the design constraint.
 */

import { join } from "node:path";
import { tmpdir } from "node:os";
import { mkdirSync, rmSync, writeFileSync } from "node:fs";

import { MdnavEngine } from "../src/engine.ts";
import {
  INDEX_TOPIC,
  listTopics,
  outlineTopic,
  readSection,
  readTopic,
  searchSkills,
  skillRoot,
} from "../src/skills.ts";

let pass = 0, fail = 0;
const ok = (name, cond, detail) => {
  if (cond) { pass++; process.stdout.write(`  ok   ${name}\n`); }
  else { fail++; process.stdout.write(`  FAIL ${name}${detail ? `\n       ${detail}` : ""}\n`); }
};
const eq = (name, a, b) => ok(name, a === b, `expected ${JSON.stringify(b)}, got ${JSON.stringify(a)}`);
function throws(name, fn, match) {
  try { fn(); ok(name, false, "expected a throw, got a value"); }
  catch (err) { ok(name, !match || match.test(err.message), `message was: ${err.message}`); }
}

const corpus = join(tmpdir(), "mdnav-skills-corpus-" + process.pid);
const wd = join(tmpdir(), "mdnav-skills-wd-" + process.pid);
const fakeSkills = join(tmpdir(), "mdnav-skills-alt-" + process.pid);
mkdirSync(corpus, { recursive: true });

try {
  // ────────────────────────────────────────────────────────── the corpus itself

  process.stdout.write("\nthe shipped skill corpus\n");

  const topics = listTopics();
  ok("the corpus is found beside the engine", topics.length > 0);
  eq("the discipline itself is the index topic", topics[0].topic, INDEX_TOPIC);
  ok("every topic reports its size and unit count",
    topics.every((t) => t.bytes > 0 && Number.isInteger(t.headings)));
  ok("the references are listed alongside it",
    topics.some((t) => t.topic === "state-and-audit"));

  // A skill file opens with frontmatter, so a naive first-line title makes every
  // topic `---` and the listing useless for choosing between them.
  ok("titles come from the document, not from its frontmatter fence",
    topics.every((t) => t.title.length > 0 && !t.title.startsWith("---")));

  // ─────────────────────────────────────────────────────────────── addressing

  process.stdout.write("\ntopics are addressed, not just dumped\n");

  const full = readTopic("state-and-audit");
  ok("a topic reads whole when that is what you want", full.text.includes("Reversibility"));

  const shallow = outlineTopic("state-and-audit", 2);
  const deep = outlineTopic("state-and-audit", 6);
  ok("an outline lists headings with their extents",
    shallow.length > 0 && shallow.every((r) => r.bytes > 0));
  ok("and depth actually narrows it", deep.length > shallow.length);

  const byTitle = readSection("state-and-audit", "Journal Ledger");
  const byHid = readSection("state-and-audit", byTitle.heading.hid);
  eq("a section resolves by heading id", byHid.heading.hid, byTitle.heading.hid);
  eq("and by a word from its title", byTitle.span.join(".."), byHid.span.join(".."));

  // Advice separated from its qualifications is worse than no advice, so a
  // section carries its subsections rather than stopping at the next heading.
  ok("a section carries its whole subtree",
    byTitle.text.includes("Ops and what they settle") && byTitle.text.length > 1000);
  ok("the section is bytes from the file, not a summary",
    full.text.includes(byTitle.text));

  throws("an unknown topic names what is available",
    () => readTopic("nope"), /no skill topic nope — available: /);
  throws("an unknown section names the headings it does have",
    () => readSection("state-and-audit", "H9999"), /no section H9999 in state-and-audit — headings: /);

  // ────────────────────────────────────────────────────────────────── search

  process.stdout.write("\nsearch returns addresses\n");

  const hits = searchSkills("reverse walk");
  ok("a pattern finds passages across the corpus", hits.length > 0);
  ok("each hit names the section holding it, not just a line number",
    hits.every((h) => /^[HSW]\d+$/.test(h.hid) && h.line > 0 && h.topic.length > 0));
  ok("matching is case-insensitive", searchSkills("REVERSE WALK").length === hits.length);
  eq("a pattern that matches nothing returns nothing", searchSkills("zzzunlikelyzzz").length, 0);
  ok("the hit limit is honoured", searchSkills("the", 5).length === 5);

  // ───────────────────────────────────────────────────────────────── isolation

  process.stdout.write("\nserving skills leaves the investigation alone\n");

  writeFileSync(join(corpus, "paper.md"), "# Paper\n\n## Abstract\nA claim about medians.\n", "utf8");
  const engine = new MdnavEngine();
  const before = await engine.discover([corpus], { workDir: wd });
  const coverageBefore = await engine.coverage();

  listTopics();
  readTopic(INDEX_TOPIC);
  readSection("state-and-audit", "Journal Ledger");
  searchSkills("anchor");

  const after = await engine.index();
  eq("no skill file has entered the inventory", after.length, before.docs.length);
  ok("the inventory still holds only the corpus",
    after.every((d) => d.path.includes("paper.md")));
  eq("no skill document has been minted an id",
    after.filter((d) => /state-and-audit|doc-dive|SKILL/.test(d.path)).length, 0);

  const coverageAfter = await engine.coverage();
  eq("coverage still measures the corpus and nothing else",
    JSON.stringify(coverageAfter.map((c) => [c.docId, c.totalBytes])),
    JSON.stringify(coverageBefore.map((c) => [c.docId, c.totalBytes])));

  // ─────────────────────────────────────────────────────────────── relocation

  process.stdout.write("\nthe corpus can be pointed elsewhere\n");

  mkdirSync(join(fakeSkills, "references"), { recursive: true });
  writeFileSync(join(fakeSkills, "SKILL.md"), "---\nname: alt\n---\n\n# Alternate Discipline\n\nbody\n", "utf8");
  writeFileSync(join(fakeSkills, "references", "one.md"), "# One\n\ntext\n", "utf8");

  const realRoot = skillRoot();
  process.env.MDNAV_SKILL_DIR = fakeSkills;
  try {
    const alt = listTopics();
    eq("MDNAV_SKILL_DIR relocates the corpus", alt.map((t) => t.topic).join(","), "index,one");
    eq("and the relocated index is read from there", readTopic("index").text.includes("Alternate Discipline"), true);
    ok("the override actually changed roots", skillRoot() !== realRoot);
  } finally {
    delete process.env.MDNAV_SKILL_DIR;
  }
  eq("clearing the override restores the shipped corpus", skillRoot(), realRoot);
} catch (err) {
  process.stdout.write(`\n  SUITE ABORTED: ${err && err.stack ? err.stack : err}\n`);
  fail++;
} finally {
  rmSync(corpus, { recursive: true, force: true });
  rmSync(wd, { recursive: true, force: true });
  rmSync(fakeSkills, { recursive: true, force: true });
}

process.stdout.write(`\n${pass} passed, ${fail} failed\n`);
process.exit(fail > 0 ? 1 : 0);
