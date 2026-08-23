/**
 * Transactional JSON configuration provider for managed client integrations.
 *
 * Source objects are cloned before validation and only a complete, validated,
 * deeply frozen snapshot becomes observable. Reload failure leaves the prior
 * snapshot untouched.
 */

import { createHash } from "node:crypto";
import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { Ajv2020, addFormats } from "../deps.js";

import { ClientIntegrationError } from "./errors.js";

const SOURCE_DIR = path.dirname(fileURLToPath(import.meta.url));
const SCHEMA_DIR = path.resolve(SOURCE_DIR, "..", "schemas");

export const DEFAULT_CLIENT_CONFIG_SCHEMA_PATHS = Object.freeze({
  integrations: path.join(SCHEMA_DIR, "client-integration-profile.schema.json"),
  hostBindings: path.join(SCHEMA_DIR, "client-host-binding.schema.json"),
  sessionProfiles: path.join(SCHEMA_DIR, "client-session-profile.schema.json"),
});

function configError(configurationKind, reason) {
  return new ClientIntegrationError("CLIENT_CONFIG_INVALID", {
    safeDetails: { configuration_kind: configurationKind, reason },
  });
}

function isPlainObject(value) {
  if (value === null || typeof value !== "object" || Array.isArray(value)) return false;
  const prototype = Object.getPrototypeOf(value);
  return prototype === Object.prototype || prototype === null;
}

function canonicalValue(value) {
  if (Array.isArray(value)) return `[${value.map(canonicalValue).join(",")}]`;
  if (isPlainObject(value)) {
    return `{${Object.keys(value).sort().map((key) => `${JSON.stringify(key)}:${canonicalValue(value[key])}`).join(",")}}`;
  }
  return JSON.stringify(value);
}

function sha256Canonical(value) {
  return createHash("sha256").update(canonicalValue(value), "utf8").digest("hex");
}

export function canonicalClientConfigJson(value) {
  return canonicalValue(value);
}

export function computeClientConfigSnapshotRevision(snapshot) {
  if (!isPlainObject(snapshot)) throw configError("snapshot", "shape_invalid");
  return sha256Canonical({
    schema_version: snapshot.schema_version,
    integrations: snapshot.integrations,
    host_bindings: snapshot.host_bindings,
    session_profiles: snapshot.session_profiles,
  });
}

export function deepFreezeClientConfig(value) {
  if (value && typeof value === "object" && !Object.isFrozen(value)) {
    Object.freeze(value);
    for (const child of Object.values(value)) deepFreezeClientConfig(child);
  }
  return value;
}

function cloneJsonValue(value, kind) {
  try {
    const clone = structuredClone(value);
    canonicalValue(clone);
    return clone;
  } catch {
    throw configError(kind, "non_json_value");
  }
}

function assertUnique(values, key, kind, reason = "duplicate_id") {
  const seen = new Set();
  for (const value of values) {
    const candidate = value[key];
    if (seen.has(candidate)) throw configError(kind, reason);
    seen.add(candidate);
  }
}

function assertUniqueNames(entries, kind, reason) {
  const names = new Set();
  for (const entry of entries) {
    if (names.has(entry.name)) throw configError(kind, reason);
    names.add(entry.name);
  }
}

function isWellFormedString(value) {
  if (typeof value !== "string" || value.length === 0 || value.includes("\0")) return false;
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

function assertArguments(values, allowedPlaceholders) {
  for (const value of values ?? []) {
    if (!isWellFormedString(value)) throw configError("integration_profile", "argument_invalid");
    const placeholders = value.match(/\{[a-z][a-z0-9_]*\}/g) ?? [];
    if (
      placeholders.length > 0
      && (placeholders.length !== 1 || placeholders[0] !== value || !allowedPlaceholders.has(value))
    ) {
      throw configError("integration_profile", "argument_placeholder_unknown");
    }
  }
}

const WINDOWS_DEVICE_SEGMENT = /^(?:CON|PRN|AUX|NUL|CLOCK\$|COM[1-9]|LPT[1-9])(?:\..*)?$/i;

function assertConcreteHostPath(value, platform) {
  if (!isWellFormedString(value)) throw configError("host_binding", "path_invalid");
  if (platform === "win32") {
    if (/^[\\/]{2}[?.][\\/]/.test(value)) throw configError("host_binding", "path_invalid");
    const driveAbsolute = /^[A-Za-z]:[\\/]/.test(value);
    const uncAbsolute = /^[\\/]{2}[^\\/]+[\\/][^\\/]+(?:[\\/]|$)/.test(value);
    if (!path.win32.isAbsolute(value) || (!driveAbsolute && !uncAbsolute)) {
      throw configError("host_binding", "path_not_absolute");
    }
    const root = path.win32.parse(value).root;
    const remainder = value.slice(root.length);
    const components = remainder.length === 0 ? [] : remainder.split(/[\\/]/);
    if (components.some((component) => (
      component.length === 0
      || component === "."
      || component === ".."
      || component.endsWith(".")
      || component.endsWith(" ")
      || /[<>:"|?*]/.test(component)
      || WINDOWS_DEVICE_SEGMENT.test(component)
    ))) {
      throw configError("host_binding", "path_invalid");
    }
    return;
  }
  if ((platform !== "linux" && platform !== "darwin") || !path.posix.isAbsolute(value)) {
    throw configError("host_binding", "path_not_absolute");
  }
  if (value !== "/") {
    const components = value.slice(1).split("/");
    if (components.some((component) => component.length === 0 || component === "." || component === "..")) {
      throw configError("host_binding", "path_invalid");
    }
  }
}

function assertPolicyProfile(profile) {
  const dimensions = new Set(Object.keys(profile.policy.dimensions));
  for (const section of ["ceiling", "defaults"]) {
    const keys = Object.keys(profile.policy[section]);
    if (keys.length !== dimensions.size || keys.some((key) => !dimensions.has(key))) {
      throw configError("integration_profile", "policy_dimension_mismatch");
    }
  }
}

function assertIntegrationSemantics(profile) {
  const hasSelectedSurface = Object.hasOwn(profile.surfaces, profile.default_selection.surface);
  const selectedSurface = hasSelectedSurface ? profile.surfaces[profile.default_selection.surface] : undefined;
  if (!selectedSurface || !Object.hasOwn(selectedSurface.modes, profile.default_selection.mode)) {
    throw configError("integration_profile", "default_selection_unknown");
  }

  for (const surface of Object.values(profile.surfaces)) {
    for (const mode of Object.values(surface.modes)) {
      assertArguments(mode.fixed_args, new Set(["{exchange_id}"]));
      const placeholderCount = mode.carrier.kind === "prompt_file"
        ? mode.carrier.arg_template.filter((token) => token === "{carrier_path}").length
        : 0;
      if (mode.carrier.kind === "prompt_file") {
        assertArguments(mode.carrier.arg_template, new Set(["{carrier_path}"]));
        if (mode.stdio.prompt !== "file" || placeholderCount !== 1) {
          throw configError("integration_profile", "carrier_stdio_mismatch");
        }
      } else if (mode.stdio.prompt !== "stdin") {
        throw configError("integration_profile", "carrier_stdio_mismatch");
      }
      if (mode.backend === "managed_mux" && mode.carrier.kind !== "prompt_file") {
        throw configError("integration_profile", "backend_carrier_mismatch");
      }
      assertUnique(mode.readiness.probes, "id", "integration_profile", "readiness_probe_duplicate");
      for (const probe of mode.readiness.probes) assertArguments(probe.fixed_args, new Set());
    }
  }

  assertPolicyProfile(profile);
  assertUniqueNames(profile.environment.variables, "integration_profile", "environment_variable_duplicate");
  assertUniqueNames(profile.environment.entries, "integration_profile", "environment_entry_duplicate");
  const variables = new Map(profile.environment.variables.map((variable) => [variable.name, variable]));
  for (const entry of profile.environment.entries) {
    const variable = variables.get(entry.name);
    if (!variable) throw configError("integration_profile", "environment_variable_unknown");
    if (variable.secret && entry.kind === "literal") {
      throw configError("integration_profile", "secret_literal_forbidden");
    }
    if (variable.required && entry.kind === "unset") {
      throw configError("integration_profile", "required_unset");
    }
  }
}

function assertHostSemantics(binding) {
  assertConcreteHostPath(binding.executable.path, binding.platform);
  for (const workspace of binding.workspaces) assertConcreteHostPath(workspace.root, binding.platform);
  if (binding.runtime?.prompt_file_root !== undefined) {
    assertConcreteHostPath(binding.runtime.prompt_file_root, binding.platform);
  }
  assertUnique(binding.workspaces, "id", "host_binding", "workspace_duplicate");
  assertUniqueNames(binding.environment.entries, "host_binding", "environment_entry_duplicate");
  for (const entry of binding.environment.entries) {
    if (entry.kind === "source" && !Object.hasOwn(binding.environment.sources, entry.source_id)) {
      throw configError("host_binding", "environment_source_unknown");
    }
  }
}

function assertSessionSemantics(profile) {
  assertUniqueNames(profile.environment.entries, "session_profile", "environment_entry_duplicate");
}

async function compileValidators(schemaPaths, suppliedAjv) {
  const ajv = suppliedAjv ?? addFormats(new Ajv2020({
    allErrors: true,
    strict: true,
    validateFormats: true,
  }));
  try {
    const schemas = await Promise.all([
      fs.readFile(schemaPaths.integrations, "utf8"),
      fs.readFile(schemaPaths.hostBindings, "utf8"),
      fs.readFile(schemaPaths.sessionProfiles, "utf8"),
    ]);
    return {
      integrations: ajv.compile(JSON.parse(schemas[0])),
      hostBindings: ajv.compile(JSON.parse(schemas[1])),
      sessionProfiles: ajv.compile(JSON.parse(schemas[2])),
    };
  } catch {
    throw configError("schema", "compile_failed");
  }
}

async function readJsonDirectory(directory, { required, kind }) {
  let entries;
  try {
    entries = await fs.readdir(directory, { withFileTypes: true });
  } catch (error) {
    if (!required && error?.code === "ENOENT") return [];
    throw configError(kind, error?.code === "ENOENT" ? "directory_missing" : "directory_unreadable");
  }
  const jsonEntries = entries.filter((entry) => entry.name.endsWith(".json")).sort((left, right) => (
    left.name.localeCompare(right.name, "en")
  ));
  if (jsonEntries.some((entry) => !entry.isFile())) throw configError(kind, "source_not_file");
  const values = [];
  for (const entry of jsonEntries) {
    try {
      values.push(JSON.parse(await fs.readFile(path.join(directory, entry.name), "utf8")));
    } catch {
      throw configError(kind, "parse_failed");
    }
  }
  if (required && values.length === 0) throw configError(kind, "configuration_empty");
  return values;
}

function validateValues(values, validate, kind, semanticValidator) {
  const staged = values.map((value) => cloneJsonValue(value, kind));
  for (const value of staged) {
    if (!validate(value)) throw configError(kind, "schema_invalid");
    semanticValidator(value);
  }
  return staged;
}

function makeSnapshot(integrations, hostBindings, sessionProfiles) {
  const ordered = {
    schema_version: 1,
    integrations: [...integrations].sort((left, right) => left.id.localeCompare(right.id, "en")),
    host_bindings: [...hostBindings].sort((left, right) => left.id.localeCompare(right.id, "en")),
    session_profiles: [...sessionProfiles].sort((left, right) => left.id.localeCompare(right.id, "en")),
  };
  const revision = computeClientConfigSnapshotRevision(ordered);
  return deepFreezeClientConfig({ ...ordered, revision });
}

function revisionFingerprints(integrations, hostBindings, sessionProfiles) {
  const result = new Map();
  for (const [kind, values] of [
    ["integration_profile", integrations],
    ["host_binding", hostBindings],
    ["session_profile", sessionProfiles],
  ]) {
    for (const value of values) {
      result.set(`${kind}\u0000${value.id}\u0000${value.revision}`, {
        kind,
        fingerprint: sha256Canonical(value),
      });
    }
  }
  return result;
}

export class ClientConfigProvider {
  #snapshot = null;
  #validators = null;
  #revisionFingerprints = new Map();

  constructor({
    configRoot = undefined,
    integrationsDir = configRoot === undefined ? undefined : path.join(configRoot, "integrations"),
    hostBindingsDir = configRoot === undefined ? undefined : path.join(configRoot, "host-bindings"),
    sessionProfilesDir = configRoot === undefined ? undefined : path.join(configRoot, "session-profiles"),
    schemaPaths = DEFAULT_CLIENT_CONFIG_SCHEMA_PATHS,
    ajv = undefined,
  } = {}) {
    this.directories = Object.freeze({ integrationsDir, hostBindingsDir, sessionProfilesDir });
    this.schemaPaths = Object.freeze({ ...schemaPaths });
    this.ajv = ajv;
  }

  async #getValidators() {
    this.#validators ??= await compileValidators(this.schemaPaths, this.ajv);
    return this.#validators;
  }

  /** Load a complete filesystem snapshot. Host bindings are intentionally optional. */
  async load() {
    const { integrationsDir, hostBindingsDir, sessionProfilesDir } = this.directories;
    if (!integrationsDir || !sessionProfilesDir) throw configError("provider", "directories_required");
    const [integrations, hostBindings, sessionProfiles] = await Promise.all([
      readJsonDirectory(integrationsDir, { required: true, kind: "integration_profile" }),
      hostBindingsDir
        ? readJsonDirectory(hostBindingsDir, { required: false, kind: "host_binding" })
        : [],
      readJsonDirectory(sessionProfilesDir, { required: true, kind: "session_profile" }),
    ]);
    return this.replace({ integrations, hostBindings, sessionProfiles });
  }

  /** Atomically replace the source values, primarily for embedded/test providers. */
  async replace({ integrations, hostBindings = [], sessionProfiles }) {
    if (!Array.isArray(integrations) || !Array.isArray(hostBindings) || !Array.isArray(sessionProfiles)) {
      throw configError("provider", "configuration_arrays_required");
    }
    if (integrations.length === 0 || sessionProfiles.length === 0) {
      throw configError("provider", "configuration_empty");
    }

    const validators = await this.#getValidators();
    const stagedIntegrations = validateValues(
      integrations,
      validators.integrations,
      "integration_profile",
      assertIntegrationSemantics,
    );
    const stagedHostBindings = validateValues(
      hostBindings,
      validators.hostBindings,
      "host_binding",
      assertHostSemantics,
    );
    const stagedSessionProfiles = validateValues(
      sessionProfiles,
      validators.sessionProfiles,
      "session_profile",
      assertSessionSemantics,
    );

    assertUnique(stagedIntegrations, "id", "integration_profile");
    assertUnique(stagedIntegrations, "application_id", "integration_profile", "duplicate_application");
    assertUnique(stagedHostBindings, "id", "host_binding");
    assertUnique(stagedHostBindings, "integration_id", "host_binding", "duplicate_integration_binding");
    assertUnique(stagedSessionProfiles, "id", "session_profile");

    const integrationById = new Map(stagedIntegrations.map((profile) => [profile.id, profile]));
    for (const binding of stagedHostBindings) {
      const integration = integrationById.get(binding.integration_id);
      if (!integration || integration.revision !== binding.integration_revision) {
        throw configError("host_binding", "integration_reference_invalid");
      }
    }

    const fingerprints = revisionFingerprints(
      stagedIntegrations,
      stagedHostBindings,
      stagedSessionProfiles,
    );
    for (const [key, candidate] of fingerprints) {
      const prior = this.#revisionFingerprints.get(key);
      if (prior && prior.fingerprint !== candidate.fingerprint) {
        throw configError(candidate.kind, "revision_content_changed");
      }
    }

    const snapshot = makeSnapshot(stagedIntegrations, stagedHostBindings, stagedSessionProfiles);
    for (const [key, candidate] of fingerprints) this.#revisionFingerprints.set(key, candidate);
    this.#snapshot = snapshot;
    return snapshot;
  }

  getSnapshot() {
    if (!this.#snapshot) throw configError("provider", "not_initialized");
    return this.#snapshot;
  }
}
