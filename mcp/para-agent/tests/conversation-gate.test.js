import test from "node:test";
import assert from "node:assert/strict";

import { ConversationGate } from "../src/conversation-gate.js";

test("conversation keys reject noncanonical aliases instead of trimming them", () => {
  const gate = new ConversationGate();
  for (const key of [" claude:receiver", "claude:receiver ", "claude:receiver\ud800", "", null, 7]) {
    assert.throws(
      () => gate.acquire(key),
      (error) => new Set(["CONVERSATION_KEY_INVALID", "CONVERSATION_KEY_REQUIRED"]).has(error.code),
    );
  }
  assert.deepEqual(gate.status("claude:receiver"), { active: false, quarantined: null });
});

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

test("durable quarantine restoration and status are idempotent snapshots", () => {
  const gate = new ConversationGate();
  const evidence = {
    exchangeId: "xid-recovered-1",
    reason: "SERVER_RESTART_RECOVERY: native stop was not confirmed",
    observedAt: "2026-08-14T12:00:00.000Z",
  };

  assert.equal(gate.restoreQuarantine("claude:receiver-2", evidence), true);
  assert.equal(gate.restoreQuarantine("claude:receiver-2", evidence), false);
  const first = gate.status("claude:receiver-2");
  const second = gate.status("claude:receiver-2");
  assert.deepEqual(first, second);
  assert.deepEqual(first.quarantined, evidence);
  first.quarantined.reason = "caller mutation must not alter the gate";
  assert.deepEqual(gate.status("claude:receiver-2").quarantined, evidence);
  assert.throws(
    () => gate.restoreQuarantine("claude:receiver-2", {
      ...evidence,
      exchangeId: "xid-recovered-2",
    }),
    { code: "CONVERSATION_QUARANTINE_CONFLICT" },
  );
});

test("reconciliation compare-and-clear requires the exact current quarantine tuple", () => {
  const gate = new ConversationGate();
  const key = "claude:receiver-2";
  const evidence = {
    exchangeId: "xid-recovered-1",
    reason: "SERVER_RESTART_RECOVERY: native stop was not confirmed",
    observedAt: "2026-08-14T12:00:00.000Z",
  };
  gate.restoreQuarantine(key, evidence);

  for (const stale of [
    { ...evidence, exchangeId: "xid-stale" },
    { ...evidence, reason: "stale reason" },
    { ...evidence, observedAt: "2026-08-14T12:00:01.000Z" },
  ]) {
    assert.throws(
      () => gate.reconcile(key, stale),
      (error) => error.code === "CONVERSATION_QUARANTINE_STALE"
        && error.details.actual.exchangeId === evidence.exchangeId,
    );
    assert.deepEqual(gate.status(key).quarantined, evidence);
  }
  assert.throws(
    () => gate.reconcile(key, { ...evidence, force: true }),
    { code: "CONVERSATION_GATE_ARGUMENT_INVALID" },
  );

  assert.deepEqual(gate.reconcile(key, evidence), evidence);
  assert.deepEqual(gate.status(key), { active: false, quarantined: null });
  assert.throws(
    () => gate.reconcile(key, evidence),
    { code: "CONVERSATION_QUARANTINE_NOT_FOUND" },
  );
});

test("reconciliation refuses an active lane before considering missing quarantine", () => {
  const gate = new ConversationGate();
  const key = "claude:receiver-active";
  const evidence = {
    exchangeId: "xid-not-current",
    reason: "not current",
    observedAt: "2026-08-14T12:00:00.000Z",
  };
  const active = gate.acquire(key);

  assert.throws(
    () => gate.reconcile(key, evidence),
    { code: "CONVERSATION_BUSY" },
  );
  assert.equal(active.release(), true);
  assert.throws(
    () => active.bindExchangeId("xid-too-late"),
    { code: "CONVERSATION_LEASE_SETTLED" },
  );
});
