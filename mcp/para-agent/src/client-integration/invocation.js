import { ClientIntegrationError } from "./errors.js";
import { assertReadinessDescriptor, compileReadinessProfile } from "./readiness.js";

const IDENTIFIER = /^[a-z][a-z0-9_.-]*$/;
const SHA256 = /^[a-f0-9]{64}$/;
const CARRIER_KINDS = new Set(["stdin_utf8", "prompt_file"]);
const BACKEND_KINDS = new Set(["process", "managed_mux"]);
const TOP_LEVEL_KEYS = new Set([
  "resolved",
  "environmentResult",
  "workspaceResult",
  "policyResult",
]);

function fail(code, options = {}) {
  throw new ClientIntegrationError(code, options);
}

function plainObject(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    fail("INVOCATION_PLAN_INVALID");
  }
  const prototype = Object.getPrototypeOf(value);
  if (prototype !== Object.prototype && prototype !== null) fail("INVOCATION_PLAN_INVALID");
  if (Object.getOwnPropertySymbols(value).length > 0) fail("INVOCATION_PLAN_INVALID");
  for (const key of Object.keys(value)) {
    const descriptor = Object.getOwnPropertyDescriptor(value, key);
    if (!descriptor || !("value" in descriptor) || descriptor.enumerable !== true) {
      fail("INVOCATION_PLAN_INVALID");
    }
  }
  return value;
}

function exactKeys(value, allowed) {
  plainObject(value);
  if (Object.keys(value).some((key) => !allowed.has(key))) {
    fail("INVOCATION_PLAN_INVALID");
  }
}

function safeString(value, { identifier = false, phase = "pre_acceptance" } = {}) {
  if (
    typeof value !== "string"
    || value.length === 0
    || value.includes("\0")
    || (typeof value.isWellFormed === "function" && !value.isWellFormed())
    || (identifier && !IDENTIFIER.test(value))
  ) {
    fail("INVOCATION_PLAN_INVALID", { phase });
  }
  return value;
}

function digest(value) {
  if (typeof value !== "string" || !SHA256.test(value)) {
    fail("INVOCATION_PLAN_INVALID");
  }
  return value;
}

function clone(value) {
  if (Array.isArray(value)) return value.map(clone);
  if (value && typeof value === "object") {
    const result = {};
    for (const [key, child] of Object.entries(value)) {
      Object.defineProperty(result, key, {
        value: clone(child),
        enumerable: true,
        configurable: true,
        writable: true,
      });
    }
    return result;
  }
  return value;
}

export function deepFreeze(value) {
  if (value && (typeof value === "object" || typeof value === "function") && !Object.isFrozen(value)) {
    Object.freeze(value);
    for (const child of Object.values(value)) deepFreeze(child);
  }
  return value;
}

function identityPair(value, { closed = false } = {}) {
  plainObject(value);
  if (closed) exactKeys(value, new Set(["id", "revision"]));
  return {
    id: safeString(value.id, { identifier: true }),
    revision: safeString(value.revision),
  };
}

function adapterBinding(value) {
  exactKeys(value, new Set(["id", "version", "profile_id"]));
  return {
    id: safeString(value.id),
    version: safeString(value.version),
    profile_id: safeString(value.profile_id),
  };
}

function workspaceBinding(value) {
  exactKeys(value, new Set(["id", "working_directory_id"]));
  return {
    id: safeString(value.id, { identifier: true }),
    working_directory_id: safeString(value.working_directory_id, { identifier: true }),
  };
}

function policyBinding(value) {
  exactKeys(value, new Set(["session_sha256", "effective_sha256"]));
  return {
    session_sha256: digest(value.session_sha256),
    effective_sha256: digest(value.effective_sha256),
  };
}

function carrierRecipe(value, hostBinding) {
  plainObject(value);
  const kind = value.kind;
  if (!CARRIER_KINDS.has(kind)) fail("PROMPT_CARRIER_UNSUPPORTED");
  if (kind === "stdin_utf8") {
    exactKeys(value, new Set(["kind"]));
    return { kind };
  }
  exactKeys(value, new Set(["kind", "arg_template"]));
  const root = hostBinding?.runtime?.prompt_file_root;
  return { kind, root: safeString(root) };
}

function carrierBinding(value) {
  exactKeys(value, new Set(["kind"]));
  if (!CARRIER_KINDS.has(value.kind)) fail("INVOCATION_PLAN_INVALID");
  return { kind: value.kind };
}

function stdioBinding(value, kind) {
  exactKeys(value, new Set(["prompt", "semantic", "diagnostic"]));
  const expectedPrompt = kind === "stdin_utf8" ? "stdin" : "file";
  if (value.prompt !== expectedPrompt || value.semantic !== "stdout" || value.diagnostic !== "stderr") {
    fail("INVOCATION_PLAN_INVALID");
  }
  return {
    prompt: expectedPrompt,
    semantic: "stdout",
    diagnostic: "stderr",
  };
}

function environmentMap(value) {
  plainObject(value);
  const result = {};
  for (const [name, child] of Object.entries(value)) {
    if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(name) || typeof child !== "string" || child.includes("\0")) {
      fail("INVOCATION_PLAN_INVALID");
    }
    Object.defineProperty(result, name, {
      value: child,
      enumerable: true,
      configurable: true,
      writable: true,
    });
  }
  return result;
}

function argvTemplate(modeProfile, kind) {
  if (!Array.isArray(modeProfile.fixed_args)) fail("INVOCATION_PLAN_INVALID");
  const carrierArguments = kind === "prompt_file" ? modeProfile.carrier.arg_template : [];
  if (!Array.isArray(carrierArguments)) fail("INVOCATION_PLAN_INVALID");
  const value = [...modeProfile.fixed_args, ...carrierArguments];
  let carrierSlots = 0;
  const result = value.map((part, index) => {
    safeString(part);
    if (part === "{exchange_id}" && index < modeProfile.fixed_args.length) {
      return { slot: "exchange_id" };
    }
    if (part === "{carrier_path}" && index >= modeProfile.fixed_args.length) {
      carrierSlots += 1;
      return { slot: "carrier_path" };
    }
    if (/^\{[^{}]+\}$/.test(part)) fail("INVOCATION_PLAN_INVALID");
    return part;
  });
  if ((kind === "prompt_file" && carrierSlots !== 1) || (kind === "stdin_utf8" && carrierSlots !== 0)) {
    fail("INVOCATION_PLAN_INVALID");
  }
  return result;
}

function effectiveAllowedVersions(resolved) {
  if (!Array.isArray(resolved.supportedVersions)) fail("INVOCATION_PLAN_INVALID");
  const expected = resolved.hostBinding?.executable?.expected_version;
  if (expected === undefined) return [...resolved.supportedVersions];
  if (!resolved.supportedVersions.includes(expected)) fail("INVOCATION_PLAN_INVALID");
  return [expected];
}

/**
 * Compile already-resolved authority into a private, exchange-independent recipe
 * and a separately constructed safe descriptor basis.
 */
export function compileInvocationRecipe(input) {
  exactKeys(input, TOP_LEVEL_KEYS);
  const resolved = plainObject(input.resolved);
  const modeProfile = plainObject(resolved.modeProfile);
  exactKeys(modeProfile, new Set(["fixed_args", "carrier", "stdio", "readiness", "backend"]));
  if (!BACKEND_KINDS.has(modeProfile.backend)) fail("INVOCATION_PLAN_INVALID");
  const carrier = carrierRecipe(modeProfile.carrier, resolved.hostBinding);
  const stdio = stdioBinding(modeProfile.stdio, carrier.kind);
  const environment = environmentMap(input.environmentResult?.private?.environment);
  const workspace = workspaceBinding(input.workspaceResult?.descriptor?.workspace);
  const policy = policyBinding({
    session_sha256: input.policyResult?.session_sha256,
    effective_sha256: input.policyResult?.effective_sha256,
  });
  const executable = safeString(resolved.hostBinding?.executable?.path);
  const translatedReadiness = compileReadinessProfile(modeProfile.readiness, {
    executable,
    effectiveAllowedVersions: effectiveAllowedVersions(resolved),
  });
  const descriptorBasis = deepFreeze({
    descriptor_version: 1,
    integration: identityPair(resolved.integration),
    adapter: adapterBinding(resolved.adapter),
    surface: safeString(resolved.surface, { identifier: true }),
    mode: safeString(resolved.mode, { identifier: true }),
    session_profile: identityPair(resolved.sessionProfile),
    workspace,
    policy,
    carrier: { kind: carrier.kind },
    stdio: { ...stdio },
  });

  const recipe = deepFreeze({
    recipe_version: 1,
    executable,
    argv_template: argvTemplate(modeProfile, carrier.kind),
    cwd: safeString(input.workspaceResult?.private?.cwd),
    environment,
    carrier,
    backend: { kind: modeProfile.backend },
    stdio: { ...stdio },
    readiness: translatedReadiness,
  });

  return deepFreeze({ recipe, descriptorBasis });
}

/** Complete the durable/public descriptor from allowlisted readiness facts only. */
export function finalizeInvocationDescriptor(descriptorBasis, readiness) {
  plainObject(descriptorBasis);
  exactKeys(descriptorBasis, new Set([
    "descriptor_version",
    "integration",
    "adapter",
    "surface",
    "mode",
    "session_profile",
    "workspace",
    "policy",
    "carrier",
    "stdio",
  ]));
  if (descriptorBasis.descriptor_version !== 1) fail("INVOCATION_PLAN_INVALID");
  const integration = identityPair(descriptorBasis.integration, { closed: true });
  const adapter = adapterBinding(descriptorBasis.adapter);
  const surface = safeString(descriptorBasis.surface, { identifier: true });
  const mode = safeString(descriptorBasis.mode, { identifier: true });
  const sessionProfile = identityPair(descriptorBasis.session_profile, { closed: true });
  const workspace = workspaceBinding(descriptorBasis.workspace);
  const policy = policyBinding(descriptorBasis.policy);
  const carrier = carrierBinding(descriptorBasis.carrier);
  const stdio = stdioBinding(descriptorBasis.stdio, carrier.kind);
  const checkedReadiness = assertReadinessDescriptor(readiness, integration.revision);
  return deepFreeze({
    descriptor_version: 1,
    integration,
    adapter,
    surface,
    mode,
    session_profile: sessionProfile,
    workspace,
    policy,
    carrier,
    stdio,
    readiness: clone(checkedReadiness),
  });
}

function privateCarrier(value, expectedKind) {
  plainObject(value);
  if (value.kind !== expectedKind) fail("INVOCATION_PLAN_INVALID", { phase: "accepted" });
  if (!Number.isSafeInteger(value.bytes) || value.bytes < 0 || !SHA256.test(value.sha256 ?? "")) {
    fail("INVOCATION_PLAN_INVALID", { phase: "accepted" });
  }
  if (expectedKind === "stdin_utf8") {
    if (typeof value.readBytes !== "function" || Object.hasOwn(value, "path")) {
      fail("INVOCATION_PLAN_INVALID", { phase: "accepted" });
    }
  } else if (typeof value.path !== "string" || value.path.length === 0 || typeof value.cleanup !== "function") {
    fail("INVOCATION_PLAN_INVALID", { phase: "accepted" });
  }
  return value;
}

/** Fill only declared exchange/carrier slots and return the immutable private plan. */
export function finalizeInvocationPlan(recipe, { exchangeId, carrier } = {}) {
  plainObject(recipe);
  if (
    recipe.recipe_version !== 1
    || !CARRIER_KINDS.has(recipe.carrier?.kind)
    || !BACKEND_KINDS.has(recipe.backend?.kind)
  ) {
    fail("INVOCATION_PLAN_INVALID", { phase: "accepted" });
  }
  const id = safeString(exchangeId, { phase: "accepted" });
  const checkedCarrier = privateCarrier(carrier, recipe.carrier.kind);
  const argv = recipe.argv_template.map((part) => {
    if (typeof part === "string") return part;
    if (part.slot === "exchange_id") return id;
    if (part.slot === "carrier_path" && checkedCarrier.kind === "prompt_file") return checkedCarrier.path;
    fail("INVOCATION_PLAN_INVALID", { phase: "accepted" });
  });

  const prompt = checkedCarrier.kind === "stdin_utf8"
    ? {
        kind: "stdin_utf8",
        bytes: checkedCarrier.bytes,
        sha256: checkedCarrier.sha256,
        readBytes: checkedCarrier.readBytes,
      }
    : {
        kind: "prompt_file",
        bytes: checkedCarrier.bytes,
        sha256: checkedCarrier.sha256,
        path: checkedCarrier.path,
        cleanup: checkedCarrier.cleanup,
      };

  return deepFreeze({
    plan_version: 1,
    exchange_id: id,
    executable: recipe.executable,
    argv,
    cwd: recipe.cwd,
    environment: clone(recipe.environment),
    backend: clone(recipe.backend),
    stdio: clone(recipe.stdio),
    prompt,
  });
}
