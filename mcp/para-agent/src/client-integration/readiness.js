import { TextDecoder } from "node:util";

import { ClientIntegrationError } from "./errors.js";

export const READINESS_DIMENSIONS = Object.freeze([
  "executable",
  "version",
  "configuration",
  "authentication",
  "capabilities",
  "environment_sources",
  "environment_exact",
  "workspace",
  "prompt_carrier",
  "backend",
]);

const DIMENSION_SET = new Set(READINESS_DIMENSIONS);
const STATES = new Set(["passed", "failed", "unknown", "not_applicable"]);
const TOKEN = /^[A-Za-z0-9_.:+-]{1,128}$/;
const PROBE_RESULT_KEYS = new Set(["exitCode", "stdout", "stderr"]);
const NORMALIZED_PROBE_KEYS = new Set([
  "dimension",
  "evidenceKind",
  "request",
  "timeoutMs",
  "maxOutputBytes",
  "parse",
]);
const PROFILE_PROBE_KEYS = new Set([
  "id",
  "dimension",
  "kind",
  "fixed_args",
  "timeout_ms",
  "max_output_bytes",
  "parser",
  "safe_facts",
]);
const SAFE_FACTS = Object.freeze({
  executable: Object.freeze({ available: "boolean" }),
  version: Object.freeze({ version: "token" }),
  configuration: Object.freeze({ configured: "boolean" }),
  authentication: Object.freeze({ authenticated: "boolean" }),
  capabilities: Object.freeze({ capabilities: "token_array" }),
  environment_sources: Object.freeze({ required_count: "count", resolved_count: "count" }),
  environment_exact: Object.freeze({ exact: "boolean" }),
  workspace: Object.freeze({ working_directory_id: "token" }),
  prompt_carrier: Object.freeze({ kind: "token" }),
  backend: Object.freeze({ kind: "token" }),
});
const PASSED_FACTS = Object.freeze({
  executable: Object.freeze(["available"]),
  version: Object.freeze(["version"]),
  configuration: Object.freeze(["configured"]),
  authentication: Object.freeze(["authenticated"]),
  capabilities: Object.freeze(["capabilities"]),
  environment_sources: Object.freeze(["required_count", "resolved_count"]),
  environment_exact: Object.freeze(["exact"]),
  workspace: Object.freeze(["working_directory_id"]),
  prompt_carrier: Object.freeze(["kind"]),
  backend: Object.freeze(["kind"]),
});
const FAILURE_CODES = Object.freeze({
  executable: "READINESS_EXECUTABLE_UNAVAILABLE",
  version: "READINESS_VERSION_UNSUPPORTED",
  configuration: "READINESS_CONFIGURATION_FAILED",
  authentication: "READINESS_AUTHENTICATION_FAILED",
  capabilities: "READINESS_CAPABILITY_UNAVAILABLE",
});
const UTF8_FATAL = new TextDecoder("utf-8", { fatal: true });

function fail(code, dimension = undefined) {
  throw new ClientIntegrationError(code, {
    safeDetails: dimension === undefined ? undefined : { dimension },
  });
}

function plainObject(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) fail("READINESS_MALFORMED");
  const prototype = Object.getPrototypeOf(value);
  if (prototype !== Object.prototype && prototype !== null) fail("READINESS_MALFORMED");
  if (Object.getOwnPropertySymbols(value).length > 0) fail("READINESS_MALFORMED");
  for (const key of Object.keys(value)) {
    const descriptor = Object.getOwnPropertyDescriptor(value, key);
    if (!descriptor || !("value" in descriptor) || descriptor.enumerable !== true) {
      fail("READINESS_MALFORMED");
    }
  }
  return value;
}

function exactKeys(value, allowed, required = []) {
  plainObject(value);
  if (
    Object.keys(value).some((key) => !allowed.has(key))
    || required.some((key) => !Object.hasOwn(value, key))
  ) {
    fail("READINESS_MALFORMED");
  }
}

function positiveInteger(value, fallback, dimension) {
  const result = value ?? fallback;
  if (!Number.isSafeInteger(result) || result <= 0) fail("READINESS_MALFORMED", dimension);
  return result;
}

function token(value, dimension) {
  if (typeof value !== "string" || !TOKEN.test(value)) fail("READINESS_MALFORMED", dimension);
  return value;
}

function boundedString(value) {
  return typeof value === "string"
    && value.length > 0
    && !value.includes("\0")
    && (typeof value.isWellFormed !== "function" || value.isWellFormed());
}

function requiredSet(value) {
  if (!Array.isArray(value)) fail("READINESS_MALFORMED");
  const result = new Set();
  for (const dimension of value) {
    if (!DIMENSION_SET.has(dimension) || result.has(dimension)) fail("READINESS_MALFORMED");
    result.add(dimension);
  }
  return result;
}

function normalizeFacts(dimension, facts) {
  const input = facts ?? {};
  plainObject(input);
  const declaration = SAFE_FACTS[dimension];
  if (Object.keys(input).some((key) => !Object.hasOwn(declaration, key))) {
    fail("READINESS_MALFORMED", dimension);
  }
  const result = {};
  for (const [key, value] of Object.entries(input)) {
    switch (declaration[key]) {
      case "boolean":
        if (typeof value !== "boolean") fail("READINESS_MALFORMED", dimension);
        result[key] = value;
        break;
      case "count":
        if (!Number.isSafeInteger(value) || value < 0) fail("READINESS_MALFORMED", dimension);
        result[key] = value;
        break;
      case "token":
        result[key] = token(value, dimension);
        break;
      case "token_array": {
        if (!Array.isArray(value) || value.length > 128) fail("READINESS_MALFORMED", dimension);
        const normalized = value.map((item) => token(item, dimension)).sort();
        if (new Set(normalized).size !== normalized.length) fail("READINESS_MALFORMED", dimension);
        result[key] = normalized;
        break;
      }
      default:
        fail("READINESS_MALFORMED", dimension);
    }
  }
  return result;
}

function assertPassedSemantics(dimension, state, facts) {
  if (state !== "passed") return;
  if (PASSED_FACTS[dimension].some((key) => !Object.hasOwn(facts, key))) {
    fail("READINESS_MALFORMED", dimension);
  }
  if (
    (dimension === "executable" && facts.available !== true)
    || (dimension === "configuration" && facts.configured !== true)
    || (dimension === "authentication" && facts.authenticated !== true)
    || (dimension === "environment_exact" && facts.exact !== true)
    || (
      dimension === "environment_sources"
      && facts.resolved_count < facts.required_count
    )
    || (
      dimension === "prompt_carrier"
      && !["stdin_utf8", "prompt_file"].includes(facts.kind)
    )
    || (
      dimension === "backend"
      && !["process", "managed_mux"].includes(facts.kind)
    )
  ) {
    fail("READINESS_MALFORMED", dimension);
  }
}

function freeze(value, seen = new Set()) {
  if (value === null || (typeof value !== "object" && typeof value !== "function")) return value;
  if (seen.has(value)) return value;
  seen.add(value);
  for (const key of Reflect.ownKeys(value)) freeze(value[key], seen);
  return Object.freeze(value);
}

function descriptorEntry(dimension, state, evidenceKind, revision, facts = {}) {
  if (!STATES.has(state)) fail("READINESS_MALFORMED", dimension);
  const normalizedFacts = normalizeFacts(dimension, facts);
  assertPassedSemantics(dimension, state, normalizedFacts);
  return freeze({
    state,
    evidence_kind: token(evidenceKind, dimension),
    integration_revision: token(revision, dimension),
    ...normalizedFacts,
  });
}

function requiredFailure(dimension, state) {
  if (state === "unknown" || state === "not_applicable") {
    fail("READINESS_PROOF_INSUFFICIENT", dimension);
  }
  if (state === "failed") fail(FAILURE_CODES[dimension] ?? "READINESS_PROOF_INSUFFICIENT", dimension);
}

function unknownEntry(probe, revision) {
  return descriptorEntry(probe.dimension, "unknown", probe.evidenceKind, revision);
}

function assertProbe(probe) {
  exactKeys(probe, NORMALIZED_PROBE_KEYS, [
    "dimension",
    "evidenceKind",
    "request",
    "parse",
  ]);
  if (!DIMENSION_SET.has(probe.dimension) || typeof probe.parse !== "function") {
    fail("READINESS_MALFORMED");
  }
  token(probe.evidenceKind, probe.dimension);
  return probe;
}

function strictUtf8(bytes) {
  if (!Buffer.isBuffer(bytes)) fail("READINESS_MALFORMED");
  try {
    const text = UTF8_FATAL.decode(bytes);
    if (!Buffer.from(text, "utf8").equals(bytes)) fail("READINESS_MALFORMED");
    return text;
  } catch (error) {
    if (error instanceof ClientIntegrationError) throw error;
    fail("READINESS_MALFORMED");
  }
}

function assertNoDuplicateObjectKeys(text) {
  const seenByDepth = new Map();
  let depth = 0;
  let inString = false;
  let escaped = false;
  let stringStart = -1;
  for (let index = 0; index < text.length; index += 1) {
    const character = text[index];
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (character === "\\") {
        escaped = true;
      } else if (character === '"') {
        inString = false;
        let next = index + 1;
        while (/\s/u.test(text[next] ?? "")) next += 1;
        if (text[next] === ":") {
          let key;
          try {
            key = JSON.parse(text.slice(stringStart, index + 1));
          } catch {
            fail("READINESS_MALFORMED");
          }
          const seen = seenByDepth.get(depth) ?? new Set();
          if (seen.has(key)) fail("READINESS_MALFORMED");
          seen.add(key);
          seenByDepth.set(depth, seen);
        }
      }
      continue;
    }
    if (character === '"') {
      inString = true;
      stringStart = index;
    } else if (character === "{" || character === "[") {
      depth += 1;
    } else if (character === "}" || character === "]") {
      seenByDepth.delete(depth);
      depth -= 1;
    }
  }
  if (inString || depth !== 0) fail("READINESS_MALFORMED");
}

/** Parse exactly one UTF-8 JSON object and reject undeclared, missing, or duplicate keys. */
export function parseStrictJsonObject(bytes, { allowedKeys, requiredKeys = [] } = {}) {
  if (!Buffer.isBuffer(bytes) || !Array.isArray(allowedKeys) || !Array.isArray(requiredKeys)) {
    fail("READINESS_MALFORMED");
  }
  const text = strictUtf8(bytes);
  assertNoDuplicateObjectKeys(text);
  let value;
  try {
    value = JSON.parse(text);
  } catch {
    fail("READINESS_MALFORMED");
  }
  plainObject(value);
  const allowed = new Set(allowedKeys);
  if (
    allowed.size !== allowedKeys.length
    || new Set(requiredKeys).size !== requiredKeys.length
    || requiredKeys.some((key) => !allowed.has(key))
    || Object.keys(value).some((key) => !allowed.has(key))
    || requiredKeys.some((key) => !Object.hasOwn(value, key))
  ) {
    fail("READINESS_MALFORMED");
  }
  return value;
}

function normalizeSuccessCodes(parser) {
  exactKeys(parser, new Set(["kind", "success_exit_codes"]), ["kind"]);
  const values = parser.success_exit_codes ?? [0];
  if (
    !Array.isArray(values)
    || values.length === 0
    || values.some((value) => !Number.isInteger(value) || value < 0 || value > 255)
    || new Set(values).size !== values.length
  ) {
    fail("READINESS_MALFORMED");
  }
  return [...values];
}

function safeFactNames(dimension, value) {
  const names = value ?? [];
  if (!Array.isArray(names) || new Set(names).size !== names.length) fail("READINESS_MALFORMED", dimension);
  for (const name of names) {
    if (typeof name !== "string" || !Object.hasOwn(SAFE_FACTS[dimension], name)) {
      fail("READINESS_MALFORMED", dimension);
    }
  }
  return [...names];
}

function profileParser({ dimension, parser, safeFacts, effectiveAllowedVersions }) {
  const successCodes = new Set(normalizeSuccessCodes(parser));
  if (!["exit_code", "utf8_text", "json"].includes(parser.kind)) fail("READINESS_MALFORMED", dimension);
  let exitBooleanFact;
  if (parser.kind === "exit_code") {
    const booleanFacts = safeFacts.filter((name) => SAFE_FACTS[dimension][name] === "boolean");
    if (safeFacts.length !== 1 || booleanFacts.length !== 1) fail("READINESS_MALFORMED", dimension);
    [exitBooleanFact] = booleanFacts;
  }
  if (parser.kind === "utf8_text") {
    if (safeFacts.length !== 1 || SAFE_FACTS[dimension][safeFacts[0]] !== "token") {
      fail("READINESS_MALFORMED", dimension);
    }
  }
  if (dimension === "version" && !safeFacts.includes("version")) fail("READINESS_MALFORMED", dimension);

  if (PASSED_FACTS[dimension].some((name) => !safeFacts.includes(name))) {
    fail("READINESS_MALFORMED", dimension);
  }

  return async ({ exitCode, stdout }) => {
    const succeeded = successCodes.has(exitCode);
    if (parser.kind === "exit_code") {
      return {
        state: succeeded ? "passed" : "failed",
        facts: { [exitBooleanFact]: succeeded },
      };
    }
    if (!succeeded) return { state: "failed", facts: {} };
    let facts = {};
    if (parser.kind === "utf8_text") {
      let text = strictUtf8(stdout);
      if (text.endsWith("\r\n")) text = text.slice(0, -2);
      else if (text.endsWith("\n")) text = text.slice(0, -1);
      if (text.includes("\r") || text.includes("\n")) fail("READINESS_MALFORMED", dimension);
      facts = { [safeFacts[0]]: token(text, dimension) };
    } else if (parser.kind === "json") {
      facts = normalizeFacts(dimension, parseStrictJsonObject(stdout, {
        allowedKeys: safeFacts,
        requiredKeys: safeFacts,
      }));
    }
    if (
      dimension === "version"
      && effectiveAllowedVersions.size > 0
      && !effectiveAllowedVersions.has(facts.version)
    ) {
      return { state: "failed", facts };
    }
    return { state: "passed", facts };
  };
}

/** Translate a schema readiness profile into private executable runner probes. */
export function compileReadinessProfile(profile, {
  executable,
  effectiveAllowedVersions,
} = {}) {
  exactKeys(profile, new Set(["required", "probes"]), ["required", "probes"]);
  const required = requiredSet(profile.required);
  if (!boundedString(executable) || !Array.isArray(effectiveAllowedVersions)) {
    fail("READINESS_MALFORMED");
  }
  const allowedVersions = new Set();
  for (const version of effectiveAllowedVersions) {
    const normalized = token(version, "version");
    if (allowedVersions.has(normalized)) fail("READINESS_MALFORMED", "version");
    allowedVersions.add(normalized);
  }
  if (!Array.isArray(profile.probes)) fail("READINESS_MALFORMED");
  const ids = new Set();
  const dimensions = new Set();
  const probes = profile.probes.map((probe) => {
    exactKeys(probe, PROFILE_PROBE_KEYS, [
      "id",
      "dimension",
      "kind",
      "timeout_ms",
      "max_output_bytes",
      "parser",
    ]);
    const id = token(probe.id);
    if (ids.has(id) || !DIMENSION_SET.has(probe.dimension) || dimensions.has(probe.dimension)) {
      fail("READINESS_MALFORMED", probe.dimension);
    }
    ids.add(id);
    dimensions.add(probe.dimension);
    if (probe.kind !== "command" && probe.kind !== "static") fail("READINESS_MALFORMED", probe.dimension);
    const fixedArgs = probe.fixed_args ?? [];
    if (
      !Array.isArray(fixedArgs)
      || fixedArgs.some((argument) => !boundedString(argument))
      || (probe.kind === "static" && fixedArgs.length !== 0)
    ) {
      fail("READINESS_MALFORMED", probe.dimension);
    }
    const safeFacts = safeFactNames(probe.dimension, probe.safe_facts);
    const request = probe.kind === "command"
      ? freeze({ kind: "command", executable, argv: [...fixedArgs], probe_id: id })
      : freeze({ kind: "static", probe_id: id });
    return freeze({
      dimension: probe.dimension,
      evidenceKind: `profile_${probe.kind}_${probe.parser?.kind ?? "invalid"}`,
      request,
      timeoutMs: positiveInteger(probe.timeout_ms, undefined, probe.dimension),
      maxOutputBytes: positiveInteger(probe.max_output_bytes, undefined, probe.dimension),
      parse: profileParser({
        dimension: probe.dimension,
        parser: probe.parser,
        safeFacts,
        effectiveAllowedVersions: allowedVersions,
      }),
    });
  });
  return freeze({ requiredDimensions: [...required], probes });
}

function validateProbeResult(result, maxOutputBytes) {
  if (!result || typeof result !== "object" || Array.isArray(result)) return null;
  if (Object.keys(result).some((key) => !PROBE_RESULT_KEYS.has(key))) return null;
  if (
    (!Number.isInteger(result.exitCode) && result.exitCode !== null)
    || !Buffer.isBuffer(result.stdout)
    || !Buffer.isBuffer(result.stderr)
    || result.stdout.length + result.stderr.length > maxOutputBytes
  ) {
    return null;
  }
  return result;
}

function timerOutcome(milliseconds, value) {
  let timer;
  const promise = new Promise((resolve) => {
    timer = setTimeout(() => resolve(value), milliseconds);
  });
  return { promise, clear: () => clearTimeout(timer) };
}

async function executeBounded(probe, executor, defaults) {
  const timeoutMs = positiveInteger(probe.timeoutMs, defaults.timeoutMs, probe.dimension);
  const maxOutputBytes = positiveInteger(probe.maxOutputBytes, defaults.maxOutputBytes, probe.dimension);
  const controller = new AbortController();
  const operation = Promise.resolve().then(async () => {
    let raw;
    try {
      raw = await executor({
        dimension: probe.dimension,
        request: probe.request,
        signal: controller.signal,
        maxOutputBytes,
      });
    } catch {
      return { kind: controller.signal.aborted ? "aborted" : "execution_failed" };
    }
    if (controller.signal.aborted) return { kind: "aborted" };
    const result = validateProbeResult(raw, maxOutputBytes);
    if (!result) return { kind: "malformed" };
    try {
      const parsed = await probe.parse({
        exitCode: result.exitCode,
        stdout: Buffer.from(result.stdout),
        stderr: Buffer.from(result.stderr),
        signal: controller.signal,
      });
      if (controller.signal.aborted) return { kind: "aborted" };
      exactKeys(parsed, new Set(["state", "facts"]), ["state"]);
      return { kind: "parsed", state: parsed.state, facts: parsed.facts ?? {} };
    } catch {
      return { kind: controller.signal.aborted ? "aborted" : "malformed" };
    }
  });

  const deadline = timerOutcome(timeoutMs, { deadline: true });
  const first = await Promise.race([operation, deadline.promise]);
  deadline.clear();
  if (!first.deadline) return first;

  controller.abort();
  const teardownDeadline = timerOutcome(defaults.teardownTimeoutMs, { settled: false });
  const settlement = await Promise.race([
    operation.then(() => ({ settled: true }), () => ({ settled: true })),
    teardownDeadline.promise,
  ]);
  teardownDeadline.clear();
  return settlement.settled ? { kind: "timeout" } : { kind: "teardown_unconfirmed" };
}

function normalizeStaticEvidence(value) {
  if (value === undefined) return new Map();
  plainObject(value);
  const result = new Map();
  for (const [dimension, entry] of Object.entries(value)) {
    if (!DIMENSION_SET.has(dimension)) fail("READINESS_MALFORMED");
    exactKeys(entry, new Set(["state", "evidenceKind", "facts"]), [
      "state",
      "evidenceKind",
      "facts",
    ]);
    if (!STATES.has(entry.state)) fail("READINESS_MALFORMED", dimension);
    result.set(dimension, {
      state: entry.state,
      evidenceKind: token(entry.evidenceKind, dimension),
      facts: normalizeFacts(dimension, entry.facts),
    });
  }
  return result;
}

/**
 * Run one bounded probe per declared dimension and return descriptor-safe facts.
 * The executor promise must settle only after its process/resources are closed.
 */
export async function runReadiness({
  integrationRevision,
  requiredDimensions = [],
  probes = [],
  staticEvidence = {},
  executor,
  defaultTimeoutMs = 5_000,
  defaultMaxOutputBytes = 64 * 1024,
  defaultTeardownTimeoutMs = 1_000,
} = {}) {
  const revision = token(integrationRevision, "integration");
  const required = requiredSet(requiredDimensions);
  if (!Array.isArray(probes) || (probes.length > 0 && typeof executor !== "function")) {
    fail("READINESS_MALFORMED");
  }
  const byDimension = new Map();
  for (const raw of probes) {
    const probe = assertProbe(raw);
    if (byDimension.has(probe.dimension)) fail("READINESS_MALFORMED", probe.dimension);
    byDimension.set(probe.dimension, probe);
  }
  const staticByDimension = normalizeStaticEvidence(staticEvidence);
  for (const dimension of staticByDimension.keys()) {
    if (byDimension.has(dimension)) fail("READINESS_MALFORMED", dimension);
  }
  const defaults = {
    timeoutMs: positiveInteger(defaultTimeoutMs, 5_000),
    maxOutputBytes: positiveInteger(defaultMaxOutputBytes, 64 * 1024),
    teardownTimeoutMs: positiveInteger(defaultTeardownTimeoutMs, 1_000),
  };
  const report = {};

  for (const dimension of READINESS_DIMENSIONS) {
    const staticEntry = staticByDimension.get(dimension);
    if (staticEntry) {
      const entry = descriptorEntry(
        dimension,
        staticEntry.state,
        staticEntry.evidenceKind,
        revision,
        staticEntry.facts,
      );
      if (required.has(dimension) && entry.state !== "passed") requiredFailure(dimension, entry.state);
      report[dimension] = entry;
      continue;
    }

    const probe = byDimension.get(dimension);
    if (!probe) {
      const entry = descriptorEntry(dimension, "not_applicable", "profile_declaration", revision);
      if (required.has(dimension)) requiredFailure(dimension, entry.state);
      report[dimension] = entry;
      continue;
    }

    const observed = await executeBounded(probe, executor, defaults);
    let entry;
    if (observed.kind === "teardown_unconfirmed") {
      fail("READINESS_TIMEOUT", dimension);
    } else if (observed.kind === "timeout") {
      if (required.has(dimension)) fail("READINESS_TIMEOUT", dimension);
      entry = unknownEntry(probe, revision);
    } else if (observed.kind === "malformed") {
      if (required.has(dimension)) fail("READINESS_MALFORMED", dimension);
      entry = unknownEntry(probe, revision);
    } else if (observed.kind === "execution_failed" || observed.kind === "aborted") {
      if (required.has(dimension)) fail(FAILURE_CODES[dimension] ?? "READINESS_PROOF_INSUFFICIENT", dimension);
      entry = unknownEntry(probe, revision);
    } else {
      entry = descriptorEntry(dimension, observed.state, probe.evidenceKind, revision, observed.facts);
      if (required.has(dimension) && entry.state !== "passed") requiredFailure(dimension, entry.state);
    }
    report[dimension] = entry;
  }

  return freeze(report);
}

/** Validate the closed readiness projection before descriptor construction. */
export function assertReadinessDescriptor(readiness, expectedRevision) {
  plainObject(readiness);
  if (
    Object.keys(readiness).length !== READINESS_DIMENSIONS.length
    || Object.keys(readiness).some((dimension) => !DIMENSION_SET.has(dimension))
  ) {
    fail("READINESS_MALFORMED");
  }
  const result = {};
  for (const dimension of READINESS_DIMENSIONS) {
    const entry = readiness[dimension];
    plainObject(entry);
    const factKeys = Object.keys(SAFE_FACTS[dimension]);
    exactKeys(entry, new Set(["state", "evidence_kind", "integration_revision", ...factKeys]), [
      "state",
      "evidence_kind",
      "integration_revision",
    ]);
    if (expectedRevision !== undefined && entry.integration_revision !== expectedRevision) {
      fail("READINESS_MALFORMED", dimension);
    }
    const facts = {};
    for (const key of factKeys) if (Object.hasOwn(entry, key)) facts[key] = entry[key];
    result[dimension] = descriptorEntry(
      dimension,
      entry.state,
      entry.evidence_kind,
      entry.integration_revision,
      facts,
    );
  }
  return freeze(result);
}
