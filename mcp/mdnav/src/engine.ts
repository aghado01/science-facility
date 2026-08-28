/**
 * Stateful in-memory engine and cache for mdnav.
 */

import { readFileSync, writeFileSync, mkdirSync, existsSync, readdirSync, statSync, appendFileSync } from "node:fs";
import { resolve, join, basename, dirname, relative } from "node:path";
import { tmpdir } from "node:os";

import type {
  ByteSpan,
  DocumentIndex,
  Inventory,
  InventoryDoc,
  MountAddressing,
  OutlineUnit,
  ProfileRow,
  ConstructRun,
  DocumentCoverage,
  ReadLedgerEntry,
  AnchorTarget,
  Elision,
  StripSpec,
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

  // Document ids are assigned ONCE per path and never reassigned. Numbering by
  // sort position instead means a file joining the corpus renumbers everything
  // after it — and a journal anchor recorded as D001:H0002 then silently points
  // at a different document, which no amount of digest checking can catch
  // because the digest belongs to the wrong file too.
  //
  // Coordinates are stored; the ID IS RENDERED at the session's widths. Every
  // atom is then the same length for the whole session by construction rather
  // than by arithmetic that has to be kept in agreement across three call
  // sites. Group 0 is reserved for documents outside any mount, so an
  // on-the-fly read can never collide with a mounted `D001`.
  private docCoord = new Map<string, [number, number]>();
  private groupWidth = 0;
  private docWidth = 3;
  private currentRoot: string | null = null;

  constructor(initialWorkDir?: string) {
    if (initialWorkDir) {
      this.initWorkDir(initialWorkDir);
    }
  }

  /** Render a coordinate at the session's current widths. */
  private renderDocId(coord: [number, number]): string {
    const group = this.groupWidth > 0 ? String(coord[0]).padStart(this.groupWidth, "0") : "";
    return `D${group}${String(coord[1]).padStart(this.docWidth, "0")}`;
  }

  /** Mint an id for a path, or return the one it already has. */
  private docIdFor(path: string): string {
    const existing = this.docCoord.get(path);
    if (existing) return this.renderDocId(existing);

    // Outside any mount: group 0, the next free slot in it.
    let next = 0;
    for (const [g, d] of this.docCoord.values()) if (g === 0 && d > next) next = d;
    const coord: [number, number] = [0, next + 1];
    this.growWidthsFor(0, coord[1]);
    this.docCoord.set(path, coord);
    return this.renderDocId(coord);
  }

  /**
   * Widen the session's id format if a coordinate no longer fits.
   *
   * Every id is re-rendered when this happens, because the alternative is a
   * session whose atoms are not all the same length — and re-keying the caches
   * is the price of keeping that invariant true at every moment rather than
   * only at the start. It is loud, because ids an agent has already seen change
   * underneath it.
   */
  private growWidthsFor(group: number, doc: number): void {
    const needGroup = group > 0 ? String(group).length : this.groupWidth;
    const needDoc = String(doc).length;
    if (needGroup <= this.groupWidth && needDoc <= this.docWidth) return;

    const before = this.renderWidthSpec();
    this.groupWidth = Math.max(this.groupWidth, needGroup);
    this.docWidth = Math.max(this.docWidth, needDoc);
    this.rekeyToCurrentWidths(before);
  }

  private renderWidthSpec(): string {
    return this.groupWidth > 0 ? `D<${this.groupWidth}><${this.docWidth}>` : `D<${this.docWidth}>`;
  }

  /** Re-render every id and move the caches onto the new keys. */
  private rekeyToCurrentWidths(before: string): void {
    if (this.docCoord.size === 0) return;

    const indices = new Map<string, DocumentIndex>();
    const buffers = new Map<string, Buffer>();
    for (const [path, coord] of this.docCoord) {
      const id = this.renderDocId(coord);
      for (const [oldId, idx] of this.indices) {
        if (idx.path !== path) continue;
        idx.id = id;
        indices.set(id, idx);
        const buf = this.sourceBuffers.get(oldId);
        if (buf) buffers.set(id, buf);
      }
    }
    if (indices.size === 0) return;

    this.indices = indices;
    this.sourceBuffers = buffers;
    this.notices.push(
      `document ids widened from ${before} to ${this.renderWidthSpec()} — the corpus outgrew the format. ` +
      `Every id is re-rendered; anchors taken before now name the same documents under the shorter form.`
    );
  }

  /**
   * Assign every file under a mount a group/document coordinate.
   *
   * Both axes come from the data — directories in sorted order, files sorted
   * within them — so the same corpus mounted on another machine produces the
   * same addresses. Widths are measured, never assumed: a corpus with 7 groups
   * and 43 files in its largest gets `D<g><dd>`, and one with 200 files in a
   * group gets three digits. Regularity has to hold within a stream, not
   * between corpora.
   *
   * A single-group corpus carries no group axis at all — a constant coordinate
   * is not information, it is width.
   */
  private assignMountIds(root: string, files: string[]): MountAddressing {
    const byGroup = new Map<string, string[]>();
    for (const f of files) {
      const dir = dirname(relative(root, f)).replace(/\\/g, "/");
      const key = dir === "." ? "" : dir;
      const bucket = byGroup.get(key);
      if (bucket) bucket.push(f);
      else byGroup.set(key, [f]);
    }

    // Root first, then directories in path order — a canonical walk, so the
    // numbering reflects the layout rather than the order files were met.
    const groupPaths = Array.from(byGroup.keys()).sort();
    const single = groupPaths.length === 1;

    // Widths come from this corpus's own cardinality. A small corpus is
    // entitled to short ids — the invariant is that every atom in a session is
    // the same length, not that the length is the same between corpora. But a
    // session that has already handed ids out can only grow them, never narrow.
    const before = this.renderWidthSpec();
    // Two digits is the floor for an axis in use: a corpus of three is entitled
    // to short ids, but `D31` reads as a number rather than a coordinate.
    const fresh = this.docCoord.size === 0;
    const needGroup = single ? 0 : Math.max(2, String(groupPaths.length).length);
    const needDoc = Math.max(2, ...Array.from(byGroup.values()).map((v) => String(v.length).length));

    this.groupWidth = fresh ? needGroup : Math.max(this.groupWidth, needGroup);
    this.docWidth = fresh ? needDoc : Math.max(this.docWidth, needDoc);

    // Group 1 upward for mounted directories; 0 stays reserved for anything
    // read from outside the mount.
    groupPaths.forEach((g, gi) => {
      const inGroup = byGroup.get(g)!.slice().sort();
      inGroup.forEach((f, di) => {
        this.docCoord.set(f, [single ? 0 : gi + 1, di + 1]);
      });
    });

    if (before !== this.renderWidthSpec()) this.rekeyToCurrentWidths(before);

    return {
      groups: groupPaths.length,
      groupWidth: this.groupWidth,
      docWidth: this.docWidth,
      groupPaths,
    };
  }

  public initWorkDir(
    customWorkDir?: string,
    anchorPath?: string,
    run?: string | undefined,
    newRun = false
  ): string {
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

    // Re-discovering the same corpus CONTINUES the current run. Two discovers
    // are not two investigations: minting again would set the reading record
    // aside and report 0% over material already read, which is the fragmentation
    // this is meant to prevent. `newRun` is how you ask for a fresh start.
    if (!run && !newRun && this.workDir && this.currentRoot === root) {
      if (this.readsLedger.length > 0) {
        this.notices.push(
          `continuing run ${basename(this.workDir)} — ${this.readsLedger.length} read(s) so far are preserved; ` +
          `pass newRun to start a separate one`
        );
      }
      return this.workDir;
    }

    let rel: string;
    if (run) {
      // Attaching to an existing run, not starting one.
      rel = run === "latest" ? this.readLatest(root) : run;
      if (!existsSync(join(root, rel))) {
        throw new Error(`no run ${rel} under ${root} — omit run to start a new one`);
      }
    } else {
      // Second-resolution stamps collide when runs start in quick succession,
      // and a silently reused directory would merge two investigations.
      // Disambiguate deterministically, so the order stays readable.
      rel = stamp;
      for (let n = 2; existsSync(join(root, rel)); n++) rel = `${stamp}-${n}`;
    }

    const runDir = join(root, rel);
    mkdirSync(join(runDir, "documents"), { recursive: true });

    // LATEST names the run in progress. Attaching to an OLDER run to look at it
    // must not redefine that for everyone else — inspection should not move a
    // shared pointer. Written on mint, or if nothing has claimed it yet.
    if (!run || !existsSync(join(root, "LATEST"))) {
      writeFileSync(join(root, "LATEST"), rel, "utf8");
    }

    // A new run reads nothing yet; an attached one inherits what it already
    // read, so coverage continues across a restart instead of resetting to 0%.
    this.readsLedger = [];
    if (run) this.loadReadsLedger(runDir);

    // Re-anchoring on a different corpus means a different notebook. Drop the
    // cache so the next journal op rehydrates from the new root rather than
    // minting ids on top of someone else's ledger.
    if (this.journalRoot !== root) {
      this.journalRoot = root;
      this.journalEntries = [];
      this.journalLoaded = false;
    }

    this.workDir = runDir;
    this.currentRoot = root;
    return runDir;
  }

  private readLatest(root: string): string {
    const p = join(root, "LATEST");
    if (!existsSync(p)) throw new Error(`no run found under ${root} — omit run to start one`);
    return readFileSync(p, "utf8").trim();
  }

  /**
   * Restore a run's read ledger.
   *
   * reads.jsonl belongs to its run, so without this an attached run reports 0%
   * coverage over documents it has already read — the journal survives a
   * restart and the reading record did not, which made the two halves of the
   * read-vs-cited arithmetic disagree about what happened.
   */
  private loadReadsLedger(runDir: string): void {
    const p = join(runDir, "reads.jsonl");
    if (!existsSync(p)) return;

    for (const line of readFileSync(p, "utf8").split("\n")) {
      const t = line.trim();
      if (!t) continue;
      try {
        const rec = JSON.parse(t) as ReadLedgerEntry;
        if (rec && typeof rec.doc === "string" && Array.isArray(rec.spans)) this.readsLedger.push(rec);
      } catch {
        // A torn line must not take the whole ledger down.
      }
    }

    if (this.readsLedger.length > 0) {
      this.notices.push(
        `attached to run ${basename(runDir)} — ${this.readsLedger.length} prior read(s) restored, ` +
        `so coverage continues rather than restarting at zero`
      );
    }
  }

  /** Take and clear the pending notices, for the caller to put in the stream. */
  public drainNotices(): string[] {
    const out = this.notices;
    this.notices = [];
    return out;
  }

  // ──────────────────────────────────────────────────────── Discover & Index

  public async discover(
    paths: string[] = [],
    options: { glob?: string | undefined; recursive?: boolean | undefined; workDir?: string | undefined; run?: string | undefined; newRun?: boolean | undefined; root?: string | undefined } = {}
  ): Promise<Inventory> {
    const { glob = "*.md", recursive = false, workDir, run, newRun = false, root } = options;

    // A mount is a root plus everything Markdown beneath it. Recursion is not a
    // choice there — "the corpus" means the corpus.
    const mountRoot = root ? resolve(root) : null;
    const resolvedTargets = mountRoot ? [mountRoot] : paths.map((p) => resolve(p));
    if (resolvedTargets.length === 0) {
      throw new Error("discover needs a root or at least one path");
    }
    if (mountRoot && !existsSync(mountRoot)) {
      throw new Error(`no such root: ${mountRoot}`);
    }

    this.initWorkDir(workDir, resolvedTargets[0], run, newRun);

    // Collect matching files
    const fileList: string[] = [];
    for (const target of resolvedTargets) {
      if (!existsSync(target)) continue;
      const st = statSync(target);
      if (st.isFile()) {
        fileList.push(target);
      } else if (st.isDirectory()) {
        this.crawlDirectory(target, glob, mountRoot ? true : recursive, fileList);
      }
    }

    const uniqueFiles = Array.from(new Set(fileList)).sort();
    if (mountRoot && uniqueFiles.length === 0) {
      throw new Error(`no ${glob} files under ${mountRoot}`);
    }

    const addressing = mountRoot ? this.assignMountIds(mountRoot, uniqueFiles) : undefined;
    const docs: InventoryDoc[] = [];

    for (let i = 0; i < uniqueFiles.length; i++) {
      const filePath = uniqueFiles[i]!;
      const docId = this.docIdFor(filePath);
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

      const described = this.describeDoc(idx, grain);
      if (mountRoot) described.relPath = relative(mountRoot, filePath).replace(/\\/g, "/");
      docs.push(described);

      // Persist index
      if (this.workDir) {
        writeFileSync(join(this.workDir, "documents", `${docId}.index.json`), JSON.stringify(idx, null, 2), "utf8");
      }
    }

    // By id, so co-located documents sit together and the shared prefix that
    // marks a group is visible as a block rather than scattered.
    docs.sort((a, b) => a.id.localeCompare(b.id));

    this.inventory = {
      schema: 2,
      stamp: basename(this.workDir || ""),
      workDir: this.workDir || "",
      docs,
      root: mountRoot ?? undefined,
      addressing,
    };

    if (this.workDir) {
      writeFileSync(join(this.workDir, "inventory.json"), JSON.stringify(this.inventory, null, 2), "utf8");
    }

    return this.inventory;
  }

  /**
   * Re-report the inventory row for documents already indexed, the way the CLI's
   * `index` verb does — without re-crawling a directory. `refresh` forces a
   * re-scan even when size and mtime say nothing moved.
   */
  public async index(docIds?: string[] | undefined, refresh = false): Promise<InventoryDoc[]> {
    const targets = docIds && docIds.length > 0 ? docIds : Array.from(this.indices.keys());
    const out: InventoryDoc[] = [];

    for (const ref of targets) {
      const { docId } = this.resolveDoc(ref);
      if (refresh) {
        const idx = this.getIndex(docId);
        const buf = readFileSync(idx.path);
        const fresh = scanDocument(buf, { id: docId, path: idx.path, mtimeMs: statSync(idx.path).mtimeMs });
        this.indices.set(docId, fresh);
        this.sourceBuffers.set(docId, buf);
        this.persistIndex(docId, fresh);
      }
      out.push(this.describeDoc(this.getIndex(docId)));
    }

    return out;
  }

  /**
   * Triage facts about a document, decided on composition and never on meaning:
   * how much of it is machine furniture, whether its breaks correspond to its
   * H1s, and what structural oddities would mislead a reader who assumed a
   * clean ATX document.
   */
  private describeDoc(idx: DocumentIndex, grainOverride?: string): InventoryDoc {
    const c = (n: number) => idx.counts[n] ?? 0;
    const d1 = c(0), d2 = d1 + c(1), d3 = d2 + c(2);
    const grain = grainOverride ??
      `${d1}/${d2}/${d3}~${this.fmtBytes(idx.bytes > 0 && d1 > 0 ? Math.round(idx.bytes / d1) : idx.bytes)}`;

    const byKind = new Map<string, { count: number; bytes: number }>();
    let noiseBytes = 0;
    for (const n of idx.noise) {
      const cur = byKind.get(n.kind) ?? { count: 0, bytes: 0 };
      byKind.set(n.kind, { count: cur.count + 1, bytes: cur.bytes + n.bytes });
      noiseBytes += n.bytes;
    }
    const noiseRatio = idx.bytes > 0 ? noiseBytes / idx.bytes : 0;

    // Species are reported separately: an embedded file and a handful of tags
    // are different problems with different remedies.
    const notes: string[] = [];
    const embedded = byKind.get("data-uri");
    if (embedded?.bytes) notes.push(`embedded ${this.fmtBytes(embedded.bytes)} (${(embedded.bytes / idx.bytes * 100).toFixed(0)}%)`);
    const signed = byKind.get("signed-url");
    if (signed?.count) notes.push(`signed x${signed.count}`);
    const html = byKind.get("html");
    if (html && html.bytes > 1024) notes.push(`html ${this.fmtBytes(html.bytes)}`);
    const imgref = byKind.get("image-ref");
    if (imgref?.count) notes.push(`imgref x${imgref.count}`);

    // Two bases, neither privileged. Saying whether they correspond is what
    // lets the reader choose one deliberately.
    const breaksUnaligned = idx.breaks.length > 0 && d1 > 0 && idx.breaks.length !== d1 - 1;
    if (idx.breaks.length) notes.push(`breaks x${idx.breaks.length}${breaksUnaligned ? " (not h1-1)" : " (= h1-1)"}`);

    // A very long line in an otherwise clean document is a blob, not prose.
    if (idx.maxLine > 4096 && noiseRatio < 0.02) notes.push(`maxline ${this.fmtBytes(idx.maxLine)}`);
    if (idx.setextSuspects?.length) notes.push(`setext? x${idx.setextSuspects.length}`);
    if (idx.frontmatter) notes.push("frontmatter");
    if (idx.newline !== "lf") notes.push(idx.newline);
    if (idx.bom) notes.push("bom");
    if (idx.windows?.length) notes.push(`windows x${idx.windows.length}`);

    return {
      id: idx.id,
      path: idx.path,
      name: basename(idx.path),
      bytes: idx.bytes,
      grain,
      spineRatio: Number(idx.spine.ratio.toFixed(3)),
      levels: [0, 1, 2, 3, 4, 5].map((n) => c(n)).join("/").replace(/(\/0)+$/, ""),
      notes: notes.join(" "),
      noiseRatio: Number(noiseRatio.toFixed(3)),
      breaksUnaligned,
    };
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
      strip?: StripSpec | undefined;
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
      // A raw span read has NO anchor: the span field already carries the
      // location, and it is what a repeat call takes. The old `@a..b` marker
      // was malformed twice over — it wrote the range without isolating `..`,
      // and it overloaded `@`, which everywhere else introduces a digest. It
      // also did not resolve, so it named an address the tool would reject.
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
      chunks,
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
    options: { depth?: number | undefined; strip?: StripSpec | undefined } = {}
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
      const full = resolve(docRef);
      const docId = this.docIdFor(full);
      const buf = readFileSync(docRef);
      const idx = scanDocument(buf, { id: docId, path: full, mtimeMs: statSync(docRef).mtimeMs });
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
