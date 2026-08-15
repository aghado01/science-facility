/**
 * Closed public error vocabulary for managed client integration.
 *
 * Messages are selected by code and details accept only short, path-free tokens.
 * Raw causes and native diagnostics deliberately have no place in this object.
 */

const DEFINITIONS = Object.freeze({
  CLIENT_UNKNOWN: ["No client integration is registered for the requested application.", false],
  CLIENT_UNAVAILABLE: ["The requested client integration is unavailable on this host.", true],
  CLIENT_CONFIG_INVALID: ["Client integration configuration is invalid.", false],
  INTEGRATION_ADAPTER_INCOMPATIBLE: ["The selected integration and adapter profiles are incompatible.", false],
  SESSION_PROFILE_UNKNOWN: ["The requested client session profile is not registered.", false],
  CLIENT_POLICY_WIDENING: ["The requested client policy would widen its configured ceiling.", false],
  CLIENT_POLICY_UNSUPPORTED: ["The requested client policy selection is unsupported.", false],
  CLIENT_POLICY_AMBIGUOUS: ["The requested client policy selection is ambiguous.", false],
  CLIENT_ENV_NAME_INVALID: ["A managed client environment name is invalid.", false],
  CLIENT_ENV_CASE_COLLISION: ["Managed client environment names collide under host comparison rules.", false],
  CLIENT_ENV_SOURCE_MISSING: ["A required managed client environment source is missing.", false],
  CLIENT_ENV_SOURCE_INVALID: ["A managed client environment source is invalid.", false],
  CLIENT_ENV_REQUIRED_UNSET: ["A required managed client environment value cannot be unset.", false],
  CLIENT_ENV_SECRET_UNSAFE_BACKEND: ["The selected backend cannot safely receive secret environment values.", false],
  CLIENT_ENV_ISOLATION_UNPROVEN: ["Exact managed client environment isolation has not been proven.", false],
  CLIENT_WORKSPACE_UNKNOWN: ["The requested managed client workspace is not registered.", false],
  CLIENT_CWD_INVALID: ["The requested managed client working directory is invalid.", false],
  CLIENT_CWD_MISSING: ["The requested managed client working directory does not exist.", false],
  CLIENT_CWD_NOT_DIRECTORY: ["The requested managed client working directory is not a directory.", false],
  CLIENT_CWD_ESCAPE: ["The requested managed client working directory escapes its workspace.", false],
  CLIENT_CWD_REPARSE: ["The requested managed client working directory traverses a disallowed reparse point.", false],
  CONVERSATION_BINDING_CONFLICT: ["The conversation is already bound to different managed client context.", false],
  TRANSCRIPT_UPGRADE_REQUIRED: ["The transcript must be upgraded or replaced before accepting new managed turns.", false],
  READINESS_EXECUTABLE_UNAVAILABLE: ["The managed client executable is unavailable.", true],
  READINESS_VERSION_UNSUPPORTED: ["The managed client executable version is unsupported.", false],
  READINESS_CONFIGURATION_FAILED: ["Managed client configuration readiness failed.", false],
  READINESS_AUTHENTICATION_FAILED: ["Managed client authentication readiness failed.", true],
  READINESS_CAPABILITY_UNAVAILABLE: ["A required managed client capability is unavailable.", false],
  READINESS_TIMEOUT: ["A managed client readiness probe timed out.", true],
  READINESS_MALFORMED: ["A managed client readiness probe returned malformed output.", false],
  READINESS_PROOF_INSUFFICIENT: ["Managed client readiness evidence is insufficient.", false],
  PROMPT_CARRIER_UNSUPPORTED: ["The selected prompt carrier is unsupported.", false],
  PROMPT_CARRIER_ROOT_UNSAFE: ["The configured prompt carrier root is unsafe.", false],
  PROMPT_CARRIER_CREATE_FAILED: ["The prompt carrier could not be created.", true],
  PROMPT_CARRIER_WRITE_FAILED: ["The prompt carrier could not be written.", true],
  PROMPT_CARRIER_VERIFY_FAILED: ["The prompt carrier could not be verified.", false],
  PROMPT_CARRIER_CLEANUP_PENDING: ["Prompt carrier cleanup remains pending.", true],
  PROMPT_CARRIER_SCAVENGE_FAILED: ["Prompt carrier scavenging failed.", true],
  PROMPT_ENCODING_FAILED: ["The accepted prompt could not be encoded.", false],
  PROMPT_CARRIER_MATERIALIZATION_FAILED: ["The accepted prompt carrier could not be materialized.", true],
  INVOCATION_PLAN_INVALID: ["The managed client invocation plan is invalid.", false],
  NATIVE_APPLICATION_VERSION_MISMATCH: ["Receiver-native application version evidence disagrees with launch readiness.", false],
});
for (const definition of Object.values(DEFINITIONS)) Object.freeze(definition);

const PHASES = new Set(["pre_acceptance", "accepted", "post_commit"]);
const SAFE_DETAIL_KEYS = new Set([
  "availability",
  "configuration_kind",
  "dimension",
  "kind",
  "reason",
  "selector",
  "state",
]);
const SAFE_TOKEN = /^[A-Za-z0-9_.:+-]{1,128}$/;
const WINDOWS_DRIVE_TOKEN = /^[A-Za-z]:/;
const WINDOWS_DEVICE_TOKEN = /^(?:CON|PRN|AUX|NUL|CLOCK\$|COM[1-9]|LPT[1-9])(?:[.:].*)?$/i;

function safeScalar(value) {
  return typeof value === "boolean"
    || (Number.isSafeInteger(value) && value >= 0)
    || (
      typeof value === "string"
      && SAFE_TOKEN.test(value)
      && value !== "."
      && value !== ".."
      && !value.endsWith(".")
      && !WINDOWS_DRIVE_TOKEN.test(value)
      && !WINDOWS_DEVICE_TOKEN.test(value)
    );
}

function normalizeSafeDetails(details) {
  if (details === undefined) return undefined;
  if (details === null || typeof details !== "object" || Array.isArray(details)) {
    throw new TypeError("safeDetails must be a plain object");
  }
  const prototype = Object.getPrototypeOf(details);
  if (prototype !== Object.prototype && prototype !== null) {
    throw new TypeError("safeDetails must be a plain object");
  }
  const normalized = {};
  for (const [key, value] of Object.entries(details)) {
    if (!SAFE_DETAIL_KEYS.has(key)) throw new TypeError(`unsupported safe detail key '${key}'`);
    const values = Array.isArray(value) ? value : [value];
    if (values.length > 32 || !values.every(safeScalar)) {
      throw new TypeError(`safe detail '${key}' must contain only bounded path-free tokens`);
    }
    normalized[key] = Array.isArray(value) ? Object.freeze([...value]) : value;
  }
  return Object.freeze(normalized);
}

export const CLIENT_ERROR_DEFINITIONS = DEFINITIONS;

export class ClientIntegrationError extends Error {
  constructor(code, { phase = "pre_acceptance", retryable = undefined, safeDetails = undefined } = {}) {
    const definition = DEFINITIONS[code];
    if (!definition) throw new TypeError(`unknown client integration error code '${code}'`);
    if (!PHASES.has(phase)) throw new TypeError(`invalid client integration error phase '${phase}'`);
    if (retryable !== undefined && typeof retryable !== "boolean") {
      throw new TypeError("retryable must be a boolean");
    }
    super(definition[0]);
    this.name = "ClientIntegrationError";
    this.code = code;
    this.phase = phase;
    this.retryable = retryable ?? definition[1];
    const details = normalizeSafeDetails(safeDetails);
    if (details !== undefined) this.safeDetails = details;
    Object.freeze(this);
  }

  toJSON() {
    return {
      code: this.code,
      phase: this.phase,
      retryable: this.retryable,
      message: this.message,
      ...(this.safeDetails === undefined ? {} : { safe_details: this.safeDetails }),
    };
  }
}
