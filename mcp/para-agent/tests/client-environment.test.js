import test from "node:test";
import assert from "node:assert/strict";
import {
  mkdir,
  mkdtemp,
  readFile,
  rm,
  symlink,
  writeFile,
} from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { ClientIntegrationError } from "../../para-agent/src/client-integration/errors.js";
import {
  assertEnvironmentBackend,
  compileClientEnvironment,
  compileEnvironment,
} from "../../para-agent/src/client-integration/environment.js";
import {
  assertPolicyNarrowing,
  compileClientPolicy,
  compilePolicy,
  intersectPolicyCeilings,
} from "../../para-agent/src/client-integration/policy.js";
import {
  canonicalSemanticJson,
  semanticSha256,
} from "../../para-agent/src/client-integration/semantic-json.js";
import { resolveWorkspace } from "../../para-agent/src/client-integration/workspace.js";

const TEST_ROOT = path.dirname(fileURLToPath(import.meta.url));
const ENVIRONMENT_FIXTURE = path.join(
  TEST_ROOT,
  "fixtures",
  "client-integration",
  "environment",
  "layered.json",
);

function hasCode(code) {
  return (error) => error instanceof ClientIntegrationError && error.code === code;
}

const POLICY_DIMENSIONS = {
  access: { kind: "ordered", values: ["none", "read", "write"] },
  tools: { kind: "set", universe: ["read", "edit", "execute"] },
  web: { kind: "boolean", narrower: false },
};

const PACKAGE_CEILING = {
  access: "write",
  tools: ["edit", "read"],
  web: true,
};

const HOST_CEILING = {
  web: true,
  tools: ["read", "execute"],
  access: "read",
};

test("SEMANTIC-JSON-V1: object order is canonical, versioned, and digest-stable", () => {
  const left = { b: 2, a: { z: true, y: ["λ", 0, -0] } };
  const right = { a: { y: ["λ", -0, 0], z: true }, b: 2 };
  assert.equal(
    canonicalSemanticJson(left),
    '{"semantic_json_version":1,"value":{"a":{"y":["λ",0,0],"z":true},"b":2}}',
  );
  assert.equal(canonicalSemanticJson(left), canonicalSemanticJson(right));
  assert.equal(semanticSha256(left), semanticSha256(right));
  assert.match(semanticSha256(left), /^[a-f0-9]{64}$/);
});

test("SEMANTIC-JSON-CLOSED: non-JSON, ambiguous, and ill-formed values reject", () => {
  const cycle = {};
  cycle.self = cycle;
  const sparse = [];
  sparse.length = 1;
  const accessor = {};
  Object.defineProperty(accessor, "value", { enumerable: true, get: () => 1 });

  for (const value of [undefined, 1n, NaN, Infinity, cycle, sparse, accessor, new Date(0), "\ud800"]) {
    assert.throws(() => canonicalSemanticJson(value), TypeError);
  }
  assert.throws(() => canonicalSemanticJson({}, { version: 2 }), RangeError);
});

test("POLICY-INTERSECTION: explicit orders intersect and later layers only narrow", () => {
  const compiled = compilePolicy({
    dimensions: POLICY_DIMENSIONS,
    packageCeiling: PACKAGE_CEILING,
    hostCeiling: HOST_CEILING,
    packageDefaults: { access: "read", tools: ["read"], web: true },
    sessionPolicy: { web: false },
    operationPolicy: { access: "none" },
  });

  assert.deepEqual(compiled.ceiling, { access: "read", tools: ["read"], web: true });
  assert.deepEqual(compiled.session, { access: "read", tools: ["read"], web: false });
  assert.deepEqual(compiled.effective, { access: "none", tools: ["read"], web: false });
  assert.notEqual(compiled.session_sha256, compiled.effective_sha256);
  assert.deepEqual(compiled.descriptor, {
    policy: {
      session_sha256: compiled.session_sha256,
      effective_sha256: compiled.effective_sha256,
    },
  });
  assert.ok(Object.isFrozen(compiled));
  assert.ok(Object.isFrozen(compiled.effective));
  assert.ok(Object.isFrozen(compiled.descriptor.policy));

  const reordered = compilePolicy({
    dimensions: { web: POLICY_DIMENSIONS.web, tools: POLICY_DIMENSIONS.tools, access: POLICY_DIMENSIONS.access },
    packageCeiling: { web: true, access: "write", tools: ["read", "edit"] },
    hostCeiling: { tools: ["execute", "read"], access: "read", web: true },
    packageDefaults: { web: true, tools: ["read"], access: "read" },
    sessionPolicy: { web: false },
    operationPolicy: { access: "none" },
  });
  assert.equal(reordered.session_sha256, compiled.session_sha256);
  assert.equal(reordered.effective_sha256, compiled.effective_sha256);

  const noOperationNarrowing = compilePolicy({
    dimensions: POLICY_DIMENSIONS,
    packageCeiling: PACKAGE_CEILING,
    hostCeiling: HOST_CEILING,
  });
  assert.equal(noOperationNarrowing.session_sha256, noOperationNarrowing.effective_sha256);
});

test("POLICY-WIDENING: defaults, session, and operation controls reject instead of clamping", () => {
  assert.throws(() => compilePolicy({
    dimensions: POLICY_DIMENSIONS,
    packageCeiling: PACKAGE_CEILING,
    hostCeiling: HOST_CEILING,
    hostDefaults: { access: "write" },
  }), hasCode("CLIENT_POLICY_WIDENING"));

  assert.throws(() => compilePolicy({
    dimensions: POLICY_DIMENSIONS,
    packageCeiling: PACKAGE_CEILING,
    hostCeiling: HOST_CEILING,
    sessionPolicy: { tools: ["read", "edit"] },
  }), hasCode("CLIENT_POLICY_WIDENING"));

  assert.throws(() => compilePolicy({
    dimensions: POLICY_DIMENSIONS,
    packageCeiling: PACKAGE_CEILING,
    hostCeiling: HOST_CEILING,
    sessionPolicy: { access: "none" },
    operationPolicy: { access: "read" },
  }), hasCode("CLIENT_POLICY_WIDENING"));

  assert.throws(
    () => assertPolicyNarrowing(POLICY_DIMENSIONS, { access: "read", tools: ["read"], web: false }, { web: true }),
    hasCode("CLIENT_POLICY_WIDENING"),
  );
});

test("POLICY-PROFILES: strict integration, host, and session shapes compile directly", () => {
  const compiled = compileClientPolicy({
    integrationPolicy: {
      dimensions: POLICY_DIMENSIONS,
      ceiling: PACKAGE_CEILING,
      defaults: { access: "read", tools: ["read"], web: true },
    },
    hostPolicy: {
      ceiling: HOST_CEILING,
      defaults: { access: "read", tools: ["read"], web: true },
    },
    sessionPolicy: { values: { web: false } },
  });
  assert.deepEqual(compiled.session, { access: "read", tools: ["read"], web: false });
});

test("POLICY-PARTIAL-ORDER: incomparable ceilings with multiple maximal lower bounds reject", () => {
  const dimensions = {
    capability: {
      kind: "partial_order",
      values: ["none", "a", "b", "x", "y"],
      narrower_or_equal: [
        ["none", "a"],
        ["none", "b"],
        ["a", "x"],
        ["a", "y"],
        ["b", "x"],
        ["b", "y"],
      ],
    },
  };
  assert.throws(
    () => intersectPolicyCeilings(dimensions, { capability: "x" }, { capability: "y" }),
    hasCode("CLIENT_POLICY_AMBIGUOUS"),
  );
  assert.throws(
    () => intersectPolicyCeilings(dimensions, { capability: "missing" }, { capability: "y" }),
    hasCode("CLIENT_POLICY_UNSUPPORTED"),
  );

  const first = compilePolicy({
    dimensions: {
      capability: {
        kind: "partial_order",
        values: ["none", "read", "write"],
        narrower_or_equal: [["none", "read"], ["read", "write"]],
      },
    },
    packageCeiling: { capability: "write" },
    hostCeiling: { capability: "write" },
  });
  const semanticallyEquivalent = compilePolicy({
    dimensions: {
      capability: {
        kind: "partial_order",
        values: ["write", "none", "read"],
        narrower_or_equal: [["none", "write"], ["read", "write"], ["none", "read"]],
      },
    },
    packageCeiling: { capability: "write" },
    hostCeiling: { capability: "write" },
  });
  assert.equal(first.session_sha256, semanticallyEquivalent.session_sha256);
});

test("ENVIRONMENT-EXACT: compilation starts empty, preserves declaration order, and freezes private output", async () => {
  const fixture = JSON.parse(await readFile(ENVIRONMENT_FIXTURE, "utf8"));
  const runtimeSecret = `runtime-only-${Date.now()}-${Math.random()}`;
  const parentEnvironment = {
    Path: "C:\\portable\\bin",
    PARA_AGENT_TEST_AUTH: runtimeSecret,
    AMBIENT_MUST_NOT_LEAK: "ambient-value",
  };
  const before = structuredClone(parentEnvironment);
  const compiled = compileEnvironment({
    ...fixture,
    parentEnvironment,
    platform: "win32",
  });

  assert.deepEqual(Object.keys(compiled.private.environment), ["PATH", "CLIENT_MODE", "CLIENT_AUTH"]);
  assert.equal(compiled.private.environment.PATH, "C:\\portable\\bin");
  assert.equal(compiled.private.environment.CLIENT_MODE, "deterministic-λ");
  assert.equal(compiled.private.environment.CLIENT_AUTH === runtimeSecret, true);
  assert.equal(compiled.private.contains_secret, true);
  assert.equal(Object.hasOwn(compiled.private.environment, "AMBIENT_MUST_NOT_LEAK"), false);
  assert.deepEqual(parentEnvironment, before, "parent environment must not be mutated");
  assert.deepEqual(compiled.descriptor, {});
  assert.equal(JSON.stringify(compiled.descriptor), "{}");
  assert.equal(JSON.stringify(compiled.descriptor).includes(runtimeSecret), false);
  assert.equal(JSON.stringify(compiled.descriptor).includes("client-auth"), false);
  assert.equal(JSON.stringify(compiled.descriptor).includes("PATH"), false);
  assert.deepEqual(compiled.readiness_facts, {
    environment_sources: { required_count: 2, resolved_count: 2 },
  });
  assert.deepEqual(compiled.plan_intent, { child_environment: "replace" });
  assert.equal(Object.hasOwn(compiled.readiness_facts, "environment_exact"), false);
  const safeJson = JSON.stringify({ descriptor: compiled.descriptor, readiness: compiled.readiness_facts });
  assert.equal(safeJson.includes(runtimeSecret), false);
  assert.equal(safeJson.includes("client-auth"), false);
  assert.equal(safeJson.includes("PARA_AGENT_TEST_AUTH"), false);
  assert.equal(safeJson.includes("PATH"), false);
  assert.ok(Object.isFrozen(compiled.private.environment));
  assert.throws(() => { compiled.private.environment.EXTRA = "forbidden"; }, TypeError);
});

test("ENVIRONMENT-WINDOWS-CASING: declaration, layer, and ambient collisions reject", () => {
  assert.throws(() => compileEnvironment({
    platform: "win32",
    variables: [
      { name: "Path", required: false, secret: false },
      { name: "PATH", required: false, secret: false },
    ],
  }), hasCode("CLIENT_ENV_CASE_COLLISION"));

  assert.throws(() => compileEnvironment({
    platform: "win32",
    variables: [{ name: "PATH", required: false, secret: false }],
    layers: [{ entries: [{ name: "Path", kind: "literal", value: "one" }] }],
  }), hasCode("CLIENT_ENV_CASE_COLLISION"));

  assert.throws(() => compileEnvironment({
    platform: "win32",
    variables: [{ name: "PATH", required: true, secret: false }],
    layers: [{ entries: [{ name: "PATH", kind: "inherit" }] }],
    parentEnvironment: { Path: "one", PATH: "two" },
  }), hasCode("CLIENT_ENV_CASE_COLLISION"));
});

test("ENVIRONMENT-PROFILES: strict integration, host, and session shapes compile directly", () => {
  const compiled = compileClientEnvironment({
    integrationEnvironment: {
      variables: [
        { name: "PATH", required: true, secret: false },
        { name: "MODE", required: true, secret: false },
      ],
      entries: [
        { name: "PATH", kind: "inherit" },
        { name: "MODE", kind: "literal", value: "package" },
      ],
    },
    hostEnvironment: {
      sources: {},
      entries: [{ name: "MODE", kind: "literal", value: "host" }],
    },
    sessionEnvironment: {
      entries: [{ name: "MODE", kind: "literal", value: "session" }],
    },
    parentEnvironment: { Path: "C:\\portable\\bin", UNDECLARED: "excluded" },
    platform: "win32",
  });
  assert.deepEqual(compiled.private.environment, {
    PATH: "C:\\portable\\bin",
    MODE: "session",
  });
});

test("ENVIRONMENT-TOMBSTONES: optional unsets persist and required/restored values reject", () => {
  const optional = [{ name: "OPTIONAL", required: false, secret: false }];
  const unset = { name: "OPTIONAL", kind: "unset" };
  assert.deepEqual(compileEnvironment({
    variables: optional,
    platform: "linux",
    layers: [
      { entries: [{ name: "OPTIONAL", kind: "literal", value: "initial" }] },
      { entries: [unset] },
    ],
  }).private.environment, {});

  assert.throws(() => compileEnvironment({
    variables: optional,
    platform: "linux",
    layers: [
      { entries: [unset] },
      { entries: [{ name: "OPTIONAL", kind: "literal", value: "restored" }] },
    ],
  }), hasCode("CLIENT_POLICY_WIDENING"));

  assert.throws(() => compileEnvironment({
    variables: [{ name: "REQUIRED", required: true, secret: false }],
    platform: "linux",
    layers: [{ entries: [{ name: "REQUIRED", kind: "unset" }] }],
  }), hasCode("CLIENT_ENV_REQUIRED_UNSET"));
});

test("ENVIRONMENT-SOURCES: named process sources resolve once and invalid material fails closed", () => {
  const variable = [{ name: "SECRET", required: true, secret: true }];
  assert.throws(() => compileEnvironment({
    variables: variable,
    layers: [{ entries: [{ name: "SECRET", kind: "literal", value: "not-committable" }] }],
  }), hasCode("CLIENT_ENV_SOURCE_INVALID"));
  assert.throws(() => compileEnvironment({
    variables: variable,
    layers: [{ entries: [{ name: "SECRET", kind: "source", source_id: "opaque" }] }],
    sources: {},
  }), hasCode("CLIENT_ENV_SOURCE_MISSING"));
  assert.throws(() => compileEnvironment({
    variables: variable,
    layers: [{ entries: [{ name: "SECRET", kind: "source", source_id: "opaque" }] }],
    sources: { opaque: { kind: "file", name: "NOT_SUPPORTED" } },
  }), hasCode("CLIENT_ENV_SOURCE_INVALID"));
  assert.throws(() => compileEnvironment({
    variables: [{ name: "VALUE", required: true, secret: false }],
    layers: [{ entries: [{ name: "VALUE", kind: "literal", value: "bad\0value" }] }],
  }), hasCode("CLIENT_ENV_SOURCE_INVALID"));
  assert.throws(() => compileEnvironment({
    variables: [{ name: "BAD-NAME", required: false, secret: false }],
  }), hasCode("CLIENT_ENV_NAME_INVALID"));

  let reads = 0;
  const parentEnvironment = { "=UNRELATED-WINDOWS-ENTRY": "ignored" };
  Object.defineProperty(parentEnvironment, "SHARED_SOURCE", {
    enumerable: true,
    get() {
      reads += 1;
      return "resolved-once";
    },
  });
  const resolved = compileEnvironment({
    variables: [
      { name: "FIRST", required: true, secret: false },
      { name: "SECOND", required: true, secret: false },
      { name: "__proto__", required: true, secret: false },
    ],
    layers: [{ entries: [
      { name: "FIRST", kind: "source", source_id: "shared" },
      { name: "SECOND", kind: "source", source_id: "shared" },
      { name: "__proto__", kind: "literal", value: "owned-data-property" },
    ] }],
    sources: { shared: { kind: "process_env", name: "SHARED_SOURCE" } },
    parentEnvironment,
    platform: "win32",
  });
  assert.equal(reads, 1, "one named process source must be resolved only once per compilation");
  assert.equal(Object.hasOwn(resolved.private.environment, "__proto__"), true);
  assert.equal(resolved.private.environment.__proto__, "owned-data-property");
});

test("ENVIRONMENT-BACKEND: managed mux rejects secrets and requires independent isolation proof", () => {
  const nonsecret = compileEnvironment({ variables: [] });
  const secret = compileEnvironment({
    variables: [{ name: "SECRET", required: true, secret: true }],
    layers: [{ entries: [{ name: "SECRET", kind: "source", source_id: "secret" }] }],
    sources: { secret: { kind: "process_env", name: "PRIVATE_SOURCE" } },
    parentEnvironment: { PRIVATE_SOURCE: "runtime-only" },
  });
  const proof = (backendKind) => ({
    state: "passed",
    backend_kind: backendKind,
    evidence_kind: "subprocess_exact_environment",
  });
  assert.throws(
    () => assertEnvironmentBackend(secret, { backendKind: "process" }),
    hasCode("CLIENT_ENV_ISOLATION_UNPROVEN"),
  );
  const processApproved = assertEnvironmentBackend(secret, {
    backendKind: "process",
    exactIsolationProof: proof("process"),
  });
  assert.equal(processApproved.private === secret.private, true);
  assert.deepEqual(processApproved.readiness_facts, {
    environment_sources: { required_count: 1, resolved_count: 1 },
    environment_exact: { exact: true },
    backend: { kind: "process" },
  });
  assert.throws(
    () => assertEnvironmentBackend(secret, {
      backendKind: "managed_mux",
      exactIsolationProof: proof("managed_mux"),
    }),
    hasCode("CLIENT_ENV_SECRET_UNSAFE_BACKEND"),
  );
  assert.throws(
    () => assertEnvironmentBackend(nonsecret, { backendKind: "managed_mux" }),
    hasCode("CLIENT_ENV_ISOLATION_UNPROVEN"),
  );
  assert.equal(
    Object.hasOwn(nonsecret.readiness_facts, "environment_exact"),
    false,
  );
  assert.throws(
    () => assertEnvironmentBackend(nonsecret, {
      backendKind: "managed_mux",
      exactIsolationProof: proof("process"),
    }),
    hasCode("CLIENT_ENV_ISOLATION_UNPROVEN"),
  );
  const muxApproved = assertEnvironmentBackend(nonsecret, {
    backendKind: "managed_mux",
    exactIsolationProof: proof("managed_mux"),
  });
  assert.deepEqual(muxApproved.backend_proof, proof("managed_mux"));
  assert.deepEqual(muxApproved.readiness_facts.environment_exact, { exact: true });
  assert.deepEqual(muxApproved.readiness_facts.backend, { kind: "managed_mux" });
  assert.ok(Object.isFrozen(muxApproved.backend_proof));
});

function provenLstatInspection({ stats }) {
  return stats.isSymbolicLink() ? "reparse" : "passed";
}

async function makeWorkspace(t, prefix = "para-client-workspace-") {
  const root = await mkdtemp(path.join(os.tmpdir(), prefix));
  t.after(async () => {
    const resolved = path.resolve(root);
    assert.ok(resolved.startsWith(path.resolve(os.tmpdir())), "test cleanup must stay under the temp root");
    await rm(resolved, { recursive: true, force: true });
  });
  await mkdir(path.join(root, "alpha", "beta"), { recursive: true });
  return root;
}

test("WORKSPACE-IDENTITY: logical cwd resolves privately while stable descriptor IDs contain no path", async (t) => {
  const firstRoot = await makeWorkspace(t, "para-client-workspace-a-");
  const secondRoot = await makeWorkspace(t, "para-client-workspace-b-");
  const logical = process.platform === "win32" ? "alpha\\beta" : "alpha/beta";
  const first = await resolveWorkspace({
    workspace: { id: "primary", root: firstRoot },
    cwd: logical,
    inspectReparse: provenLstatInspection,
  });
  const second = await resolveWorkspace({
    workspace: { id: "primary", root: secondRoot },
    cwd: logical,
    inspectReparse: provenLstatInspection,
  });
  const rootSelection = await resolveWorkspace({
    workspace: { id: "primary", root: firstRoot },
    inspectReparse: provenLstatInspection,
  });

  assert.equal(first.private.cwd, await import("node:fs/promises").then(({ realpath }) => realpath(path.join(firstRoot, "alpha", "beta"))));
  assert.equal(first.descriptor.workspace.id, "primary");
  assert.match(first.descriptor.workspace.working_directory_id, /^wd1_[a-f0-9]{64}$/);
  assert.deepEqual(first.readiness_facts, {
    workspace: { working_directory_id: first.descriptor.workspace.working_directory_id },
  });
  assert.equal(first.descriptor.workspace.working_directory_id, second.descriptor.workspace.working_directory_id);
  assert.notEqual(first.descriptor.workspace.working_directory_id, rootSelection.descriptor.workspace.working_directory_id);
  const publicJson = JSON.stringify(first.descriptor);
  assert.equal(publicJson.includes(firstRoot), false);
  assert.equal(publicJson.includes("alpha"), false);
  assert.ok(Object.isFrozen(first.private));
  assert.ok(Object.isFrozen(first.descriptor.workspace));

  if (process.platform === "win32") {
    const differentlyCased = await resolveWorkspace({
      workspace: { id: "primary", root: firstRoot },
      cwd: "ALPHA/BETA",
      inspectReparse: provenLstatInspection,
    });
    assert.equal(
      differentlyCased.descriptor.workspace.working_directory_id,
      first.descriptor.workspace.working_directory_id,
      "Windows-equivalent logical selectors must have one stable working-directory identity",
    );
  }
});

test("WORKSPACE-LOGICAL-CWD: rooted, drive, device, dot, and empty segments reject", async (t) => {
  const root = await makeWorkspace(t);
  const invalid = [
    "",
    ".",
    "..",
    "alpha//beta",
    "alpha/../beta",
    "/alpha",
    "C:alpha",
    "C:\\alpha",
    "\\\\server\\share",
    "\\\\?\\C:\\alpha",
    "bad\ud800segment",
  ];
  for (const cwd of invalid) {
    await assert.rejects(
      resolveWorkspace({ workspace: { id: "primary", root }, cwd, inspectReparse: provenLstatInspection }),
      hasCode("CLIENT_CWD_INVALID"),
      cwd,
    );
  }
});

test("WORKSPACE-PHYSICAL: missing and non-directory components have distinct typed failures", async (t) => {
  const root = await makeWorkspace(t);
  await writeFile(path.join(root, "plain-file"), "content", "utf8");
  await assert.rejects(
    resolveWorkspace({ workspace: { id: "primary", root }, cwd: "missing", inspectReparse: provenLstatInspection }),
    hasCode("CLIENT_CWD_MISSING"),
  );
  await assert.rejects(
    resolveWorkspace({ workspace: { id: "primary", root }, cwd: "plain-file", inspectReparse: provenLstatInspection }),
    hasCode("CLIENT_CWD_NOT_DIRECTORY"),
  );
});

test("WORKSPACE-REPARSE-ACTUAL: inward and outward directory links reject without a skip", async (t) => {
  const root = await makeWorkspace(t, "para-client-links-");
  const outside = await mkdtemp(path.join(os.tmpdir(), "para-client-outside-"));
  t.after(async () => {
    const resolved = path.resolve(outside);
    assert.ok(resolved.startsWith(path.resolve(os.tmpdir())), "test cleanup must stay under the temp root");
    await rm(resolved, { recursive: true, force: true });
  });
  const inwardTarget = path.join(root, "inward-target");
  await mkdir(inwardTarget);
  const linkType = process.platform === "win32" ? "junction" : "dir";
  await symlink(inwardTarget, path.join(root, "inward-link"), linkType);
  await symlink(outside, path.join(root, "outward-link"), linkType);

  for (const cwd of ["inward-link", "outward-link"]) {
    await assert.rejects(
      resolveWorkspace({ workspace: { id: "primary", root }, cwd, inspectReparse: provenLstatInspection }),
      hasCode("CLIENT_CWD_REPARSE"),
      cwd,
    );
  }
});

test("WORKSPACE-REPARSE-SEAM: unknown and injected non-link reparse states fail closed", async (t) => {
  const root = await makeWorkspace(t);
  let visits = 0;
  await assert.rejects(resolveWorkspace({
    workspace: { id: "primary", root },
    cwd: "alpha",
    inspectReparse() {
      visits += 1;
      return visits === 1 ? "passed" : "unknown";
    },
  }), hasCode("CLIENT_CWD_REPARSE"));

  visits = 0;
  await assert.rejects(resolveWorkspace({
    workspace: { id: "primary", root },
    cwd: "alpha",
    inspectReparse() {
      visits += 1;
      return visits === 1 ? { state: "passed" } : { state: "reparse", kind: "junction" };
    },
  }), hasCode("CLIENT_CWD_REPARSE"));

  const fakeStats = {
    dev: 1,
    isDirectory: () => true,
    isSymbolicLink: () => false,
  };
  await assert.rejects(resolveWorkspace({
    workspace: { id: "primary", root: "C:\\workspace" },
    platform: "win32",
    fsOps: {
      lstat: async () => fakeStats,
      realpath: async (value) => value,
    },
  }), hasCode("CLIENT_CWD_REPARSE"), "default Windows proof must not silently treat unknown as safe");
});

test("PUBLIC-ERRORS: environment and workspace failures disclose no supplied private material", async (t) => {
  const root = await makeWorkspace(t);
  const privateFragment = path.basename(root);
  let caught;
  try {
    await resolveWorkspace({
      workspace: { id: "primary", root },
      cwd: "missing-private-component",
      inspectReparse: provenLstatInspection,
    });
  } catch (error) {
    caught = error;
  }
  assert.ok(caught instanceof ClientIntegrationError);
  const publicJson = JSON.stringify(caught.toJSON());
  assert.equal(publicJson.includes(privateFragment), false);
  assert.equal(publicJson.includes("missing-private-component"), false);
});
