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
  IndexSchema,
  JournalRecordSchema,
  JournalReadSchema,
  JournalTreeSchema,
  SkillsSchema,
  type ByteSpan,
  type DiscoverArgs,
  type ProfileArgs,
  type OutlineArgs,
  type MarksArgs,
  type ReadArgs,
  type BatchReadArgs,
  type CoverageArgs,
  type LocateArgs,
  type IndexArgs,
  type InventoryDoc,
  type JournalRecordArgs,
  type JournalReadArgs,
  type JournalTreeArgs,
  type SkillsArgs,
  type Elision,
} from "./types.ts";
import { MdnavEngine } from "./engine.ts";
import { listTopics, outlineTopic, readSection, readTopic, searchSkills, skillRoot } from "./skills.ts";
import {
  formatSourceChunkPrefix,
  formatAnchorString,
  formatJournalEntry,
  formatJournalReceipt,
  renderJournalTree,
  JOURNAL_HEADER,
  chunkHeader,
  frameConfig,
  closeChunk,
  FIELD,
  RANGE,
  EMPTY,
} from "./formatting.ts";

export function registerMdnavTools(server: any, engine: MdnavEngine) {
  /**
   * Every tool registers through here so out-of-band notices — a source that
   * moved under the cache — always reach the reader, whichever verb happens to
   * notice. On stderr they would reach the server log and nobody who matters.
   */
  const tool = (name: string, desc: string, shape: unknown, fn: (args: any) => Promise<any>) => {
    server.tool(name, desc, shape, async (args: any) => {
      const res = await fn(args);
      const notes = engine.drainNotices();
      if (notes.length === 0) return res;
      const lead = `${notes.map((n) => `mdnav: ${n}`).join("\n")}\n\n`;
      return { ...res, content: [{ type: "text", text: lead + (res?.content?.[0]?.text ?? "") }] };
    });
  };

  // 1. mdnav_discover
  tool(
    "mdnav_discover",
    "Mount a corpus. Pass a root to index every Markdown file nested under it in one call, addressed by a group/document coordinate and reported by relative path; or pass individual paths when there is no single root.",
    DiscoverSchema.shape,
    async (args: DiscoverArgs) => {
      try {
        const inventory = await engine.discover(args.paths ?? [], {
          glob: args.glob,
          recursive: args.recursive,
          root: args.root,
          run: args.run,
          newRun: args.newRun,
          workDir: args.workDir,
        });

        // The root once, then relative paths. Repeating a 70-character absolute
        // prefix on every row spends tokens restating a constant.
        //
        // The id scheme itself is NOT stated. The engine holds it — widths,
        // group paths, the whole map, in inventory.json — but the table already
        // demonstrates it: D301..D315 sit against Chapters/ rows. Emitting a
        // decoder for something the rows already show is the MCP spending
        // context on what it merely happens to know.
        const head = inventory.root ? `mount | ${inventory.root}\n\n` : "";

        return {
          content: [
            {
              type: "text",
              text: `${head}${renderInventory(inventory.docs)}\n\n${inventory.docs.length} document(s) indexed under ${inventory.workDir}`,
            },
          ],
        };
      } catch (err: any) {
        return { isError: true, content: [{ type: "text", text: `mdnav_discover error: ${err.message}` }] };
      }
    }
  );

  // 1b. mdnav_index
  tool(
    "mdnav_index",
    "Re-report the inventory row for documents already indexed — sizes, grain, and triage flags — without re-crawling a directory. Pass refresh to force a re-scan.",
    IndexSchema.shape,
    async (args: IndexArgs) => {
      try {
        const docs = await engine.index(args.docIds, args.refresh);
        if (docs.length === 0) {
          return { content: [{ type: "text", text: "No documents indexed yet — run mdnav_discover first." }] };
        }
        return { content: [{ type: "text", text: renderInventory(docs) }] };
      } catch (err: any) {
        return { isError: true, content: [{ type: "text", text: `mdnav_index error: ${err.message}` }] };
      }
    }
  );

  // 2. mdnav_profile
  tool(
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
  tool(
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
          // No brackets around the anchor: `[H0001` and `3504]` merge the
          // punctuation into the identifier, so the same chunk would not
          // present the same tokens here as it does everywhere else.
          const id = formatAnchorString(u.digest ? `${u.id}@${u.digest}` : u.id).padEnd(18);
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
  tool(
    "mdnav_marks",
    "List exact runs and byte spans of specific constructs (blockquote, fence, html, table, list).",
    MarksSchema.shape,
    async (args: MarksArgs) => {
      try {
        const runs = await engine.marks(args.docId, args.kind, args.minBytes);
        const lines = runs.map((r) => {
          const span = `${r.start}${RANGE}${r.end}`.padStart(20);
          const size = fmtBytes(r.bytes).padStart(10);
          const linesCount = `${r.lines} L`.padStart(6);
          const anchor = (r.containingAnchor ? formatAnchorString(r.containingAnchor) : "").padEnd(20);
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
  tool(
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
        const notes = [...res.warnings, ...elisionNote(res.elidedBytes, res.elisions)];
        const warn = notes.length > 0 ? `${notes.map((w) => `mdnav: ${w}`).join("\n")}\n\n` : "";

        // Each span gets its OWN header. A discontiguous read (headings: [...])
        // has no single span — labelling it with the outer bound would claim
        // the gaps between the units as read material.
        let body = res.text;
        if (prefixOn(args.prefixFormat)) {
          const blocks = res.chunks.map((chunk, i) => {
            const span = res.spans[i] ?? mergeSpans(res.spans);
            // No anchor (a raw span read) means the document IS the address.
            const anchor = res.anchors[i] ?? res.anchors[0] ?? "";
            return `${formatSourceChunkPrefix(res.docId, anchor, span)}\n${closeChunk(chunk, res.docId, anchor)}`;
          });
          body = `${chunkHeader()}\n\n${blocks.join("\n\n")}`;
        }

        return {
          content: [
            {
              type: "text",
              text: `${warn}${body}`,
            },
          ],
        };
      } catch (err: any) {
        return { isError: true, content: [{ type: "text", text: `mdnav_read error: ${err.message}` }] };
      }
    }
  );

  // 6. mdnav_batch_read
  tool(
    "mdnav_batch_read",
    "Native batch reader for harvesting multiple sections (e.g. abstracts across 20+ papers) in a single RPC.",
    BatchReadSchema.shape,
    async (args: BatchReadArgs) => {
      try {
        const results = await engine.batchRead(args.requests, {
          depth: args.depth,
          strip: args.strip,
        });

        // Framing off means NO provenance, here as anywhere else. This branch
        // used to emit an HTML comment carrying the full address, so the
        // "off" setting was only off for `read` — which would quietly
        // contaminate the control arm of any study of the framing itself.
        // The label rides in the frame, and so is surfaced only when there is
        // one.
        const blocks = results.map((r) => {
          if (!prefixOn(args.prefixFormat)) return r.text;
          const head = formatSourceChunkPrefix(r.docId, r.anchor || EMPTY, r.span ?? [0, 0], r.label ?? EMPTY);
          return `${head}\n${closeChunk(r.text, r.docId, r.anchor || EMPTY)}`;
        });

        const warnings = [
          ...results.flatMap((r) => r.warnings),
          ...elisionNote(
            results.reduce((n, r) => n + r.elidedBytes, 0),
            results.flatMap((r) => r.elisions)
          ),
        ];
        const warn = warnings.length > 0 ? `${warnings.map((w) => `mdnav: ${w}`).join("\n")}\n\n` : "";
        const header = prefixOn(args.prefixFormat) ? `${chunkHeader(true)}\n\n` : "";

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
  tool(
    "mdnav_coverage",
    "Compute byte-exact reading coverage against total document size and list unread units.",
    CoverageSchema.shape,
    async (args: CoverageArgs) => {
      try {
        const reports = await engine.coverage(args.docIds, args.depth, args.byBreaks);
        const lines: string[] = [];

        lines.push(["doc", "read", "of", "read %", "cited", "cited %", "reads", "entries"].join(FIELD));

        for (const rep of reports) {
          lines.push([
            rep.docId,
            `${fmtNum(rep.bytesRead)} B`,
            `${fmtNum(rep.totalBytes)} B`,
            `${rep.percent.toFixed(1)}%`,
            `${fmtNum(rep.bytesCited)} B`,
            `${rep.citedPercent.toFixed(1)}%`,
            String(rep.readsCount),
            String(rep.citations),
          ].join(FIELD) + (rep.elidedBytes > 0 ? `${FIELD}elided ${fmtBytes(rep.elidedBytes)}` : ""));

          // The two structural reading defects, as byte counts rather than as
          // something to eyeball. See state-and-audit.md §6.
          if (rep.readNotCited > 0) {
            lines.push(`  read not cited${FIELD}${fmtBytes(rep.readNotCited)}${FIELD}silent attrition candidate — say why, or restore it`);
          }
          if (rep.citedNotRead > 0) {
            lines.push(`  cited not read${FIELD}${fmtBytes(rep.citedNotRead)}${FIELD}salience capture hazard — re-read the surrounding unit`);
          }

          for (const u of rep.unreadAnchors.slice(0, 10)) {
            lines.push(`  unread${FIELD}${formatAnchorString(u.anchor)}${FIELD}${fmtBytes(u.bytes)}${FIELD}${u.title}`);
          }
          if (rep.unreadAnchors.length > 10) {
            lines.push(`  unread${FIELD}${rep.unreadAnchors.length - 10} more not listed`);
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
  tool(
    "mdnav_locate",
    "Locate exact text or regex matches in headings/lines without dumping full text bodies.",
    LocateSchema.shape,
    async (args: LocateArgs) => {
      try {
        const hits = await engine.locate(args.pattern, args.docIds, args.caseInsensitive, args.max);
        const lines = hits.map((h) => `${formatAnchorString(h.anchor).padEnd(24)} L ${String(h.line).padEnd(5)} ${h.text}`);

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
  tool(
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
  tool(
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
  tool(
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

  // 12. mdnav_skills
  tool(
    "mdnav_skills",
    "Serve mdnav's own investigative discipline — the doc-dive skill and its references — listed, outlined, searched, or read a section at a time. Call with no arguments to see what is available.",
    SkillsSchema.shape,
    async (args: SkillsArgs) => {
      try {
        if (args.search) {
          const hits = searchSkills(args.search);
          if (hits.length === 0) {
            return { content: [{ type: "text", text: `No skill topic matches ${args.search}.` }] };
          }
          const rows = hits.map((h) =>
            `${formatAnchorString(`${h.topic}:${h.hid}`).padEnd(34)}${FIELD}L ${String(h.line).padEnd(5)}${FIELD}${h.text}`
          );
          return { content: [{ type: "text", text: rows.join("\n") }] };
        }

        if (!args.topic) {
          const topics = listTopics();
          if (topics.length === 0) {
            return { content: [{ type: "text", text: `No skill corpus found at ${skillRoot()}.` }] };
          }
          const row = (topic: string, bytes: string, units: string, title: string) =>
            [topic.padEnd(22), bytes.padStart(10), units.padStart(9), title].join(FIELD);
          const rows = topics.map((t) =>
            row(t.topic, fmtBytes(t.bytes), `${t.headings} units`, t.title)
          );
          return {
            content: [{
              type: "text",
              text: `${row("topic", "bytes", "units", "title")}\n${rows.join("\n")}\n\n` +
                `Read one with mdnav_skills({ topic }), a section with { topic, section }, ` +
                `or find a passage with { search }. 'index' is the discipline itself.`,
            }],
          };
        }

        if (args.outline) {
          const rows = outlineTopic(args.topic, args.depth ?? 6).map(({ heading, bytes }) =>
            [
              `${"  ".repeat(Math.max(0, heading.level - 1))}${formatAnchorString(`${heading.hid}@${heading.digest}`)}`.padEnd(30),
              fmtBytes(bytes).padStart(10),
              heading.title,
            ].join(FIELD)
          );
          return { content: [{ type: "text", text: rows.join("\n") }] };
        }

        if (args.section) {
          const s = readSection(args.topic, args.section);
          const anchor = `${s.heading.hid}@${s.heading.digest}`;
          const head = formatSourceChunkPrefix(s.topic, anchor, s.span);
          return { content: [{ type: "text", text: `${head}\n${closeChunk(s.text, s.topic, anchor)}` }] };
        }

        const { topic, text } = readTopic(args.topic);
        const head = formatSourceChunkPrefix(topic.topic, EMPTY, [0, topic.bytes]);
        return { content: [{ type: "text", text: `${head}\n${closeChunk(text, topic.topic, EMPTY)}` }] };
      } catch (err: any) {
        return { isError: true, content: [{ type: "text", text: `mdnav_skills error: ${err.message}` }] };
      }
    }
  );
}

/**
 * The inventory table, with the triage facts a reader needs BEFORE spending
 * context on the bytes: how much of each document is machine furniture, whether
 * its thematic breaks correspond to its H1s, and what structural oddities would
 * mislead someone assuming a clean ATX document.
 *
 * The two closing warnings are composition, never meaning: they say what the
 * material costs to read, not what it is worth reading.
 */
function renderInventory(docs: InventoryDoc[]): string {
  const rows = docs.map((d) => [
    d.id,
    `${fmtNum(d.bytes ?? 0)} B`,
    d.levels || "—",
    d.grain || "—",
    (d.spineRatio ?? 0) > 0 ? `${((d.spineRatio ?? 0) * 100).toFixed(1)}%` : "—",
    d.notes || EMPTY,
    d.relPath ?? d.path,
  ]);
  const header = ["doc", "bytes", "h1/h2/..", "grain", "spine", "notes", "path"];
  const lines = [header.join(FIELD), ...rows.map((r) => r.join(FIELD))];

  const unaligned = docs.filter((d) => d.breaksUnaligned);
  if (unaligned.length > 0) {
    lines.push(
      "",
      `mdnav: in ${unaligned.length} document(s) the H1 count and thematic-break count do not correspond.`,
      `       Neither basis is privileged — inspect both and choose: outline({ depth: 1 }) or outline({ byBreaks: true }).`
    );
  }

  const noisy = docs.filter((d) => (d.noiseRatio ?? 0) >= 0.1);
  if (noisy.length > 0) {
    const worst = noisy.reduce((a, b) => ((a.noiseRatio ?? 0) > (b.noiseRatio ?? 0) ? a : b));
    lines.push(
      "",
      `mdnav: ${noisy.length} document(s) are >=10% embedded data or HTML markup (worst: ${worst.id} at ${((worst.noiseRatio ?? 0) * 100).toFixed(1)}%).`,
      `       Read those with strip: "all" — or name the species, e.g. strip: ["data-uri"] — before spending context on the raw bytes.`,
      `       For a species mdnav does not know about, aim stripMatch: "<regex>" at it.`
    );
  }

  return lines.join("\n");
}

/**
 * Provenance headers are ON by default: a header the reader can rely on being
 * there is worth more than one that comes and goes, and a chunk that enters
 * context unlabelled cannot be bound to the outline row that introduced it.
 * MDNAV_PREFIX=off silences them for a whole session.
 */
function prefixOn(argValue: boolean | undefined): boolean {
  return frameConfig().frame && argValue !== false;
}

/** Outer bound of a set of spans — used only when a span cannot be identified. */
function mergeSpans(spans: ByteSpan[]): ByteSpan {
  if (spans.length === 0) return [0, 0];
  return [Math.min(...spans.map((s) => s[0])), Math.max(...spans.map((s) => s[1]))];
}

/**
 * Elision is addressed, not hidden. The stream carries a marker where each
 * removed span was; this says how much went in total, so the reader can see
 * what was skipped and decide whether to re-read the anchor without strip.
 */
function elisionNote(elidedBytes: number, elisions: Elision[]): string[] {
  if (elidedBytes <= 0) return [];
  const byKind = new Map<string, number>();
  for (const e of elisions) byKind.set(e.kind, (byKind.get(e.kind) ?? 0) + 1);
  const detail = Array.from(byKind.entries()).map(([k, n]) => `${k} x${n}`).join(", ");
  return [`elided ${fmtBytes(elidedBytes)}${detail ? ` (${detail})` : ""} — re-read this anchor without strip to get it`];
}

function fmtBytes(n: number): string {
  if (n < 1024) return `${n} B`;
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(2)} KiB`;
  return `${(n / 1048576).toFixed(2)} MiB`;
}

function fmtNum(n: number): string {
  return n.toLocaleString("en-US");
}
