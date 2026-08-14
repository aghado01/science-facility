export class ConversationGateError extends Error {
  constructor(code, message, details = {}) {
    super(message);
    this.name = "ConversationGateError";
    this.code = code;
    this.details = details;
  }
}

export class ConversationGate {
  #active = new Map();
  #quarantined = new Map();

  acquire(conversationKey, { exchangeId } = {}) {
    const key = String(conversationKey ?? "").trim();
    if (!key) {
      throw new ConversationGateError(
        "CONVERSATION_KEY_REQUIRED",
        "the adapter must provide a stable conversation key before acceptance",
      );
    }

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
    this.#active.set(key, { token, exchangeId });
    let settled = false;

    return {
      conversationKey: key,
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
          exchangeId,
          reason: String(reason),
          observedAt: new Date().toISOString(),
        });
      },
    };
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
