export class ConversationGateError extends Error {
  constructor(code, message, details = {}) {
    super(message);
    this.name = "ConversationGateError";
    this.code = code;
    this.details = details;
  }
}

function conversationKeyOf(value) {
  const key = String(value ?? "").trim();
  if (!key) {
    throw new ConversationGateError(
      "CONVERSATION_KEY_REQUIRED",
      "the adapter must provide a stable conversation key before acceptance",
    );
  }
  return key;
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
      quarantine: (reason = "native stop is unconfirmed") => {
        if (!settled) {
          settled = true;
          const current = this.#active.get(key);
          if (current?.token === token) this.#active.delete(key);
        }
        this.#quarantined.set(key, {
          exchangeId: boundExchangeId,
          reason: String(reason),
          observedAt: new Date().toISOString(),
        });
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

  reconcile(conversationKey) {
    return this.#quarantined.delete(String(conversationKey));
  }

  status(conversationKey) {
    const key = String(conversationKey);
    return {
      active: this.#active.has(key),
      quarantined: this.#quarantined.get(key) ?? null,
    };
  }
}
