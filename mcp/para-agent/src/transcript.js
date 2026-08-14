/**
 * Durable mediated transcript store.
 *
 * A transcript contains an immutable row-0 header and terminal exchange rows.
 * Durable acceptance and terminal markers live in a paired append-only WAL.
 * Writable stores hold an exclusive fenced lease; read-only stores never create.
 */

import crypto from "node:crypto";
import fs from "node:fs/promises";
import path from "node:path";
import { TextDecoder } from "node:util";

import {
  PersistedValidationError,
  assertAcceptanceWalRow,
  assertExchange,
  assertHeader,
  sha256Utf8,
} from "./schema-validation.js";

const HEADER_SCHEMA_ID = "urn:science-facility:para-agent:schema:transcript-header:1";
const EXCHANGE_SCHEMA_ID = "urn:science-facility:para-agent:schema:transcript-exchange:1";
const ACTIVE_LEASES = new Map();
const UTF8_FATAL = new TextDecoder("utf-8", { fatal: true });

export class TranscriptStoreError extends Error {
  constructor(code, message, details = undefined) {
    super(message);
    this.name = "TranscriptStoreError";
    this.code = code;
    if (details !== undefined) this.details = details;
  }
}

function requireString(value, name) {
  if (typeof value !== "string" || value.length === 0) {
    throw new TranscriptStoreError("TRANSCRIPT_ARGUMENT_INVALID", `${name} must be a non-empty string`);
  }
  return value;
}

function assertKnownKeys(value, allowed, label) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new TranscriptStoreError("TRANSCRIPT_ARGUMENT_INVALID", `${label} must be an object`);
  }
  const unknown = Object.keys(value).filter((key) => !allowed.has(key));
  if (unknown.length > 0) {
    throw new TranscriptStoreError(
      "TRANSCRIPT_ARGUMENT_UNKNOWN",
      `${label} contains unknown fields: ${unknown.join(", ")}`,
    );
  }
}

function canonicalize(value) {
  if (Array.isArray(value)) return value.map(canonicalize);
  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.keys(value).sort().map((key) => [key, canonicalize(value[key])]),
    );
  }
  return value;
}

function canonicalJson(value) {
  return JSON.stringify(canonicalize(value));
}

function sessionKeyOf(sessionId) {
  const normalized = sessionId.normalize("NFC");
  const readable = normalized
    .replace(/[^A-Za-z0-9_-]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 40) || "session";
  return `${readable}-${sha256Utf8(sessionId).slice(0, 16)}`;
}

function containedPath(root, ...parts) {
  const resolvedRoot = path.resolve(root);
  const candidate = path.resolve(resolvedRoot, ...parts);
  if (candidate !== resolvedRoot && !candidate.startsWith(`${resolvedRoot}${path.sep}`)) {
    throw new TranscriptStoreError("TRANSCRIPT_PATH_ESCAPE", "derived transcript path escaped its storage root");
  }
  return candidate;
}

async function exists(filePath) {
  try {
    await fs.access(filePath);
    return true;
  } catch (error) {
    if (error?.code === "ENOENT") return false;
    throw error;
  }
}

function isProcessAlive(pid) {
  if (!Number.isSafeInteger(pid) || pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    if (error?.code === "ESRCH" || error?.code === "EINVAL") return false;
    return true;
  }
}

function terminalTime(clock, acceptedAt) {
  const now = clock().getTime();
  return new Date(Math.max(now, Date.parse(acceptedAt))).toISOString();
}

function recoveryNoticesOf(state) {
  const notices = [];
  for (const exchange of state.exchangeRows ?? []) {
    if (exchange.outcome?.native_stop_confirmed !== false) continue;
    const acceptance = state.acceptances.get(exchange.exchange_id);
    if (!acceptance) continue;
    notices.push({
      exchange_id: exchange.exchange_id,
      conversation_key: acceptance.conversation_key,
      terminal_status: exchange.status,
      observed_at: exchange.exchange_end,
      outcome: {
        code: exchange.outcome.code,
        message: exchange.outcome.message,
        native_stop_confirmed: false,
      },
    });
  }
  return notices;
}

async function readJsonl(filePath, kind) {
  let bytes;
  try {
    bytes = await fs.readFile(filePath);
  } catch (error) {
    if (error?.code === "ENOENT") return null;
    throw error;
  }
  if (bytes.length === 0) {
    throw new TranscriptStoreError(`${kind}_EMPTY`, `${kind.toLowerCase()} file is empty`);
  }

  let text;
  try {
    text = UTF8_FATAL.decode(bytes);
  } catch (error) {
    throw new TranscriptStoreError(`${kind}_UTF8_INVALID`, `${kind.toLowerCase()} is not valid UTF-8`, {
      cause: error.message,
    });
  }

  const hasTerminalLf = text.endsWith("\n");
  const physical = text.split("\n");
  if (hasTerminalLf) physical.pop();
  const rows = [];
  const digests = [];

  for (let index = 0; index < physical.length; index++) {
    const physicalLine = physical[index];
    const line = physicalLine.endsWith("\r") ? physicalLine.slice(0, -1) : physicalLine;
    if (line.length === 0) {
      throw new TranscriptStoreError(`${kind}_MALFORMED_ROW`, `${kind.toLowerCase()} contains an empty physical row`, {
        physical_row: index,
      });
    }
    try {
      rows.push(JSON.parse(line));
      digests.push(sha256Utf8(line));
    } catch (error) {
      const isTornTail = index === physical.length - 1 && !hasTerminalLf;
      throw new TranscriptStoreError(
        isTornTail ? `${kind}_TORN_TAIL` : `${kind}_MALFORMED_ROW`,
        isTornTail
          ? `${kind.toLowerCase()} ends with an incomplete JSON row`
          : `${kind.toLowerCase()} contains malformed JSON`,
        { physical_row: index, cause: error.message },
      );
    }
  }

  return {
    rows,
    digests,
    needsFraming: !hasTerminalLf,
  };
}

export class TranscriptStore {
  constructor({
    workspaceRoot = process.cwd(),
    sessionId,
    mode = "writable",
    writerId = `writer-${crypto.randomUUID()}`,
    clock = () => new Date(),
  }) {
    requireString(sessionId, "sessionId");
    if (!new Set(["writable", "read-only"]).has(mode)) {
      throw new TranscriptStoreError("TRANSCRIPT_MODE_INVALID", "mode must be 'writable' or 'read-only'");
    }

    this.workspaceRoot = path.resolve(workspaceRoot);
    this.sessionId = sessionId;
    this.sessionKey = sessionKeyOf(sessionId);
    this.transcriptId = `trn-${sha256Utf8(sessionId)}`;
    this.mode = mode;
    this.writerId = writerId;
    this.clock = clock;

    this.dirPath = containedPath(this.workspaceRoot, ".para-agent", "transcripts");
    this.filePath = containedPath(this.dirPath, `${this.sessionKey}.jsonl`);
    this.walPath = containedPath(this.dirPath, `${this.sessionKey}.acceptance.jsonl`);
    this.lockPath = containedPath(this.dirPath, `${this.sessionKey}.writer.lock`);
    this.traceDir = containedPath(this.dirPath, "traces", this.sessionKey);

    this.initialized = false;
    this.nextIndex = 0;
    this._header = null;
    this._recoveryNotices = [];
    this._lease = null;
    this._writeTail = Promise.resolve();
  }

  static async openWritable(options) {
    const store = new TranscriptStore({ ...options, mode: "writable" });
    await store.open(options?.headerData);
    return store;
  }

  static async openReadOnly(options) {
    const store = new TranscriptStore({ ...options, mode: "read-only" });
    await store.open();
    return store;
  }

  async init(headerData = {}) {
    if (this.mode !== "writable") {
      throw new TranscriptStoreError("TRANSCRIPT_READ_ONLY", "read-only stores cannot initialize transcripts");
    }
    return this.open(headerData);
  }

  async open(headerData = {}) {
    if (this.initialized) return this;

    if (this.mode === "read-only") {
      const state = await this._scanState();
      this._adoptState(state);
      this.initialized = true;
      return this;
    }

    await fs.mkdir(this.dirPath, { recursive: true });
    await this._acquireWriterLease();
    try {
      await this._createHeaderIfMissing(headerData);
      let state = await this._scanState();
      this._adoptState(state);
      this.initialized = true;
      await this._withWriteLane(async () => {
        await this._recoverPending(state);
      });
      state = await this._scanState();
      this._adoptState(state);
      return this;
    } catch (error) {
      this.initialized = false;
      await this._releaseWriterLease({ suppressMissing: true });
      throw error;
    }
  }

  async close() {
    await this._writeTail.catch(() => {});
    if (this._lease) await this._releaseWriterLease();
    this.initialized = false;
  }

  getRecoveryNotices() {
    return structuredClone(this._recoveryNotices);
  }

  traceRelativeRef(exchangeId) {
    if (!/^xid-[A-Za-z0-9-]+$/.test(exchangeId)) {
      throw new TranscriptStoreError("TRANSCRIPT_EXCHANGE_ID_UNSAFE", "exchangeId is not a store-generated safe identifier");
    }
    return path.posix.join("traces", this.sessionKey, `${exchangeId}.trace`);
  }

  tracePath(exchangeId) {
    return containedPath(this.traceDir, `${exchangeId}.trace`);
  }

  async acceptExchange(input) {
    await this._ensureWritableOpen();
    assertKnownKeys(input, new Set([
      "prompt",
      "senderParticipantId",
      "receiverParticipantId",
      "conversationKey",
      "adapter",
      "requestId",
      "idempotencyKey",
      "selectedApplicationId",
    ]), "acceptExchange input");
    const {
      prompt,
      senderParticipantId,
      receiverParticipantId,
      conversationKey,
      adapter,
      requestId,
      idempotencyKey,
      selectedApplicationId,
    } = input;

    return this._withWriteLane(async () => {
      const state = await this._scanState();
      requireString(senderParticipantId, "senderParticipantId");
      requireString(receiverParticipantId, "receiverParticipantId");
      requireString(conversationKey, "conversationKey");
      if (typeof prompt !== "string") {
        throw new TranscriptStoreError("TRANSCRIPT_ARGUMENT_INVALID", "prompt must be an exact UTF-8 string");
      }
      if (requestId !== undefined) requireString(requestId, "requestId");
      if (selectedApplicationId !== undefined) requireString(selectedApplicationId, "selectedApplicationId");

      const participantIds = new Set(state.header.participants.map((participant) => participant.participant_id));
      for (const participantId of [senderParticipantId, receiverParticipantId]) {
        if (!participantIds.has(participantId)) {
          throw new TranscriptStoreError(
            "ACCEPTANCE_PARTICIPANT_UNKNOWN",
            `acceptance references unknown participant '${participantId}'`,
          );
        }
      }

      if (idempotencyKey !== undefined) {
        requireString(idempotencyKey, "idempotencyKey");
        const priorId = state.idempotency.get(idempotencyKey);
        if (priorId) {
          const prior = state.acceptances.get(priorId);
          const same = prior.prompt.text === prompt
            && prior.sender_participant_id === senderParticipantId
            && prior.receiver_participant_id === receiverParticipantId
            && prior.conversation_key === conversationKey
            && canonicalJson(prior.adapter) === canonicalJson(adapter)
            && prior.selected_application_id === selectedApplicationId;
          if (!same) {
            throw new TranscriptStoreError(
              "ACCEPTANCE_IDEMPOTENCY_CONFLICT",
              "idempotency key was already accepted with different immutable input",
            );
          }
          return prior;
        }
      }

      const acceptedAt = this.clock().toISOString();
      const acceptance = {
        record_type: "exchange_acceptance",
        schema_version: 1,
        exchange_id: `xid-${crypto.randomUUID()}`,
        accepted_at: acceptedAt,
        ...(requestId !== undefined ? { request_id: requestId } : {}),
        ...(idempotencyKey !== undefined ? { idempotency_key: idempotencyKey } : {}),
        ...(selectedApplicationId !== undefined ? { selected_application_id: selectedApplicationId } : {}),
        prompt: {
          text: prompt,
          sha256: sha256Utf8(prompt),
          bytes: Buffer.byteLength(prompt, "utf8"),
          record_id: `rec-${crypto.randomUUID()}`,
        },
        sender_participant_id: senderParticipantId,
        receiver_participant_id: receiverParticipantId,
        conversation_key: conversationKey,
        adapter,
        writer: this._writerEvidence(),
      };
      assertAcceptanceWalRow(acceptance);
      await this._appendRow(this.walPath, acceptance, state.walNeedsFraming);
      return acceptance;
    });
  }

  async commitExchange(payload) {
    await this._ensureWritableOpen();
    assertKnownKeys(payload, new Set([
      "exchange_id",
      "status",
      "exchange_end",
      "application",
      "model",
      "native",
      "outcome",
      "trace",
      "delivery",
      "records",
      "extensions",
    ]), "commitExchange payload");

    return this._withWriteLane(async () => {
      const state = await this._scanState();
      const exchangeId = requireString(payload.exchange_id, "exchange_id");
      const acceptance = state.acceptances.get(exchangeId);
      if (!acceptance) {
        throw new TranscriptStoreError(
          "EXCHANGE_NOT_ACCEPTED",
          `exchange '${exchangeId}' has no durable acceptance row`,
        );
      }

      const existing = state.exchanges.get(exchangeId);
      if (existing) {
        const candidate = this._buildExchangeRow(
          acceptance,
          payload,
          existing.exchange_index,
          payload.exchange_end ?? existing.exchange_end,
        );
        if (canonicalJson(candidate) !== canonicalJson(existing)) {
          throw new TranscriptStoreError(
            "EXCHANGE_TERMINAL_CONFLICT",
            `exchange '${exchangeId}' is already terminal with different content`,
          );
        }
        if (!state.markers.has(exchangeId)) {
          const marker = this._terminalMarker(existing, state.exchangeDigests.get(exchangeId));
          await this._appendRow(this.walPath, marker, state.walNeedsFraming);
        }
        this.nextIndex = state.nextIndex;
        return existing;
      }

      const exchange = this._buildExchangeRow(
        acceptance,
        payload,
        state.nextIndex,
        payload.exchange_end ?? terminalTime(this.clock, acceptance.accepted_at),
      );
      const exchangeDigest = await this._appendRow(this.filePath, exchange, state.transcriptNeedsFraming);
      const marker = this._terminalMarker(exchange, exchangeDigest);
      await this._appendRow(this.walPath, marker, state.walNeedsFraming);
      this.nextIndex = exchange.exchange_index + 1;
      return exchange;
    });
  }

  async readHeader() {
    await this._ensureOpen();
    const state = await this._scanState();
    this._adoptState(state);
    return state.header ? structuredClone(state.header) : null;
  }

  async select(selector = { kind: "summary" }) {
    await this._ensureOpen();
    assertKnownKeys(selector, new Set(["kind", "exchangeId", "recordKind", "step"]), "transcript selector");
    const state = await this._scanState();
    this._adoptState(state);
    if (!state.exists) {
      return selector.kind === "summary" || selector.kind === undefined ? [] : null;
    }

    const kind = selector.kind ?? "summary";
    if (kind === "summary") {
      if (selector.exchangeId !== undefined || selector.recordKind !== undefined || selector.step !== undefined) {
        throw new TranscriptStoreError("TRANSCRIPT_SELECTOR_INVALID", "summary selector accepts no additional fields");
      }
      return state.exchangeRows.map((exchange) => this._summarize(exchange));
    }

    const exchangeId = requireString(selector.exchangeId, "exchangeId");
    const exchange = state.exchanges.get(exchangeId);
    if (!exchange) return null;

    if (kind === "exchange") {
      if (selector.recordKind !== undefined || selector.step !== undefined) {
        throw new TranscriptStoreError("TRANSCRIPT_SELECTOR_INVALID", "exchange selector accepts only exchangeId");
      }
      return structuredClone(exchange);
    }
    if (kind === "records") {
      if (selector.step !== undefined) {
        throw new TranscriptStoreError("TRANSCRIPT_SELECTOR_INVALID", "records selector does not accept step");
      }
      const records = selector.recordKind === undefined
        ? exchange.records
        : exchange.records.filter((record) => record._type === selector.recordKind);
      return structuredClone(records);
    }
    if (kind === "step") {
      if (selector.recordKind !== undefined || !Number.isInteger(selector.step) || selector.step < 0) {
        throw new TranscriptStoreError("TRANSCRIPT_SELECTOR_INVALID", "step selector requires a non-negative integer step and no recordKind");
      }
      return exchange.records[selector.step] === undefined ? null : structuredClone(exchange.records[selector.step]);
    }
    throw new TranscriptStoreError("TRANSCRIPT_SELECTOR_INVALID", `unknown transcript selector kind '${kind}'`);
  }

  async query() {
    throw new TranscriptStoreError(
      "TRANSCRIPT_RAW_QUERY_FORBIDDEN",
      "raw query source is forbidden; use TranscriptStore.select with a typed selector",
    );
  }

  _buildHeader(headerData) {
    const header = {
      record_type: "transcript_header",
      schema_version: 1,
      transcript_id: this.transcriptId,
      created_at: this.clock().toISOString(),
      schemas: {
        header: HEADER_SCHEMA_ID,
        exchange: EXCHANGE_SCHEMA_ID,
      },
      producer: {
        name: "para-agent",
        version: headerData.version ?? "0.1.0",
        ...(headerData.instanceId ? { instance_id: headerData.instanceId } : {}),
      },
      session: {
        session_id: this.sessionId,
      },
      workspace: {
        default_root: this.workspaceRoot,
        selection_policy: "primary_workspace",
      },
      participants: headerData.participants ?? [
        { participant_id: "primary", role: "primary" },
        { participant_id: "para", role: "para" },
      ],
      ...(headerData.labels ? { labels: headerData.labels } : {}),
      ...(headerData.extensions ? { extensions: headerData.extensions } : {}),
    };
    return assertHeader(header);
  }

  async _createHeaderIfMissing(headerData) {
    if (await exists(this.filePath)) return;
    const header = this._buildHeader(headerData);
    await this._assertFence();
    try {
      await fs.writeFile(this.filePath, `${JSON.stringify(header)}\n`, { encoding: "utf8", flag: "wx" });
    } catch (error) {
      if (error?.code !== "EEXIST") throw error;
    }
  }

  _buildExchangeRow(acceptance, payload, exchangeIndex, exchangeEnd) {
    if (!Array.isArray(payload.records) || payload.records.some((record) => record?._type === "prompt")) {
      throw new TranscriptStoreError(
        "EXCHANGE_RECORDS_INVALID",
        "commitExchange records must be receiver-derived records only; the store owns the ingress prompt",
      );
    }
    const promptRecord = {
      _type: "prompt",
      record_id: acceptance.prompt.record_id,
      observed_at: acceptance.accepted_at,
      text: acceptance.prompt.text,
      content_sha256: acceptance.prompt.sha256,
      source: {
        kind: "mediation_ingress",
        ...(acceptance.request_id ? { request_id: acceptance.request_id } : {}),
      },
    };
    const exchange = {
      record_type: "transcript_exchange",
      schema_version: 1,
      exchange_id: acceptance.exchange_id,
      exchange_index: exchangeIndex,
      exchange_start: acceptance.accepted_at,
      exchange_end: exchangeEnd,
      ...(acceptance.request_id ? { request_id: acceptance.request_id } : {}),
      ...(acceptance.idempotency_key ? { idempotency_key: acceptance.idempotency_key } : {}),
      sender_participant_id: acceptance.sender_participant_id,
      receiver_participant_id: acceptance.receiver_participant_id,
      ...(payload.application ? { application: payload.application } : {}),
      adapter: acceptance.adapter,
      ...(payload.model ? { model: payload.model } : {}),
      ...(payload.native ? { native: payload.native } : {}),
      status: payload.status,
      ...(payload.outcome ? { outcome: payload.outcome } : {}),
      trace: payload.trace,
      delivery: payload.delivery,
      records: [promptRecord, ...payload.records],
      ...(payload.extensions ? { extensions: payload.extensions } : {}),
    };
    return assertExchange(exchange, this._header);
  }

  _terminalMarker(exchange, exchangeDigest) {
    const marker = {
      record_type: "exchange_terminal_marker",
      schema_version: 1,
      exchange_id: exchange.exchange_id,
      exchange_index: exchange.exchange_index,
      terminal_status: exchange.status,
      terminal_at: terminalTime(this.clock, exchange.exchange_end),
      exchange_sha256: exchangeDigest,
      writer: this._writerEvidence(),
    };
    return assertAcceptanceWalRow(marker);
  }

  _summarize(exchange) {
    return {
      exchange_id: exchange.exchange_id,
      exchange_index: exchange.exchange_index,
      exchange_start: exchange.exchange_start,
      exchange_end: exchange.exchange_end,
      duration_ms: Date.parse(exchange.exchange_end) - Date.parse(exchange.exchange_start),
      status: exchange.status,
      application_id: exchange.application?.id,
      model_id: exchange.model?.id,
      records: exchange.records.length,
      tool_calls: exchange.records.filter((record) => record._type === "tool_call").length,
      thinking: exchange.records.filter((record) => record._type === "thinking").length,
      trace_complete: exchange.trace.complete,
      omissions: exchange.trace.omissions.length,
    };
  }

  async _scanState() {
    const transcript = await readJsonl(this.filePath, "TRANSCRIPT");
    const wal = await readJsonl(this.walPath, "ACCEPTANCE_WAL");
    if (!transcript) {
      if (wal) {
        throw new TranscriptStoreError("TRANSCRIPT_WAL_ORPHANED", "acceptance WAL exists without its transcript");
      }
      return {
        exists: false,
        header: null,
        exchangeRows: [],
        exchanges: new Map(),
        exchangeDigests: new Map(),
        acceptances: new Map(),
        acceptanceOrder: [],
        markers: new Map(),
        idempotency: new Map(),
        nextIndex: 0,
        transcriptNeedsFraming: false,
        walNeedsFraming: false,
      };
    }
    if (transcript.rows.length === 0) {
      throw new TranscriptStoreError("TRANSCRIPT_HEADER_MISSING", "transcript has no row-0 header");
    }

    const header = assertHeader(transcript.rows[0]);
    if (header.transcript_id !== this.transcriptId || header.session.session_id !== this.sessionId) {
      throw new TranscriptStoreError(
        "TRANSCRIPT_IDENTITY_MISMATCH",
        "transcript header identity does not match the requested logical session",
      );
    }

    const exchangeRows = [];
    const exchanges = new Map();
    const exchangeDigests = new Map();
    const exchangeIndexes = new Set();
    let priorIndex = -1;
    for (let rowIndex = 1; rowIndex < transcript.rows.length; rowIndex++) {
      const exchange = assertExchange(transcript.rows[rowIndex], header);
      if (exchanges.has(exchange.exchange_id)) {
        throw new TranscriptStoreError("TRANSCRIPT_EXCHANGE_DUPLICATE", `duplicate exchange_id '${exchange.exchange_id}'`);
      }
      if (exchangeIndexes.has(exchange.exchange_index) || exchange.exchange_index <= priorIndex) {
        throw new TranscriptStoreError(
          "TRANSCRIPT_INDEX_INVALID",
          "exchange indexes must be unique and strictly increase in physical commit order",
        );
      }
      exchanges.set(exchange.exchange_id, exchange);
      exchangeDigests.set(exchange.exchange_id, transcript.digests[rowIndex]);
      exchangeIndexes.add(exchange.exchange_index);
      exchangeRows.push(exchange);
      priorIndex = exchange.exchange_index;
    }

    const acceptances = new Map();
    const acceptanceOrder = [];
    const markers = new Map();
    const idempotency = new Map();
    for (const row of wal?.rows ?? []) {
      assertAcceptanceWalRow(row);
      if (row.record_type === "exchange_acceptance") {
        if (acceptances.has(row.exchange_id)) {
          throw new TranscriptStoreError("ACCEPTANCE_DUPLICATE", `duplicate acceptance '${row.exchange_id}'`);
        }
        if (row.idempotency_key && idempotency.has(row.idempotency_key)) {
          throw new TranscriptStoreError("ACCEPTANCE_IDEMPOTENCY_DUPLICATE", `duplicate idempotency key '${row.idempotency_key}'`);
        }
        const participantIds = new Set(header.participants.map((participant) => participant.participant_id));
        if (!participantIds.has(row.sender_participant_id) || !participantIds.has(row.receiver_participant_id)) {
          throw new TranscriptStoreError("ACCEPTANCE_PARTICIPANT_UNKNOWN", "acceptance references an unknown participant");
        }
        acceptances.set(row.exchange_id, row);
        acceptanceOrder.push(row.exchange_id);
        if (row.idempotency_key) idempotency.set(row.idempotency_key, row.exchange_id);
      } else {
        if (!acceptances.has(row.exchange_id)) {
          throw new TranscriptStoreError("ACCEPTANCE_MARKER_ORPHANED", `terminal marker precedes or lacks acceptance '${row.exchange_id}'`);
        }
        if (markers.has(row.exchange_id)) {
          throw new TranscriptStoreError("ACCEPTANCE_MARKER_DUPLICATE", `duplicate terminal marker '${row.exchange_id}'`);
        }
        markers.set(row.exchange_id, row);
      }
    }

    if (exchangeRows.length > 0 && !wal) {
      throw new TranscriptStoreError("TRANSCRIPT_ACCEPTANCE_WAL_MISSING", "terminal exchanges exist without an acceptance WAL");
    }
    for (const exchange of exchangeRows) {
      const acceptance = acceptances.get(exchange.exchange_id);
      if (!acceptance) {
        throw new TranscriptStoreError("TRANSCRIPT_EXCHANGE_UNACCEPTED", `terminal exchange '${exchange.exchange_id}' has no acceptance`);
      }
      if (
        exchange.exchange_start !== acceptance.accepted_at
        || exchange.sender_participant_id !== acceptance.sender_participant_id
        || exchange.receiver_participant_id !== acceptance.receiver_participant_id
        || canonicalJson(exchange.adapter) !== canonicalJson(acceptance.adapter)
        || exchange.records[0].text !== acceptance.prompt.text
        || exchange.records[0].content_sha256 !== acceptance.prompt.sha256
      ) {
        throw new TranscriptStoreError("TRANSCRIPT_ACCEPTANCE_MISMATCH", `terminal exchange '${exchange.exchange_id}' disagrees with durable acceptance`);
      }
      if (acceptance.request_id !== exchange.request_id || acceptance.idempotency_key !== exchange.idempotency_key) {
        throw new TranscriptStoreError("TRANSCRIPT_ACCEPTANCE_MISMATCH", `terminal exchange '${exchange.exchange_id}' changes request identity`);
      }
      if (acceptance.selected_application_id && exchange.application
        && acceptance.selected_application_id !== exchange.application.id) {
        throw new TranscriptStoreError("TRANSCRIPT_APPLICATION_MISMATCH", `observed application differs from selected adapter application`);
      }
    }
    for (const [exchangeId, marker] of markers) {
      const exchange = exchanges.get(exchangeId);
      if (!exchange) {
        throw new TranscriptStoreError("ACCEPTANCE_MARKER_WITHOUT_EXCHANGE", `terminal marker '${exchangeId}' has no terminal exchange`);
      }
      if (
        marker.exchange_index !== exchange.exchange_index
        || marker.terminal_status !== exchange.status
        || marker.exchange_sha256 !== exchangeDigests.get(exchangeId)
      ) {
        throw new TranscriptStoreError("ACCEPTANCE_MARKER_MISMATCH", `terminal marker '${exchangeId}' does not bind the persisted exchange`);
      }
    }

    return {
      exists: true,
      header,
      exchangeRows,
      exchanges,
      exchangeDigests,
      acceptances,
      acceptanceOrder,
      markers,
      idempotency,
      nextIndex: exchangeRows.length === 0
        ? 0
        : Math.max(...exchangeRows.map((exchange) => exchange.exchange_index)) + 1,
      transcriptNeedsFraming: transcript.needsFraming,
      walNeedsFraming: wal?.needsFraming ?? false,
    };
  }

  async _recoverPending(state) {
    for (const exchangeId of state.acceptanceOrder) {
      const acceptance = state.acceptances.get(exchangeId);
      const existing = state.exchanges.get(exchangeId);
      if (existing) {
        if (!state.markers.has(exchangeId)) {
          const marker = this._terminalMarker(existing, state.exchangeDigests.get(exchangeId));
          await this._appendRow(this.walPath, marker, state.walNeedsFraming);
          state.walNeedsFraming = false;
          state.markers.set(exchangeId, marker);
        }
        continue;
      }

      const exchange = this._buildExchangeRow(acceptance, {
        exchange_id: exchangeId,
        status: "interrupted",
        outcome: {
          code: "SERVER_RESTART_RECOVERY",
          message: "Durably accepted exchange had no terminal commit when the writer restarted.",
          retryable: true,
          native_stop_confirmed: false,
        },
        trace: {
          complete: false,
          omissions: [{
            code: "RESTART_BEFORE_TERMINAL",
            detail: "Native trace completeness and receiver termination could not be established after writer restart.",
          }],
        },
        delivery: { events: [] },
        records: [],
      }, state.nextIndex, terminalTime(this.clock, acceptance.accepted_at));
      const digest = await this._appendRow(this.filePath, exchange, state.transcriptNeedsFraming);
      state.transcriptNeedsFraming = false;
      state.exchanges.set(exchangeId, exchange);
      state.exchangeRows.push(exchange);
      state.exchangeDigests.set(exchangeId, digest);
      state.nextIndex += 1;
      const marker = this._terminalMarker(exchange, digest);
      await this._appendRow(this.walPath, marker, state.walNeedsFraming);
      state.walNeedsFraming = false;
      state.markers.set(exchangeId, marker);
    }
  }

  async _appendRow(filePath, row, needsFraming) {
    await this._assertFence();
    const serialized = JSON.stringify(row);
    await fs.appendFile(filePath, `${needsFraming ? "\n" : ""}${serialized}\n`, "utf8");
    return sha256Utf8(serialized);
  }

  _writerEvidence() {
    if (!this._lease) {
      throw new TranscriptStoreError("TRANSCRIPT_WRITER_LEASE_REQUIRED", "a writable operation requires an active lease");
    }
    return {
      writer_id: this._lease.writer_id,
      fence: this._lease.fence,
    };
  }

  async _withWriteLane(operation) {
    if (this.mode !== "writable" || !this._lease) {
      throw new TranscriptStoreError("TRANSCRIPT_READ_ONLY", "operation requires a writable transcript store");
    }
    const queued = this._writeTail.then(operation);
    this._writeTail = queued.catch(() => {});
    return queued;
  }

  async _ensureOpen() {
    if (!this.initialized) await this.open();
  }

  async _ensureWritableOpen() {
    if (this.mode !== "writable") {
      throw new TranscriptStoreError("TRANSCRIPT_READ_ONLY", "operation requires a writable transcript store");
    }
    if (!this.initialized) await this.open();
  }

  _adoptState(state) {
    this._header = state.header;
    this.nextIndex = state.nextIndex;
    this._recoveryNotices = recoveryNoticesOf(state);
  }

  async _acquireWriterLease() {
    if (ACTIVE_LEASES.has(this.lockPath)) {
      throw new TranscriptStoreError("TRANSCRIPT_WRITER_BUSY", "this process already owns the transcript writer lease");
    }

    for (let attempt = 0; attempt < 4; attempt++) {
      const lease = {
        record_type: "transcript_writer_lease",
        schema_version: 1,
        transcript_id: this.transcriptId,
        writer_id: this.writerId,
        pid: process.pid,
        acquired_at: this.clock().toISOString(),
        fence: crypto.randomUUID(),
      };
      try {
        const handle = await fs.open(this.lockPath, "wx", 0o600);
        try {
          await handle.writeFile(`${JSON.stringify(lease)}\n`, "utf8");
        } finally {
          await handle.close();
        }
        this._lease = lease;
        ACTIVE_LEASES.set(this.lockPath, lease.fence);
        return;
      } catch (error) {
        if (error?.code !== "EEXIST") throw error;
      }

      let raw;
      try {
        raw = await fs.readFile(this.lockPath, "utf8");
      } catch (error) {
        if (error?.code === "ENOENT") continue;
        throw error;
      }
      let prior;
      try {
        prior = JSON.parse(raw.trim());
      } catch (error) {
        throw new TranscriptStoreError("TRANSCRIPT_LOCK_CORRUPT", "writer lock is not valid JSON", {
          cause: error.message,
        });
      }
      if (
        prior?.record_type !== "transcript_writer_lease"
        || prior?.transcript_id !== this.transcriptId
        || typeof prior?.writer_id !== "string"
        || typeof prior?.fence !== "string"
        || !Number.isSafeInteger(prior?.pid)
      ) {
        throw new TranscriptStoreError("TRANSCRIPT_LOCK_CORRUPT", "writer lock does not satisfy the lease contract");
      }
      if (isProcessAlive(prior.pid)) {
        throw new TranscriptStoreError(
          "TRANSCRIPT_WRITER_BUSY",
          `transcript is owned by live writer '${prior.writer_id}' (PID ${prior.pid})`,
        );
      }

      const staleName = `${this.sessionKey}.writer.lock.stale.${Date.now()}.${sha256Utf8(raw).slice(0, 12)}.json`;
      const stalePath = containedPath(this.dirPath, staleName);
      try {
        await fs.rename(this.lockPath, stalePath);
      } catch (error) {
        if (error?.code === "ENOENT" || error?.code === "EEXIST") continue;
        throw error;
      }
    }
    throw new TranscriptStoreError("TRANSCRIPT_WRITER_RACE", "could not acquire transcript writer lease after concurrent changes");
  }

  async _assertFence() {
    if (!this._lease) {
      throw new TranscriptStoreError("TRANSCRIPT_WRITER_LEASE_REQUIRED", "writer lease is not held");
    }
    let current;
    try {
      current = JSON.parse((await fs.readFile(this.lockPath, "utf8")).trim());
    } catch (error) {
      throw new TranscriptStoreError("TRANSCRIPT_FENCE_LOST", "writer lease disappeared or became unreadable", {
        cause: error.message,
      });
    }
    if (current.fence !== this._lease.fence || current.writer_id !== this._lease.writer_id) {
      throw new TranscriptStoreError("TRANSCRIPT_FENCE_LOST", "writer lease fencing identity changed");
    }
  }

  async _releaseWriterLease({ suppressMissing = false } = {}) {
    const lease = this._lease;
    if (!lease) return;
    try {
      const current = JSON.parse((await fs.readFile(this.lockPath, "utf8")).trim());
      if (current.fence !== lease.fence || current.writer_id !== lease.writer_id) {
        throw new TranscriptStoreError("TRANSCRIPT_FENCE_LOST", "refusing to release another writer's lease");
      }
      await fs.unlink(this.lockPath);
    } catch (error) {
      if (!(suppressMissing && error?.code === "ENOENT")) throw error;
    } finally {
      if (ACTIVE_LEASES.get(this.lockPath) === lease.fence) ACTIVE_LEASES.delete(this.lockPath);
      this._lease = null;
    }
  }
}

export { PersistedValidationError };
