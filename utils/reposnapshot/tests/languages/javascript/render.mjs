// pig-lane raster tool — render PDF page(s) or clip-region(s) to PNG via MuPDF (WASM).
//
//   single:  node render.mjs --mupdf <package-dir> --pdf <in.pdf> --out <out.png> [--page N] [--bbox x0,y0,x1,y1] [--dpi D]
//   batch:   node render.mjs --mupdf <package-dir> --pdf <in.pdf> --jobs <jobs.json> [--dpi D]
//
// A batch --jobs file is a JSON array of { "pdf": "<path>"?, "page": N, "bbox": [x0,y0,x1,y1]|null,
// "out": "<path>" }; batch opens the WASM once and renders every job (the fast path for a paper's
// figures). Each job MAY carry its own "pdf" (documents are opened once and cached by path) so one
// invocation converts a whole paper's separate figure PDFs / per-diagram compiled PDFs; a job that
// omits "pdf" falls back to the top-level --pdf. --pdf is optional when every job specifies its own.
// --page is 0-based. --bbox is PDF points (y-up, PdfPig [left,bottom,right,top]); omit to render the
// whole page. Rasterizes whatever is drawn in the region — vector TikZ AND embedded bitmaps alike.
// Prints one JSON results array to stdout: [{out, ok, bytes, w, h} | {out, ok:false, error}].
// Exit 0 (results printed, even if some jobs failed), 2 usage.
import fs from "node:fs"
import path from "node:path"
import { pathToFileURL } from "node:url"

function argOf(name, def) {
    const i = process.argv.indexOf("--" + name)
    return (i >= 0 && i + 1 < process.argv.length) ? process.argv[i + 1] : def
}

const mupdfDir = argOf("mupdf", null)
if (!mupdfDir) {
    process.stderr.write("usage: --mupdf <package-dir> --pdf <p> (--jobs <json> | --out <png>) [--dpi D]\n")
    process.exit(2)
}
let mupdf
try {
    const packageRoot = path.resolve(mupdfDir)
    const manifest = JSON.parse(fs.readFileSync(path.join(packageRoot, "package.json"), "utf8"))
    const exported = manifest.exports?.["."]
    const entry = typeof exported === "string" ? exported : exported?.default
    if (!entry) throw new Error("package does not export a default entry")
    mupdf = await import(pathToFileURL(path.join(packageRoot, entry)).href)
} catch (e) {
    process.stderr.write("mupdf dependency error: " + String(e?.message ?? e) + "\n")
    process.exit(2)
}

const pdfPath  = argOf("pdf", null)
const dpi      = parseFloat(argOf("dpi", "150"))
const jobsPath = argOf("jobs", null)
const scale    = dpi / 72

let jobs
if (jobsPath) {
    jobs = JSON.parse(fs.readFileSync(jobsPath, "utf8"))
} else {
    const out = argOf("out")
    if (!pdfPath || !out) { process.stderr.write("usage: --mupdf <package-dir> --pdf <p> (--jobs <json> | --out <png> [--page N] [--bbox x0,y0,x1,y1]) [--dpi D]\n"); process.exit(2) }
    const bbox = argOf("bbox", null)
    jobs = [{ page: parseInt(argOf("page", "0"), 10), bbox: bbox ? bbox.split(",").map(Number) : null, out }]
}

// documents opened once and cached by path — one --jobs run rasterizes many separate source PDFs
// (a paper's figure PDFs, or per-diagram compiled PDFs) without re-reading/re-parsing any of them.
const docCache = new Map()
function getDoc(p) {
    if (!p) throw new Error("job has no pdf and no --pdf default")
    let d = docCache.get(p)
    if (!d) { d = mupdf.Document.openDocument(fs.readFileSync(p), "application/pdf"); docCache.set(p, d) }
    return d
}
const ctm = mupdf.Matrix.scale(scale, scale)

function renderOne(job) {
    const doc = getDoc(job.pdf || pdfPath)
    const page = doc.loadPage(job.page ?? 0)
    let pix
    if (job.bbox) {
        const [rx0, ry0, rx1, ry1] = job.bbox
        const b = page.getBounds()                 // mupdf page space
        // Device space is y-down (top-left origin); PDF bbox is y-up. Map + scale to a clip rect.
        const clip = [(rx0 - b[0]) * scale, (b[3] - ry1) * scale, (rx1 - b[0]) * scale, (b[3] - ry0) * scale]
        pix = new mupdf.Pixmap(mupdf.ColorSpace.DeviceRGB, clip, false)
        pix.clear(255)
        const dev = new mupdf.DrawDevice(mupdf.Matrix.identity, pix)
        page.run(dev, ctm)                          // ctm applied to page content; the pixmap clip captures the region
        dev.close()
    } else {
        pix = page.toPixmap(ctm, mupdf.ColorSpace.DeviceRGB, false, false)
    }
    const png = pix.asPNG()
    fs.writeFileSync(job.out, Buffer.from(png))
    return { out: job.out, ok: true, bytes: png.length, w: pix.getWidth?.() ?? null, h: pix.getHeight?.() ?? null }
}

const results = []
for (const job of jobs) {
    try { results.push(renderOne(job)) }
    catch (e) { results.push({ out: job.out, ok: false, error: String(e?.message ?? e) }) }
}
process.stdout.write(JSON.stringify(results) + "\n")
