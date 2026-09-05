/**
 * Serving mdnav's own skill corpus over the MCP.
 *
 * The trigger skill a client installs is deliberately thin — a pointer. The
 * investigative discipline lives here, beside the engine it describes, so it is
 * revised with the code rather than drifting in however many client-side copies
 * exist. A caller that wants it asks for it.
 *
 * The corpus is Markdown and this is a Markdown navigator, so it is TRAVERSED
 * the way any corpus is: listed with sizes before it is read, outlined before a
 * section is taken. What it must NOT do is mount itself into the live session.
 * Minting `Dnnn` ids for skill files would put them in the inventory a reader is
 * investigating, and their bytes would land in the coverage arithmetic of a
 * corpus that never contained them — the tool would corrupt the measurement it
 * exists to teach.
 *
 * ── Why this surface is not framed ───────────────────────────────────────────
 * Corpus reads are framed because an anchor has to present the same tokens in an
 * outline, a chunk prefix and a journal line, so attention binds those mentions
 * into one citation graph. Every part of that argument is about material a
 * reader CITES. None of it holds here. Skill text is not evidence: nothing is
 * claimed about its bytes, so a digest has no drift to catch; its spans are not
 * re-read for an audit; it is not in anyone's coverage. Framing it would pay the
 * cost with none of the benefit — and worse, hand back something anchor-shaped
 * and citable in the very vocabulary the reader is about to use for real
 * anchors, inviting priming text into the evidence chain that follows it.
 *
 * Framing would also make this surface swing with `frameConfig()`, putting a
 * non-corpus output inside the prefixing ablation it has no business confounding.
 *
 * So topics are named, sections are handed back as the literal markdown they
 * are, and the heading ids exist only as handles for asking for the next piece.
 * This is priming, delivered before an investigation rather than inside one.
 */

import { existsSync, readFileSync, readdirSync, statSync } from "node:fs";
import { basename, dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { scanDocument } from "./scanner.ts";
import type { DocumentIndex, HeadingEntry } from "./types.ts";

const HERE = dirname(fileURLToPath(import.meta.url));

/** The topic name for the skill's own SKILL.md, which is its entry point. */
export const INDEX_TOPIC = "index";

export interface SkillTopic {
  topic: string;
  path: string;
  bytes: number;
  title: string;
  headings: number;
}

/**
 * Where the corpus lives. `MDNAV_SKILL_DIR` overrides, the same way
 * `MDNAV_WORK_DIR` does, so a fork can serve its own discipline without
 * patching the server.
 */
export function skillRoot(): string {
  const env = process.env["MDNAV_SKILL_DIR"];
  return env ? resolve(env) : resolve(HERE, "../skills/doc-dive");
}

/**
 * What the skill calls itself, from its own frontmatter.
 *
 * Leading the marquee with this rather than the directory name means a
 * relocated corpus announces what it is, not where it happens to sit.
 */
export function skillName(): string {
  const root = skillRoot();
  const indexFile = join(root, "SKILL.md");
  if (existsSync(indexFile)) {
    const { buf, index } = loadDocument(INDEX_TOPIC, indexFile);
    if (index.frontmatter) {
      const fm = buf.subarray(index.frontmatter.start, index.frontmatter.end).toString("utf8");
      const named = /^name:\s*(.+)$/m.exec(fm);
      if (named) return named[1]!.trim();
    }
  }
  return basename(root);
}

/** Topic names use forward slashes and carry no extension, on every platform. */
function normalizeTopic(raw: string): string {
  return raw
    .replace(/\.md$/i, "")
    .replace(/\\/g, "/")
    .replace(/^\/+|\/+$/g, "");
}

/**
 * The document's own name for itself.
 *
 * A skill file opens with frontmatter, so the first non-empty line is `---` and
 * naming a topic after it names every topic the same thing. The scanner already
 * located the frontmatter; start after it.
 */
function firstHeading(buf: Buffer, index: DocumentIndex): string {
  const body = buf.subarray(index.frontmatter?.end ?? 0).toString("utf8");
  for (const line of body.split("\n")) {
    const t = line.trim();
    if (t.length === 0) continue;
    if (t.startsWith("#")) return t.replace(/^#+\s*/, "").trim();
    return t;
  }
  return "";
}

// Scanning is pure over bytes, so the result is cached against the file's mtime
// and size. A skill file changes when it is edited, which is rare, and a reader
// consulting three sections should not pay to re-scan the document three times.
const scanCache = new Map<string, { key: string; buf: Buffer; index: DocumentIndex }>();

function loadDocument(topic: string, path: string): { buf: Buffer; index: DocumentIndex } {
  const st = statSync(path);
  const key = `${st.mtimeMs}:${st.size}`;
  const hit = scanCache.get(path);
  if (hit && hit.key === key) return hit;

  const buf = readFileSync(path);
  // The id is the TOPIC, not a `Dnnn` coordinate — see the note at the top.
  const index = scanDocument(buf, { id: topic, path, mtimeMs: st.mtimeMs });
  scanCache.set(path, { key, buf, index });
  return { buf, index };
}

function markdownFilesUnder(dir: string): string[] {
  if (!existsSync(dir)) return [];
  const out: string[] = [];
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const full = join(dir, entry.name);
    if (entry.isDirectory()) out.push(...markdownFilesUnder(full));
    else if (/\.md$/i.test(entry.name)) out.push(full);
  }
  return out.sort();
}

/** Every topic, the index first and the references after it in path order. */
export function listTopics(): SkillTopic[] {
  const root = skillRoot();
  const out: SkillTopic[] = [];

  const describe = (topic: string, path: string): SkillTopic => {
    const { buf, index } = loadDocument(topic, path);
    return {
      topic,
      path,
      bytes: buf.length,
      title: firstHeading(buf, index),
      headings: index.headings.length,
    };
  };

  const indexFile = join(root, "SKILL.md");
  if (existsSync(indexFile)) out.push(describe(INDEX_TOPIC, indexFile));

  const refs = join(root, "references");
  for (const path of markdownFilesUnder(refs)) {
    out.push(describe(normalizeTopic(relative(refs, path)), path));
  }

  return out;
}

/** Resolve a topic name to its file, naming what is available when it misses. */
export function resolveTopic(raw: string): SkillTopic {
  const topic = normalizeTopic(raw);
  const topics = listTopics();

  const exact = topics.find((t) => t.topic.toLowerCase() === topic.toLowerCase());
  if (exact) return exact;

  // A caller who names the file, or the last segment of a nested topic, meant
  // the topic. Guessing here is safe: the alternative is an error listing the
  // very name they typed.
  const loose = topics.find((t) => t.topic.toLowerCase().endsWith(`/${topic.toLowerCase()}`));
  if (loose) return loose;

  const known = topics.map((t) => t.topic).join(", ") || "none — the skill corpus is missing";
  throw new Error(`no skill topic ${topic} — available: ${known}`);
}

export interface SkillSection {
  topic: string;
  heading: HeadingEntry;
  span: [number, number];
  text: string;
}

/** One topic's headings, with the byte extent of each subtree. */
export function outlineTopic(raw: string, depth = 6): { heading: HeadingEntry; bytes: number }[] {
  const t = resolveTopic(raw);
  const { index } = loadDocument(t.topic, t.path);
  return index.headings
    .filter((h) => h.level <= depth)
    .map((h) => ({ heading: h, bytes: h.subtreeEnd - h.headingStart }));
}

/**
 * One section, as bytes.
 *
 * The whole subtree is taken, not the unit alone: a skill section that loses its
 * subsections is advice with its qualifications removed, which is worse than not
 * serving it.
 */
export function readSection(raw: string, hid: string): SkillSection {
  const t = resolveTopic(raw);
  const { buf, index } = loadDocument(t.topic, t.path);

  const want = hid.trim().toLowerCase();
  const heading =
    index.headings.find((h) => h.hid.toLowerCase() === want) ??
    index.headings.find((h) => h.title.toLowerCase().includes(want));

  if (!heading) {
    const known = index.headings.map((h) => `${h.hid} ${h.title}`).join(" ; ");
    throw new Error(`no section ${hid} in ${t.topic} — headings: ${known}`);
  }

  const span: [number, number] = [heading.headingStart, heading.subtreeEnd];
  return { topic: t.topic, heading, span, text: buf.subarray(span[0], span[1]).toString("utf8") };
}

/** A whole topic, for when the discipline is what you came for. */
export function readTopic(raw: string): { topic: SkillTopic; text: string } {
  const topic = resolveTopic(raw);
  const { buf } = loadDocument(topic.topic, topic.path);
  return { topic, text: buf.toString("utf8") };
}

export interface SkillHit {
  topic: string;
  hid: string;
  line: number;
  text: string;
}

/** Matching lines across the corpus, each reported under the section holding it. */
export function searchSkills(pattern: string, limit = 60): SkillHit[] {
  const re = new RegExp(pattern, "i");
  const hits: SkillHit[] = [];

  for (const t of listTopics()) {
    const { buf, index } = loadDocument(t.topic, t.path);
    const text = buf.toString("utf8");

    let offset = 0;
    const lines = text.split("\n");
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i]!;
      if (re.test(line)) {
        // Report the containing section, so a hit is an address and not just a
        // line number that shifts the next time the file is edited.
        const owner = index.headings
          .filter((h) => h.headingStart <= offset && offset < h.subtreeEnd)
          .pop();
        hits.push({ topic: t.topic, hid: owner?.hid ?? "H0000", line: i + 1, text: line.trim() });
        if (hits.length >= limit) return hits;
      }
      offset += Buffer.byteLength(line, "utf8") + 1;
    }
  }

  return hits;
}
