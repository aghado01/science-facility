import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import { createHash } from "node:crypto";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { ClientConfigProvider } from "../../para-agent/src/client-integration/config-provider.js";
import {
  compileClientEnvironment,
  assertEnvironmentBackend,
} from "../../para-agent/src/client-integration/environment.js";
import { compileClientPolicy } from "../../para-agent/src/client-integration/policy.js";
import {
  compileInvocationRecipe,
  finalizeInvocationDescriptor,
  finalizeInvocationPlan,
} from "../../para-agent/src/client-integration/invocation.js";
import {
  preparePromptCarrier,
  materializePromptCarrier,
} from "../../para-agent/src/client-integration/carrier.js";
import { ClientRegistry } from "../../para-agent/src/client-integration/registry.js";
import { resolveWorkspace } from "../../para-agent/src/client-integration/workspace.js";
import { runReadiness } from "../../para-agent/src/client-integration/readiness.js";

const TEST_DIR = path.dirname(fileURLToPath(import.meta.url));
const FIXTURE_ROOT = path.join(TEST_DIR, "fixtures", "client-integration", "registry");
const VALID_ROOT = path.join(FIXTURE_ROOT, "valid");

function sha256(bytes) {
  return createHash("sha256").update(bytes).digest("hex");
}

async function readJson(file) {
  return JSON.parse(await fs.readFile(file, "utf8"));
}

async function fakeRegistry() {
  const provider = new ClientConfigProvider({ configRoot: VALID_ROOT });
  const snapshot = await provider.load();
  const adapter = await readJson(path.join(VALID_ROOT, "adapters", "fake-client.json"));
  return {
    snapshot,
    registry: new ClientRegistry(snapshot, { adapterProfiles: [adapter] }),
  };
}

function workspaceOps(root) {
  return {
    lstat: async (candidate) => ({
      isSymbolicLink: () => false,
      isDirectory: () => true,
      isReparsePoint: () => false,
      isFile: () => false,
      dev: 1,
      ino: 1,
    }),
    realpath: async (candidate) => {
      if (candidate === root || candidate.startsWith(`${root}${path.win32.sep}`)) return candidate;
      return candidate;
    },
  };
}

function parentEnvironment() {
  return {
    PATH: "/tmp/fake-bin",
    PARA_FAKE_TOKEN: "private-token",
  };
}

test("CLIENT-INTEGRATION-PIPELINE: fake delegate resolution compiles immutable plan and safe descriptor", async () => {
  const { registry } = await fakeRegistry();
  const resolved = registry.resolve({ application: "fake-client", sessionProfile: "restricted" });

  const workspace = await resolveWorkspace({
    workspace: resolved.hostBinding.workspaces[0],
    platform: "win32",
    fsOps: workspaceOps(resolved.hostBinding.workspaces[0].root),
    inspectReparse: () => ({ state: "passed" }),
  });

  const environment = compileClientEnvironment({
    integrationEnvironment: resolved.integration.environment,
    hostEnvironment: resolved.hostBinding.environment,
    sessionEnvironment: resolved.sessionProfile.environment,
    parentEnvironment: parentEnvironment(),
    platform: "win32",
  });
  const envWithProof = assertEnvironmentBackend(environment, {
    backendKind: resolved.modeProfile.backend,
    exactIsolationProof: { state: "passed", backend_kind: "process", evidence_kind: "process_backend" },
  });
  const policy = compileClientPolicy({
    integrationPolicy: resolved.integration.policy,
    hostPolicy: resolved.hostBinding.policy,
    sessionPolicy: resolved.sessionProfile.policy,
  });

  const compiled = compileInvocationRecipe({
    resolved,
    environmentResult: envWithProof,
    workspaceResult: {
      private: { cwd: workspace.private.cwd },
      descriptor: workspace.descriptor,
      readiness_facts: workspace.readiness_facts,
    },
    policyResult: policy,
  });

  const readiness = await runReadiness({
    integrationRevision: resolved.integration.revision,
    ...compiled.recipe.readiness,
    staticEvidence: {
      executable: {
        state: "passed",
        evidenceKind: "compiled_executable",
        facts: { available: true },
      },
      environment_exact: {
        state: "passed",
        evidenceKind: "compiled_environment",
        facts: { exact: true },
      },
      workspace: {
        state: "passed",
        evidenceKind: "resolved_workspace",
        facts: { working_directory_id: workspace.readiness_facts.workspace.working_directory_id },
      },
      prompt_carrier: {
        state: "passed",
        evidenceKind: "planned_carrier",
        facts: { kind: "stdin_utf8" },
      },
      backend: {
        state: "passed",
        evidenceKind: "profile_backend",
        facts: { kind: "process" },
      },
    },
    executor: ({ dimension }) => {
      if (dimension === "version") {
        return Promise.resolve({
          exitCode: 0,
          stdout: Buffer.from("1.0.0-fixture"),
          stderr: Buffer.alloc(0),
        });
      }
      return Promise.reject(new Error(`unexpected readiness probe ${dimension}`));
    },
  });

  const descriptor = finalizeInvocationDescriptor(compiled.descriptorBasis, readiness);
  const prepared = await preparePromptCarrier(compiled.recipe.carrier);
  const prompt = await materializePromptCarrier(prepared, "hello from para-agent");
  const plan = finalizeInvocationPlan(compiled.recipe, {
    exchangeId: "exchange-1",
    carrier: prompt,
  });

  assert.equal(Object.isFrozen(compiled.recipe), true);
  assert.equal(Object.isFrozen(plan), true);
  assert.equal(plan.exchange_id, "exchange-1");
  assert.deepEqual(Object.keys(plan.environment).sort(), ["FAKE_OPTIONAL", "FAKE_TOKEN", "PATH"].sort());
  assert.equal(plan.prompt.kind, "stdin_utf8");
  assert.equal(plan.backend.kind, "process");
  assert.equal(plan.prompt.sha256, sha256(Buffer.from("hello from para-agent")));
  assert.equal(prompt.readBytes().toString(), "hello from para-agent");

  assert.equal(descriptor.readiness.version.version, "1.0.0-fixture");
  assert.equal(descriptor.adapter.id, "para-agent.fake-client");
  assert.equal(descriptor.workspace.working_directory_id, workspace.descriptor.workspace.working_directory_id);
  assert.equal(Object.isFrozen(descriptor), true);

  const publicText = JSON.stringify(descriptor);
  assert.equal(publicText.includes("D:\\fake-client\\fake-client.exe"), false);
  assert.equal(publicText.includes("private-token"), false);
});
