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
} from "../../para-agent/src/index.js";
import { MediatedTurnError } from "../../para-agent/src/mediated-turn.js";
import { TranscriptStore } from "../../para-agent/src/transcript.js";
import { memoryTransportPair } from "./support/memory-transport.js";

const here = path.dirname(fileURLToPath(import.meta.url));
const packageRoot = path.resolve(here, "../../para-agent");
const packageRequire = createRequire(path.join(packageRoot, "package.json"));
const { Client } = await import(pathToFileURL(packageRequire.resolve("@modelcontextprotocol/sdk/client/index.js")).href);

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
        },
      };
    },
  });

  await registerNativeSkills(server);
  const pair = memoryTransportPair();
  await server.connect(pair.server);
  const client = new Client({ name: "para-agent-mcp-test", version: "1.0.0" });
  await client.connect(pair.client);

  try {
    const listed = await client.listTools();
    const tools = new Map(listed.tools.map((tool) => [tool.name, tool]));
    for (const required of [
      "delegate", "scrutinize", "spawn", "send", "wait", "read", "run", "log", "body", "find", "cancel", "kill", "skills",
    ]) {
      assert.ok(tools.has(required), `missing tool ${required}`);
    }
    assert.deepEqual(new Set(tools.get("delegate").inputSchema.required), new Set(["handle", "application", "prompt"]));
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

    const skills = parsedResult(await client.callTool({ name: "skills", arguments: {} }));
    assert.ok(skills.availableSkills.some((skill) => skill.name === "primary"));
  } finally {
    await client.close();
    await pair.server.close();
  }
});
