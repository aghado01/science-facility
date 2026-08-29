/**
 * Core type definitions and schemas for mdnav.
 */

import { z } from "./deps.ts";

export type ByteSpan = [number, number];

export interface HeadingEntry {
  hid: string;           // e.g. "H0001"
  level: number;         // 1..6
  title: string;
  digest: string;        // 4-char hex
  line: number;          // 1-indexed
  headingStart: number;  // byte offset of '#'
  bodyStart: number;     // byte offset after heading line
  subtreeEnd: number;    // byte offset where subtree ends
}

export interface BreakEntry {
  sid: string;           // e.g. "S0001"
  line: number;
  start: number;
  end: number;
  label: string;
}

export interface WindowEntry {
  wid: string;           // e.g. "W0001"
  title: string;
  digest: string;        // 4-char hex, minted from sha256 + start
  start: number;
  end: number;
  bytes: number;
  within?: string | undefined;
  unbroken?: boolean | undefined;
}

/**
 * A resolved anchor target. Headings, thematic-break segments (Snnnn) and
 * windows (Wnnnn) all resolve into this one shape, so `read` treats the three
 * as a single address space — the same guarantee the CLI makes.
 */
export interface AnchorTarget {
  hid: string;
  level: number;
  title: string;
  digest: string;
  headingStart: number;
  bodyStart: number;
  subtreeEnd: number;
  synthetic?: boolean | undefined;
}

export interface NoiseEntry {
  kind: "data-uri" | "html" | "signed-url" | "image-ref";
  start: number;
  end: number;
  bytes: number;
  replacement?: string | undefined;
}

export interface DocumentIndex {
  schema: number;
  id: string;            // e.g. "D001"
  path: string;
  bytes: number;
  sha256: string;
  mtimeMs: number;
  encoding: string;
  bom: boolean;
  newline: string;
  headings: HeadingEntry[];
  counts: number[];
  spine: { bytes: number; ratio: number };
  breaks: BreakEntry[];
  maxLine: number;
  noise: NoiseEntry[];
  setextSuspects?: number[] | undefined;
  frontmatter?: { start: number; end: number } | undefined;
  windows?: WindowEntry[] | undefined;
}

/** Machine furniture mdnav knows how to name and remove. */
export type StripKind = "data-uri" | "html" | "signed-url" | "image-ref";

export const STRIP_KINDS: StripKind[] = ["data-uri", "html", "signed-url", "image-ref"];

/** `"all"`, `"none"`, or the exact species to elide. */
export type StripSpec = "all" | "none" | StripKind[];

export interface InventoryDoc {
  id: string;
  path: string;
  /** Path relative to the mount root, when one was given. */
  relPath?: string | undefined;
  name: string;
  bytes?: number | undefined;
  grain?: string | undefined;
  spineRatio?: number | undefined;
  /** H1/H2/.. counts, trailing zeroes trimmed. */
  levels?: string | undefined;
  /** Triage flags: embedded data, signed URLs, break basis, setext suspects... */
  notes?: string | undefined;
  /** Share of the document that is machine furniture rather than prose. */
  noiseRatio?: number | undefined;
  /** True when the thematic-break count does not correspond to the H1 count. */
  breaksUnaligned?: boolean | undefined;
}

export interface Inventory {
  schema: number;
  stamp: string;
  workDir: string;
  docs: InventoryDoc[];
  /** The mounted corpus root, when discovery was given one. */
  root?: string | undefined;
  /** How document ids were minted under this mount. */
  addressing?: MountAddressing | undefined;
}

/**
 * Document ids under a mount are a coordinate, not a counter: a group axis
 * (which directory) and a document axis (which file within it), each padded to
 * a width measured from the corpus itself rather than assumed.
 *
 * Both axes are derived canonically from the data, so the same corpus mounted
 * anywhere yields the same addresses — which is what makes a corpus usable as a
 * fixture. A corpus that changes is a new version of the data, and citations
 * carried across versions are caught by digest drift.
 *
 * Padding is what makes co-located documents share a literal token prefix
 * (`D0301`, `D0302`), so grouping is legible without decoding anything.
 */
export interface MountAddressing {
  groups: number;
  groupWidth: number;
  docWidth: number;
  /** Directory per group index, relative to root. Index 0 is the root itself. */
  groupPaths: string[];
}

export interface ReadLedgerEntry {
  ts: string;
  doc: string;
  spans: ByteSpan[];
  basis: string;
  depth?: number | undefined;
  bytes: number;
  elidedBytes?: number | undefined;
}

export interface OutlineUnit {
  id: string;
  level?: number | undefined;
  title: string;
  digest?: string | undefined;
  unitBytes: number;
  subtreeBytes?: number | undefined;
  comp?: string | undefined;
  noiseBytes?: number | undefined;
  noisePercent?: number | undefined;
}

export interface ProfileRow {
  construct: string;
  runs: number;
  bytes: number;
  percent: number;
  medianGap: number | null;
  cv: number | null;
  detail?: string | undefined;
}

export interface ConstructRun {
  start: number;
  end: number;
  bytes: number;
  lines: number;
  containingAnchor?: string | undefined;
  preview: string;
  detail?: string | undefined;
}

export interface DocumentCoverage {
  docId: string;
  path: string;
  bytesRead: number;
  totalBytes: number;
  percent: number;
  readsCount: number;
  elidedBytes: number;
  unreadAnchors: Array<{ anchor: string; bytes: number; title: string }>;

  // The other half of the read-vs-cited arithmetic. `readNotCited` is the
  // silent-attrition surface; `citedNotRead` is the salience-capture surface.
  bytesCited: number;
  citedPercent: number;
  citations: number;
  readNotCited: number;
  citedNotRead: number;
}

// ────────────────────────────────────────────────────────── Journal Ledger

export type JournalOp = "propose" | "refine" | "supersede" | "reject" | "adopt" | "retract" | "note";

export type JournalStatus = "active" | "refined" | "superseded" | "rejected" | "adopted" | "retracted";

/**
 * One append-only entry in the investigative notebook.
 *
 * `status` is NOT stored: it is derived from the ops of an entry's children at
 * read time. The file stays a pure event log, so rehydrating it reproduces the
 * live session exactly, and "preserve history — never overwrite in place" holds
 * by construction rather than by discipline.
 */
export interface JournalEntry {
  id: string;              // "N001", "N002", ...
  ts: string;              // ISO-8601 UTC, directly comparable with ReadLedgerEntry.ts
  op: JournalOp;
  refs: string[];          // Causal parents. Plural: reconciling two lines of thought is a merge.
  concept?: string | undefined;   // e.g. "C-001" or a topic tag
  anchors: string[];       // e.g. ["D014:H0003@a1b2", "code:grassmann.py"]
  bytes: number;           // Byte length of body
  body: string;
}

/** A journal entry with its derived state attached. */
export interface ResolvedJournalEntry extends JournalEntry {
  status: JournalStatus;
  children: string[];
}

/**
 * One anchor with its components given separately.
 *
 * The stream already presents anchors decomposed — `D014 : H0003 @ a1b2` — so
 * taking them back apart is the input form that matches what the reader saw.
 * A fused string is still accepted, but then the tool has to INFER from
 * punctuation whether `code:grassmann.py` was meant as an address or as the
 * reader's own vocabulary. Components state it instead of implying it.
 */
export interface AnchorInput {
  scope: string;
  unit?: string | undefined;
  digest?: string | undefined;
}

/** The same components as a filter, where each is optional and names its own edge. */
export interface AnchorFilter {
  scope?: string | undefined;
  unit?: string | undefined;
  digest?: string | undefined;
}

export interface JournalRecordArgs {
  op: JournalOp;
  body: string;
  concept?: string | undefined;
  refs?: string[] | undefined;
  anchors?: Array<string | AnchorInput> | undefined;
  workDir?: string | undefined;
}

export interface JournalReadArgs {
  concept?: string | undefined;
  status?: JournalStatus | undefined;
  /** Anchor scope: a document id, or a namespace like `code`. */
  scope?: string | undefined;
  /** @deprecated The old name for `scope`. It never only took document ids. */
  docId?: string | undefined;
  anchor?: string | AnchorFilter | undefined;
  digest?: string | undefined;
  op?: JournalOp | undefined;
  limit?: number | undefined;
  rawJson?: boolean | undefined;
  workDir?: string | undefined;
}

export interface JournalTreeArgs {
  concept?: string | undefined;
  workDir?: string | undefined;
}

// ────────────────────────────────────────────────────────── Tool Arguments

export interface DiscoverArgs {
  paths?: string[] | undefined;
  root?: string | undefined;
  glob?: string | undefined;
  recursive?: boolean | undefined;
  run?: string | undefined;
  newRun?: boolean | undefined;
  workDir?: string | undefined;
}

export interface IndexArgs {
  docIds?: string[] | undefined;
  refresh?: boolean | undefined;
  workDir?: string | undefined;
}

export interface ProfileArgs {
  docId: string;
  workDir?: string | undefined;
}

export interface OutlineArgs {
  docId: string;
  depth?: number | undefined;
  within?: string | undefined;
  comp?: boolean | undefined;
  byBreaks?: boolean | undefined;
  windows?: number | undefined;
  workDir?: string | undefined;
}

export interface MarksArgs {
  docId: string;
  kind: string;
  minBytes?: number | undefined;
  workDir?: string | undefined;
}

export interface ReadArgs {
  docId: string;
  heading?: string | undefined;
  headings?: string[] | undefined;
  from?: string | undefined;
  to?: string | undefined;
  span?: ByteSpan | undefined;
  extent?: "unit" | "subtree" | undefined;
  depth?: number | undefined;
  strip?: StripSpec | undefined;
  stripMatch?: string | undefined;
  prefixFormat?: boolean | undefined;
  workDir?: string | undefined;
}

/** One span removed from a read, named and measured so it stays addressable. */
export interface Elision {
  kind: "data-uri" | "html" | "signed-url" | "image-ref" | "custom";
  bytes: number;
}

export interface ReadResult {
  docId: string;
  text: string;
  /** Per-span text, aligned with `spans`, so each chunk can carry its own header. */
  chunks: string[];
  bytes: number;
  elidedBytes: number;
  elisions: Elision[];
  spans: ByteSpan[];
  anchors: string[];
  /** Digest-drift notices. Reported, never fatal — the bytes are still there. */
  warnings: string[];
}

export interface BatchReadResult {
  docId: string;
  label?: string | undefined;
  anchor: string;
  span?: ByteSpan | undefined;
  text: string;
  bytes: number;
  elidedBytes: number;
  elisions: Elision[];
  warnings: string[];
}

export interface BatchReadArgs {
  requests: Array<{
    docId: string;
    heading?: string | undefined;
    headings?: string[] | undefined;
    from?: string | undefined;
    to?: string | undefined;
    span?: ByteSpan | undefined;
    label?: string | undefined;
  }>;
  depth?: number | undefined;
  strip?: StripSpec | undefined;
  prefixFormat?: boolean | undefined;
  workDir?: string | undefined;
}

export interface CoverageArgs {
  docIds?: string[] | undefined;
  depth?: number | undefined;
  byBreaks?: boolean | undefined;
  workDir?: string | undefined;
}

export interface LocateArgs {
  pattern: string;
  docIds?: string[] | undefined;
  caseInsensitive?: boolean | undefined;
  max?: number | undefined;
  workDir?: string | undefined;
}

// ────────────────────────────────────────────────────────── Zod Tool Schemas

export const DiscoverSchema = z.object({
  root: z.string().optional().describe("Mount a corpus root: index every Markdown file nested under it, address them by a group/document coordinate derived from the directory layout, and report paths relative to the root. Prefer this over 'paths' for a corpus."),
  paths: z.array(z.string()).optional().describe("Individual files or directories to index, when there is no single root"),
  glob: z.string().optional().default("*.md").describe("File glob pattern (default: *.md)"),
  recursive: z.boolean().optional().default(false).describe("Whether to crawl subdirectories recursively"),
  run: z.string().optional().describe("Attach to an existing run stamp instead of starting a new one ('latest' follows the LATEST pointer). Restores that run's read ledger, so coverage continues across a restart."),
  newRun: z.boolean().optional().default(false).describe("Start a separate run even if one is already open on this corpus. Off by default: re-discovering the same corpus continues the current run, so coverage is not fragmented."),
  workDir: z.string().optional().describe("Explicit runtime artifact directory"),
});

export const IndexSchema = z.object({
  docIds: z.array(z.string()).optional().describe("Documents to re-report (default: everything indexed)"),
  refresh: z.boolean().optional().default(false).describe("Force a re-scan even when size and mtime say the source has not moved"),
  workDir: z.string().optional().describe("Explicit work directory"),
});

export const ProfileSchema = z.object({
  docId: z.string().describe("Document reference (e.g. D001 or file path)"),
  workDir: z.string().optional().describe("Explicit work directory"),
});

export const OutlineSchema = z.object({
  docId: z.string().describe("Document reference (e.g. D001 or file path)"),
  depth: z.number().int().min(1).max(6).optional().default(1).describe("Active heading depth (1..6)"),
  within: z.string().optional().describe("Restrict outline to children under a specific heading (e.g. H0005)"),
  comp: z.boolean().optional().default(false).describe("Include construct composition tag (e.g. [quote84 prose12])"),
  byBreaks: z.boolean().optional().default(false).describe("Partition by thematic breaks (---) instead of headings"),
  windows: z.number().int().positive().optional().describe("Window size in bytes for unheaded fallback partition"),
  workDir: z.string().optional().describe("Explicit work directory"),
});

export const MarksSchema = z.object({
  docId: z.string().describe("Document reference (e.g. D001)"),
  kind: z.string().describe("Construct kind to enumerate: blockquote, fence, html, table, list, paragraph"),
  minBytes: z.number().int().nonnegative().optional().default(0).describe("Filter out runs shorter than minBytes"),
  workDir: z.string().optional().describe("Explicit work directory"),
});

export const ReadSchema = z.object({
  docId: z.string().describe("Document reference (e.g. D001)"),
  heading: z.string().optional().describe("Single heading ID to read (e.g. H0003)"),
  headings: z.array(z.string()).optional().describe("List of discontiguous heading IDs to batch read (e.g. ['H0003', 'H0019'])"),
  from: z.string().optional().describe("Start heading ID for contiguous span range"),
  to: z.string().optional().describe("End heading ID for contiguous span range"),
  span: z.tuple([z.number(), z.number()]).optional().describe("Exact byte span [start, end)"),
  extent: z.enum(["unit", "subtree"]).optional().default("unit").describe("Read unit cell or full subtree branch"),
  depth: z.number().int().min(1).max(6).optional().describe("Depth grain context for the unit read"),
  strip: z.union([z.enum(["all", "none"]), z.array(z.enum(["data-uri", "html", "signed-url", "image-ref"]))])
    .optional().default("none")
    .describe("Elide machine furniture: 'all', 'none', or the exact species, e.g. ['data-uri','signed-url']. Each removed span leaves a marker naming its kind and size."),
  stripMatch: z.string().optional().describe("Custom regex pattern to elide at read time"),
  prefixFormat: z.boolean().optional().default(true).describe("Frame each chunk with a provenance line — 'D023 : H0006 @ e5f6 | 8420 .. 9860 |' — and close it by repeating the address. On by default; pass false here, or set MDNAV_PREFIX=off for the session."),
  workDir: z.string().optional().describe("Explicit work directory"),
});

export const BatchReadSchema = z.object({
  requests: z.array(z.object({
    docId: z.string().describe("Document reference (e.g. D001)"),
    heading: z.string().optional().describe("Heading ID to read (e.g. H0003)"),
    headings: z.array(z.string()).optional().describe("Discontiguous heading IDs to read"),
    from: z.string().optional().describe("Start heading ID"),
    to: z.string().optional().describe("End heading ID"),
    span: z.tuple([z.number(), z.number()]).optional().describe("Byte span [start, end)"),
    label: z.string().optional().describe("Optional user label for the section"),
  })).describe("List of target sections to read across one or multiple documents"),
  depth: z.number().int().min(1).max(6).optional().default(2).describe("Default depth for unit extents"),
  strip: z.union([z.enum(["all", "none"]), z.array(z.enum(["data-uri", "html", "signed-url", "image-ref"]))])
    .optional().default("all")
    .describe("Elide machine furniture: 'all' (default), 'none', or the exact species, e.g. ['data-uri','signed-url']."),
  prefixFormat: z.boolean().optional().default(true).describe("Head each block with a token-isolated provenance line instead of an HTML comment tag. On by default; MDNAV_PREFIX=off disables it for the session."),
  workDir: z.string().optional().describe("Explicit work directory"),
});

export const CoverageSchema = z.object({
  docIds: z.array(z.string()).optional().describe("List of documents to check, or empty for entire indexed corpus"),
  depth: z.number().int().min(1).max(6).optional().default(1).describe("Depth grain for unread listing"),
  byBreaks: z.boolean().optional().default(false).describe("Compute coverage against thematic break basis"),
  workDir: z.string().optional().describe("Explicit work directory"),
});

export const LocateSchema = z.object({
  pattern: z.string().describe("Literal string or regex to search for in lines/headings"),
  docIds: z.array(z.string()).optional().describe("Documents to search within (default: all)"),
  caseInsensitive: z.boolean().optional().default(false).describe("Case insensitive match (-i)"),
  max: z.number().int().positive().optional().default(50).describe("Maximum matches to return"),
  workDir: z.string().optional().describe("Explicit work directory"),
});

export const AnchorInputSchema = z.object({
  scope: z.string().describe("Document id ('D014') or namespace ('code', 'url')"),
  unit: z.string().optional().describe("Chunk within the scope ('H0003', 'S0007', 'W0002'), or the item named by a non-corpus scope ('grassmann.py')"),
  digest: z.string().optional().describe("Four hex characters: the unit's content identity at the moment you cited it"),
});

export const AnchorArgSchema = z.union([AnchorInputSchema, z.string()]);

/**
 * The same components as a filter, where every one is optional and each names
 * exactly the edge it is: `{ unit: 'H0003' }` is a unit, `{ scope: 'D014' }` is
 * a scope. A bare STRING keeps its older reading — one component means the unit
 * — because that is what callers already pass.
 */
export const AnchorFilterSchema = z.object({
  scope: z.string().optional().describe("Pin the document or namespace"),
  unit: z.string().optional().describe("Pin the chunk within it"),
  digest: z.string().optional().describe("Pin one content version of that chunk"),
});

export const AnchorFilterArgSchema = z.union([AnchorFilterSchema, z.string()]);

export const JournalRecordSchema = z.object({
  op: z.enum(["propose", "refine", "supersede", "reject", "adopt", "retract", "note"])
    .describe("What this entry does to the record: propose | refine | supersede | reject | adopt | retract | note"),
  body: z.string().describe("The observation, hypothesis, or decision text"),
  concept: z.string().optional().describe("Concept or topic tag this entry belongs to (e.g. C-001)"),
  refs: z.array(z.string()).optional().describe("Causal parent entry IDs (e.g. ['N001']). Two or more express a merge."),
  anchors: z.array(AnchorArgSchema).optional().describe("Evidence anchors, each as components: { scope: 'D014', unit: 'H0003', digest: 'a1b2' }. A scope of Dnnn with a unit resolves and is digest-checked; any other scope (e.g. { scope: 'code', unit: 'file.py' }) is kept verbatim. A string is accepted too, spaced as the stream prints it or compact — same address either way."),
  workDir: z.string().optional().describe("Explicit work directory"),
});

export const JournalReadSchema = z.object({
  concept: z.string().optional().describe("Filter to one concept tag"),
  status: z.enum(["active", "refined", "superseded", "rejected", "adopted", "retracted"]).optional()
    .describe("Filter by derived status — 'active' lists entries nothing has superseded"),
  scope: z.string().optional().describe("Traverse by scope: every entry citing this document (or namespace, e.g. 'code')"),
  docId: z.string().optional().describe("The old name for 'scope'; still accepted"),
  anchor: AnchorFilterArgSchema.optional().describe("Traverse by unit: { unit: 'H0003' } matches every version cited, whatever the digest; add scope to pin the document and digest to pin one version"),
  digest: z.string().optional().describe("Traverse by content identity: every entry citing any chunk at this digest"),
  op: z.enum(["propose", "refine", "supersede", "reject", "adopt", "retract", "note"]).optional().describe("Filter by op"),
  limit: z.number().int().positive().optional().default(100).describe("Maximum entries to return (most recent kept)"),
  rawJson: z.boolean().optional().default(false).describe("Return raw JSON records instead of the formatted ledger"),
  workDir: z.string().optional().describe("Explicit work directory"),
});

export const JournalTreeSchema = z.object({
  concept: z.string().optional().describe("Restrict the lineage forest to one concept tag"),
  workDir: z.string().optional().describe("Explicit work directory"),
});

export const SkillsSchema = z.object({
  topic: z.string().optional().describe("Topic to read: 'index' for the doc-dive discipline itself, or a reference such as 'state-and-audit'. Omit to list what is available."),
  section: z.string().optional().describe("One section of that topic, by heading id ('H0004') or by a word in its title. The whole subtree comes with it."),
  outline: z.boolean().optional().describe("List the topic's headings with their byte sizes instead of reading it"),
  search: z.string().optional().describe("Case-insensitive pattern to find across the whole skill corpus; each hit reports the section holding it"),
  depth: z.number().int().positive().optional().describe("Heading depth for outline (default 6)"),
});

export interface SkillsArgs {
  topic?: string | undefined;
  section?: string | undefined;
  outline?: boolean | undefined;
  search?: string | undefined;
  depth?: number | undefined;
}
