import test from "node:test";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { ClientIntegrationError } from "../src/client-integration/errors.js";
import {
  compileInvocationRecipe,
  finalizeInvocationDescriptor,
  finalizeInvocationPlan,
} from "../src/client-integration/invocation.js";
import {
  parseStrictJsonObject,
  runReadiness,
} from "../src/client-integration/readiness.js";
import {
  cleanupPromptCarrier,
  materializePromptCarrier,
  preparePromptCarrier,
} from "../src/client-integration/carrier.js";
import {
  PROMPT_CARRIER_SCAVENGE_LOCK,
  scavengePromptCarriers,
} from "../src/client-integration/scavenger.js";

const here = path.dirname(fileURLToPath(import.meta.url));
const fixtureRoot = path.join(here, "fixtures", "client-integration", "invocation");
const sha256 = (bytes) => createHash("sha256").update(bytes).digest("hex");
const securityOps = {
  validateRoot: async () => true,
  validateFile: async () => true,
  validateScavengeCandidate: async () => true,
};

async function tempRoot(t) {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "para-client-invocation-"));
  if (process.platform !== "win32") await fs.chmod(root, 0o700);
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  return root;
}

function invocationInput(overrides = {}) {
  const {
    modeProfile: modeProfileOverride,
    promptFileRoot,
    resolved: resolvedOverride,
    ...topLevelOverrides
  } = overrides;
  const modeProfile = modeProfileOverride ?? {
    fixed_args: ["--structured", "{exchange_id}"],
    carrier: { kind: "stdin_utf8" },
    stdio: { prompt: "stdin", semantic: "stdout", diagnostic: "stderr" },
    readiness: { required: ["executable", "version"], probes: [] },
    backend: "process",
  };
  const resolved = {
    snapshotRevision: "c".repeat(64),
    applicationId: "fake-client",
    integration: { id: "fake-client", revision: "integration-r1" },
    hostBinding: {
      executable: { path: process.execPath },
      ...(promptFileRoot === undefined
        ? {}
        : { runtime: { prompt_file_root: promptFileRoot } }),
    },
    adapter: { id: "para-agent.fake", version: "1.0.0", profile_id: "fake/1.2.3" },
    adapterProfile: {},
    supportedVersions: ["1.2.3"],
    surface: "delegate",
    mode: "headless",
    modeProfile,
    sessionProfile: { id: "bounded", revision: "session-r1" },
    workspaceBinding: { id: "science-facility", root: path.resolve(".") },
    ...resolvedOverride,
  };
  const environment = { PATH: "private-runtime-path", CLIENT_TOKEN: "private-secret-value" };
  Object.defineProperty(environment, "__proto__", {
    value: "private-prototype-value",
    enumerable: true,
    configurable: true,
    writable: true,
  });
  return {
    resolved,
    environmentResult: {
      private: { environment },
      descriptor: {},
    },
    workspaceResult: {
      private: { cwd: path.resolve(".") },
      descriptor: { workspace: { id: "science-facility", working_directory_id: "workspace-root" } },
    },
    policyResult: {
      session_sha256: "a".repeat(64),
      effective_sha256: "b".repeat(64),
    },
    ...topLevelOverrides,
  };
}

function passingProbe(dimension, facts, evidenceKind = "bounded_probe") {
  return {
    dimension,
    evidenceKind,
    request: { private_command: ["not-public"] },
    timeoutMs: 1_000,
    maxOutputBytes: 4_096,
    parse: () => ({ state: "passed", facts }),
  };
}

async function passingReadiness() {
  return runReadiness({
    integrationRevision: "integration-r1",
    requiredDimensions: ["executable", "version"],
    probes: [
      passingProbe("executable", { available: true }),
      passingProbe("version", { version: "1.2.3" }, "version_output"),
    ],
    executor: async () => ({ exitCode: 0, stdout: Buffer.alloc(0), stderr: Buffer.alloc(0) }),
  });
}

test("INVOCATION-RECIPE-IMMUTABLE: private authority and safe descriptor basis remain separate", async () => {
  const input = invocationInput();
  const compiled = compileInvocationRecipe(input);
  input.environmentResult.private.environment.CLIENT_TOKEN = "mutated";
  input.resolved.integration.revision = "mutated";

  assert.equal(Object.isFrozen(compiled), true);
  assert.equal(Object.isFrozen(compiled.recipe.environment), true);
  assert.equal(compiled.recipe.environment.CLIENT_TOKEN, "private-secret-value");
  assert.equal(Object.hasOwn(compiled.recipe.environment, "__proto__"), true);
  assert.equal(compiled.recipe.environment.__proto__, "private-prototype-value");
  assert.equal(compiled.descriptorBasis.integration.revision, "integration-r1");
  assert.throws(() => { compiled.recipe.environment.NEW_VALUE = "forbidden"; }, TypeError);

  const safe = JSON.stringify(compiled.descriptorBasis);
  for (const forbidden of [process.execPath, path.resolve("."), "PATH", "CLIENT_TOKEN", "private-secret-value"]) {
    assert.equal(safe.includes(forbidden), false);
  }
  const descriptor = finalizeInvocationDescriptor(compiled.descriptorBasis, await passingReadiness());
  assert.equal(descriptor.readiness.version.version, "1.2.3");
  assert.equal(Object.isFrozen(descriptor.readiness.version), true);
});

test("READINESS-CURRENT-VERSION: omitted pins accept the observed executable version", async () => {
  const versionProbe = {
    id: "version",
    dimension: "version",
    kind: "command",
    fixed_args: ["--version"],
    timeout_ms: 1000,
    max_output_bytes: 4096,
    parser: { kind: "utf8_text", success_exit_codes: [0] },
    safe_facts: ["version"],
  };
  const modeProfile = {
    fixed_args: ["--structured"],
    carrier: { kind: "stdin_utf8" },
    stdio: { prompt: "stdin", semantic: "stdout", diagnostic: "stderr" },
    readiness: { required: ["version"], probes: [versionProbe] },
    backend: "process",
  };
  const current = compileInvocationRecipe(invocationInput({
    modeProfile,
    resolved: { supportedVersions: [] },
  }));
  const readiness = await runReadiness({
    integrationRevision: "integration-r1",
    ...current.recipe.readiness,
    executor: async () => ({
      exitCode: 0,
      stdout: Buffer.from("2.1.232\n"),
      stderr: Buffer.alloc(0),
    }),
  });
  assert.equal(readiness.version.state, "passed");
  assert.equal(readiness.version.version, "2.1.232");

  const pinned = compileInvocationRecipe(invocationInput({ modeProfile }));
  await assert.rejects(() => runReadiness({
    integrationRevision: "integration-r1",
    ...pinned.recipe.readiness,
    executor: async () => ({
      exitCode: 0,
      stdout: Buffer.from("2.1.232\n"),
      stderr: Buffer.alloc(0),
    }),
  }), { code: "READINESS_VERSION_UNSUPPORTED" });
});

test("INVOCATION-STDIO-STRICT: mixed streams, unknown fields, and undeclared carrier slots reject", () => {
  for (const input of [
    invocationInput({ modeProfile: {
      fixed_args: [],
      carrier: { kind: "stdin_utf8" },
      stdio: { prompt: "stdin", semantic: "stderr", diagnostic: "stdout" },
      readiness: { required: [], probes: [] },
    } }),
    invocationInput({ modeProfile: {
      fixed_args: ["{carrier_path}"],
      carrier: { kind: "stdin_utf8" },
      stdio: { prompt: "stdin", semantic: "stdout", diagnostic: "stderr" },
      readiness: { required: [], probes: [] },
    } }),
    invocationInput({ modeProfile: {
      fixed_args: ["{prompt}"],
      carrier: { kind: "stdin_utf8" },
      stdio: { prompt: "stdin", semantic: "stdout", diagnostic: "stderr" },
      readiness: { required: [], probes: [] },
    } }),
    { ...invocationInput(), prompt: "must-not-enter-the-compiler" },
  ]) {
    assert.throws(() => compileInvocationRecipe(input), (error) => (
      error instanceof ClientIntegrationError && error.code === "INVOCATION_PLAN_INVALID"
    ));
  }
});

test("INVOCATION-FINALIZE-SLOTS: only exchange and opaque carrier slots enter argv", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "para-plan-slot-"));
  try {
    if (process.platform !== "win32") await fs.chmod(root, 0o700);
    const compiled = compileInvocationRecipe(invocationInput({
      promptFileRoot: root,
      modeProfile: {
        fixed_args: ["--exchange", "{exchange_id}"],
        carrier: { kind: "prompt_file", arg_template: ["--prompt-file", "{carrier_path}"] },
        stdio: { prompt: "file", semantic: "stdout", diagnostic: "stderr" },
        readiness: { required: ["prompt_carrier"], probes: [] },
        backend: "process",
      },
    }));
    const prepared = await preparePromptCarrier(compiled.recipe.carrier, { securityOps });
    const prompt = "hostile λ\n'$env:SECRET' `literal`";
    const carrier = await materializePromptCarrier(prepared, prompt, {
      securityOps,
      randomBytes: () => Buffer.alloc(16, 7),
    });
    const plan = finalizeInvocationPlan(compiled.recipe, { exchangeId: "xid-test", carrier });

    assert.deepEqual(plan.argv, ["--exchange", "xid-test", "--prompt-file", carrier.path]);
    assert.equal(plan.argv.some((argument) => argument.includes(prompt)), false);
    assert.equal((await fs.readFile(carrier.path, "utf8")), prompt);
    assert.equal(plan.prompt.sha256, sha256(Buffer.from(prompt)));
    assert.equal(Object.isFrozen(plan), true);
    assert.equal((await plan.prompt.cleanup()).state, "cleaned");
  } finally {
    await fs.rm(root, { recursive: true, force: true });
  }
});

test("READINESS-BOUNDED: required probes yield a closed all-dimension safe projection", async () => {
  const observedRequests = [];
  const report = await runReadiness({
    integrationRevision: "integration-r1",
    requiredDimensions: ["executable", "version", "capabilities"],
    probes: [
      passingProbe("executable", { available: true }),
      {
        ...passingProbe("version", { version: "unused" }, "version_output"),
        request: { fixture: "version-ok.json" },
        parse: ({ stdout }) => {
          const value = parseStrictJsonObject(stdout, {
            allowedKeys: ["available", "version"],
            requiredKeys: ["available", "version"],
          });
          return { state: value.available ? "passed" : "failed", facts: { version: value.version } };
        },
      },
      passingProbe("capabilities", { capabilities: ["web.disabled", "tools.disabled"] }),
    ],
    executor: async ({ request }) => {
      observedRequests.push(request);
      const stdout = request.fixture
        ? await fs.readFile(path.join(fixtureRoot, request.fixture))
        : Buffer.alloc(0);
      return { exitCode: 0, stdout, stderr: Buffer.from("private diagnostic") };
    },
  });

  assert.equal(report.executable.state, "passed");
  assert.equal(report.version.version, "1.2.3");
  assert.deepEqual(report.capabilities.capabilities, ["tools.disabled", "web.disabled"]);
  assert.equal(report.authentication.state, "not_applicable");
  assert.equal(Object.keys(report).length, 10);
  assert.equal(JSON.stringify(report).includes("private diagnostic"), false);
  assert.equal(observedRequests.length, 3);
});

test("READINESS-FAIL-CLOSED: required unknown, timeout, malformed output, and unsafe facts are typed", async (t) => {
  await t.test("required unknown", async () => {
    await assert.rejects(() => runReadiness({
      integrationRevision: "integration-r1",
      requiredDimensions: ["authentication"],
      probes: [{
        ...passingProbe("authentication", {}),
        parse: () => ({ state: "unknown", facts: {} }),
      }],
      executor: async () => ({ exitCode: 0, stdout: Buffer.alloc(0), stderr: Buffer.alloc(0) }),
    }), { code: "READINESS_PROOF_INSUFFICIENT" });
  });

  await t.test("timeout", async () => {
    await assert.rejects(() => runReadiness({
      integrationRevision: "integration-r1",
      requiredDimensions: ["executable"],
      probes: [{ ...passingProbe("executable", { available: true }), timeoutMs: 5 }],
      executor: async () => new Promise(() => {}),
    }), { code: "READINESS_TIMEOUT" });
  });

  await t.test("strict JSON rejects undeclared output", async () => {
    const raw = await fs.readFile(path.join(fixtureRoot, "version-extra.json"));
    assert.throws(() => parseStrictJsonObject(raw, {
      allowedKeys: ["available", "version"],
      requiredKeys: ["available", "version"],
    }), { code: "READINESS_MALFORMED" });
  });

  await t.test("unsafe projected fact", async () => {
    await assert.rejects(() => runReadiness({
      integrationRevision: "integration-r1",
      requiredDimensions: ["version"],
      probes: [{
        ...passingProbe("version", {}),
        parse: () => ({ state: "passed", facts: { executable_path: "private" } }),
      }],
      executor: async () => ({ exitCode: 0, stdout: Buffer.alloc(0), stderr: Buffer.alloc(0) }),
    }), { code: "READINESS_MALFORMED" });
  });
});

test("READINESS-OPTIONAL-UNKNOWN: optional probe failure remains explicit and safe", async () => {
  const report = await runReadiness({
    integrationRevision: "integration-r1",
    probes: [passingProbe("configuration", { configured: true })],
    executor: async () => { throw new Error("C:\\private\\config secret-value"); },
  });
  assert.equal(report.configuration.state, "unknown");
  assert.equal(JSON.stringify(report).includes("private"), false);
  assert.equal(JSON.stringify(report).includes("secret-value"), false);
});

test("CARRIER-STDIN-EXACT: hostile valid UTF-8 is copied exactly and cannot be mutated through reads", async () => {
  const prepared = await preparePromptCarrier({ kind: "stdin_utf8" });
  const prompt = "first\n'\"`$()|;&<>\nλ 第二行 👩🏽‍🔬";
  const carrier = await materializePromptCarrier(prepared, prompt);
  const first = carrier.readBytes();
  first.fill(0);
  assert.deepEqual(carrier.readBytes(), Buffer.from(prompt, "utf8"));
  assert.equal(carrier.bytes, Buffer.byteLength(prompt));
  assert.equal(carrier.sha256, sha256(Buffer.from(prompt)));
  await assert.rejects(
    () => materializePromptCarrier(prepared, Buffer.from([0xff])),
    { code: "PROMPT_ENCODING_FAILED", phase: "accepted" },
  );
});

test("CARRIER-FILE-DURABLE: wx materialization verifies exact bytes and cleanup removes only the file", async (t) => {
  const root = await tempRoot(t);
  const prepared = await preparePromptCarrier({ kind: "prompt_file", root }, { securityOps });
  const payload = Buffer.from("exact payload λ\n", "utf8");
  const carrier = await materializePromptCarrier(prepared, payload, {
    securityOps,
    randomBytes: () => Buffer.alloc(16, 3),
  });

  assert.match(path.basename(carrier.path), /^pa-prompt-[a-f0-9]{32}\.tmp$/);
  assert.deepEqual(await fs.readFile(carrier.path), payload);
  assert.equal(carrier.bytes, payload.length);
  assert.equal(carrier.sha256, sha256(payload));
  assert.equal((await carrier.cleanup()).state, "cleaned");
  await assert.rejects(() => fs.access(carrier.path), { code: "ENOENT" });
  assert.equal((await fs.readdir(root)).length, 0);
});

test("CARRIER-WX: collision never overwrites an existing prompt file", async (t) => {
  const root = await tempRoot(t);
  const name = `pa-prompt-${Buffer.alloc(16, 9).toString("hex")}.tmp`;
  const target = path.join(root, name);
  await fs.writeFile(target, "existing", { flag: "wx", mode: 0o600 });
  const prepared = await preparePromptCarrier({ kind: "prompt_file", root }, { securityOps });
  await assert.rejects(() => materializePromptCarrier(prepared, "new", {
    securityOps,
    randomBytes: () => Buffer.alloc(16, 9),
    createAttempts: 1,
  }), { code: "PROMPT_CARRIER_CREATE_FAILED" });
  assert.equal(await fs.readFile(target, "utf8"), "existing");
});

test("CARRIER-ROOT-PROTECTION: Windows file mode is unavailable without an approving security seam", async (t) => {
  const root = await tempRoot(t);
  await assert.rejects(
    () => preparePromptCarrier({ kind: "prompt_file", root }, { platform: "win32" }),
    { code: "PROMPT_CARRIER_ROOT_UNSAFE" },
  );
});

test("CARRIER-CLEANUP-RETRY: Windows locks receive bounded retry and path-free warning", async (t) => {
  const root = await tempRoot(t);
  const filePath = path.join(root, `pa-prompt-${"1".repeat(32)}.tmp`);
  await fs.writeFile(filePath, "payload", { mode: 0o600 });
  let unlinks = 0;
  const fsOps = new Proxy(fs, {
    get(target, property) {
      if (property !== "unlink") return target[property];
      return async (candidate) => {
        unlinks += 1;
        if (unlinks < 3) throw Object.assign(new Error("locked private path"), { code: "EBUSY" });
        return fs.unlink(candidate);
      };
    },
  });
  const sleeps = [];
  const result = await cleanupPromptCarrier({ kind: "prompt_file", path: filePath }, {
    fsOps,
    platform: "win32",
    maxAttempts: 3,
    retryDelayMs: 1,
    sleep: async (delay) => { sleeps.push(delay); },
  });
  assert.equal(result.state, "pending");
  assert.equal(result.warning.code, "PROMPT_CARRIER_CLEANUP_PENDING");
  assert.equal(result.warning.safe_details.reason, "unsafe_handle");

  const preparedForCleanup = await preparePromptCarrier({ kind: "prompt_file", root }, { securityOps });
  const cleanCarrier = await materializePromptCarrier(preparedForCleanup, "payload", {
    fsOps,
    securityOps,
    randomBytes: () => Buffer.alloc(16, 7),
    platform: "win32",
  });
  const cleaned = await cleanupPromptCarrier(cleanCarrier, {
    fsOps,
    platform: "win32",
    maxAttempts: 3,
    retryDelayMs: 1,
    sleep: async (delay) => { sleeps.push(delay); },
  });
  assert.deepEqual(cleaned, { state: "cleaned", attempts: 3 });
  assert.deepEqual(sleeps, [1, 1]);

  const pendingPath = path.join(root, `pa-prompt-${"2".repeat(32)}.tmp`);
  await fs.writeFile(pendingPath, "payload", { mode: 0o600 });
  const lockedFs = new Proxy(fs, {
    get(target, property) {
      if (property !== "unlink") return target[property];
      return async () => { throw Object.assign(new Error("C:\\private\\prompt"), { code: "EBUSY" }); };
    },
  });
  const pending = await cleanupPromptCarrier({ kind: "prompt_file", path: pendingPath }, {
    fsOps: lockedFs,
    platform: "win32",
    maxAttempts: 2,
    retryDelayMs: 0,
    sleep: async () => {},
  });
  assert.equal(pending.state, "pending");
  assert.equal(pending.warning.code, "PROMPT_CARRIER_CLEANUP_PENDING");
  assert.equal(JSON.stringify(pending).includes("private"), false);
});

test("CARRIER-SCAVENGER-CONSERVATIVE: only stale, owned, inactive, regular fixed-name files are removed", async (t) => {
  const root = await tempRoot(t);
  const stale = path.join(root, `pa-prompt-${"a".repeat(32)}.tmp`);
  const fresh = path.join(root, `pa-prompt-${"b".repeat(32)}.tmp`);
  const maliciousName = path.join(root, "pa-prompt-not-opaque.tmp");
  const matchingDirectory = path.join(root, `pa-prompt-${"c".repeat(32)}.tmp`);
  await fs.writeFile(stale, "stale", { mode: 0o600 });
  await fs.writeFile(fresh, "fresh", { mode: 0o600 });
  await fs.writeFile(maliciousName, "preserve", { mode: 0o600 });
  await fs.mkdir(matchingDirectory);
  await fs.writeFile(path.join(matchingDirectory, "nested"), "preserve");
  const nowMs = Date.now();
  await fs.utimes(stale, new Date(nowMs - 10_000), new Date(nowMs - 10_000));
  await fs.utimes(fresh, new Date(nowMs), new Date(nowMs));

  const result = await scavengePromptCarriers({
    root,
    minimumAgeMs: 1_000,
    now: () => nowMs,
    securityOps,
    leaseState: async ({ name }) => name === path.basename(stale) ? "inactive" : "unknown",
  });
  assert.deepEqual(result, { state: "completed", scanned: 3, removed: 1, retained: 2, failed: 0 });
  await assert.rejects(() => fs.access(stale), { code: "ENOENT" });
  await fs.access(fresh);
  await fs.access(maliciousName);
  await fs.access(path.join(matchingDirectory, "nested"));
});

test("CARRIER-SCAVENGER-LOCK: an existing lock causes a bounded no-op", async (t) => {
  const root = await tempRoot(t);
  const lock = path.join(root, PROMPT_CARRIER_SCAVENGE_LOCK);
  await fs.writeFile(lock, "active", { flag: "wx", mode: 0o600 });
  const result = await scavengePromptCarriers({
    root,
    securityOps,
    leaseState: async () => "inactive",
  });
  assert.deepEqual(result, { state: "busy", scanned: 0, removed: 0, retained: 0, failed: 0 });
  assert.equal(await fs.readFile(lock, "utf8"), "active");
});
