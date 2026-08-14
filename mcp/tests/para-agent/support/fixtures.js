import { sha256Utf8 } from "../../../para-agent/src/schema-validation.js";

export const TEST_ADAPTER = Object.freeze({
  id: "codex-stream",
  version: "1.0.0",
  profile_id: "codex-test-v1",
});

export const TRACE_REF = "traces/test-session/xid-test.trace";

export function validHeader(overrides = {}) {
  return {
    record_type: "transcript_header",
    schema_version: 1,
    transcript_id: "trn-test",
    created_at: "2026-08-14T12:00:00.000Z",
    schemas: {
      header: "urn:science-facility:para-agent:schema:transcript-header:1",
      exchange: "urn:science-facility:para-agent:schema:transcript-exchange:1",
    },
    producer: { name: "para-agent", version: "0.1.0" },
    session: { session_id: "test-session" },
    workspace: { default_root: "D:/workspace", selection_policy: "primary_workspace" },
    participants: [
      { participant_id: "primary", role: "primary" },
      { participant_id: "para", role: "para" },
    ],
    ...overrides,
  };
}

export function rawSource(frameIndex = 0, traceRef = TRACE_REF) {
  return {
    kind: "receiver_native",
    trace_ref: traceRef,
    frame_index: frameIndex,
  };
}

export function rawTrace(traceRef = TRACE_REF) {
  return {
    relative_ref: traceRef,
    sha256: "a".repeat(64),
    bytes: 24,
    format: "test-stream-json",
    application_id: "codex",
    application_version: "0.147.0",
    adapter: { ...TEST_ADAPTER },
    frame_count: 2,
    malformed_frame_count: 0,
  };
}

export function validExchange(overrides = {}) {
  const prompt = "Inspect the proof.";
  const reply = "The proof is sound.";
  return {
    record_type: "transcript_exchange",
    schema_version: 1,
    exchange_id: "xid-test",
    exchange_index: 0,
    exchange_start: "2026-08-14T12:00:00.000Z",
    exchange_end: "2026-08-14T12:00:02.000Z",
    request_id: "request-test",
    sender_participant_id: "primary",
    receiver_participant_id: "para",
    application: {
      id: "codex",
      version: "0.147.0",
      source: rawSource(0),
    },
    adapter: { ...TEST_ADAPTER },
    model: {
      id: "gpt-test",
      display_name: "GPT Test",
      source: rawSource(0),
    },
    native: {
      receiver: {
        application_id: "codex",
        adapter_id: "codex-stream",
        conversation_id: "conversation-test",
        turn_id: "turn-test",
        source: rawSource(0),
      },
    },
    status: "completed",
    trace: {
      complete: true,
      raw: rawTrace(),
      omissions: [],
    },
    delivery: {
      events: [
        {
          stage: "rendered",
          observed_at: "2026-08-14T12:00:00.100Z",
          evidence: { kind: "adapter_receipt", ref: "render-test" },
        },
        {
          stage: "adapter_emitted",
          observed_at: "2026-08-14T12:00:00.200Z",
          evidence: { kind: "adapter_receipt", ref: "emit-test" },
        },
        {
          stage: "receiver_observed",
          observed_at: "2026-08-14T12:00:00.300Z",
          evidence: { kind: "native_event", ref: "frame-0" },
        },
      ],
      egress: {
        stage: "constructed",
        observed_at: "2026-08-14T12:00:02.000Z",
        reply_sha256: sha256Utf8(reply),
      },
    },
    records: [
      {
        _type: "prompt",
        record_id: "rec-prompt",
        observed_at: "2026-08-14T12:00:00.000Z",
        text: prompt,
        content_sha256: sha256Utf8(prompt),
        source: { kind: "mediation_ingress", request_id: "request-test" },
      },
      {
        _type: "response",
        record_id: "rec-response",
        observed_at: "2026-08-14T12:00:01.900Z",
        native_timestamp: "2026-08-14T12:00:01.800Z",
        phase: "final",
        text: reply,
        content_sha256: sha256Utf8(reply),
        source: rawSource(1),
      },
    ],
    ...overrides,
  };
}

export function completedCommit(acceptance, {
  reply = "Completed.",
  traceRef,
  exchangeEnd,
} = {}) {
  const relativeRef = traceRef ?? `traces/test/${acceptance.exchange_id}.trace`;
  const end = exchangeEnd ?? new Date(Date.parse(acceptance.accepted_at) + 1000).toISOString();
  return {
    exchange_id: acceptance.exchange_id,
    status: "completed",
    exchange_end: end,
    application: {
      id: "codex",
      version: "0.147.0",
      source: rawSource(0, relativeRef),
    },
    model: {
      id: "gpt-test",
      source: rawSource(0, relativeRef),
    },
    native: {
      receiver: {
        application_id: "codex",
        adapter_id: TEST_ADAPTER.id,
        conversation_id: acceptance.conversation_key,
        turn_id: `turn-${acceptance.exchange_id}`,
        source: rawSource(0, relativeRef),
      },
    },
    trace: {
      complete: true,
      raw: rawTrace(relativeRef),
      omissions: [],
    },
    delivery: {
      events: [
        {
          stage: "adapter_emitted",
          observed_at: acceptance.accepted_at,
          evidence: { kind: "adapter_receipt", ref: `emit-${acceptance.exchange_id}` },
        },
        {
          stage: "receiver_observed",
          observed_at: new Date(Date.parse(acceptance.accepted_at) + 500).toISOString(),
          evidence: { kind: "native_event", ref: `frame-${acceptance.exchange_id}` },
        },
      ],
      egress: {
        stage: "constructed",
        observed_at: end,
        reply_sha256: sha256Utf8(reply),
      },
    },
    records: [
      {
        _type: "response",
        record_id: `response-${acceptance.exchange_id}`,
        observed_at: new Date(Date.parse(acceptance.accepted_at) + 750).toISOString(),
        phase: "final",
        text: reply,
        content_sha256: sha256Utf8(reply),
        source: rawSource(1, relativeRef),
      },
    ],
  };
}
