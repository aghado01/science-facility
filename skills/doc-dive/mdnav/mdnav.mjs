#!/usr/bin/env node
// mdnav — structure-aware navigation over Markdown corpora.
//
// Design rule: presume about the reading process, never about the content.
// Sizes, spans, counts, ratios and structural anomalies are properties of the
// material as an object and are fair game. Relevance, topic, importance and
// reading order are the reader's job and are never computed here.
//
// Addressing is a single shared space: every anchor is `Dnnn:Hnnnn[@digest]`
// resolving to a half-open byte span [start, end). Planning, reading, coverage,
// provenance and batch re-reading all speak those same coordinates.

import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync, mkdirSync, existsSync, readdirSync, statSync, appendFileSync, realpathSync } from 'node:fs';
import { resolve, join, basename, dirname, sep } from 'node:path';
import { tmpdir } from 'node:os';

const SCHEMA = 2;
const LF = 10, CR = 13;

// ─────────────────────────────────────────────────────────── small utilities

const warn = (m) => process.stderr.write(`mdnav: ${m}\n`);
const die = (m) => { process.stderr.write(`mdnav: error: ${m}\n`); process.exit(2); };
const sha256 = (b) => createHash('sha256').update(b).digest('hex');
const digestOf = (s) => sha256(Buffer.from(s, 'utf8')).slice(0, 4);

function fmtBytes(n) {
  if (n < 1024) return `${n} B`;
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(2)} KiB`;
  return `${(n / 1048576).toFixed(2)} MiB`;
}
const fmtNum = (n) => n.toLocaleString('en-US');

function parseArgs(argv) {
  const out = { _: [], f: {} };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a.startsWith('--')) {
      const eq = a.indexOf('=');
      if (eq !== -1) { out.f[a.slice(2, eq)] = a.slice(eq + 1); continue; }
      const k = a.slice(2), nx = argv[i + 1];
      if (nx !== undefined && !nx.startsWith('--')) { out.f[k] = nx; i++; } else out.f[k] = true;
    } else if (a === '-i') out.f.i = true;
    else out._.push(a);
  }
  return out;
}

const intFlag = (f, names, dflt) => {
  for (const n of names) if (f[n] !== undefined && f[n] !== true) {
    const v = parseInt(f[n], 10);
    if (Number.isNaN(v)) die(`--${n} expects a number`);
    return v;
  }
  return dflt;
};

// ────────────────────────────────────────────────────────── work dir + state

// Runtime artifacts: <root>/<slug>/<UTC stamp>/
//
// Two rules, both learned the hard way elsewhere in this repo. First, the root is
// never a bare relative path — jso-jackson carries a comment about exactly this,
// where an empty variable produced a relative 'tmp' and "scattered run artifacts
// under the caller's current directory". Second, runs are stamped rather than
// overwriting a fixed 'current', so an investigation's history survives and two
// runs cannot collide.
//
// Locality is preserved by the slug, not by physical adjacency to the sources:
// artifacts group by what they are about, and never land in the material being
// read (see assertOutsideCorpus).

const stampNow = () => new Date().toISOString().replace(/[-:]/g, '').replace(/T/, '_').slice(0, 15);
const ARTIFACT_DIR = '.doc-dive';
const globalPtr = () => join(tmpdir(), 'mdnav', 'LAST');

// Anchor: the directory of the corpus. Artifacts live beside the documents they
// describe, because that is where you will look for them — but under a dot
// directory, which `discover` skips, so a later scan can never index the reader's
// own exhaust as source material. Scattering loose files into the source
// directory is the failure; adjacency is not.
const anchorFor = (targets) => {
  const t = resolve(targets[0]);
  try { return statSync(t).isDirectory() ? t : dirname(t); } catch { return dirname(t); }
};

function workRoot(f, anchor) {
  if (f['work-dir'] && f['work-dir'] !== true) return resolve(String(f['work-dir']));
  if (process.env.MDNAV_WORK_DIR) return resolve(process.env.MDNAV_WORK_DIR);
  return anchor ? join(anchor, ARTIFACT_DIR) : null;
}

// `mint` for entry points (discover/index). Later verbs have no target to anchor
// on, so they follow a pointer rather than requiring the path to be retyped:
// the run's own LATEST when a root is known, else a single global LAST.
function workDir(f, { mint = false, anchor = null } = {}) {
  const root = workRoot(f, anchor);

  if (!mint && !root) {
    const p = globalPtr();
    if (!existsSync(p)) die(`no run found — start one with 'discover' or 'index', or pass --work-dir <path>`);
    const dir = readFileSync(p, 'utf8').trim();
    if (!existsSync(dir)) die(`the last run directory no longer exists: ${dir}`);
    return dir;
  }

  const latest = join(root, 'LATEST');
  let rel;
  if (f.run && f.run !== true) rel = String(f.run);
  else if (mint) {
    // Second-resolution stamps collide when runs are started in quick succession,
    // and a silently reused directory would merge two investigations. Disambiguate
    // deterministically rather than with randomness, so the order stays readable.
    const base = stampNow();
    rel = base;
    for (let n = 2; existsSync(join(root, rel)); n++) rel = `${base}-${n}`;
  }
  else if (existsSync(latest)) rel = readFileSync(latest, 'utf8').trim();
  else die(`no run found under ${root} — start one with 'discover' or 'index', or pass --run <stamp>`);

  const dir = resolve(root, rel);
  try { mkdirSync(join(dir, 'documents'), { recursive: true }); }
  catch (e) {
    // A curated reference library may be read-only, or simply somewhere the
    // reader does not want touched at all. Say so and name the override rather
    // than relocating silently — where artifacts land is the caller's call.
    die(`cannot create the run directory: ${dir}\n       ${e.code ?? e.message}\n` +
      `       Anchor elsewhere with --work-dir <path> or $MDNAV_WORK_DIR ` +
      `(e.g. a project's own .claude/ directory).`);
  }
  if (mint || !existsSync(latest)) writeFileSync(latest, rel);
  mkdirSync(dirname(globalPtr()), { recursive: true });
  writeFileSync(globalPtr(), dir);
  return dir;
}

// Adjacent is fine; visible is not. If the work dir sits inside the corpus it
// must be under a dot segment, or a later `discover` will index the artifacts as
// documents and the reader ends up studying its own output.
function assertNotDiscoverable(wd, targets) {
  const norm = (p) => resolve(p).replace(/\\/g, '/').replace(/\/+$/, '');
  const w = norm(wd);
  for (const t of targets) {
    const d = norm(anchorFor([t]));
    if (!w.startsWith(d + '/')) continue;
    const rel = w.slice(d.length + 1);
    if (!rel.split('/').some((seg) => seg.startsWith('.'))) die(
      `artifacts would be written inside the corpus where 'discover' can see them.\n` +
      `       work dir: ${wd}\n       corpus:   ${d}\n` +
      `       Use a dot-prefixed directory (the default is <corpus>/${ARTIFACT_DIR}/) or --work-dir <elsewhere>.`);
  }
}

const invPath = (wd) => join(wd, 'inventory.json');
const idxPath = (wd, id) => join(wd, 'documents', `${id}.index.json`);
const readsPath = (wd) => join(wd, 'reads.jsonl');

function loadInventory(wd) {
  const p = invPath(wd);
  if (!existsSync(p)) return { schema: SCHEMA, docs: [] };
  try { return JSON.parse(readFileSync(p, 'utf8')); }
  catch { warn(`inventory unreadable, starting fresh: ${p}`); return { schema: SCHEMA, docs: [] }; }
}
const saveInventory = (wd, inv) => writeFileSync(invPath(wd), JSON.stringify(inv, null, 2));

function canonical(p) {
  try { return realpathSync(resolve(p)); } catch { return resolve(p); }
}

function nextId(inv) {
  let n = 0;
  for (const d of inv.docs) { const m = /^D(\d+)$/.exec(d.id); if (m) n = Math.max(n, +m[1]); }
  return `D${String(n + 1).padStart(3, '0')}`;
}

// ───────────────────────────────────────────────────────────── noise detection
//
// Composition, not meaning. These patterns are recognised by shape alone — a
// base64 payload is a base64 payload regardless of what the document is about —
// so detecting them presumes nothing about content. What they are *worth* is the
// reader's call; the tool only reports how many bytes of the document are made
// of them, and can elide them from a read on request.
//
// An embedded image is the pathological case: the payload IS the document by
// byte count, and ingesting it costs the entire context for no information.

// Distinct species, not one category. An image can be *embedded* as a base64
// payload or *referenced* by URL; both render identically, but the first inlines
// the entire file into the document and the second costs a few dozen bytes. Only
// the first is a threat, and treating them alike would strip a useful reference
// for no saving.
const NOISE = {
  // An embedded file. The whole markdown image wrapper goes when the target is a
  // data URI, so no `![]()` debris is left behind; a bare payload (HTML attribute,
  // link target) is matched on its own.
  'data-uri': /!\[[^\]]*\]\(\s*data:[\w.+-]+\/[\w.+-]+;base64,[^)\s]*\)|data:[\w.+-]+\/[\w.+-]+;base64,[A-Za-z0-9+/=]{64,}/g,
  // HTML furniture: tags and comments. Inner text is preserved; only markup goes.
  html: /<!--[\s\S]*?-->|<\/?[a-zA-Z][^<>]*>/g,
  // A credentialed, expiring object-store link. Detected by the signing parameters
  // themselves, not by length — a long GitHub permalink is signal, a presigned URL
  // is dead by construction once it expires. Shares the `[]()`/`![]()` shape with
  // ordinary citations, so the target decides, and the `!` decides the remedy:
  // an image has nothing worth keeping, a link's label names what was cited.
  'signed-url': {
    re: /!?\[[^\]]*\]\(\s*[^)\s]*\)|https?:\/\/[^\s)"'<>\]]+/g,
    test: (m) => /X-Amz-(?:Signature|Credential|Security-Token)|X-Goog-Signature|[?&]Signature=[^&)\s]{16,}|[?&]sig=[^&)\s]{16,}/.test(m),
    keep: (m) => (m.startsWith('!') ? '' : (/^\[([^\]]*)\]/.exec(m)?.[1] ?? '')),
  },
  // A reference to an external image. Cheap, and it records that a figure was
  // there — so this is OPT-IN ONLY and deliberately excluded from --strip all.
  'image-ref': /!\[[^\]]*\]\(\s*(?!data:)[^)\s]*(?:\s+"[^"]*")?\)/g,
};
const reOf = (k) => (NOISE[k] instanceof RegExp ? NOISE[k] : NOISE[k].re);
const testOf = (k) => (NOISE[k] instanceof RegExp ? null : NOISE[k].test);
const keepOf = (k) => (NOISE[k] instanceof RegExp ? null : NOISE[k].keep);

// What --strip all removes: species that are unambiguously machine noise.
const STRIP_ALL = ['data-uri', 'html', 'signed-url'];

// Line-scoped so byte offsets stay exact without decoding the whole file at once.
// Multi-line HTML elements are not matched — reported rather than pretended away.
function noiseSpans(buf, from, to, kinds) {
  const found = [];
  for (let p = from; p < to;) {
    let nl = buf.indexOf(LF, p);
    if (nl === -1 || nl > to) nl = to;
    const text = buf.toString('utf8', p, nl);
    for (const kind of kinds) {
      if (!NOISE[kind]) continue;
      const re = reOf(kind), test = testOf(kind);
      re.lastIndex = 0;
      for (let m; (m = re.exec(text));) {
        if (m[0].length === 0) { re.lastIndex++; continue; }
        if (test && !test(m[0])) continue;          // shape matched, target didn't
        const s = p + Buffer.byteLength(text.slice(0, m.index), 'utf8');
        found.push({ kind, start: s, end: s + Buffer.byteLength(m[0], 'utf8'), text: m[0] });
      }
    }
    p = nl + 1;
  }
  // A data URI inside an <img> tag matches both; keep the outer span only.
  found.sort((a, b) => a.start - b.start || b.end - a.end);
  const out = [];
  for (const s of found) if (!out.length || s.start >= out[out.length - 1].end) out.push(s);
  return out;
}

function noiseProfile(buf) {
  const p = {};
  for (const k of Object.keys(NOISE)) p[k] = { count: 0, bytes: 0 };
  for (const s of noiseSpans(buf, 0, buf.length, Object.keys(NOISE))) {
    p[s.kind].count++; p[s.kind].bytes += s.end - s.start;
  }
  // The headline ratio reflects what --strip all would actually remove, so it is
  // not inflated by species the reader may well want to keep.
  const total = STRIP_ALL.reduce((a, k) => a + p[k].bytes, 0);
  return { ...p, bytes: total, ratio: buf.length ? total / buf.length : 0 };
}

// ────────────────────────────────────────────────────────── construct profile
//
// Given an unknown Markdown document, nothing can be assumed about which
// constructs carry structure. Headings may be titles or delimiters; blockquotes
// may be turns or pull-quotes; a `<details>` block may be a tool call or an
// aside. So the profiler measures composition and CADENCE and reports both,
// leaving recognition to the reader.
//
// Cadence is the discriminator that heading counts cannot supply: a construct
// recurring at even intervals is partitioning the document; one appearing in
// bursts is content. Both are byte-level facts, not interpretations.

const LINE_KIND = [
  ['heading', /^ {0,3}#{1,6}(\s|$)/],
  ['blockquote', /^ {0,3}>/],
  ['break', /^ {0,3}(-{3,}|\*{3,}|_{3,})\s*$/],
  ['table', /^ {0,3}\|.*\|\s*$/],
  ['list', /^ {0,3}([-*+]|\d{1,9}[.)])(\s|$)/],
  ['html', /^ {0,3}<[!/a-zA-Z]/],
];
const SINGLETON = new Set(['heading', 'break']);      // never merge into runs

function constructRuns(buf) {
  const runs = [];
  let fenceChar = null, fenceLen = 0, cur = null;
  const close = () => { cur = null; };
  const push = (kind, start, end, info) => {
    if (!SINGLETON.has(kind) && cur && cur.kind === kind) { cur.end = end; cur.lines++; return; }
    cur = { kind, start, end, lines: 1, info };
    runs.push(cur);
  };

  for (let i = 0; i < buf.length;) {
    let j = buf.indexOf(LF, i);
    const eol = j === -1 ? buf.length : j, next = j === -1 ? buf.length : j + 1;
    let ce = eol; if (ce > i && buf[ce - 1] === CR) ce--;
    const t = buf.toString('utf8', i, ce);

    const fm = /^ {0,3}(`{3,}|~{3,})(.*)$/.exec(t);
    if (fm && fenceChar === null) {
      fenceChar = fm[1][0]; fenceLen = fm[1].length;
      close(); push('fence', i, next, fm[2].trim().split(/\s+/)[0] || '');
    } else if (fenceChar !== null) {
      if (cur && cur.kind === 'fence') cur.end = next;
      if (fm && fm[1][0] === fenceChar && fm[1].length >= fenceLen && fm[2].trim() === '') { fenceChar = null; fenceLen = 0; close(); }
    } else if (t.trim() === '') {
      close();
    } else {
      const hit = LINE_KIND.find(([, re]) => re.test(t));
      push(hit ? hit[0] : 'paragraph', i, next);
    }
    if (j === -1) break;
    i = next;
  }
  return runs;
}

const COMP_LABEL = { paragraph: 'prose', fence: 'code', blockquote: 'quote', list: 'list', table: 'tbl', html: 'html', heading: 'head', break: 'rule' };

// What one unit is MADE OF, so a reader can decide whether to open it without
// opening it. Noise spans are reassigned out of whatever construct contains them
// — an embedded PNG sits inside a paragraph line, and reporting that unit as
// "prose 100%" would be exactly backwards.
function compositionOf(buf, runs, noise, from, to) {
  const bucket = {};
  const add = (k, n) => { if (n > 0) bucket[k] = (bucket[k] ?? 0) + n; };
  // Noise keeps its own species in the sketch: an embedded file and a scatter of
  // HTML tags are both "not prose", but only one of them is a context hazard.
  const NOISE_LABEL = { 'data-uri': 'data', html: 'html', 'signed-url': 'link', 'image-ref': 'img' };
  for (const r of runs) {
    const s = Math.max(r.start, from), e = Math.min(r.end, to);
    if (e <= s) continue;
    let junk = 0;
    for (const n of noise) {
      const a = Math.max(n.start, s), b = Math.min(n.end, e);
      if (b > a) { junk += b - a; add(NOISE_LABEL[n.kind] ?? 'data', b - a); }
    }
    add(COMP_LABEL[r.kind] ?? r.kind, (e - s) - junk);
  }
  const total = Object.values(bucket).reduce((a, n) => a + n, 0) || 1;
  return Object.entries(bucket)
    .sort((a, b) => b[1] - a[1])
    .filter(([, n]) => n / total >= 0.05)
    .slice(0, 3)
    .map(([k, n]) => `${k}${Math.round((n / total) * 100)}`)
    .join(' ');
}

// Coefficient of variation of the gaps between successive occurrences. Near zero
// means evenly spaced — the construct is dividing the document. Above ~1 means
// bursty — it is decoration inside something else.
function cadence(starts, docBytes) {
  if (starts.length < 4) return null;
  const gaps = starts.slice(1).map((s, k) => s - starts[k]);
  const mean = gaps.reduce((a, n) => a + n, 0) / gaps.length;
  const sd = Math.sqrt(gaps.reduce((a, n) => a + (n - mean) ** 2, 0) / gaps.length);
  const sorted = [...gaps].sort((a, b) => a - b);
  return { median: sorted[Math.floor(sorted.length / 2)], cv: mean ? sd / mean : 0, span: (starts[starts.length - 1] - starts[0]) / docBytes };
}

// ───────────────────────────────────────────────────────── structural scanner
//
// Raw bytes in, structure out. Lines are decoded only for recognition; every
// offset returned is a byte offset into the original buffer, so a read can
// always reproduce the source exactly.

function analyze(buf) {
  const len = buf.length;
  const bom = len >= 3 && buf[0] === 0xef && buf[1] === 0xbb && buf[2] === 0xbf;

  // Pass 1 — line table.
  const lines = [];
  let crlf = 0, lone = 0;
  for (let i = 0; i < len;) {
    let j = buf.indexOf(LF, i);
    const eol = j === -1 ? len : j;
    let ce = eol;
    if (ce > i && buf[ce - 1] === CR) { ce--; crlf++; } else if (j !== -1) lone++;
    lines.push({ start: i, contentEnd: ce, next: j === -1 ? len : j + 1 });
    if (j === -1) break;
    i = j + 1;
  }

  const text = (k) => buf.toString('utf8', lines[k].start, lines[k].contentEnd);

  // Pass 2 — fences, frontmatter, ATX headings, setext suspects, separators.
  const ATX = /^ {0,3}(#{1,6})(?:[ \t]+(.*?))?[ \t]*$/;
  const FENCE = /^ {0,3}(`{3,}|~{3,})(.*)$/;
  const SETEXT = /^ {0,3}(=+|-+)[ \t]*$/;

  const raw = [], setextSuspects = [], breakEnds = [];
  let fenceChar = null, fenceLen = 0, frontmatter = null, maxLine = { bytes: 0, line: 0 };
  let start = 0;

  if (lines.length && text(0).trim() === '---') {           // YAML frontmatter
    for (let k = 1; k < lines.length; k++) {
      const t = text(k).trim();
      if (t === '---' || t === '...') { frontmatter = { start: 0, end: lines[k].next }; start = k + 1; break; }
    }
  }

  for (let k = start; k < lines.length; k++) {
    const t = text(k);
    const nbytes = lines[k].contentEnd - lines[k].start;
    if (nbytes > maxLine.bytes) maxLine = { bytes: nbytes, line: k + 1 };
    const fm = FENCE.exec(t);
    if (fm) {
      const ch = fm[1][0], n = fm[1].length;
      if (fenceChar === null) { fenceChar = ch; fenceLen = n; }
      else if (ch === fenceChar && n >= fenceLen && fm[2].trim() === '') { fenceChar = null; fenceLen = 0; }
      continue;
    }
    if (fenceChar !== null) continue;                        // inside a fence

    const prevBlank = k === start || text(k - 1).trim() === '';
    if (t.trim() === '---' && prevBlank) breakEnds.push(lines[k].next);   // thematic break

    const am = ATX.exec(t);
    if (am) {
      let title = (am[2] ?? '').replace(/[ \t]+#+[ \t]*$/, '').trim();
      raw.push({ level: am[1].length, title, line: k + 1, headingStart: lines[k].start, bodyStart: lines[k].next });
      continue;
    }
    if (SETEXT.test(t) && !prevBlank && !ATX.test(text(k - 1)) && !FENCE.test(text(k - 1)))
      setextSuspects.push({ line: k + 1, text: text(k - 1).slice(0, 120) });
  }
  if (fenceChar !== null) warn(`unclosed code fence — headings after it were treated as fenced content`);

  // Pass 3 — identity, structural extents, synthetic units.
  const headings = raw.map((h, k) => ({
    hid: `H${String(k + 1).padStart(4, '0')}`,
    level: h.level, title: h.title, digest: digestOf(h.title),
    line: h.line, headingStart: h.headingStart, bodyStart: h.bodyStart, subtreeEnd: len,
  }));
  for (let k = 0; k < headings.length; k++)
    for (let m = k + 1; m < headings.length; m++)
      if (headings[m].level <= headings[k].level) { headings[k].subtreeEnd = headings[m].headingStart; break; }

  // Nothing may be silently dropped because a document lacks expected structure.
  const firstStart = headings.length ? headings[0].headingStart : len;
  const leading = buf.subarray(0, firstStart).toString('utf8').trim();
  if (!headings.length) {
    headings.push({ hid: 'H0000', level: 0, title: 'BODY', digest: digestOf('BODY'), line: 1, headingStart: 0, bodyStart: 0, subtreeEnd: len });
  } else if (firstStart > 0 && leading !== '') {
    headings.unshift({ hid: 'H0000', level: 0, title: 'PREAMBLE', digest: digestOf('PREAMBLE'), line: 1, headingStart: 0, bodyStart: 0, subtreeEnd: firstStart });
  }

  const counts = {};
  for (const h of headings) if (h.level > 0) counts[`h${h.level}`] = (counts[`h${h.level}`] ?? 0) + 1;

  // Spine — bytes occupied by level-1 heading lines. In chat exports the H1 line
  // is the complete user turn, so this is the intent trajectory's byte cost.
  let spineBytes = 0;
  for (const h of headings) if (h.level === 1) spineBytes += h.bodyStart - h.headingStart;

  // Two independent structural facts — level-1 headings, and thematic breaks —
  // both usable as a partition basis. Whether they should correspond is the
  // reader's hypothesis about the document's provenance, not this tool's: a
  // Markdown file is not assumed to be a chat envelope, a manuscript, or anything
  // else. We report the counts and their relation; naming an expected shape and
  // calling deviations "corrupt" would be presuming the content.
  const h1 = counts.h1 ?? 0;
  const nb = breakEnds.length;
  const aligned = nb === 0 ? null : h1 === nb + 1 ? 'aligned' : h1 > nb + 1 ? 'more-h1' : 'more-breaks';

  return {
    bytes: len, bom, newline: crlf && lone ? 'mixed' : crlf ? 'CRLF' : 'LF',
    headings, counts, setextSuspects, frontmatter, maxLine,
    spine: { bytes: spineBytes, ratio: len ? spineBytes / len : 0 },
    breaks: { count: nb, ends: breakEnds, aligned },
  };
}

// ───────────────────────────────────────────────────────────── index handling

function buildIndex(path, id) {
  const abs = canonical(path);
  let buf;
  try { buf = readFileSync(abs); } catch (e) { die(`cannot read ${abs}: ${e.message}`); }
  const a = analyze(buf);
  return {
    schema: SCHEMA, id, path: abs, bytes: a.bytes, sha256: sha256(buf), mtimeMs: statSync(abs).mtimeMs,
    encoding: 'utf-8', bom: a.bom, newline: a.newline,
    headings: a.headings, counts: a.counts, spine: a.spine, breaks: a.breaks, maxLine: a.maxLine,
    noise: noiseProfile(buf),
    setextSuspects: a.setextSuspects, frontmatter: a.frontmatter, windows: [],
  };
}

function ensureIndexed(wd, inv, path, { refresh = false } = {}) {
  const abs = canonical(path);
  if (!existsSync(abs)) die(`no such file: ${abs}`);
  let entry = inv.docs.find((d) => d.path === abs);
  const id = entry ? entry.id : nextId(inv);
  const sidecar = idxPath(wd, id);

  if (!refresh && existsSync(sidecar)) {
    try {
      const idx = JSON.parse(readFileSync(sidecar, 'utf8'));
      const st = statSync(abs);
      if (idx.schema === SCHEMA && idx.bytes === st.size) {
        // Hash is the authority, but an agent makes many sequential calls against
        // the same large file. Skip the digest when size and mtime both agree.
        if (idx.mtimeMs === st.mtimeMs) return idx;
        if (idx.sha256 === sha256(readFileSync(abs))) { idx.mtimeMs = st.mtimeMs; writeFileSync(sidecar, JSON.stringify(idx, null, 2)); return idx; }
      }
      warn(`${id} index is stale (source changed) — rebuilding; anchors recorded earlier may no longer resolve to the same content`);
    } catch { warn(`${id} sidecar unreadable — rebuilding`); }
  }

  const idx = buildIndex(abs, id);
  const keep = { ...idx };
  if (existsSync(sidecar)) {                                  // preserve window anchors across refresh
    try { const old = JSON.parse(readFileSync(sidecar, 'utf8')); if (old.sha256 === idx.sha256) keep.windows = old.windows ?? []; } catch { }
  }
  writeFileSync(sidecar, JSON.stringify(keep, null, 2));
  if (!entry) { inv.docs.push({ id, path: abs, name: basename(abs) }); saveInventory(wd, inv); }
  return keep;
}

function resolveDoc(wd, inv, ref, opts) {
  if (/^D\d+$/i.test(ref)) {
    const entry = inv.docs.find((d) => d.id.toLowerCase() === ref.toLowerCase());
    if (!entry) die(`unknown document id ${ref} — run 'discover' first, or pass a path`);
    return ensureIndexed(wd, inv, entry.path, opts);
  }
  return ensureIndexed(wd, inv, ref, opts);
}

// ─────────────────────────────────────────────────────── anchors and extents

// depth chooses the partition; extent chooses one cell of it or the whole branch.
const isActive = (h, depth) => h.level === 0 || h.level <= depth;

const virtualRoot = (title, start, end) => ({
  hid: 'H0000', level: 0, title, digest: digestOf(title),
  line: 1, headingStart: start, bodyStart: start, subtreeEnd: end, virtual: true,
});

// A second partition basis, for documents where thematic breaks delimit units
// better than headings do — or where there are no usable headings at all. The
// break terminates its segment, matching the `... reply / --- / next` shape.
// Same address space, same coverage arithmetic, anchors prefixed S.
function segmentsOf(idx) {
  const out = [];
  let pos = 0, n = 1;
  const push = (start, end) => out.push({
    hid: `S${String(n++).padStart(4, '0')}`, level: 0, title: `SEGMENT`, digest: digestOf(`seg:${idx.sha256}:${start}`),
    headingStart: start, bodyStart: start, subtreeEnd: end, end, synthetic: true,
  });
  for (const e of idx.breaks?.ends ?? []) { if (e > pos) { push(pos, e); pos = e; } }
  if (pos < idx.bytes) push(pos, idx.bytes);
  return out;
}

function findHeading(idx, spec) {
  const [hidRaw, dig] = String(spec).split('@');
  const hid = hidRaw.includes(':') ? hidRaw.split(':').pop() : hidRaw;
  const h = idx.headings.find((x) => x.hid.toLowerCase() === hid.toLowerCase());
  if (!h) {
    const w = (idx.windows ?? []).find((x) => x.wid.toLowerCase() === hid.toLowerCase());
    if (w) return { hid: w.wid, level: 0, title: w.title, digest: w.digest, headingStart: w.start, bodyStart: w.start, subtreeEnd: w.end, end: w.end, synthetic: true };
    if (/^S\d+$/i.test(hid)) {
      const s = segmentsOf(idx).find((x) => x.hid.toLowerCase() === hid.toLowerCase());
      if (s) { if (dig && dig !== s.digest) warn(`anchor ${idx.id}:${s.hid}@${dig} does not match current segment digest @${s.digest} — the source has changed under this anchor`); return s; }
      die(`${idx.id}: no anchor ${hid} (document has ${(idx.breaks?.ends ?? []).length} thematic break(s))`);
    }
    if (hid.toUpperCase() === 'H0000')
      return virtualRoot(idx.headings.length ? 'PREAMBLE' : 'BODY', 0, idx.headings.length ? idx.headings[0].headingStart : idx.bytes);
    die(`${idx.id}: no anchor ${hid}`);
  }
  if (dig && dig !== h.digest)
    warn(`anchor ${idx.id}:${h.hid}@${dig} does not match current heading digest @${h.digest} — the source has changed under this anchor`);
  return h;
}

function unitEnd(idx, h, depth) {
  if (h.synthetic) return h.end ?? h.subtreeEnd;
  const k = idx.headings.indexOf(h);
  for (let m = k + 1; m < idx.headings.length; m++)
    if (idx.headings[m].level > 0 && idx.headings[m].level <= depth) return idx.headings[m].headingStart;
  return idx.bytes;
}

function spanFor(idx, h, depth, extent) {
  if (extent === 'subtree') return [h.headingStart, h.subtreeEnd];
  if (!isActive(h, depth))
    die(`${idx.id}:${h.hid} is H${h.level}, which is not active at depth ${depth} — raise --depth or use --extent subtree`);
  return [h.headingStart, unitEnd(idx, h, depth)];
}

// The active set must partition [0, bytes) — a document whose first heading sits
// below the chosen depth still has to be reachable, or bytes vanish from both the
// outline and the coverage arithmetic.
function activeAt(idx, depth, withinHid) {
  if (withinHid) {
    const w = findHeading(idx, withinHid);
    return idx.headings.filter((h) => isActive(h, depth) && h.headingStart > w.headingStart && h.headingStart < w.subtreeEnd);
  }
  const list = idx.headings.filter((h) => isActive(h, depth));
  if (!list.length) return [virtualRoot('BODY', 0, idx.bytes)];
  if (list[0].headingStart > 0) list.unshift(virtualRoot('PREAMBLE', 0, list[0].headingStart));
  return list;
}

// Headings or thematic breaks — the reader chooses the basis, since which one
// delimits meaningful units is a property of how the document was produced.
function partitionOf(idx, { depth, by, within }) {
  if (by !== 'breaks') return activeAt(idx, depth, within);
  if (within) die(`--within applies to heading partitions; --by breaks partitions the whole document`);
  const segs = segmentsOf(idx);
  if (!segs.length) die(`${idx.id}: no thematic breaks to partition on`);
  return segs;
}

// ────────────────────────────────────────────────────────────── read ledger

// The ledger records the grain a span was read at, not just that it was read.
// Bytes are the invariant measure; "which unit" is only meaningful relative to
// the basis and depth that produced it, so both are stamped.
function logRead(wd, idx, spans, depth, extent, anchors, elided = 0, elidedSpans = []) {
  const kind = anchors[0]?.[0]?.toUpperCase();
  const basis = kind === 'S' ? 'breaks' : kind === 'W' ? 'windows' : `d${depth}`;
  const bytes = spans.reduce((a, [s, e]) => a + (e - s), 0);
  // The span was materialised and adjudicated; elided bytes are recorded so the
  // ledger never implies they were read as prose.
  appendFileSync(readsPath(wd), JSON.stringify({ doc: idx.id, anchors, basis, depth, extent, spans, bytes, elided, elidedSpans }) + '\n');
}

function loadReads(wd) {
  const p = readsPath(wd);
  if (!existsSync(p)) return [];
  return readFileSync(p, 'utf8').split('\n').filter(Boolean).map((l) => { try { return JSON.parse(l); } catch { return null; } }).filter(Boolean);
}

function mergeSpans(spans) {
  const s = [...spans].sort((a, b) => a[0] - b[0]);
  const out = [];
  for (const [a, b] of s) {
    const last = out[out.length - 1];
    if (last && a <= last[1]) last[1] = Math.max(last[1], b); else out.push([a, b]);
  }
  return out;
}
const coveredWithin = (merged, a, b) => merged.reduce((n, [s, e]) => n + Math.max(0, Math.min(e, b) - Math.max(s, a)), 0);

// ──────────────────────────────────────────────────────────────────── verbs

function vDiscover(args) {
  const targets = args._.slice(1);
  if (!targets.length) die(`discover needs at least one file or directory`);
  const wd = workDir(args.f, { mint: !args.f.run, anchor: anchorFor(targets) });
  assertNotDiscoverable(wd, targets);
  const inv = loadInventory(wd);
  const glob = args.f.glob && args.f.glob !== true ? String(args.f.glob) : '*.md';
  const rx = new RegExp('^' + glob.replace(/[.+^${}()|[\]\\]/g, '\\$&').replace(/\*/g, '.*').replace(/\?/g, '.') + '$', 'i');
  const recursive = args.f.recursive !== undefined;

  const found = [];
  const visit = (p, depth) => {
    const st = statSync(p);
    if (st.isDirectory()) {
      if (depth > 0 && !recursive) return;
      for (const e of readdirSync(p, { withFileTypes: true })) {
        if (e.name.startsWith('.')) continue;
        const child = join(p, e.name);
        if (e.isDirectory()) visit(child, depth + 1);
        else if (rx.test(e.name)) found.push(child);
      }
    } else if (st.isFile()) found.push(p);                    // explicit files bypass the glob
  };
  for (const t of targets) { if (!existsSync(t)) die(`no such path: ${t}`); visit(resolve(t), 0); }

  const seen = new Set(), docs = [];
  for (const f of found) { const c = canonical(f); if (seen.has(c)) continue; seen.add(c); docs.push(ensureIndexed(wd, inv, c)); }
  if (!docs.length) die(`no documents matched ${glob}`);
  printInventory(docs, wd);
}

// What each depth would actually hand you. Purely mechanical — unit counts and a
// median size — but it is the fact that decides where to start reading, and it is
// not derivable from heading counts alone. Reading the signature is the reader's
// job; see README, "Grain signatures".
function grainOf(idx) {
  const at = (depth) => {
    const sizes = activeAt(idx, depth).map((h) => { const [s, e] = spanFor(idx, h, depth, 'unit'); return e - s; });
    if (!sizes.length) return { n: 0, med: 0 };
    const sorted = [...sizes].sort((a, b) => a - b);
    return { n: sizes.length, med: sorted[Math.floor(sorted.length / 2)] };
  };
  const d = [1, 2, 3].map(at);
  const first = d.find((x) => x.n > 1) ?? d[0];          // the shallowest depth that divides anything
  return `${d.map((x) => x.n).join('/')}~${fmtBytes(first.med).replace(' ', '').replace('iB', '')}`;
}

function printInventory(docs, wd) {
  const rows = docs.map((d) => {
    const notes = [];
    // Species are reported separately: an embedded file and a handful of tags are
    // different problems with different remedies.
    const n = d.noise ?? { ratio: 0, bytes: 0 };
    if (n['data-uri']?.bytes) notes.push(`embedded=${fmtBytes(n['data-uri'].bytes)}(${(n['data-uri'].bytes / d.bytes * 100).toFixed(0)}%)`);
    if (n['signed-url']?.count) notes.push(`signed=${n['signed-url'].count}(${fmtBytes(n['signed-url'].bytes)})`);
    if (n.html?.bytes > 1024) notes.push(`html=${fmtBytes(n.html.bytes)}`);
    if (n['image-ref']?.count) notes.push(`imgref=${n['image-ref'].count}`);
    if (d.breaks.count) notes.push(`breaks=${d.breaks.count}${d.breaks.aligned === 'aligned' ? '=h1-1' : `≠h1-1`}`);
    if (d.maxLine?.bytes > 4096 && n.ratio < 0.02) notes.push(`maxline=${fmtBytes(d.maxLine.bytes)}`);
    if (d.setextSuspects.length) notes.push(`setext? x${d.setextSuspects.length}`);
    if (d.frontmatter) notes.push('frontmatter');
    if ((d.windows ?? []).length) notes.push(`windows x${d.windows.length}`);
    return {
      id: d.id, bytes: fmtNum(d.bytes),
      lv: [1, 2, 3, 4, 5, 6].map((n) => d.counts[`h${n}`] ?? 0).join('/').replace(/(\/0)+$/, ''),
      grain: grainOf(d),
      spine: (d.counts.h1 ?? 0) >= 2 ? `${(d.spine.ratio * 100).toFixed(1)}%` : '—',
      notes: notes.join(' '), path: d.path,
    };
  });
  const w = (k, min) => Math.max(min, ...rows.map((r) => String(r[k]).length));
  const wB = w('bytes', 5), wL = w('lv', 8), wG = w('grain', 5), wS = w('spine', 5), wN = w('notes', 0);
  process.stdout.write(`ID    ${'Bytes'.padStart(wB)}  ${'H1/H2/..'.padEnd(wL)}  ${'Grain d1/d2/d3'.padEnd(wG)}  ${'Spine'.padStart(wS)}  ${wN ? 'Notes'.padEnd(wN) + '  ' : ''}Path\n`);
  for (const r of rows)
    process.stdout.write(`${r.id.padEnd(5)} ${String(r.bytes).padStart(wB)}  ${r.lv.padEnd(wL)}  ${r.grain.padEnd(wG)}  ${r.spine.padStart(wS)}  ${wN ? r.notes.padEnd(wN) + '  ' : ''}${r.path}\n`);
  process.stdout.write(`\n${rows.length} document(s) indexed under ${wd}\n`);
  const unaligned = docs.filter((d) => d.breaks.aligned && d.breaks.aligned !== 'aligned').length;
  if (unaligned) process.stderr.write(
    `mdnav: in ${unaligned} document(s) the H1 count and thematic-break count do not correspond. Neither basis\n` +
    `       is privileged — inspect both and choose: 'outline --depth 1' or 'outline --by breaks'.\n`);

  // Triage on composition, never on meaning: how much of the document is made of
  // machine furniture, and therefore what it would cost to read it unfiltered.
  const noisy = docs.filter((d) => (d.noise?.ratio ?? 0) >= 0.10);
  if (noisy.length) {
    const worst = noisy.reduce((a, b) => (a.noise.ratio > b.noise.ratio ? a : b));
    process.stderr.write(
      `mdnav: ${noisy.length} document(s) are ≥10% embedded data or HTML markup (worst: ${worst.id} at ` +
      `${(worst.noise.ratio * 100).toFixed(1)}%, ${fmtBytes(worst.noise.bytes)}).\n` +
      `       Read those with --strip all, or preprocess them, before spending context on the raw bytes.\n` +
      `       For a species mdnav does not know about, aim --strip-match '<regex>' at it.\n`);
  }
}

function vIndex(args) {
  const refs = args._.slice(1);
  if (!refs.length) die(`index needs a file or document id`);
  const fresh = !args.f.run && !/^D\d+$/i.test(refs[0]);
  const wd = workDir(args.f, { mint: fresh, anchor: fresh ? anchorFor(refs) : null });
  if (fresh) assertNotDiscoverable(wd, refs);
  const inv = loadInventory(wd);
  printInventory(refs.map((r) => resolveDoc(wd, inv, r, { refresh: args.f.refresh !== undefined })), wd);
}

function vOutline(args) {
  const wd = workDir(args.f), inv = loadInventory(wd);
  const ref = args._[1];
  if (!ref) die(`outline needs a file or document id`);
  const idx = resolveDoc(wd, inv, ref);
  const depth = intFlag(args.f, ['depth', 'max-depth'], 1);
  if (depth < 1 || depth > 6) die(`--depth must be 1..6`);
  const within = args.f.within && args.f.within !== true ? String(args.f.within) : null;
  const preview = intFlag(args.f, ['preview'], 0);
  const trunc = intFlag(args.f, ['truncate'], 0);       // full titles by default: in chat exports the title is the turn
  const buf = readFileSync(idx.path);

  if (args.f.windows !== undefined) { computeWindows(wd, idx, args, buf); return; }

  const by = args.f.by && args.f.by !== true ? String(args.f.by) : 'headings';
  const list = partitionOf(idx, { depth, by, within });
  if (!list.length) { process.stdout.write(`(no units at depth ${depth}${within ? ` within ${within}` : ''})\n`); return; }

  // Longest line inside a unit: a unit that is mostly one unbroken line is a blob
  // (base64, minified data), not prose, and the reader should know before diving.
  const longestLine = (s, e) => { let m = 0, p = s; for (; ;) { const nl = buf.indexOf(LF, p); const q = nl === -1 || nl >= e ? e : nl; if (q - p > m) m = q - p; if (q >= e) break; p = q + 1; } return m; };
  const wantComp = args.f.comp !== undefined || args.f.composition !== undefined;
  const allRuns = wantComp ? constructRuns(buf) : null;
  const allNoise = wantComp ? noiseSpans(buf, 0, buf.length, Object.keys(NOISE)) : null;

  for (const h of list) {
    const [us, ue] = spanFor(idx, h, depth, 'unit');
    const lvl = h.synthetic ? (h.hid[0] === 'S' ? 'S ' : 'W ') : h.level === 0 ? '--' : `H${h.level}`;
    let title = h.synthetic && h.hid[0] === 'S'
      ? (buf.toString('utf8', us, Math.min(ue, us + 600)).split('\n').map((l) => l.trim()).find((l) => l && l !== '---') ?? 'SEGMENT')
      : h.title;
    if (trunc > 0 && title.length > trunc) title = title.slice(0, trunc) + '…';
    const nz = noiseSpans(buf, us, ue, STRIP_ALL).reduce((a, n) => a + (n.end - n.start), 0);
    const ll = longestLine(us, ue);
    const flag = wantComp ? `  [${compositionOf(buf, allRuns, allNoise, us, ue)}]`
      : nz > 1024 ? `  noise=${fmtBytes(nz)}(${((nz / ((ue - us) || 1)) * 100).toFixed(0)}%)`
        : ll > 4096 ? `  maxline=${fmtBytes(ll)}` : '';
    process.stdout.write(
      `[${h.hid}@${h.digest}] ${lvl}  unit=${fmtBytes(ue - us).padEnd(9)} subtree=${fmtBytes(h.subtreeEnd - h.headingStart).padEnd(9)}${flag} ${title}\n`);
    if (preview > 0) {
      const body = buf.toString('utf8', h.bodyStart, Math.min(ue, h.bodyStart + preview * 4)).replace(/\s+/g, ' ').trim();
      if (body) process.stdout.write(`          > ${body.slice(0, preview)}${body.length > preview ? '…' : ''}\n`);
    }
  }
  // Distribution, not just the total: a partition of 62 even units and one of 62
  // units where two hold 92% of the bytes call for completely different plans.
  const sizes = list.map((h) => { const [s, e] = spanFor(idx, h, depth, 'unit'); return e - s; }).sort((a, b) => a - b);
  const total = sizes.reduce((a, n) => a + n, 0);
  const med = sizes[Math.floor(sizes.length / 2)] ?? 0;
  const basis = by === 'breaks' ? 'thematic break' : `depth ${depth}`;
  process.stderr.write(`mdnav: ${list.length} unit(s) by ${basis}${within ? ` within ${within}` : ''}, ` +
    `${fmtBytes(total)} of ${fmtBytes(idx.bytes)} — median ${fmtBytes(med)}, largest ${fmtBytes(sizes[sizes.length - 1] ?? 0)}\n`);
}

// Fallback partition for documents whose headings are absent or too sparse to be
// a usable reading grain. Windows live in the same address space as headings.
function computeWindows(wd, idx, args, buf) {
  const size = intFlag(args.f, ['windows'], 8192);
  const within = args.f.within && args.f.within !== true ? findHeading(idx, String(args.f.within)) : null;
  const lo = within ? within.headingStart : 0, hi = within ? within.subtreeEnd : idx.bytes;

  // Window boundaries ALWAYS fall after a newline. Any prose document has line
  // breaks, so a stretch with none is not prose — it is a blob (base64, minified
  // JSON, a data URI). Slicing a blob at an arbitrary offset would manufacture
  // fragments that mean nothing; emitting it whole reports what is actually there
  // and lets the reader skip it. Prefer a paragraph break within slack, else take
  // the next line break, however far.
  const boundary = (from) => {
    const target = Math.min(from + size, hi);
    if (target >= hi) return hi;
    const slack = Math.floor(size / 2);
    const a = Math.max(from + 1, target - slack), b = Math.min(hi, target + slack);
    const near = buf.subarray(a, b);

    let rel = near.indexOf('\n\n');
    if (rel === -1) rel = near.indexOf('\r\n\r\n');
    if (rel !== -1) return a + rel + (near[rel] === CR ? 4 : 2);

    const nl = buf.indexOf(LF, target);
    return nl === -1 || nl + 1 >= hi ? hi : nl + 1;
  };

  const windows = [];
  for (let pos = lo, n = 1; pos < hi; n++) {
    const end = boundary(pos);
    if (end <= pos) break;
    const wid = `W${String(n).padStart(4, '0')}`;
    windows.push({ wid, start: pos, end, within: within ? within.hid : null, title: `WINDOW ${n}`, digest: digestOf(`${idx.sha256}:${pos}`) });
    pos = end;
  }
  idx.windows = windows;
  writeFileSync(idxPath(wd, idx.id), JSON.stringify(idx, null, 2));
  let over = 0;
  for (const w of windows) {
    const n = w.end - w.start, big = n > size * 2;
    if (big) over++;
    process.stdout.write(`[${w.wid}@${w.digest}] W   unit=${fmtBytes(n).padEnd(9)} bytes ${w.start}..${w.end}${big ? '  UNBROKEN — no line break to split on' : ''}\n`);
  }
  process.stderr.write(`mdnav: ${windows.length} window(s) of ~${fmtBytes(size)} over ${fmtBytes(hi - lo)}${within ? ` within ${within.hid}` : ''}\n`);
  if (over) process.stderr.write(`mdnav: ${over} window(s) far exceed the requested size — that content has no line breaks to split on\n`);
}

function vRead(args) {
  const wd = workDir(args.f), inv = loadInventory(wd);
  const ref = args._[1];
  if (!ref) die(`read needs a file or document id`);
  const idx = resolveDoc(wd, inv, ref);
  const depth = intFlag(args.f, ['depth', 'max-depth'], 1);
  const extent = args.f.extent && args.f.extent !== true ? String(args.f.extent) : 'unit';
  if (!['unit', 'subtree'].includes(extent)) die(`--extent must be unit or subtree`);
  const buf = readFileSync(idx.path);

  let spans = [], anchors = [], decorate = false;

  if (args.f.from) {                                          // merge: one contiguous range across units
    const a = findHeading(idx, String(args.f.from));
    const b = args.f.to && args.f.to !== true ? findHeading(idx, String(args.f.to)) : a;
    const [, endB] = spanFor(idx, b, depth, extent);
    if (endB <= a.headingStart) die(`--to anchor precedes --from anchor`);
    spans = [[a.headingStart, endB]];
    anchors = [a.hid, b.hid];
  } else if (args.f.headings) {                               // batch: discontiguous cluster re-read
    const hs = String(args.f.headings).split(',').map((s) => s.trim()).filter(Boolean).map((s) => findHeading(idx, s));
    hs.sort((x, y) => x.headingStart - y.headingStart);
    spans = hs.map((h) => spanFor(idx, h, depth, extent));
    anchors = hs.map((h) => h.hid);
    decorate = spans.length > 1;
  } else if (args.f.heading) {
    const h = findHeading(idx, String(args.f.heading));
    spans = [spanFor(idx, h, depth, extent)];
    anchors = [h.hid];
  } else if (args.f.span) {                                   // raw byte span — the substrate itself
    const m = /^(\d+)\.\.(\d+)$/.exec(String(args.f.span));
    if (!m) die(`--span expects <start>..<end> in bytes`);
    const [a, b] = [+m[1], +m[2]];
    if (b <= a || b > idx.bytes) die(`--span ${a}..${b} is outside 0..${idx.bytes}`);
    spans = [[a, b]];
    anchors = [`@${a}..${b}`];
  } else die(`read needs --heading <id>, --from <id> --to <id>, --headings <id,id,...>, or --span <a>..<b>`);

  // --strip elides machine furniture from the output stream. The source is never
  // touched and the elision is addressed, not hidden: anything substantial leaves
  // a placeholder naming its kind and size, so the reader can see what was skipped
  // and re-read the same anchor without --strip to get it. Byte fidelity is
  // deliberately traded away here and only here.
  // --strip-match lets the reader aim the same machinery at a species this tool
  // has no business guessing at — signed URLs, tracking pixels, whatever a given
  // corpus carries. The pattern comes from the reader, so nothing is presumed.
  const custom = args.f['strip-match'] && args.f['strip-match'] !== true ? String(args.f['strip-match']) : null;
  if (custom) { try { NOISE.custom = new RegExp(custom, 'g'); } catch (e) { die(`--strip-match: ${e.message}`); } }

  const strip = args.f.strip === undefined && !custom ? null
    : new Set([
      ...(args.f.strip === undefined ? [] : args.f.strip === true || args.f.strip === 'all' ? STRIP_ALL : String(args.f.strip).split(',')),
      ...(custom ? ['custom'] : []),
    ]);
  if (strip) for (const k of strip) if (!NOISE[k]) die(`--strip expects all or a comma list of: ${Object.keys(NOISE).filter((x) => x !== 'custom').join(', ')}`);
  let elided = 0, elisions = 0;
  const elidedSpans = [];

  // Warn BEFORE writing: once the bytes are on stdout they are in the reader's
  // context and the cost is already paid. Detection is mechanical, so this can
  // be said without any claim about what the document means.
  if (!strip) {
    const n = spans.reduce((a, [s, e]) => a + noiseSpans(buf, s, e, STRIP_ALL).reduce((x, y) => x + (y.end - y.start), 0), 0);
    const tot = spans.reduce((a, [s, e]) => a + (e - s), 0);
    if (n > 65536) process.stderr.write(
      `mdnav: this read carries ${fmtBytes(n)} of embedded data or HTML markup ` +
      `(${((n / (tot || 1)) * 100).toFixed(0)}% of ${fmtBytes(tot)}).\n` +
      `       Re-run with --strip all to elide it; the placeholders keep the spans addressable.\n`);
  }

  for (let k = 0; k < spans.length; k++) {
    if (decorate) process.stdout.write(`<!-- mdnav ${idx.id}:${anchors[k]} -->\n`);
    const [s, e] = spans[k];
    if (!strip) { process.stdout.write(buf.subarray(s, e)); continue; }
    let p = s;
    for (const n of noiseSpans(buf, s, e, strip)) {
      if (n.start < p) continue;
      process.stdout.write(buf.subarray(p, n.start));
      const size = n.end - n.start;
      // Some species carry a fragment worth keeping — a citation's label names
      // what was referenced even when its URL is long dead.
      const keep = keepOf(n.kind)?.(n.text ?? buf.toString('utf8', n.start, n.end)) ?? null;
      if (keep) { process.stdout.write(keep); elided += size - Buffer.byteLength(keep, 'utf8'); elidedSpans.push([n.start, n.end]); }
      else {
        if (size >= 1024) process.stdout.write(`<!-- mdnav: elided ${n.kind} ${fmtBytes(size)} @${n.start}..${n.end} -->`);
        elided += size; elidedSpans.push([n.start, n.end]);
      }
      elisions++;
      p = n.end;
    }
    process.stdout.write(buf.subarray(p, e));
  }

  const total = spans.reduce((a, [s, e]) => a + (e - s), 0);
  logRead(wd, idx, spans, depth, extent, anchors, elided, elidedSpans);
  process.stderr.write(`mdnav: read ${idx.id} ${anchors.join(',')} extent=${extent} depth=${depth} ${fmtBytes(total)}` +
    (strip ? ` — elided ${elisions} span(s), ${fmtBytes(elided)} (${((elided / (total || 1)) * 100).toFixed(1)}%)` : '') + '\n');
}

function vCoverage(args) {
  const wd = workDir(args.f), inv = loadInventory(wd);
  const reads = loadReads(wd);
  const refs = args._.slice(1);
  const docs = (refs.length ? refs.map((r) => resolveDoc(wd, inv, r)) : inv.docs.map((d) => ensureIndexed(wd, inv, d.path)));
  if (!docs.length) die(`nothing indexed yet — run 'discover' first`);
  const depthFlag = intFlag(args.f, ['depth', 'max-depth'], 0);

  let tot = 0, cov = 0;
  for (const idx of docs) {
    const mine = reads.filter((r) => r.doc === idx.id);
    const merged = mergeSpans(mine.flatMap((r) => r.spans));
    const skipped = mergeSpans(mine.flatMap((r) => r.elidedSpans ?? []));
    const spanned = merged.reduce((a, [s, e]) => a + (e - s), 0);
    // Elided bytes were materialised and adjudicated, not read. Counting them as
    // covered would let a screenshot masquerade as prose the reader has seen.
    const skip = skipped.reduce((a, [s, e]) => a + (e - s), 0);
    const bytes = spanned - skip;
    tot += idx.bytes; cov += bytes;

    const byBasis = {};
    for (const r of mine) { const b = r.basis ?? `d${r.depth}`; byBasis[b] = (byBasis[b] ?? 0) + 1; }
    const bb = Object.entries(byBasis).map(([b, n]) => `${b}:${n}`).join(' ') || '—';
    process.stdout.write(
      `${idx.id}  ${fmtNum(bytes).padStart(9)} / ${fmtNum(idx.bytes).padStart(9)} B  ` +
      `${((idx.bytes ? bytes / idx.bytes : 0) * 100).toFixed(1).padStart(5)}%  reads=${String(mine.length).padStart(3)}  grain={${bb}}` +
      `${skip ? `  elided=${fmtBytes(skip)}` : ''}  ${basename(idx.path)}\n`);

    // Byte coverage is the invariant measure; unit counts are not comparable
    // across a depth change, so unread listings are always stamped with a depth.
    const byFlag = args.f.by && args.f.by !== true ? String(args.f.by) : null;
    if (depthFlag || byFlag) {
      const unread = [], partial = [];
      for (const h of partitionOf(idx, { depth: depthFlag || 1, by: byFlag })) {
        const [s, e] = spanFor(idx, h, depthFlag || 1, 'unit');
        const c = coveredWithin(merged, s, e);
        if (c === 0) unread.push(h.hid); else if (c < e - s) partial.push(h.hid);
      }
      const at = byFlag === 'breaks' ? '@breaks' : `@depth${depthFlag}`;
      // The point is to cut noise, not add it: a 61-anchor wall helps nobody.
      const brief = (l) => (l.length <= 16 ? l.join(' ') : `${l.slice(0, 16).join(' ')} … +${l.length - 16} more`);
      if (unread.length) process.stdout.write(`      unread ${at} (${unread.length}): ${brief(unread)}\n`);
      if (partial.length) process.stdout.write(`      partial ${at} (${partial.length}): ${brief(partial)}\n`);
      if (!unread.length && !partial.length) process.stdout.write(`      complete ${at}\n`);
    }
    for (const w of idx.windows ?? []) {
      if (coveredWithin(merged, w.start, w.end) === 0) { process.stdout.write(`      unread windows: ${(idx.windows).filter((x) => coveredWithin(merged, x.start, x.end) === 0).map((x) => x.wid).join(' ')}\n`); break; }
    }
  }
  process.stdout.write(`\nTOTAL  ${fmtNum(cov)} / ${fmtNum(tot)} B  ${((tot ? cov / tot : 0) * 100).toFixed(1)}%\n`);
  if (!depthFlag) process.stderr.write(`mdnav: pass --depth <n> to list unread anchors at a reading grain\n`);
}

// A commutative observable over a committed partition: returns anchors, never
// interpretation. Safe to run corpus-wide in one call.
function vLocate(args) {
  const wd = workDir(args.f), inv = loadInventory(wd);
  const pattern = args._[1];
  if (!pattern) die(`locate needs a pattern`);
  const refs = args._.slice(2);
  const docs = (refs.length ? refs.map((r) => resolveDoc(wd, inv, r)) : inv.docs.map((d) => ensureIndexed(wd, inv, d.path)));
  if (!docs.length) die(`nothing indexed yet — run 'discover' first`);
  const depth = intFlag(args.f, ['depth', 'max-depth'], 6);
  const cap = intFlag(args.f, ['max'], 50);
  let rx;
  try { rx = new RegExp(pattern, args.f.i ? 'i' : ''); } catch (e) { die(`bad pattern: ${e.message}`); }

  let hits = 0;
  for (const idx of docs) {
    const buf = readFileSync(idx.path);
    const active = activeAt(idx, depth);
    const starts = active.map((h) => h.headingStart);
    const anchorAt = (off) => { let lo = 0, hi = starts.length - 1, k = 0; while (lo <= hi) { const m = (lo + hi) >> 1; if (starts[m] <= off) { k = m; lo = m + 1; } else hi = m - 1; } return active[k]; };

    let n = 0, line = 0, capped = false;
    for (let i = 0; i < buf.length;) {
      let j = buf.indexOf(LF, i); const eol = j === -1 ? buf.length : j;
      let ce = eol; if (ce > i && buf[ce - 1] === CR) ce--;
      line++;
      const t = buf.toString('utf8', i, ce);
      if (rx.test(t)) {
        if (n >= cap) { capped = true; break; }
        const h = anchorAt(i);
        process.stdout.write(`${idx.id}:${h ? h.hid : '?'}${h ? '@' + h.digest : ''}  L${line}  ${t.trim().slice(0, 160)}\n`);
        n++; hits++;
      }
      if (j === -1) break; i = j + 1;
    }
    if (capped) process.stdout.write(`${idx.id}  … capped at ${cap} matches (raise with --max)\n`);
  }
  process.stderr.write(`mdnav: ${hits} match(es) at depth ${depth}\n`);
}

function vProfile(args) {
  const wd = workDir(args.f), inv = loadInventory(wd);
  const refs = args._.slice(1);
  const docs = (refs.length ? refs.map((r) => resolveDoc(wd, inv, r)) : inv.docs.map((d) => ensureIndexed(wd, inv, d.path)));
  if (!docs.length) die(`nothing indexed yet — run 'discover' first`);

  for (const idx of docs) {
    const buf = readFileSync(idx.path);
    const runs = constructRuns(buf);
    const agg = new Map();
    for (const r of runs) {
      const key = r.kind === 'heading' ? `heading h${/^ {0,3}(#{1,6})/.exec(buf.toString('utf8', r.start, Math.min(r.end, r.start + 12)))?.[1].length ?? 1}` : r.kind;
      const a = agg.get(key) ?? { n: 0, bytes: 0, lines: 0, starts: [], info: new Map() };
      a.n++; a.bytes += r.end - r.start; a.lines += r.lines; a.starts.push(r.start);
      if (r.info) a.info.set(r.info, (a.info.get(r.info) ?? 0) + 1);
      agg.set(key, a);
    }

    process.stdout.write(`\n${idx.id}  ${basename(idx.path)}  ${fmtNum(idx.bytes)} B\n\n`);
    process.stdout.write(`  construct      runs      bytes      %   median gap      cv   detail\n`);
    const rows = [...agg.entries()].sort((a, b) => b[1].bytes - a[1].bytes);
    for (const [kind, a] of rows) {
      const c = cadence(a.starts, idx.bytes);
      const info = [...a.info.entries()].sort((x, y) => y[1] - x[1]).slice(0, 4).map(([k, n]) => `${k || '·'}×${n}`).join(' ');
      process.stdout.write(
        `  ${kind.padEnd(13)}${String(a.n).padStart(5)}${fmtNum(a.bytes).padStart(11)}` +
        `${((a.bytes / idx.bytes) * 100).toFixed(1).padStart(7)}%` +
        `${(c ? fmtBytes(c.median) : '—').padStart(13)}${(c ? c.cv.toFixed(2) : '—').padStart(8)}   ${info}\n`);
    }
    // Cadence is only meaningful for a construct that spans the document — and
    // paragraphs are filler by nature, so their even spacing says nothing.
    const even = rows.filter(([kind, a]) => {
      if (kind === 'paragraph') return false;
      const c = cadence(a.starts, idx.bytes);
      return c && c.cv < 0.6 && c.span > 0.6;
    });
    if (even.length) process.stderr.write(
      `mdnav: ${idx.id} — evenly spaced across the document: ${even.map(([k]) => k).join(', ')}. ` +
      `A construct with low cv and wide span is dividing the document; treat it as a candidate delimiter.\n`);
  }
}

// The bridge from a flagged candidate to something readable. `outline` enumerates
// headings; this enumerates occurrences of ANY construct, as runs rather than
// lines, with spans so each one can be read directly. It says where the motifs
// are and how each begins — never what they are.
function vMarks(args) {
  const wd = workDir(args.f), inv = loadInventory(wd);
  const ref = args._[1];
  if (!ref) die(`marks needs a file or document id`);
  const idx = resolveDoc(wd, inv, ref);
  const kind = args.f.kind && args.f.kind !== true ? String(args.f.kind) : die(`marks needs --kind <blockquote|fence|table|list|html|break|paragraph|heading>`);
  const preview = intFlag(args.f, ['preview'], 72);
  const min = intFlag(args.f, ['min'], 0);
  const buf = readFileSync(idx.path);

  const runs = constructRuns(buf).filter((r) => r.kind === kind && r.end - r.start >= min);
  if (!runs.length) { process.stdout.write(`(no ${kind} runs${min ? ` of ${min}+ bytes` : ''})\n`); return; }

  const heads = idx.headings.filter((h) => h.level > 0);
  const containing = (off) => { let k = null; for (const h of heads) { if (h.headingStart <= off) k = h; else break; } return k; };

  for (const r of runs) {
    const h = containing(r.start);
    const text = buf.toString('utf8', r.start, Math.min(r.end, r.start + preview * 4))
      .replace(/^ {0,3}>[ \t]?/gm, '').replace(/\s+/g, ' ').trim();
    process.stdout.write(
      `${String(r.start).padStart(8)}..${String(r.end).padEnd(8)} ${fmtBytes(r.end - r.start).padStart(9)} ` +
      `${String(r.lines).padStart(3)}L  ${(h ? `${idx.id}:${h.hid}` : `${idx.id}:—`).padEnd(12)} ` +
      `${r.info ? `[${r.info}] ` : ''}${text.slice(0, preview)}${text.length > preview ? '…' : ''}\n`);
  }
  const total = runs.reduce((a, r) => a + (r.end - r.start), 0);
  process.stderr.write(`mdnav: ${runs.length} ${kind} run(s), ${fmtBytes(total)} of ${fmtBytes(idx.bytes)} ` +
    `(${((total / idx.bytes) * 100).toFixed(1)}%) — read one with 'read ${idx.id} --span <start>..<end>'\n`);
}

const HELP = `mdnav — structure-aware navigation over Markdown corpora

  discover <path>...            [--glob '*.md'] [--recursive]
  index    <file|Dnnn>...       [--refresh]
  outline  <file|Dnnn>          [--depth 1-6 | --by breaks] [--within <anchor>] [--preview N] [--truncate N] [--comp]
  outline  <file|Dnnn>          --windows <bytes> [--within <anchor>]
  read     <file|Dnnn>          --heading <anchor> | --from <a> --to <b> | --headings <a,b,c>
                                [--depth 1-6] [--extent unit|subtree]
                                [--strip all|data-uri,html,image-ref] [--strip-match <regex>]
  read     <file|Dnnn>          --span <start>..<end>          (raw byte span)
  coverage [<file|Dnnn>...]     [--depth 1-6] [--by breaks]
  locate   <pattern> [<file|Dnnn>...]  [-i] [--depth 1-6] [--max N]
  profile  [<file|Dnnn>...]     construct composition and cadence of an unknown document
  marks    <file|Dnnn>          --kind <construct> [--preview N] [--min bytes]

Common flags: --work-dir <path> (or $MDNAV_WORK_DIR), --run <stamp>

Artifacts
  Local to the corpus: discover/index mint <corpus>/.doc-dive/<UTC yyyyMMdd_HHmmss>/.
  Dot-prefixed so 'discover' never indexes them; refused if placed where it would.
  Later verbs follow the last run, so the stamp is never retyped. Runs are never
  overwritten — each is a new stamp and earlier ones survive.

Model
  depth chooses the partition; extent chooses one cell of it (unit) or the whole branch (subtree).
  Partition basis is the reader's choice: headings (Hnnnn), thematic breaks (--by breaks, Snnnn),
  or fixed windows for documents with neither (--windows, Wnnnn). No document format is assumed.
  Anchors are Dnnn:Hnnnn[@digest]; the digest guards against the source shifting under a note.
  'read' writes literal source bytes to stdout — single-anchor reads are undecorated.
  --strip elides from the OUTPUT only; the source is never modified, and anything over
  1 KiB leaves a placeholder naming its kind, size and span. 'all' = data-uri + html.
  An embedded file and a reference to an external one are different species: image-ref
  is opt-in, since a URL costs bytes you can count and records that a figure was there.
  Everything diagnostic goes to stderr.
`;

const VERBS = { discover: vDiscover, index: vIndex, outline: vOutline, read: vRead, coverage: vCoverage, locate: vLocate, profile: vProfile, marks: vMarks };

const args = parseArgs(process.argv.slice(2));
const verb = args._[0];
if (!verb || verb === 'help' || args.f.help) { process.stdout.write(HELP); process.exit(0); }
if (!VERBS[verb]) die(`unknown verb '${verb}' — try: ${Object.keys(VERBS).join(', ')}`);
VERBS[verb](args);
