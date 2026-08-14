/**
 * Transcript Store
 *
 * Manages durable, JSONL-backed session transcripts with Row-0 header initialization,
 * transactional atomic appends, and high-performance querying via NuEngine.
 */

import fs from "node:fs/promises";
import { existsSync, createReadStream } from "node:fs";
import readline from "node:readline";
import path from "node:path";

export class TranscriptStore {
  constructor({ workspaceRoot = process.cwd(), sessionId }) {
    this.workspaceRoot = workspaceRoot;
    this.sessionId = sessionId;
    this.dirPath = path.join(this.workspaceRoot, ".para-agent", "transcripts");
    this.filePath = path.join(this.dirPath, `${sessionId}.jsonl`);
    this.initialized = false;
    this.nextIndex = 0;
  }

  /** Initialize Row 0 (transcript_header) if not already present */
  async init(headerData = {}) {
    if (this.initialized && existsSync(this.filePath)) return this;

    await fs.mkdir(this.dirPath, { recursive: true });

    if (!existsSync(this.filePath)) {
      const headerRow = {
        record_type: "transcript_header",
        schema_version: 1,
        transcript_id: `trn-${this.sessionId}`,
        created_at: new Date().toISOString(),
        schemas: {
          header: "urn:science-facility:para-agent:schema:transcript-header:1",
          exchange: "urn:science-facility:para-agent:schema:transcript-exchange:1",
        },
        producer: {
          name: "para-agent",
          version: headerData.version ?? "0.1.0",
        },
        session: {
          session_id: this.sessionId,
        },
        workspace: {
          default_root: this.workspaceRoot,
          selection_policy: "primary_workspace",
        },
        participants: headerData.participants ?? [
          { participant_id: "primary", role: "primary", default_client: "claude" },
          { participant_id: "para", role: "para", default_client: "nu" },
        ],
      };

      await fs.writeFile(this.filePath, JSON.stringify(headerRow) + "\n", "utf8");
      this.nextIndex = 0;
    } else {
      // Discover current exchange index from existing file
      this.nextIndex = await this._countExchanges();
    }

    this.initialized = true;
    return this;
  }

  /**
   * Transactional atomic append of a completed transcript_exchange row.
   */
  async commitExchange(exchangePayload) {
    if (!this.initialized) await this.init();

    const exchangeRow = {
      record_type: "transcript_exchange",
      ...exchangePayload,
    };

    // Single-line atomic append with LF normalization
    const line = JSON.stringify(exchangeRow) + "\n";
    await fs.appendFile(this.filePath, line, "utf8");
    this.nextIndex++;

    return exchangeRow;
  }

  /** Read the Row-0 transcript header */
  async readHeader() {
    if (!existsSync(this.filePath)) return null;
    const stream = createReadStream(this.filePath, { encoding: "utf8" });
    const rl = readline.createInterface({ input: stream, crlfDelay: Infinity });

    for await (const line of rl) {
      if (line.trim()) {
        rl.close();
        return JSON.parse(line);
      }
    }
    return null;
  }

  /** Count existing exchange rows in this transcript */
  async _countExchanges() {
    if (!existsSync(this.filePath)) return 0;
    let count = 0;
    const stream = createReadStream(this.filePath, { encoding: "utf8" });
    const rl = readline.createInterface({ input: stream, crlfDelay: Infinity });

    for await (const line of rl) {
      if (line.trim().includes('"record_type":"transcript_exchange"')) {
        count++;
      }
    }
    return count;
  }

  /**
   * Query this transcript file using a Nushell pipeline expression via NuEngine.
   */
  async query(nuEngine, pipeline) {
    if (!existsSync(this.filePath)) return [];
    const nuPath = this.filePath.replace(/\\/g, "/");
    const script = `open --raw "${nuPath}" | lines | where ($it | str trim | str length) > 0 | each { from json } | ${pipeline}`;
    return await nuEngine.eval(script);
  }
}
