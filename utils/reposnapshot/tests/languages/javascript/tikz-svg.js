// tikz-svg.js — batch TikZ/tikz-cd -> SVG via node-tikzjax (wasm TeX + dvi2svg).
//
// One node invocation renders a whole paper's diagrams (wasm init is the expensive part).
// stdin/argv contract, mirroring katex-check.js's role as the PS-orchestrated worker:
//
//   node tikz-svg.js <jobs.json> <outdir> --tikzjax <package-dir>
//
// jobs.json: { "jobs": [ { "id": "diagram-1", "source": "\\begin{tikzpicture}...\\end{tikzpicture}",
//                          "tikzLibraries": "cd,arrows.meta", "texPackages": {"tikz-cd": ""},
//                          "preamble": "\\tikzset{...}" } ] }
//
// Per-job fault isolation: a diagram that fails to compile reports {ok:false,error} and never kills
// the batch. Output: <outdir>/<id>.svg per success; a JSON report on stdout.

const fs = require('fs');
const path = require('path');

async function main() {
  const args = process.argv.slice(2);
  const [jobsPath, outDir] = args;
  const ti = args.indexOf('--tikzjax');
  const tikzjaxDir = ti >= 0 ? args[ti + 1] : undefined;
  if (!jobsPath || !outDir || !tikzjaxDir) {
    console.error('usage: node tikz-svg.js <jobs.json> <outdir> --tikzjax <package-dir>');
    process.exit(2);
  }
  const packageRoot = path.resolve(tikzjaxDir);
  const manifest = JSON.parse(fs.readFileSync(path.join(packageRoot, 'package.json'), 'utf8'));
  if (!manifest.main) throw new Error('node-tikzjax package has no main entry');
  const mod = require(path.join(packageRoot, manifest.main));
  const tex2svg = mod.default || mod;
  const { jobs } = JSON.parse(fs.readFileSync(jobsPath, 'utf8'));
  fs.mkdirSync(outDir, { recursive: true });

  const report = [];
  for (const job of jobs) {
    try {
      let source = job.source || '';
      if (!/\\begin\{document\}/.test(source)) {
        source = '\\begin{document}\n' + source + '\n\\end{document}';
      }
      const opts = {
        showConsole: false,
        texPackages: job.texPackages || {},
        tikzLibraries: job.tikzLibraries || '',
        addToPreamble: job.preamble || '',
        embedFontCss: true,   // self-contained SVG: renders on GitHub without external font fetches
      };
      const svg = await tex2svg(source, opts);
      const file = path.join(outDir, job.id + '.svg');
      fs.writeFileSync(file, svg, 'utf8');
      report.push({ id: job.id, ok: true, bytes: svg.length });
    } catch (e) {
      report.push({ id: job.id, ok: false, error: String(e && e.message ? e.message : e).slice(0, 500) });
    }
  }
  process.stdout.write(JSON.stringify({ total: jobs.length, ok: report.filter(r => r.ok).length, results: report }));
}

main().catch(e => { console.error(String(e)); process.exit(1); });
