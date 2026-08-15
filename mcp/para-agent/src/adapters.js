/**
 * Versioned application-adapter registry and projection engine.
 *
 * Adapter profiles describe evidenced transport and native-event semantics. They
 * never invent client identities, timestamps, model names, or terminal state.
 * Unknown native frames remain raw evidence and are reported as unmapped.
 */

import { createHash } from "node:crypto";
import fs from "node:fs/promises";
import { existsSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import Ajv2020 from "ajv/dist/2020.js";
import addFormats from "ajv-formats";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
export const DEFAULT_ADAPTERS_DIR = path.join(__dirname, "adapters");
export const DEFAULT_ADAPTER_SCHEMA = path.join(__dirname, "schemas", "client-adapter.schema.json");

const CANONICAL_OUTCOMES = new Set(["completed", "failed", "interrupted", "timeout"]);
const FORBIDDEN_PATH_PARTS = new Set(["__proto__", "prototype", "constructor"]);
const REQUIRED_RECORD_FIELDS = Object.freeze({
  prompt_echo: ["text"],
  thinking: ["text"],
  tool_call: ["tool_use_id", "tool_name", "input"],
  tool_result: ["tool_use_id", "result"],
  response: ["text"],
});

export class AdapterError extends Error {
  constructor(code, message, details = undefined) {
    super(message);
    this.name = "AdapterError";
    this.code = code;
    if (details !== undefined) this.details = details;
  }
}

function sha256(bytes) {
  return createHash("sha256").update(bytes).digest("hex");
}

function nonEmpty(value, label) {
  if (typeof value !== "string" || value.length === 0) {
    throw new AdapterError("ADAPTER_VALUE_REQUIRED", `${label} must be a non-empty string`);
  }
  return value;
}

function assertIsoTimestamp(value, label) {
  nonEmpty(value, label);
  if (!Number.isFinite(Date.parse(value))) {
    throw new AdapterError("ADAPTER_TIMESTAMP_INVALID", `${label} is not an ISO date-time`, { value });
  }
  return value;
}

function pathParts(dotPath) {
  nonEmpty(dotPath, "adapter path");
  const normalized = dotPath.replace(/\[(\d+)\]/g, ".$1");
  const parts = normalized.split(".");
  if (
    parts.some((part, index) =>
      !part || FORBIDDEN_PATH_PARTS.has(part) ||
      (index === 0 ? !/^[A-Za-z_][A-Za-z0-9_]*$/.test(part) : !/^(?:[A-Za-z_][A-Za-z0-9_]*|\d+)$/.test(part))
    )
  ) {
    throw new AdapterError("ADAPTER_PATH_INVALID", `unsafe or invalid adapter path '${dotPath}'`);
  }
  return parts;
}

/** Resolve a validated dotted path without evaluating source text. */
export function getByPath(object, dotPath) {
  if (object === null || object === undefined || !dotPath) return undefined;
  let current = object;
  for (const part of pathParts(dotPath)) {
    if (current === null || current === undefined) return undefined;
    current = current[part];
  }
  return current;
}

function setByPath(object, dotPath, value) {
  const parts = pathParts(dotPath);
  let current = object;
  for (let index = 0; index < parts.length - 1; index++) {
    const part = parts[index];
    const nextIsArray = /^\d+$/.test(parts[index + 1]);
    if (current[part] === undefined) current[part] = nextIsArray ? [] : {};
    if (current[part] === null || typeof current[part] !== "object") {
      throw new AdapterError("ADAPTER_PATH_COLLISION", `cannot assign adapter path '${dotPath}'`);
    }
    current = current[part];
  }
  current[parts.at(-1)] = value;
}

function deepFreeze(value) {
  if (value && typeof value === "object" && !Object.isFrozen(value)) {
    Object.freeze(value);
    for (const child of Object.values(value)) deepFreeze(child);
  }
  return value;
}

function matchesConditions(event, conditions = []) {
  return conditions.every(({ path: conditionPath, equals }) =>
    Object.is(getByPath(event, conditionPath), equals)
  );
}

function matchingRule(rules, nativeType, event, label) {
  const matches = (rules ?? []).filter((rule) =>
    rule.native_type === nativeType && matchesConditions(event, rule.conditions)
  );
  if (matches.length > 1) {
    throw new AdapterError("ADAPTER_EVENT_AMBIGUOUS", `${label} has ${matches.length} matching rules`, {
      native_type: nativeType,
    });
  }
  return matches[0] ?? null;
}

function normalizeRawRef(rawRef) {
  if (!rawRef || typeof rawRef !== "object" || Array.isArray(rawRef)) {
    throw new AdapterError("ADAPTER_RAW_REF_REQUIRED", "a raw trace source reference is required");
  }
  if (rawRef.kind !== "receiver_native") {
    throw new AdapterError(
      "ADAPTER_RAW_REF_INVALID",
      "rawRef.kind must be 'receiver_native'"
    );
  }
  const traceRef = nonEmpty(rawRef.trace_ref, "rawRef.trace_ref");
  const hasFrame = Number.isInteger(rawRef.frame_index) && rawRef.frame_index >= 0;
  const span = rawRef.byte_span;
  const hasSpan = span && Number.isInteger(span.start) && Number.isInteger(span.length) && span.start >= 0 && span.length > 0;
  if (hasFrame === Boolean(hasSpan)) {
    throw new AdapterError(
      "ADAPTER_RAW_REF_INVALID",
      "rawRef must identify exactly one non-negative frame_index or byte_span"
    );
  }
  const normalized = hasFrame
    ? { kind: "receiver_native", trace_ref: traceRef, frame_index: rawRef.frame_index }
    : { kind: "receiver_native", trace_ref: traceRef, byte_span: { start: span.start, length: span.length } };
  if (rawRef.native_event_id !== undefined) {
    normalized.native_event_id = nonEmpty(rawRef.native_event_id, "rawRef.native_event_id");
  }
  return deepFreeze(normalized);
}

function validateRecordFields(mapping, fields) {
  for (const name of REQUIRED_RECORD_FIELDS[mapping.kind]) {
    if (!(name in fields) || fields[name] === undefined || fields[name] === null) {
      throw new AdapterError(
        "ADAPTER_EVENT_FIELD_MISSING",
        `native '${mapping.native_type}' event did not supply '${name}' for ${mapping.kind}`
      );
    }
  }
  if (["prompt_echo", "thinking", "response"].includes(mapping.kind) && typeof fields.text !== "string") {
    throw new AdapterError("ADAPTER_EVENT_FIELD_INVALID", `${mapping.kind}.text must be a string`);
  }
  for (const name of ["tool_use_id", "tool_name"]) {
    if (name in fields && (typeof fields[name] !== "string" || fields[name].length === 0)) {
      throw new AdapterError("ADAPTER_EVENT_FIELD_INVALID", `${mapping.kind}.${name} must be a non-empty string`);
    }
  }
}

function semanticValidateProfile(profile, source) {
  const fail = (message) => {
    throw new AdapterError("ADAPTER_PROFILE_SEMANTIC_INVALID", `${source}: ${message}`);
  };
  if (profile.verification.status !== "verified") return;

  if (profile.prompt_delivery.payload_format === "raw_utf8" && profile.transport.kind !== "raw_stdin") {
    fail("raw_utf8 prompt delivery requires raw_stdin transport");
  }
  if (profile.prompt_delivery.payload_format === "json" && profile.transport.kind !== "jsonl_stdin") {
    fail("JSON prompt delivery requires jsonl_stdin transport");
  }
  if (profile.capabilities.prompt_observation !== Boolean(profile.prompt_observation)) {
    fail("prompt_observation capability and mapping disagree");
  }
  if (profile.capabilities.scoped_cancellation !== Boolean(profile.cancellation)) {
    fail("scoped_cancellation capability and mapping disagree");
  }
  if (profile.capabilities.model_identity && !profile.provenance_mappings.model_id_path) {
    fail("model_identity capability requires model_id_path");
  }

  const kinds = new Set(profile.record_mappings.map((mapping) => mapping.kind));
  for (const [capability, kind] of [
    ["reasoning_events", "thinking"],
    ["tool_calls", "tool_call"],
    ["tool_results", "tool_result"],
  ]) {
    if (profile.capabilities[capability] !== kinds.has(kind)) {
      fail(`${capability} capability and ${kind} record mapping disagree`);
    }
  }
  for (const mapping of profile.record_mappings) {
    const fields = new Set(Object.keys(mapping.fields));
    for (const required of REQUIRED_RECORD_FIELDS[mapping.kind]) {
      if (!fields.has(required)) fail(`${mapping.kind} mapping requires '${required}'`);
    }
  }

  const signatures = profile.record_mappings.map(({ native_type, conditions = [] }) =>
    JSON.stringify([native_type, conditions])
  );
  if (new Set(signatures).size !== signatures.length) fail("record mappings contain an ambiguous duplicate rule");
}

export class AdapterEngine {
  constructor({ adaptersDir = DEFAULT_ADAPTERS_DIR, schemaPath = DEFAULT_ADAPTER_SCHEMA, ajv = undefined } = {}) {
    this.adaptersDir = adaptersDir;
    this.schemaPath = schemaPath;
    this.ajv = ajv ?? addFormats(new Ajv2020({ strict: true, allErrors: true }));
    this.adapters = new Map();
    this.initialized = false;
    this.validateProfile = null;
  }

  /** Load every profile as one transaction. Any invalid profile prevents startup. */
  async init() {
    if (this.initialized) return this;
    if (!existsSync(this.adaptersDir)) {
      throw new AdapterError("ADAPTER_DIRECTORY_MISSING", `adapter directory does not exist: ${this.adaptersDir}`);
    }

    let schema;
    try {
      schema = JSON.parse(await fs.readFile(this.schemaPath, "utf8"));
      this.validateProfile = this.ajv.compile(schema);
    } catch (error) {
      throw new AdapterError("ADAPTER_SCHEMA_INVALID", `could not compile adapter schema: ${error.message}`);
    }

    const files = (await fs.readdir(this.adaptersDir)).filter((file) => file.endsWith(".json")).sort();
    if (files.length === 0) {
      throw new AdapterError("ADAPTER_PROFILE_NONE", `no adapter profiles found in ${this.adaptersDir}`);
    }

    const staged = new Map();
    for (const file of files) {
      const fullPath = path.join(this.adaptersDir, file);
      let profile;
      try {
        profile = JSON.parse(await fs.readFile(fullPath, "utf8"));
      } catch (error) {
        throw new AdapterError("ADAPTER_PROFILE_PARSE_FAILED", `${file}: ${error.message}`);
      }
      if (!this.validateProfile(profile)) {
        throw new AdapterError(
          "ADAPTER_PROFILE_SCHEMA_INVALID",
          `${file}: ${this.ajv.errorsText(this.validateProfile.errors, { separator: "; " })}`,
          this.validateProfile.errors
        );
      }
      semanticValidateProfile(profile, file);
      const applicationId = profile.application.id;
      if (staged.has(applicationId)) {
        throw new AdapterError("ADAPTER_PROFILE_DUPLICATE", `multiple profiles register application '${applicationId}'`);
      }
      staged.set(applicationId, deepFreeze(profile));
    }

    this.adapters = staged;
    this.initialized = true;
    return this;
  }

  _assertReady() {
    if (!this.initialized) throw new AdapterError("ADAPTER_NOT_INITIALIZED", "adapter registry has not been initialized");
  }

  listProfiles() {
    this._assertReady();
    return [...this.adapters.values()];
  }

  getProfile(applicationId) {
    this._assertReady();
    return this.adapters.get(applicationId) ?? null;
  }

  /** Get an operational profile. Unknown and unverified profiles fail explicitly. */
  getAdapter(applicationId) {
    this._assertReady();
    const profile = this.adapters.get(applicationId);
    if (!profile) {
      throw new AdapterError("ADAPTER_UNKNOWN", `no adapter profile is registered for application '${applicationId}'`);
    }
    if (profile.verification.status !== "verified") {
      throw new AdapterError(
        "ADAPTER_UNVERIFIED",
        `adapter profile '${profile.profile_id}' is unverified: ${profile.verification.reason}`
      );
    }
    return profile;
  }

  assertCapability(applicationId, capability) {
    const profile = this.getAdapter(applicationId);
    if (!(capability in profile.capabilities)) {
      throw new AdapterError("ADAPTER_CAPABILITY_UNKNOWN", `unknown adapter capability '${capability}'`);
    }
    if (!profile.capabilities[capability]) {
      throw new AdapterError(
        "ADAPTER_CAPABILITY_UNSUPPORTED",
        `adapter profile '${profile.profile_id}' does not support '${capability}'`
      );
    }
    return profile;
  }

  assertApplicationVersion(applicationId, observedVersion) {
    const profile = this.getAdapter(applicationId);
    nonEmpty(observedVersion, "observed application version");
    if (!profile.application.verified_versions.includes(observedVersion)) {
      throw new AdapterError(
        "ADAPTER_VERSION_UNSUPPORTED",
        `profile '${profile.profile_id}' does not support observed ${applicationId} version '${observedVersion}'`,
        { supported: profile.application.verified_versions }
      );
    }
    return profile;
  }

  /** Render, but do not claim emission of, one exact prompt payload. */
  renderPrompt(applicationId, { prompt, exchangeId, conversationKey }) {
    const profile = this.assertCapability(applicationId, "prompt_delivery");
    if (typeof prompt !== "string") throw new AdapterError("ADAPTER_PROMPT_INVALID", "prompt must be a string");
    nonEmpty(exchangeId, "exchangeId");
    nonEmpty(conversationKey, "conversationKey");

    const promptBytes = Buffer.from(prompt, "utf8");
    let bytes;
    if (profile.prompt_delivery.payload_format === "raw_utf8") {
      bytes = promptBytes;
    } else {
      const payload = {};
      setByPath(payload, profile.prompt_delivery.type_path, profile.prompt_delivery.native_type);
      setByPath(payload, profile.prompt_delivery.prompt_path, prompt);
      setByPath(payload, profile.prompt_delivery.exchange_id_path, exchangeId);
      setByPath(payload, profile.prompt_delivery.conversation_key_path, conversationKey);
      bytes = Buffer.from(`${JSON.stringify(payload)}\n`, "utf8");
    }

    return {
      command: [...profile.transport.command],
      bytes,
      receipt: {
        stage: "rendered",
        profile_id: profile.profile_id,
        adapter: { ...profile.adapter },
        transport: {
          kind: profile.transport.kind,
          encoding: profile.transport.encoding,
          framing: profile.transport.framing,
        },
        prompt: { sha256: sha256(promptBytes), bytes: promptBytes.length },
        payload: { sha256: sha256(bytes), bytes: bytes.length },
      },
    };
  }

  /** Render a profile-evidenced turn-scoped cancel message. */
  renderCancellation(applicationId, { exchangeId, conversationKey, turnId }) {
    const profile = this.assertCapability(applicationId, "scoped_cancellation");
    nonEmpty(exchangeId, "exchangeId");
    nonEmpty(conversationKey, "conversationKey");
    nonEmpty(turnId, "turnId");
    if (profile.transport.kind !== "jsonl_stdin") {
      throw new AdapterError("ADAPTER_CANCEL_TRANSPORT_UNSUPPORTED", "scoped cancellation requires structured JSONL transport");
    }
    const mapping = profile.cancellation;
    const payload = {};
    setByPath(payload, mapping.type_path, mapping.native_type);
    setByPath(payload, mapping.exchange_id_path, exchangeId);
    setByPath(payload, mapping.conversation_key_path, conversationKey);
    setByPath(payload, mapping.turn_id_path, turnId);
    const bytes = Buffer.from(`${JSON.stringify(payload)}\n`, "utf8");
    return {
      bytes,
      receipt: {
        stage: "rendered",
        scope: "turn",
        profile_id: profile.profile_id,
        payload: { sha256: sha256(bytes), bytes: bytes.length },
      },
    };
  }

  _extractCorrelation(profile, event, context) {
    const mappings = profile.correlation_mappings;
    const native = {};
    for (const [name, mappingName] of [
      ["exchange_id", "exchange_id_path"],
      ["conversation_id", "conversation_id_path"],
      ["turn_id", "turn_id_path"],
    ]) {
      const mappingPath = mappings[mappingName];
      if (!mappingPath) continue;
      const value = getByPath(event, mappingPath);
      if (value !== undefined && value !== null) native[name] = nonEmpty(value, `native ${name}`);
    }
    for (const [nativeName, expectedName] of [
      ["exchange_id", "exchangeId"],
      ["conversation_id", "nativeConversationId"],
      ["turn_id", "nativeTurnId"],
    ]) {
      if (context[expectedName] !== undefined && native[nativeName] !== undefined && context[expectedName] !== native[nativeName]) {
        throw new AdapterError("ADAPTER_CORRELATION_MISMATCH", `native ${nativeName} does not match the mediated turn`, {
          expected: context[expectedName],
          observed: native[nativeName],
        });
      }
    }
    return native;
  }

  /** Extract only values actually carried by this native event. */
  extractProvenance(applicationId, event) {
    const profile = this.getAdapter(applicationId);
    if (!event || typeof event !== "object" || Array.isArray(event)) {
      throw new AdapterError("ADAPTER_EVENT_INVALID", "native event must be an object");
    }
    const mappings = profile.provenance_mappings;
    const result = {};

    const observedApplicationId = mappings.application_id_path
      ? getByPath(event, mappings.application_id_path)
      : undefined;
    const observedApplicationVersion = mappings.application_version_path
      ? getByPath(event, mappings.application_version_path)
      : undefined;
    if (observedApplicationId !== undefined || observedApplicationVersion !== undefined) {
      const applicationId = observedApplicationId === undefined
        ? profile.application.id
        : nonEmpty(observedApplicationId, "native application.id");
      nonEmpty(observedApplicationVersion, "native application.version");
      if (applicationId !== profile.application.id) {
        throw new AdapterError("ADAPTER_APPLICATION_MISMATCH", `expected application '${profile.application.id}', observed '${observedApplicationId}'`);
      }
      result.application = { id: applicationId, version: observedApplicationVersion };
    }

    const modelId = mappings.model_id_path ? getByPath(event, mappings.model_id_path) : undefined;
    const modelDisplayName = mappings.model_display_name_path
      ? getByPath(event, mappings.model_display_name_path)
      : undefined;
    if (modelDisplayName !== undefined && modelId === undefined) {
      throw new AdapterError("ADAPTER_MODEL_INCOMPLETE", "native model.display_name appeared without native model.id");
    }
    if (modelId !== undefined) {
      result.model = { id: nonEmpty(modelId, "native model.id") };
      if (modelDisplayName !== undefined) result.model.display_name = nonEmpty(modelDisplayName, "native model.display_name");
    }

    const nativeTimestamp = mappings.native_timestamp_path
      ? getByPath(event, mappings.native_timestamp_path)
      : undefined;
    if (nativeTimestamp !== undefined) result.native_timestamp = assertIsoTimestamp(nativeTimestamp, "native timestamp");
    return result;
  }

  /**
   * Project one raw-preserved native event. Unmapped events remain explicit and
   * retain their source reference; they are never heuristically normalized.
   */
  projectEvent(applicationId, event, context) {
    const profile = this.getAdapter(applicationId);
    if (!event || typeof event !== "object" || Array.isArray(event)) {
      throw new AdapterError("ADAPTER_EVENT_INVALID", "native event must be an object");
    }
    if (!context || typeof context !== "object") {
      throw new AdapterError("ADAPTER_CONTEXT_REQUIRED", "event projection context is required");
    }
    const observedAt = assertIsoTimestamp(context.observedAt, "context.observedAt");
    const exchangeId = nonEmpty(context.exchangeId, "context.exchangeId");
    const conversationKey = nonEmpty(context.conversationKey, "context.conversationKey");
    const sourceRef = normalizeRawRef(context.rawRef);
    const nativeType = nonEmpty(getByPath(event, profile.native_events.discriminator_path), "native event type");
    const provenance = this.extractProvenance(applicationId, event);
    const nativeCorrelation = this._extractCorrelation(profile, event, context);

    const recordRule = matchingRule(profile.record_mappings, nativeType, event, "record mapping");
    let record = null;
    if (recordRule) {
      const fields = {};
      for (const [field, fieldPath] of Object.entries(recordRule.fields)) fields[field] = getByPath(event, fieldPath);
      validateRecordFields(recordRule, fields);
      record = {
        _type: recordRule.kind,
        observed_at: observedAt,
        source_ref: sourceRef,
        ...("native_timestamp" in provenance ? { native_timestamp: provenance.native_timestamp } : {}),
        ...(nativeCorrelation.turn_id ? { native_turn_id: nativeCorrelation.turn_id } : {}),
        ...fields,
      };
    }

    let delivery = null;
    const promptRule = profile.prompt_observation;
    if (
      promptRule && promptRule.native_type === nativeType &&
      matchesConditions(event, promptRule.conditions)
    ) {
      const observedPrompt = getByPath(event, promptRule.prompt_path);
      if (typeof observedPrompt !== "string") {
        throw new AdapterError("ADAPTER_PROMPT_OBSERVATION_INVALID", "receiver prompt observation did not contain a string prompt");
      }
      const promptBytes = Buffer.from(observedPrompt, "utf8");
      delivery = {
        stage: "receiver_observed",
        evidence_ref: sourceRef,
        prompt: { sha256: sha256(promptBytes), bytes: promptBytes.length },
      };
    }

    const terminalRule = matchingRule(profile.terminal_events, nativeType, event, "terminal mapping");
    let terminal = null;
    if (terminalRule) {
      let outcome = terminalRule.outcome;
      if (!outcome) {
        const nativeOutcome = getByPath(event, terminalRule.outcome_path);
        outcome = terminalRule.outcome_map[String(nativeOutcome)];
        if (!outcome) {
          throw new AdapterError("ADAPTER_TERMINAL_OUTCOME_UNKNOWN", `unmapped native terminal outcome '${nativeOutcome}'`);
        }
      }
      if (!CANONICAL_OUTCOMES.has(outcome)) {
        throw new AdapterError("ADAPTER_TERMINAL_OUTCOME_INVALID", `invalid canonical outcome '${outcome}'`);
      }
      terminal = { outcome, reply_source: terminalRule.reply_source };
      if (terminalRule.reply_source.strategy === "event_path") {
        const nativeReply = getByPath(event, terminalRule.reply_source.path);
        if (nativeReply !== undefined && typeof nativeReply !== "string") {
          throw new AdapterError("ADAPTER_TERMINAL_REPLY_INVALID", "native terminal reply must be a string");
        }
        if (nativeReply !== undefined) terminal.native_reply = nativeReply;
      }
    }

    const classification = record || delivery || terminal || Object.keys(provenance).length || Object.keys(nativeCorrelation).length
      ? "mapped"
      : "unmapped";
    return {
      classification,
      native_type: nativeType,
      observed_at: observedAt,
      source_ref: sourceRef,
      mediation: { exchange_id: exchangeId, conversation_key: conversationKey },
      native_correlation: nativeCorrelation,
      provenance,
      record,
      delivery,
      terminal,
    };
  }

  /** Compatibility projection: strict profile selection, no heuristic fallback. */
  normalizeEvent(applicationId, event, context) {
    return this.projectEvent(applicationId, event, context).record;
  }

  isTerminal(applicationId, event) {
    const profile = this.getAdapter(applicationId);
    const nativeType = getByPath(event, profile.native_events.discriminator_path);
    return Boolean(matchingRule(profile.terminal_events, nativeType, event, "terminal mapping"));
  }

  /** Resolve a receiver-authoritative reply only after a correlated terminal event. */
  resolveTerminal(applicationId, terminalProjection, projectedRecords = []) {
    this.getAdapter(applicationId);
    if (!terminalProjection?.terminal) {
      throw new AdapterError("ADAPTER_TERMINAL_REQUIRED", "a terminal event projection is required");
    }
    const terminal = terminalProjection.terminal;
    const result = {
      outcome: terminal.outcome,
      source_ref: terminalProjection.source_ref,
      observed_at: terminalProjection.observed_at,
      native_correlation: terminalProjection.native_correlation,
      provenance: terminalProjection.provenance,
    };
    if (terminal.outcome !== "completed") return result;

    let reply = terminal.native_reply;
    if (reply === undefined && terminal.reply_source.strategy === "latest_record") {
      const records = projectedRecords.map((value) => value?.record ?? value).filter(Boolean);
      const match = [...records].reverse().find((record) => record._type === terminal.reply_source.record_kind);
      reply = match?.[terminal.reply_source.field];
    }
    if (typeof reply !== "string") {
      throw new AdapterError("ADAPTER_TERMINAL_REPLY_MISSING", "completed terminal event has no receiver-authoritative reply");
    }
    result.reply = reply;
    return result;
  }
}
