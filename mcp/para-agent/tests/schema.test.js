import test from "node:test";
import assert from "node:assert/strict";

import {
  PersistedValidationError,
  assertAcceptanceWalRow,
  assertExchange,
  assertHeader,
  describeRawTrace,
  sha256Utf8,
  validateExchangeSchema,
  validateHeaderSchema,
} from "../../para-agent/src/schema-validation.js";
import { TEST_ADAPTER, validExchange, validHeader } from "./support/fixtures.js";

test("JSON Schema 2020-12 validators compile in strict mode and accept canonical fixtures", () => {
  const header = validHeader();
  const exchange = validExchange();
  assert.equal(validateHeaderSchema(header), true, JSON.stringify(validateHeaderSchema.errors));
  assert.equal(validateExchangeSchema(exchange), true, JSON.stringify(validateExchangeSchema.errors));
  assert.equal(assertHeader(header), header);
  assert.equal(assertExchange(exchange, header), exchange);
});

test("closed allOf record variants reject undeclared properties without rejecting base properties", () => {
  const exchange = validExchange();
  exchange.records[1].undeclared = true;
  assert.equal(validateExchangeSchema(exchange), false);
  assert.ok(validateExchangeSchema.errors.some((error) => error.keyword === "unevaluatedProperties"));
});

test("semantic validation rejects duplicate participant identities", () => {
  const header = validHeader({
    participants: [
      { participant_id: "same", role: "primary" },
      { participant_id: "same", role: "para" },
    ],
  });
  assert.throws(
    () => assertHeader(header),
    (error) => error instanceof PersistedValidationError && error.code === "HEADER_PARTICIPANT_DUPLICATE",
  );
});

test("semantic validation rejects fabricated or mismatched prompt and model provenance", () => {
  const badPrompt = validExchange();
  badPrompt.records[0].content_sha256 = "0".repeat(64);
  assert.throws(() => assertExchange(badPrompt, validHeader()), { code: "EXCHANGE_PROMPT_DIGEST" });

  const badModel = validExchange();
  badModel.model.source.trace_ref = "traces/another.trace";
  assert.throws(() => assertExchange(badModel, validHeader()), { code: "EXCHANGE_SOURCE_TRACE_MISMATCH" });
});

test("incomplete traces disclose omissions and persisted schema rejects return-only egress", () => {
  const incomplete = validExchange({
    status: "failed",
    outcome: { code: "CLIENT_FAILED", retryable: true, native_stop_confirmed: true },
    trace: { complete: false, omissions: [] },
    delivery: { events: [] },
    records: [validExchange().records[0]],
  });
  assert.throws(() => assertExchange(incomplete, validHeader()), { code: "EXCHANGE_TRACE_OMISSION_REQUIRED" });

  const legacyEgress = validExchange();
  legacyEgress.delivery.egress = {
    stage: "constructed",
    observed_at: legacyEgress.exchange_end,
    reply_sha256: legacyEgress.records.at(-1).content_sha256,
  };
  assert.equal(validateExchangeSchema(legacyEgress), false);
  assert.ok(validateExchangeSchema.errors.some((error) => (
    error.keyword === "additionalProperties"
      && error.instancePath === "/delivery"
      && error.params.additionalProperty === "egress"
  )));
  assert.throws(() => assertExchange(legacyEgress, validHeader()), { code: "EXCHANGE_SCHEMA_INVALID" });
});

test("acceptance WAL validation binds prompt digest and byte count", () => {
  const prompt = "Unicode prompt: λ";
  const row = {
    record_type: "exchange_acceptance",
    schema_version: 1,
    exchange_id: "xid-test",
    accepted_at: "2026-08-14T12:00:00.000Z",
    prompt: {
      text: prompt,
      sha256: sha256Utf8(prompt),
      bytes: Buffer.byteLength(prompt, "utf8"),
      record_id: "rec-test",
    },
    sender_participant_id: "primary",
    receiver_participant_id: "para",
    conversation_key: "conversation-test",
    adapter: { ...TEST_ADAPTER },
    writer: { writer_id: "writer-test", fence: "fence-test" },
  };
  assert.equal(assertAcceptanceWalRow(row), row);
  row.prompt.bytes -= 1;
  assert.throws(() => assertAcceptanceWalRow(row), { code: "ACCEPTANCE_PROMPT_BYTES" });
});

test("raw trace descriptors derive exact byte digests and reject unsafe references", () => {
  const content = Buffer.from("native\u0000bytes", "utf8");
  const descriptor = describeRawTrace({
    relativeRef: "traces/session/xid.trace",
    content,
    format: "stream-json",
    adapter: { ...TEST_ADAPTER },
  });
  assert.equal(descriptor.bytes, content.length);
  assert.equal(descriptor.sha256, sha256Utf8(content.toString("utf8")));
  assert.throws(
    () => describeRawTrace({ relativeRef: "../escape", content, format: "stream-json", adapter: TEST_ADAPTER }),
    { code: "RAW_TRACE_REF_UNSAFE" },
  );
});
