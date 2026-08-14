import test from "node:test";
import assert from "node:assert/strict";

import {
  QuarantineReconciliationService,
  deriveConversationKey,
} from "../../para-agent/src/quarantine-reconciliation.js";

const TARGET = {
  application: "claude",
  handle: "agent-receiver:0.0",
};
const KEY = "claude:agent-receiver:0.0";
const EVIDENCE = {
  exchangeId: "xid-quarantined-1",
  reason: "SERVER_RESTART_RECOVERY: native stop was not confirmed",
  observedAt: "2026-08-14T12:00:00.000Z",
};
const BASIS = {
  kind: "operator_attested_native_stop",
  evidenceRef: "operator-log:stop-confirmation-1",
};

function request(overrides = {}) {
  return {
    ...TARGET,
    exchangeId: EVIDENCE.exchangeId,
    expected: {
      reason: EVIDENCE.reason,
      observedAt: EVIDENCE.observedAt,
    },
    basis: BASIS,
    ...overrides,
  };
}

function receipt(reconciliationId) {
  return {
    record_type: "conversation_reconciliation",
    reconciliation_id: reconciliationId,
    conversation_key: KEY,
    exchange_id: EVIDENCE.exchangeId,
    expected: {
      reason: EVIDENCE.reason,
      observed_at: EVIDENCE.observedAt,
    },
    basis: {
      kind: BASIS.kind,
      evidence_ref: BASIS.evidenceRef,
    },
  };
}

function serviceWith(reconcileQuarantine) {
  const store = { reconcileQuarantine };
  return new QuarantineReconciliationService({
    gate: null,
    storeForHandle: async (handle) => {
      assert.equal(handle, TARGET.handle);
      return store;
    },
  });
}

test("offline quarantine status derives the internal key without attaching a live gate", () => {
  const service = serviceWith(async () => assert.fail("read-only status must not mutate the store"));

  assert.equal(deriveConversationKey(TARGET), KEY);
  const first = service.status(TARGET);
  assert.deepEqual(first, {
    ...TARGET,
    conversationKey: KEY,
    gate: { attached: false },
  });
  first.gate.attached = true;
  assert.deepEqual(service.status(TARGET), {
    ...TARGET,
    conversationKey: KEY,
    gate: { attached: false },
  });
});

test("conversation-key derivation rejects noncanonical target aliases", () => {
  for (const target of [
    { ...TARGET, application: ` ${TARGET.application}` },
    { ...TARGET, application: `${TARGET.application} ` },
    { ...TARGET, handle: ` ${TARGET.handle}` },
    { ...TARGET, handle: `${TARGET.handle} ` },
    { ...TARGET, application: `${TARGET.application}\ud800` },
    { ...TARGET, handle: `${TARGET.handle}\ud801` },
  ]) {
    assert.throws(
      () => deriveConversationKey(target),
      { code: "QUARANTINE_RECONCILIATION_INVALID" },
    );
  }
});

test("offline reconciliation delegates exact CAS and repeated retries to the durable store", async () => {
  const calls = [];
  const durableReceipt = receipt("reconcile-1");
  const service = serviceWith(async (input) => {
    calls.push(structuredClone(input));
    return durableReceipt;
  });

  const first = await service.reconcile(request());
  const second = await service.reconcile(request());
  const expectedStoreInput = {
    conversationKey: KEY,
    exchangeId: EVIDENCE.exchangeId,
    expected: {
      reason: EVIDENCE.reason,
      observedAt: EVIDENCE.observedAt,
    },
    basis: BASIS,
  };
  assert.deepEqual(calls, [expectedStoreInput, expectedStoreInput]);
  assert.deepEqual(first, {
    conversationKey: KEY,
    exchangeId: EVIDENCE.exchangeId,
    durable: durableReceipt,
    gate: { attached: false, cleared: false },
  });
  assert.deepEqual(second, first);
  assert.notStrictEqual(first.durable, durableReceipt, "the service returns detached durable evidence");
});

test("offline reconciliation propagates durable-store CAS failure", async () => {
  const failure = new Error("synthetic durable compare-and-set failure");
  const service = serviceWith(async () => { throw failure; });
  await assert.rejects(() => service.reconcile(request()), failure);
});

test("offline reconciliation rejects a store receipt that is not exactly bound", async () => {
  const service = serviceWith(async () => ({
    ...receipt("reconcile-wrong-binding"),
    exchange_id: "xid-different",
  }));

  await assert.rejects(
    () => service.reconcile(request()),
    { code: "QUARANTINE_STORE_RECEIPT_INVALID" },
  );
});

test("the reconciliation service rejects every live-gate configuration", () => {
  const storeForHandle = async () => ({ reconcileQuarantine: async () => receipt("unused") });
  assert.throws(
    () => new QuarantineReconciliationService({ storeForHandle }),
    /gate must be explicitly null/,
  );
  assert.throws(
    () => new QuarantineReconciliationService({ gate: {}, storeForHandle }),
    /gate must be explicitly null/,
  );
  assert.throws(
    () => new QuarantineReconciliationService({
      gate: { status() {}, assertReconciliation() {}, reconcile() {} },
      storeForHandle,
    }),
    /gate must be explicitly null/,
  );
});

test("invalid and force-like requests fail before durable-store access", async (t) => {
  let storeCalls = 0;
  const service = new QuarantineReconciliationService({
    gate: null,
    storeForHandle: async () => {
      storeCalls++;
      return { reconcileQuarantine: async () => receipt("must-not-run") };
    },
  });

  const cases = [
    ["force field", { ...request(), force: true }],
    ["noncanonical application", { ...request(), application: "Claude Desktop" }],
    ["leading application whitespace", { ...request(), application: ` ${TARGET.application}` }],
    ["trailing application whitespace", { ...request(), application: `${TARGET.application} ` }],
    ["leading handle whitespace", { ...request(), handle: ` ${TARGET.handle}` }],
    ["trailing handle whitespace", { ...request(), handle: `${TARGET.handle} ` }],
    ["missing expected tuple", { ...request(), expected: undefined }],
    ["unsupported basis", { ...request(), basis: { ...BASIS, kind: "force" } }],
  ];
  for (const [name, candidate] of cases) {
    await t.test(name, async () => {
      await assert.rejects(
        () => service.reconcile(candidate),
        { code: "QUARANTINE_RECONCILIATION_INVALID" },
      );
    });
  }
  assert.equal(storeCalls, 0);
});
