import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

import {
  AdapterEngine,
  AdapterError,
  DEFAULT_ADAPTERS_DIR,
} from "../../para-agent/src/adapters.js";

const TEST_ROOT = path.dirname(fileURLToPath(import.meta.url));
const FIXTURES = path.join(TEST_ROOT, "fixtures", "adapters");
const FAKE_ROOT = path.join(FIXTURES, "fake", "1.0.0");

async function jsonLines(filePath) {
  return (await readFile(filePath, "utf8"))
    .split(/\r?\n/)
    .filter(Boolean)
    .map((line) => ({ line, event: JSON.parse(line) }));
}

function assertAdapterError(error, code) {
  return error instanceof AdapterError && error.code === code;
}

test("ADAPTER-STARTUP-VALIDATES: committed profiles load atomically with explicit status", async () => {
  const engine = await new AdapterEngine().init();
  const byApplication = Object.fromEntries(engine.listProfiles().map((profile) => [profile.application.id, profile]));

  assert.deepEqual(Object.keys(byApplication).sort(), ["agy", "claude", "codex"]);
  assert.equal(byApplication.claude.profile_id, "claude/2.1.226");
  assert.equal(byApplication.codex.profile_id, "codex/0.147.0");
  assert.equal(byApplication.agy.verification.status, "unverified");
  assert.throws(() => engine.getAdapter("agy"), (error) => assertAdapterError(error, "ADAPTER_UNVERIFIED"));
  assert.throws(() => engine.getAdapter("missing"), (error) => assertAdapterError(error, "ADAPTER_UNKNOWN"));
});

test("ADAPTER-VERSION-EXACT: version-labelled profiles reject drift", async () => {
  const engine = await new AdapterEngine().init();

  assert.equal(engine.assertApplicationVersion("claude", "2.1.226").profile_id, "claude/2.1.226");
  assert.equal(engine.assertApplicationVersion("codex", "0.147.0").profile_id, "codex/0.147.0");
  assert.throws(
    () => engine.assertApplicationVersion("claude", "2.1.227"),
    (error) => assertAdapterError(error, "ADAPTER_VERSION_UNSUPPORTED")
  );
});

test("ADAPTER-PROFILE-FAIL-CLOSED: malformed and duplicate profiles prevent initialization", async (t) => {
  const fakeProfile = JSON.parse(await readFile(path.join(FAKE_ROOT, "profile", "fake.json"), "utf8"));

  await t.test("schema-invalid profile", async () => {
    const dir = await mkdtemp(path.join(os.tmpdir(), "para-adapter-invalid-"));
    t.after(() => rm(dir, { recursive: true, force: true }));
    const invalid = structuredClone(fakeProfile);
    delete invalid.terminal_events;
    await writeFile(path.join(dir, "invalid.json"), JSON.stringify(invalid), "utf8");
    await assert.rejects(
      new AdapterEngine({ adaptersDir: dir }).init(),
      (error) => assertAdapterError(error, "ADAPTER_PROFILE_SCHEMA_INVALID")
    );
  });

  await t.test("duplicate application profile", async () => {
    const dir = await mkdtemp(path.join(os.tmpdir(), "para-adapter-duplicate-"));
    t.after(() => rm(dir, { recursive: true, force: true }));
    const duplicate = structuredClone(fakeProfile);
    duplicate.profile_id = "fake-native/duplicate-fixture";
    await Promise.all([
      writeFile(path.join(dir, "a.json"), JSON.stringify(fakeProfile), "utf8"),
      writeFile(path.join(dir, "b.json"), JSON.stringify(duplicate), "utf8"),
    ]);
    await assert.rejects(
      new AdapterEngine({ adaptersDir: dir }).init(),
      (error) => assertAdapterError(error, "ADAPTER_PROFILE_DUPLICATE")
    );
  });
});

test("FAKE-PROMPT-UTF8: structured delivery preserves the exact arbitrary prompt", async () => {
  const engine = await new AdapterEngine({ adaptersDir: path.join(FAKE_ROOT, "profile") }).init();
  const prompt = await readFile(path.join(FAKE_ROOT, "prompt.txt"), "utf8");
  const rendered = engine.renderPrompt("fake-native", {
    prompt,
    exchangeId: "xid-fixture",
    conversationKey: "exclusive:fake-conversation",
  });
  const payload = JSON.parse(rendered.bytes.toString("utf8"));

  assert.equal(payload.prompt, prompt);
  assert.deepEqual(Buffer.from(payload.prompt, "utf8"), Buffer.from(prompt, "utf8"));
  assert.equal(payload.exchange_id, "xid-fixture");
  assert.equal(payload.conversation_key, "exclusive:fake-conversation");
  assert.equal(rendered.receipt.stage, "rendered");
  assert.equal(rendered.receipt.prompt.bytes, Buffer.byteLength(prompt));
  assert.ok(!("emitted" in rendered.receipt), "rendering must not claim transport emission");
});

test("FAKE-NATIVE-CONFORMANCE: correlated projections preserve raw references and terminal authority", async () => {
  const engine = await new AdapterEngine({ adaptersDir: path.join(FAKE_ROOT, "profile") }).init();
  const prompt = await readFile(path.join(FAKE_ROOT, "prompt.txt"), "utf8");
  const rendered = engine.renderPrompt("fake-native", {
    prompt,
    exchangeId: "xid-fixture",
    conversationKey: "exclusive:fake-conversation",
  });
  const rows = await jsonLines(path.join(FAKE_ROOT, "events.jsonl"));
  const projections = rows.map(({ line, event }, frameIndex) => {
    const before = structuredClone(event);
    const projection = engine.projectEvent("fake-native", event, {
      observedAt: `2026-08-14T02:00:0${frameIndex}.000Z`,
      exchangeId: "xid-fixture",
      conversationKey: "exclusive:fake-conversation",
      nativeConversationId: "fake-conversation",
      nativeTurnId: "fake-turn",
      rawRef: { kind: "receiver_native", trace_ref: "traces/fake/xid-fixture.trace", frame_index: frameIndex },
    });
    assert.deepEqual(event, before, "projection must not mutate the raw parsed event");
    assert.deepEqual(projection.source_ref, {
      kind: "receiver_native",
      trace_ref: "traces/fake/xid-fixture.trace",
      frame_index: frameIndex,
    });
    assert.equal(Buffer.from(line, "utf8").toString("utf8"), line, "raw UTF-8 frame remains byte-addressable");
    return projection;
  });

  assert.equal(projections[0].delivery.stage, "receiver_observed");
  assert.equal(projections[0].delivery.prompt.sha256, rendered.receipt.prompt.sha256);
  assert.equal(projections[1].record._type, "thinking");
  assert.equal(projections[1].record.observed_at, "2026-08-14T02:00:01.000Z");
  assert.ok(!("native_timestamp" in projections[1].record), "missing native timestamp remains absent");
  assert.deepEqual(projections.map((value) => value.record?._type).filter(Boolean), [
    "prompt_echo",
    "thinking",
    "tool_call",
    "tool_result",
    "response",
  ]);
  assert.deepEqual(projections.at(-1).provenance.model, {
    id: "opaque/model@fixture",
    display_name: "Fixture Model",
  });

  const resolved = engine.resolveTerminal("fake-native", projections.at(-1), projections);
  assert.deepEqual({ outcome: resolved.outcome, reply: resolved.reply }, {
    outcome: "completed",
    reply: "FAKE_OK 🧪",
  });
});

test("FAKE-CANCEL-SCOPED: cancellation is explicitly turn-scoped and correlated", async () => {
  const engine = await new AdapterEngine({ adaptersDir: path.join(FAKE_ROOT, "profile") }).init();
  const rendered = engine.renderCancellation("fake-native", {
    exchangeId: "xid-fixture",
    conversationKey: "exclusive:fake-conversation",
    turnId: "fake-turn",
  });
  assert.deepEqual(JSON.parse(rendered.bytes.toString("utf8")), {
    type: "turn.cancel",
    exchange_id: "xid-fixture",
    conversation_key: "exclusive:fake-conversation",
    turn_id: "fake-turn",
  });
  assert.equal(rendered.receipt.scope, "turn");
});

test("ADAPTER-UNMAPPED-EXPLICIT: an unknown native event is preserved but never normalized heuristically", async () => {
  const engine = await new AdapterEngine({ adaptersDir: path.join(FAKE_ROOT, "profile") }).init();
  const projection = engine.projectEvent("fake-native", { type: "telemetry.unknown", payload: "opaque" }, {
    observedAt: "2026-08-14T02:01:00.000Z",
    exchangeId: "xid-fixture",
    conversationKey: "exclusive:fake-conversation",
    rawRef: { kind: "receiver_native", trace_ref: "traces/fake/xid-fixture.trace", frame_index: 99 },
  });
  assert.equal(projection.classification, "unmapped");
  assert.equal(projection.record, null);
  assert.equal(projection.terminal, null);
});

test("ADAPTER-CORRELATION-STRICT: mismatched live identifiers reject projection", async () => {
  const engine = await new AdapterEngine({ adaptersDir: path.join(FAKE_ROOT, "profile") }).init();
  const [{ event }] = await jsonLines(path.join(FAKE_ROOT, "events.jsonl"));
  await assert.rejects(async () => engine.projectEvent("fake-native", event, {
    observedAt: "2026-08-14T02:02:00.000Z",
    exchangeId: "different-xid",
    conversationKey: "exclusive:fake-conversation",
    nativeConversationId: "fake-conversation",
    nativeTurnId: "fake-turn",
    rawRef: { kind: "receiver_native", trace_ref: "traces/fake/xid-fixture.trace", frame_index: 0 },
  }), (error) => assertAdapterError(error, "ADAPTER_CORRELATION_MISMATCH"));
});

test("CLAUDE-2.1.226-CONFORMANCE: stdin, live model, terminal result, and omissions remain exact", async () => {
  const engine = await new AdapterEngine().init();
  const metadata = JSON.parse(await readFile(path.join(FIXTURES, "claude", "2.1.226", "metadata.json"), "utf8"));
  const rendered = engine.renderPrompt("claude", {
    prompt: metadata.stdin_prompt,
    exchangeId: "xid-claude",
    conversationKey: "process:claude-probe",
  });
  assert.deepEqual(rendered.bytes, Buffer.from(metadata.stdin_prompt, "utf8"));
  assert.ok(!rendered.command.includes(metadata.stdin_prompt), "prompt must not enter argv");

  const rows = await jsonLines(path.join(FIXTURES, "claude", "2.1.226", "stdout.reduced.jsonl"));
  const projections = rows.map(({ event }, frameIndex) => engine.projectEvent("claude", event, {
    observedAt: `2026-08-14T03:00:0${frameIndex}.000Z`,
    exchangeId: "xid-claude",
    conversationKey: "process:claude-probe",
    nativeConversationId: "0c07bff7-7a08-4247-81bc-401643760e46",
    rawRef: { kind: "receiver_native", trace_ref: "traces/claude/xid-claude.trace", frame_index: frameIndex },
  }));

  assert.deepEqual(projections[0].provenance.application, { id: "claude", version: "2.1.226" });
  assert.deepEqual(projections[1].provenance.model, { id: "claude-opus-5" });
  assert.ok(!("turn_id" in projections[1].native_correlation));
  assert.equal(projections[1].record.text, "PARA_STDIN_OK");
  const resolved = engine.resolveTerminal("claude", projections.at(-1), projections);
  assert.equal(resolved.outcome, "completed");
  assert.equal(resolved.reply, "PARA_STDIN_OK");
  assert.throws(
    () => engine.renderCancellation("claude", { exchangeId: "x", conversationKey: "c", turnId: "t" }),
    (error) => assertAdapterError(error, "ADAPTER_CAPABILITY_UNSUPPORTED")
  );
});

test("CODEX-0.147.0-CONFORMANCE: terminal stream resolves without invented model or turn identity", async () => {
  const engine = await new AdapterEngine().init();
  const metadata = JSON.parse(await readFile(path.join(FIXTURES, "codex", "0.147.0", "metadata.json"), "utf8"));
  const prompt = "Résumé 加算 — exact stdin bytes";
  const rendered = engine.renderPrompt("codex", {
    prompt,
    exchangeId: "xid-codex",
    conversationKey: "process:codex-probe",
  });
  assert.deepEqual(rendered.bytes, Buffer.from(prompt, "utf8"));
  assert.ok(!rendered.command.includes(prompt));

  const rows = await jsonLines(path.join(FIXTURES, "codex", "0.147.0", "stdout.jsonl"));
  const projections = rows.map(({ event }, frameIndex) => engine.projectEvent("codex", event, {
    observedAt: `2026-08-14T04:00:0${frameIndex}.000Z`,
    exchangeId: "xid-codex",
    conversationKey: "process:codex-probe",
    nativeConversationId: "019fff6d-5ddd-77c0-9227-67dc24affe5b",
    rawRef: { kind: "receiver_native", trace_ref: "traces/codex/xid-codex.trace", frame_index: frameIndex },
  }));

  assert.equal(projections[0].native_correlation.conversation_id, "019fff6d-5ddd-77c0-9227-67dc24affe5b");
  assert.equal(projections[1].classification, "unmapped");
  assert.equal(projections[2].record.text, metadata.expected_terminal_reply);
  assert.ok(projections.every((value) => !("model" in value.provenance)), "model stays absent");
  assert.ok(projections.every((value) => !("turn_id" in value.native_correlation)), "native turn ID stays absent");
  const resolved = engine.resolveTerminal("codex", projections.at(-1), projections);
  assert.equal(resolved.outcome, "completed");
  assert.equal(resolved.reply, metadata.expected_terminal_reply);
  assert.throws(
    () => engine.renderCancellation("codex", { exchangeId: "x", conversationKey: "c", turnId: "t" }),
    (error) => assertAdapterError(error, "ADAPTER_CAPABILITY_UNSUPPORTED")
  );
});

test("ADAPTER-DEFAULT-DIRECTORY is the package-owned profile directory", () => {
  assert.equal(path.basename(DEFAULT_ADAPTERS_DIR), "adapters");
});
