#!/usr/bin/env node
// Acceptance tests for mdnav. Self-contained: fixtures are generated into a temp
// work area, so nothing large is checked in and the suite runs anywhere Node runs.
//
// The load-bearing test is `partition`: concatenating every unit at a given depth
// must reproduce the source byte-for-byte. That single check covers completeness,
// non-overlap, byte fidelity, and preservation of LaTeX/equations/images/long lines.

import { spawnSync } from 'node:child_process';
import { mkdtempSync, writeFileSync, readFileSync, rmSync, statSync, existsSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';

const MDNAV = join(dirname(fileURLToPath(import.meta.url)), '..', 'mdnav.mjs');
const root = mkdtempSync(join(tmpdir(), 'mdnav-test-'));
// Work root lives OUTSIDE the fixture corpus — mdnav refuses to write inside it.
const wroot = mkdtempSync(join(tmpdir(), 'mdnav-wd-'));

let pass = 0, fail = 0;
const ok = (name, cond, detail) => {
  if (cond) { pass++; process.stdout.write(`  ok   ${name}\n`); }
  else { fail++; process.stdout.write(`  FAIL ${name}${detail ? `\n       ${detail}` : ''}\n`); }
};
const eq = (name, a, b) => ok(name, a === b, `expected ${JSON.stringify(b)}, got ${JSON.stringify(a)}`);
const loadLedger = () => readFileSync(join(wroot, 'fixed', 'reads.jsonl'), 'utf8')
  .split('\n').filter(Boolean).map((l) => JSON.parse(l));

// spawnSync, not execFileSync: mdnav writes diagnostics to stderr on success too,
// and execFileSync only surfaces stderr when the child exits non-zero.
// Pin the work dir and run so the suite is independent of the minting convention
// (which is itself tested separately, below).
const WD = ['--work-dir', wroot, '--run', 'fixed'];
function sh(args, { binary = false } = {}) {
  const r = spawnSync(process.execPath, [MDNAV, ...args, ...WD], { cwd: root, encoding: binary ? 'buffer' : 'utf8' });
  return { out: r.stdout, err: binary ? String(r.stderr) : r.stderr, code: r.status };
}
function run(args, opts) {
  const r = sh(args, opts);
  if (r.code !== 0) throw new Error(`mdnav ${args.join(' ')} exited ${r.code}\n${r.err}`);
  return r.out;
}
const runBoth = (args) => sh(args);
const runErr = (args) => sh(args).err;

// ─────────────────────────────────────────────────────────────────── fixtures

const CRLF = (s) => s.replace(/\n/g, '\r\n');

// Chat export shape: `# <full prompt>` per exchange, `---` between exchanges.
// Includes multibyte, a fenced block containing heading-like text, and a reply
// whose own structure uses H2 (which must NOT become an exchange boundary).
const chat = CRLF([
  '# can you look at the résumé parser and tell me why it drops ünicode names',
  '',
  'Sure — the parser normalises before splitting.',
  '',
  '## What I checked',
  '',
  'Three things, in order.',
  '',
  '```bash',
  '# this is a comment, not a heading',
  '## neither is this',
  '```',
  '',
  '---',
  '',
  '# ok but that doesn\'t explain the 加算 case, which is the one I actually care about',
  '',
  'Right — that path is different.',
  '',
  '---',
  '',
  '# hold on, back up. what did you mean by "normalises" in the first reply?',
  '',
  'I meant NFKC.',
  '',
  '---',
  '',
  '# fine. now show me the fix',
  '',
  'Here it is.',
  '',
  '---',
  '',
  '# last thing — does this interact with the α/β test split at all?',
  '',
  'No.',
  '',
].join('\n'));

// Paper shape: 1 H1, 15 H2, 22 H3, with LaTeX residue, an image, a very long line.
let paper = '# A Study of Something\n\nAbstract with a long line: ' + 'lorem ipsum dolor sit amet '.repeat(60) + '\n\n';
let h3budget = 22;
for (let i = 1; i <= 15; i++) {
  paper += `## Section ${i}\n\nSome prose with inline math $\\alpha_{ij} \\le \\sum_k \\beta_k$ and a citation [12].\n\n`;
  const n = Math.min(h3budget, i <= 7 ? 2 : i <= 11 ? 1 : 0);
  for (let j = 1; j <= n; j++) {
    paper += `### Subsection ${i}.${j}\n\n$$\n\\int_0^\\infty e^{-x^2}\\,dx = \\frac{\\sqrt{\\pi}}{2}\n$$\n\n![figure](./fig-${i}-${j}.png)\n\n`;
    h3budget--;
  }
}
while (h3budget > 0) { paper += `### Extra ${h3budget}\n\nfiller\n\n`; h3budget--; }

const preamble = 'Front matter prose that precedes any heading.\n\nIt must never be dropped.\n\n# First Heading\n\nBody.\n';
const headingless = Array.from({ length: 8 }, (_, i) =>
  `Paragraph ${i + 1}. This document has no headings anywhere, which is the shape a paper ` +
  `transferred from PDF often arrives in — structure present to a reader, absent to a parser.`).join('\n\n') + '\n';
const deepStart = '## Starts At H2\n\nThere is no H1 anywhere in this document.\n\n## Another\n\nMore.\n';
// A reply that emits its own bare H1 — indistinguishable from an exchange boundary.
const corrupt = '# first prompt\n\nreply text\n\n# A Heading The Model Wrote\n\nmore reply\n\n---\n\n# second prompt\n\nreply\n';
const setext = 'Introduction\n============\n\nSome text.\n\nBackground\n----------\n\nMore text.\n';

const files = { 'chat.md': chat, 'paper.md': paper, 'preamble.md': preamble, 'headingless.md': headingless, 'deep-start.md': deepStart, 'corrupt-chat.md': corrupt, 'setext.md': setext };
for (const [n, c] of Object.entries(files)) writeFileSync(join(root, n), c, 'utf8');

// ────────────────────────────────────────────────────────────────────── tests

process.stdout.write('\nmdnav acceptance\n\n');

// -- structure ---------------------------------------------------------------
process.stdout.write('structure\n');
run(['discover', '.']);
const idxOf = (id) => JSON.parse(readFileSync(join(wroot, 'fixed', 'documents', `${id}.index.json`), 'utf8'));
const inv = JSON.parse(readFileSync(join(wroot, 'fixed', 'inventory.json'), 'utf8'));
const byName = Object.fromEntries(inv.docs.map((d) => [d.name, idxOf(d.id)]));

eq('chat: 5 H1 (fenced "# comment" ignored)', byName['chat.md'].counts.h1, 5);
eq('chat: 1 H2 from the reply body', byName['chat.md'].counts.h2 ?? 0, 1);
eq('chat: CRLF detected', byName['chat.md'].newline, 'CRLF');
eq('paper: 1 H1', byName['paper.md'].counts.h1, 1);
eq('paper: 15 H2', byName['paper.md'].counts.h2, 15);
eq('paper: 22 H3', byName['paper.md'].counts.h3, 22);
eq('preamble: synthetic H0000 emitted', byName['preamble.md'].headings[0].title, 'PREAMBLE');
eq('headingless: single BODY unit', byName['headingless.md'].headings[0].title, 'BODY');
eq('setext: suspects reported, not silently misread', byName['setext.md'].setextSuspects.length, 2);

// -- chat consistency check --------------------------------------------------
process.stdout.write('\nstructural signals (reported, not asserted)\n');
eq('H1 count and break count align', byName['chat.md'].breaks.aligned, 'aligned');
eq('reply-written H1: more headings than breaks', byName['corrupt-chat.md'].breaks.aligned, 'more-h1');
eq('counts surfaced, not a verdict', `${byName['corrupt-chat.md'].counts.h1}/${byName['corrupt-chat.md'].breaks.count}`, '3/1');
ok('no breaks: no relation claimed at all', byName['paper.md'].breaks.aligned === null);
// The opposite deviation must be distinguished, not lumped in with the first.
writeFileSync(join(root, 'unlabelled.md'), '# only prompt\n\nreply\n\n---\n\nunlabelled turn\n\n---\n\nanother\n', 'utf8');
run(['index', 'unlabelled.md']);
const inv2 = JSON.parse(readFileSync(join(wroot, 'fixed', 'inventory.json'), 'utf8'));
const unlabelledId = inv2.docs.find((d) => d.name === 'unlabelled.md').id;
eq('unheaded boundaries: more breaks than headings', idxOf(unlabelledId).breaks.aligned, 'more-breaks');

// -- thematic breaks as an alternative partition basis ------------------------
process.stdout.write('\nbreak partition (--by breaks)\n');
const segOut = run(['outline', unlabelledId, '--by', 'breaks']);
const segIds = [...segOut.matchAll(/^\[(S\d+)@/gm)].map((m) => m[1]);
eq('breaks yield one segment per delimited turn', segIds.length, 3);
const segSrc = readFileSync(join(root, 'unlabelled.md'));
const segJoin = Buffer.concat(segIds.map((s) => run(['read', unlabelledId, '--heading', s], { binary: true })));
ok('segments partition the document exactly', segJoin.equals(segSrc), `${segJoin.length} vs ${segSrc.length}`);
ok('segment labels come from the first real line', /only prompt/.test(segOut), segOut);
ok('heading partition and break partition disagree here, as they should',
  [...run(['outline', unlabelledId, '--depth', '1']).matchAll(/^\[/gm)].length !== segIds.length);
rmSync(join(wroot, 'fixed', 'reads.jsonl'), { force: true });
run(['read', unlabelledId, '--heading', segIds[0]], { binary: true });
const segCov = run(['coverage', unlabelledId, '--by', 'breaks']);
ok('segment reads participate in coverage', /unread @breaks \(2\)/.test(segCov), segCov);
ok('ledger stamps the basis, not a meaningless depth', /grain=\{breaks:1\}/.test(segCov), segCov);

// -- the partition invariant -------------------------------------------------
process.stdout.write('\npartition (units at depth D reproduce the source exactly)\n');
function partitionCheck(name, docId, depth) {
  const src = readFileSync(join(root, name));
  const out = run(['outline', docId, '--depth', String(depth)]);
  const ids = [...out.matchAll(/^\[(\w+)@/gm)].map((m) => m[1]);
  const parts = ids.map((h) => run(['read', docId, '--heading', h, '--depth', String(depth)], { binary: true }));
  const joined = Buffer.concat(parts);
  ok(`${name} @depth${depth}: ${ids.length} units, byte-identical to source`,
    joined.equals(src), `source ${src.length} B vs units ${joined.length} B`);
}
const id = Object.fromEntries(inv.docs.map((d) => [d.name, d.id]));
partitionCheck('chat.md', id['chat.md'], 1);
partitionCheck('chat.md', id['chat.md'], 2);
partitionCheck('paper.md', id['paper.md'], 1);
partitionCheck('paper.md', id['paper.md'], 2);
partitionCheck('paper.md', id['paper.md'], 3);
partitionCheck('preamble.md', id['preamble.md'], 1);
partitionCheck('headingless.md', id['headingless.md'], 1);
partitionCheck('deep-start.md', id['deep-start.md'], 1);   // no H1 exists — must still partition
partitionCheck('deep-start.md', id['deep-start.md'], 2);

// -- extents -----------------------------------------------------------------
process.stdout.write('\nextents\n');
const paperId = id['paper.md'];
const unit2 = run(['read', paperId, '--heading', 'H0001', '--depth', '2', '--extent', 'unit'], { binary: true });
const sub2 = run(['read', paperId, '--heading', 'H0001', '--depth', '2', '--extent', 'subtree'], { binary: true });
ok('unit ⊂ subtree for a non-leaf active heading', unit2.length < sub2.length, `${unit2.length} vs ${sub2.length}`);
eq('subtree of the single H1 is the whole document', sub2.length, statSync(join(root, 'paper.md')).size);
ok('unit begins at the heading line', unit2.subarray(0, 2).toString() === '# ');

// -- merge and batch ---------------------------------------------------------
process.stdout.write('\nmerge and batch reads\n');
const chatId = id['chat.md'];
// Exchange anchors are not consecutive: the reply's own H2 occupies an id between
// them. Derive the depth-1 units rather than assuming numbering.
const units1 = [...run(['outline', chatId, '--depth', '1']).matchAll(/^\[(\w+)@/gm)].map((m) => m[1]);
eq('chat has 5 exchange units at depth 1', units1.length, 5);
const merged = run(['read', chatId, '--from', units1[0], '--to', units1[2], '--depth', '1'], { binary: true });
const single = units1.slice(0, 3).map((h) => run(['read', chatId, '--heading', h, '--depth', '1'], { binary: true }));
ok('--from/--to returns one contiguous span equal to its units', merged.equals(Buffer.concat(single)));
const batch = run(['read', chatId, '--headings', `${units1[0]},${units1[3]}`, '--depth', '1']);
ok('--headings emits one marker per span', (batch.match(/<!-- mdnav D\d+:H\d+ -->/g) ?? []).length === 2);
ok('batch is discontiguous (skips the intervening units)', batch.length < Buffer.concat(single).length + 200);

// -- coverage ----------------------------------------------------------------
process.stdout.write('\ncoverage\n');
rmSync(join(wroot, 'fixed', 'reads.jsonl'), { force: true });
run(['read', chatId, '--heading', units1[0], '--depth', '1'], { binary: true });
run(['read', chatId, '--heading', units1[1], '--depth', '1'], { binary: true });
const cov = run(['coverage', chatId, '--depth', '1']);
ok('unread anchors listed at the stated depth',
  new RegExp(`unread @depth1 \\(3\\): ${units1.slice(2).join(' ')}`).test(cov), cov);
// Overlapping reads must not double-count: a subtree read subsumes its units.
run(['read', chatId, '--heading', units1[0], '--depth', '1', '--extent', 'subtree'], { binary: true });
const cov2 = run(['coverage', chatId, '--depth', '1']);
const pct = /(\d+\.\d)%/.exec(cov2);
ok('overlapping spans merge rather than double-count', pct && parseFloat(pct[1]) <= 100, cov2);
for (const h of units1.slice(2)) run(['read', chatId, '--heading', h, '--depth', '1'], { binary: true });
ok('full sweep reports complete', /complete @depth1/.test(run(['coverage', chatId, '--depth', '1'])));

// -- locate ------------------------------------------------------------------
process.stdout.write('\nlocate\n');
const loc = run(['locate', 'normalis', chatId, '--depth', '1']);
ok('locate returns anchors, never content blocks', /^D\d+:H\d+@\w+\s+L\d+\s+/m.test(loc), loc);
ok('locate finds the reframe turn', /back up/.test(run(['locate', 'back up', chatId, '--depth', '1'])));

// -- windows -----------------------------------------------------------------
process.stdout.write('\nwindow fallback\n');
const hlId = id['headingless.md'];
run(['outline', hlId, '--windows', '250']);
const hlIdx = idxOf(hlId);
ok('windows created for a headingless document', hlIdx.windows.length > 1, `${hlIdx.windows.length}`);
const wsrc = readFileSync(join(root, 'headingless.md'));
const wjoin = Buffer.concat(hlIdx.windows.map((w) => run(['read', hlId, '--heading', w.wid], { binary: true })));
ok('windows partition the document exactly', wjoin.equals(wsrc), `${wjoin.length} vs ${wsrc.length}`);

// A long single-line blob has no paragraph or line boundary to snap to. Real
// transcripts contain these (base64, minified JSON), and an unbounded search for
// a boundary makes one window swallow the remainder of the document.
const blobLine = 'QUJDRA' + 'x7Yz'.repeat(3000) + 'é≈中';         // no newlines, multibyte tail
writeFileSync(join(root, 'blob.md'), `# Heading\n\nintro\n\n${blobLine}\n\ntail paragraph\n`, 'utf8');
run(['index', 'blob.md']);
const blobId = JSON.parse(readFileSync(join(wroot, 'fixed', 'inventory.json'), 'utf8')).docs.find((d) => d.name === 'blob.md').id;
const blobOut = run(['outline', blobId, '--windows', '2048']);
const bIdx = idxOf(blobId), bsrc = readFileSync(join(root, 'blob.md'));
// The blob is emitted whole rather than sliced: every boundary is a line break,
// so a stretch with no line break cannot be subdivided. Reported, not hidden.
ok('every window boundary falls after a newline',
  bIdx.windows.every((w) => w.start === 0 || bsrc[w.start - 1] === 0x0a), JSON.stringify(bIdx.windows.map((w) => w.start)));
ok('the unbroken run is one window, flagged as such', /UNBROKEN/.test(blobOut), blobOut);
// The blob absorbs whatever precedes it back to the last newline before the
// first target — unavoidable when boundaries must be newlines — but it must not
// run to EOF and swallow the trailing prose.
ok('the blob does not swallow trailing content',
  bIdx.windows.length >= 2 && bIdx.windows.at(-1).end === bsrc.length
  && bsrc.subarray(bIdx.windows.at(-1).start).toString('utf8').includes('tail paragraph'),
  JSON.stringify(bIdx.windows));
const bjoin = Buffer.concat(bIdx.windows.map((w) => run(['read', blobId, '--heading', w.wid], { binary: true })));
ok('blob windows partition exactly', bjoin.equals(bsrc), `${bjoin.length} vs ${bsrc.length}`);
ok('no window splits a UTF-8 codepoint', bIdx.windows.every((w) => (bsrc[w.start] & 0xc0) !== 0x80));
ok('long line surfaced in the index', bIdx.maxLine.bytes > 10000, JSON.stringify(bIdx.maxLine));

// -- noise triage and stripping ----------------------------------------------
process.stdout.write('\nnoise triage and --strip\n');
const png = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=='.repeat(40);
const noisy = [
  '# a prompt with an embedded screenshot',
  '',
  '<div align="center">⁂</div>',
  '',
  '<img src="https://r2cdn.perplexity.ai/pplx-full-logo-primary-dark%402x.png" style="height:64px;margin-right:32px"/>',
  '',
  `![screenshot](data:image/png;base64,${png})`,
  '',
  'Real prose that must survive stripping intact, including a < b and 3 > 2.',
  '',
].join('\n');
writeFileSync(join(root, 'noisy.md'), noisy, 'utf8');
run(['index', 'noisy.md']);
const nId = JSON.parse(readFileSync(join(wroot, 'fixed', 'inventory.json'), 'utf8')).docs.find((d) => d.name === 'noisy.md').id;
const nIdx = idxOf(nId);
ok('embedded file measured whole, wrapper included', nIdx.noise['data-uri'].bytes > 3000, JSON.stringify(nIdx.noise['data-uri']));
ok('html furniture measured', nIdx.noise.html.count >= 3, JSON.stringify(nIdx.noise.html));
ok('noise ratio dominates the document', nIdx.noise.ratio > 0.8, `${nIdx.noise.ratio}`);
ok('outline flags the noisy unit before it is read', /noise=/.test(run(['outline', nId, '--depth', '1'])));

const rawRead = run(['read', nId, '--heading', 'H0001', '--depth', '1'], { binary: true });
const stripped = run(['read', nId, '--heading', 'H0001', '--depth', '1', '--strip', 'all']);
ok('stripping removes the bulk', stripped.length < rawRead.length / 8, `${stripped.length} vs ${rawRead.length}`);
ok('prose survives verbatim', stripped.includes('Real prose that must survive stripping intact'), stripped);
ok('the heading survives', stripped.includes('# a prompt with an embedded screenshot'));
ok('inner text of stripped tags is kept', stripped.includes('⁂'), stripped);
ok('elision leaves an addressed placeholder', /<!-- mdnav: elided data-uri [\d.]+ KiB @\d+\.\.\d+ -->/.test(stripped), stripped);
ok('no ![]() debris left where the wrapper was elided', !/!\[\]\(\s*\)/.test(stripped), stripped);
ok('prose punctuation is not mistaken for markup', stripped.includes('a < b and 3 > 2'), stripped);
ok('the img tag is gone', !stripped.includes('r2cdn.perplexity.ai'), stripped);
eq('selective strip leaves the other kind alone',
  run(['read', nId, '--heading', 'H0001', '--depth', '1', '--strip', 'html']).includes('data:image/png;base64'), true);

// An embedded file and a reference to an external one are different species:
// one inlines the whole file, the other costs a URL. --strip all must not remove
// the cheap, informative one.
writeFileSync(join(root, 'remote-img.md'), `# turn\n\n![chart](https://example.com/figure-3.png)\n\nprose after.\n`, 'utf8');
run(['index', 'remote-img.md']);
const rId = JSON.parse(readFileSync(join(wroot, 'fixed', 'inventory.json'), 'utf8')).docs.find((d) => d.name === 'remote-img.md').id;
eq('external reference counted separately', idxOf(rId).noise['image-ref'].count, 1);
eq('external reference is not counted as strippable noise', idxOf(rId).noise.bytes, 0);
const rKeep = run(['read', rId, '--heading', 'H0001', '--depth', '1', '--strip', 'all']);
ok('--strip all keeps the external reference', rKeep.includes('![chart](https://example.com/figure-3.png)'), rKeep);
const rDrop = run(['read', rId, '--heading', 'H0001', '--depth', '1', '--strip', 'image-ref']);
ok('image-ref is available when explicitly asked for', !rDrop.includes('example.com'), rDrop);
ok('surrounding prose is intact either way', rKeep.includes('prose after.') && rDrop.includes('prose after.'));

// Presigned object-store links share the []()/![]() shape with real citations, so
// the TARGET decides — signing parameters, not URL length. A long permalink is
// signal; a presigned URL is dead by construction. And the `!` decides the
// remedy: an image has nothing to keep, a link's label names what was cited.
const sig = `https://bucket.s3.amazonaws.com/f.png?X-Amz-Credential=AKIA%2F20260410&X-Amz-Signature=${'a'.repeat(200)}`;
const permalink = 'https://github.com/aghado01/PowerShellCore/blob/b7d9b20c367b91dd9f02f09b1a2c3d4e5f60718293a4b5c6/src/Very/Deeply/Nested/Path/To/A/Module.psm1#L120-L188';
writeFileSync(join(root, 'signed.md'), [
  '# turn', '',
  `An image: ![](${sig})`, '',
  `A citation: [threadparser-notes.md](${sig})`, '',
  `A permalink: [Module.psm1](${permalink})`, '',
  'keep this prose.', '',
].join('\n'), 'utf8');
run(['index', 'signed.md']);
const sId = JSON.parse(readFileSync(join(wroot, 'fixed', 'inventory.json'), 'utf8')).docs.find((d) => d.name === 'signed.md').id;
eq('both signed links detected, permalink not', idxOf(sId).noise['signed-url'].count, 2);
const sOut = run(['read', sId, '--heading', 'H0001', '--depth', '1', '--strip', 'all']);
ok('presigned URLs are gone', !sOut.includes('X-Amz-Signature'), sOut);
ok('the citation label survives the dead URL', sOut.includes('threadparser-notes.md'), sOut);
ok('the signed image leaves nothing behind', /^An image:[ \t]*$/m.test(sOut), JSON.stringify(sOut.slice(0, 200)));
ok('a long permalink is untouched — length is not the discriminator', sOut.includes(permalink), sOut);
ok('surrounding prose intact', sOut.includes('keep this prose.') && sOut.includes('# turn'), sOut);

// --strip-match: the reader aims the same machinery at a species mdnav has no
// pattern for at all.
const cOut = run(['read', sId, '--heading', 'H0001', '--depth', '1', '--strip-match', 'A permalink:[^\\n]*']);
ok('custom pattern elides what it targets', !cOut.includes('Module.psm1'), cOut);
ok('custom pattern leaves everything else', cOut.includes('keep this prose.'), cOut);
ok('invalid custom pattern is rejected', runBoth(['read', sId, '--heading', 'H0001', '--strip-match', '([']).code !== 0);
ok('source is untouched by stripping', readFileSync(join(root, 'noisy.md'), 'utf8') === noisy);
ok('unstripped read is still byte-exact', rawRead.equals(readFileSync(join(root, 'noisy.md'))));
ok('ledger records elided bytes', loadLedger().some((r) => r.doc === nId && r.elided > 3000));
ok('ledger records the elided spans, not just a total',
  loadLedger().some((r) => r.doc === nId && Array.isArray(r.elidedSpans) && r.elidedSpans.length > 0));
// Elided bytes were skipped, not read. Coverage must not count them.
rmSync(join(wroot, 'fixed', 'reads.jsonl'), { force: true });
run(['read', nId, '--heading', 'H0001', '--depth', '1', '--strip', 'all'], { binary: true });
const nCov = run(['coverage', nId, '--depth', '1']);
const covPct = parseFloat(/(\d+\.\d)%/.exec(nCov)[1]);
ok('coverage subtracts elided bytes rather than crediting them', covPct < 20, nCov);
ok('coverage names what was elided', /elided=/.test(nCov), nCov);
ok('bad --strip kind is rejected', runBoth(['read', nId, '--heading', 'H0001', '--strip', 'nonsense']).code !== 0);

// The warning must precede the payload — once bytes are on stdout the cost is paid.
writeFileSync(join(root, 'huge-img.md'), `# turn\n\n![shot](data:image/png;base64,${'A'.repeat(200000)})\n\nprose.\n`, 'utf8');
run(['index', 'huge-img.md']);
const hId = JSON.parse(readFileSync(join(wroot, 'fixed', 'inventory.json'), 'utf8')).docs.find((d) => d.name === 'huge-img.md').id;
ok('unstripped read of a heavy span warns first',
  /carries [\d.]+ KiB of embedded data or HTML markup/.test(sh(['read', hId, '--heading', 'H0001', '--depth', '1'], { binary: true }).err));
ok('a stripped read does not nag', !/Re-run with --strip/.test(runErr(['read', hId, '--heading', 'H0001', '--depth', '1', '--strip', 'all'])));

// -- construct profiling -----------------------------------------------------
process.stdout.write('\nconstruct profile\n');
// A turn-delimited document: the delimiter recurs evenly, decoration does not.
const turns = Array.from({ length: 12 }, (_, i) =>
  `# turn ${i + 1} asking about something\n\nSome reply prose here for turn ${i + 1}.\n\n` +
  (i % 4 === 0 ? '> a pull quote that only appears sometimes\n\n' : '') +
  '```powershell\nGet-ChildItem\n```\n\n').join('');
writeFileSync(join(root, 'cadence.md'), turns, 'utf8');
run(['index', 'cadence.md']);
const cId = JSON.parse(readFileSync(join(wroot, 'fixed', 'inventory.json'), 'utf8')).docs.find((d) => d.name === 'cadence.md').id;
const prof = sh(['profile', cId]);
ok('profile lists constructs with byte shares', /heading h1\s+12\s/.test(prof.out), prof.out);
ok('fence info strings are histogrammed', /powershell×12/.test(prof.out), prof.out);
ok('the even delimiter is flagged as a candidate', /evenly spaced.*heading h1/.test(prof.err), prof.err);
ok('the bursty construct is not flagged', !/evenly spaced.*blockquote/.test(prof.err), prof.err);
ok('paragraphs are never delimiter candidates', !/evenly spaced.*paragraph/.test(prof.err), prof.err);
ok('fenced content does not leak into other construct counts',
  !/heading h1\s+(1[3-9]|[2-9]\d)/.test(prof.out), prof.out);
// A document with no headings at all yields no candidate.
ok('no candidate where nothing divides the document', !/evenly spaced/.test(sh(['profile', hlId]).err));

// Per-unit composition: decide whether to open a unit without opening it.
const comp = run(['outline', cId, '--depth', '1', '--comp']);
ok('units carry a composition sketch', /\[(prose|code|list)\d+/.test(comp), comp.slice(0, 300));
const nComp = run(['outline', nId, '--depth', '1', '--comp']);
// nId is the noisy fixture: an embedded image dominates it.
ok('an embedded file dominates its unit sketch', /\[data\d\d/.test(nComp), nComp);
ok('embedded data is not reported as prose', !/\[prose9\d/.test(nComp), nComp);
// HTML furniture must not be mislabelled as embedded data — different hazards.
writeFileSync(join(root, 'htmlish.md'), `# t\n\n<div align="center">x</div>\n\n<span>y</span>\n\nshort.\n`, 'utf8');
run(['index', 'htmlish.md']);
const htId = JSON.parse(readFileSync(join(wroot, 'fixed', 'inventory.json'), 'utf8')).docs.find((d) => d.name === 'htmlish.md').id;
const htComp = run(['outline', htId, '--depth', '1', '--comp']);
ok('html noise is labelled html, not data', /html\d+/.test(htComp) && !/data\d+/.test(htComp), htComp);

// -- marks: enumerate any construct as runs, with readable spans ---------------
process.stdout.write('\nmarks\n');
// A blank line must BREAK a run — merging across one hides whatever follows
// behind whatever preceded it. This is the exact bug that cost a turn in a real dive.
writeFileSync(join(root, 'quotes.md'), [
  '# doc', '', '> Framing statement from the model.', '',
  '> a substantive user turn that must not be swallowed by the quote above', '',
  'Reply prose.', '', '> another quote', '', 'More prose.', '',
].join('\n'), 'utf8');
run(['index', 'quotes.md']);
const qId = JSON.parse(readFileSync(join(wroot, 'fixed', 'inventory.json'), 'utf8')).docs.find((d) => d.name === 'quotes.md').id;
const marks = sh(['marks', qId, '--kind', 'blockquote']);
eq('a blank line breaks a run', (marks.out.match(/\n/g) ?? []).length, 3);
ok('adjacent quotes stay distinct', /Framing statement/.test(marks.out) && /a substantive user turn/.test(marks.out), marks.out);
ok('each run reports a byte span and containing anchor', /^\s*\d+\.\.\d+\s+[\d.]+ \w+\s+\d+L\s+D\d+:H\d+/m.test(marks.out), marks.out);
ok('runs below --min are excluded', !/another quote/.test(run(['marks', qId, '--kind', 'blockquote', '--min', '40'])));
ok('fence info strings are shown', /\[powershell\]/.test(run(['marks', cId, '--kind', 'fence'])), '');
ok('an absent construct says so rather than erroring', /no table runs/.test(run(['marks', qId, '--kind', 'table'])));

// read --span: the substrate itself, so a marked run is directly readable
const spanRow = /^\s*(\d+)\.\.(\d+)/m.exec(marks.out);
const spanOut = run([`read`, qId, '--span', `${spanRow[1]}..${spanRow[2]}`], { binary: true });
ok('read --span returns exactly those bytes',
  spanOut.equals(readFileSync(join(root, 'quotes.md')).subarray(+spanRow[1], +spanRow[2])), spanOut.toString());
ok('an out-of-range span is rejected', runBoth(['read', qId, '--span', '0..999999']).code !== 0);
ok('a malformed span is rejected', runBoth(['read', qId, '--span', 'abc']).code !== 0);

// -- runtime artifact hygiene -------------------------------------------------
process.stdout.write('\nartifact hygiene\n');
const raw = (args, cwd = tmpdir()) => spawnSync(process.execPath, [MDNAV, ...args], { cwd, encoding: 'utf8' });

// Artifacts are LOCAL to the corpus — that is where you look for them — but under
// a dot directory, so a later discover cannot index the reader's own exhaust.
const corpus = mkdtempSync(join(tmpdir(), 'mdnav-corpus-'));
writeFileSync(join(corpus, 'a.md'), '# one\n\nalpha\n\n# two\n\nbeta\n', 'utf8');
const m1 = raw(['discover', corpus]);
ok('mints beside the corpus', m1.status === 0, m1.stderr);
const localLatest = readFileSync(join(corpus, '.doc-dive', 'LATEST'), 'utf8').trim();
ok('run directory is a UTC stamp', /^\d{8}_\d{6}$/.test(localLatest), localLatest);
ok('the run exists under <corpus>/.doc-dive/', statSync(join(corpus, '.doc-dive', localLatest, 'inventory.json')).isFile());

// The dot prefix is the whole hygiene mechanism: rediscovery must not see them.
const rediscover = raw(['discover', corpus]);
const inv3 = JSON.parse(readFileSync(join(corpus, '.doc-dive', readFileSync(join(corpus, '.doc-dive', 'LATEST'), 'utf8').trim(), 'inventory.json'), 'utf8'));
ok('rediscovery does not index prior artifacts', inv3.docs.every((d) => !d.path.includes('.doc-dive')), JSON.stringify(inv3.docs.map((d) => d.name)));
eq('rediscovery finds only the real source', inv3.docs.length, 1);

// A second run is a new stamp; the first survives.
ok('a second run mints a distinct stamp', readFileSync(join(corpus, '.doc-dive', 'LATEST'), 'utf8').trim() !== localLatest);
ok('the earlier run survives', statSync(join(corpus, '.doc-dive', localLatest, 'inventory.json')).isFile());

// Later verbs follow the last run without the path being retyped.
const follow = raw(['outline', 'D001', '--depth', '1']);
ok('later verbs follow the last run from any cwd', follow.status === 0 && /H0001/.test(follow.stdout), follow.stderr);

// Adjacent is fine; visible is not.
const visible = raw(['discover', corpus, '--work-dir', join(corpus, 'notes')]);
ok('refuses a work dir discover could see',
  visible.status !== 0 && /where 'discover' can see them/.test(visible.stderr), visible.stderr);
const hidden = raw(['discover', corpus, '--work-dir', join(corpus, '.scratch')]);
ok('accepts any dot-prefixed location inside the corpus', hidden.status === 0, hidden.stderr);
rmSync(corpus, { recursive: true, force: true });

// A curated corpus you do not want touched: anchor the run somewhere else
// entirely, e.g. a project's own .claude/ directory. Precedence and locality
// still hold — stamped run, LATEST, later verbs follow it.
const library = mkdtempSync(join(tmpdir(), 'mdnav-library-'));
const project = mkdtempSync(join(tmpdir(), 'mdnav-project-'));
writeFileSync(join(library, 'ref.md'), '# ref\n\ncontent\n', 'utf8');
const anchored = raw(['discover', library, '--work-dir', join(project, '.claude', 'doc-dive')]);
ok('an explicit anchor outside the corpus is accepted', anchored.status === 0, anchored.stderr);
ok('the curated corpus is left untouched', !existsSync(join(library, '.doc-dive')));
const projLatest = readFileSync(join(project, '.claude', 'doc-dive', 'LATEST'), 'utf8').trim();
ok('the anchored run is still stamped', /^\d{8}_\d{6}(-\d+)?$/.test(projLatest), projLatest);
ok('later verbs follow the anchored run', /H0001/.test(raw(['outline', 'D001', '--depth', '1']).stdout));
// $MDNAV_WORK_DIR does the same without repeating the flag.
const envRun = spawnSync(process.execPath, [MDNAV, 'discover', library], {
  cwd: tmpdir(), encoding: 'utf8', env: { ...process.env, MDNAV_WORK_DIR: join(project, 'envdir') },
});
ok('$MDNAV_WORK_DIR anchors without the flag', envRun.status === 0 && existsSync(join(project, 'envdir', 'LATEST')), envRun.stderr);
rmSync(library, { recursive: true, force: true }); rmSync(project, { recursive: true, force: true });

// Spread-out documents anchor on the first.
const c1 = mkdtempSync(join(tmpdir(), 'mdnav-c1-')), c2 = mkdtempSync(join(tmpdir(), 'mdnav-c2-'));
writeFileSync(join(c1, 'x.md'), '# x\n\nex\n', 'utf8');
writeFileSync(join(c2, 'y.md'), '# y\n\nwhy\n', 'utf8');
const spread = raw(['discover', join(c1, 'x.md'), join(c2, 'y.md')]);
ok('spread corpora anchor on the first document', spread.status === 0 && statSync(join(c1, '.doc-dive')).isDirectory(), spread.stderr);
ok('no artifacts at the second location', !existsSync(join(c2, '.doc-dive')));
rmSync(c1, { recursive: true, force: true }); rmSync(c2, { recursive: true, force: true });

// -- staleness and immutability ----------------------------------------------
process.stdout.write('\nstaleness and immutability\n');
const before = readFileSync(join(root, 'paper.md'));
run(['outline', paperId, '--depth', '2']);
ok('indexing does not modify the source', readFileSync(join(root, 'paper.md')).equals(before));
run(['read', paperId, '--heading', 'H0002', '--depth', '2'], { binary: true });
ok('reading does not modify the source', readFileSync(join(root, 'paper.md')).equals(before));

const h1digest = idxOf(chatId).headings[0].digest;
const warnMismatch = runErr(['read', chatId, '--heading', `H0001@0000`, '--depth', '1']);
ok('anchor digest mismatch is reported', /does not match current heading digest/.test(warnMismatch), warnMismatch);
ok('matching digest is silent about drift', !/does not match/.test(runErr(['read', chatId, '--heading', `H0001@${h1digest}`, '--depth', '1'])));

writeFileSync(join(root, 'chat.md'), chat + CRLF('\n---\n\n# a sixth prompt appended later\n\nreply\n'), 'utf8');
const staleErr = runErr(['outline', chatId, '--depth', '1']);
ok('changed source invalidates the prior index', /stale/.test(staleErr), staleErr);
eq('rebuilt index reflects the change', idxOf(chatId).counts.h1, 6);

// -- error surfaces ----------------------------------------------------------
process.stdout.write('\nerror surfaces\n');
const bad = runBoth(['read', paperId, '--heading', 'H0002', '--depth', '1', '--extent', 'unit']);
ok('reading an inactive heading as a unit fails loudly', bad.code !== 0 && /not active at depth/.test(bad.err), bad.err);
ok('unknown anchor fails loudly', runBoth(['read', paperId, '--heading', 'H9999']).code !== 0);

// ───────────────────────────────────────────────────────────────────── report
process.stdout.write(`\n${pass} passed, ${fail} failed\n`);
if (!process.env.MDNAV_KEEP) { rmSync(root, { recursive: true, force: true }); rmSync(wroot, { recursive: true, force: true }); }
else process.stdout.write(`fixtures kept at ${root}\n`);
process.exit(fail ? 1 : 0);
