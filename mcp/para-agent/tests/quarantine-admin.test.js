import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { main } from "../src/quarantine-admin.js";
import { TranscriptStore } from "../src/transcript.js";

const ADMIN_PATH = fileURLToPath(new URL("../src/quarantine-admin.js", import.meta.url));
const APPLICATION = "codex";
const SESSION = "operator-seat";
const HANDLE = "operator-seat:0.0";
const EXCHANGE_ID = "xid-quarantined-1";
const REASON = "terminal transcript commit is ambiguous and requires store reconciliation";
const OBSERVED_AT = "2026-08-14T18:00:00.000Z";
const BASIS = "terminal_commit_verified";
const EVIDENCE_REF = "operator-log://verified-terminal/71";

function capture() {
  let text = "";
  return {
    stream: {
      write(chunk) {
        text += String(chunk);
        return true;
      },
    },
    text: () => text,
    json: () => JSON.parse(text),
  };
}

function commonArgs(command, workspaceRoot) {
  return [
    command,
    "--workspace-root", workspaceRoot,
    "--application", APPLICATION,
    "--handle", HANDLE,
  ];
}

function reconcileArgs(workspaceRoot) {
  return [
    ...commonArgs("reconcile", workspaceRoot),
    "--exchange-id", EXCHANGE_ID,
    "--reason", REASON,
    "--observed-at", OBSERVED_AT,
    "--basis", BASIS,
    "--evidence-ref", EVIDENCE_REF,
  ];
}

async function tempWorkspace(t) {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "para-agent-quarantine-admin-"));
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  return root;
}

async function invoke(argv, dependencies = {}) {
  const stdout = capture();
  const stderr = capture();
  const code = await main(argv, {
    stdout: stdout.stream,
    stderr: stderr.stream,
    env: {},
    ...dependencies,
  });
  return { code, stdout, stderr };
}

test("status uses a read-only store and does not create an unknown transcript", async (t) => {
  const root = await tempWorkspace(t);
  const before = await fs.readdir(root);
  const result = await invoke(commonArgs("status", root));

  assert.equal(result.code, 0);
  assert.equal(result.stderr.text(), "");
  assert.deepEqual(result.stdout.json(), {
    ok: true,
    command: "status",
    result: {
      workspace_root: path.resolve(root),
      application: APPLICATION,
      handle: HANDLE,
      conversation_key: `${APPLICATION}:${HANDLE}`,
      gate: { attached: false },
      transcript: { exists: false },
      quarantines: [],
    },
  });
  assert.deepEqual(await fs.readdir(root), before);
});

test("status and reconcile reject noncanonical identities before any transcript store opens", async (t) => {
  const root = await tempWorkspace(t);
  const cases = [
    ["status", "--application", ` ${APPLICATION}`, "--application must not contain leading or trailing whitespace"],
    ["status", "--application", `${APPLICATION} `, "--application must not contain leading or trailing whitespace"],
    ["status", "--handle", ` ${HANDLE}`, "--handle must not contain leading or trailing whitespace"],
    ["status", "--handle", `${HANDLE} `, "--handle must not contain leading or trailing whitespace"],
    ["status", "--application", `${APPLICATION}\ud800`, "--application must be well-formed Unicode"],
    ["status", "--handle", `${HANDLE}\ud801`, "--handle must be well-formed Unicode"],
    ["reconcile", "--application", ` ${APPLICATION}`, "--application must not contain leading or trailing whitespace"],
    ["reconcile", "--application", `${APPLICATION} `, "--application must not contain leading or trailing whitespace"],
    ["reconcile", "--handle", ` ${HANDLE}`, "--handle must not contain leading or trailing whitespace"],
    ["reconcile", "--handle", `${HANDLE} `, "--handle must not contain leading or trailing whitespace"],
    ["reconcile", "--application", `${APPLICATION}\ud800`, "--application must be well-formed Unicode"],
    ["reconcile", "--handle", `${HANDLE}\ud801`, "--handle must be well-formed Unicode"],
  ];

  for (const [command, option, value, message] of cases) {
    const argv = command === "status" ? commonArgs(command, root) : reconcileArgs(root);
    argv[argv.indexOf(option) + 1] = value;
    let storeCalls = 0;
    const result = await invoke(argv, {
      env: { PARA_AGENT_ENABLE_QUARANTINE_ADMIN: "1" },
      openReadOnly: async () => {
        storeCalls++;
        assert.fail("noncanonical identity must fail before read-only store open");
      },
      openWritable: async () => {
        storeCalls++;
        assert.fail("noncanonical identity must fail before writable store open");
      },
    });

    assert.equal(result.code, 1, `${command} ${option}=${JSON.stringify(value)}`);
    assert.equal(result.stdout.text(), "");
    assert.deepEqual(result.stderr.json(), {
      ok: false,
      error: {
        code: "QUARANTINE_ADMIN_ARGUMENT_INVALID",
        name: "QuarantineAdminError",
        message,
      },
    });
    assert.equal(storeCalls, 0);
  }
});

test("reconcile preflights the header, then delegates under the writable lease", async () => {
  const root = path.resolve("test-workspace");
  const calls = [];
  const header = {
    transcript_id: "trn-admin-test",
    session: { session_id: SESSION },
  };
  const durable = {
    record_type: "conversation_reconciliation",
    schema_version: 1,
    reconciliation_id: "rid-admin-test",
    conversation_key: `${APPLICATION}:${HANDLE}`,
    exchange_id: EXCHANGE_ID,
    expected: { reason: REASON, observed_at: OBSERVED_AT },
    basis: { kind: BASIS, evidence_ref: EVIDENCE_REF },
  };

  const result = await invoke(reconcileArgs(root), {
    env: { PARA_AGENT_ENABLE_QUARANTINE_ADMIN: "1" },
    openReadOnly: async (options) => {
      calls.push(["read-open", options]);
      return {
        async readHeader() {
          calls.push(["read-header"]);
          return header;
        },
        getRecoveryNotices() {
          calls.push(["read-quarantines"]);
          return [];
        },
        async close() {
          calls.push(["read-close"]);
        },
      };
    },
    openWritable: async (options) => {
      calls.push(["write-open", options]);
      return {
        async reconcileQuarantine(input) {
          calls.push(["reconcile", structuredClone(input)]);
          return durable;
        },
        async close() {
          calls.push(["write-close"]);
        },
      };
    },
  });

  assert.equal(result.code, 0);
  assert.equal(result.stderr.text(), "");
  assert.deepEqual(calls, [
    ["read-open", { workspaceRoot: root, sessionId: SESSION }],
    ["read-header"],
    ["read-quarantines"],
    ["read-close"],
    ["write-open", { workspaceRoot: root, sessionId: SESSION }],
    ["reconcile", {
      conversationKey: `${APPLICATION}:${HANDLE}`,
      exchangeId: EXCHANGE_ID,
      expected: { reason: REASON, observedAt: OBSERVED_AT },
      basis: { kind: BASIS, evidenceRef: EVIDENCE_REF },
    }],
    ["write-close"],
  ]);
  assert.deepEqual(result.stdout.json(), {
    ok: true,
    command: "reconcile",
    result: {
      workspace_root: root,
      application: APPLICATION,
      handle: HANDLE,
      conversation_key: `${APPLICATION}:${HANDLE}`,
      exchange_id: EXCHANGE_ID,
      durable,
      gate: { attached: false, cleared: false },
    },
  });
});

test("reconcile refuses an unknown transcript before opening writable state", async () => {
  let writableCalls = 0;
  const result = await invoke(reconcileArgs(path.resolve("missing-workspace")), {
    env: { PARA_AGENT_ENABLE_QUARANTINE_ADMIN: "1" },
    openReadOnly: async () => ({
      async readHeader() { return null; },
      getRecoveryNotices() { return []; },
      async close() {},
    }),
    openWritable: async () => {
      writableCalls++;
      assert.fail("unknown transcript must fail before writable open");
    },
  });

  assert.equal(result.code, 1);
  assert.equal(result.stdout.text(), "");
  assert.equal(result.stderr.json().error.code, "QUARANTINE_ADMIN_TRANSCRIPT_NOT_FOUND");
  assert.equal(writableCalls, 0);
});

test("reconcile is disabled by default before any transcript store opens", async () => {
  let storeCalls = 0;
  const result = await invoke(reconcileArgs(path.resolve("disabled-workspace")), {
    openReadOnly: async () => {
      storeCalls++;
      assert.fail("disabled reconciliation must not inspect transcript storage");
    },
    openWritable: async () => {
      storeCalls++;
      assert.fail("disabled reconciliation must not acquire a writer lease");
    },
  });

  assert.equal(result.code, 1);
  assert.equal(result.stdout.text(), "");
  assert.deepEqual(result.stderr.json(), {
    ok: false,
    error: {
      code: "QUARANTINE_ADMIN_DISABLED",
      name: "QuarantineAdminError",
      message: "offline reconciliation is disabled; set PARA_AGENT_ENABLE_QUARANTINE_ADMIN=1 to opt in",
    },
  });
  assert.equal(storeCalls, 0);
});

test("argument errors are JSON and no force option reaches transcript storage", async () => {
  let storeCalls = 0;
  const result = await invoke([
    ...reconcileArgs(path.resolve("force-workspace")),
    "--force", "true",
  ], {
    openReadOnly: async () => {
      storeCalls++;
      assert.fail("invalid arguments must not open transcript storage");
    },
  });

  assert.equal(result.code, 1);
  assert.equal(result.stdout.text(), "");
  assert.deepEqual(result.stderr.json(), {
    ok: false,
    error: {
      code: "QUARANTINE_ADMIN_ARGUMENT_INVALID",
      name: "QuarantineAdminError",
      message: "unsupported option '--force'",
    },
  });
  assert.equal(storeCalls, 0);
});

test("a live writable owner remains authoritative over offline reconciliation", async (t) => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "para-agent-quarantine-admin-lease-"));
  const owner = await TranscriptStore.openWritable({ workspaceRoot: root, sessionId: SESSION });
  t.after(async () => {
    await owner.close();
    await fs.rm(root, { recursive: true, force: true });
  });

  const result = await invoke(reconcileArgs(root), {
    env: { PARA_AGENT_ENABLE_QUARANTINE_ADMIN: "1" },
  });
  assert.equal(result.code, 1);
  assert.equal(result.stdout.text(), "");
  assert.equal(result.stderr.json().error.code, "TRANSCRIPT_WRITER_BUSY");
  assert.equal((await owner.readHeader()).session.session_id, SESSION);
});

test("package metadata and direct entry expose the separate administrative command", async () => {
  const packageRoot = path.dirname(path.dirname(ADMIN_PATH));
  const manifest = JSON.parse(await fs.readFile(path.join(packageRoot, "package.json"), "utf8"));
  const lock = JSON.parse(await fs.readFile(path.join(packageRoot, "package-lock.json"), "utf8"));
  assert.equal(manifest.bin["para-agent-quarantine"], "src/quarantine-admin.js");
  assert.equal(lock.packages[""].bin["para-agent-quarantine"], "src/quarantine-admin.js");
  assert.equal(manifest.engines.node, ">=20");
  assert.equal(lock.packages[""].engines.node, manifest.engines.node);
  assert.match(await fs.readFile(ADMIN_PATH, "utf8"), /^#!\/usr\/bin\/env node\r?\n/);
});
