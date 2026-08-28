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
  AnchorTarget,
  Elision,
  ReadResult,
  BatchReadResult,
  JournalEntry,
  ResolvedJournalEntry,
  JournalStatus,
  JournalRecordArgs,
  JournalReadArgs,
} from "./types.ts";
import { scanDocument, stripNoise, profileDocument, extractMarks, computeWindows, digestOf } from "./scanner.ts";
import { parseAnchor, formatAnchorString } from "./formatting.ts";

export class MdnavEngine {
  private workDir: string | null = null;
  private inventory: Inventory | null = null;
  private indices = new Map<string, DocumentIndex>();
  private sourceBuffers = new Map<string, Buffer>();
  private readsLedger: ReadLedgerEntry[] = [];

  // The journal is a notebook, not a run artifact: it lives at the .doc-dive
  // ROOT and outlives re-indexing, while reads.jsonl belongs to its stamped run.
  private journalRoot: string | null = null;
  private journalEntries: JournalEntry[] = [];
  private journalLoaded = false;

  // Out-of-band things the reader must be told about — a source that moved
  // under the cache, so far. Drained into whatever tool output comes next,
  // because stderr reaches the server log and never the reader.
  private notices: string[] = [];

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

    // Re-anchoring on a different corpus means a different notebook. Drop the
    // cache so the next journal op rehydrates from the new root rather than
    // minting ids on top of someone else's ledger.
    if (this.journalRoot !== root) {
      this.journalRoot = root;
      this.journalEntries = [];
      this.journalLoaded = false;
    }

    this.workDir = runDir;
    return runDir;
  }

  /** Take and clear the pending notices, for the caller to put in the stream. */
  public drainNotices(): string[] {
    const out = this.notices;
    this.notices = [];
    return out;
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
      // The file's own mtime, not the moment we scanned it — staleness is
      // decided by comparing against the source, so the source's clock is the
      // only one that means anything here.
      const idx = scanDocument(buf, { id: docId, path: filePath, mtimeMs: statSync(filePath).mtimeMs });

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
    const { depth = 1, within, comp = false, byBreaks = false, windows } = options;
    const { docId, buf } = this.resolveDoc(docRef);
    const idx = this.getIndex(docId);

    const units: OutlineUnit[] = [];

    // Windows are the last-resort partition for a document whose headings give
    // no usable grain. They are minted onto the index here so that Wnnnn anchors
    // resolve on the reads that follow.
    if (windows !== undefined) {
      const parent = within ? idx.headings.find((h) => h.hid === within) : undefined;
      const wins = computeWindows(buf, idx, windows, parent);
      idx.windows = wins;
      this.persistIndex(docId, idx);
      return wins.map((w) => ({
        id: w.wid,
        digest: w.digest,
        title: w.unbroken ? `${w.title}  UNBROKEN — no line break to split on` : w.title,
        unitBytes: w.bytes,
      }));
    }

    if (byBreaks) {
      // Segments partition the whole document, not just the stretch after the
      // first break — otherwise everything ahead of it is silently dropped.
      const segs = this.segmentsOf(idx);
      return segs.map((s, i) => {
        const terminator = idx.breaks.find((b) => b.end === s.subtreeEnd);
        return {
          id: s.hid,
          digest: s.digest,
          title: terminator?.label || `SEGMENT ${i + 1}`,
          unitBytes: s.subtreeEnd - s.headingStart,
        };
      });
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
  ): Promise<ReadResult> {
    const { heading, headings, from, to, span, extent = "unit", depth = 1, strip = "none", stripMatch } = options;
    const { docId, buf } = this.resolveDoc(docRef);
    const idx = this.getIndex(docId);

    const spansToRead: ByteSpan[] = [];
    const anchors: string[] = [];
    const warnings: string[] = [];

    const take = (spec: string): AnchorTarget => {
      const { target, warning } = this.resolveAnchor(idx, spec);
      if (warning) warnings.push(warning);
      return target;
    };

    if (span) {
      if (span[1] <= span[0] || span[0] < 0 || span[1] > buf.length) {
        throw new Error(`span ${span[0]}..${span[1]} is outside 0..${buf.length}`);
      }
      spansToRead.push(span);
      anchors.push(`@${span[0]}..${span[1]}`);
    } else if (headings && headings.length > 0) {
      const targets = headings.map(take).sort((a, b) => a.headingStart - b.headingStart);
      for (const t of targets) {
        spansToRead.push(this.computeHeadingSpan(idx, t, depth, extent));
        anchors.push(`${t.hid}@${t.digest}`);
      }
    } else if (from) {
      const a = take(from);
      const b = to ? take(to) : a;
      const [, endB] = this.computeHeadingSpan(idx, b, depth, extent);
      if (endB <= a.headingStart) {
        throw new Error(`"to" anchor ${b.hid} precedes "from" anchor ${a.hid}`);
      }
      spansToRead.push([a.headingStart, endB]);
      anchors.push(`${a.hid}@${a.digest}`, `${b.hid}@${b.digest}`);
    } else if (heading) {
      const t = take(heading);
      spansToRead.push(this.computeHeadingSpan(idx, t, depth, extent));
      anchors.push(`${t.hid}@${t.digest}`);
    } else {
      // Defaulting to the whole document would be the exact failure this tool
      // exists to prevent. A headingless document is still addressable — the
      // scanner mints H0000 (BODY) for it — so there is always a named way in.
      throw new Error(
        `read needs a selector: heading, headings, from/to, or span. ` +
        `To read a whole document, address it as H0000 or give an explicit span.`
      );
    }

    // Materialize spans
    const chunks: string[] = [];
    const elisions: Elision[] = [];
    let totalRawBytes = 0;
    let totalElided = 0;

    for (const [start, end] of spansToRead) {
      const raw = buf.subarray(start, end).toString("utf8");
      totalRawBytes += (end - start);

      const stripped = stripNoise(raw, { strip, stripMatch });
      totalElided += stripped.elidedBytes;
      elisions.push(...stripped.elisions);
      chunks.push(stripped.text);
    }

    const first = anchors[0] ?? "";
    const basis = span ? "span" : /^S/i.test(first) ? "breaks" : /^W/i.test(first) ? "windows" : `d${depth}`;
    this.recordRead(docId, spansToRead, basis, depth, totalRawBytes, totalElided);

    return {
      docId,
      text: chunks.join("\n\n"),
      bytes: totalRawBytes,
      elidedBytes: totalElided,
      elisions,
      spans: spansToRead,
      anchors,
      warnings,
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
  ): Promise<BatchReadResult[]> {
    const { depth = 2, strip = "all" } = options;
    const results: BatchReadResult[] = [];

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

        // Report the anchor that RESOLVED, digest included — that string is what
        // a follow-up read takes verbatim.
        const anchor = readResult.anchors[0] ?? readResult.docId;
        const starts = readResult.spans.map((s) => s[0]);
        const ends = readResult.spans.map((s) => s[1]);
        const merged: ByteSpan | undefined =
          starts.length > 0 ? [Math.min(...starts), Math.max(...ends)] : undefined;

        results.push({
          docId: readResult.docId,
          label: req.label,
          anchor,
          span: merged,
          text: readResult.text,
          bytes: readResult.bytes,
          elidedBytes: readResult.elidedBytes,
          elisions: readResult.elisions,
          warnings: readResult.warnings,
        });
      } catch (err: any) {
        results.push({
          docId: req.docId,
          label: req.label,
          anchor: req.heading ?? req.from ?? "",
          text: `[Error reading ${req.docId}: ${err.message}]`,
          bytes: 0,
          elidedBytes: 0,
          elisions: [],
          warnings: [],
        });
      }
    }

    return results;
  }

  // ──────────────────────────────────────────────────────── Coverage

  public async coverage(docIds?: string[] | undefined, depth = 1, byBreaks = false): Promise<DocumentCoverage[]> {
    const targetDocIds = docIds && docIds.length > 0 ? docIds : Array.from(this.indices.keys());
    const reports: DocumentCoverage[] = [];

    // An unreadable notebook must not fail a coverage report; it just means
    // nothing has been cited yet.
    let journal: ResolvedJournalEntry[] = [];
    try { journal = this.resolveJournal(); } catch { journal = []; }

    for (const docId of targetDocIds) {
      const idx = this.getIndex(docId);
      const docReads = this.readsLedger.filter((r) => r.doc === docId);

      // Merge read intervals ONCE, and settle every question against the merged
      // list: two adjacent reads that together cover a unit do cover it.
      const merged = mergeIntervals(docReads.flatMap((r) => r.spans));
      const bytesRead = totalBytes(merged);
      let elided = 0;
      docReads.forEach((r) => (elided += r.elidedBytes || 0));

      // Bytes CITED: resolve every journal anchor scoped to this document down
      // to the chunk it names. Comparing this against bytes read is the
      // diagnostic the notebook has always specified and never had — both
      // ledgers are on disk in the same directory, so it is arithmetic now.
      const citedSpans: ByteSpan[] = [];
      let citations = 0;
      for (const entry of journal) {
        let citesThis = false;
        for (const a of entry.anchors) {
          const p = parseAnchor(a);
          if (p.unit === undefined || p.scope.toUpperCase() !== docId.toUpperCase()) continue;
          citesThis = true;
          try {
            const { target } = this.resolveAnchor(idx, p.unit);
            // At the chunk's OWN grain: a citation names the unit it names,
            // not whatever the caller happens to be scoring coverage at.
            citedSpans.push(this.computeHeadingSpan(idx, target, Math.max(1, target.level), "unit"));
          } catch {
            // An anchor that no longer resolves cites no bytes. The drift is
            // reported where it is actionable — at read and at record time.
          }
        }
        if (citesThis) citations++;
      }

      const cited = mergeIntervals(citedSpans);
      const bytesCited = totalBytes(cited);
      const both = totalBytes(intersectIntervals(merged, cited));

      // Unread units, against whichever basis the caller is working on.
      const unread: Array<{ anchor: string; bytes: number; title: string }> = [];
      const basis = byBreaks
        ? this.segmentsOf(idx).map((s) => ({ hid: s.hid, title: s.title, start: s.headingStart, end: s.subtreeEnd }))
        : ((): Array<{ hid: string; title: string; start: number; end: number }> => {
            const active = idx.headings.filter((h) => h.level <= depth);
            return active.map((h, i) => ({
              hid: h.hid,
              title: h.title,
              start: h.headingStart,
              end: i + 1 < active.length ? active[i + 1]!.headingStart : idx.bytes,
            }));
          })();

      for (const u of basis) {
        const isRead = merged.some(([s, e]) => s <= u.start && e >= u.end);
        if (!isRead) {
          unread.push({ anchor: `${docId}:${u.hid}`, bytes: u.end - u.start, title: u.title });
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
        bytesCited,
        citedPercent: idx.bytes > 0 ? Number(((bytesCited / idx.bytes) * 100).toFixed(1)) : 0,
        citations,
        readNotCited: bytesRead - both,
        citedNotRead: bytesCited - both,
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
      // Split on LF only and keep any trailing CR on the line: a line's byte
      // cost is then exactly its own length plus the one LF, whatever newline
      // convention the document uses. Splitting on /\r?\n/ discards the CR and
      // drifts the offset by one byte per line on CRLF sources — which silently
      // produces a WRONG anchor, the one failure this tool must not have.
      const lines = text.split("\n");

      let byteOffset = 0;
      for (let l = 0; l < lines.length; l++) {
        const raw = lines[l]!;
        const line = raw.endsWith("\r") ? raw.slice(0, -1) : raw;
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
        byteOffset += Buffer.byteLength(raw, "utf8") + 1;
      }
    }

    return matches;
  }

  // ──────────────────────────────────────────────────────── Journal Ledger

  private ensureJournalRoot(explicit?: string | undefined): string {
    if (explicit) {
      const root = resolve(explicit);
      if (this.journalRoot !== root) {
        this.journalRoot = root;
        this.journalEntries = [];
        this.journalLoaded = false;
      }
    }
    if (!this.journalRoot) {
      const env = process.env["MDNAV_WORK_DIR"];
      this.journalRoot = env ? resolve(env) : join(tmpdir(), "mdnav");
    }
    return this.journalRoot;
  }

  /** The notebook sits at the .doc-dive root, beside LATEST — not inside a run. */
  public journalPath(explicit?: string | undefined): string {
    return join(this.ensureJournalRoot(explicit), "journal.jsonl");
  }

  /**
   * Rehydrate the ledger from disk before touching it.
   *
   * Ids are minted from what the FILE already holds, never from an in-memory
   * counter: the notebook outlives the server process, and minting N001 on top
   * of an existing N001 would make every `refs` pointer ambiguous.
   */
  private ensureJournalLoaded(explicit?: string | undefined): void {
    const path = this.journalPath(explicit);
    if (this.journalLoaded) return;

    this.journalEntries = [];
    if (existsSync(path)) {
      for (const line of readFileSync(path, "utf8").split("\n")) {
        const t = line.trim();
        if (!t) continue;
        try {
          const rec = JSON.parse(t) as JournalEntry;
          if (rec && typeof rec.id === "string") {
            this.journalEntries.push({ ...rec, refs: rec.refs ?? [], anchors: rec.anchors ?? [] });
          }
        } catch {
          // A torn or hand-edited line must not take the whole notebook down.
        }
      }
    }
    this.journalLoaded = true;
  }

  private mintJournalId(): string {
    let max = 0;
    for (const e of this.journalEntries) {
      const m = /^N(\d+)$/.exec(e.id);
      if (m) max = Math.max(max, Number(m[1]));
    }
    return `N${String(max + 1).padStart(3, "0")}`;
  }

  public recordJournal(args: JournalRecordArgs): { entry: JournalEntry; anchorWarnings: string[] } {
    this.ensureJournalLoaded(args.workDir);

    const refs = args.refs ?? [];
    for (const r of refs) {
      if (!this.journalEntries.some((e) => e.id === r)) {
        throw new Error(`journal: ref ${r} does not exist — record the parent before referring to it`);
      }
    }

    // Validate mdnav-shaped anchors against the live index. Anything else
    // (`code:grassmann.py`, a url, a bare tag) is the reader's own vocabulary
    // and is kept verbatim. A citation that is ALREADY stale should be said so
    // at write time, while it is still cheap to fix.
    const anchorWarnings: string[] = [];
    const anchors = args.anchors ?? [];
    for (const a of anchors) {
      const m = /^(D\d+):([HSW]\d+)(?:@([0-9a-f]{4}))?$/i.exec(a.trim());
      if (!m) continue;
      const idx = this.indices.get(m[1]!.toUpperCase());
      if (!idx) {
        anchorWarnings.push(`anchor ${formatAnchorString(a)} names ${m[1]}, which is not indexed in this session`);
        continue;
      }
      try {
        const { warning } = this.resolveAnchor(idx, m[3] ? `${m[2]}@${m[3]}` : `${m[2]}`);
        if (warning) anchorWarnings.push(warning);
      } catch (err: any) {
        anchorWarnings.push(`anchor ${formatAnchorString(a)} — ${err.message}`);
      }
    }

    const entry: JournalEntry = {
      id: this.mintJournalId(),
      ts: new Date().toISOString(),
      op: args.op,
      refs,
      concept: args.concept,
      anchors,
      bytes: Buffer.byteLength(args.body, "utf8"),
      body: args.body,
    };

    this.journalEntries.push(entry);
    const path = this.journalPath(args.workDir);
    mkdirSync(dirname(path), { recursive: true });
    appendFileSync(path, JSON.stringify(entry) + "\n", "utf8");

    return { entry, anchorWarnings };
  }

  /**
   * Every entry with its state attached.
   *
   * Status is DERIVED from the ops of an entry's children, never stored and
   * never written back over a parent. That keeps the file a pure event log, so
   * rehydrating it reproduces the live session exactly — and "preserve history,
   * never overwrite in place" holds by construction rather than by discipline.
   */
  public resolveJournal(workDir?: string | undefined): ResolvedJournalEntry[] {
    this.ensureJournalLoaded(workDir);

    const byId = new Map<string, ResolvedJournalEntry>();
    for (const e of this.journalEntries) {
      byId.set(e.id, { ...e, status: "active", children: [] });
    }

    const VERDICT: Record<string, JournalStatus | undefined> = {
      refine: "refined",
      supersede: "superseded",
      reject: "rejected",
      adopt: "adopted",
      retract: "retracted",
    };
    // A decisive verdict outranks a refinement; among equals the most recent
    // child wins, which is why this walks the ledger in file order.
    const RANK: Record<JournalStatus, number> = {
      active: 0, refined: 1, superseded: 2, rejected: 3, adopted: 3, retracted: 3,
    };

    for (const e of this.journalEntries) {
      const verdict = VERDICT[e.op];
      for (const r of e.refs) {
        const parent = byId.get(r);
        if (!parent) continue;
        parent.children.push(e.id);
        if (verdict && RANK[verdict] >= RANK[parent.status]) parent.status = verdict;
      }
    }

    return Array.from(byId.values());
  }

  public readJournal(args: JournalReadArgs): ResolvedJournalEntry[] {
    let out = this.resolveJournal(args.workDir);

    if (args.concept) out = out.filter((e) => e.concept === args.concept);
    if (args.op) out = out.filter((e) => e.op === args.op);
    if (args.status) out = out.filter((e) => e.status === args.status);

    // Anchor filters join on COMPONENTS, not on string prefixes. Each component
    // is an edge — document, chunk, content identity — and each has to be
    // traversable on its own, or citations are only ever a leaf you can match
    // whole.
    const ci = (a?: string | undefined) => (a === undefined ? undefined : a.toUpperCase());

    if (args.docId) {
      const doc = ci(args.docId);
      out = out.filter((e) => e.anchors.some((a) => ci(parseAnchor(a).scope) === doc));
    }

    if (args.anchor) {
      const want = parseAnchor(args.anchor);
      // A bare "H0003" names the unit; "D014:H0003" pins the scope as well.
      const wantUnit = ci(want.unit ?? want.scope);
      const wantScope = want.unit !== undefined ? ci(want.scope) : undefined;
      out = out.filter((e) =>
        e.anchors.some((a) => {
          const p = parseAnchor(a);
          if (ci(p.unit ?? p.scope) !== wantUnit) return false;
          if (wantScope !== undefined && ci(p.scope) !== wantScope) return false;
          // No digest asked for means every version of this chunk.
          if (want.digest !== undefined && ci(p.digest) !== ci(want.digest)) return false;
          return true;
        })
      );
    }

    if (args.digest) {
      const dig = ci(args.digest);
      out = out.filter((e) => e.anchors.some((a) => ci(parseAnchor(a).digest) === dig));
    }

    const limit = args.limit ?? 100;
    return out.length > limit ? out.slice(out.length - limit) : out;
  }

  // ──────────────────────────────────────────────────────── Internal Helpers

  private resolveDoc(docRef: string): { docId: string; buf: Buffer } {
    if (this.indices.has(docRef) && this.sourceBuffers.has(docRef)) {
      return { docId: docRef, buf: this.refreshIfStale(docRef) };
    }

    // Try finding by path or filename
    for (const [id, idx] of this.indices.entries()) {
      if (idx.path === docRef || basename(idx.path) === docRef) {
        return { docId: id, buf: this.refreshIfStale(id) };
      }
    }

    // If not cached but exists on filesystem, index it on the fly
    if (existsSync(docRef)) {
      const docId = `D${String(this.indices.size + 1).padStart(3, "0")}`;
      const buf = readFileSync(docRef);
      const idx = scanDocument(buf, { id: docId, path: resolve(docRef), mtimeMs: statSync(docRef).mtimeMs });
      this.indices.set(docId, idx);
      this.sourceBuffers.set(docId, buf);
      return { docId, buf };
    }

    throw new Error(`Document reference "${docRef}" could not be resolved`);
  }

  /**
   * Re-read and re-index a document whose bytes changed under us.
   *
   * Without this the cache is authoritative for the life of the process: a
   * corpus edited while you are working in it keeps serving the bytes it had at
   * discover, and — worse — the digest-drift check compares an anchor against
   * the STALE index, so it always matches and drift is never reported. The one
   * case the drift guarantee exists for is precisely the case that defeated it.
   */
  private refreshIfStale(docId: string): Buffer {
    const idx = this.indices.get(docId)!;
    const cached = this.sourceBuffers.get(docId)!;

    let st;
    try { st = statSync(idx.path); } catch { return cached; }

    // Size and mtime both agreeing is enough to skip the hash on a large file.
    if (st.size === idx.bytes && Math.floor(st.mtimeMs) === Math.floor(idx.mtimeMs)) return cached;

    const buf = readFileSync(idx.path);
    const fresh = scanDocument(buf, { id: docId, path: idx.path, mtimeMs: st.mtimeMs });

    if (fresh.sha256 === idx.sha256) {
      // Touched but not changed. Adopt the new mtime so we stop re-reading it.
      idx.mtimeMs = st.mtimeMs;
      return cached;
    }

    this.indices.set(docId, fresh);
    this.sourceBuffers.set(docId, buf);
    this.persistIndex(docId, fresh);
    this.notices.push(
      `${docId} changed on disk and was re-indexed — ${idx.bytes} B became ${fresh.bytes} B. ` +
      `Anchors and digests below describe the NEW source; citations taken before now may no longer match.`
    );
    return buf;
  }

  private getIndex(docId: string): DocumentIndex {
    const idx = this.indices.get(docId);
    if (!idx) throw new Error(`Index for ${docId} is not loaded`);
    return idx;
  }

  /**
   * Resolve one anchor spec against the document's single shared address space.
   *
   * Accepts `Hnnnn`, `Dnnn:Hnnnn`, and either with an `@digest` suffix, plus the
   * synthetic families: `H0000` (preamble/body), `Snnnn` (break segments) and
   * `Wnnnn` (windows). A digest that no longer matches is REPORTED, not
   * rejected — the bytes are still there; the reader needs to know the source
   * moved under the citation, and needs to be told in-band to know it at all.
   */
  private resolveAnchor(idx: DocumentIndex, spec: string): { target: AnchorTarget; warning?: string | undefined } {
    const [hidRaw = "", dig] = String(spec).trim().split("@");
    const hid = hidRaw.includes(":") ? (hidRaw.split(":").pop() ?? hidRaw) : hidRaw;

    // Warnings and errors are context-stream text like any other output: the
    // chunk they name has to present the same tokens here as it does in an
    // outline, a chunk prefix, or a journal line, or it cannot be bound to them.
    const drift = (t: AnchorTarget, kind: string): string | undefined =>
      dig && dig !== t.digest
        ? `anchor ${formatAnchorString(`${idx.id}:${t.hid}@${dig}`)} does not match the current ${kind} digest ${formatAnchorString(`${t.hid}@${t.digest}`)} — the source has changed under this anchor`
        : undefined;

    const h = idx.headings.find((x) => x.hid.toLowerCase() === hid.toLowerCase());
    if (h) {
      const target: AnchorTarget = {
        hid: h.hid, level: h.level, title: h.title, digest: h.digest,
        headingStart: h.headingStart, bodyStart: h.bodyStart, subtreeEnd: h.subtreeEnd,
        synthetic: h.level === 0 ? true : undefined,
      };
      return { target, warning: drift(target, "heading") };
    }

    if (/^W\d+$/i.test(hid)) {
      const w = (idx.windows ?? []).find((x) => x.wid.toLowerCase() === hid.toLowerCase());
      if (!w) {
        throw new Error(`no anchor ${hid} in ${idx.id} — mint window anchors first with outline(windows: <size>)`);
      }
      const target: AnchorTarget = {
        hid: w.wid, level: 0, title: w.title, digest: w.digest,
        headingStart: w.start, bodyStart: w.start, subtreeEnd: w.end, synthetic: true,
      };
      return { target, warning: drift(target, "window") };
    }

    if (/^S\d+$/i.test(hid)) {
      const s = this.segmentsOf(idx).find((x) => x.hid.toLowerCase() === hid.toLowerCase());
      if (!s) {
        throw new Error(`no anchor ${hid} in ${idx.id} — the document has ${idx.breaks.length} thematic break(s)`);
      }
      return { target: s, warning: drift(s, "segment") };
    }

    throw new Error(`no anchor ${hid} in ${idx.id}`);
  }

  /**
   * Thematic-break segments as anchor targets. Segments partition the WHOLE
   * document: the first one starts at byte 0, so nothing ahead of the first
   * break is dropped from a break-basis outline or coverage report.
   */
  private segmentsOf(idx: DocumentIndex): AnchorTarget[] {
    const out: AnchorTarget[] = [];
    let pos = 0;
    let n = 1;
    const push = (start: number, end: number) => {
      out.push({
        hid: `S${String(n++).padStart(4, "0")}`,
        level: 0,
        title: "SEGMENT",
        digest: digestOf(`seg:${idx.sha256}:${start}`),
        headingStart: start,
        bodyStart: start,
        subtreeEnd: end,
        synthetic: true,
      });
    };
    for (const b of idx.breaks) {
      if (b.end > pos) { push(pos, b.end); pos = b.end; }
    }
    if (pos < idx.bytes) push(pos, idx.bytes);
    return out;
  }

  private computeHeadingSpan(idx: DocumentIndex, h: AnchorTarget, depth: number, extent: "unit" | "subtree"): ByteSpan {
    // A segment, a window, or a synthetic root IS its own unit — there is no
    // depth ladder to walk for it.
    if (h.synthetic || extent === "subtree") {
      return [h.headingStart, h.subtreeEnd];
    }

    // Unit extent: until the next heading that is active at this depth.
    const active = idx.headings.filter((e) => e.level <= depth);
    const curIdx = active.findIndex((e) => e.hid === h.hid);
    if (curIdx === -1) {
      // Silently running the span to EOF would hand back a unit that does not
      // exist at the requested grain. Fail where the mistake was made.
      throw new Error(
        `${formatAnchorString(`${idx.id}:${h.hid}`)} is a level-${h.level} heading and is not active at depth ${depth} — ` +
        `raise depth to ${h.level}, or read it with extent "subtree"`
      );
    }
    const nextStart = curIdx + 1 < active.length ? active[curIdx + 1]!.headingStart : idx.bytes;
    return [h.headingStart, nextStart];
  }

  private persistIndex(docId: string, idx: DocumentIndex): void {
    if (!this.workDir) return;
    try {
      writeFileSync(join(this.workDir, "documents", `${docId}.index.json`), JSON.stringify(idx, null, 2), "utf8");
    } catch {
      // The index is a cache; failing to persist it must not fail the read.
    }
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

// ──────────────────────────────────────────────────────────── Interval algebra

/** Sort and coalesce overlapping or touching spans into a canonical list. */
function mergeIntervals(spans: ByteSpan[]): ByteSpan[] {
  const sorted = [...spans].sort((a, b) => a[0] - b[0]);
  const out: ByteSpan[] = [];
  for (const iv of sorted) {
    const last = out[out.length - 1];
    if (last && iv[0] <= last[1]) last[1] = Math.max(last[1], iv[1]);
    else out.push([iv[0], iv[1]]);
  }
  return out;
}

/** Overlap of two already-merged lists. */
function intersectIntervals(a: ByteSpan[], b: ByteSpan[]): ByteSpan[] {
  const out: ByteSpan[] = [];
  let i = 0, j = 0;
  while (i < a.length && j < b.length) {
    const x = a[i]!, y = b[j]!;
    const start = Math.max(x[0], y[0]);
    const end = Math.min(x[1], y[1]);
    if (start < end) out.push([start, end]);
    if (x[1] < y[1]) i++; else j++;
  }
  return out;
}

function totalBytes(spans: ByteSpan[]): number {
  let n = 0;
  for (const [s, e] of spans) n += e - s;
  return n;
}
