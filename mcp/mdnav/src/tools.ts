/**
 * MCP tool handlers for mdnav.
 */

import {
  DiscoverSchema,
  ProfileSchema,
  OutlineSchema,
  MarksSchema,
  ReadSchema,
  BatchReadSchema,
  CoverageSchema,
  LocateSchema,
  JournalRecordSchema,
  JournalReadSchema,
  JournalTreeSchema,
  type ByteSpan,
  type DiscoverArgs,
  type ProfileArgs,
  type OutlineArgs,
  type MarksArgs,
  type ReadArgs,
  type BatchReadArgs,
  type CoverageArgs,
  type LocateArgs,
  type JournalRecordArgs,
  type JournalReadArgs,
  type JournalTreeArgs,
} from "./types.ts";
import { MdnavEngine } from "./engine.ts";
import {
  formatSourceChunkPrefix,
  formatJournalEntry,
  formatJournalReceipt,
  renderJournalTree,
  JOURNAL_HEADER,
  CHUNK_HEADER,
  FIELD,
  EMPTY,
} from "./formatting.ts";

export function registerMdnavTools(server: any, engine: MdnavEngine) {
  // 1. mdnav_discover
  server.tool(
    "mdnav_discover",
    "Discover, index, and cache Markdown documents from paths or directories.",
    DiscoverSchema.shape,
    async (args: DiscoverArgs) => {
      try {
        const inventory = await engine.discover(args.paths, {
          glob: args.glob,
          recursive: args.recursive,
          workDir: args.workDir,
        });

        const rows = inventory.docs.map(
          (d) => `${d.id}  ${String(d.bytes).padStart(8)} B  Grain: ${d.grain}  Spine: ${(d.spineRatio ? `${(d.spineRatio * 100).toFixed(1)}%` : "—").padStart(5)}  ${d.path}`
        );

        return {
          content: [
            {
              type: "text",
              text: `Indexed ${inventory.docs.length} document(s) under ${inventory.workDir}\n\n${rows.join("\n")}`,
            },
          ],
        };
      } catch (err: any) {
        return { isError: true, content: [{ type: "text", text: `mdnav_discover error: ${err.message}` }] };
      }
    }
  );

  // 2. mdnav_profile
  server.tool(
    "mdnav_profile",
    "Profile construct composition and gap cadence (cv) to identify structural delimiters.",
    ProfileSchema.shape,
    async (args: ProfileArgs) => {
      try {
        const rows = await engine.profile(args.docId);
        const header = "  construct       runs      bytes      %   median gap      cv   detail";
        const lines = rows.map((r) => {
          const name = r.construct.padEnd(14);
          const runs = String(r.runs).padStart(6);
          const bytes = String(r.bytes.toLocaleString("en-US")).padStart(10);
          const pct = `${r.percent.toFixed(1)}%`.padStart(6);
          const gap = r.medianGap !== null ? `${r.medianGap} B`.padStart(12) : "—".padStart(12);
          const cv = r.cv !== null ? r.cv.toFixed(2).padStart(7) : "—".padStart(7);
          const detail = r.detail ? `   ${r.detail}` : "";
          return `  ${name}${runs} ${bytes} ${pct} ${gap} ${cv}${detail}`;
        });

        return {
          content: [
            {
              type: "text",
              text: `Profile for ${args.docId}\n\n${header}\n${lines.join("\n")}`,
            },
          ],
        };
      } catch (err: any) {
        return { isError: true, content: [{ type: "text", text: `mdnav_profile error: ${err.message}` }] };
      }
    }
  );

  // 3. mdnav_outline
  server.tool(
    "mdnav_outline",
    "Generate hierarchical outline with direct and subtree sizes, and construct composition tags.",
    OutlineSchema.shape,
    async (args: OutlineArgs) => {
      try {
        const units = await engine.outline(args.docId, {
          depth: args.depth,
          within: args.within,
          comp: args.comp,
          byBreaks: args.byBreaks,
          windows: args.windows,
        });

        const lines = units.map((u) => {
          const id = `[${u.id}${u.digest ? `@${u.digest}` : ""}]`.padEnd(14);
          const lvl = u.level ? `H${u.level}`.padEnd(4) : "    ";
          const size = `unit=${fmtBytes(u.unitBytes)}`.padEnd(15);
          const sub = u.subtreeBytes ? `subtree=${fmtBytes(u.subtreeBytes)}`.padEnd(18) : "".padEnd(18);
          const comp = u.comp ? `${u.comp}`.padEnd(24) : "";
          return `${id} ${lvl} ${size} ${sub} ${comp} ${u.title}`;
        });

        return {
          content: [
            {
              type: "text",
              text: lines.join("\n"),
            },
          ],
        };
      } catch (err: any) {
        return { isError: true, content: [{ type: "text", text: `mdnav_outline error: ${err.message}` }] };
      }
    }
  );

  // 4. mdnav_marks
  server.tool(
    "mdnav_marks",
    "List exact runs and byte spans of specific constructs (blockquote, fence, html, table, list).",
    MarksSchema.shape,
    async (args: MarksArgs) => {
      try {
        const runs = await engine.marks(args.docId, args.kind, args.minBytes);
        const lines = runs.map((r) => {
          const span = `${r.start}..${r.end}`.padStart(16);
          const size = fmtBytes(r.bytes).padStart(10);
          const linesCount = `${r.lines}L`.padStart(4);
          const anchor = r.containingAnchor ? r.containingAnchor.padEnd(14) : "".padEnd(14);
          return `${span} ${size} ${linesCount}  ${anchor} ${r.preview}`;
        });

        return {
          content: [
            {
              type: "text",
              text: lines.join("\n"),
            },
          ],
        };
      } catch (err: any) {
        return { isError: true, content: [{ type: "text", text: `mdnav_marks error: ${err.message}` }] };
      }
    }
  );

  // 5. mdnav_read
  server.tool(
    "mdnav_read",
    "Read literal Markdown byte span at exact depth/extent with optional binary noise stripping.",
    ReadSchema.shape,
    async (args: ReadArgs) => {
      try {
        const res = await engine.read(args.docId, {
          heading: args.heading,
          headings: args.headings,
          from: args.from,
          to: args.to,
          span: args.span,
          extent: args.extent,
          depth: args.depth,
          strip: args.strip,
          stripMatch: args.stripMatch,
        });

        // Drift notices go in-band. On stderr they would reach the server log
        // and never the reader, who is the one citing the anchor.
        const warn = res.warnings.length > 0 ? `${res.warnings.map((w) => `mdnav: ${w}`).join("\n")}\n\n` : "";
        const head = args.prefixFormat
          ? `${CHUNK_HEADER}\n${formatSourceChunkPrefix(res.docId, res.anchors[0] ?? EMPTY, mergeSpans(res.spans), res.bytes)}\n`
          : "";

        return {
          content: [
            {
              type: "text",
              text: `${warn}${head}${res.text}`,
            },
          ],
        };
      } catch (err: any) {
        return { isError: true, content: [{ type: "text", text: `mdnav_read error: ${err.message}` }] };
      }
    }
  );

  // 6. mdnav_batch_read
  server.tool(
    "mdnav_batch_read",
    "Native batch reader for harvesting multiple sections (e.g. abstracts across 20+ papers) in a single RPC.",
    BatchReadSchema.shape,
    async (args: BatchReadArgs) => {
      try {
        const results = await engine.batchRead(args.requests, {
          depth: args.depth,
          strip: args.strip,
        });

        // One labelling mechanism, not two: prefixFormat REPLACES the comment
        // tag rather than stacking on it. The prefix carries strictly more —
        // the resolved digest, the span, and the byte count.
        const blocks = results.map((r) => {
          if (args.prefixFormat) {
            const head = `${formatSourceChunkPrefix(r.docId, r.anchor || EMPTY, r.span ?? [0, 0], r.bytes)}${FIELD}${r.label ?? EMPTY}`;
            return `${head}\n${r.text}`;
          }
          const tag = r.label
            ? `<!-- mdnav ${r.docId}:${r.anchor} [${r.label}] -->`
            : `<!-- mdnav ${r.docId}:${r.anchor} -->`;
          return `${tag}\n\n${r.text}`;
        });

        const warnings = results.flatMap((r) => r.warnings);
        const warn = warnings.length > 0 ? `${warnings.map((w) => `mdnav: ${w}`).join("\n")}\n\n` : "";
        const header = args.prefixFormat ? `${CHUNK_HEADER}${FIELD}label\n\n` : "";

        return {
          content: [
            {
              type: "text",
              text: `${warn}${header}${blocks.join("\n\n---\n\n")}`,
            },
          ],
        };
      } catch (err: any) {
        return { isError: true, content: [{ type: "text", text: `mdnav_batch_read error: ${err.message}` }] };
      }
    }
  );

  // 7. mdnav_coverage
  server.tool(
    "mdnav_coverage",
    "Compute byte-exact reading coverage against total document size and list unread units.",
    CoverageSchema.shape,
    async (args: CoverageArgs) => {
      try {
        const reports = await engine.coverage(args.docIds, args.depth, args.byBreaks);
        const lines: string[] = [];

        for (const rep of reports) {
          const pct = `${rep.percent.toFixed(1)}%`.padStart(6);
          const ratio = `${fmtNum(rep.bytesRead)} / ${fmtNum(rep.totalBytes)} B`.padEnd(26);
          const elided = rep.elidedBytes > 0 ? `  elided=${fmtBytes(rep.elidedBytes)}` : "";
          lines.push(`${rep.docId.padEnd(6)} ${ratio} ${pct}  reads=${rep.readsCount}${elided}`);

          if (rep.unreadAnchors.length > 0) {
            for (const u of rep.unreadAnchors.slice(0, 10)) {
              lines.push(`  unread: ${u.anchor.padEnd(12)} (${fmtBytes(u.bytes).padStart(8)})  ${u.title}`);
            }
            if (rep.unreadAnchors.length > 10) {
              lines.push(`  ... and ${rep.unreadAnchors.length - 10} more unread anchors`);
            }
          }
        }

        return {
          content: [
            {
              type: "text",
              text: lines.join("\n"),
            },
          ],
        };
      } catch (err: any) {
        return { isError: true, content: [{ type: "text", text: `mdnav_coverage error: ${err.message}` }] };
      }
    }
  );

  // 8. mdnav_locate
  server.tool(
    "mdnav_locate",
    "Locate exact text or regex matches in headings/lines without dumping full text bodies.",
    LocateSchema.shape,
    async (args: LocateArgs) => {
      try {
        const hits = await engine.locate(args.pattern, args.docIds, args.caseInsensitive, args.max);
        const lines = hits.map((h) => `${h.anchor.padEnd(16)} L${String(h.line).padEnd(5)} ${h.text}`);

        return {
          content: [
            {
              type: "text",
              text: lines.length > 0 ? lines.join("\n") : `No matches found for pattern "${args.pattern}"`,
            },
          ],
        };
      } catch (err: any) {
        return { isError: true, content: [{ type: "text", text: `mdnav_locate error: ${err.message}` }] };
      }
    }
  );

  // 9. mdnav_journal_record
  server.tool(
    "mdnav_journal_record",
    "Append one observation, hypothesis, or decision to the investigative notebook, optionally linked to the entries it develops. Returns a compact receipt — never an echo of the body you just wrote.",
    JournalRecordSchema.shape,
    async (args: JournalRecordArgs) => {
      try {
        const { entry, anchorWarnings } = engine.recordJournal(args);
        const warn = anchorWarnings.length > 0 ? `${anchorWarnings.map((w) => `mdnav: ${w}`).join("\n")}\n` : "";
        return { content: [{ type: "text", text: `${warn}${formatJournalReceipt(entry)}` }] };
      } catch (err: any) {
        return { isError: true, content: [{ type: "text", text: `mdnav_journal_record error: ${err.message}` }] };
      }
    }
  );

  // 10. mdnav_journal_read
  server.tool(
    "mdnav_journal_read",
    "Read back the notebook as a token-isolated ledger, filtered by concept, derived status, op, or citing document.",
    JournalReadSchema.shape,
    async (args: JournalReadArgs) => {
      try {
        const entries = engine.readJournal(args);
        if (entries.length === 0) {
          return { content: [{ type: "text", text: "No journal entries match those filters." }] };
        }
        const text = args.rawJson
          ? JSON.stringify(entries, null, 2)
          : [JOURNAL_HEADER, ...entries.map(formatJournalEntry)].join("\n");
        return { content: [{ type: "text", text }] };
      } catch (err: any) {
        return { isError: true, content: [{ type: "text", text: `mdnav_journal_read error: ${err.message}` }] };
      }
    }
  );

  // 11. mdnav_journal_tree
  server.tool(
    "mdnav_journal_tree",
    "Render the lineage of recorded ideas — what refined, superseded, adopted, or rejected what — with each entry's derived status.",
    JournalTreeSchema.shape,
    async (args: JournalTreeArgs) => {
      try {
        const all = engine.resolveJournal(args.workDir);
        const scoped = args.concept ? all.filter((e) => e.concept === args.concept) : all;
        if (scoped.length === 0) {
          return { content: [{ type: "text", text: "No journal entries to chart." }] };
        }
        return { content: [{ type: "text", text: renderJournalTree(scoped) }] };
      } catch (err: any) {
        return { isError: true, content: [{ type: "text", text: `mdnav_journal_tree error: ${err.message}` }] };
      }
    }
  );
}

/** Outer bound of a set of spans, for one provenance header over a multi-span read. */
function mergeSpans(spans: ByteSpan[]): ByteSpan {
  if (spans.length === 0) return [0, 0];
  return [Math.min(...spans.map((s) => s[0])), Math.max(...spans.map((s) => s[1]))];
}

function fmtBytes(n: number): string {
  if (n < 1024) return `${n} B`;
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(2)} KiB`;
  return `${(n / 1048576).toFixed(2)} MiB`;
}

function fmtNum(n: number): string {
  return n.toLocaleString("en-US");
}
