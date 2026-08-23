import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import path from "node:path";
import { createRequire } from "node:module";
import { fileURLToPath, pathToFileURL } from "node:url";

import {
  registerNativeSkills,
  server,
  setMediatedTurnServiceForTesting,
} from "../src/index.js";
import { MediatedTurnError } from "../src/mediated-turn.js";
import { TranscriptStore } from "../src/transcript.js";
import { memoryTransportPair } from "./support/memory-transport.js";

const here = path.dirname(fileURLToPath(import.meta.url));
const packageRoot = path.resolve(here, "../../para-agent");
const depsRequire = createRequire(path.join(packageRoot, "deps", "node_modules", "index.js"));
const { Client } = await import(pathToFileURL(depsRequire.resolve("@modelcontextprotocol/sdk/client/index.js")).href);

function parsedResult(result) {
  assert.ok(Array.isArray(result.content));
  assert.equal(result.content[0]?.type, "text");
  return JSON.parse(result.content[0].text);
}

test("MCP wire exposes thin delegate/scrutiny semantics and preserves console schemas", async () => {
  const calls = [];
  setMediatedTurnServiceForTesting({
    async delegate(request) {
      calls.push(request);
      if (request.prompt === "fail durably") {
        throw new MediatedTurnError("NATIVE_TERMINAL_FAILED", "receiver reported failure", {
          receipt: {
            exchange_id: "xid-failed",
            exchange_index: 3,
            status: "failed",
            prompt: { sha256: "a".repeat(64), bytes: 14 },
            trace: { complete: true, ref: "traces/fake/xid-failed.trace" },
          },
        });
      }
      return {
        reply: "receiver-authoritative reply",
        receipt: {
          exchange_id: "xid-completed",
          exchange_index: 2,
          status: "completed",
          prompt: { sha256: "b".repeat(64), bytes: Buffer.byteLength(request.prompt) },
          reply: { sha256: "c".repeat(64), bytes: 28 },
          trace: { complete: true, ref: "traces/fake/xid-completed.trace" },
          egress: {
            stage: "constructed",
            observed_at: "2026-08-14T12:00:03.000Z",
            reply_sha256: "c".repeat(64),
          },
        },
      };
    },
  });

  await registerNativeSkills(server);
  const pair = memoryTransportPair();
  await server.connect(pair.server);
  const client = new Client({ name: "para-agent-mcp-test", version: "1.0.0" });
  await client.connect(pair.client);
  let statusStore = null;
  const cleanupPaths = [];

  try {
    const listed = await client.listTools();
    const tools = new Map(listed.tools.map((tool) => [tool.name, tool]));
    for (const required of [
      "delegate", "quarantine_status", "scrutinize", "spawn", "send", "wait", "read", "run", "log", "body", "find", "cancel", "kill", "skills",
    ]) {
      assert.ok(tools.has(required), `missing tool ${required}`);
    }
    assert.deepEqual(new Set(tools.get("delegate").inputSchema.required), new Set(["handle", "application", "prompt"]));
    assert.deepEqual(new Set(tools.get("quarantine_status").inputSchema.required), new Set(["application", "handle"]));
    assert.equal(tools.has("quarantine_reconcile"), false, "ordinary MCP must not expose quarantine mutation");
    assert.ok("input" in tools.get("send").inputSchema.properties);
    assert.ok(!("text" in tools.get("send").inputSchema.properties));
    assert.ok("stableForMs" in tools.get("wait").inputSchema.properties);
    assert.ok(!("stableMs" in tools.get("wait").inputSchema.properties));
    assert.ok("scope" in tools.get("kill").inputSchema.properties);

    const completed = await client.callTool({
      name: "delegate",
      arguments: {
        handle: "review-seat",
        application: "claude",
        prompt: "exact λ 雪 prompt",
        timeoutMs: 30_000,
      },
    });
    assert.notEqual(completed.isError, true);
    const completedPayload = parsedResult(completed);
    assert.equal(completedPayload.reply, "receiver-authoritative reply");
    assert.equal(completedPayload.receipt.exchange_id, "xid-completed");
    assert.equal(completedPayload.receipt.egress.stage, "constructed");
    assert.equal(calls[0].prompt, "exact λ 雪 prompt");

    const failed = await client.callTool({
      name: "delegate",
      arguments: { handle: "review-seat", application: "claude", prompt: "fail durably" },
    });
    assert.equal(failed.isError, true);
    const failedPayload = parsedResult(failed);
    assert.equal(failedPayload.error.code, "NATIVE_TERMINAL_FAILED");
    assert.equal(failedPayload.receipt.exchange_id, "xid-failed");
    assert.equal("reply" in failedPayload, false);

    const unknownSession = `unknown-mcp-${process.pid}-${Date.now()}`;
    const probe = new TranscriptStore({
      workspaceRoot: process.cwd(),
      sessionId: unknownSession,
      mode: "read-only",
    });
    await assert.rejects(fs.access(probe.filePath));
    const unknownQuarantine = await client.callTool({
      name: "quarantine_status",
      arguments: { application: "claude", handle: unknownSession },
    });
    assert.notEqual(unknownQuarantine.isError, true);
    assert.deepEqual(parsedResult(unknownQuarantine), {
      found: false,
      blocked: false,
      gate: { active: false, quarantined: null },
      durable_notices: [],
    });

    const originalOpenReadOnly = TranscriptStore.openReadOnly;
    let invalidTargetStoreOpens = 0;
    TranscriptStore.openReadOnly = async (...args) => {
      invalidTargetStoreOpens++;
      return originalOpenReadOnly.call(TranscriptStore, ...args);
    };
    try {
      const invalidTargets = [
        ["leading application whitespace", { application: " claude", handle: unknownSession }],
        ["trailing application whitespace", { application: "claude ", handle: unknownSession }],
        ["leading handle whitespace", { application: "claude", handle: ` ${unknownSession}` }],
        ["trailing handle whitespace", { application: "claude", handle: `${unknownSession} ` }],
        ["ill-formed application", { application: "claude\ud800", handle: unknownSession }],
        ["ill-formed handle", { application: "claude", handle: `${unknownSession}\ud801` }],
      ];
      for (const [name, target] of invalidTargets) {
        const invalid = await client.callTool({ name: "quarantine_status", arguments: target });
        assert.equal(invalid.isError, true, name);
        assert.match(
          invalid.content[0]?.text ?? "",
          name.startsWith("ill-formed")
            ? /must be well-formed Unicode/
            : /must not contain leading or trailing whitespace/,
          name,
        );
      }
      const callsBeforeInvalidDelegate = calls.length;
      for (const [name, target] of invalidTargets) {
        const invalid = await client.callTool({
          name: "delegate",
          arguments: { ...target, prompt: "must fail before service dispatch" },
        });
        assert.equal(invalid.isError, true, `delegate ${name}`);
      }
      assert.equal(calls.length, callsBeforeInvalidDelegate, "invalid delegate identity must fail before service dispatch");

      for (const handle of [` ${unknownSession}`, `${unknownSession} `, `${unknownSession}\ud800`]) {
        const invalid = await client.callTool({ name: "scrutinize", arguments: { handle } });
        assert.equal(invalid.isError, true, `scrutinize ${JSON.stringify(handle)}`);
      }
    } finally {
      TranscriptStore.openReadOnly = originalOpenReadOnly;
    }
    assert.equal(invalidTargetStoreOpens, 0, "invalid identity spelling must fail before store open");

    const scrutiny = await client.callTool({
      name: "scrutinize",
      arguments: { handle: unknownSession },
    });
    assert.notEqual(scrutiny.isError, true);
    assert.deepEqual(parsedResult(scrutiny), {
      session: unknownSession,
      found: false,
      exchanges: [],
    });
    await assert.rejects(fs.access(probe.filePath));
    await assert.rejects(fs.access(probe.walPath));
    await assert.rejects(fs.access(probe.lockPath));

    const statusSession = `quarantine-mcp-${process.pid}-${Date.now()}`;
    const statusHandle = `${statusSession}:0.0`;
    statusStore = await TranscriptStore.openWritable({
      workspaceRoot: process.cwd(),
      sessionId: statusSession,
    });
    cleanupPaths.push(statusStore.filePath, statusStore.walPath, statusStore.lockPath);
    const acceptance = await statusStore.acceptExchange({
      prompt: "Status target prompt.",
      senderParticipantId: "primary",
      receiverParticipantId: "para",
      conversationKey: `claude:${statusHandle}`,
      adapter: { id: "status-test", version: "1" },
      requestId: "status-target-request",
      selectedApplicationId: "claude",
    });
    const exchangeEnd = new Date(Date.parse(acceptance.accepted_at) + 1000).toISOString();
    await statusStore.commitExchange({
      exchange_id: acceptance.exchange_id,
      status: "failed",
      exchange_end: exchangeEnd,
      outcome: {
        code: "CLIENT_FAILED",
        message: "The receiver did not produce a terminal reply.",
        retryable: true,
        native_stop_confirmed: false,
      },
      trace: {
        complete: false,
        omissions: [{ code: "TRACE_UNAVAILABLE", detail: "No validated receiver-native frame was observed." }],
      },
      delivery: { events: [] },
      records: [],
    });
    const unrelated = await statusStore.acceptExchange({
      prompt: "Unrelated lane prompt.",
      senderParticipantId: "primary",
      receiverParticipantId: "para",
      conversationKey: `codex:${statusHandle}`,
      adapter: { id: "status-test", version: "1" },
      requestId: "status-unrelated-request",
      selectedApplicationId: "codex",
    });
    await statusStore.commitExchange({
      exchange_id: unrelated.exchange_id,
      status: "failed",
      exchange_end: new Date(Date.parse(unrelated.accepted_at) + 1000).toISOString(),
      outcome: {
        code: "UNRELATED_FAILURE",
        message: "This notice belongs to another application lane.",
        retryable: true,
        native_stop_confirmed: false,
      },
      trace: {
        complete: false,
        omissions: [{ code: "TRACE_UNAVAILABLE", detail: "No validated receiver-native frame was observed." }],
      },
      delivery: { events: [] },
      records: [],
    });
    await statusStore.close();
    statusStore = null;
    const transcriptBeforeStatus = await fs.readFile(cleanupPaths[0]);
    const walBeforeStatus = await fs.readFile(cleanupPaths[1]);

    const quarantine = await client.callTool({
      name: "quarantine_status",
      arguments: { application: "claude", handle: statusHandle },
    });
    assert.notEqual(quarantine.isError, true);
    assert.deepEqual(parsedResult(quarantine), {
      found: true,
      blocked: true,
      gate: { active: false, quarantined: null },
      durable_notices: [{
        exchange_id: acceptance.exchange_id,
        conversation_key: `claude:${statusHandle}`,
        terminal_status: "failed",
        reason: "CLIENT_FAILED: The receiver did not produce a terminal reply.",
        observed_at: exchangeEnd,
        outcome: {
          code: "CLIENT_FAILED",
          message: "The receiver did not produce a terminal reply.",
          native_stop_confirmed: false,
        },
      }],
    });
    assert.deepEqual(await fs.readFile(cleanupPaths[0]), transcriptBeforeStatus);
    assert.deepEqual(await fs.readFile(cleanupPaths[1]), walBeforeStatus);
    await assert.rejects(fs.access(cleanupPaths[2]), { code: "ENOENT" });

    const skills = parsedResult(await client.callTool({ name: "skills", arguments: {} }));
    assert.ok(skills.availableSkills.some((skill) => skill.name === "primary"));
  } finally {
    await statusStore?.close();
    await client.close();
    await pair.server.close();
    for (const filePath of cleanupPaths) await fs.rm(filePath, { force: true });
  }
});
