import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";

import { NuEngine, NuExecutionError } from "../../para-agent/src/nu.js";
import { TranscriptQuery } from "../../para-agent/src/transcript-query.js";

function assertNuFailure(error, code) {
  assert.ok(error instanceof NuExecutionError);
  const envelope = JSON.parse(error.message);
  assert.equal(envelope.protocol, "para-agent.nu.v1");
  assert.equal(envelope.ok, false);
  assert.equal(envelope.error.code, code);
  assert.notEqual(envelope.exit_code, 0);
  return true;
}

const rows = [
  { record_type: "transcript_header", transcript_id: "trn-test" },
  {
    record_type: "transcript_exchange",
    exchange_id: "xid-α|'quoted'",
    exchange_index: 0,
    exchange_start: "2026-08-14T00:00:00.000Z",
    exchange_end: "2026-08-14T00:00:01.000Z",
    model: "model/opaque-λ",
    status: "completed",
    records: [
      { _type: "prompt", text: "line one\n第二行" },
      { _type: "thinking", text: "visible thought" },
      { _type: "tool_call", tool_name: "read" },
      { _type: "response", phase: "final", text: "done ✓" },
    ],
  },
  {
    record_type: "transcript_exchange",
    exchange_id: "xid-α",
    exchange_index: 1,
    exchange_start: "2026-08-14T00:00:02.000Z",
    exchange_end: "2026-08-14T00:00:03.000Z",
    status: "failed",
    records: [],
  },
];

test("strict structured evaluation round-trips exact Unicode JSON", async (t) => {
  const engine = new NuEngine();
  t.after(() => engine.close());
  const input = { text: "λ — 第二行 — 👩🏽‍🔬\nexact" };
  assert.deepEqual(await engine.eval("$in", input), input);
});

test("raw output is available only through explicit evalRaw", async (t) => {
  const engine = new NuEngine();
  t.after(() => engine.close());
  assert.equal(await engine.evalRaw("get text", { text: "raw λ\n第二行" }), "raw λ\n第二行");
});

test("NU-SCRUTINY-FALSE-SUCCESS: runtime errors reject and do not mutate transcript bytes", async (t) => {
  const engine = new NuEngine();
  t.after(() => engine.close());
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), "para-nu-false-success-"));
  t.after(() => fs.rm(dir, { recursive: true, force: true }));
  const transcript = path.join(dir, "transcript.jsonl");
  const before = Buffer.from('{"record_type":"transcript_header"}\n', "utf8");
  await fs.writeFile(transcript, before);

  await assert.rejects(
    engine.eval("get rows | get missing_column", { rows }),
    (error) => assertNuFailure(error, "NU_RUNTIME"),
  );
  assert.deepEqual(await fs.readFile(transcript), before);
});

test("syntax failures reject with one valid nonzero error envelope", async (t) => {
  const engine = new NuEngine();
  t.after(() => engine.close());
  await assert.rejects(
    engine.eval("this is [ invalid nu source"),
    (error) => assertNuFailure(error, "NU_PROCESS_FAILURE"),
  );
});

test("timeout rejects structurally and terminates the Nu process", async (t) => {
  const engine = new NuEngine();
  t.after(() => engine.close());
  await assert.rejects(
    engine.eval("do { sleep 5sec; null }", null, { timeoutMs: 50 }),
    (error) => assertNuFailure(error, "NU_TIMEOUT"),
  );
});

test("AbortSignal cancellation rejects structurally", async (t) => {
  const engine = new NuEngine();
  t.after(() => engine.close());
  const controller = new AbortController();
  const pending = engine.eval("do { sleep 5sec; null }", null, { signal: controller.signal });
  setTimeout(() => controller.abort(), 50);
  await assert.rejects(pending, (error) => assertNuFailure(error, "NU_CANCELLED"));
});

test("max-buffer overflow rejects instead of returning truncated data", async (t) => {
  const engine = new NuEngine();
  t.after(() => engine.close());
  await assert.rejects(
    engine.eval("get text", { text: "x".repeat(8192) }, { maxBufferBytes: 128 }),
    (error) => assertNuFailure(error, "NU_MAX_BUFFER"),
  );
});

test("typed transcript summaries tolerate absent duration_ms", async (t) => {
  const engine = new NuEngine();
  const query = new TranscriptQuery(engine);
  t.after(() => engine.close());
  assert.deepEqual(await query.summary(rows), [
    {
      xid: "xid-α|'quoted'",
      xidx: 0,
      exchange_start: "2026-08-14T00:00:00.000Z",
      exchange_end: "2026-08-14T00:00:01.000Z",
      duration_ms: null,
      model: "model/opaque-λ",
      status: "completed",
      steps: 4,
      tools: 1,
      thinking: 1,
    },
    {
      xid: "xid-α",
      xidx: 1,
      exchange_start: "2026-08-14T00:00:02.000Z",
      exchange_end: "2026-08-14T00:00:03.000Z",
      duration_ms: null,
      model: null,
      status: "failed",
      steps: 0,
      tools: 0,
      thinking: 0,
    },
  ]);
});

test("typed record and step selectors use exact exchange identity", async (t) => {
  const engine = new NuEngine();
  const query = new TranscriptQuery(engine);
  t.after(() => engine.close());

  const exactId = "xid-α|'quoted'";
  const thinking = await query.records(rows, { exchangeId: exactId, kind: "thinking" });
  assert.deepEqual(thinking, [{ _type: "thinking", text: "visible thought" }]);
  assert.deepEqual(await query.step(rows, { exchangeId: exactId, step: 3 }), {
    _type: "response",
    phase: "final",
    text: "done ✓",
  });
  assert.deepEqual(await query.records(rows, { exchangeId: "xid-α", kind: "all" }), []);
  assert.equal(await query.step(rows, { exchangeId: "missing", step: 0 }), null);
});

test("typed selectors remain JSON data even when they contain Nu source text", async (t) => {
  const engine = new NuEngine();
  const query = new TranscriptQuery(engine);
  t.after(() => engine.close());
  const hostile = 'xid-α| error make {msg: "injected"}';
  assert.deepEqual(await query.records(rows, { exchangeId: hostile }), []);
});
