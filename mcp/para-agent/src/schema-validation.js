import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

import Ajv2020 from "ajv/dist/2020.js";
import addFormats from "ajv-formats";

import { AMBIGUOUS_COMMIT_QUARANTINE_REASON } from "./quarantine-contract.js";

const SCHEMA_DIR = path.join(path.dirname(fileURLToPath(import.meta.url)), "schemas");

function loadSchema(name) {
  return JSON.parse(fs.readFileSync(path.join(SCHEMA_DIR, name), "utf8"));
}

export const transcriptHeaderSchema = loadSchema("transcript-header.schema.json");
export const transcriptExchangeSchema = loadSchema("transcript-exchange.schema.json");

const nonEmptyString = { type: "string", minLength: 1 };
const adapterBinding = {
  type: "object",
  required: ["id", "version"],
  properties: {
    id: nonEmptyString,
    version: nonEmptyString,
    profile_id: nonEmptyString,
  },
  additionalProperties: false,
};
const writerEvidence = {
  type: "object",
  required: ["writer_id", "fence"],
  properties: {
    writer_id: nonEmptyString,
    fence: nonEmptyString,
  },
  additionalProperties: false,
};

/** Internal persisted contract for the acceptance WAL paired with a transcript. */
export const acceptanceWalSchema = {
  $schema: "https://json-schema.org/draft/2020-12/schema",
  $id: "urn:science-facility:para-agent:schema:acceptance-wal:1",
  title: "Para-Agent Exchange Acceptance WAL Row",
  oneOf: [
    {
      type: "object",
      required: [
        "record_type",
        "schema_version",
        "exchange_id",
        "accepted_at",
        "prompt",
        "sender_participant_id",
        "receiver_participant_id",
        "conversation_key",
        "adapter",
        "writer",
      ],
      properties: {
        record_type: { const: "exchange_acceptance" },
        schema_version: { const: 1 },
        exchange_id: nonEmptyString,
        accepted_at: { type: "string", format: "date-time" },
        request_id: nonEmptyString,
        idempotency_key: nonEmptyString,
        selected_application_id: nonEmptyString,
        prompt: {
          type: "object",
          required: ["text", "sha256", "bytes", "record_id"],
          properties: {
            text: { type: "string" },
            sha256: { type: "string", pattern: "^[a-f0-9]{64}$" },
            bytes: { type: "integer", minimum: 0 },
            record_id: nonEmptyString,
          },
          additionalProperties: false,
        },
        sender_participant_id: nonEmptyString,
        receiver_participant_id: nonEmptyString,
        conversation_key: nonEmptyString,
        adapter: adapterBinding,
        writer: writerEvidence,
      },
      additionalProperties: false,
    },
    {
      type: "object",
      required: [
        "record_type",
        "schema_version",
        "exchange_id",
        "exchange_index",
        "terminal_status",
        "terminal_at",
        "exchange_sha256",
        "writer",
      ],
      properties: {
        record_type: { const: "exchange_terminal_marker" },
        schema_version: { const: 1 },
        exchange_id: nonEmptyString,
        exchange_index: { type: "integer", minimum: 0 },
        terminal_status: { enum: ["completed", "failed", "interrupted", "timeout"] },
        terminal_at: { type: "string", format: "date-time" },
        exchange_sha256: { type: "string", pattern: "^[a-f0-9]{64}$" },
        recovery: {
          type: "object",
          required: ["kind", "observed_at", "quarantine_reason"],
          properties: {
            kind: { const: "missing_terminal_marker_repaired" },
            observed_at: { type: "string", format: "date-time" },
            quarantine_reason: { const: AMBIGUOUS_COMMIT_QUARANTINE_REASON },
          },
          additionalProperties: false,
        },
        writer: writerEvidence,
      },
      additionalProperties: false,
    },
    {
      type: "object",
      required: [
        "record_type",
        "schema_version",
        "reconciliation_id",
        "conversation_key",
        "exchange_id",
        "expected",
        "basis",
        "reconciled_at",
        "authority",
        "writer",
      ],
      properties: {
        record_type: { const: "conversation_reconciliation" },
        schema_version: { const: 1 },
        reconciliation_id: nonEmptyString,
        conversation_key: nonEmptyString,
        exchange_id: nonEmptyString,
        expected: {
          type: "object",
          required: ["reason", "observed_at"],
          properties: {
            reason: nonEmptyString,
            observed_at: { type: "string", format: "date-time" },
          },
          additionalProperties: false,
        },
        basis: {
          type: "object",
          required: ["kind", "evidence_ref"],
          properties: {
            kind: { enum: ["terminal_commit_verified", "operator_attested_native_stop"] },
            evidence_ref: nonEmptyString,
          },
          additionalProperties: false,
        },
        reconciled_at: { type: "string", format: "date-time" },
        authority: {
          type: "object",
          required: ["kind"],
          properties: {
            kind: { const: "local_operator" },
          },
          additionalProperties: false,
        },
        writer: writerEvidence,
      },
      additionalProperties: false,
    },
  ],
};

const ajv = new Ajv2020({
  allErrors: true,
  strict: true,
  validateFormats: true,
});
addFormats(ajv);

export const validateHeaderSchema = ajv.compile(transcriptHeaderSchema);
export const validateExchangeSchema = ajv.compile(transcriptExchangeSchema);
export const validateAcceptanceWalSchema = ajv.compile(acceptanceWalSchema);

export class PersistedValidationError extends Error {
  constructor(code, message, details = undefined) {
    super(message);
    this.name = "PersistedValidationError";
    this.code = code;
    if (details !== undefined) this.details = details;
  }
}

function schemaErrors(validate) {
  return (validate.errors ?? []).map((error) => ({
    instancePath: error.instancePath,
    keyword: error.keyword,
    message: error.message,
    params: error.params,
  }));
}

function assertSchema(validate, value, kind) {
  if (!validate(value)) {
    throw new PersistedValidationError(
      `${kind.toUpperCase()}_SCHEMA_INVALID`,
      `${kind} does not satisfy its persisted JSON Schema`,
      schemaErrors(validate),
    );
  }
  return value;
}

export function sha256Bytes(value) {
  return crypto.createHash("sha256").update(value).digest("hex");
}

export function sha256Utf8(value) {
  return sha256Bytes(Buffer.from(value, "utf8"));
}

export function isContainedRelativeRef(value) {
  if (typeof value !== "string" || value.length === 0 || value.includes("\\")) return false;
  if (path.posix.isAbsolute(value) || /^[A-Za-z]:/.test(value)) return false;
  const parts = value.split("/");
  return parts.every((part) => part !== "" && part !== "." && part !== "..");
}

export function describeRawTrace({
  relativeRef,
  content,
  format,
  adapter,
  applicationId,
  applicationVersion,
  frameCount,
  malformedFrameCount,
}) {
  const bytes = Buffer.isBuffer(content) ? content : Buffer.from(content);
  const descriptor = {
    relative_ref: relativeRef,
    sha256: sha256Bytes(bytes),
    bytes: bytes.length,
    format,
    adapter,
    ...(applicationId ? { application_id: applicationId } : {}),
    ...(applicationVersion ? { application_version: applicationVersion } : {}),
    ...(frameCount !== undefined ? { frame_count: frameCount } : {}),
    ...(malformedFrameCount !== undefined ? { malformed_frame_count: malformedFrameCount } : {}),
  };
  if (!isContainedRelativeRef(relativeRef)) {
    throw new PersistedValidationError("RAW_TRACE_REF_UNSAFE", "raw trace reference must be a contained POSIX-relative path");
  }
  return descriptor;
}

export function assertHeader(header) {
  assertSchema(validateHeaderSchema, header, "header");
  const participantIds = header.participants.map((participant) => participant.participant_id);
  if (new Set(participantIds).size !== participantIds.length) {
    throw new PersistedValidationError("HEADER_PARTICIPANT_DUPLICATE", "participant_id values must be unique");
  }
  return header;
}

function assertSourceMatchesTrace(source, rawTrace, label) {
  if (source.trace_ref !== rawTrace?.relative_ref) {
    throw new PersistedValidationError(
      "EXCHANGE_SOURCE_TRACE_MISMATCH",
      `${label} source does not reference the exchange raw trace`,
    );
  }
  if (source.frame_index !== undefined && rawTrace.frame_count !== undefined
    && source.frame_index >= rawTrace.frame_count) {
    throw new PersistedValidationError(
      "EXCHANGE_SOURCE_COORDINATE_INVALID",
      `${label} frame index falls outside the declared raw trace`,
    );
  }
  if (source.byte_span !== undefined
    && source.byte_span.start + source.byte_span.length > rawTrace.bytes) {
    throw new PersistedValidationError(
      "EXCHANGE_SOURCE_COORDINATE_INVALID",
      `${label} byte span falls outside the declared raw trace`,
    );
  }
}

const DELIVERY_ORDER = new Map([
  ["rendered", 0],
  ["adapter_emitted", 1],
  ["host_acknowledged", 2],
  ["receiver_observed", 3],
  ["model_visible", 4],
]);

export function assertExchange(exchange, header = undefined) {
  assertSchema(validateExchangeSchema, exchange, "exchange");

  const started = Date.parse(exchange.exchange_start);
  const ended = Date.parse(exchange.exchange_end);
  if (ended < started) {
    throw new PersistedValidationError("EXCHANGE_TIME_ORDER", "exchange_end precedes durable acceptance time");
  }

  if (exchange.sender_participant_id === exchange.receiver_participant_id) {
    throw new PersistedValidationError("EXCHANGE_PARTICIPANT_ALIAS", "sender and receiver participant IDs must differ");
  }
  if (header) {
    const participantIds = new Set(header.participants.map((participant) => participant.participant_id));
    for (const participantId of [exchange.sender_participant_id, exchange.receiver_participant_id]) {
      if (!participantIds.has(participantId)) {
        throw new PersistedValidationError(
          "EXCHANGE_PARTICIPANT_UNKNOWN",
          `exchange references unknown participant '${participantId}'`,
        );
      }
    }
  }

  const promptRecords = exchange.records.filter((record) => record._type === "prompt");
  if (promptRecords.length !== 1 || exchange.records[0] !== promptRecords[0]) {
    throw new PersistedValidationError("EXCHANGE_PROMPT_CARDINALITY", "exchange must begin with exactly one ingress prompt");
  }
  if (sha256Utf8(promptRecords[0].text) !== promptRecords[0].content_sha256) {
    throw new PersistedValidationError("EXCHANGE_PROMPT_DIGEST", "ingress prompt digest does not match exact UTF-8 content");
  }

  const recordIds = new Set();
  let lastObserved = started;
  for (const record of exchange.records) {
    if (recordIds.has(record.record_id)) {
      throw new PersistedValidationError("EXCHANGE_RECORD_ID_DUPLICATE", `duplicate record_id '${record.record_id}'`);
    }
    recordIds.add(record.record_id);
    const observed = Date.parse(record.observed_at);
    if (observed < started || observed > ended || observed < lastObserved) {
      throw new PersistedValidationError("EXCHANGE_RECORD_TIME_ORDER", "record observation times must be chronological and within the exchange interval");
    }
    lastObserved = observed;
    if ((record._type === "response") && sha256Utf8(record.text) !== record.content_sha256) {
      throw new PersistedValidationError("EXCHANGE_RESPONSE_DIGEST", `response '${record.record_id}' digest does not match its UTF-8 content`);
    }
  }

  const finalResponses = exchange.records.filter(
    (record) => record._type === "response" && record.phase === "final",
  );
  if (exchange.status === "completed") {
    if (finalResponses.length !== 1) {
      throw new PersistedValidationError("EXCHANGE_FINAL_RESPONSE", "completed exchange requires exactly one final receiver response");
    }
    if (exchange.records.at(-1) !== finalResponses[0]) {
      throw new PersistedValidationError("EXCHANGE_FINAL_RESPONSE_ORDER", "receiver terminal response must be the final normalized record");
    }
    if (exchange.outcome !== undefined) {
      throw new PersistedValidationError("EXCHANGE_COMPLETED_OUTCOME", "completed exchange must not carry a failure outcome");
    }
  } else if (finalResponses.length !== 0) {
    throw new PersistedValidationError("EXCHANGE_FAILED_REPLY", "non-completed exchange must not expose a terminal reply");
  }

  let priorDelivery = -1;
  const deliveryStages = new Set();
  for (const event of exchange.delivery.events) {
    const current = DELIVERY_ORDER.get(event.stage);
    if (deliveryStages.has(event.stage) || current <= priorDelivery) {
      throw new PersistedValidationError("EXCHANGE_DELIVERY_ORDER", "delivery evidence stages must be unique and strictly monotonic");
    }
    if (Date.parse(event.observed_at) < started || Date.parse(event.observed_at) > ended) {
      throw new PersistedValidationError("EXCHANGE_DELIVERY_TIME", "delivery evidence time must fall within the exchange interval");
    }
    if (event.stage === "receiver_observed" && event.evidence.kind !== "native_event") {
      throw new PersistedValidationError("EXCHANGE_RECEIVER_EVIDENCE", "receiver_observed requires native-event evidence");
    }
    if (event.stage === "model_visible" && event.evidence.kind !== "host_receipt") {
      throw new PersistedValidationError("EXCHANGE_MODEL_VISIBLE_EVIDENCE", "model_visible requires an explicit host receipt");
    }
    priorDelivery = current;
    deliveryStages.add(event.stage);
  }
  if (exchange.status === "completed" && !deliveryStages.has("adapter_emitted")) {
    throw new PersistedValidationError("EXCHANGE_DELIVERY_INCOMPLETE", "completed exchange requires adapter emission evidence");
  }

  const traceRef = exchange.trace.raw?.relative_ref;
  if (traceRef && !isContainedRelativeRef(traceRef)) {
    throw new PersistedValidationError("RAW_TRACE_REF_UNSAFE", "raw trace reference must be a contained POSIX-relative path");
  }
  if (exchange.trace.complete && !exchange.trace.raw) {
    throw new PersistedValidationError("EXCHANGE_TRACE_COMPLETE_WITHOUT_RAW", "a complete trace requires a raw trace descriptor");
  }
  if (exchange.trace.complete && exchange.trace.omissions.length > 0) {
    throw new PersistedValidationError("EXCHANGE_TRACE_COMPLETE_WITH_OMISSIONS", "a complete trace cannot also report omissions");
  }
  if (!exchange.trace.complete && exchange.trace.omissions.length === 0) {
    throw new PersistedValidationError("EXCHANGE_TRACE_OMISSION_REQUIRED", "an incomplete trace requires an explicit omission");
  }

  const nativeSources = [];
  if (exchange.application) nativeSources.push([exchange.application.source, "application"]);
  if (exchange.model) nativeSources.push([exchange.model.source, "model"]);
  for (const [side, binding] of Object.entries(exchange.native ?? {})) {
    if (binding.source) nativeSources.push([binding.source, `${side} native binding`]);
  }
  for (const record of exchange.records.slice(1)) nativeSources.push([record.source, `record ${record.record_id}`]);
  if (nativeSources.length > 0 && !traceRef) {
    throw new PersistedValidationError("EXCHANGE_NATIVE_WITHOUT_TRACE", "receiver-native claims require a raw trace descriptor");
  }
  for (const [source, label] of nativeSources) assertSourceMatchesTrace(source, exchange.trace.raw, label);

  if (exchange.trace.raw) {
    const raw = exchange.trace.raw;
    if (raw.frame_count !== undefined && raw.malformed_frame_count !== undefined
      && raw.malformed_frame_count > raw.frame_count) {
      throw new PersistedValidationError(
        "EXCHANGE_TRACE_FRAME_COUNTS",
        "malformed frame count cannot exceed total frame count",
      );
    }
    if (raw.adapter.id !== exchange.adapter.id || raw.adapter.version !== exchange.adapter.version) {
      throw new PersistedValidationError("EXCHANGE_TRACE_ADAPTER_MISMATCH", "raw trace adapter does not match the exchange adapter");
    }
    if (exchange.application && raw.application_id && raw.application_id !== exchange.application.id) {
      throw new PersistedValidationError("EXCHANGE_TRACE_APPLICATION_MISMATCH", "raw trace application does not match observed application");
    }
  }

  return exchange;
}

export function assertAcceptanceWalRow(row) {
  assertSchema(validateAcceptanceWalSchema, row, "acceptance_wal");
  if (row.record_type === "exchange_acceptance") {
    if (sha256Utf8(row.prompt.text) !== row.prompt.sha256) {
      throw new PersistedValidationError("ACCEPTANCE_PROMPT_DIGEST", "acceptance prompt digest does not match exact UTF-8 content");
    }
    if (Buffer.byteLength(row.prompt.text, "utf8") !== row.prompt.bytes) {
      throw new PersistedValidationError("ACCEPTANCE_PROMPT_BYTES", "acceptance prompt byte count does not match exact UTF-8 content");
    }
    if (row.sender_participant_id === row.receiver_participant_id) {
      throw new PersistedValidationError("ACCEPTANCE_PARTICIPANT_ALIAS", "sender and receiver participant IDs must differ");
    }
  } else if (row.record_type === "exchange_terminal_marker" && row.recovery) {
    if (row.recovery.observed_at !== row.terminal_at) {
      throw new PersistedValidationError(
        "TERMINAL_MARKER_RECOVERY_TIME",
        "missing-marker recovery observation must equal the repaired terminal marker time",
      );
    }
  } else if (row.record_type === "conversation_reconciliation") {
    if (row.basis.evidence_ref.trim().length === 0) {
      throw new PersistedValidationError(
        "RECONCILIATION_EVIDENCE_REQUIRED",
        "quarantine reconciliation requires a non-blank evidence reference",
      );
    }
    if (Date.parse(row.reconciled_at) < Date.parse(row.expected.observed_at)) {
      throw new PersistedValidationError(
        "RECONCILIATION_TIME_ORDER",
        "reconciliation time precedes the quarantine observation",
      );
    }
  }
  return row;
}
