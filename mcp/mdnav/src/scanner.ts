/**
 * Fast byte-level Markdown scanner and noise analyzer.
 */

import { createHash } from "node:crypto";
import type { HeadingEntry, BreakEntry, NoiseEntry, DocumentIndex, ProfileRow, ConstructRun } from "./types.ts";

const LF = 10, CR = 13;

export const sha256 = (b: Buffer): string => createHash("sha256").update(b).digest("hex");
export const digestOf = (s: string): string => sha256(Buffer.from(s, "utf8")).slice(0, 4);

export interface ScanOptions {
  id: string;
  path: string;
  mtimeMs?: number;
}

export function scanDocument(buf: Buffer, options: ScanOptions): DocumentIndex {
  const { id, path, mtimeMs = Date.now() } = options;
  const len = buf.length;
  const hash = sha256(buf);

  // Check BOM
  let offset = 0;
  let bom = false;
  if (len >= 3 && buf[0] === 0xEF && buf[1] === 0xBB && buf[2] === 0xBF) {
    bom = true;
    offset = 3;
  }

  // Detect newline convention
  let crCount = 0, lfCount = 0;
  for (let i = offset; i < Math.min(len, 8192); i++) {
    if (buf[i] === CR) crCount++;
    if (buf[i] === LF) lfCount++;
  }
  const newline = crCount > 0 && crCount === lfCount ? "crlf" : crCount > 0 ? "mixed" : "lf";

  // Check frontmatter
  let frontmatter: { start: number; end: number } | undefined;
  if (offset + 3 <= len && buf.subarray(offset, offset + 3).toString("utf8") === "---") {
    let e = offset + 3;
    while (e < len && buf[e] !== LF) e++;
    if (e < len && buf[e] === LF) {
      let cur = e + 1;
      while (cur < len) {
        if (cur + 3 <= len && buf.subarray(cur, cur + 3).toString("utf8") === "---") {
          let lineEnd = cur + 3;
          while (lineEnd < len && buf[lineEnd] !== LF) lineEnd++;
          frontmatter = { start: offset, end: lineEnd < len ? lineEnd + 1 : len };
          break;
        }
        while (cur < len && buf[cur] !== LF) cur++;
        if (cur < len) cur++;
      }
    }
  }

  const headings: HeadingEntry[] = [];
  const breaks: BreakEntry[] = [];
  const setextSuspects: number[] = [];
  let maxLine = 0;
  let lineNum = 1;
  let lineStart = offset;

  let inFence = false;
  let fenceChar = 0;
  let fenceLen = 0;

  let prevLineText = "";

  while (lineStart < len) {
    let lineEnd = lineStart;
    while (lineEnd < len && buf[lineEnd] !== LF) lineEnd++;
    let textEnd = lineEnd;
    if (textEnd > lineStart && buf[textEnd - 1] === CR) textEnd--;

    const lineBytes = lineEnd - lineStart;
    if (lineBytes > maxLine) maxLine = lineBytes;

    const rawLine = buf.subarray(lineStart, textEnd).toString("utf8");
    const trimmed = rawLine.trimStart();

    // Check code fences
    if ((trimmed.startsWith("```") || trimmed.startsWith("~~~"))) {
      const char = trimmed.charCodeAt(0);
      let count = 0;
      while (count < trimmed.length && trimmed.charCodeAt(count) === char) count++;
      if (!inFence) {
        inFence = true;
        fenceChar = char;
        fenceLen = count;
      } else if (char === fenceChar && count >= fenceLen) {
        inFence = false;
        fenceChar = 0;
        fenceLen = 0;
      }
    }

    if (!inFence) {
      // Check ATX Heading
      if (trimmed.startsWith("#")) {
        let level = 0;
        while (level < trimmed.length && trimmed.charCodeAt(level) === 35) level++;
        if (level >= 1 && level <= 6 && (trimmed.charCodeAt(level) === 32 || trimmed.charCodeAt(level) === 9)) {
          const title = trimmed.slice(level).trim();
          const digest = digestOf(title);
          const hid = `H${String(headings.length + 1).padStart(4, "0")}`;
          const bodyStart = lineEnd < len ? lineEnd + 1 : len;
          headings.push({
            hid,
            level,
            title,
            digest,
            line: lineNum,
            headingStart: lineStart,
            bodyStart,
            subtreeEnd: len,
          });
        }
      }

      // Check Thematic Break
      if (/^(\s*[-*_]\s*){3,}$/.test(rawLine)) {
        const sid = `S${String(breaks.length + 1).padStart(4, "0")}`;
        breaks.push({
          sid,
          line: lineNum,
          start: lineStart,
          end: lineEnd < len ? lineEnd + 1 : len,
          label: prevLineText.trim() || rawLine.trim(),
        });
      }

      // Check Setext Suspects
      if (/^(=+|-+)\s*$/.test(rawLine) && prevLineText.trim().length > 0 && !rawLine.startsWith("#")) {
        setextSuspects.push(lineNum);
      }
    }

    prevLineText = rawLine;
    lineNum++;
    lineStart = lineEnd < len ? lineEnd + 1 : len;
  }

  // Compute subtree bounds
  for (let i = 0; i < headings.length; i++) {
    const cur = headings[i]!;
    let nextSameOrHigher = len;
    for (let j = i + 1; j < headings.length; j++) {
      if (headings[j]!.level <= cur.level) {
        nextSameOrHigher = headings[j]!.headingStart;
        break;
      }
    }
    cur.subtreeEnd = nextSameOrHigher;
  }

  // Count distribution
  const counts = [0, 0, 0, 0, 0, 0];
  for (const h of headings) {
    const idx = h.level - 1;
    counts[idx] = (counts[idx] ?? 0) + 1;
  }

  // Compute spine
  let spineBytes = 0;
  for (const h of headings) {
    if (h.level === 1) {
      spineBytes += (h.bodyStart - h.headingStart);
    }
  }
  const spineRatio = len > 0 ? spineBytes / len : 0;

  // Scan Noise
  const noise = scanNoise(buf);

  return {
    schema: 2,
    id,
    path,
    bytes: len,
    sha256: hash,
    mtimeMs,
    encoding: "utf-8",
    bom,
    newline,
    headings,
    counts,
    spine: { bytes: spineBytes, ratio: spineRatio },
    breaks,
    maxLine,
    noise,
    setextSuspects: setextSuspects.length > 0 ? setextSuspects : undefined,
    frontmatter,
  };
}

function scanNoise(buf: Buffer): NoiseEntry[] {
  const text = buf.toString("utf8");
  const entries: NoiseEntry[] = [];

  // Data URIs
  const dataUriRe = /!\[.*?\]\((data:[^;]+;base64,[A-Za-z0-9+/=]+)\)/g;
  let m: RegExpExecArray | null;
  while ((m = dataUriRe.exec(text)) !== null) {
    const start = Buffer.byteLength(text.slice(0, m.index));
    const bytes = Buffer.byteLength(m[0]);
    entries.push({ kind: "data-uri", start, end: start + bytes, bytes });
  }

  // Presigned URLs
  const signedUrlRe = /(!?\[([^\]]*)\])\((https?:\/\/[^)]*(?:X-Amz-Signature|X-Amz-Credential|X-Goog-Signature|sig=)[^)]*)\)/g;
  while ((m = signedUrlRe.exec(text)) !== null) {
    const isImage = m[0].startsWith("!");
    const start = Buffer.byteLength(text.slice(0, m.index));
    const bytes = Buffer.byteLength(m[0]);
    const label = m[2] || "";
    entries.push({
      kind: "signed-url",
      start,
      end: start + bytes,
      bytes,
      replacement: isImage ? "" : label ? `[${label}]` : undefined,
    });
  }

  // External Image References
  const imgRefRe = /!\[([^\]]*)\]\((https?:\/\/[^)]+)\)/g;
  while ((m = imgRefRe.exec(text)) !== null) {
    if (m[2] && !/X-Amz-|X-Goog-|sig=/.test(m[2])) {
      const start = Buffer.byteLength(text.slice(0, m.index));
      const bytes = Buffer.byteLength(m[0]);
      entries.push({ kind: "image-ref", start, end: start + bytes, bytes });
    }
  }

  // HTML Tags (non-code)
  const htmlRe = /<([a-zA-Z/][^>]*|!--[\s\S]*?--)>/g;
  while ((m = htmlRe.exec(text)) !== null) {
    const start = Buffer.byteLength(text.slice(0, m.index));
    const bytes = Buffer.byteLength(m[0]);
    entries.push({ kind: "html", start, end: start + bytes, bytes });
  }

  return entries.sort((a, b) => a.start - b.start);
}

// ────────────────────────────────────────────────────────── Noise Stripping

export function stripNoise(
  text: string,
  options: { strip?: "all" | "none" | undefined; stripMatch?: string | undefined } = {}
): { text: string; elidedBytes: number } {
  const { strip = "none", stripMatch } = options;
  if (strip === "none" && !stripMatch) return { text, elidedBytes: 0 };

  const initialBytes = Buffer.byteLength(text);
  let out = text;

  if (strip === "all") {
    // 1. Data URIs
    out = out.replace(/!\[(.*?)\]\(data:[^;]+;base64,[A-Za-z0-9+/=]+\)/g, (_, alt) => {
      return alt ? `<!-- mdnav: elided data-uri [${alt}] -->` : `<!-- mdnav: elided data-uri -->`;
    });

    // 2. Presigned URLs
    out = out.replace(/!\[(.*?)\]\((https?:\/\/[^)]*(?:X-Amz-Signature|X-Amz-Credential|X-Goog-Signature|sig=)[^)]*)\)/g, "");
    out = out.replace(/\[(.*?)\]\((https?:\/\/[^)]*(?:X-Amz-Signature|X-Amz-Credential|X-Goog-Signature|sig=)[^)]*)\)/g, "$1");

    // 3. HTML tags (preserve inner text)
    out = out.replace(/<div\b[^>]*>([\s\S]*?)<\/div>/gi, "$1");
    out = out.replace(/<span\b[^>]*>([\s\S]*?)<\/span>/gi, "$1");
    out = out.replace(/<!--[\s\S]*?-->/g, "");
  }

  if (stripMatch) {
    try {
      const re = new RegExp(stripMatch, "g");
      out = out.replace(re, "<!-- mdnav: elided pattern match -->");
    } catch {
      // Invalid pattern ignored
    }
  }

  const finalBytes = Buffer.byteLength(out);
  const elidedBytes = Math.max(0, initialBytes - finalBytes);
  return { text: out, elidedBytes };
}

// ────────────────────────────────────────────────────────── Profile & Cadence

export function profileDocument(buf: Buffer): ProfileRow[] {
  const text = buf.toString("utf8");
  const totalBytes = buf.length;
  if (totalBytes === 0) return [];

  const constructs: Array<{ name: string; regex: RegExp; extractDetail?: (m: RegExpExecArray) => string }> = [
    { name: "heading h1", regex: /^#\s+.+$/gm },
    { name: "heading h2", regex: /^##\s+.+$/gm },
    { name: "heading h3", regex: /^###\s+.+$/gm },
    { name: "blockquote", regex: /^(?:>[ \t]*.*(?:\r?\n|$))+/gm },
    { name: "fence", regex: /^```([a-zA-Z0-9_-]*)\r?\n[\s\S]*?^```/gm, extractDetail: (m) => m[1] || "plain" },
    { name: "list", regex: /^(?:[ \t]*(?:[-*+]|\d+\.)[ \t]+.*(?:\r?\n|$))+/gm },
    { name: "table", regex: /^(?:\|.+?\|\r?\n)+/gm },
    { name: "html", regex: /<[a-zA-Z/][^>]*>|<!--[\s\S]*?-->/gm },
    { name: "paragraph", regex: /^(?:[^\r\n#>|`\-\*\+ \t].*(?:\r?\n|$))+/gm },
  ];

  const results: ProfileRow[] = [];

  for (const c of constructs) {
    const matches: Array<{ start: number; end: number; detail?: string | undefined }> = [];
    let m: RegExpExecArray | null;
    const detailsMap = new Map<string, number>();

    while ((m = c.regex.exec(text)) !== null) {
      const start = Buffer.byteLength(text.slice(0, m.index));
      const bytes = Buffer.byteLength(m[0]);
      const detail = c.extractDetail ? c.extractDetail(m) : undefined;
      if (detail) {
        detailsMap.set(detail, (detailsMap.get(detail) || 0) + 1);
      }
      matches.push({ start, end: start + bytes, detail });
    }

    if (matches.length === 0) continue;

    let constructBytes = 0;
    const gaps: number[] = [];
    for (let i = 0; i < matches.length; i++) {
      const cur = matches[i]!;
      constructBytes += (cur.end - cur.start);
      if (i > 0) {
        gaps.push(cur.start - matches[i - 1]!.end);
      }
    }

    // Compute median gap and cv
    let medianGap: number | null = null;
    let cv: number | null = null;
    if (gaps.length > 0) {
      gaps.sort((a, b) => a - b);
      medianGap = gaps[Math.floor(gaps.length / 2)]!;

      const mean = gaps.reduce((acc, g) => acc + g, 0) / gaps.length;
      const variance = gaps.reduce((acc, g) => acc + Math.pow(g - mean, 2), 0) / gaps.length;
      const stdDev = Math.sqrt(variance);
      cv = mean > 0 ? Number((stdDev / mean).toFixed(2)) : 0;
    }

    let detailStr: string | undefined;
    if (detailsMap.size > 0) {
      detailStr = Array.from(detailsMap.entries())
        .sort((a, b) => b[1] - a[1])
        .slice(0, 3)
        .map(([k, v]) => `${k}×${v}`)
        .join(" ");
    }

    results.push({
      construct: c.name,
      runs: matches.length,
      bytes: constructBytes,
      percent: Number(((constructBytes / totalBytes) * 100).toFixed(1)),
      medianGap,
      cv,
      detail: detailStr,
    });
  }

  return results.sort((a, b) => b.bytes - a.bytes);
}

// ────────────────────────────────────────────────────────── Marks Enumeration

export function extractMarks(buf: Buffer, kind: string, minBytes = 0): ConstructRun[] {
  const text = buf.toString("utf8");
  let regex: RegExp;

  switch (kind.toLowerCase()) {
    case "blockquote":
      regex = /^(?:>[ \t]*.*(?:\r?\n|$))+/gm;
      break;
    case "fence":
      regex = /^```[a-zA-Z0-9_-]*\r?\n[\s\S]*?^```/gm;
      break;
    case "html":
      regex = /<[a-zA-Z/][^>]*>|<!--[\s\S]*?-->/gm;
      break;
    case "table":
      regex = /^(?:\|.+?\|\r?\n)+/gm;
      break;
    case "list":
      regex = /^(?:[ \t]*(?:[-*+]|\d+\.)[ \t]+.*(?:\r?\n|$))+/gm;
      break;
    default:
      regex = new RegExp(kind, "gm");
  }

  const runs: ConstructRun[] = [];
  let m: RegExpExecArray | null;

  while ((m = regex.exec(text)) !== null) {
    const raw = m[0];
    const start = Buffer.byteLength(text.slice(0, m.index));
    const bytes = Buffer.byteLength(raw);
    if (bytes < minBytes) continue;

    const lines = raw.split(/\r?\n/).filter(Boolean).length;
    const preview = raw.slice(0, 80).replace(/\r?\n/g, " ").trim();

    runs.push({
      start,
      end: start + bytes,
      bytes,
      lines,
      preview: preview.length === 80 ? `${preview}…` : preview,
    });
  }

  return runs;
}
