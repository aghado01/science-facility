import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { AdapterEngine } from "../../para-agent/src/adapters.js";
import {
  ClientConfigProvider,
  canonicalClientConfigJson,
} from "../../para-agent/src/client-integration/config-provider.js";
import {
  CLIENT_ERROR_DEFINITIONS,
  ClientIntegrationError,
} from "../../para-agent/src/client-integration/errors.js";
import { ClientRegistry } from "../../para-agent/src/client-integration/registry.js";

const TEST_DIR = path.dirname(fileURLToPath(import.meta.url));
const FIXTURE_ROOT = path.join(TEST_DIR, "fixtures", "client-integration", "registry");
const VALID_ROOT = path.join(FIXTURE_ROOT, "valid");
const MISSING_HOST_ROOT = path.join(FIXTURE_ROOT, "missing-host");

async function readJson(file) {
  return JSON.parse(await fs.readFile(file, "utf8"));
}

async function validValues() {
  return {
    integrations: [await readJson(path.join(VALID_ROOT, "integrations", "fake-client.json"))],
    hostBindings: [await readJson(path.join(VALID_ROOT, "host-bindings", "fake-client-host.json"))],
    sessionProfiles: [await readJson(path.join(VALID_ROOT, "session-profiles", "restricted.json"))],
  };
}

async function validAdapter() {
  return readJson(path.join(VALID_ROOT, "adapters", "fake-client.json"));
}

async function validRegistry() {
  const provider = new ClientConfigProvider({ configRoot: VALID_ROOT });
  const snapshot = await provider.load();
  const adapter = await validAdapter();
  return { provider, snapshot, adapter, registry: new ClientRegistry(snapshot, { adapterProfiles: [adapter] }) };
}

test("strict JSON Schema 2020-12 provider and fake adapter fixtures load together", async () => {
  const adapterEngine = await new AdapterEngine({ adaptersDir: path.join(VALID_ROOT, "adapters") }).init();
  assert.deepEqual(adapterEngine.listProfiles().map((profile) => profile.profile_id), ["fake-client/events-v1"]);

  const provider = new ClientConfigProvider({ configRoot: VALID_ROOT });
  const snapshot = await provider.load();
  const identicalReload = await provider.load();
  assert.equal(snapshot.schema_version, 1);
  assert.match(snapshot.revision, /^[a-f0-9]{64}$/);
  assert.deepEqual(snapshot.integrations.map(({ id }) => id), ["fake-client"]);
  assert.deepEqual(snapshot.host_bindings.map(({ id }) => id), ["fake-client-local"]);
  assert.deepEqual(snapshot.session_profiles.map(({ id }) => id), ["restricted"]);
  assert.ok(Object.isFrozen(snapshot));
  assert.ok(Object.isFrozen(snapshot.integrations[0].surfaces.delegate.modes.headless));
  assert.equal(identicalReload.revision, snapshot.revision);
});

test("provider snapshots defensively clone inputs and have deterministic order and revision", async () => {
  const values = await validValues();
  const secondIntegration = structuredClone(values.integrations[0]);
  secondIntegration.id = "another-fake-client";
  secondIntegration.application_id = "another-fake-client";
  secondIntegration.adapter.profile_id = "another-fake-client/events-v1";
  const secondSession = structuredClone(values.sessionProfiles[0]);
  secondSession.id = "another-restricted";

  const source = {
    integrations: [values.integrations[0], secondIntegration],
    hostBindings: values.hostBindings,
    sessionProfiles: [values.sessionProfiles[0], secondSession],
  };
  const provider = new ClientConfigProvider();
  const first = await provider.replace(source);
  source.integrations[0].revision = "mutated-after-load";
  source.sessionProfiles[0].workspace = "mutated-after-load";
  assert.equal(first.integrations.find(({ id }) => id === "fake-client").revision, "registry-v1");
  assert.equal(first.session_profiles.find(({ id }) => id === "restricted").workspace, "fake-workspace");
  assert.throws(() => {
    first.integrations[0].revision = "cannot-mutate";
  }, TypeError);

  const reversedProvider = new ClientConfigProvider();
  const reversed = await reversedProvider.replace({
    integrations: [...source.integrations].reverse().map((profile) => {
      const copy = structuredClone(profile);
      if (copy.id === "fake-client") copy.revision = "registry-v1";
      return copy;
    }),
    hostBindings: [...source.hostBindings].reverse(),
    sessionProfiles: [...source.sessionProfiles].reverse().map((profile) => {
      const copy = structuredClone(profile);
      if (copy.id === "restricted") copy.workspace = "fake-workspace";
      return copy;
    }),
  });
  assert.deepEqual(first.integrations.map(({ id }) => id), ["another-fake-client", "fake-client"]);
  assert.deepEqual(first.session_profiles.map(({ id }) => id), ["another-restricted", "restricted"]);
  assert.equal(reversed.revision, first.revision);
  assert.equal(canonicalClientConfigJson(reversed), canonicalClientConfigJson(first));
});

test("invalid present configuration fails atomically and retains the prior snapshot", async () => {
  const provider = new ClientConfigProvider();
  const values = await validValues();
  const prior = await provider.replace(values);
  const invalid = structuredClone(values);
  invalid.integrations[0].undeclared = "must-fail";

  await assert.rejects(
    provider.replace(invalid),
    (error) => error instanceof ClientIntegrationError
      && error.code === "CLIENT_CONFIG_INVALID"
      && error.message === CLIENT_ERROR_DEFINITIONS.CLIENT_CONFIG_INVALID[0]
      && error.safeDetails.configuration_kind === "integration_profile"
      && error.safeDetails.reason === "schema_invalid",
  );
  assert.equal(provider.getSnapshot(), prior);
});

test("declared revisions are immutable across atomic replace and identical reloads", async () => {
  const provider = new ClientConfigProvider();
  const values = await validValues();
  const first = await provider.replace(values);
  const identical = await provider.replace(structuredClone(values));
  assert.equal(identical.revision, first.revision);

  const changed = structuredClone(values);
  changed.integrations[0].surfaces.delegate.modes.headless.fixed_args.push("--changed");
  await assert.rejects(provider.replace(changed), {
    code: "CLIENT_CONFIG_INVALID",
    safeDetails: { configuration_kind: "integration_profile", reason: "revision_content_changed" },
  });
  assert.equal(provider.getSnapshot(), identical);

  changed.integrations[0].revision = "registry-v2";
  changed.hostBindings[0].integration_revision = "registry-v2";
  changed.hostBindings[0].revision = "host-v2";
  const advanced = await provider.replace(changed);
  assert.notEqual(advanced.revision, first.revision);
  assert.equal(advanced.integrations[0].revision, "registry-v2");
});

test("schema and semantic invalidity reject closed fields, unsafe values, and carrier mismatch", async () => {
  const base = await validValues();
  const cases = [
    (value) => { value.integrations[0].policy.dimensions.access.values = [false, true]; },
    (value) => { value.integrations[0].surfaces.delegate.modes.headless.stdio.prompt = "file"; },
    (value) => {
      value.integrations[0].environment.entries[1] = {
        name: "FAKE_TOKEN",
        kind: "literal",
        value: "must-not-be-a-secret-fixture",
      };
    },
    (value) => { value.hostBindings[0].workspaces[0].root = "bad\u0000root"; },
    (value) => { value.sessionProfiles[0].extra = true; },
    (value) => { delete value.integrations[0].surfaces.delegate.modes.headless.backend; },
    (value) => { value.integrations[0].surfaces.delegate.modes.headless.backend = "caller_selected"; },
  ];
  for (const mutate of cases) {
    const value = structuredClone(base);
    mutate(value);
    await assert.rejects(new ClientConfigProvider().replace(value), { code: "CLIENT_CONFIG_INVALID" });
  }

  const badTemplate = structuredClone(base);
  badTemplate.integrations[0].surfaces["managed-pane"].modes.console.carrier.arg_template = ["--prompt-file"];
  await assert.rejects(new ClientConfigProvider().replace(badTemplate), {
    code: "CLIENT_CONFIG_INVALID",
    safeDetails: { configuration_kind: "integration_profile", reason: "carrier_stdio_mismatch" },
  });

  const managedStdin = structuredClone(base);
  const managedMode = managedStdin.integrations[0].surfaces["managed-pane"].modes.console;
  managedMode.carrier = { kind: "stdin_utf8" };
  managedMode.stdio.prompt = "stdin";
  await assert.rejects(new ClientConfigProvider().replace(managedStdin), {
    code: "CLIENT_CONFIG_INVALID",
    safeDetails: { configuration_kind: "integration_profile", reason: "backend_carrier_mismatch" },
  });
});

test("argv templates reject empty, ill-formed, NUL, and unknown placeholder tokens atomically", async () => {
  const base = await validValues();
  const mutations = [
    (value) => { value.integrations[0].surfaces.delegate.modes.headless.fixed_args = [""]; },
    (value) => { value.integrations[0].surfaces.delegate.modes.headless.fixed_args = ["bad\u0000arg"]; },
    (value) => { value.integrations[0].surfaces.delegate.modes.headless.fixed_args = ["bad\ud800arg"]; },
    (value) => { value.integrations[0].surfaces.delegate.modes.headless.fixed_args = ["{prompt}"]; },
    (value) => { value.integrations[0].surfaces.delegate.modes.headless.fixed_args = ["--prompt={prompt}"]; },
    (value) => {
      value.integrations[0].surfaces["managed-pane"].modes.console.carrier.arg_template = [
        "--prompt-file",
        "{unknown_path}",
        "{carrier_path}",
      ];
    },
    (value) => {
      value.integrations[0].surfaces.delegate.modes.headless.readiness.probes[0].fixed_args = ["{exchange_id}"];
    },
  ];
  for (const mutate of mutations) {
    const value = structuredClone(base);
    mutate(value);
    await assert.rejects(new ClientConfigProvider().replace(value), { code: "CLIENT_CONFIG_INVALID" });
  }
});

test("host private paths are concrete absolute paths for their declared platform", async () => {
  const base = await validValues();
  const mutations = [
    (value) => { value.hostBindings[0].executable.path = "fake-client.exe"; },
    (value) => { value.hostBindings[0].workspaces[0].root = "\\current-drive-root"; },
    (value) => { value.hostBindings[0].runtime.prompt_file_root = "relative\\prompts"; },
    (value) => { value.hostBindings[0].executable.path = "D:\\safe\\..\\fake-client.exe"; },
    (value) => { value.hostBindings[0].workspaces[0].root = "D:\\CON\\workspace"; },
    (value) => { value.hostBindings[0].platform = "linux"; },
  ];
  for (const mutate of mutations) {
    const value = structuredClone(base);
    mutate(value);
    await assert.rejects(new ClientConfigProvider().replace(value), { code: "CLIENT_CONFIG_INVALID" });
  }

  const posix = structuredClone(base);
  posix.hostBindings[0].platform = "linux";
  posix.hostBindings[0].executable.path = "/opt/fake-client/bin/fake-client";
  posix.hostBindings[0].workspaces[0].root = "/srv/fake-workspace";
  posix.hostBindings[0].runtime.prompt_file_root = "/var/run/fake-client/prompts";
  const snapshot = await new ClientConfigProvider().replace(posix);
  assert.equal(snapshot.host_bindings[0].platform, "linux");
});

test("host binding is optional at load and resolves as typed unavailability", async () => {
  const provider = new ClientConfigProvider({ configRoot: MISSING_HOST_ROOT });
  const snapshot = await provider.load();
  assert.deepEqual(snapshot.host_bindings, []);
  const registry = new ClientRegistry(snapshot, { adapterProfiles: [await validAdapter()] });
  assert.throws(
    () => registry.resolve({ application: "fake-client", sessionProfile: "restricted" }),
    (error) => error instanceof ClientIntegrationError
      && error.code === "CLIENT_UNAVAILABLE"
      && error.safeDetails.availability === "host_binding_missing",
  );
});

test("registry resolves deterministic fake selections and exact version intersection", async () => {
  const { registry, adapter } = await validRegistry();
  adapter.application.verified_versions.push("mutation-after-registry");

  assert.deepEqual(registry.listApplications(), ["fake-client"]);
  assert.deepEqual(registry.listSessionProfiles(), ["restricted"]);
  const selected = registry.resolve({ application: "fake-client", sessionProfile: "restricted" });
  assert.equal(selected.surface, "delegate");
  assert.equal(selected.mode, "headless");
  assert.equal(selected.modeProfile.backend, "process");
  assert.deepEqual(selected.supportedVersions, ["1.0.0-fixture"]);
  assert.equal(selected.workspaceBinding.id, "fake-workspace");
  assert.deepEqual(selected.adapter, {
    id: "para-agent.fake-client",
    version: "1.0.0",
    profile_id: "fake-client/events-v1",
  });
  assert.equal(selected.adapterProfile.application.verified_versions.includes("mutation-after-registry"), false);
  assert.ok(Object.isFrozen(selected));
  assert.ok(Object.isFrozen(selected.modeProfile.fixed_args));

  const uniqueMode = registry.resolve({
    application: "fake-client",
    surface: "managed-pane",
    sessionProfile: "restricted",
  });
  assert.equal(uniqueMode.mode, "console");
  assert.equal(uniqueMode.modeProfile.backend, "managed_mux");
  assert.equal(uniqueMode.modeProfile.carrier.kind, "prompt_file");

  const unpinnedValues = await validValues();
  delete unpinnedValues.hostBindings[0].executable.expected_version;
  const unpinnedSnapshot = await new ClientConfigProvider().replace(unpinnedValues);
  const unpinned = new ClientRegistry(unpinnedSnapshot, { adapterProfiles: [await validAdapter()] });
  assert.deepEqual(
    unpinned.resolve({ application: "fake-client", sessionProfile: "restricted" }).supportedVersions,
    ["1.0.0-fixture", "2.0.0-fixture", "9.9.9-unsupported"],
  );
});

test("omitted version pins launch the current executable and keep adapter evidence off the launch path", async () => {
  const values = await validValues();
  delete values.integrations[0].executable.supported_versions;
  delete values.hostBindings[0].executable.expected_version;
  const snapshot = await new ClientConfigProvider().replace(values);
  const adapter = await validAdapter();
  adapter.application.verified_versions = ["0.0.0-incompatible"];
  const registry = new ClientRegistry(snapshot, { adapterProfiles: [adapter] });
  const selected = registry.resolve({ application: "fake-client", sessionProfile: "restricted" });
  assert.deepEqual(selected.supportedVersions, []);
});

test("surface and mode selection fails closed on unsupported or ambiguous requests", async () => {
  const { registry } = await validRegistry();
  const request = { application: "fake-client", sessionProfile: "restricted" };
  assert.throws(() => registry.resolve({ ...request, surface: "missing" }), {
    code: "CLIENT_POLICY_UNSUPPORTED",
    safeDetails: { selector: "surface" },
  });
  assert.throws(() => registry.resolve({ ...request, surface: "batch", mode: "missing" }), {
    code: "CLIENT_POLICY_UNSUPPORTED",
    safeDetails: { selector: "mode" },
  });
  assert.throws(() => registry.resolve({ ...request, surface: "batch" }), {
    code: "CLIENT_POLICY_AMBIGUOUS",
    safeDetails: { selector: "mode" },
  });
  assert.throws(() => registry.resolve({ ...request, mode: "headless" }), {
    code: "CLIENT_POLICY_AMBIGUOUS",
    safeDetails: { selector: "surface" },
  });
  assert.throws(() => registry.resolve({ ...request, surface: "constructor", mode: "headless" }), {
    code: "CLIENT_POLICY_UNSUPPORTED",
    safeDetails: { selector: "surface" },
  });
  assert.throws(() => registry.resolve({ ...request, surface: "delegate", mode: "constructor" }), {
    code: "CLIENT_POLICY_UNSUPPORTED",
    safeDetails: { selector: "mode" },
  });
});

test("prompt-file selection requires the private host runtime root while stdin does not", async () => {
  const values = await validValues();
  delete values.hostBindings[0].runtime;
  const snapshot = await new ClientConfigProvider().replace(values);
  const registry = new ClientRegistry(snapshot, { adapterProfiles: [await validAdapter()] });
  assert.equal(
    registry.resolve({ application: "fake-client", sessionProfile: "restricted" }).modeProfile.carrier.kind,
    "stdin_utf8",
  );
  assert.throws(
    () => registry.resolve({
      application: "fake-client",
      surface: "managed-pane",
      sessionProfile: "restricted",
    }),
    {
      code: "CLIENT_CONFIG_INVALID",
      safeDetails: { configuration_kind: "host_binding", reason: "prompt_file_root_missing" },
    },
  );
});

test("unknown application, session, and workspace use distinct safe failures", async () => {
  const { registry, adapter } = await validRegistry();
  assert.throws(() => registry.getRegistration("unknown"), { code: "CLIENT_UNKNOWN" });
  assert.throws(
    () => registry.resolve({ application: "fake-client", sessionProfile: "unknown" }),
    { code: "SESSION_PROFILE_UNKNOWN" },
  );

  const badWorkspaceValues = await validValues();
  badWorkspaceValues.sessionProfiles[0].workspace = "missing-workspace";
  const badWorkspaceSnapshot = await new ClientConfigProvider().replace(badWorkspaceValues);
  const badWorkspaceRegistry = new ClientRegistry(badWorkspaceSnapshot, { adapterProfiles: [adapter] });
  assert.throws(
    () => badWorkspaceRegistry.resolve({ application: "fake-client", sessionProfile: "restricted" }),
    { code: "CLIENT_WORKSPACE_UNKNOWN" },
  );
});

test("registry initialization rejects adapter identity, verification, and version incompatibility", async () => {
  const provider = new ClientConfigProvider({ configRoot: VALID_ROOT });
  const snapshot = await provider.load();
  const adapter = await validAdapter();

  const forgedRevision = structuredClone(snapshot);
  forgedRevision.revision = "0".repeat(64);
  assert.throws(() => new ClientRegistry(forgedRevision, { adapterProfiles: [adapter] }), {
    code: "CLIENT_CONFIG_INVALID",
    safeDetails: { configuration_kind: "snapshot", reason: "revision_mismatch" },
  });

  const forgedContent = structuredClone(snapshot);
  forgedContent.integrations[0].surfaces.delegate.modes.headless.fixed_args.push("--forged");
  assert.throws(() => new ClientRegistry(forgedContent, { adapterProfiles: [adapter] }), {
    code: "CLIENT_CONFIG_INVALID",
    safeDetails: { configuration_kind: "snapshot", reason: "revision_mismatch" },
  });

  assert.throws(() => new ClientRegistry(snapshot, { adapterProfiles: [] }), {
    code: "INTEGRATION_ADAPTER_INCOMPATIBLE",
    safeDetails: { reason: "adapter_profile_missing" },
  });

  const applicationMismatch = structuredClone(adapter);
  applicationMismatch.application.id = "different-fake-client";
  assert.throws(() => new ClientRegistry(snapshot, { adapterProfiles: [applicationMismatch] }), {
    code: "INTEGRATION_ADAPTER_INCOMPATIBLE",
    safeDetails: { reason: "application_identity_mismatch" },
  });

  const unverified = structuredClone(adapter);
  unverified.verification.status = "unverified";
  assert.throws(() => new ClientRegistry(snapshot, { adapterProfiles: [unverified] }), {
    code: "INTEGRATION_ADAPTER_INCOMPATIBLE",
    safeDetails: { reason: "adapter_unverified" },
  });

  const versionMismatch = structuredClone(adapter);
  versionMismatch.application.verified_versions = ["0.0.0-incompatible"];
  assert.deepEqual(
    new ClientRegistry(snapshot, { adapterProfiles: [versionMismatch] }).getRegistration("fake-client").supportedVersions,
    ["1.0.0-fixture"],
  );

  const values = await validValues();
  values.hostBindings[0].executable.expected_version = "0.0.0-not-declared";
  const hostVersionSnapshot = await new ClientConfigProvider().replace(values);
  assert.throws(() => new ClientRegistry(hostVersionSnapshot, { adapterProfiles: [adapter] }), {
    code: "INTEGRATION_ADAPTER_INCOMPATIBLE",
    safeDetails: { reason: "host_version_outside_intersection" },
  });
});

test("cross-profile host and session references reject without partial selection", async () => {
  const values = await validValues();
  values.hostBindings[0].integration_revision = "wrong-revision";
  await assert.rejects(new ClientConfigProvider().replace(values), {
    code: "CLIENT_CONFIG_INVALID",
    safeDetails: { configuration_kind: "host_binding", reason: "integration_reference_invalid" },
  });

  const { adapter } = await validRegistry();
  const unknownVariable = await validValues();
  unknownVariable.sessionProfiles[0].environment.entries.push({
    name: "UNDECLARED",
    kind: "literal",
    value: "fixture",
  });
  const unknownVariableSnapshot = await new ClientConfigProvider().replace(unknownVariable);
  const registry = new ClientRegistry(unknownVariableSnapshot, { adapterProfiles: [adapter] });
  assert.throws(
    () => registry.resolve({ application: "fake-client", sessionProfile: "restricted" }),
    {
      code: "CLIENT_CONFIG_INVALID",
      safeDetails: { configuration_kind: "session_profile", reason: "environment_variable_unknown" },
    },
  );

  const incompleteCeiling = await validValues();
  delete incompleteCeiling.hostBindings[0].policy.ceiling.web;
  const incompleteCeilingSnapshot = await new ClientConfigProvider().replace(incompleteCeiling);
  assert.throws(
    () => new ClientRegistry(incompleteCeilingSnapshot, { adapterProfiles: [adapter] }),
    {
      code: "CLIENT_CONFIG_INVALID",
      safeDetails: { configuration_kind: "host_binding", reason: "policy_ceiling_incomplete" },
    },
  );

  const inheritedSource = await validValues();
  inheritedSource.integrations[0].environment.entries[1].source_id = "constructor";
  const inheritedSnapshot = await new ClientConfigProvider().replace(inheritedSource);
  assert.throws(
    () => new ClientRegistry(inheritedSnapshot, { adapterProfiles: [adapter] }),
    {
      code: "CLIENT_CONFIG_INVALID",
      safeDetails: { configuration_kind: "host_binding", reason: "environment_source_unknown" },
    },
  );
});

test("public errors have fixed messages, closed phases, and path-free safe details", async () => {
  const error = new ClientIntegrationError("READINESS_TIMEOUT", {
    safeDetails: { dimension: "version", state: "failed" },
  });
  assert.deepEqual(error.toJSON(), {
    code: "READINESS_TIMEOUT",
    phase: "pre_acceptance",
    retryable: true,
    message: "A managed client readiness probe timed out.",
    safe_details: { dimension: "version", state: "failed" },
  });
  assert.equal("cause" in error, false);
  assert.ok(Object.isFrozen(error));
  assert.ok(Object.isFrozen(CLIENT_ERROR_DEFINITIONS.READINESS_TIMEOUT));
  assert.equal(
    new ClientIntegrationError("CLIENT_CONFIG_INVALID", { safeDetails: { reason: "qualified:token" } })
      .safeDetails.reason,
    "qualified:token",
  );
  for (const unsafe of [
    "D:\\private\\secret",
    "C:",
    "C:relative",
    "CON",
    "nul.txt",
    "NUL:stream",
    "..",
    "trailing.",
  ]) {
    assert.throws(
      () => new ClientIntegrationError("CLIENT_CONFIG_INVALID", { safeDetails: { reason: unsafe } }),
      TypeError,
    );
  }
  assert.throws(
    () => new ClientIntegrationError("CLIENT_CONFIG_INVALID", { phase: "before" }),
    TypeError,
  );

  const privateRoot = path.join(FIXTURE_ROOT, "private-secret-directory-does-not-exist");
  await assert.rejects(
    new ClientConfigProvider({ configRoot: privateRoot }).load(),
    (failure) => failure.code === "CLIENT_CONFIG_INVALID"
      && !failure.message.includes(privateRoot)
      && !JSON.stringify(failure).includes(privateRoot),
  );
});
