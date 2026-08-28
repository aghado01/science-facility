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
  start: number;
  end: number;
  bytes: number;
  unbroken?: boolean | undefined;
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

export interface InventoryDoc {
  id: string;
  path: string;
  name: string;
  bytes?: number | undefined;
  grain?: string | undefined;
  spineRatio?: number | undefined;
  notes?: string | undefined;
}

export interface Inventory {
  schema: number;
  stamp: string;
  workDir: string;
  docs: InventoryDoc[];
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
}

// ────────────────────────────────────────────────────────── Tool Arguments

export interface DiscoverArgs {
  paths: string[];
  glob?: string | undefined;
  recursive?: boolean | undefined;
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
  strip?: "all" | "none" | undefined;
  stripMatch?: string | undefined;
  workDir?: string | undefined;
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
  strip?: "all" | "none" | undefined;
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
  paths: z.array(z.string()).describe("Files or directories to index"),
  glob: z.string().optional().default("*.md").describe("File glob pattern (default: *.md)"),
  recursive: z.boolean().optional().default(false).describe("Whether to crawl subdirectories recursively"),
  workDir: z.string().optional().describe("Explicit runtime artifact directory"),
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
  strip: z.enum(["all", "none"]).optional().default("none").describe("Strip heavy binary noise (base64 PNGs, presigned URLs)"),
  stripMatch: z.string().optional().describe("Custom regex pattern to elide at read time"),
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
  strip: z.enum(["all", "none"]).optional().default("all").describe("Strip heavy binary noise (default: all)"),
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
