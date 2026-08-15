/**
 * Deterministic registry joining integration, adapter, host, and session facts.
 *
 * Registry selection returns frozen launch authority. It never treats the
 * public application selector, adapter evidence lists, or preflight-observed
 * versions as provenance. Version pins are optional.
 */

import { ClientIntegrationError } from "./errors.js";
import {
  computeClientConfigSnapshotRevision,
  deepFreezeClientConfig,
} from "./config-provider.js";

function configError(kind, reason) {
  return new ClientIntegrationError("CLIENT_CONFIG_INVALID", {
    safeDetails: { configuration_kind: kind, reason },
  });
}

function incompatible(reason) {
  return new ClientIntegrationError("INTEGRATION_ADAPTER_INCOMPATIBLE", {
    safeDetails: { reason },
  });
}

function cloneFrozen(value, kind) {
  try {
    return deepFreezeClientConfig(structuredClone(value));
  } catch {
    throw configError(kind, "non_json_value");
  }
}

function indexUnique(values, key, kind, reason = "duplicate_id") {
  const result = new Map();
  for (const value of values) {
    const candidate = value?.[key];
    if (typeof candidate !== "string" || candidate.length === 0) {
      throw configError(kind, "identity_missing");
    }
    if (result.has(candidate)) throw configError(kind, reason);
    result.set(candidate, value);
  }
  return result;
}

function assertSnapshotShape(snapshot) {
  if (
    !snapshot || snapshot.schema_version !== 1
    || typeof snapshot.revision !== "string" || !/^[a-f0-9]{64}$/.test(snapshot.revision)
    || !Array.isArray(snapshot.integrations)
    || !Array.isArray(snapshot.host_bindings)
    || !Array.isArray(snapshot.session_profiles)
    || Object.keys(snapshot).some((key) => !new Set([
      "schema_version",
      "revision",
      "integrations",
      "host_bindings",
      "session_profiles",
    ]).has(key))
  ) {
    throw configError("snapshot", "shape_invalid");
  }
  if (computeClientConfigSnapshotRevision(snapshot) !== snapshot.revision) {
    throw configError("snapshot", "revision_mismatch");
  }
}

function adapterIdentity(profile) {
  if (
    !profile || typeof profile !== "object" || Array.isArray(profile)
    || typeof profile.profile_id !== "string"
    || !profile.adapter || typeof profile.adapter.id !== "string" || typeof profile.adapter.version !== "string"
    || !profile.application || typeof profile.application.id !== "string"
    || !Array.isArray(profile.application.verified_versions)
  ) {
    throw incompatible("adapter_profile_invalid");
  }
  return `${profile.adapter.id}\u0000${profile.adapter.version}\u0000${profile.profile_id}`;
}

function assertPolicyKeys(integration, hostBinding) {
  const dimensions = new Set(Object.keys(integration.policy.dimensions));
  if (Object.keys(hostBinding.policy.ceiling).length !== dimensions.size) {
    throw configError("host_binding", "policy_ceiling_incomplete");
  }
  for (const section of ["ceiling", "defaults"]) {
    const keys = Object.keys(hostBinding.policy[section]);
    if (keys.some((key) => !dimensions.has(key))) {
      throw configError("host_binding", "policy_dimension_unknown");
    }
  }
}

function assertEnvironmentEntries(integration, binding) {
  const variables = new Map(integration.environment.variables.map((variable) => [variable.name, variable]));
  for (const entry of binding.environment.entries) {
    const variable = variables.get(entry.name);
    if (!variable) throw configError("host_binding", "environment_variable_unknown");
    if (variable.secret && entry.kind === "literal") {
      throw configError("host_binding", "secret_literal_forbidden");
    }
    if (variable.required && entry.kind === "unset") {
      throw configError("host_binding", "required_unset");
    }
  }
  for (const entry of integration.environment.entries) {
    if (entry.kind === "source" && !Object.hasOwn(binding.environment.sources, entry.source_id)) {
      throw configError("host_binding", "environment_source_unknown");
    }
  }
}

function assertSessionCompatible(integration, hostBinding, sessionProfile) {
  const dimensions = new Set(Object.keys(integration.policy.dimensions));
  if (Object.keys(sessionProfile.policy.values).some((key) => !dimensions.has(key))) {
    throw configError("session_profile", "policy_dimension_unknown");
  }
  const variables = new Map(integration.environment.variables.map((variable) => [variable.name, variable]));
  for (const entry of sessionProfile.environment.entries) {
    const variable = variables.get(entry.name);
    if (!variable) throw configError("session_profile", "environment_variable_unknown");
    if (variable.secret && entry.kind === "literal") {
      throw configError("session_profile", "secret_literal_forbidden");
    }
    if (variable.required && entry.kind === "unset") {
      throw configError("session_profile", "required_unset");
    }
    if (entry.kind === "source" && !Object.hasOwn(hostBinding.environment.sources, entry.source_id)) {
      throw configError("session_profile", "environment_source_unknown");
    }
  }
}

function selectSurfaceMode(integration, requestedSurface, requestedMode) {
  if (requestedSurface !== undefined && (typeof requestedSurface !== "string" || requestedSurface.length === 0)) {
    throw new ClientIntegrationError("CLIENT_POLICY_UNSUPPORTED", {
      safeDetails: { selector: "surface" },
    });
  }
  if (requestedMode !== undefined && (typeof requestedMode !== "string" || requestedMode.length === 0)) {
    throw new ClientIntegrationError("CLIENT_POLICY_UNSUPPORTED", {
      safeDetails: { selector: "mode" },
    });
  }

  if (requestedSurface === undefined && requestedMode === undefined) {
    return { ...integration.default_selection };
  }

  if (requestedSurface === undefined) {
    const surfaces = Object.entries(integration.surfaces)
      .filter(([, profile]) => Object.hasOwn(profile.modes, requestedMode))
      .map(([surface]) => surface)
      .sort((left, right) => left.localeCompare(right, "en"));
    if (surfaces.length === 0) {
      throw new ClientIntegrationError("CLIENT_POLICY_UNSUPPORTED", {
        safeDetails: { selector: "mode" },
      });
    }
    if (surfaces.length !== 1) {
      throw new ClientIntegrationError("CLIENT_POLICY_AMBIGUOUS", {
        safeDetails: { selector: "surface" },
      });
    }
    return { surface: surfaces[0], mode: requestedMode };
  }

  if (!Object.hasOwn(integration.surfaces, requestedSurface)) {
    throw new ClientIntegrationError("CLIENT_POLICY_UNSUPPORTED", {
      safeDetails: { selector: "surface" },
    });
  }
  const surfaceProfile = integration.surfaces[requestedSurface];
  if (requestedMode !== undefined) {
    if (!Object.hasOwn(surfaceProfile.modes, requestedMode)) {
      throw new ClientIntegrationError("CLIENT_POLICY_UNSUPPORTED", {
        safeDetails: { selector: "mode" },
      });
    }
    return { surface: requestedSurface, mode: requestedMode };
  }

  if (requestedSurface === integration.default_selection.surface) {
    return { surface: requestedSurface, mode: integration.default_selection.mode };
  }
  const modes = Object.keys(surfaceProfile.modes).sort((left, right) => left.localeCompare(right, "en"));
  if (modes.length !== 1) {
    throw new ClientIntegrationError("CLIENT_POLICY_AMBIGUOUS", {
      safeDetails: { selector: "mode" },
    });
  }
  return { surface: requestedSurface, mode: modes[0] };
}

export class ClientRegistry {
  #byApplication;
  #sessions;

  constructor(snapshot, { adapterProfiles = [] } = {}) {
    const frozenSnapshot = cloneFrozen(snapshot, "snapshot");
    assertSnapshotShape(frozenSnapshot);
    if (!Array.isArray(adapterProfiles)) throw incompatible("adapter_profiles_invalid");
    const frozenAdapters = adapterProfiles.map((profile) => cloneFrozen(profile, "adapter_profile"));

    const integrationsById = indexUnique(frozenSnapshot.integrations, "id", "integration_profile");
    const integrationsByApplication = indexUnique(
      frozenSnapshot.integrations,
      "application_id",
      "integration_profile",
      "duplicate_application",
    );
    const hostByIntegration = indexUnique(
      frozenSnapshot.host_bindings,
      "integration_id",
      "host_binding",
      "duplicate_integration_binding",
    );
    this.#sessions = indexUnique(frozenSnapshot.session_profiles, "id", "session_profile");

    const adapterByIdentity = new Map();
    for (const profile of frozenAdapters) {
      const identity = adapterIdentity(profile);
      if (adapterByIdentity.has(identity)) throw incompatible("adapter_profile_duplicate");
      adapterByIdentity.set(identity, profile);
    }

    const entries = new Map();
    for (const [applicationId, integration] of integrationsByApplication) {
      if (!integrationsById.has(integration.id)) throw configError("snapshot", "integration_index_invalid");
      const identity = `${integration.adapter.id}\u0000${integration.adapter.version}\u0000${integration.adapter.profile_id}`;
      const adapterProfile = adapterByIdentity.get(identity);
      if (!adapterProfile) throw incompatible("adapter_profile_missing");
      if (adapterProfile.verification?.status !== "verified") throw incompatible("adapter_unverified");
      if (adapterProfile.application.id !== applicationId) throw incompatible("application_identity_mismatch");

      const declaredVersions = Array.isArray(integration.executable.supported_versions)
        ? [...integration.executable.supported_versions].sort((left, right) => left.localeCompare(right, "en"))
        : [];

      const hostBinding = hostByIntegration.get(integration.id) ?? null;
      if (hostBinding) {
        if (hostBinding.integration_revision !== integration.revision) {
          throw configError("host_binding", "integration_revision_mismatch");
        }
        if (
          hostBinding.executable.expected_version !== undefined
          && declaredVersions.length > 0
          && !declaredVersions.includes(hostBinding.executable.expected_version)
        ) {
          throw incompatible("host_version_outside_intersection");
        }
        assertPolicyKeys(integration, hostBinding);
        assertEnvironmentEntries(integration, hostBinding);
      }

      const supportedVersions = hostBinding?.executable.expected_version === undefined
        ? declaredVersions
        : [hostBinding.executable.expected_version];

      entries.set(applicationId, deepFreezeClientConfig({
        applicationId,
        integration,
        adapter: {
          id: adapterProfile.adapter.id,
          version: adapterProfile.adapter.version,
          profile_id: adapterProfile.profile_id,
        },
        adapterProfile,
        supportedVersions,
        hostBinding,
      }));
    }

    this.snapshot = frozenSnapshot;
    this.adapterProfiles = deepFreezeClientConfig(frozenAdapters);
    this.#byApplication = entries;
    Object.freeze(this);
  }

  listApplications() {
    return Object.freeze([...this.#byApplication.keys()].sort((left, right) => left.localeCompare(right, "en")));
  }

  listSessionProfiles() {
    return Object.freeze([...this.#sessions.keys()].sort((left, right) => left.localeCompare(right, "en")));
  }

  getRegistration(application) {
    if (typeof application !== "string") {
      throw new ClientIntegrationError("CLIENT_UNKNOWN");
    }
    const registration = this.#byApplication.get(application);
    if (!registration) throw new ClientIntegrationError("CLIENT_UNKNOWN");
    return registration;
  }

  resolve({ application, surface = undefined, mode = undefined, sessionProfile } = {}) {
    const registration = this.getRegistration(application);
    if (!registration.hostBinding) {
      throw new ClientIntegrationError("CLIENT_UNAVAILABLE", {
        safeDetails: { availability: "host_binding_missing" },
      });
    }
    if (typeof sessionProfile !== "string" || !this.#sessions.has(sessionProfile)) {
      throw new ClientIntegrationError("SESSION_PROFILE_UNKNOWN");
    }
    const selectedSession = this.#sessions.get(sessionProfile);
    assertSessionCompatible(registration.integration, registration.hostBinding, selectedSession);

    const selection = selectSurfaceMode(registration.integration, surface, mode);
    const modeProfile = registration.integration.surfaces[selection.surface].modes[selection.mode];
    if (modeProfile.carrier.kind === "prompt_file" && !registration.hostBinding.runtime?.prompt_file_root) {
      throw configError("host_binding", "prompt_file_root_missing");
    }
    const workspaceBinding = registration.hostBinding.workspaces.find(
      (workspace) => workspace.id === selectedSession.workspace,
    );
    if (!workspaceBinding) throw new ClientIntegrationError("CLIENT_WORKSPACE_UNKNOWN");

    return deepFreezeClientConfig({
      snapshotRevision: this.snapshot.revision,
      applicationId: registration.applicationId,
      integration: registration.integration,
      hostBinding: registration.hostBinding,
      adapter: registration.adapter,
      adapterProfile: registration.adapterProfile,
      supportedVersions: registration.supportedVersions,
      surface: selection.surface,
      mode: selection.mode,
      modeProfile,
      sessionProfile: selectedSession,
      workspaceBinding,
    });
  }
}
