import { isWellFormedUnicode } from "./identity.js";

export class ConversationGateError extends Error {
  constructor(code, message, details = {}) {
    super(message);
    this.name = "ConversationGateError";
    this.code = code;
    this.details = details;
  }
}

function conversationKeyOf(value) {
  if (typeof value !== "string" || value.length === 0) {
    throw new ConversationGateError(
      "CONVERSATION_KEY_REQUIRED",
      "the adapter must provide a stable conversation key before acceptance",
    );
  }
  if (value !== value.trim()) {
    throw new ConversationGateError(
      "CONVERSATION_KEY_INVALID",
      "conversation key must not contain leading or trailing whitespace",
    );
  }
  if (!isWellFormedUnicode(value)) {
    throw new ConversationGateError(
      "CONVERSATION_KEY_INVALID",
      "conversation key must be well-formed Unicode",
    );
  }
  return value;
}

function nonEmptyString(value, label) {
  if (typeof value !== "string" || value.length === 0) {
    throw new ConversationGateError(
      "CONVERSATION_GATE_ARGUMENT_INVALID",
      `${label} must be a non-empty string`,
    );
  }
  return value;
}

function observedAtOf(value) {
  const observedAt = value ?? new Date().toISOString();
  if (typeof observedAt !== "string" || !Number.isFinite(Date.parse(observedAt))) {
    throw new ConversationGateError(
      "CONVERSATION_GATE_ARGUMENT_INVALID",
      "observedAt must be an ISO date-time string",
    );
  }
  return observedAt;
}

function reconciliationExpectationOf(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new ConversationGateError(
      "CONVERSATION_GATE_ARGUMENT_INVALID",
      "expected quarantine evidence must be an object",
    );
  }
  const unknown = Object.keys(value).filter(
    (key) => !new Set(["exchangeId", "reason", "observedAt"]).has(key),
  );
  if (unknown.length > 0) {
    throw new ConversationGateError(
      "CONVERSATION_GATE_ARGUMENT_INVALID",
      `expected quarantine evidence has unsupported fields: ${unknown.join(", ")}`,
    );
  }
  return {
    exchangeId: nonEmptyString(value.exchangeId, "expected.exchangeId"),
    reason: nonEmptyString(value.reason, "expected.reason"),
    observedAt: observedAtOf(nonEmptyString(value.observedAt, "expected.observedAt")),
  };
}

function sameQuarantine(left, right) {
  return left.exchangeId === right.exchangeId
    && left.reason === right.reason
    && left.observedAt === right.observedAt;
}

export class ConversationGate {
  #active = new Map();
  #quarantined = new Map();

  acquire(conversationKey, { exchangeId } = {}) {
    const key = conversationKeyOf(conversationKey);
    let boundExchangeId = exchangeId === undefined
      ? undefined
      : nonEmptyString(exchangeId, "exchangeId");

    const quarantine = this.#quarantined.get(key);
    if (quarantine) {
      throw new ConversationGateError(
        "CONVERSATION_QUARANTINED",
        `conversation '${key}' requires reconciliation before another delegation`,
        { conversationKey: key, ...quarantine },
      );
    }
    if (this.#active.has(key)) {
      throw new ConversationGateError(
        "CONVERSATION_BUSY",
        `conversation '${key}' already has an in-flight mediated turn`,
        { conversationKey: key },
      );
    }

    const token = Symbol(key);
    this.#active.set(key, { token, exchangeId: boundExchangeId });
    let settled = false;

    return {
      conversationKey: key,
      bindExchangeId: (nextExchangeId) => {
        const value = nonEmptyString(nextExchangeId, "exchangeId");
        if (settled) {
          throw new ConversationGateError(
            "CONVERSATION_LEASE_SETTLED",
            `conversation '${key}' lease is already settled`,
            { conversationKey: key, exchangeId: boundExchangeId },
          );
        }
        const current = this.#active.get(key);
        if (current?.token !== token) {
          throw new ConversationGateError(
            "CONVERSATION_LEASE_LOST",
            `conversation '${key}' lease is no longer active`,
            { conversationKey: key, exchangeId: boundExchangeId },
          );
        }
        if (boundExchangeId !== undefined) {
          if (boundExchangeId === value) return false;
          throw new ConversationGateError(
            "CONVERSATION_EXCHANGE_CONFLICT",
            `conversation '${key}' lease is already bound to another exchange`,
            { conversationKey: key, exchangeId: boundExchangeId, conflictingExchangeId: value },
          );
        }
        boundExchangeId = value;
        current.exchangeId = value;
        return true;
      },
      release: () => {
        if (settled) return false;
        settled = true;
        const current = this.#active.get(key);
        if (current?.token === token) this.#active.delete(key);
        return true;
      },
      quarantine: (reason = "native stop is unconfirmed", observedAt = undefined) => {
        if (!settled) {
          settled = true;
          const current = this.#active.get(key);
          if (current?.token === token) this.#active.delete(key);
        }
        const quarantine = {
          exchangeId: boundExchangeId,
          reason: nonEmptyString(String(reason), "reason"),
          observedAt: observedAtOf(observedAt),
        };
        this.#quarantined.set(key, quarantine);
        return structuredClone(quarantine);
      },
    };
  }

  restoreQuarantine(conversationKey, {
    exchangeId,
    reason = "native stop was unconfirmed by durable recovery",
    observedAt = undefined,
  } = {}) {
    const key = conversationKeyOf(conversationKey);
    const quarantine = {
      exchangeId: nonEmptyString(exchangeId, "exchangeId"),
      reason: nonEmptyString(reason, "reason"),
      observedAt: observedAtOf(observedAt),
    };
    if (this.#active.has(key)) {
      throw new ConversationGateError(
        "CONVERSATION_BUSY",
        `conversation '${key}' already has an in-flight mediated turn`,
        { conversationKey: key },
      );
    }
    const existing = this.#quarantined.get(key);
    if (existing) {
      if (
        existing.exchangeId === quarantine.exchangeId
        && existing.reason === quarantine.reason
        && existing.observedAt === quarantine.observedAt
      ) {
        return false;
      }
      throw new ConversationGateError(
        "CONVERSATION_QUARANTINE_CONFLICT",
        `conversation '${key}' already has different quarantine evidence`,
        { conversationKey: key, existing, conflicting: quarantine },
      );
    }
    this.#quarantined.set(key, quarantine);
    return true;
  }

  assertReconciliation(conversationKey, expected) {
    const key = conversationKeyOf(conversationKey);
    const expectation = reconciliationExpectationOf(expected);
    if (this.#active.has(key)) {
      throw new ConversationGateError(
        "CONVERSATION_BUSY",
        `conversation '${key}' has an active mediated turn and cannot be reconciled`,
        { conversationKey: key },
      );
    }

    const quarantine = this.#quarantined.get(key);
    if (!quarantine) {
      throw new ConversationGateError(
        "CONVERSATION_QUARANTINE_NOT_FOUND",
        `conversation '${key}' has no quarantine matching the administrative request`,
        { conversationKey: key },
      );
    }
    if (!sameQuarantine(quarantine, expectation)) {
      throw new ConversationGateError(
        "CONVERSATION_QUARANTINE_STALE",
        `conversation '${key}' quarantine changed before reconciliation`,
        {
          conversationKey: key,
          expected: structuredClone(expectation),
          actual: structuredClone(quarantine),
        },
      );
    }
    return structuredClone(quarantine);
  }

  reconcile(conversationKey, expected) {
    const key = conversationKeyOf(conversationKey);
    const quarantine = this.assertReconciliation(key, expected);
    this.#quarantined.delete(key);
    return quarantine;
  }

  status(conversationKey) {
    const key = conversationKeyOf(conversationKey);
    return {
      active: this.#active.has(key),
      quarantined: this.#quarantined.has(key)
        ? structuredClone(this.#quarantined.get(key))
        : null,
    };
  }
}
