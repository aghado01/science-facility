import { createHash } from "node:crypto";

const TERMINAL_STATUSES = new Set(["completed", "failed", "interrupted", "timeout"]);
const COMMIT_KEYS = new Set([
  "acceptance",
  "status",
  "exchangeEnd",
  "application",
  "model",
  "native",
  "outcome",
  "trace",
  "delivery",
  "records",
  "extensions",
]);
const RECEIPT_KEYS = new Set(["acceptance", "exchange"]);
const COMPLETED_RESULT_KEYS = new Set(["acceptance", "exchange", "egress"]);
const EGRESS_KEYS = new Set(["stage", "observed_at", "reply_sha256"]);

export class ExchangeAssemblyError extends Error {
  constructor(code, message, { details, receipt } = {}) {
    super(message);
    this.name = "ExchangeAssemblyError";
    this.code = code;
    if (details !== undefined) this.details = details;
    if (receipt !== undefined) this.receipt = receipt;
  }
}

function fail(code, message, details = undefined) {
  throw new ExchangeAssemblyError(code, message, { details });
}

function assertExactKeys(value, allowed, label) {
  const unknown = Object.keys(value).filter((key) => !allowed.has(key));
  if (unknown.length > 0) {
    fail("ASSEMBLY_UNKNOWN_FIELD", `${label} contains unknown fields: ${unknown.join(", ")}`);
  }
}

function assertObject(value, label) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    fail("ASSEMBLY_INVALID_INPUT", `${label} must be an object`);
  }
  return value;
}

function assertNonEmptyString(value, label) {
  if (typeof value !== "string" || value.length === 0) {
    fail("ASSEMBLY_INVALID_INPUT", `${label} must be a non-empty string`);
  }
  return value;
}

function parseDateTime(value, label) {
  assertNonEmptyString(value, label);
  const time = Date.parse(value);
  if (!Number.isFinite(time)) fail("ASSEMBLY_INVALID_TIME", `${label} must be an ISO date-time`);
  return time;
}

function sha256Utf8(value) {
  return createHash("sha256").update(Buffer.from(value, "utf8")).digest("hex");
}

function clone(value) {
  return structuredClone(value);
}

function validateAcceptance(acceptance) {
  assertObject(acceptance, "acceptance");
  assertNonEmptyString(acceptance.exchange_id, "acceptance.exchange_id");
  parseDateTime(acceptance.accepted_at, "acceptance.accepted_at");
  assertObject(acceptance.prompt, "acceptance.prompt");
  assertNonEmptyString(acceptance.prompt.sha256, "acceptance.prompt.sha256");
  if (!Number.isSafeInteger(acceptance.prompt.bytes) || acceptance.prompt.bytes < 0) {
    fail("ASSEMBLY_INVALID_INPUT", "acceptance.prompt.bytes must be a non-negative safe integer");
  }
  return acceptance;
}

function validateLiveObservation(observation, label) {
  if (observation === undefined) return;
  assertObject(observation, label);
  assertNonEmptyString(observation.id, `${label}.id`);
  assertObject(observation.source, `${label}.source`);
  if (observation.source.kind !== "receiver_native") {
    fail("ASSEMBLY_PROVENANCE_INVALID", `${label} must be bound to receiver-native evidence`);
  }
  assertNonEmptyString(observation.source.trace_ref, `${label}.source.trace_ref`);
}

function validateRecords(records, status) {
  if (!Array.isArray(records)) fail("ASSEMBLY_INVALID_RECORDS", "records must be an array");
  if (records.some((record) => !record || typeof record !== "object" || Array.isArray(record))) {
    fail("ASSEMBLY_INVALID_RECORDS", "records must contain objects only");
  }
  if (records.some((record) => record._type === "prompt")) {
    fail(
      "ASSEMBLY_INGRESS_OWNERSHIP",
      "records must contain receiver-derived records only; TranscriptStore owns the accepted ingress prompt",
    );
  }

  const finalResponses = records.filter(
    (record) => record._type === "response" && record.phase === "final",
  );
  if (status === "completed") {
    if (finalResponses.length !== 1 || records.at(-1) !== finalResponses[0]) {
      fail(
        "ASSEMBLY_TERMINAL_REPLY_REQUIRED",
        "completed assembly requires exactly one final receiver response as the last normalized record",
      );
    }
    const final = finalResponses[0];
    if (typeof final.text !== "string" || final.content_sha256 !== sha256Utf8(final.text)) {
      fail("ASSEMBLY_TERMINAL_REPLY_INVALID", "final receiver response text and digest do not agree");
    }
    if (final.source?.kind !== "receiver_native") {
      fail("ASSEMBLY_TERMINAL_REPLY_INVALID", "final receiver response must carry receiver-native evidence");
    }
  } else if (finalResponses.length !== 0) {
    fail("ASSEMBLY_NONCOMPLETED_REPLY", "non-completed assembly cannot expose a final receiver reply");
  }
}

function validateTrace(trace, status) {
  assertObject(trace, "trace");
  if (typeof trace.complete !== "boolean" || !Array.isArray(trace.omissions)) {
    fail("ASSEMBLY_TRACE_INVALID", "trace must declare complete and omissions");
  }
  if (status === "completed" && (!trace.complete || !trace.raw)) {
    fail("ASSEMBLY_TRACE_INVALID", "completed assembly requires a complete durable raw trace descriptor");
  }
}

function validateDelivery(delivery, status) {
  assertObject(delivery, "delivery");
  if (!Array.isArray(delivery.events)) {
    fail("ASSEMBLY_DELIVERY_INVALID", "delivery.events must be an array");
  }
  if (Object.hasOwn(delivery, "egress")) {
    fail(
      "ASSEMBLY_DELIVERY_INVALID",
      "durable delivery cannot contain return-only MCP egress evidence",
    );
  }
  const stages = delivery.events.map((event) => event?.stage);
  if (status === "completed" && !stages.includes("adapter_emitted")) {
    fail("ASSEMBLY_DELIVERY_INVALID", "completed assembly requires adapter emission evidence");
  }
}

function validateEgress(egress, exchange) {
  assertObject(egress, "egress");
  assertExactKeys(egress, EGRESS_KEYS, "egress");
  if (egress.stage !== "constructed") {
    fail("ASSEMBLY_EGRESS_INVALID", "completed result egress stage must be constructed");
  }
  const observed = parseDateTime(egress.observed_at, "egress.observed_at");
  const terminal = parseDateTime(exchange.exchange_end, "exchange.exchange_end");
  if (observed < terminal) {
    fail("ASSEMBLY_EGRESS_TIME", "result egress construction cannot precede the terminal exchange");
  }
  const final = exchange.records.at(-1);
  if (egress.reply_sha256 !== final.content_sha256) {
    fail("ASSEMBLY_EGRESS_DIGEST", "result egress digest differs from receiver terminal reply");
  }
}

function validateOutcome(outcome, status) {
  if (status === "completed") {
    if (outcome !== undefined) fail("ASSEMBLY_COMPLETED_OUTCOME", "completed assembly cannot carry a failure outcome");
    return;
  }
  assertObject(outcome, "outcome");
  assertNonEmptyString(outcome.code, "outcome.code");
  if (typeof outcome.retryable !== "boolean" || typeof outcome.native_stop_confirmed !== "boolean") {
    fail(
      "ASSEMBLY_OUTCOME_INVALID",
      "non-completed outcome must declare retryable and native_stop_confirmed",
    );
  }
}

function validateTerminalExchange(acceptance, exchange) {
  assertObject(exchange, "exchange");
  if (exchange.exchange_id !== acceptance.exchange_id) {
    fail("ASSEMBLY_ACCEPTANCE_MISMATCH", "terminal exchange does not match its durable acceptance");
  }
  if (!TERMINAL_STATUSES.has(exchange.status)) {
    fail("ASSEMBLY_INVALID_STATUS", `unsupported terminal status '${exchange.status}'`);
  }
  if (!Number.isSafeInteger(exchange.exchange_index) || exchange.exchange_index < 0) {
    fail("ASSEMBLY_INVALID_INPUT", "exchange.exchange_index must be assigned by TranscriptStore");
  }
  const started = parseDateTime(exchange.exchange_start, "exchange.exchange_start");
  const ended = parseDateTime(exchange.exchange_end, "exchange.exchange_end");
  if (ended < started) fail("ASSEMBLY_INVALID_TIME", "exchange.exchange_end precedes exchange.exchange_start");
  if (!Array.isArray(exchange.records) || exchange.records[0]?._type !== "prompt") {
    fail("ASSEMBLY_INGRESS_OWNERSHIP", "committed exchange must begin with the store-owned ingress prompt");
  }
  if (
    exchange.records[0].content_sha256 !== acceptance.prompt.sha256
    || Buffer.byteLength(exchange.records[0].text ?? "", "utf8") !== acceptance.prompt.bytes
  ) {
    fail("ASSEMBLY_ACCEPTANCE_MISMATCH", "committed ingress prompt differs from durable acceptance");
  }
  validateRecords(exchange.records.slice(1), exchange.status);
  validateTrace(exchange.trace, exchange.status);
  validateDelivery(exchange.delivery, exchange.status);
  validateOutcome(exchange.outcome, exchange.status);
  validateLiveObservation(exchange.application, "exchange.application");
  validateLiveObservation(exchange.model, "exchange.model");
}

function compactTrace(trace) {
  return {
    complete: trace.complete,
    ...(trace.raw ? {
      ref: trace.raw.relative_ref,
      sha256: trace.raw.sha256,
      bytes: trace.raw.bytes,
      frame_count: trace.raw.frame_count ?? null,
      malformed_frame_count: trace.raw.malformed_frame_count ?? null,
    } : {}),
    omission_codes: trace.omissions.map((omission) => omission.code),
  };
}

/**
 * Pure projection boundary for a terminal mediated exchange.
 *
 * This class performs no I/O, allocates no identity or index, reads no clock,
 * invokes no adapter, and does not infer provenance. TranscriptStore owns the
 * accepted prompt and terminal index; MediatedTurnService owns orchestration;
 * ApplicationAdapter owns receiver-native projection.
 */
export class ExchangeAssembler {
  assembleCommit(input) {
    assertObject(input, "assembly input");
    assertExactKeys(input, COMMIT_KEYS, "assembly input");
    const {
      acceptance,
      status,
      exchangeEnd,
      application,
      model,
      native,
      outcome,
      trace,
      delivery,
      records,
      extensions,
    } = input;

    validateAcceptance(acceptance);
    if (!TERMINAL_STATUSES.has(status)) {
      fail("ASSEMBLY_INVALID_STATUS", `unsupported terminal status '${status}'`);
    }
    const accepted = parseDateTime(acceptance.accepted_at, "acceptance.accepted_at");
    const ended = parseDateTime(exchangeEnd, "exchangeEnd");
    if (ended < accepted) fail("ASSEMBLY_INVALID_TIME", "exchangeEnd precedes durable acceptance");
    validateLiveObservation(application, "application");
    validateLiveObservation(model, "model");
    validateRecords(records, status);
    validateTrace(trace, status);
    validateDelivery(delivery, status);
    validateOutcome(outcome, status);

    if (
      application !== undefined
      && acceptance.selected_application_id !== undefined
      && application.id !== acceptance.selected_application_id
    ) {
      fail("ASSEMBLY_APPLICATION_MISMATCH", "live application differs from the selected adapter application");
    }

    return clone({
      exchange_id: acceptance.exchange_id,
      status,
      exchange_end: exchangeEnd,
      ...(application !== undefined ? { application } : {}),
      ...(model !== undefined ? { model } : {}),
      ...(native !== undefined ? { native } : {}),
      ...(outcome !== undefined ? { outcome } : {}),
      trace,
      delivery,
      records,
      ...(extensions !== undefined ? { extensions } : {}),
    });
  }

  assembleReceipt(input) {
    assertObject(input, "receipt input");
    assertExactKeys(input, RECEIPT_KEYS, "receipt input");
    const { acceptance, exchange } = input;
    validateAcceptance(acceptance);
    validateTerminalExchange(acceptance, exchange);

    const receipt = {
      exchange_id: exchange.exchange_id,
      exchange_index: exchange.exchange_index,
      status: exchange.status,
      duration_ms: Date.parse(exchange.exchange_end) - Date.parse(exchange.exchange_start),
      prompt: {
        sha256: acceptance.prompt.sha256,
        bytes: acceptance.prompt.bytes,
      },
      ...(exchange.application ? { application: exchange.application } : {}),
      ...(exchange.model ? { model: exchange.model } : {}),
      ...(exchange.native ? { native: exchange.native } : {}),
      trace: compactTrace(exchange.trace),
      delivery_stages: exchange.delivery.events.map((event) => event.stage),
      records_count: exchange.records.length,
      ...(exchange.status !== "completed" ? { outcome: exchange.outcome } : {}),
    };

    if (exchange.status === "completed") {
      const final = exchange.records.at(-1);
      receipt.reply = {
        sha256: final.content_sha256,
        bytes: Buffer.byteLength(final.text, "utf8"),
      };
    }
    return clone(receipt);
  }

  assembleCompletedResult(input) {
    assertObject(input, "completed result input");
    assertExactKeys(input, COMPLETED_RESULT_KEYS, "completed result input");
    const { acceptance, exchange, egress } = input;
    const receipt = this.assembleReceipt({ acceptance, exchange });
    if (exchange.status !== "completed") {
      throw new ExchangeAssemblyError(
        "ASSEMBLY_NONCOMPLETED_RESULT",
        "only a completed terminal exchange can expose a receiver reply",
        { receipt },
      );
    }
    validateEgress(egress, exchange);
    receipt.egress = clone(egress);
    return {
      reply: exchange.records.at(-1).text,
      receipt,
    };
  }
}
