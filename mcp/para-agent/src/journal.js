/**
 * Console journal — producer and reader for the v1 contract in
 * contract/CONSOLE-CONTRACT.md.
 *
 * The organising rule: the journal holds *descriptions* of what happened and
 * bodies live beside it in separate files. Scanning two hundred turns should
 * cost less than reading one of them, and that is only true if the thing you
 * scan does not contain the bodies.
 *
 * The second rule: every read returns a receipt, unconditionally. Making it
 * unconditional is what lets a consumer treat its absence as a defect rather
 * than as "nothing was withheld".
 */

import { createHash } from "node:crypto";
import fs from "node:fs/promises";
import { existsSync } from "node:fs";
import path from "node:path";

const SCHEMA_VERSION = 1;
const DEFAULT_INLINE_LIMIT = 2048;
const PREVIEW_CHARS = 200;

const sha8 = (s) => createHash("sha256").update(s, "utf8").digest("hex").slice(0, 8);
const pad6 = (n) => String(n).padStart(6, "0");

/**
 * Split a body into lines.
 *
 * A body ending in a newline has N lines, not N+1 — the terminator belongs to
 * the last line rather than introducing an empty one after it. Getting this
 * wrong inflates every line count and every offset by one.
 */
const splitLines = (s) => (s === "" ? [] : s.replace(/\r?\n$/, "").split(/\r?\n/));

export class Journal {
  constructor({ root, stream, inlineLimit = DEFAULT_INLINE_LIMIT }) {
    this.root = root;
    this.stream = stream;
    this.inlineLimit = inlineLimit;
    this.dir = path.join(root, "streams", stream);
    this.journalPath = path.join(this.dir, "journal.jsonl");
    this.turnsDir = path.join(this.dir, "turns");
    this._seq = 0;
    this._turn = 0;
    this._ready = false;
  }

  async init() {
    if (this._ready) return this;
    await fs.mkdir(this.turnsDir, { recursive: true });
    // Recover counters from the tail rather than storing them separately —
    // one source of truth, and a half-written sidecar cannot desync them.
    if (existsSync(this.journalPath)) {
      const records = await this._readAll();
      for (const r of records) {
        if (r.seq > this._seq) this._seq = r.seq;
        if (r.turn > this._turn) this._turn = r.turn;
      }
    }
    this._ready = true;
    return this;
  }

  /** Canonical path for one of a turn's sidecar files. */
  turnPath(turn, ext) {
    return path.join(this.turnsDir, `${pad6(turn)}.${ext}`);
  }

  // ---- writing -------------------------------------------------------------

  async _append(record) {
    const full = {
      v: SCHEMA_VERSION,
      seq: ++this._seq,
      ts: new Date().toISOString(),
      stream: this.stream,
      ...record,
    };
    await fs.appendFile(this.journalPath, JSON.stringify(full) + "\n", "utf8");
    return full;
  }

  /** Open a turn. Returns its ids and the paths its producer should write. */
  async openTurn({ cmd, cwd, shell, origin = "run" }) {
    await this.init();
    const turn = ++this._turn;
    const record = await this._append({
      turn,
      kind: "turn",
      cmd,
      cwd: cwd ?? null,
      shell: shell ?? null,
      cmd_hash: sha8(cmd),
      origin,
    });
    return {
      turn,
      seq: record.seq,
      outPath: this.turnPath(turn, "out"),
      donePath: this.turnPath(turn, "done"),
      cancelPath: this.turnPath(turn, "cancel"),
    };
  }

  /** Record a turn's output, inlining it only if it is small. */
  async recordOutput({ turn, bodyPath }) {
    let body = "";
    if (bodyPath && existsSync(bodyPath)) body = await fs.readFile(bodyPath, "utf8");

    const bytes = Buffer.byteLength(body, "utf8");
    const lines = splitLines(body).length;
    const base = { turn, kind: "out", bytes, lines, out_hash: sha8(body), truncatedInline: false };

    if (bytes <= this.inlineLimit) {
      return this._append({ ...base, text: body });
    }
    return this._append({
      ...base,
      ref: path.relative(this.dir, bodyPath).replace(/\\/g, "/"),
      preview: body.slice(0, PREVIEW_CHARS),
    });
  }

  async recordExit({ turn, code, ok, duration_ms, outcome }) {
    return this._append({
      turn,
      kind: "exit",
      code: code ?? null, // never coerced to 0 — see contract
      ok: Boolean(ok),
      duration_ms,
      outcome,
    });
  }

  async note(note, data) {
    await this.init();
    return this._append({ turn: this._turn, kind: "note", note, ...(data ? { data } : {}) });
  }

  /**
   * Drain envelopes written by the interactive producer into the journal.
   *
   * The shell hook cannot assign `seq` — it has no way to coordinate with this
   * process — so it appends unsequenced envelopes to an inbox and we do the
   * sequencing here. That keeps the journal single-writer, which is what makes
   * gap-free `seq` (and therefore integer cursors) possible at all.
   *
   * The inbox is renamed before reading rather than read-then-truncated, so an
   * append landing mid-drain goes to the new inbox instead of being discarded.
   */
  async ingestInbox() {
    await this.init();
    const inbox = path.join(this.dir, "inbox.jsonl");
    if (!existsSync(inbox)) return [];

    const claimed = path.join(this.dir, `inbox.${Date.now()}.claim`);
    try {
      await fs.rename(inbox, claimed);
    } catch {
      return []; // another drain won the race
    }

    const raw = await fs.readFile(claimed, "utf8").catch(() => "");
    const ingested = [];

    for (const line of raw.split("\n")) {
      if (!line.trim()) continue;
      let env;
      try {
        env = JSON.parse(line);
      } catch {
        await this.note("unparseable inbox line", { raw: line.slice(0, 200) });
        continue;
      }

      if (env.kind === "note") {
        await this._append({
          turn: this._turn, kind: "note", note: env.note,
          ...(env.data ? { data: env.data } : {}),
        });
        continue;
      }
      if (env.kind !== "turn") continue;

      const turn = ++this._turn;
      await this._append({
        turn, kind: "turn",
        cmd: env.cmd ?? "",
        cwd: env.cwd ?? null,
        shell: env.shell ?? null,
        cmd_hash: sha8(env.cmd ?? ""),
        origin: env.origin ?? "interactive",
      });

      const body = await this._sliceTranscript(env.transcript, env.cmd);
      const outPath = this.turnPath(turn, "out");
      await fs.writeFile(outPath, body, "utf8");
      await this.recordOutput({ turn, bodyPath: outPath });
      await this.recordExit({
        turn,
        code: env.code ?? null,
        ok: env.ok ?? false,
        duration_ms: env.duration_ms ?? null,
        outcome: "completed",
      });
      ingested.push({ turn, cmd: env.cmd, bytes: Buffer.byteLength(body, "utf8") });
    }

    await fs.rm(claimed, { force: true }).catch(() => {});
    return ingested;
  }

  /** Read a byte range out of the shell transcript, minus the echoed prompt. */
  async _sliceTranscript(spec, cmd) {
    if (!spec?.file) return "";
    const p = path.join(this.dir, spec.file);
    const { start, end } = spec;
    if (!existsSync(p) || !Number.isFinite(start) || !Number.isFinite(end) || end <= start) return "";

    const handle = await fs.open(p, "r").catch(() => null);
    if (!handle) return "";
    try {
      const buf = Buffer.alloc(end - start);
      await handle.read(buf, 0, end - start, start);
      let text = buf.toString("utf8");

      // Transcription records what the host *displayed*, so a slice opens with
      // the previous command's trailing prompt and then this command's echo,
      // e.g.
      //     PS D:\work>
      //     PS>Write-Output 'x'
      //     x
      // Everything up to and including the echo is preamble. Anchoring on the
      // command text rather than dropping a fixed number of lines means a
      // command whose echo is absent keeps all of its output instead of losing
      // the first line or two of it.
      if (cmd) {
        const probe = cmd.split("\n")[0].slice(0, 40);
        const lines = text.split("\n");
        const echoAt = probe ? lines.findIndex((l) => l.includes(probe)) : -1;
        if (echoAt !== -1) text = lines.slice(echoAt + 1).join("\n");
      }
      return text.replace(/^(\r?\n)+/, "");
    } finally {
      await handle.close();
    }
  }

  // ---- reading -------------------------------------------------------------

  async _readAll() {
    if (!existsSync(this.journalPath)) return [];
    const raw = await fs.readFile(this.journalPath, "utf8");
    const out = [];
    for (const line of raw.split("\n")) {
      if (!line.trim()) continue;
      try {
        out.push(JSON.parse(line));
      } catch {
        // A corrupt line is data loss the reader must be able to see.
        out.push({ v: 0, seq: -1, kind: "note", note: "unparseable journal line", raw: line.slice(0, 200) });
      }
    }
    return out;
  }

  /**
   * Read journal records from a cursor.
   *
   * Returns descriptions, not bodies — a body over `inlineLimit` appears as a
   * ref plus a preview, and the receipt says how many bodies were left behind
   * and how to fetch them.
   */
  async read({ from = 0, limit = 50, kinds, turn, match, matchFlags = "i" } = {}) {
    await this.init();
    const all = await this._readAll();
    const scanned = all.length;

    let matched = all.filter((r) => r.seq >= from);
    if (kinds?.length) matched = matched.filter((r) => kinds.includes(r.kind));
    if (turn != null) matched = matched.filter((r) => r.turn === turn);
    if (match) {
      const re = new RegExp(match, matchFlags);
      matched = matched.filter((r) => re.test(r.cmd ?? "") || re.test(r.text ?? "") || re.test(r.preview ?? "") || re.test(r.note ?? ""));
    }

    const returned = matched.slice(0, limit);
    const withheldCount = matched.length - returned.length;
    const lastSeq = returned.length ? returned[returned.length - 1].seq : from;
    const next = matched.length ? (returned.length ? lastSeq + 1 : from) : this._seq + 1;

    // A deferred body is NOT an omission: the record is returned whole, with a
    // ref and a preview. Conflating the two would make `complete` false for
    // almost every read containing large output, and a flag that is nearly
    // always false stops being worth checking. Query completeness and body
    // deferral are separate facts, so they get separate fields — both always
    // reported.
    const deferred = returned
      .filter((r) => r.kind === "out" && r.ref)
      .map((r) => ({ turn: r.turn, bytes: r.bytes, lines: r.lines, retrieve: `body(turn: ${r.turn})` }));

    const withheld = [];
    if (withheldCount > 0) {
      withheld.push({
        reason: "limit",
        count: withheldCount,
        retrieve: `read(from: ${next})`,
      });
    }

    return {
      receipt: {
        op: "read",
        stream: this.stream,
        cursor: { from, to: lastSeq, next },
        counts: { scanned, matched: matched.length, returned: returned.length, withheld: withheldCount },
        bytes: { returned: returned.reduce((n, r) => n + Buffer.byteLength(JSON.stringify(r)), 0) },
        complete: withheld.length === 0,
        withheld,
        deferredBodies: deferred,
      },
      records: returned,
    };
  }

  /**
   * Fetch one turn's output body, selectively.
   *
   * `lines` slices, `grep` filters to matching lines with optional context.
   * Either way the receipt reports exactly how many lines were left out, so a
   * partial body can never be mistaken for the whole one.
   */
  async body(turn, { offsetLines = 0, limitLines = 200, grep, grepFlags = "i", context = 0 } = {}) {
    await this.init();
    const all = await this._readAll();
    const outRec = all.find((r) => r.turn === turn && r.kind === "out");
    if (!outRec) {
      return {
        receipt: {
          op: "body", stream: this.stream, turn,
          counts: { scanned: all.length, matched: 0, returned: 0, withheld: 0 },
          complete: true, withheld: [],
          note: `No output record for turn ${turn}. It may still be running, or produced nothing.`,
        },
        text: "",
      };
    }

    let body = outRec.text;
    if (body == null && outRec.ref) {
      const p = path.join(this.dir, outRec.ref);
      body = existsSync(p) ? await fs.readFile(p, "utf8") : "";
    }
    body ??= "";

    const allLines = splitLines(body);
    let selected;
    let selectionNote;

    if (grep) {
      const re = new RegExp(grep, grepFlags);
      const keep = new Set();
      allLines.forEach((l, i) => {
        if (re.test(l)) {
          for (let j = Math.max(0, i - context); j <= Math.min(allLines.length - 1, i + context); j++) keep.add(j);
        }
      });
      selected = [...keep].sort((a, b) => a - b).map((i) => ({ n: i + 1, text: allLines[i] }));
      selectionNote = `grep /${grep}/${grepFlags}${context ? ` ±${context}` : ""}`;
    } else {
      selected = allLines.map((text, i) => ({ n: i + 1, text })).slice(offsetLines);
    }

    const page = selected.slice(0, limitLines);
    const withheldLines = selected.length - page.length;
    const filteredOut = grep ? allLines.length - selected.length : Math.max(0, allLines.length - offsetLines - page.length - 0);

    const withheld = [];
    if (withheldLines > 0) {
      withheld.push({
        reason: "line limit",
        count: withheldLines,
        retrieve: grep
          ? `body(turn: ${turn}, grep: ${JSON.stringify(grep)}, offsetLines: ${offsetLines + limitLines})`
          : `body(turn: ${turn}, offsetLines: ${offsetLines + page.length})`,
      });
    }
    if (grep && filteredOut > 0) {
      withheld.push({
        reason: "did not match grep",
        count: filteredOut,
        retrieve: `body(turn: ${turn}) without grep`,
      });
    }
    if (!grep && offsetLines > 0) {
      withheld.push({ reason: "before offset", count: offsetLines, retrieve: `body(turn: ${turn}, offsetLines: 0)` });
    }

    return {
      receipt: {
        op: "body", stream: this.stream, turn,
        selection: selectionNote ?? `lines ${offsetLines + 1}-${offsetLines + page.length}`,
        counts: { totalLines: allLines.length, matched: selected.length, returned: page.length, withheld: withheldLines + (grep ? filteredOut : offsetLines) },
        bytes: { total: outRec.bytes, returned: Buffer.byteLength(page.map((l) => l.text).join("\n"), "utf8") },
        out_hash: outRec.out_hash,
        complete: withheld.length === 0,
        withheld,
      },
      lines: page,
      text: page.map((l) => l.text).join("\n"),
    };
  }

  /** Search across turn bodies. Returns hits, never whole bodies. */
  async search({ pattern, flags = "i", from = 0, maxHits = 50, maxPerTurn = 5, context = 0 } = {}) {
    await this.init();
    const all = await this._readAll();
    const re = new RegExp(pattern, flags);
    const outs = all.filter((r) => r.kind === "out" && r.seq >= from);

    const hits = [];
    let turnsScanned = 0;
    let turnsWithHits = 0;
    let suppressed = 0;

    for (const rec of outs) {
      turnsScanned++;
      let body = rec.text;
      if (body == null && rec.ref) {
        const p = path.join(this.dir, rec.ref);
        body = existsSync(p) ? await fs.readFile(p, "utf8") : "";
      }
      if (!body) continue;

      const lines = body.split(/\r?\n/);
      const local = [];
      lines.forEach((l, i) => {
        if (re.test(l)) {
          local.push({
            turn: rec.turn,
            line: i + 1,
            text: l,
            ...(context
              ? { context: lines.slice(Math.max(0, i - context), Math.min(lines.length, i + context + 1)) }
              : {}),
          });
        }
      });
      if (!local.length) continue;
      turnsWithHits++;
      if (local.length > maxPerTurn) suppressed += local.length - maxPerTurn;
      hits.push(...local.slice(0, maxPerTurn));
    }

    const returned = hits.slice(0, maxHits);
    const overflow = hits.length - returned.length;
    const withheld = [];
    if (suppressed > 0) {
      withheld.push({ reason: "per-turn cap", count: suppressed, retrieve: `body(turn: <n>, grep: ${JSON.stringify(pattern)})` });
    }
    if (overflow > 0) {
      withheld.push({ reason: "hit cap", count: overflow, retrieve: `search(pattern, maxHits: ${maxHits + overflow})` });
    }

    return {
      receipt: {
        op: "search", stream: this.stream, pattern, flags,
        counts: { turnsScanned, turnsWithHits, matched: hits.length + suppressed, returned: returned.length, withheld: suppressed + overflow },
        complete: withheld.length === 0,
        withheld,
      },
      hits: returned,
    };
  }

  /** Cheap orientation: what is in this stream, without reading any of it. */
  async summary() {
    await this.init();
    const all = await this._readAll();
    const turns = new Map();
    for (const r of all) {
      if (r.kind === "turn") turns.set(r.turn, { turn: r.turn, cmd: r.cmd, ts: r.ts, origin: r.origin });
      if (r.kind === "out" && turns.has(r.turn)) Object.assign(turns.get(r.turn), { bytes: r.bytes, lines: r.lines, out_hash: r.out_hash });
      if (r.kind === "exit" && turns.has(r.turn)) Object.assign(turns.get(r.turn), { code: r.code, ok: r.ok, duration_ms: r.duration_ms, outcome: r.outcome });
    }
    const list = [...turns.values()];
    return {
      receipt: {
        op: "summary", stream: this.stream,
        counts: { records: all.length, turns: list.length, returned: list.length, withheld: 0 },
        cursor: { next: this._seq + 1 },
        complete: true, withheld: [],
      },
      turns: list,
    };
  }
}

/** Identical bodies across turns are worth naming rather than re-sending. */
export function dedupeByHash(turns) {
  const seen = new Map();
  return turns.map((t) => {
    if (!t.out_hash) return t;
    if (seen.has(t.out_hash)) return { ...t, sameAsTurn: seen.get(t.out_hash) };
    seen.set(t.out_hash, t.turn);
    return t;
  });
}
