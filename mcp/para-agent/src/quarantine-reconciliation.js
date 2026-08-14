const APPLICATION_ID = /^[a-z][a-z0-9_.-]*$/;
const BASIS_KINDS = new Set([
  "terminal_commit_verified",
  "operator_attested_native_stop",
]);

export class QuarantineReconciliationError extends Error {
  constructor(code, message, { details, cause, durableReceipt } = {}) {
    super(message, cause === undefined ? undefined : { cause });
    this.name = "QuarantineReconciliationError";
    this.code = code;
    if (details !== undefined) this.details = details;
    if (durableReceipt !== undefined) this.durableReceipt = durableReceipt;
  }
}

function fail(code, message, details) {
  throw new QuarantineReconciliationError(code, message, { details });
}

function plainObject(value, label) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    fail("QUARANTINE_RECONCILIATION_INVALID", `${label} must be an object`);
  }
  return value;
}

function exactKeys(value, allowed, label) {
  const unknown = Object.keys(value).filter((key) => !allowed.has(key));
  if (unknown.length > 0) {
    fail(
      "QUARANTINE_RECONCILIATION_INVALID",
      `${label} has unsupported fields: ${unknown.join(", ")}`,
    );
  }
}

function nonEmptyString(value, label, { trim = false } = {}) {
  if (typeof value !== "string" || value.length === 0) {
    fail("QUARANTINE_RECONCILIATION_INVALID", `${label} must be a non-empty string`);
  }
  const normalized = trim ? value.trim() : value;
  if (normalized.length === 0) {
    fail("QUARANTINE_RECONCILIATION_INVALID", `${label} must be a non-empty string`);
  }
  return normalized;
}

function dateTime(value, label) {
  const normalized = nonEmptyString(value, label);
  if (!Number.isFinite(Date.parse(normalized))) {
    fail("QUARANTINE_RECONCILIATION_INVALID", `${label} must be an ISO date-time string`);
  }
  return normalized;
}

function targetOf(value) {
  plainObject(value, "request");
  const application = nonEmptyString(value.application, "application", { trim: true });
  if (!APPLICATION_ID.test(application)) {
    fail(
      "QUARANTINE_RECONCILIATION_INVALID",
      "application must be a canonical lowercase application id",
    );
  }
  const handle = nonEmptyString(value.handle, "handle", { trim: true });
  if (/\p{Cc}/u.test(handle)) {
    fail("QUARANTINE_RECONCILIATION_INVALID", "handle cannot contain control characters");
  }
  return { application, handle };
}

function expectedOf(value) {
  plainObject(value, "expected");
  exactKeys(value, new Set(["reason", "observedAt"]), "expected");
  return {
    reason: nonEmptyString(value.reason, "expected.reason"),
    observedAt: dateTime(value.observedAt, "expected.observedAt"),
  };
}

function basisOf(value) {
  plainObject(value, "basis");
  exactKeys(value, new Set(["kind", "evidenceRef"]), "basis");
  const kind = nonEmptyString(value.kind, "basis.kind");
  if (!BASIS_KINDS.has(kind)) {
    fail(
      "QUARANTINE_RECONCILIATION_INVALID",
      `basis.kind '${kind}' is not supported`,
    );
  }
  return {
    kind,
    evidenceRef: nonEmptyString(value.evidenceRef, "basis.evidenceRef"),
  };
}

function clone(value) {
  return structuredClone(value);
}

function validateDurableReceipt(receipt, { conversationKey, exchangeId, expected, basis }) {
  if (!receipt || typeof receipt !== "object" || Array.isArray(receipt)) {
    fail(
      "QUARANTINE_STORE_RECEIPT_INVALID",
      "reconcileQuarantine() did not return a durable reconciliation receipt",
    );
  }
  if (
    receipt.record_type !== "conversation_reconciliation"
    || typeof receipt.reconciliation_id !== "string"
    || receipt.reconciliation_id.length === 0
    || receipt.conversation_key !== conversationKey
    || receipt.exchange_id !== exchangeId
    || receipt.expected?.reason !== expected.reason
    || receipt.expected?.observed_at !== expected.observedAt
    || receipt.basis?.kind !== basis.kind
    || receipt.basis?.evidence_ref !== basis.evidenceRef
  ) {
    fail(
      "QUARANTINE_STORE_RECEIPT_INVALID",
      "durable reconciliation receipt does not bind the exact requested quarantine and evidence",
    );
  }
  return receipt;
}

export function deriveConversationKey({ application, handle }) {
  const target = targetOf({ application, handle });
  return `${target.application}:${target.handle}`;
}

/**
 * Platform-neutral, offline-only administrative boundary for quarantine
 * reconciliation. The normal writable server must be stopped before the
 * injected store can acquire its writer lease. That durable store is the sole
 * compare-and-set, evidence, and idempotency authority; no process-local gate
 * participates in this operation.
 */
export class QuarantineReconciliationService {
  constructor({ storeForHandle, gate } = {}) {
    if (typeof storeForHandle !== "function") {
      throw new TypeError("storeForHandle must be a function");
    }
    if (gate !== null) {
      throw new TypeError("gate must be explicitly null for offline quarantine administration");
    }
    this.storeForHandle = storeForHandle;
  }

  status(request) {
    exactKeys(plainObject(request, "request"), new Set(["application", "handle"]), "request");
    const { application, handle } = targetOf(request);
    const conversationKey = deriveConversationKey({ application, handle });
    return {
      application,
      handle,
      conversationKey,
      gate: { attached: false },
    };
  }

  async reconcile(request) {
    exactKeys(
      plainObject(request, "request"),
      new Set(["application", "handle", "exchangeId", "expected", "basis"]),
      "request",
    );
    const { application, handle } = targetOf(request);
    const conversationKey = deriveConversationKey({ application, handle });
    const exchangeId = nonEmptyString(request.exchangeId, "exchangeId");
    const expected = expectedOf(request.expected);
    const basis = basisOf(request.basis);

    const store = await this.storeForHandle(handle);
    if (!store || typeof store.reconcileQuarantine !== "function") {
      throw new QuarantineReconciliationError(
        "QUARANTINE_STORE_INVALID",
        "storeForHandle returned a store without reconcileQuarantine()",
      );
    }

    const durableReceipt = validateDurableReceipt(await store.reconcileQuarantine({
      conversationKey,
      exchangeId,
      expected,
      basis,
    }), { conversationKey, exchangeId, expected, basis });

    return {
      conversationKey,
      exchangeId,
      durable: clone(durableReceipt),
      gate: {
        attached: false,
        cleared: false,
      },
    };
  }
}
