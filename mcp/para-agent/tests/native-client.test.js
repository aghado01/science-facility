import test from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { ProcessNativeClient } from "../../para-agent/src/native-client.js";

const fixture = path.join(
  path.dirname(fileURLToPath(import.meta.url)),
  "support",
  "native-client-child.mjs",
);

function childArgs(mode) {
  return [fixture, mode];
}

test("writes exact hostile multiline Unicode prompt bytes without an implicit newline", async (t) => {
  const client = new ProcessNativeClient();
  t.after(() => client.close());
  const prompt = "first line\n'\"`$()|;&<>\nλ 第二行 👩🏽‍🔬\u0000tail";
  const expected = Buffer.from(prompt, "utf8");
  const observed = [];

  const result = await client.run({
    executable: process.execPath,
    args: childArgs("echo"),
    prompt,
    onStdout: (chunk, meta) => observed.push({ chunk, meta }),
  });

  assert.equal(result.outcome, "completed");
  assert.equal(result.ok, true);
  assert.equal(result.prompt.writeCompleted, true);
  assert.match(result.prompt.writeCompletedAt, /^\d{4}-\d{2}-\d{2}T/);
  assert.equal(result.prompt.bytes, expected.length);
  assert.deepEqual(result.stdout, expected);
  assert.deepEqual(Buffer.concat(observed.map((item) => item.chunk)), expected);
  assert.equal(result.stderr.length, 0);
});

test("streams stdout and stderr separately with one monotonic observation order", async (t) => {
  const client = new ProcessNativeClient();
  t.after(() => client.close());
  const observations = [];
  const result = await client.run({
    executable: process.execPath,
    args: childArgs("separate"),
    prompt: "",
    onStdout: (chunk, meta) => observations.push({ bytes: chunk, ...meta }),
    onStderr: (chunk, meta) => observations.push({ bytes: chunk, ...meta }),
  });

  assert.equal(result.outcome, "completed");
  assert.equal(result.stdout.toString("utf8"), "stdout-onestdout-two");
  assert.equal(result.stderr.toString("utf8"), "stderr-one");
  assert.deepEqual(observations.map((item) => item.index), observations.map((_, index) => index));
  assert.ok(observations.every((item) => Buffer.isBuffer(item.bytes)));
  assert.equal(result.output.observations, observations.length);
});

test("reports a nonzero exit without merging stderr into stdout", async (t) => {
  const client = new ProcessNativeClient();
  t.after(() => client.close());
  const result = await client.run({
    executable: process.execPath,
    args: childArgs("nonzero"),
    prompt: "request",
  });

  assert.equal(result.ok, false);
  assert.equal(result.outcome, "nonzero");
  assert.equal(result.exitCode, 23);
  assert.equal(result.stdout.toString("utf8"), "partial-output");
  assert.equal(result.stderr.toString("utf8"), "native-failure");
  assert.equal(result.termination.requested, false);
  assert.equal(result.termination.closed, true);
});

test("reports spawn failure as a transport outcome", async (t) => {
  const client = new ProcessNativeClient();
  t.after(() => client.close());
  const result = await client.run({
    executable: path.join(path.dirname(fixture), "definitely-not-an-executable"),
    args: [],
    prompt: "request",
  });

  assert.equal(result.ok, false);
  assert.equal(result.outcome, "spawn_failed");
  assert.equal(result.spawned, false);
  assert.equal(result.prompt.writeCompleted, false);
  assert.ok(result.error?.message);
});

test("times out, terminates, and confirms child close", async (t) => {
  const client = new ProcessNativeClient({ terminationGraceMs: 250 });
  t.after(() => client.close());
  const result = await client.run({
    executable: process.execPath,
    args: childArgs("hang"),
    prompt: "request",
    timeoutMs: 75,
  });

  assert.equal(result.outcome, "timeout");
  assert.equal(result.termination.requested, true);
  assert.equal(result.termination.reason, "timeout");
  assert.equal(result.termination.closedAfterRequest, true);
});

test("AbortSignal cancellation terminates and confirms child close", async (t) => {
  const client = new ProcessNativeClient({ terminationGraceMs: 250 });
  t.after(() => client.close());
  const controller = new AbortController();
  const pending = client.run({
    executable: process.execPath,
    args: childArgs("hang"),
    prompt: "request",
    signal: controller.signal,
  });
  setTimeout(() => controller.abort(), 75);
  const result = await pending;

  assert.equal(result.outcome, "cancelled");
  assert.equal(result.termination.requested, true);
  assert.equal(result.termination.reason, "cancelled");
  assert.equal(result.termination.closedAfterRequest, true);
});

test("combined output bound terminates and returns only the bounded prefix", async (t) => {
  const client = new ProcessNativeClient({ maxBufferBytes: 512, terminationGraceMs: 250 });
  t.after(() => client.close());
  const result = await client.run({
    executable: process.execPath,
    args: childArgs("flood"),
    prompt: "request",
  });

  assert.equal(result.outcome, "max_buffer");
  assert.equal(result.output.maxBufferBytes, 512);
  assert.equal(result.output.capturedBytes, 512);
  assert.ok(result.stdout.length + result.stderr.length <= 512);
  assert.equal(result.output.truncated, true);
  assert.equal(result.termination.requested, true);
  assert.equal(result.termination.closedAfterRequest, true);
});

test("rejects ill-formed Unicode rather than changing prompt bytes", async (t) => {
  const client = new ProcessNativeClient();
  t.after(() => client.close());
  await assert.rejects(
    client.run({ executable: process.execPath, args: childArgs("echo"), prompt: "\ud800" }),
    /well-formed Unicode/,
  );
});
