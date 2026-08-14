import test from "node:test";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";

import {
  ExchangeAssembler,
  ExchangeAssemblyError,
} from "../../para-agent/src/assembler.js";

const sha256 = (text) => createHash("sha256").update(Buffer.from(text, "utf8")).digest("hex");

const prompt = "Delegate exactly:\nRésumé 加算 🧪\n${not-source}";
const reply = "Receiver says: 完了 ✅";
const traceRef = "traces/session/xid-accepted.trace";

function acceptance() {
  return {
    record_type: "exchange_acceptance",
    schema_version: 1,
    exchange_id: "xid-accepted",
    accepted_at: "2026-08-14T10:00:00.000Z",
    selected_application_id: "claude",
    prompt: {
      text: prompt,
      sha256: sha256(prompt),
      bytes: Buffer.byteLength(prompt, "utf8"),
      record_id: "rec-ingress",
    },
    sender_participant_id: "primary",
    receiver_participant_id: "para",
    conversation_key: "claude:seat-a",
    adapter: { id: "claude-stream", version: "1", profile_id: "claude/2.1.226" },
  };
}

function source(frameIndex) {
  return {
    kind: "receiver_native",
    trace_ref: traceRef,
    frame_index: frameIndex,
  };
}

function finalResponse() {
  return {
    _type: "response",
    record_id: "rec-final",
    observed_at: "2026-08-14T10:00:02.000Z",
    phase: "final",
    text: reply,
    content_sha256: sha256(reply),
    source: source(2),
  };
}

function trace() {
  return {
    complete: true,
    raw: {
      relative_ref: traceRef,
      sha256: sha256("raw native bytes\n"),
      bytes: Buffer.byteLength("raw native bytes\n"),
      format: "jsonl",
      adapter: { id: "claude-stream", version: "1", profile_id: "claude/2.1.226" },
      frame_count: 3,
      malformed_frame_count: 0,
    },
    omissions: [],
  };
}

function completedDelivery() {
  return {
    events: [
      {
        stage: "rendered",
        observed_at: "2026-08-14T10:00:00.100Z",
        evidence: { kind: "adapter_receipt", ref: "adapter:render" },
      },
      {
        stage: "adapter_emitted",
        observed_at: "2026-08-14T10:00:00.200Z",
        evidence: { kind: "adapter_receipt", ref: "transport:stdin" },
      },
    ],
    egress: {
      stage: "constructed",
      observed_at: "2026-08-14T10:00:03.000Z",
      reply_sha256: sha256(reply),
    },
  };
}

function completedCommitInput() {
  return {
    acceptance: acceptance(),
    status: "completed",
    exchangeEnd: "2026-08-14T10:00:03.000Z",
    application: { id: "claude", version: "2.1.226", source: source(0) },
    model: { id: "opaque/model-id", display_name: "Observed Model", source: source(1) },
    native: {
      receiver: {
        application_id: "claude",
        adapter_id: "claude-stream",
        conversation_id: "native-conversation",
        source: source(0),
      },
    },
    trace: trace(),
    delivery: completedDelivery(),
    records: [finalResponse()],
  };
}

function committedExchange(commitInput = completedCommitInput()) {
  const commit = new ExchangeAssembler().assembleCommit(commitInput);
  return {
    record_type: "transcript_exchange",
    schema_version: 1,
    exchange_id: commitInput.acceptance.exchange_id,
    exchange_index: 7,
    exchange_start: commitInput.acceptance.accepted_at,
    exchange_end: commit.exchange_end,
    sender_participant_id: "primary",
    receiver_participant_id: "para",
    adapter: commitInput.acceptance.adapter,
    ...commit,
    records: [
      {
        _type: "prompt",
        record_id: "rec-ingress",
        observed_at: commitInput.acceptance.accepted_at,
        text: prompt,
        content_sha256: sha256(prompt),
        source: { kind: "mediation_ingress" },
      },
      ...commit.records,
    ],
  };
}

function assertAssemblyError(code) {
  return (error) => error instanceof ExchangeAssemblyError && error.code === code;
}

test("ExchangeAssembler is a pure commit projector with no identity, time, store, or model fallback", () => {
  const assembler = new ExchangeAssembler();
  const input = completedCommitInput();
  const before = structuredClone(input);
  const commit = assembler.assembleCommit(input);

  assert.deepEqual(input, before, "assembly must not mutate caller-owned observations");
  assert.notStrictEqual(commit.records, input.records, "assembly returns detached JSON data");
  assert.equal(commit.exchange_id, "xid-accepted", "xid comes only from durable acceptance");
  assert.equal(commit.exchange_end, input.exchangeEnd, "time is supplied, never read internally");
  assert.deepEqual(commit.application, input.application);
  assert.deepEqual(commit.model, input.model);
  assert.deepEqual(commit.records, [finalResponse()]);
  assert.ok(commit.records.every((record) => record._type !== "prompt"), "store retains ingress ownership");

  const failed = assembler.assembleCommit({
    acceptance: acceptance(),
    status: "failed",
    exchangeEnd: "2026-08-14T10:00:01.000Z",
    outcome: {
      code: "NATIVE_TRANSPORT_NONZERO",
      retryable: false,
      native_stop_confirmed: true,
    },
    trace: { complete: false, omissions: [{ code: "NO_STREAM", detail: "No bytes observed." }] },
    delivery: { events: [] },
    records: [],
  });
  assert.ok(!("application" in failed));
  assert.ok(!("model" in failed), "an application name is never substituted for a live model observation");
});

test("completed result exposes the exact receiver reply plus a bounded evidence receipt", () => {
  const assembler = new ExchangeAssembler();
  const accepted = acceptance();
  const exchange = committedExchange();
  const before = structuredClone(exchange);
  const result = assembler.assembleCompletedResult({ acceptance: accepted, exchange });

  assert.equal(result.reply, reply);
  assert.deepEqual(exchange, before, "egress projection must not mutate the committed row");
  assert.deepEqual(result.receipt, {
    exchange_id: "xid-accepted",
    exchange_index: 7,
    status: "completed",
    duration_ms: 3000,
    prompt: { sha256: sha256(prompt), bytes: Buffer.byteLength(prompt, "utf8") },
    application: completedCommitInput().application,
    model: completedCommitInput().model,
    native: completedCommitInput().native,
    trace: {
      complete: true,
      ref: traceRef,
      sha256: sha256("raw native bytes\n"),
      bytes: Buffer.byteLength("raw native bytes\n"),
      frame_count: 3,
      malformed_frame_count: 0,
      omission_codes: [],
    },
    delivery_stages: ["rendered", "adapter_emitted"],
    records_count: 2,
    reply: { sha256: sha256(reply), bytes: Buffer.byteLength(reply, "utf8") },
  });
  assert.ok(!Object.hasOwn(result.receipt, "prompt_text"));
  assert.ok(!Object.hasOwn(result.receipt, "reply_text"));
});

test("non-completed assembly carries a durable receipt but cannot expose a reply", () => {
  const assembler = new ExchangeAssembler();
  const accepted = acceptance();
  const failedInput = {
    acceptance: accepted,
    status: "timeout",
    exchangeEnd: "2026-08-14T10:00:05.000Z",
    outcome: {
      code: "NATIVE_TRANSPORT_TIMEOUT",
      message: "deadline expired",
      retryable: true,
      native_stop_confirmed: false,
    },
    trace: {
      complete: false,
      omissions: [{ code: "TIMEOUT", detail: "Native stream may continue." }],
    },
    delivery: {
      events: [{
        stage: "rendered",
        observed_at: "2026-08-14T10:00:00.100Z",
        evidence: { kind: "adapter_receipt", ref: "adapter:render" },
      }],
    },
    records: [],
  };
  const exchange = committedExchange(failedInput);
  const receipt = assembler.assembleReceipt({ acceptance: accepted, exchange });

  assert.equal(receipt.status, "timeout");
  assert.deepEqual(receipt.outcome, failedInput.outcome);
  assert.ok(!("reply" in receipt));
  assert.throws(
    () => assembler.assembleCompletedResult({ acceptance: accepted, exchange }),
    (error) => {
      assert.equal(assertAssemblyError("ASSEMBLY_NONCOMPLETED_RESULT")(error), true);
      assert.deepEqual(error.receipt, receipt);
      assert.ok(!("reply" in error));
      return true;
    },
  );
});

test("assembly fails closed at authority and terminal-state boundaries", async (t) => {
  const cases = [
    ["store-owned ingress prompt", "ASSEMBLY_INGRESS_OWNERSHIP", (input) => {
      input.records.unshift({ _type: "prompt" });
    }],
    ["missing receiver terminal reply", "ASSEMBLY_TERMINAL_REPLY_REQUIRED", (input) => {
      input.records = [];
    }],
    ["invented terminal reply on failure", "ASSEMBLY_NONCOMPLETED_REPLY", (input) => {
      input.status = "failed";
      input.outcome = { code: "FAILED", retryable: false, native_stop_confirmed: true };
      delete input.delivery.egress;
    }],
    ["model without native source", "ASSEMBLY_PROVENANCE_INVALID", (input) => {
      input.model.source = { kind: "mediation_ingress" };
    }],
    ["selected application mismatch", "ASSEMBLY_APPLICATION_MISMATCH", (input) => {
      input.application.id = "codex";
    }],
    ["completed outcome", "ASSEMBLY_COMPLETED_OUTCOME", (input) => {
      input.outcome = { code: "IMPOSSIBLE", retryable: false, native_stop_confirmed: true };
    }],
    ["completed without raw trace", "ASSEMBLY_TRACE_INVALID", (input) => {
      delete input.trace.raw;
    }],
    ["completed with incomplete raw capture", "ASSEMBLY_TRACE_INVALID", (input) => {
      input.trace.complete = false;
      input.trace.omissions = [{ code: "CAPTURE_GAP", detail: "raw capture did not close" }];
    }],
    ["unacknowledged adapter emission", "ASSEMBLY_DELIVERY_INVALID", (input) => {
      input.delivery.events = input.delivery.events.filter((event) => event.stage !== "adapter_emitted");
    }],
    ["caller-supplied index", "ASSEMBLY_UNKNOWN_FIELD", (input) => {
      input.exchangeIndex = 99;
    }],
  ];

  for (const [name, code, mutate] of cases) {
    await t.test(name, () => {
      const input = completedCommitInput();
      mutate(input);
      assert.throws(() => new ExchangeAssembler().assembleCommit(input), assertAssemblyError(code));
    });
  }
});
