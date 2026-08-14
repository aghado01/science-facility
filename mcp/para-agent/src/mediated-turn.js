import { createHash } from "node:crypto";
import { isDeepStrictEqual, TextDecoder } from "node:util";

import { ExchangeAssembler } from "./assembler.js";
import { ConversationGate } from "./conversation-gate.js";
import { AMBIGUOUS_COMMIT_QUARANTINE_REASON } from "./quarantine-contract.js";
import { isWellFormedUnicode } from "./identity.js";
import { deriveConversationKey } from "./quarantine-reconciliation.js";

const UTF8_FATAL = new TextDecoder("utf-8", { fatal: true });
const REQUEST_KEYS = new Set([
  "handle",
  "application",
  "prompt",
  "timeoutMs",
  "signal",
  "requestId",
]);

export class MediatedTurnError extends Error {
  constructor(code, message, { receipt, cause, details } = {}) {
    super(message, cause ? { cause } : undefined);
    this.name = "MediatedTurnError";
    this.code = code;
    if (receipt !== undefined) this.receipt = receipt;
    if (details !== undefined) this.details = details;
  }
}

function sha256(value) {
  return createHash("sha256").update(value).digest("hex");
}

function nonEmpty(value, label) {
  if (typeof value !== "string" || value.length === 0) {
    throw new MediatedTurnError("DELEGATE_INVALID_REQUEST", `${label} must be a non-empty string`);
  }
  return value;
}

function thrownMessage(value, fallback) {
  if (typeof value?.message === "string" && value.message.length > 0) return value.message;
  if (typeof value === "string" && value.length > 0) return value;
  try {
    const serialized = JSON.stringify(value);
    if (typeof serialized === "string" && serialized.length > 0) return serialized;
  } catch {}
  const rendered = String(value ?? "");
  return rendered.length > 0 ? rendered : fallback;
}

function validateRequest(request) {
  if (!request || typeof request !== "object" || Array.isArray(request)) {
    throw new MediatedTurnError("DELEGATE_INVALID_REQUEST", "delegate request must be an object");
  }
  const unknown = Object.keys(request).filter((key) => !REQUEST_KEYS.has(key));
  if (unknown.length > 0) {
    throw new MediatedTurnError("DELEGATE_INVALID_REQUEST", `unknown delegate fields: ${unknown.join(", ")}`);
  }
  let conversationKey;
  try {
    conversationKey = deriveConversationKey({
      application: request.application,
      handle: request.handle,
    });
  } catch (error) {
    throw new MediatedTurnError(
      "DELEGATE_INVALID_REQUEST",
      thrownMessage(error, "application and handle must identify one canonical conversation lane"),
      { cause: error },
    );
  }
  if (typeof request.prompt !== "string" || !isWellFormedUnicode(request.prompt)) {
    throw new MediatedTurnError("DELEGATE_INVALID_REQUEST", "prompt must be one well-formed Unicode string");
  }
  if (request.timeoutMs !== undefined && (!Number.isSafeInteger(request.timeoutMs) || request.timeoutMs <= 0)) {
    throw new MediatedTurnError("DELEGATE_INVALID_REQUEST", "timeoutMs must be a positive safe integer");
  }
  if (request.requestId !== undefined) nonEmpty(request.requestId, "requestId");
  if (request.signal?.aborted) {
    throw new MediatedTurnError("DELEGATE_CANCELLED_BEFORE_ACCEPTANCE", "delegate request was cancelled before durable acceptance");
  }
  return conversationKey;
}

function nowIso(clock) {
  const value = clock();
  const date = value instanceof Date ? value : new Date(value);
  if (!Number.isFinite(date.getTime())) {
    throw new MediatedTurnError("DELEGATE_CLOCK_INVALID", "clock must return a valid date-time");
  }
  return date.toISOString();
}

function nowIsoAtOrAfter(clock, floor) {
  const floorTime = Date.parse(floor);
  if (!Number.isFinite(floorTime)) {
    throw new MediatedTurnError(
      "TRANSCRIPT_COMMIT_RECEIPT_INVALID",
      "terminal marker time is not a valid date-time",
    );
  }
  const observed = nowIso(clock);
  return Date.parse(observed) < floorTime ? new Date(floorTime).toISOString() : observed;
}

function validateCommitResult(value, acceptance, intended) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new MediatedTurnError(
      "TRANSCRIPT_COMMIT_RECEIPT_INVALID",
      "commitExchange() did not return a terminal exchange and marker",
    );
  }
  const { exchange, marker } = value;
  const exchangeDigest = exchange && typeof exchange === "object"
    ? sha256(Buffer.from(JSON.stringify(exchange), "utf8"))
    : null;
  const returnedPayload = exchange && typeof exchange === "object" && Array.isArray(exchange.records)
    ? {
        exchange_id: exchange.exchange_id,
        status: exchange.status,
        exchange_end: exchange.exchange_end,
        ...(Object.hasOwn(exchange, "application") ? { application: exchange.application } : {}),
        ...(Object.hasOwn(exchange, "model") ? { model: exchange.model } : {}),
        ...(Object.hasOwn(exchange, "native") ? { native: exchange.native } : {}),
        ...(Object.hasOwn(exchange, "outcome") ? { outcome: exchange.outcome } : {}),
        trace: exchange.trace,
        delivery: exchange.delivery,
        records: exchange.records.slice(1),
        ...(Object.hasOwn(exchange, "extensions") ? { extensions: exchange.extensions } : {}),
      }
    : null;
  const prompt = exchange?.records?.[0];
  if (
    !exchange
    || typeof exchange !== "object"
    || Array.isArray(exchange)
    || !marker
    || typeof marker !== "object"
    || Array.isArray(marker)
    || exchange.exchange_id !== acceptance.exchange_id
    || !Number.isSafeInteger(exchange.exchange_index)
    || exchange.exchange_index < 0
    || exchange.exchange_start !== acceptance.accepted_at
    || exchange.sender_participant_id !== acceptance.sender_participant_id
    || exchange.receiver_participant_id !== acceptance.receiver_participant_id
    || !isDeepStrictEqual(exchange.adapter, acceptance.adapter)
    || exchange.request_id !== acceptance.request_id
    || exchange.idempotency_key !== acceptance.idempotency_key
    || prompt?._type !== "prompt"
    || prompt.record_id !== acceptance.prompt?.record_id
    || prompt.observed_at !== acceptance.accepted_at
    || prompt.text !== acceptance.prompt?.text
    || prompt.content_sha256 !== acceptance.prompt?.sha256
    || !isDeepStrictEqual(returnedPayload, intended)
    || marker.record_type !== "exchange_terminal_marker"
    || marker.exchange_id !== exchange.exchange_id
    || marker.exchange_index !== exchange.exchange_index
    || marker.terminal_status !== exchange.status
    || marker.exchange_sha256 !== exchangeDigest
    || !Number.isFinite(Date.parse(exchange.exchange_end))
    || !Number.isFinite(Date.parse(marker.terminal_at))
    || Date.parse(marker.terminal_at) < Date.parse(exchange.exchange_end)
  ) {
    throw new MediatedTurnError(
      "TRANSCRIPT_COMMIT_RECEIPT_INVALID",
      "commitExchange() returned terminal evidence that is not bound to the accepted exchange",
    );
  }
  return { exchange, marker };
}

function adapterBinding(profile) {
  return {
    ...profile.adapter,
    profile_id: profile.profile_id,
  };
}

function recordId(exchangeId, sourceRef, kind) {
  const locator = sourceRef.frame_index !== undefined
    ? `frame:${sourceRef.frame_index}`
    : `span:${sourceRef.byte_span.start}:${sourceRef.byte_span.length}`;
  return `rec-${sha256(Buffer.from(`${exchangeId}|${locator}|${kind}`, "utf8"))}`;
}

function sourceLocator(sourceRef) {
  if (sourceRef.frame_index !== undefined) {
    return `${sourceRef.trace_ref}#frame=${sourceRef.frame_index}`;
  }
  return `${sourceRef.trace_ref}#bytes=${sourceRef.byte_span.start}:${sourceRef.byte_span.length}`;
}

function canonicalRecord(exchangeId, projection) {
  const record = projection.record;
  if (!record || record._type === "prompt_echo") return null;
  const base = {
    _type: record._type,
    record_id: recordId(exchangeId, projection.source_ref, record._type),
    observed_at: record.observed_at,
    ...(record.native_timestamp ? { native_timestamp: record.native_timestamp } : {}),
    source: projection.source_ref,
  };

  switch (record._type) {
    case "thinking":
      return { ...base, text: record.text };
    case "tool_call":
      return {
        ...base,
        tool_use_id: record.tool_use_id,
        tool_name: record.tool_name,
        ...(record.tool_kind ? { tool_kind: record.tool_kind } : {}),
        status: record.status ?? "running",
        input: record.input,
      };
    case "tool_result":
      return {
        ...base,
        tool_use_id: record.tool_use_id,
        status: record.status ?? "completed",
        result: record.result,
      };
    case "response":
      return {
        ...base,
        phase: "partial",
        text: record.text,
        content_sha256: sha256(Buffer.from(record.text, "utf8")),
      };
    default:
      throw new MediatedTurnError("NATIVE_RECORD_UNSUPPORTED", `adapter projected unsupported record kind '${record._type}'`);
  }
}

function bindObservation(current, candidate, label) {
  if (!candidate) return current;
  if (!current) return candidate;
  for (const key of Object.keys(candidate).filter((key) => key !== "source")) {
    if (current[key] !== undefined && current[key] !== candidate[key]) {
      throw new MediatedTurnError(
        "NATIVE_PROVENANCE_CONFLICT",
        `conflicting live ${label}.${key} observations`,
      );
    }
  }
  if (candidate.display_name && !current.display_name) return candidate;
  if (candidate.version && !current.version) return candidate;
  return current;
}

function enrichFinalResponse(records, terminalProjection, reply) {
  const result = records.map((record) => ({ ...record }));
  if (terminalProjection.terminal.reply_source.strategy === "latest_record") {
    const index = result.findLastIndex((record) => record._type === "response");
    if (index < 0 || result[index].text !== reply) {
      throw new MediatedTurnError("NATIVE_TERMINAL_REPLY_UNBOUND", "terminal reply is not bound to the projected response record");
    }
    result[index] = { ...result[index], phase: "final" };
    return result;
  }

  result.push({
    _type: "response",
    record_id: recordId(terminalProjection.mediation.exchange_id, terminalProjection.source_ref, "response-final"),
    observed_at: terminalProjection.observed_at,
    ...(terminalProjection.provenance.native_timestamp
      ? { native_timestamp: terminalProjection.provenance.native_timestamp }
      : {}),
    phase: "final",
    text: reply,
    content_sha256: sha256(Buffer.from(reply, "utf8")),
    source: terminalProjection.source_ref,
  });
  return result;
}

function nativeStopConfirmed(result, invocationStarted) {
  if (!invocationStarted) return true;
  if (!result) return false;
  if (result.spawned === false) return true;
  if (result.termination?.requested) return result.termination.closedAfterRequest === true;
  return result.termination?.closed === true;
}

function rawCaptureOmissions(result, invocationStarted, forwardedStdoutBytes) {
  const omissions = [];
  if (!invocationStarted || result?.spawned !== true) {
    omissions.push({ code: "RAW_NATIVE_NOT_SPAWNED", detail: "no receiver-native process produced a capturable stream" });
  }
  if (result?.spawned === true && result?.termination?.closed !== true) {
    omissions.push({ code: "RAW_NATIVE_CLOSE_UNCONFIRMED", detail: "receiver-native process closure was not observed" });
  }
  if (result?.outcome === "callback_failed") {
    omissions.push({ code: "RAW_TRACE_CALLBACK_FAILED", detail: "raw stdout forwarding failed before capture completed" });
  }
  const observed = result?.output?.stdoutBytes;
  if (
    result?.spawned === true &&
    (!Number.isSafeInteger(observed) || observed < 0 || observed !== forwardedStdoutBytes)
  ) {
    omissions.push({
      code: "RAW_STDOUT_BYTE_MISMATCH",
      detail: `native transport observed ${String(observed)} stdout bytes but raw framing received ${forwardedStdoutBytes}`,
    });
  }
  return omissions;
}

function transportFault(result) {
  switch (result?.outcome) {
    case "timeout":
      return { status: "timeout", code: "NATIVE_TRANSPORT_TIMEOUT", message: "native client exceeded the mediation deadline", retryable: true };
    case "cancelled":
      return { status: "interrupted", code: "NATIVE_TRANSPORT_CANCELLED", message: "native client transport was cancelled", retryable: true };
    case "spawn_failed":
      return { status: "failed", code: "NATIVE_TRANSPORT_SPAWN_FAILED", message: result.error?.message ?? "native client could not be started", retryable: true };
    case "write_failed":
      return { status: "failed", code: "NATIVE_TRANSPORT_WRITE_FAILED", message: result.error?.message ?? "native prompt write failed", retryable: true };
    case "nonzero":
      return { status: "failed", code: "NATIVE_TRANSPORT_NONZERO", message: `native client exited with code ${result.exitCode}`, retryable: false };
    case "max_buffer":
      return { status: "failed", code: "NATIVE_TRANSPORT_MAX_BUFFER", message: "native client exceeded the bounded output limit", retryable: true };
    case "callback_failed":
      return { status: "failed", code: "NATIVE_TRACE_CALLBACK_FAILED", message: result.error?.message ?? "native trace callback failed", retryable: true };
    case "completed":
      return null;
    default:
      return { status: "failed", code: "NATIVE_TRANSPORT_INVALID_OUTCOME", message: `unknown native transport outcome '${result?.outcome}'`, retryable: false };
  }
}

function terminalFault(status) {
  return {
    status,
    code: `NATIVE_TERMINAL_${status.toUpperCase()}`,
    message: `receiver-native terminal event reported '${status}'`,
    retryable: status === "timeout" || status === "interrupted",
  };
}

class JsonlFrames {
  constructor({ sink, clock }) {
    this.sink = sink;
    this.clock = clock;
    this.pending = Buffer.alloc(0);
    this.frames = [];
    this.totalBytes = 0;
  }

  push(chunk) {
    if (!Buffer.isBuffer(chunk)) throw new TypeError("native stdout callback must supply a Buffer");
    this.totalBytes += chunk.length;
    this.pending = this.pending.length === 0
      ? Buffer.from(chunk)
      : Buffer.concat([this.pending, chunk]);
    let newline;
    while ((newline = this.pending.indexOf(0x0a)) >= 0) {
      const frame = this.pending.subarray(0, newline + 1);
      this.pending = Buffer.from(this.pending.subarray(newline + 1));
      this.#stage(frame);
    }
  }

  flush() {
    if (this.pending.length > 0) {
      this.#stage(this.pending);
      this.pending = Buffer.alloc(0);
    }
  }

  #stage(bytes) {
    let content = bytes;
    if (content.at(-1) === 0x0a) content = content.subarray(0, -1);
    if (content.at(-1) === 0x0d) content = content.subarray(0, -1);
    let event = null;
    let parseError = null;
    try {
      const text = UTF8_FATAL.decode(content);
      event = JSON.parse(text);
    } catch (error) {
      parseError = error;
    }
    const observedAt = nowIso(this.clock);
    const source = this.sink.appendFrame(Buffer.from(bytes), { malformed: Boolean(parseError) });
    this.frames.push({ event, parseError, observedAt, source });
  }

  async materialize() {
    const result = [];
    for (const frame of this.frames) {
      result.push({ ...frame, source: await frame.source });
    }
    return result;
  }
}

/**
 * Dependency-injected application service for one mediated Primary-to-Para turn.
 *
 * traceSinkFactory receives
 * `{ handle, application, profile, adapter, conversationKey, exchangeId, store }`
 * and returns a sink implementing async `init()`, `appendFrame(Buffer, options)`,
 * and async `finalize({ complete, omissions })`.
 */
export class MediatedTurnService {
  constructor({
    adapterEngine,
    storeForHandle,
    nativeClient,
    traceSinkFactory,
    assembler = new ExchangeAssembler(),
    gate = new ConversationGate(),
    clock = () => new Date(),
  } = {}) {
    if (!adapterEngine || typeof adapterEngine.getAdapter !== "function" || typeof adapterEngine.renderPrompt !== "function") {
      throw new TypeError("adapterEngine must implement the AdapterEngine application API");
    }
    if (typeof storeForHandle !== "function") throw new TypeError("storeForHandle must be a function");
    if (!nativeClient || typeof nativeClient.run !== "function") throw new TypeError("nativeClient must implement run()");
    if (typeof traceSinkFactory !== "function") throw new TypeError("traceSinkFactory must be a function");
    if (
      !assembler ||
      typeof assembler.assembleCommit !== "function" ||
      typeof assembler.assembleReceipt !== "function" ||
      typeof assembler.assembleCompletedResult !== "function"
    ) {
      throw new TypeError("assembler must implement the ExchangeAssembler projection API");
    }
    if (!gate || typeof gate.acquire !== "function" || typeof gate.restoreQuarantine !== "function") {
      throw new TypeError("gate must implement acquire() and restoreQuarantine()");
    }
    if (typeof clock !== "function") throw new TypeError("clock must be a function");
    this.adapterEngine = adapterEngine;
    this.storeForHandle = storeForHandle;
    this.nativeClient = nativeClient;
    this.traceSinkFactory = traceSinkFactory;
    this.assembler = assembler;
    this.fallbackAssembler = new ExchangeAssembler();
    this.gate = gate;
    this.clock = clock;
    this.recoveryStores = new WeakSet();
  }

  async delegate(request) {
    const key = validateRequest(request);
    const { handle, application, prompt, timeoutMs, signal, requestId } = request;
    const profile = this.adapterEngine.assertCapability(application, "terminal_events");
    this.adapterEngine.assertCapability(application, "prompt_delivery");
    if (!Array.isArray(profile.transport.command) || profile.transport.command.length === 0) {
      throw new MediatedTurnError("ADAPTER_COMMAND_INVALID", "verified adapter profile has no transport command");
    }

    const store = await this.storeForHandle(handle);
    if (!store || typeof store.acceptExchange !== "function" || typeof store.commitExchange !== "function") {
      throw new MediatedTurnError("TRANSCRIPT_STORE_INVALID", "storeForHandle returned an incompatible store");
    }

    if (typeof store.getRecoveryNotices === "function" && !this.recoveryStores.has(store)) {
      const notices = store.getRecoveryNotices();
      if (!Array.isArray(notices)) {
        throw new MediatedTurnError("TRANSCRIPT_STORE_INVALID", "getRecoveryNotices() must return an array");
      }
      for (const notice of notices) {
        this.gate.restoreQuarantine(notice.conversation_key, {
          exchangeId: notice.exchange_id,
          reason: notice.reason,
          observedAt: notice.observed_at,
        });
      }
      this.recoveryStores.add(store);
    }

    const gateLease = this.gate.acquire(key);
    const adapter = adapterBinding(profile);
    let acceptance;
    try {
      acceptance = await store.acceptExchange({
        prompt,
        senderParticipantId: "primary",
        receiverParticipantId: "para",
        conversationKey: key,
        adapter,
        requestId,
        selectedApplicationId: application,
      });
    } catch (error) {
      gateLease.release();
      throw error;
    }

    let sink = null;
    let frames = null;
    let nativeResult = null;
    let invocationStarted = false;
    let rendered = null;
    let terminalProjection = null;
    let projectedRecords = [];
    let applicationObservation = null;
    let modelObservation = null;
    let bestNativeObservation = null;
    let fault = null;
    let reply = null;
    const deliveryEvents = [];

    try {
      gateLease.bindExchangeId(acceptance.exchange_id);
      sink = await this.traceSinkFactory({
        handle,
        application,
        profile,
        adapter,
        conversationKey: key,
        exchangeId: acceptance.exchange_id,
        store,
      });
      if (!sink || typeof sink.init !== "function" || typeof sink.appendFrame !== "function" || typeof sink.finalize !== "function") {
        throw new MediatedTurnError("RAW_TRACE_SINK_INVALID", "traceSinkFactory returned an incompatible sink");
      }
      await sink.init();
      frames = new JsonlFrames({ sink, clock: this.clock });

      rendered = this.adapterEngine.renderPrompt(application, {
        prompt,
        exchangeId: acceptance.exchange_id,
        conversationKey: key,
      });
      if (!Buffer.isBuffer(rendered.bytes)) {
        throw new MediatedTurnError("ADAPTER_RENDER_INVALID", "adapter render must return Buffer bytes");
      }
      const renderedText = UTF8_FATAL.decode(rendered.bytes);
      if (!Buffer.from(renderedText, "utf8").equals(rendered.bytes)) {
        throw new MediatedTurnError("ADAPTER_RENDER_INVALID", "adapter render is not exact UTF-8");
      }
      deliveryEvents.push({
        stage: "rendered",
        observed_at: nowIso(this.clock),
        evidence: { kind: "adapter_receipt", ref: `adapter:${profile.profile_id}:render:${acceptance.exchange_id}` },
      });

      invocationStarted = true;
      nativeResult = await this.nativeClient.run({
        executable: rendered.command[0],
        args: rendered.command.slice(1),
        prompt: renderedText,
        timeoutMs,
        signal,
        onStdout: (chunk) => frames.push(chunk),
      });
      frames.flush();
      const emissionTimestamp = nativeResult?.prompt?.writeCompletedAt;
      const emissionConfirmed = nativeResult?.prompt?.writeCompleted === true
        && nativeResult.prompt.bytes === rendered.bytes.length
        && typeof emissionTimestamp === "string"
        && Number.isFinite(Date.parse(emissionTimestamp));
      if (emissionConfirmed) {
        deliveryEvents.push({
          stage: "adapter_emitted",
          observed_at: emissionTimestamp,
          evidence: { kind: "adapter_receipt", ref: `transport:${acceptance.exchange_id}:stdin` },
        });
      }

      fault = transportFault(nativeResult);
      if (!fault && !deliveryEvents.some((event) => event.stage === "adapter_emitted")) {
        fault = {
          status: "failed",
          code: "PROMPT_EMISSION_UNCONFIRMED",
          message: "native transport completed without confirming exact prompt emission",
          retryable: true,
        };
      }
      if (!fault) {
        const materialized = await frames.materialize();
        for (const frame of materialized) {
          if (frame.parseError) {
            fault = {
              status: "failed",
              code: "NATIVE_FRAME_MALFORMED",
              message: "receiver-native stdout contains malformed JSONL",
              retryable: false,
            };
            break;
          }

          let projection;
          try {
            projection = this.adapterEngine.projectEvent(application, frame.event, {
              exchangeId: acceptance.exchange_id,
              conversationKey: key,
              ...(bestNativeObservation?.conversation_id
                ? { nativeConversationId: bestNativeObservation.conversation_id }
                : {}),
              ...(bestNativeObservation?.turn_id ? { nativeTurnId: bestNativeObservation.turn_id } : {}),
              observedAt: frame.observedAt,
              rawRef: frame.source,
            });
          } catch (error) {
            fault = {
              status: "failed",
              code: error?.code ?? "NATIVE_EVENT_PROJECTION_FAILED",
              message: thrownMessage(error, "native event projection failed"),
              retryable: false,
            };
            break;
          }

          if (projection.delivery?.prompt) {
            if (
              projection.delivery.prompt.sha256 !== acceptance.prompt.sha256 ||
              projection.delivery.prompt.bytes !== acceptance.prompt.bytes
            ) {
              fault = {
                status: "failed",
                code: "NATIVE_PROMPT_OBSERVATION_MISMATCH",
                message: "receiver prompt observation differs from exact mediation ingress",
                retryable: false,
              };
              break;
            }
            if (!deliveryEvents.some((event) => event.stage === "receiver_observed")) {
              deliveryEvents.push({
                stage: "receiver_observed",
                observed_at: frame.observedAt,
                evidence: { kind: "native_event", ref: sourceLocator(projection.source_ref) },
              });
            }
          }

          if (projection.provenance.application) {
            if (projection.provenance.application.id !== application) {
              fault = {
                status: "failed",
                code: "NATIVE_APPLICATION_MISMATCH",
                message: `receiver-native application '${projection.provenance.application.id}' differs from selected application '${application}'`,
                retryable: false,
              };
              break;
            }
            applicationObservation = bindObservation(applicationObservation, {
              ...projection.provenance.application,
              source: projection.source_ref,
            }, "application");
          }
          if (projection.provenance.model) {
            modelObservation = bindObservation(modelObservation, {
              ...projection.provenance.model,
              source: projection.source_ref,
            }, "model");
          }

          const nativeCount = Object.keys(projection.native_correlation).length;
          if (nativeCount > 0) {
            if (
              bestNativeObservation?.conversation_id && projection.native_correlation.conversation_id &&
              bestNativeObservation.conversation_id !== projection.native_correlation.conversation_id
            ) {
              throw new MediatedTurnError("NATIVE_CORRELATION_CONFLICT", "native conversation identity changed during one mediated turn");
            }
            if (
              bestNativeObservation?.turn_id && projection.native_correlation.turn_id &&
              bestNativeObservation.turn_id !== projection.native_correlation.turn_id
            ) {
              throw new MediatedTurnError("NATIVE_CORRELATION_CONFLICT", "native turn identity changed during one mediated turn");
            }
            if (!bestNativeObservation || nativeCount >= bestNativeObservation.count) {
              bestNativeObservation = {
                ...projection.native_correlation,
                source: projection.source_ref,
                count: nativeCount,
              };
            }
          }

          const normalized = canonicalRecord(acceptance.exchange_id, projection);
          if (normalized) projectedRecords.push(normalized);
          if (projection.terminal) {
            if (terminalProjection) {
              fault = {
                status: "failed",
                code: "NATIVE_TERMINAL_DUPLICATE",
                message: "receiver-native stream contains multiple terminal events",
                retryable: false,
              };
              break;
            }
            terminalProjection = projection;
          }
        }

        if (!fault && !terminalProjection) {
          fault = {
            status: "failed",
            code: "NATIVE_TERMINAL_MISSING",
            message: "receiver-native stream closed without a correlated terminal event",
            retryable: false,
          };
        }

        if (!fault) {
          const terminal = this.adapterEngine.resolveTerminal(application, terminalProjection, projectedRecords);
          if (terminal.outcome === "completed") {
            reply = terminal.reply;
          } else {
            fault = terminalFault(terminal.outcome);
          }
        }
      }
    } catch (error) {
      fault ??= {
        status: "failed",
        code: error?.code ?? "MEDIATED_TURN_FAILED",
        message: thrownMessage(error, "mediated turn processing failed"),
        retryable: false,
      };
    }

    const stopConfirmed = nativeStopConfirmed(nativeResult, invocationStarted);
    const rawOmissions = rawCaptureOmissions(nativeResult, invocationStarted, frames?.totalBytes ?? 0);
    const traceShouldBeComplete = rawOmissions.length === 0;
    let trace;
    if (sink) {
      try {
        trace = await sink.finalize({
          complete: traceShouldBeComplete,
          omissions: rawOmissions,
        });
      } catch (error) {
        fault = {
          status: "failed",
          code: error?.code ?? "RAW_TRACE_FINALIZE_FAILED",
          message: thrownMessage(error, "raw trace finalization failed"),
          retryable: true,
        };
        trace = {
          complete: false,
          omissions: [{
            code: "RAW_TRACE_FINALIZE_FAILED",
            detail: thrownMessage(error, "raw trace finalization failed"),
          }],
        };
        reply = null;
      }
    } else {
      trace = {
        complete: false,
        omissions: [{ code: "RAW_TRACE_UNAVAILABLE", detail: "raw trace sink was not initialized" }],
      };
      fault ??= {
        status: "failed",
        code: "RAW_TRACE_UNAVAILABLE",
        message: "raw trace sink was not initialized",
        retryable: true,
      };
      reply = null;
    }

    let status = fault?.status ?? "completed";
    if (status === "completed" && (!trace.complete || typeof reply !== "string")) {
      status = "failed";
      fault = {
        status,
        code: "MEDIATED_COMPLETION_INCOMPLETE",
        message: "completed mediation lacks a durable complete trace or native reply",
        retryable: true,
      };
      reply = null;
    }

    let records;
    let commitPayload;
    try {
      records = status === "completed"
        ? enrichFinalResponse(projectedRecords, terminalProjection, reply)
        : projectedRecords.map(
            (record) => record._type === "response" ? { ...record, phase: "partial" } : record,
          );
      const end = nowIso(this.clock);
      const nativeReceiver = bestNativeObservation && applicationObservation
        ? {
            application_id: applicationObservation.id,
            adapter_id: adapter.id,
            ...(bestNativeObservation.conversation_id ? { conversation_id: bestNativeObservation.conversation_id } : {}),
            ...(bestNativeObservation.turn_id ? { turn_id: bestNativeObservation.turn_id } : {}),
            source: bestNativeObservation.source,
          }
        : null;
      commitPayload = this.assembler.assembleCommit({
        acceptance,
        status,
        exchangeEnd: end,
        ...(applicationObservation ? { application: applicationObservation } : {}),
        ...(modelObservation ? { model: modelObservation } : {}),
        ...(nativeReceiver ? { native: { receiver: nativeReceiver } } : {}),
        ...(status !== "completed" ? {
          outcome: {
            code: fault.code,
            message: fault.message,
            retryable: Boolean(fault.retryable),
            native_stop_confirmed: stopConfirmed,
          },
        } : {}),
        trace,
        delivery: { events: deliveryEvents },
        records,
      });
    } catch (error) {
      status = "failed";
      fault = {
        status,
        code: "EXCHANGE_ASSEMBLY_FAILED",
        message: thrownMessage(error, "terminal exchange assembly failed"),
        retryable: false,
      };
      reply = null;
      records = [];
      try {
        commitPayload = this.fallbackAssembler.assembleCommit({
          acceptance,
          status,
          exchangeEnd: acceptance.accepted_at,
          outcome: {
            code: fault.code,
            message: fault.message,
            retryable: false,
            native_stop_confirmed: stopConfirmed,
          },
          trace: {
            complete: false,
            ...(trace?.raw ? { raw: trace.raw } : {}),
            omissions: [{
              code: "EXCHANGE_ASSEMBLY_FAILED",
              detail: "normal projection was rejected; the terminal row records a minimal failure envelope",
              ...(trace?.raw?.relative_ref ? { source_ref: trace.raw.relative_ref } : {}),
            }],
          },
          delivery: { events: [] },
          records,
        });
      } catch (fallbackError) {
        const quarantine = gateLease.quarantine(
          "durably accepted exchange could not be projected for terminal commit",
        );
        throw new MediatedTurnError(
          "MEDIATED_TERMINALIZATION_FAILED",
          "durably accepted exchange could not be projected for terminal commit",
          {
            cause: fallbackError,
            details: {
              conversation_key: key,
              exchange_id: acceptance.exchange_id,
              quarantine,
            },
          },
        );
      }
    }

    let committed;
    let terminalMarker;
    try {
      ({ exchange: committed, marker: terminalMarker } = validateCommitResult(
        await store.commitExchange(commitPayload),
        acceptance,
        commitPayload,
      ));
    } catch (error) {
      const quarantine = gateLease.quarantine(stopConfirmed
        ? AMBIGUOUS_COMMIT_QUARANTINE_REASON
        : "native stop is unconfirmed and terminal transcript commit failed");
      throw new MediatedTurnError("MEDIATED_COMMIT_FAILED", "terminal exchange commit failed", {
        cause: error,
        details: {
          conversation_key: key,
          exchange_id: acceptance.exchange_id,
          intended_status: status,
          quarantine,
        },
      });
    }

    if (!stopConfirmed) {
      gateLease.quarantine(
        `${committed.outcome.code}: ${committed.outcome.message}`,
        committed.exchange_end,
      );
    }
    else gateLease.release();
    if (status === "completed") {
      const egress = {
        stage: "constructed",
        observed_at: nowIsoAtOrAfter(this.clock, terminalMarker.terminal_at),
        reply_sha256: sha256(Buffer.from(reply, "utf8")),
      };
      return this.assembler.assembleCompletedResult({ acceptance, exchange: committed, egress });
    }
    const receipt = this.assembler.assembleReceipt({ acceptance, exchange: committed });
    throw new MediatedTurnError(fault.code, fault.message, { receipt });
  }
}
