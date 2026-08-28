/**
 * Deterministic prefix formatting for mdnav's machine-read output lines.
 *
 * ── The boundary rule ────────────────────────────────────────────────────────
 * Every structural mark is an item, isolated by exactly one space on both
 * sides, so it tokenizes the same way in every context it appears in. That
 * regularity is the criterion; token cost is a price, never a counter-argument.
 *
 * An anchor is decomposed, not fused. `D014:H0003@a1b2` is not one identifier —
 * it is a path: a document, a chunk within it, and that chunk's content
 * identity at the moment it was cited. Each component is an edge in the corpus
 * graph, so each must be separately addressable: "everything citing D014",
 * "every version of H0003 anyone cited", "which digests this chunk has had".
 * Fusing collapses the path to a leaf and the edges become unreachable.
 *
 * Fusing is also the LESS regular choice: the internal split of
 * `D014:H0003@a1b2` shifts with the width of its digits, so no interior
 * boundary is stable across anchors. Isolating each component makes every
 * component and every mark tokenize identically wherever they appear.
 *
 * Marks nest by rank: ` | ` separates fields, ` ; ` separates items in a field,
 * and ` : ` / ` @ ` / ` .. ` separate the components of a single item.
 */

import type { ByteSpan, JournalEntry, ResolvedJournalEntry } from "./types.ts";

/** Field separator. */
export const FIELD = " | ";
/** Item separator, within a field that carries a list. */
export const ITEM = " ; ";
/** Range mark, between the two components of a span. */
export const RANGE = " .. ";
/** Containment mark: a scope and the unit inside it. */
export const SCOPE = " : ";
/** Identity mark: a unit and its content digest at citation time. */
export const VERSION = " @ ";
/** Line-break substitution inside a body that must stay on one line. */
export const BREAK = "\\n";
/** Stands in for a field with no value, so column count never varies. */
export const EMPTY = "-";

/** Column header for the journal ledger view. */
export const JOURNAL_HEADER =
  ["id", "ts", "op", "refs", "concept", "status", "anchors", "bytes", "body"].join(FIELD);

/** Column header for prefix-formatted source chunks. */
export const CHUNK_HEADER = ["address", "span", "content"].join(FIELD);

/** Same, for the batch reader, which carries a caller-supplied label. */
export const BATCH_CHUNK_HEADER = ["address", "label", "span", "content"].join(FIELD);

/**
 * The metadata prefix framing one materialized source chunk.
 *
 *   `D023 : H0006 @ e5f6 | 8420 .. 9860 |`
 *   `## Method`                                        <- the content block
 *   `...`
 *   `| D023 : H0006 @ e5f6`                            <- formatChunkClose
 *
 * ` | ` separates FIELDS; the operators join the components WITHIN one field —
 * so the address is a single field, `D023 : H0006 @ e5f6`, not two columns.
 *
 * There is deliberately NO length field. A length prefix delimits for something
 * that reads N bytes, and nothing here does: the consumer is attention, which
 * cannot count. Extent is already legible from the span, and an elision is
 * already reported twice — by its inline marker and by the read's summary line.
 */
export function formatSourceChunkPrefix(
  docId: string,
  anchor: string,
  span: ByteSpan,
  label?: string | undefined
): string {
  const fields = [chunkAddress(docId, anchor)];
  if (label !== undefined) fields.push(label || EMPTY);
  fields.push(`${span[0]}${RANGE}${span[1]}`);
  return `${fields.join(FIELD)}${FIELD.trimEnd()}`;
}

function chunkAddress(docId: string, anchor: string): string {
  return formatAnchorString(anchor ? `${docId}:${anchor}` : docId);
}

/**
 * Closes a content block by repeating its address.
 *
 * The stream is appended to continuously and only moves forward, so a block
 * with no terminator has an undeclared end: further down there is nothing left
 * to say where the material stopped and the next frame began.
 *
 * Repeating the address rather than emitting a bare sigil does a second job.
 * The content is then BRACKETED by its own anchor, so every token inside has
 * that anchor both before and after it — and for a long block the opening
 * frame is thousands of tokens behind by the time the end arrives. The
 * redundancy is an attention argument, not a parsing one.
 */
export function formatChunkClose(docId: string, anchor: string): string {
  return `${FIELD.trimStart()}${chunkAddress(docId, anchor)}`;
}

/** A content block with its closing frame, on its own line and without padding it. */
export function closeChunk(content: string, docId: string, anchor: string): string {
  return `${content}${content.endsWith("\n") ? "" : "\n"}${formatChunkClose(docId, anchor)}`;
}

/**
 * The components of one anchor.
 *
 * `D014:H0003@a1b2` → scope `D014`, unit `H0003`, digest `a1b2`
 * `code:grassmann.py` → scope `code`, unit `grassmann.py`
 * `H0003` → scope `H0003` (no containing scope was named)
 *
 * The digest is only split off when the tail is actually digest-shaped, so a
 * `url:` anchor carrying an `@` keeps it as part of the unit.
 */
export interface ParsedAnchor {
  raw: string;
  scope: string;
  unit?: string | undefined;
  digest?: string | undefined;
}

export function parseAnchor(raw: string): ParsedAnchor {
  const s = raw.trim();
  const m = /^(.*)@([0-9a-fA-F]{4})$/.exec(s);
  const head = m ? m[1]! : s;
  const digest = m ? m[2]! : undefined;

  const colon = head.indexOf(":");
  return colon > 0
    ? { raw: s, scope: head.slice(0, colon), unit: head.slice(colon + 1), digest }
    : { raw: s, scope: head, digest };
}

/**
 * One anchor with every component isolated, so each is separately addressable.
 * `D014:H0003@a1b2` → `D014 : H0003 @ a1b2`
 * `code:grassmann.py` → `code : grassmann.py`
 */
export function formatAnchorString(anchor: string): string {
  const a = parseAnchor(anchor);
  let out = a.scope;
  if (a.unit !== undefined) out += `${SCOPE}${a.unit}`;
  if (a.digest !== undefined) out += `${VERSION}${a.digest}`;
  return out;
}

/**
 * Join anchors as isolated items, each itself decomposed.
 * `["D014:H0003@a1b2", "code:grassmann.py"]`
 *   → `D014 : H0003 @ a1b2 ; code : grassmann.py`
 */
export function formatAnchorList(anchors: string[]): string {
  return anchors.length > 0 ? anchors.map(formatAnchorString).join(ITEM) : EMPTY;
}

/**
 * Render an ISO-8601 UTC instant as the compact stamp used on the wire.
 * `2026-08-28T19:45:30.123Z` → `20260828_194530Z`
 *
 * Storage stays ISO so journal entries and read-ledger entries sort against
 * each other directly; only the display form is compacted.
 */
export function formatCompactStamp(iso: string): string {
  const m = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})/.exec(iso);
  if (!m) return iso;
  return `${m[1]}${m[2]}${m[3]}_${m[4]}${m[5]}${m[6]}Z`;
}

/**
 * Flatten a body onto one line. Each newline becomes one isolated break mark,
 * and runs are preserved so a blank line still reads as a paragraph boundary.
 *
 * Pipes inside the body are left alone: body is the terminal field, so a
 * left-to-right parser splitting on the leading separators cannot mistake one
 * for a field boundary.
 */
export function escapeBody(s: string): string {
  const parts = s.replace(/\r\n?/g, "\n").split("\n");
  const tokens: string[] = [];
  for (let i = 0; i < parts.length; i++) {
    if (i > 0) tokens.push(BREAK);
    const seg = parts[i]!.trim();
    if (seg !== "") tokens.push(seg);
  }
  return tokens.join(" ").trim();
}

/**
 * One journal entry as a single ledger line.
 *
 *   `N003 | 20260828_194530Z | adopt | N002 | C-001 | active | D023:H0006@e5f6 ; code:grassmann.py | 148 | <body>`
 */
export function formatJournalEntry(entry: ResolvedJournalEntry): string {
  return [
    entry.id,
    formatCompactStamp(entry.ts),
    entry.op,
    entry.refs.length > 0 ? entry.refs.join(ITEM) : EMPTY,
    entry.concept || EMPTY,
    entry.status,
    formatAnchorList(entry.anchors),
    String(entry.bytes),
    escapeBody(entry.body),
  ].join(FIELD);
}

/**
 * Lineage forest. Merges make this a DAG, not a tree: an entry reached by a
 * second parent is marked rather than re-expanded, so the render stays finite
 * and no branch is silently dropped.
 */
export function renderJournalTree(entries: ResolvedJournalEntry[]): string {
  const byId = new Map(entries.map((e) => [e.id, e]));
  const hasParent = new Set<string>();
  for (const e of entries) {
    for (const c of e.children) if (byId.has(c)) hasParent.add(c);
  }

  const lines: string[] = [];
  const seen = new Set<string>();

  const walk = (e: ResolvedJournalEntry, prefix: string, last: boolean, depth: number): void => {
    const branch = depth === 0 ? "" : `${prefix}${last ? "└─ " : "├─ "}`;
    const merge = e.refs.length > 1 ? `  (merge of ${e.refs.join(", ")})` : "";
    const repeat = seen.has(e.id) ? "  ↩ shown above" : "";
    lines.push(`${branch}${[e.id, e.op, e.concept || EMPTY, e.status].join(FIELD)}${merge}${repeat}`);
    if (repeat) return;

    seen.add(e.id);
    const kids = e.children
      .map((c) => byId.get(c))
      .filter((x): x is ResolvedJournalEntry => x !== undefined);
    const childPrefix = depth === 0 ? "" : `${prefix}${last ? "   " : "│  "}`;
    kids.forEach((k, i) => walk(k, childPrefix, i === kids.length - 1, depth + 1));
  };

  const roots = entries.filter((e) => !hasParent.has(e.id));
  roots.forEach((r, i) => walk(r, "", i === roots.length - 1, 0));
  return lines.join("\n");
}

/**
 * Write receipt for a recorded entry. Carries the minted id, what it cost, and
 * where it attached — and never echoes the body, which the caller just wrote
 * and would otherwise pay for twice.
 */
export function formatJournalReceipt(entry: JournalEntry): string {
  const parts = [
    `${entry.id} (+${entry.bytes} B)`,
    entry.op,
    entry.refs.length > 0 ? entry.refs.join(ITEM) : EMPTY,
    entry.concept || EMPTY,
    formatAnchorList(entry.anchors),
  ];
  return `recorded${FIELD}${parts.join(FIELD)}`;
}
