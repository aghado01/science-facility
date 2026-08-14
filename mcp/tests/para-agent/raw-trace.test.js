import test from "node:test";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";

import { RawTraceError, RawTraceSink } from "../../para-agent/src/raw-trace.js";

const EMPTY_SHA256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";

function digest(buffer) {
  return createHash("sha256").update(buffer).digest("hex");
}

function isRawTraceError(error, code) {
  return error instanceof RawTraceError && error.code === code;
}

async function fixture(t, overrides = {}) {
  const root = await mkdtemp(path.join(os.tmpdir(), "para-raw-trace-"));
  t.after(() => rm(root, { recursive: true, force: true }));
  const options = {
    traceDir: path.join(root, "traces"),
    sessionKey: "session-a1b2c3",
    exchangeId: "xid-001",
    format: "jsonl",
    adapter: { id: "para-agent.fake", version: "1.0.0", profile_id: "fake/1.0.0" },
    application: { id: "fake", version: "1.0.0" },
    ...overrides,
  };
  const sink = await new RawTraceSink(options).init();
  return {
    root,
    sink,
    options,
    filePath: path.join(options.traceDir, options.sessionKey, `${options.exchangeId}.trace`),
  };
}

test("RAW-TRACE-EMPTY: an empty trace finalizes durably with the empty digest", async (t) => {
  const { sink, filePath } = await fixture(t);
  const descriptor = await sink.finalize();

  assert.deepEqual(descriptor, {
    complete: true,
    raw: {
      relative_ref: "traces/session-a1b2c3/xid-001.trace",
      sha256: EMPTY_SHA256,
      bytes: 0,
      format: "jsonl",
      adapter: { id: "para-agent.fake", version: "1.0.0", profile_id: "fake/1.0.0" },
      frame_count: 0,
      malformed_frame_count: 0,
      application_id: "fake",
      application_version: "1.0.0",
    },
    omissions: [],
  });
  assert.deepEqual(await readFile(filePath), Buffer.alloc(0));
});

test("RAW-TRACE-EXACT: binary and Unicode bytes, source refs, counts, and digest are exact", async (t) => {
  const { sink, filePath } = await fixture(t);
  const binary = Buffer.from([0x00, 0xff, 0x01, 0x7f]);
  const unicode = Buffer.from("Résumé α/β 加算 🧪\n", "utf8");
  const invalidJson = Buffer.from("{'not':'json'}\n", "utf8");

  const byteRef = await sink.appendBytes(binary);
  const frameRef = await sink.appendFrame(unicode, { nativeEventId: "native-message-1" });
  const malformedRef = await sink.appendFrame(invalidJson, { malformed: true });
  const expected = Buffer.concat([binary, unicode, invalidJson]);
  const descriptor = await sink.finalize({
    complete: true,
    omissions: [{ code: "MALFORMED_NATIVE_FRAME", detail: "Frame 1 was retained byte-for-byte but not normalized." }],
  });

  assert.deepEqual(byteRef, {
    kind: "receiver_native",
    trace_ref: "traces/session-a1b2c3/xid-001.trace",
    byte_span: { start: 0, length: binary.length },
  });
  assert.deepEqual(frameRef, {
    kind: "receiver_native",
    trace_ref: "traces/session-a1b2c3/xid-001.trace",
    frame_index: 0,
    native_event_id: "native-message-1",
  });
  assert.equal(malformedRef.frame_index, 1);
  assert.deepEqual(await readFile(filePath), expected);
  assert.equal(descriptor.raw.bytes, expected.length);
  assert.equal(descriptor.raw.sha256, digest(expected));
  assert.equal(descriptor.raw.frame_count, 2);
  assert.equal(descriptor.raw.malformed_frame_count, 1);
});

test("RAW-TRACE-SERIALIZED: concurrent appends preserve invocation order and copied bytes", async (t) => {
  const { sink, filePath } = await fixture(t, { format: "opaque-binary" });
  const inputs = Array.from({ length: 128 }, (_, index) => Buffer.from(`[${String(index).padStart(3, "0")}]加算`, "utf8"));
  const snapshots = inputs.map((buffer) => Buffer.from(buffer));
  const writes = inputs.map((buffer) => sink.appendBytes(buffer));

  for (const buffer of inputs) buffer.fill(0x78);
  const refs = await Promise.all(writes);
  const descriptor = await sink.finalize();
  const expected = Buffer.concat(snapshots);

  assert.deepEqual(await readFile(filePath), expected);
  assert.equal(descriptor.raw.sha256, digest(expected));
  let offset = 0;
  for (let index = 0; index < refs.length; index++) {
    assert.deepEqual(refs[index].byte_span, { start: offset, length: snapshots[index].length });
    offset += snapshots[index].length;
  }
});

test("RAW-TRACE-FINALIZE-QUEUES: finalize waits for already accepted concurrent frames", async (t) => {
  const { sink, filePath } = await fixture(t);
  const frames = Array.from({ length: 32 }, (_, index) => Buffer.from(`frame-${index}\n`, "utf8"));
  const writes = frames.map((frame) => sink.appendFrame(frame));
  const finalized = sink.finalize();

  assert.throws(
    () => sink.appendFrame(Buffer.from("late")),
    (error) => isRawTraceError(error, "RAW_TRACE_ALREADY_FINALIZED")
  );
  const [refs, descriptor] = await Promise.all([Promise.all(writes), finalized]);
  assert.deepEqual(refs.map((ref) => ref.frame_index), Array.from({ length: 32 }, (_, index) => index));
  assert.equal(descriptor.raw.frame_count, 32);
  assert.deepEqual(await readFile(filePath), Buffer.concat(frames));
});

test("RAW-TRACE-IMMUTABLE: descriptors and source refs freeze, and finalization is one-way", async (t) => {
  const { sink, filePath } = await fixture(t);
  const source = await sink.appendFrame(Buffer.from("one\n"));
  const descriptor = await sink.finalize();
  const before = await readFile(filePath);

  assert.ok(Object.isFrozen(source));
  assert.ok(Object.isFrozen(descriptor));
  assert.ok(Object.isFrozen(descriptor.raw));
  assert.ok(Object.isFrozen(descriptor.raw.adapter));
  assert.ok(Object.isFrozen(descriptor.omissions));
  assert.throws(
    () => sink.appendBytes(Buffer.from("two")),
    (error) => isRawTraceError(error, "RAW_TRACE_ALREADY_FINALIZED")
  );
  assert.throws(
    () => sink.finalize(),
    (error) => isRawTraceError(error, "RAW_TRACE_ALREADY_FINALIZED")
  );
  assert.deepEqual(await readFile(filePath), before);
});

test("RAW-TRACE-WX: an existing trace is never overwritten or appended", async (t) => {
  const root = await mkdtemp(path.join(os.tmpdir(), "para-raw-trace-wx-"));
  t.after(() => rm(root, { recursive: true, force: true }));
  const options = {
    traceDir: path.join(root, "traces"),
    sessionKey: "session-safe",
    exchangeId: "xid-safe",
    format: "jsonl",
    adapter: { id: "adapter", version: "1" },
  };
  const first = await new RawTraceSink(options).init();
  await first.appendBytes(Buffer.from("original"));
  await first.finalize();
  const filePath = path.join(options.traceDir, options.sessionKey, "xid-safe.trace");
  const before = await readFile(filePath);

  await assert.rejects(
    new RawTraceSink(options).init(),
    (error) => isRawTraceError(error, "RAW_TRACE_EXISTS")
  );
  assert.deepEqual(await readFile(filePath), before);
});

test("RAW-TRACE-PATH-SAFETY: unsafe identifiers and ambiguous directories fail before writes", async () => {
  const absolute = path.join(os.tmpdir(), "para-raw-safe-root");
  const base = {
    traceDir: absolute,
    sessionKey: "session-safe",
    exchangeId: "xid-safe",
    format: "jsonl",
    adapter: { id: "adapter", version: "1" },
  };
  for (const unsafe of ["", ".", "..", "../escape", "..\\escape", "/absolute", "C:escape", "CON", "LPT1.txt", "trailing."]) {
    assert.throws(
      () => new RawTraceSink({ ...base, exchangeId: unsafe }),
      (error) => isRawTraceError(error, unsafe === "" ? "RAW_TRACE_ARGUMENT_INVALID" : "RAW_TRACE_ID_UNSAFE"),
      unsafe
    );
  }
  assert.throws(
    () => new RawTraceSink({ ...base, sessionKey: "../escape" }),
    (error) => isRawTraceError(error, "RAW_TRACE_ID_UNSAFE")
  );
  assert.throws(
    () => new RawTraceSink({ ...base, traceDir: "relative/traces" }),
    (error) => isRawTraceError(error, "RAW_TRACE_DIRECTORY_INVALID")
  );
});

test("RAW-TRACE-BUFFER-ONLY: no string or typed-array coercion enters evidence", async (t) => {
  const { sink } = await fixture(t);
  assert.throws(
    () => sink.appendBytes("text"),
    (error) => isRawTraceError(error, "RAW_TRACE_BUFFER_REQUIRED")
  );
  assert.throws(
    () => sink.appendFrame(new Uint8Array([1, 2, 3])),
    (error) => isRawTraceError(error, "RAW_TRACE_BUFFER_REQUIRED")
  );
  assert.throws(
    () => sink.appendBytes(Buffer.alloc(0)),
    (error) => isRawTraceError(error, "RAW_TRACE_EMPTY_SPAN")
  );
  await sink.finalize();
});

test("RAW-TRACE-INCOMPLETE: incomplete capture requires explicit omissions", async (t) => {
  const { sink } = await fixture(t);
  assert.throws(
    () => sink.finalize({ complete: false }),
    (error) => isRawTraceError(error, "RAW_TRACE_OMISSIONS_REQUIRED")
  );
  const descriptor = await sink.finalize({
    complete: false,
    omissions: [{ code: "CANCEL_UNCONFIRMED", detail: "The receiver stop could not be observed." }],
  });
  assert.equal(descriptor.complete, false);
  assert.deepEqual(descriptor.omissions, [
    { code: "CANCEL_UNCONFIRMED", detail: "The receiver stop could not be observed." },
  ]);
});

test("RAW-TRACE-STATE: writes before initialization are rejected", () => {
  const sink = new RawTraceSink({
    traceDir: path.join(os.tmpdir(), "para-raw-state"),
    sessionKey: "session-safe",
    exchangeId: "xid-safe",
    format: "jsonl",
    adapter: { id: "adapter", version: "1" },
  });
  assert.throws(
    () => sink.appendFrame(Buffer.from("frame")),
    (error) => isRawTraceError(error, "RAW_TRACE_STATE_INVALID")
  );
});
