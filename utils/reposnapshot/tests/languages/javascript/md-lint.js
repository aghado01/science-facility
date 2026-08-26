#!/usr/bin/env node
// md-lint.js — markdown STRUCTURE lint for codex deliverables (the non-math half of the standard: heading
// hierarchy §5, spacing hygiene §4, Contents §6). Math validity is a separate audit (src/audits/math-render).
// PowerShell (src/audits/md-lint.ps1) orchestrates; markdownlint does the linting.
//
//   node md-lint.js --markdownlint <package-dir> --file <md> [--config <json>]
//
// Prints one compact JSON line: {file, total, issues:[{line, rule, desc, detail}]}. Exit 0 on a produced
// report (read .total), 2 on input error.
'use strict';
const fs = require('fs');
const path = require('path');
const { pathToFileURL } = require('url');

function argument(args, name) {
  const index = args.indexOf(name);
  return index >= 0 ? args[index + 1] : undefined;
}

(async () => {
  const args = process.argv.slice(2);
  const fi = args.indexOf('--file');
  const ci = args.indexOf('--config');
  const markdownlintDir = argument(args, '--markdownlint');
  if (!markdownlintDir || fi < 0 || !args[fi + 1]) {
    console.error('usage: md-lint.js --markdownlint <package-dir> --file <md> [--config <json>]');
    process.exit(2);
  }
  let lint;
  try {
    const packageRoot = path.resolve(markdownlintDir);
    const manifest = JSON.parse(fs.readFileSync(path.join(packageRoot, 'package.json'), 'utf8'));
    const exported = manifest.exports && manifest.exports['./promise'];
    if (typeof exported !== 'string') throw new Error("package does not export './promise'");
    ({ lint } = await import(pathToFileURL(path.join(packageRoot, exported)).href));
  } catch (e) {
    console.error('markdownlint dependency error: ' + e.message);
    process.exit(2);
  }
  const file = args[fi + 1];
  let config = { default: true, MD013: false };
  const cfgPath = ci >= 0 ? args[ci + 1] : path.join(__dirname, 'codex.markdownlint.json');
  try { if (fs.existsSync(cfgPath)) config = JSON.parse(fs.readFileSync(cfgPath, 'utf8')); }
  catch (e) { console.error('config error: ' + e.message); process.exit(2); }
  let res;
  try { res = await lint({ files: [file], config }); }
  catch (e) { console.error('lint error: ' + e.message); process.exit(2); }
  const issues = (res[file] || [])
    .map(e => ({ line: e.lineNumber, rule: (e.ruleNames || []).join('/'), desc: e.ruleDescription, detail: e.errorDetail || null }))
    .sort((a, b) => a.line - b.line);
  console.log(JSON.stringify({ file, total: issues.length, issues }));
})();
