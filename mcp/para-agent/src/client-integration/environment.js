import { ClientIntegrationError } from "./errors.js";
import { deepFreeze } from "./semantic-json.js";

const ENVIRONMENT_NAME = /^[A-Za-z_][A-Za-z0-9_]*$/;
const SOURCE_ID = /^[a-z][a-z0-9_.-]*$/;
const SAFE_EVIDENCE_KIND = /^[A-Za-z0-9_.:-]{1,128}$/;
const ENTRY_KEYS = new Set(["name", "kind", "value", "source_id"]);

function fail(code) {
  throw new ClientIntegrationError(code);
}

function isWellFormedString(value) {
  if (typeof value !== "string" || value.includes("\0")) return false;
  for (let index = 0; index < value.length; index += 1) {
    const code = value.charCodeAt(index);
    if (code >= 0xd800 && code <= 0xdbff) {
      const next = value.charCodeAt(index + 1);
      if (!(next >= 0xdc00 && next <= 0xdfff)) return false;
      index += 1;
    } else if (code >= 0xdc00 && code <= 0xdfff) {
      return false;
    }
  }
  return true;
}

function assertEnvironmentName(name) {
  if (typeof name !== "string" || !ENVIRONMENT_NAME.test(name)) {
    fail("CLIENT_ENV_NAME_INVALID", "environment name is not portable");
  }
  return name;
}

function assertEnvironmentValue(value) {
  if (!isWellFormedString(value)) {
    fail("CLIENT_ENV_SOURCE_INVALID", "environment value must be a well-formed string without NUL");
  }
  return value;
}

function normalizeName(name, platform) {
  return platform === "win32" ? name.replace(/[a-z]/g, (letter) => letter.toUpperCase()) : name;
}

function compileDeclarations(variables, platform) {
  if (!Array.isArray(variables)) {
    fail("CLIENT_ENV_SOURCE_INVALID", "environment variables must be declared as an array");
  }
  const declarations = [];
  const byKey = new Map();
  for (const variable of variables) {
    if (variable === null || typeof variable !== "object" || Array.isArray(variable)) {
      fail("CLIENT_ENV_SOURCE_INVALID", "environment declaration is invalid");
    }
    const keys = Object.keys(variable);
    if (keys.some((key) => !["name", "required", "secret"].includes(key))) {
      fail("CLIENT_ENV_SOURCE_INVALID", "environment declaration has unknown fields");
    }
    const name = assertEnvironmentName(variable.name);
    if (typeof variable.required !== "boolean" || typeof variable.secret !== "boolean") {
      fail("CLIENT_ENV_SOURCE_INVALID", "environment declaration flags must be boolean");
    }
    const key = normalizeName(name, platform);
    if (byKey.has(key)) {
      const code = platform === "win32" && byKey.get(key).name !== name
        ? "CLIENT_ENV_CASE_COLLISION"
        : "CLIENT_ENV_SOURCE_INVALID";
      fail(code, "environment declarations collide");
    }
    const declaration = { name, required: variable.required, secret: variable.secret };
    declarations.push(declaration);
    byKey.set(key, declaration);
  }
  return { declarations, byKey };
}

function ambientLookup(parentEnvironment, ambientName, platform, sourceCache) {
  assertEnvironmentName(ambientName);
  if (parentEnvironment === null || typeof parentEnvironment !== "object" || Array.isArray(parentEnvironment)) {
    fail("CLIENT_ENV_SOURCE_INVALID", "parent environment must be an object");
  }
  const expected = normalizeName(ambientName, platform);
  if (sourceCache.has(expected)) return sourceCache.get(expected);
  const matches = Object.keys(parentEnvironment).filter((name) => (
    ENVIRONMENT_NAME.test(name) && normalizeName(name, platform) === expected
  ));
  if (matches.length > 1) {
    fail("CLIENT_ENV_CASE_COLLISION", "ambient environment names collide with canonical spelling");
  }
  if (matches.length === 0) {
    fail("CLIENT_ENV_SOURCE_MISSING", "declared environment source is missing");
  }
  const value = assertEnvironmentValue(parentEnvironment[matches[0]]);
  sourceCache.set(expected, value);
  return value;
}

function resolveEntryValue(entry, declaration, sources, parentEnvironment, platform, sourceCache) {
  switch (entry.kind) {
    case "literal":
      if (declaration.secret || Object.hasOwn(entry, "source_id")) {
        fail("CLIENT_ENV_SOURCE_INVALID", "secret or source-backed environment values cannot be literal");
      }
      return assertEnvironmentValue(entry.value);
    case "inherit":
      if (declaration.secret || Object.hasOwn(entry, "value") || Object.hasOwn(entry, "source_id")) {
        fail("CLIENT_ENV_SOURCE_INVALID", "environment inheritance declaration is invalid");
      }
      return ambientLookup(parentEnvironment, declaration.name, platform, sourceCache);
    case "source": {
      if (Object.hasOwn(entry, "value") || !SOURCE_ID.test(entry.source_id ?? "")) {
        fail("CLIENT_ENV_SOURCE_INVALID", "named environment source declaration is invalid");
      }
      if (!Object.hasOwn(sources, entry.source_id)) {
        fail("CLIENT_ENV_SOURCE_MISSING", "declared environment source is missing");
      }
      const binding = sources[entry.source_id];
      if (
        binding === null
        || typeof binding !== "object"
        || Array.isArray(binding)
        || binding.kind !== "process_env"
        || Object.keys(binding).some((key) => !["kind", "name"].includes(key))
      ) {
        fail("CLIENT_ENV_SOURCE_INVALID", "environment source binding is invalid");
      }
      return ambientLookup(parentEnvironment, binding.name, platform, sourceCache);
    }
    default:
      fail("CLIENT_ENV_SOURCE_INVALID", "environment entry kind is unsupported");
  }
}

export function compileEnvironment({
  variables,
  layers = [],
  sources = {},
  parentEnvironment = {},
  platform = process.platform,
}) {
  if (platform !== "win32" && platform !== "linux" && platform !== "darwin") {
    fail("CLIENT_ENV_SOURCE_INVALID", "environment platform is unsupported");
  }
  if (!Array.isArray(layers)) {
    fail("CLIENT_ENV_SOURCE_INVALID", "environment layers must be an array");
  }
  if (sources === null || typeof sources !== "object" || Array.isArray(sources)) {
    fail("CLIENT_ENV_SOURCE_INVALID", "environment sources must be an object");
  }

  const { declarations, byKey } = compileDeclarations(variables, platform);
  const values = new Map();
  const tombstones = new Set();
  const spelling = new Map();
  const sourceCache = new Map();

  for (const layer of layers) {
    const entries = layer?.entries;
    if (!Array.isArray(entries)) {
      fail("CLIENT_ENV_SOURCE_INVALID", "environment layer entries must be an array");
    }
    for (const entry of entries) {
      if (entry === null || typeof entry !== "object" || Array.isArray(entry)) {
        fail("CLIENT_ENV_SOURCE_INVALID", "environment entry is invalid");
      }
      if (Object.keys(entry).some((key) => !ENTRY_KEYS.has(key))) {
        fail("CLIENT_ENV_SOURCE_INVALID", "environment entry has unknown fields");
      }
      const suppliedName = assertEnvironmentName(entry.name);
      const key = normalizeName(suppliedName, platform);
      const declaration = byKey.get(key);
      if (!declaration) {
        fail("CLIENT_ENV_SOURCE_INVALID", "environment entry is not declared");
      }
      if (platform === "win32" && declaration.name !== suppliedName) {
        fail("CLIENT_ENV_CASE_COLLISION", "environment entry changes canonical name spelling");
      }
      if (spelling.has(key) && spelling.get(key) !== suppliedName) {
        fail("CLIENT_ENV_CASE_COLLISION", "environment names collide across layers");
      }
      spelling.set(key, suppliedName);

      if (entry.kind === "unset") {
        if (Object.keys(entry).some((entryKey) => !["name", "kind"].includes(entryKey))) {
          fail("CLIENT_ENV_SOURCE_INVALID", "environment unset declaration is invalid");
        }
        if (declaration.required) {
          fail("CLIENT_ENV_REQUIRED_UNSET", "required environment value cannot be unset");
        }
        values.delete(key);
        tombstones.add(key);
        continue;
      }
      if (tombstones.has(key)) {
        fail("CLIENT_POLICY_WIDENING", "an environment tombstone cannot be restored by a later layer");
      }
      values.set(key, resolveEntryValue(
        entry,
        declaration,
        sources,
        parentEnvironment,
        platform,
        sourceCache,
      ));
    }
  }

  for (const declaration of declarations) {
    const key = normalizeName(declaration.name, platform);
    if (declaration.required && !values.has(key)) {
      fail("CLIENT_ENV_SOURCE_MISSING", "required environment value was not resolved");
    }
  }

  const environment = {};
  let containsSecret = false;
  for (const declaration of declarations) {
    const key = normalizeName(declaration.name, platform);
    if (!values.has(key)) continue;
    Object.defineProperty(environment, declaration.name, {
      value: values.get(key),
      enumerable: true,
      configurable: true,
      writable: true,
    });
    containsSecret ||= declaration.secret;
  }

  return deepFreeze({
    private: {
      environment,
      contains_secret: containsSecret,
    },
    descriptor: {},
    readiness_facts: {
      environment_sources: {
        required_count: sourceCache.size,
        resolved_count: sourceCache.size,
      },
    },
    plan_intent: { child_environment: "replace" },
  });
}

export function compileClientEnvironment({
  integrationEnvironment,
  hostEnvironment,
  sessionEnvironment,
  parentEnvironment = {},
  platform = process.platform,
}) {
  if (
    integrationEnvironment === null
    || typeof integrationEnvironment !== "object"
    || hostEnvironment === null
    || typeof hostEnvironment !== "object"
    || sessionEnvironment === null
    || typeof sessionEnvironment !== "object"
  ) {
    fail("CLIENT_ENV_SOURCE_INVALID", "resolved environment profiles are invalid");
  }
  return compileEnvironment({
    variables: integrationEnvironment.variables,
    layers: [
      { entries: integrationEnvironment.entries },
      { entries: hostEnvironment.entries },
      { entries: sessionEnvironment.entries },
    ],
    sources: hostEnvironment.sources,
    parentEnvironment,
    platform,
  });
}

export function assertEnvironmentBackend(
  compiledEnvironment,
  { backendKind, exactIsolationProof } = {},
) {
  if (
    compiledEnvironment === null
    || typeof compiledEnvironment !== "object"
    || compiledEnvironment.private === null
    || typeof compiledEnvironment.private !== "object"
    || typeof compiledEnvironment.private.contains_secret !== "boolean"
  ) {
    fail("CLIENT_ENV_SOURCE_INVALID", "compiled environment result is invalid");
  }
  if (backendKind !== "process" && backendKind !== "managed_mux") {
    fail("CLIENT_ENV_ISOLATION_UNPROVEN", "environment backend is unsupported");
  }
  if (backendKind === "managed_mux" && compiledEnvironment.private.contains_secret) {
    fail("CLIENT_ENV_SECRET_UNSAFE_BACKEND", "managed mux cannot receive secret-classified environment sources");
  }
  if (
    exactIsolationProof === null
    || typeof exactIsolationProof !== "object"
    || Array.isArray(exactIsolationProof)
    || Object.keys(exactIsolationProof).length !== 3
    || Object.keys(exactIsolationProof).some((key) => ![
      "state",
      "backend_kind",
      "evidence_kind",
    ].includes(key))
    || exactIsolationProof.state !== "passed"
    || exactIsolationProof.backend_kind !== backendKind
    || !SAFE_EVIDENCE_KIND.test(exactIsolationProof.evidence_kind ?? "")
  ) {
    fail("CLIENT_ENV_ISOLATION_UNPROVEN", "managed mux environment isolation has not been proven");
  }
  return deepFreeze({
    private: compiledEnvironment.private,
    descriptor: compiledEnvironment.descriptor,
    plan_intent: compiledEnvironment.plan_intent,
    backend_proof: {
      state: "passed",
      backend_kind: backendKind,
      evidence_kind: exactIsolationProof.evidence_kind,
    },
    readiness_facts: {
      ...compiledEnvironment.readiness_facts,
      environment_exact: { exact: true },
      backend: { kind: backendKind },
    },
  });
}
