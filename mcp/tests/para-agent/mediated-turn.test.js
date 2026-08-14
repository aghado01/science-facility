import test from "node:test";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { AdapterEngine, DEFAULT_ADAPTER_SCHEMA } from "../../para-agent/src/adapters.js";
import { ExchangeAssembler } from "../../para-agent/src/assembler.js";
import { ConversationGate } from "../../para-agent/src/conversation-gate.js";
import { MediatedTurnError, MediatedTurnService } from "../../para-agent/src/mediated-turn.js";
import { assertExchange } from "../../para-agent/src/schema-validation.js";

const here = path.dirname(fileURLToPath(import.meta.url));
const fakeAdapterDir = path.join(here, "fixtures", "adapters", "fake", "1.0.0", "profile");

const digest = (value) => createHash("sha256").update(value).digest("hex");

function testClock() {
  let value = Date.parse("2026-08-14T02:00:00.000Z");
  return () => new Date(value++);
}

async function adapterEngine() {
  return new AdapterEngine({ adaptersDir: fakeAdapterDir, schemaPath: DEFAULT_ADAPTER_SCHEMA }).init();
}

class MemoryStore {
  constructor() {
    this.accepted = [];
    this.acceptanceRows = new Map();
    this.committed = [];
    this.markers = [];
  }

  async acceptExchange(input) {
    this.accepted.push(structuredClone(input));
    const exchangeId = `xid-${this.accepted.length}`;
    const acceptance = {
      record_type: "exchange_acceptance",
      schema_version: 1,
      exchange_id: exchangeId,
      accepted_at: "2026-08-14T02:00:00.000Z",
      ...(input.requestId ? { request_id: input.requestId } : {}),
      sender_participant_id: input.senderParticipantId,
      receiver_participant_id: input.receiverParticipantId,
      conversation_key: input.conversationKey,
      adapter: structuredClone(input.adapter),
      selected_application_id: input.selectedApplicationId,
      prompt: {
        text: input.prompt,
        sha256: digest(Buffer.from(input.prompt, "utf8")),
        bytes: Buffer.byteLength(input.prompt, "utf8"),
        record_id: `prompt-${this.accepted.length}`,
      },
    };
    this.acceptanceRows.set(exchangeId, structuredClone(acceptance));
    return acceptance;
  }

  getRecoveryNotices() {
    return [];
  }

  async commitExchange(payload) {
    this.committed.push(structuredClone(payload));
    const acceptance = this.acceptanceRows.get(payload.exchange_id);
    const exchange = {
      record_type: "transcript_exchange",
      schema_version: 1,
      exchange_index: this.committed.length - 1,
      exchange_start: "2026-08-14T02:00:00.000Z",
      ...(acceptance.request_id ? { request_id: acceptance.request_id } : {}),
      sender_participant_id: acceptance.sender_participant_id,
      receiver_participant_id: acceptance.receiver_participant_id,
      adapter: structuredClone(acceptance.adapter),
      ...structuredClone(payload),
      records: [
        {
          _type: "prompt",
          record_id: acceptance.prompt.record_id,
          observed_at: acceptance.accepted_at,
          text: acceptance.prompt.text,
          content_sha256: acceptance.prompt.sha256,
          source: { kind: "mediation_ingress" },
        },
        ...structuredClone(payload.records),
      ],
    };
    assertExchange(exchange);
    const marker = {
      record_type: "exchange_terminal_marker",
      schema_version: 1,
      exchange_id: exchange.exchange_id,
      exchange_index: exchange.exchange_index,
      terminal_status: exchange.status,
      terminal_at: new Date(Date.parse(exchange.exchange_end) + 1).toISOString(),
      exchange_sha256: digest(Buffer.from(JSON.stringify(exchange), "utf8")),
      writer: { writer_id: "memory-writer", fence: "memory-fence" },
    };
    this.markers.push(structuredClone(marker));
    return {
      exchange: structuredClone(exchange),
      marker: structuredClone(marker),
    };
  }
}

class MemoryTraceSink {
  constructor({ exchangeId, adapter }) {
    this.exchangeId = exchangeId;
    this.adapter = adapter;
    this.frames = [];
    this.malformed = 0;
    this.initialized = false;
    this.finalized = null;
  }

  async init() {
    this.initialized = true;
    return this;
  }

  appendFrame(bytes, { malformed = false } = {}) {
    assert.equal(this.initialized, true);
    const frameIndex = this.frames.length;
    this.frames.push(Buffer.from(bytes));
    if (malformed) this.malformed++;
    return Promise.resolve({
      kind: "receiver_native",
      trace_ref: `traces/test/${this.exchangeId}.trace`,
      frame_index: frameIndex,
    });
  }

  async finalize({ complete, omissions }) {
    const content = Buffer.concat(this.frames);
    this.finalized = {
      complete,
      raw: {
        relative_ref: `traces/test/${this.exchangeId}.trace`,
        sha256: digest(content),
        bytes: content.length,
        format: "jsonl",
        adapter: this.adapter,
        frame_count: this.frames.length,
        malformed_frame_count: this.malformed,
      },
      omissions: structuredClone(omissions),
    };
    return this.finalized;
  }
}

function completedEvents(delivery, {
  model = true,
  terminal = true,
  wrongExchange = false,
  applicationId = "fake-native",
} = {}) {
  const common = {
    exchange_id: delivery.exchange_id,
    conversation_id: delivery.conversation_key,
    turn_id: "native-turn-1",
    application: { id: applicationId, version: "1.0.0-fixture" },
  };
  const events = [
    { ...common, type: "prompt.observed", timestamp: "2026-08-14T02:00:01.000Z", prompt: delivery.prompt },
    { ...common, type: "thinking.delta", text: "live reasoning" },
    {
      ...common,
      type: "assistant.message",
      timestamp: "2026-08-14T02:00:02.000Z",
      ...(model ? { model: { id: "opaque/model-live", display_name: "Live Model" } } : {}),
      text: "receiver reply λ",
    },
  ];
  if (terminal) {
    events.push({
      ...common,
      ...(wrongExchange ? { exchange_id: "xid-wrong" } : {}),
      type: "turn.result",
      timestamp: "2026-08-14T02:00:03.000Z",
      ...(model ? { model: { id: "opaque/model-live", display_name: "Live Model" } } : {}),
      outcome: "ok",
      reply: "receiver reply λ",
    });
  }
  return events;
}

function transportResult(outcome, stdout, overrides = {}) {
  const requested = ["timeout", "cancelled", "write_failed", "max_buffer", "callback_failed"].includes(outcome);
  return {
    ok: outcome === "completed",
    outcome,
    spawned: outcome !== "spawn_failed",
    exitCode: outcome === "nonzero" ? 17 : outcome === "completed" ? 0 : null,
    signal: null,
    error: outcome.endsWith("failed") ? { message: outcome } : null,
    prompt: { writeCompleted: outcome !== "spawn_failed" && outcome !== "write_failed" },
    stdout,
    stderr: Buffer.alloc(0),
    output: { stdoutBytes: stdout.length },
    termination: {
      requested,
      closed: true,
      closedAfterRequest: requested ? true : null,
    },
    ...overrides,
  };
}

class ScenarioNativeClient {
  constructor(handler) {
    this.handler = handler;
    this.calls = [];
  }

  async run(call) {
    this.calls.push(call);
    const result = await this.handler(call);
    if (result.prompt?.writeCompleted) {
      result.prompt.bytes ??= Buffer.byteLength(call.prompt, "utf8");
      result.prompt.writeCompletedAt ??= "2026-08-14T02:00:00.000Z";
    }
    return result;
  }
}

function emitJsonl(call, events, { split = true } = {}) {
  const raw = Buffer.from(`${events.map((event) => JSON.stringify(event)).join("\n")}\n`, "utf8");
  if (split && raw.length > 9) {
    call.onStdout(raw.subarray(0, 7));
    call.onStdout(raw.subarray(7, raw.length - 2));
    call.onStdout(raw.subarray(raw.length - 2));
  } else {
    call.onStdout(raw);
  }
  return raw;
}

async function harness(handler, {
  gate = new ConversationGate(),
  assembler = new ExchangeAssembler(),
  clock = testClock(),
} = {}) {
  const store = new MemoryStore();
  const sinks = [];
  const nativeClient = new ScenarioNativeClient(handler);
  let factoryCalls = 0;
  const service = new MediatedTurnService({
    adapterEngine: await adapterEngine(),
    storeForHandle: async () => store,
    nativeClient,
    assembler,
    gate,
    clock,
    traceSinkFactory: async ({ exchangeId, adapter }) => {
      factoryCalls++;
      const sink = new MemoryTraceSink({ exchangeId, adapter });
      sinks.push(sink);
      return sink;
    },
  });
  return { service, store, sinks, nativeClient, gate, factoryCalls: () => factoryCalls };
}

async function errorOf(promise) {
  try {
    await promise;
    assert.fail("expected delegation to fail");
  } catch (error) {
    return error;
  }
}

test("completed mediation preserves exact prompt, native bytes, source refs, and live provenance", async () => {
  let raw;
  let renderedDelivery;
  const h = await harness(async (call) => {
    renderedDelivery = JSON.parse(call.prompt.trim());
    raw = emitJsonl(call, completedEvents(renderedDelivery));
    return transportResult("completed", raw, {
      prompt: { bytes: Buffer.byteLength(call.prompt), writeCompleted: true },
    });
  });
  const prompt = "Résumé λ\n'$env.HOME'; `literal`\n第二行 👩🏽‍🔬";
  const result = await h.service.delegate({
    handle: "agent-fake:0.0",
    application: "fake-native",
    prompt,
    requestId: "request-1",
  });

  assert.equal(renderedDelivery.prompt, prompt);
  assert.equal(result.reply, "receiver reply λ");
  assert.equal(result.receipt.prompt.sha256, digest(Buffer.from(prompt, "utf8")));
  assert.equal(result.receipt.reply.sha256, digest(Buffer.from(result.reply, "utf8")));
  assert.equal(result.receipt.model.id, "opaque/model-live");
  assert.equal(result.receipt.application.version, "1.0.0-fixture");
  assert.deepEqual(result.receipt.delivery_stages, ["rendered", "adapter_emitted", "receiver_observed"]);
  assert.equal(result.receipt.trace.sha256, digest(raw));
  assert.equal(h.store.accepted[0].prompt, prompt);
  assert.equal(h.store.accepted[0].requestId, "request-1");
  assert.equal(h.store.committed.length, 1);
  assert.equal(h.store.committed[0].status, "completed");
  assert.equal("application_id" in h.store.committed[0].trace.raw, false);
  assert.equal(h.store.committed[0].native.receiver.application_id, "fake-native");
  assert.match(h.store.committed[0].delivery.events.at(-1).evidence.ref, /#frame=0$/);
  assert.equal("egress" in h.store.committed[0].delivery, false);
  assert.equal(result.receipt.egress.stage, "constructed");
  assert.equal(result.receipt.egress.reply_sha256, digest(Buffer.from(result.reply, "utf8")));
  assert.ok(Date.parse(result.receipt.egress.observed_at) >= Date.parse(h.store.committed[0].exchange_end));
  assert.ok(Date.parse(result.receipt.egress.observed_at) >= Date.parse(h.store.markers[0].terminal_at));
  assert.equal(h.store.committed[0].records.filter((record) => record.phase === "final").length, 1);
  assert.ok(h.store.committed[0].records.every((record) => record.source.trace_ref === result.receipt.trace.ref));
});

test("post-commit result construction failure preserves the terminal exchange and releases the lane", async () => {
  const delegate = new ExchangeAssembler();
  const assembler = {
    assembleCommit: (input) => delegate.assembleCommit(input),
    assembleReceipt: (input) => delegate.assembleReceipt(input),
    assembleCompletedResult() {
      throw new Error("synthetic post-commit result construction failure");
    },
  };
  const h = await harness(async (call) => {
    const delivery = JSON.parse(call.prompt.trim());
    return transportResult("completed", emitJsonl(call, completedEvents(delivery)));
  }, { assembler });

  const error = await errorOf(h.service.delegate({
    handle: "agent-egress-failure:0.0",
    application: "fake-native",
    prompt: "work",
  }));
  assert.match(error.message, /post-commit result construction failure/);
  assert.equal(h.store.committed.length, 1);
  assert.equal(h.store.committed[0].status, "completed");
  assert.equal(h.nativeClient.calls.length, 1);
  assert.deepEqual(h.gate.status("fake-native:agent-egress-failure:0.0"), {
    active: false,
    quarantined: null,
  });
});

test("a self-consistent but wrong commit receipt is ambiguous and cannot authorize MCP egress", async () => {
  const h = await harness(async (call) => {
    const delivery = JSON.parse(call.prompt.trim());
    return transportResult("completed", emitJsonl(call, completedEvents(delivery)));
  });
  const commitExchange = h.store.commitExchange.bind(h.store);
  h.store.commitExchange = async (payload) => {
    const result = await commitExchange(payload);
    result.exchange.status = "failed";
    result.exchange.outcome = {
      code: "SYNTHETIC_WRONG_COMMIT",
      message: "the returned exchange differs from the intended completed transaction",
      retryable: false,
      native_stop_confirmed: true,
    };
    result.marker.terminal_status = result.exchange.status;
    result.marker.exchange_sha256 = digest(Buffer.from(JSON.stringify(result.exchange), "utf8"));
    return result;
  };
  const handle = "agent-wrong-commit-receipt:0.0";
  const error = await errorOf(h.service.delegate({
    handle,
    application: "fake-native",
    prompt: "work",
  }));
  assert.equal(error.code, "MEDIATED_COMMIT_FAILED");
  assert.equal(h.store.committed.length, 1);
  assert.equal(h.store.committed[0].status, "completed");
  assert.equal(h.nativeClient.calls.length, 1);
  assert.equal(h.gate.status(`fake-native:${handle}`).quarantined.exchangeId, "xid-1");
});

test("conversation gate rejects concurrent work before a second acceptance", async () => {
  let release;
  let started;
  const began = new Promise((resolve) => { started = resolve; });
  const h = await harness(async (call) => {
    started();
    await new Promise((resolve) => { release = resolve; });
    const delivery = JSON.parse(call.prompt.trim());
    const raw = emitJsonl(call, completedEvents(delivery));
    return transportResult("completed", raw);
  });
  const request = { handle: "agent-busy:0.0", application: "fake-native", prompt: "one" };
  const first = h.service.delegate(request);
  await began;
  const busy = await errorOf(h.service.delegate({ ...request, prompt: "two" }));
  assert.equal(busy.code, "CONVERSATION_BUSY");
  assert.equal(h.store.accepted.length, 1);
  release();
  await first;
});

test("transport outcomes each commit exactly one durable noncompleted exchange", async (t) => {
  for (const [outcome, expectedStatus] of [
    ["spawn_failed", "failed"],
    ["write_failed", "failed"],
    ["nonzero", "failed"],
    ["timeout", "timeout"],
    ["cancelled", "interrupted"],
    ["max_buffer", "failed"],
  ]) {
    await t.test(outcome, async () => {
      const h = await harness(async () => transportResult(outcome, Buffer.alloc(0)));
      const error = await errorOf(h.service.delegate({
        handle: `agent-${outcome}:0.0`,
        application: "fake-native",
        prompt: "work",
      }));
      assert.ok(error instanceof MediatedTurnError);
      assert.equal(error.receipt.status, expectedStatus);
      assert.equal("reply" in error.receipt, false);
      assert.equal(h.store.committed.length, 1);
      assert.equal(h.store.committed[0].status, expectedStatus);
      assert.equal(h.store.committed[0].outcome.native_stop_confirmed, true);
      assert.equal(h.gate.status(`fake-native:agent-${outcome}:0.0`).quarantined, null);
    });
  }
});

test("missing, malformed, and wrongly correlated terminal streams fail closed and terminalize", async (t) => {
  for (const scenario of ["missing", "malformed", "wrong-correlation"]) {
    await t.test(scenario, async () => {
      const h = await harness(async (call) => {
        const delivery = JSON.parse(call.prompt.trim());
        let raw;
        if (scenario === "malformed") {
          raw = Buffer.from('{"type":"turn.result"\n', "utf8");
          call.onStdout(raw);
        } else {
          raw = emitJsonl(call, completedEvents(delivery, {
            terminal: scenario !== "missing",
            wrongExchange: scenario === "wrong-correlation",
          }));
        }
        return transportResult("completed", raw);
      });
      const error = await errorOf(h.service.delegate({
        handle: `agent-${scenario}:0.0`,
        application: "fake-native",
        prompt: "work",
      }));
      assert.ok(error instanceof MediatedTurnError);
      assert.equal(error.receipt.status, "failed");
      assert.equal("reply" in error, false);
      assert.equal("reply" in error.receipt, false);
      assert.equal(h.store.committed.length, 1);
      assert.equal(h.store.committed[0].trace.complete, true);
    });
  }
});

test("model provenance remains absent when no live native event supplies it", async () => {
  const h = await harness(async (call) => {
    const delivery = JSON.parse(call.prompt.trim());
    const raw = emitJsonl(call, completedEvents(delivery, { model: false }));
    return transportResult("completed", raw);
  });
  const result = await h.service.delegate({
    handle: "agent-no-model:0.0",
    application: "fake-native",
    prompt: "work",
  });
  assert.equal("model" in result.receipt, false);
  assert.equal("model" in h.store.committed[0], false);
});

test("preflight failures create no acceptance, trace, or native invocation", async () => {
  const h = await harness(async () => assert.fail("native client must not run"));
  const error = await errorOf(h.service.delegate({
    handle: "agent-preflight:0.0",
    application: "not-registered",
    prompt: "work",
  }));
  assert.equal(error.code, "ADAPTER_UNKNOWN");
  assert.equal(h.store.accepted.length, 0);
  assert.equal(h.factoryCalls(), 0);
  assert.equal(h.nativeClient.calls.length, 0);
});

test("idempotency is not a public delegate field until replay can suppress native side effects", async () => {
  const h = await harness(async () => assert.fail("native client must not run"));
  const error = await errorOf(h.service.delegate({
    handle: "agent-idempotency:0.0",
    application: "fake-native",
    prompt: "work",
    idempotencyKey: "unsafe-public-replay",
  }));
  assert.equal(error.code, "DELEGATE_INVALID_REQUEST");
  assert.equal(h.store.accepted.length, 0);
  assert.equal(h.nativeClient.calls.length, 0);
});

test("completed native exit without stdin-finish evidence cannot become a completed exchange", async () => {
  const h = await harness(async (call) => {
    const delivery = JSON.parse(call.prompt.trim());
    const raw = emitJsonl(call, completedEvents(delivery));
    return transportResult("completed", raw, {
      prompt: { bytes: Buffer.byteLength(call.prompt), writeCompleted: false },
    });
  });
  const error = await errorOf(h.service.delegate({
    handle: "agent-no-emission:0.0",
    application: "fake-native",
    prompt: "work",
  }));
  assert.equal(error.code, "PROMPT_EMISSION_UNCONFIRMED");
  assert.equal(error.receipt.status, "failed");
  assert.equal(h.store.committed[0].trace.complete, true);
  assert.deepEqual(h.store.committed[0].delivery.events.map((event) => event.stage), ["rendered"]);
  assert.equal("application" in h.store.committed[0], false);
  assert.equal("native" in h.store.committed[0], false);
});

test("receiver-native application mismatch terminalizes without laundering selected identity", async () => {
  const h = await harness(async (call) => {
    const delivery = JSON.parse(call.prompt.trim());
    const raw = emitJsonl(call, completedEvents(delivery, { applicationId: "different-native" }));
    return transportResult("completed", raw);
  });
  const error = await errorOf(h.service.delegate({
    handle: "agent-app-mismatch:0.0",
    application: "fake-native",
    prompt: "work",
  }));
  assert.equal(error.code, "ADAPTER_APPLICATION_MISMATCH");
  assert.equal(error.receipt.status, "failed");
  assert.equal(h.store.committed.length, 1);
  assert.equal(h.store.committed[0].trace.complete, true);
  assert.equal("application" in h.store.committed[0], false);
  assert.equal("native" in h.store.committed[0], false);
});

test("pure assembly rejection still yields one minimal durable terminal envelope", async () => {
  const delegate = new ExchangeAssembler();
  let commitCalls = 0;
  const assembler = {
    assembleCommit(input) {
      commitCalls++;
      assert.equal(input.status, "completed");
      throw null;
    },
    assembleReceipt: (input) => delegate.assembleReceipt(input),
    assembleCompletedResult: (input) => delegate.assembleCompletedResult(input),
  };
  const h = await harness(async (call) => {
    const delivery = JSON.parse(call.prompt.trim());
    const raw = emitJsonl(call, completedEvents(delivery));
    return transportResult("completed", raw);
  }, { assembler });
  const error = await errorOf(h.service.delegate({
    handle: "agent-assembly-fallback:0.0",
    application: "fake-native",
    prompt: "work",
  }));
  assert.equal(error.code, "EXCHANGE_ASSEMBLY_FAILED");
  assert.equal(commitCalls, 1, "the injected projector cannot defeat the built-in terminal fallback");
  assert.equal(h.store.committed.length, 1);
  assert.equal(h.store.committed[0].status, "failed");
  assert.equal(h.store.committed[0].trace.complete, false);
  assert.ok(h.store.committed[0].trace.raw, "already-durable raw evidence remains linked");
  assert.equal(h.store.committed[0].trace.omissions[0].code, "EXCHANGE_ASSEMBLY_FAILED");
  assert.equal(typeof h.store.committed[0].outcome.message, "string");
  assert.ok(h.store.committed[0].outcome.message.length > 0);
  assert.equal(h.store.committed[0].records.length, 0);
});

test("a regressed service clock cannot strand a durable acceptance or active lane", async () => {
  const h = await harness(async (call) => {
    const delivery = JSON.parse(call.prompt.trim());
    const raw = emitJsonl(call, completedEvents(delivery));
    return transportResult("completed", raw);
  }, {
    clock: () => new Date("2026-08-13T00:00:00.000Z"),
  });
  const handle = "agent-clock-regression:0.0";
  const error = await errorOf(h.service.delegate({
    handle,
    application: "fake-native",
    prompt: "work",
  }));
  assert.equal(error.code, "EXCHANGE_ASSEMBLY_FAILED");
  assert.equal(h.store.accepted.length, 1);
  assert.equal(h.store.committed.length, 1);
  assert.equal(h.store.committed[0].exchange_end, "2026-08-14T02:00:00.000Z");
  assert.deepEqual(h.gate.status(`fake-native:${handle}`), {
    active: false,
    quarantined: null,
  });
});

test("restart recovery restores durable quarantine before another acceptance", async () => {
  const h = await harness(async (call) => {
    const delivery = JSON.parse(call.prompt.trim());
    const raw = emitJsonl(call, completedEvents(delivery));
    return transportResult("completed", raw);
  });
  const key = "fake-native:agent-recovered:0.0";
  const recovery = {
    exchange_id: "xid-recovered",
    conversation_key: key,
    terminal_status: "interrupted",
    reason: "PROCESS_RESTART_RECOVERY: native stop could not be confirmed across restart",
    observed_at: "2026-08-14T02:00:00.000Z",
    outcome: {
      code: "PROCESS_RESTART_RECOVERY",
      message: "native stop could not be confirmed across restart",
      native_stop_confirmed: false,
    },
  };
  h.store.getRecoveryNotices = () => [recovery];
  const error = await errorOf(h.service.delegate({
    handle: "agent-recovered:0.0",
    application: "fake-native",
    prompt: "work",
  }));
  assert.equal(error.code, "CONVERSATION_QUARANTINED");
  assert.equal(h.store.accepted.length, 0);
  assert.equal(h.nativeClient.calls.length, 0);
  assert.equal(h.gate.status(key).quarantined.exchangeId, "xid-recovered");

  assert.deepEqual(h.gate.reconcile(key, {
    exchangeId: recovery.exchange_id,
    reason: recovery.reason,
    observedAt: recovery.observed_at,
  }), {
    exchangeId: recovery.exchange_id,
    reason: recovery.reason,
    observedAt: recovery.observed_at,
  });
  const result = await h.service.delegate({
    handle: "agent-recovered:0.0",
    application: "fake-native",
    prompt: "work after reconciliation",
  });
  assert.equal(result.reply, "receiver reply λ");
  assert.equal(h.store.accepted.length, 1, "one store generation applies each recovery notice only once");
});

test("ambiguous terminal commit quarantines even after confirmed native close", async () => {
  const h = await harness(async (call) => {
    const delivery = JSON.parse(call.prompt.trim());
    const raw = emitJsonl(call, completedEvents(delivery));
    return transportResult("completed", raw);
  });
  h.store.commitExchange = async () => {
    throw new Error("synthetic durable commit ambiguity");
  };
  const request = {
    handle: "agent-commit-ambiguity:0.0",
    application: "fake-native",
    prompt: "work",
  };
  const first = await errorOf(h.service.delegate(request));
  assert.equal(first.code, "MEDIATED_COMMIT_FAILED");
  const key = "fake-native:agent-commit-ambiguity:0.0";
  assert.equal(h.gate.status(key).quarantined.exchangeId, "xid-1");
  const second = await errorOf(h.service.delegate(request));
  assert.equal(second.code, "CONVERSATION_QUARANTINED");
  assert.equal(h.store.accepted.length, 1);
});

test("unconfirmed native stop quarantines exactly that application-handle lane", async () => {
  const gate = new ConversationGate();
  const h = await harness(async () => transportResult("timeout", Buffer.alloc(0), {
    termination: {
      requested: true,
      closed: false,
      closedAfterRequest: false,
    },
  }), { gate });
  const request = { handle: "agent-quarantine:0.0", application: "fake-native", prompt: "work" };
  const first = await errorOf(h.service.delegate(request));
  assert.equal(first.receipt.status, "timeout");
  assert.deepEqual(gate.status("fake-native:agent-quarantine:0.0").quarantined, {
    exchangeId: "xid-1",
    reason: `${h.store.committed[0].outcome.code}: ${h.store.committed[0].outcome.message}`,
    observedAt: h.store.committed[0].exchange_end,
  });

  const second = await errorOf(h.service.delegate(request));
  assert.equal(second.code, "CONVERSATION_QUARANTINED");
  assert.equal(h.store.accepted.length, 1);
});
