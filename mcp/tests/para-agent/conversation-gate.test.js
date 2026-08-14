import test from "node:test";
import assert from "node:assert/strict";

import { ConversationGate } from "../../para-agent/src/conversation-gate.js";

test("an active lease binds exactly one accepted exchange before quarantine", () => {
  const gate = new ConversationGate();
  const lease = gate.acquire("codex:receiver-1");

  assert.equal(lease.bindExchangeId("xid-accepted-1"), true);
  assert.equal(lease.bindExchangeId("xid-accepted-1"), false);
  assert.throws(
    () => lease.bindExchangeId("xid-conflict"),
    { code: "CONVERSATION_EXCHANGE_CONFLICT" },
  );

  lease.quarantine("native stop is unconfirmed");
  const quarantine = gate.status("codex:receiver-1").quarantined;
  assert.equal(quarantine.exchangeId, "xid-accepted-1");
  assert.equal(quarantine.reason, "native stop is unconfirmed");
  assert.match(quarantine.observedAt, /^\d{4}-\d{2}-\d{2}T/);
  assert.throws(
    () => gate.acquire("codex:receiver-1"),
    (error) => error.code === "CONVERSATION_QUARANTINED"
      && error.details.exchangeId === "xid-accepted-1",
  );
});

test("durable quarantine restoration is idempotent and fails closed on conflicts", () => {
  const gate = new ConversationGate();
  const evidence = {
    exchangeId: "xid-recovered-1",
    reason: "SERVER_RESTART_RECOVERY: native stop was not confirmed",
    observedAt: "2026-08-14T12:00:00.000Z",
  };

  assert.equal(gate.restoreQuarantine("claude:receiver-2", evidence), true);
  assert.equal(gate.restoreQuarantine("claude:receiver-2", evidence), false);
  assert.deepEqual(gate.status("claude:receiver-2").quarantined, evidence);
  assert.throws(
    () => gate.restoreQuarantine("claude:receiver-2", {
      ...evidence,
      exchangeId: "xid-recovered-2",
    }),
    { code: "CONVERSATION_QUARANTINE_CONFLICT" },
  );

  assert.equal(gate.reconcile("claude:receiver-2"), true);
  const active = gate.acquire("claude:receiver-2");
  assert.throws(
    () => gate.restoreQuarantine("claude:receiver-2", evidence),
    { code: "CONVERSATION_BUSY" },
  );
  assert.equal(active.release(), true);
  assert.throws(
    () => active.bindExchangeId("xid-too-late"),
    { code: "CONVERSATION_LEASE_SETTLED" },
  );
});
