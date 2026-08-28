/**
 * Stateful in-memory engine and cache for mdnav.
 */

import { readFileSync, writeFileSync, mkdirSync, existsSync, readdirSync, statSync, appendFileSync } from "node:fs";
import { resolve, join, basename, dirname } from "node:path";
import { tmpdir } from "node:os";

import type {
  ByteSpan,
  DocumentIndex,
  Inventory,
  InventoryDoc,
  OutlineUnit,
  ProfileRow,
  ConstructRun,
  DocumentCoverage,
  ReadLedgerEntry,
  HeadingEntry,
} from "./types.ts";
import { scanDocument, stripNoise, profileDocument, extractMarks } from "./scanner.ts";

export class MdnavEngine {
  private workDir: string | null = null;
  private inventory: Inventory | null = null;
  private indices = new Map<string, DocumentIndex>();
  private sourceBuffers = new Map<string, Buffer>();
  private readsLedger: ReadLedgerEntry[] = [];

  constructor(initialWorkDir?: string) {
    if (initialWorkDir) {
      this.initWorkDir(initialWorkDir);
    }
  }

  public initWorkDir(customWorkDir?: string, anchorPath?: string): string {
    const stamp = new Date().toISOString().replace(/[-:]/g, "").replace(/T/, "_").slice(0, 15);
    const envWorkDir = process.env["MDNAV_WORK_DIR"];
    let root = customWorkDir ? resolve(customWorkDir) : envWorkDir ? resolve(envWorkDir) : null;

    if (!root && anchorPath) {
      const anchor = statSync(anchorPath).isDirectory() ? anchorPath : dirname(anchorPath);
      root = join(anchor, ".doc-dive");
    }

    if (!root) {
      root = join(tmpdir(), "mdnav");
    }

    const runDir = join(root, stamp);
    mkdirSync(join(runDir, "documents"), { recursive: true });
    writeFileSync(join(root, "LATEST"), stamp, "utf8");

    this.workDir = runDir;
    return runDir;
  }

  // ──────────────────────────────────────────────────────── Discover & Index

  public async discover(
    paths: string[],
    options: { glob?: string | undefined; recursive?: boolean | undefined; workDir?: string | undefined } = {}
  ): Promise<Inventory> {
    const { glob = "*.md", recursive = false, workDir } = options;
    const resolvedTargets = paths.map((p) => resolve(p));
    if (resolvedTargets.length === 0) {
      throw new Error("No target paths supplied for discover");
    }

    this.initWorkDir(workDir, resolvedTargets[0]);

    // Collect matching files
    const fileList: string[] = [];
    for (const target of resolvedTargets) {
      if (!existsSync(target)) continue;
      const st = statSync(target);
      if (st.isFile()) {
        fileList.push(target);
      } else if (st.isDirectory()) {
        this.crawlDirectory(target, glob, recursive, fileList);
      }
    }

    const uniqueFiles = Array.from(new Set(fileList)).sort();
    const docs: InventoryDoc[] = [];

    for (let i = 0; i < uniqueFiles.length; i++) {
      const filePath = uniqueFiles[i]!;
      const docId = `D${String(i + 1).padStart(3, "0")}`;
      const buf = readFileSync(filePath);
      const idx = scanDocument(buf, { id: docId, path: filePath });

      this.indices.set(docId, idx);
      this.sourceBuffers.set(docId, buf);

      // Compute grain signature
      const d1 = idx.counts[0] || 0;
      const d2 = (idx.counts[0] || 0) + (idx.counts[1] || 0);
      const d3 = (idx.counts[0] || 0) + (idx.counts[1] || 0) + (idx.counts[2] || 0);
      const medianBytes = idx.bytes > 0 && d1 > 0 ? Math.round(idx.bytes / d1) : idx.bytes;
      const grain = `${d1}/${d2}/${d3}~${this.fmtBytes(medianBytes)}`;

      const invDoc: InventoryDoc = {
        id: docId,
        path: filePath,
        name: basename(filePath),
        bytes: idx.bytes,
        grain,
        spineRatio: Number(idx.spine.ratio.toFixed(3)),
      };
      docs.push(invDoc);

      // Persist index
      if (this.workDir) {
        writeFileSync(join(this.workDir, "documents", `${docId}.index.json`), JSON.stringify(idx, null, 2), "utf8");
      }
    }

    this.inventory = {
      schema: 2,
      stamp: basename(this.workDir || ""),
      workDir: this.workDir || "",
      docs,
    };

    if (this.workDir) {
      writeFileSync(join(this.workDir, "inventory.json"), JSON.stringify(this.inventory, null, 2), "utf8");
    }

    return this.inventory;
  }

  // ──────────────────────────────────────────────────────── Profile

  public async profile(docRef: string): Promise<ProfileRow[]> {
    const { buf } = this.resolveDoc(docRef);
    return profileDocument(buf);
  }

  // ──────────────────────────────────────────────────────── Outline

  public async outline(
    docRef: string,
    options: {
      depth?: number | undefined;
      within?: string | undefined;
      comp?: boolean | undefined;
      byBreaks?: boolean | undefined;
      windows?: number | undefined;
    } = {}
  ): Promise<OutlineUnit[]> {
    const { depth = 1, within, comp = false, byBreaks = false } = options;
    const { docId, buf } = this.resolveDoc(docRef);
    const idx = this.getIndex(docId);

    const units: OutlineUnit[] = [];

    if (byBreaks) {
      // Break partition
      for (let i = 0; i < idx.breaks.length; i++) {
        const cur = idx.breaks[i]!;
        const nextStart = i + 1 < idx.breaks.length ? idx.breaks[i + 1]!.start : idx.bytes;
        const spanBytes = nextStart - cur.start;
        units.push({
          id: cur.sid,
          title: cur.label || `Segment ${i + 1}`,
          unitBytes: spanBytes,
        });
      }
      return units;
    }

    // Heading Partition
    let candidateHeadings = idx.headings.filter((h) => h.level <= depth);

    if (within) {
      const parent = idx.headings.find((h) => h.hid === within);
      if (parent) {
        candidateHeadings = idx.headings.filter(
          (h) => h.headingStart >= parent.bodyStart && h.headingStart < parent.subtreeEnd && h.level <= depth
        );
      }
    }

    for (let i = 0; i < candidateHeadings.length; i++) {
      const cur = candidateHeadings[i]!;
      const nextActiveStart = i + 1 < candidateHeadings.length ? candidateHeadings[i + 1]!.headingStart : idx.bytes;
      const unitBytes = nextActiveStart - cur.headingStart;
      const subtreeBytes = cur.subtreeEnd - cur.headingStart;

      let compTag: string | undefined;
      if (comp) {
        compTag = this.computeUnitComposition(buf.subarray(cur.headingStart, nextActiveStart));
      }

      units.push({
        id: cur.hid,
        level: cur.level,
        title: cur.title,
        digest: cur.digest,
        unitBytes,
        subtreeBytes,
        comp: compTag,
      });
    }

    return units;
  }

  // ──────────────────────────────────────────────────────── Marks

  public async marks(docRef: string, kind: string, minBytes = 0): Promise<ConstructRun[]> {
    const { docId, buf } = this.resolveDoc(docRef);
    const idx = this.getIndex(docId);
    const runs = extractMarks(buf, kind, minBytes);

    // Annotate containing heading anchor
    for (const run of runs) {
      const parent = idx.headings.filter((h) => h.headingStart <= run.start).pop();
      if (parent) {
        run.containingAnchor = `${docId}:${parent.hid}`;
      }
    }

    return runs;
  }

  // ──────────────────────────────────────────────────────── Read

  public async read(
    docRef: string,
    options: {
      heading?: string | undefined;
      headings?: string[] | undefined;
      from?: string | undefined;
      to?: string | undefined;
      span?: ByteSpan | undefined;
      extent?: "unit" | "subtree" | undefined;
      depth?: number | undefined;
      strip?: "all" | "none" | undefined;
      stripMatch?: string | undefined;
    } = {}
  ): Promise<{ text: string; bytes: number; elidedBytes: number }> {
    const { heading, headings, from, to, span, extent = "unit", depth = 1, strip = "none", stripMatch } = options;
    const { docId, buf } = this.resolveDoc(docRef);
    const idx = this.getIndex(docId);

    const spansToRead: ByteSpan[] = [];

    if (span) {
      spansToRead.push(span);
    } else if (headings && headings.length > 0) {
      for (const hid of headings) {
        const h = idx.headings.find((e) => e.hid === hid);
        if (h) {
          const s = this.computeHeadingSpan(idx, h, depth, extent);
          spansToRead.push(s);
        }
      }
    } else if (from && to) {
      const hFrom = idx.headings.find((e) => e.hid === from);
      const hTo = idx.headings.find((e) => e.hid === to);
      if (hFrom && hTo) {
        const sFrom = this.computeHeadingSpan(idx, hFrom, depth, extent);
        const sTo = this.computeHeadingSpan(idx, hTo, depth, extent);
        spansToRead.push([sFrom[0], Math.max(sFrom[1], sTo[1])]);
      }
    } else if (heading) {
      const h = idx.headings.find((e) => e.hid === heading);
      if (!h) throw new Error(`Heading ${heading} not found in ${docId}`);
      spansToRead.push(this.computeHeadingSpan(idx, h, depth, extent));
    } else {
      // Default: full document
      spansToRead.push([0, buf.length]);
    }

    // Materialize spans
    const chunks: string[] = [];
    let totalRawBytes = 0;
    let totalElided = 0;

    for (const [start, end] of spansToRead) {
      const raw = buf.subarray(start, end).toString("utf8");
      totalRawBytes += (end - start);

      const stripped = stripNoise(raw, { strip, stripMatch });
      totalElided += stripped.elidedBytes;
      chunks.push(stripped.text);
    }

    // Log to ledger
    this.recordRead(docId, spansToRead, "heading", depth, totalRawBytes, totalElided);

    return {
      text: chunks.join("\n\n"),
      bytes: totalRawBytes,
      elidedBytes: totalElided,
    };
  }

  // ──────────────────────────────────────────────────────── Native Batch Read

  public async batchRead(
    requests: Array<{
      docId: string;
      heading?: string | undefined;
      headings?: string[] | undefined;
      from?: string | undefined;
      to?: string | undefined;
      span?: ByteSpan | undefined;
      label?: string | undefined;
    }>,
    options: { depth?: number | undefined; strip?: "all" | "none" | undefined } = {}
  ): Promise<Array<{ docId: string; label?: string | undefined; anchor?: string | undefined; text: string; bytes: number }>> {
    const { depth = 2, strip = "all" } = options;
    const results: Array<{ docId: string; label?: string | undefined; anchor?: string | undefined; text: string; bytes: number }> = [];

    for (const req of requests) {
      try {
        const readResult = await this.read(req.docId, {
          heading: req.heading,
          headings: req.headings,
          from: req.from,
          to: req.to,
          span: req.span,
          depth,
          strip,
        });

        const anchor = req.heading ? `${req.docId}:${req.heading}` : req.span ? `${req.docId}:@${req.span[0]}..${req.span[1]}` : req.docId;
        results.push({
          docId: req.docId,
          label: req.label,
          anchor,
          text: readResult.text,
          bytes: readResult.bytes,
        });
      } catch (err: any) {
        results.push({
          docId: req.docId,
          label: req.label,
          text: `[Error reading ${req.docId}: ${err.message}]`,
          bytes: 0,
        });
      }
    }

    return results;
  }

  // ──────────────────────────────────────────────────────── Coverage

  public async coverage(docIds?: string[] | undefined, depth = 1): Promise<DocumentCoverage[]> {
    const targetDocIds = docIds && docIds.length > 0 ? docIds : Array.from(this.indices.keys());
    const reports: DocumentCoverage[] = [];

    for (const docId of targetDocIds) {
      const idx = this.getIndex(docId);
      const docReads = this.readsLedger.filter((r) => r.doc === docId);

      // Merge read intervals
      const intervals = docReads.flatMap((r) => r.spans).sort((a, b) => a[0] - b[0]);
      let bytesRead = 0;
      let elided = 0;
      docReads.forEach((r) => (elided += r.elidedBytes || 0));

      if (intervals.length > 0) {
        let curStart = intervals[0]![0];
        let curEnd = intervals[0]![1];

        for (let i = 1; i < intervals.length; i++) {
          const next = intervals[i]!;
          if (next[0] <= curEnd) {
            curEnd = Math.max(curEnd, next[1]);
          } else {
            bytesRead += (curEnd - curStart);
            curStart = next[0];
            curEnd = next[1];
          }
        }
        bytesRead += (curEnd - curStart);
      }

      // Check unread units at depth
      const unread: Array<{ anchor: string; bytes: number; title: string }> = [];
      const activeHeadings = idx.headings.filter((h) => h.level <= depth);

      for (let i = 0; i < activeHeadings.length; i++) {
        const cur = activeHeadings[i]!;
        const nextStart = i + 1 < activeHeadings.length ? activeHeadings[i + 1]!.headingStart : idx.bytes;
        const isRead = intervals.some(([s, e]) => s <= cur.headingStart && e >= nextStart);
        if (!isRead) {
          unread.push({
            anchor: `${docId}:${cur.hid}`,
            bytes: nextStart - cur.headingStart,
            title: cur.title,
          });
        }
      }

      reports.push({
        docId,
        path: idx.path,
        bytesRead,
        totalBytes: idx.bytes,
        percent: idx.bytes > 0 ? Number(((bytesRead / idx.bytes) * 100).toFixed(1)) : 0,
        readsCount: docReads.length,
        elidedBytes: elided,
        unreadAnchors: unread,
      });
    }

    return reports;
  }

  // ──────────────────────────────────────────────────────── Locate

  public async locate(
    pattern: string,
    docIds?: string[] | undefined,
    caseInsensitive = false,
    max = 50
  ): Promise<Array<{ docId: string; anchor: string; line: number; text: string }>> {
    const targetDocIds = docIds && docIds.length > 0 ? docIds : Array.from(this.indices.keys());
    const matches: Array<{ docId: string; anchor: string; line: number; text: string }> = [];
    const regex = new RegExp(pattern, caseInsensitive ? "i" : "");

    for (const docId of targetDocIds) {
      const { buf } = this.resolveDoc(docId);
      const idx = this.getIndex(docId);
      const text = buf.toString("utf8");
      const lines = text.split(/\r?\n/);

      let byteOffset = 0;
      for (let l = 0; l < lines.length; l++) {
        const line = lines[l]!;
        if (regex.test(line)) {
          const parent = idx.headings.filter((h) => h.headingStart <= byteOffset).pop();
          const anchor = parent ? `${docId}:${parent.hid}@${parent.digest}` : docId;
          matches.push({
            docId,
            anchor,
            line: l + 1,
            text: line.trim(),
          });
          if (matches.length >= max) return matches;
        }
        byteOffset += Buffer.byteLength(line, "utf8") + 1;
      }
    }

    return matches;
  }

  // ──────────────────────────────────────────────────────── Internal Helpers

  private resolveDoc(docRef: string): { docId: string; buf: Buffer } {
    if (this.indices.has(docRef) && this.sourceBuffers.has(docRef)) {
      return { docId: docRef, buf: this.sourceBuffers.get(docRef)! };
    }

    // Try finding by path or filename
    for (const [id, idx] of this.indices.entries()) {
      if (idx.path === docRef || basename(idx.path) === docRef) {
        return { docId: id, buf: this.sourceBuffers.get(id)! };
      }
    }

    // If not cached but exists on filesystem, index it on the fly
    if (existsSync(docRef)) {
      const docId = `D${String(this.indices.size + 1).padStart(3, "0")}`;
      const buf = readFileSync(docRef);
      const idx = scanDocument(buf, { id: docId, path: resolve(docRef) });
      this.indices.set(docId, idx);
      this.sourceBuffers.set(docId, buf);
      return { docId, buf };
    }

    throw new Error(`Document reference "${docRef}" could not be resolved`);
  }

  private getIndex(docId: string): DocumentIndex {
    const idx = this.indices.get(docId);
    if (!idx) throw new Error(`Index for ${docId} is not loaded`);
    return idx;
  }

  private computeHeadingSpan(idx: DocumentIndex, h: HeadingEntry, depth: number, extent: "unit" | "subtree"): ByteSpan {
    if (extent === "subtree") {
      return [h.headingStart, h.subtreeEnd];
    }
    // Unit extent: until next active heading at depth
    const active = idx.headings.filter((e) => e.level <= depth);
    const curIdx = active.findIndex((e) => e.hid === h.hid);
    const nextStart = curIdx !== -1 && curIdx + 1 < active.length ? active[curIdx + 1]!.headingStart : idx.bytes;
    return [h.headingStart, nextStart];
  }

  private computeUnitComposition(buf: Buffer): string {
    const rows = profileDocument(buf).slice(0, 3);
    return `[${rows.map((r) => `${r.construct.replace("heading ", "").slice(0, 5)}${Math.round(r.percent)}`).join(" ")}]`;
  }

  private recordRead(doc: string, spans: ByteSpan[], basis: string, depth: number, bytes: number, elidedBytes: number) {
    const entry: ReadLedgerEntry = {
      ts: new Date().toISOString(),
      doc,
      spans,
      basis,
      depth,
      bytes,
      elidedBytes,
    };
    this.readsLedger.push(entry);
    if (this.workDir) {
      appendFileSync(join(this.workDir, "reads.jsonl"), JSON.stringify(entry) + "\n", "utf8");
    }
  }

  private crawlDirectory(dir: string, glob: string, recursive: boolean, out: string[]) {
    const entries = readdirSync(dir, { withFileTypes: true });
    for (const ent of entries) {
      if (ent.name.startsWith(".")) continue;
      const full = join(dir, ent.name);
      if (ent.isDirectory() && recursive) {
        this.crawlDirectory(full, glob, recursive, out);
      } else if (ent.isFile() && this.matchGlob(ent.name, glob)) {
        out.push(full);
      }
    }
  }

  private matchGlob(name: string, glob: string): boolean {
    if (glob === "*.md") return name.endsWith(".md");
    if (glob === "*") return true;
    return name.includes(glob.replace(/\*/g, ""));
  }

  private fmtBytes(n: number): string {
    if (n < 1024) return `${n}B`;
    if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)}K`;
    return `${(n / 1048576).toFixed(1)}M`;
  }
}
