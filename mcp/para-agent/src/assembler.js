/**
 * Exchange Assembler
 *
 * Staging engine for building in-flight mediated dialogue exchanges across the Primary-Para
 * boundary, performing adapter normalization, and transactionally committing completed rows.
 */

import crypto from "node:crypto";

export class ExchangeAssembler {
  constructor({
    xid,
    xidx,
    sender = "primary",
    receiver = "para",
    promptText,
    transcriptStore,
    adapterEngine,
    receiverClientId = "codex",
  }) {
    this.xid = xid ?? `xid-${Date.now()}-${crypto.randomBytes(3).toString("hex")}`;
    this.xidx = xidx ?? transcriptStore.nextIndex;
    this.sender = sender;
    this.receiver = receiver;
    this.receiverClientId = receiverClientId;
    this.transcriptStore = transcriptStore;
    this.adapterEngine = adapterEngine;

    this.startTime = new Date().toISOString();
    
    // Ingress Prompt (Authoritative primary data)
    this.records = [
      {
        _type: "prompt",
        _source_uuid: crypto.randomUUID(),
        _timestamp: this.startTime,
        text: promptText,
      },
    ];
  }

  /**
   * Ingest an intermediate raw event from the receiver pane (thinking, tool_call, partial response).
   */
  ingest(rawEvent) {
    if (!rawEvent) return null;
    const normalized = this.adapterEngine.normalizeEvent(this.receiverClientId, rawEvent);
    if (normalized) {
      this.records.push(normalized);
    }
    return normalized;
  }

  /**
   * Ingest a tool execution directly.
   */
  recordToolCall({ tool_name, tool_kind, tool_use_id, input, response, status = "completed" }) {
    const record = {
      _type: "tool_call",
      _source_uuid: crypto.randomUUID(),
      _timestamp: new Date().toISOString(),
      tool_name,
      tool_kind,
      tool_use_id: tool_use_id ?? `call-${crypto.randomBytes(3).toString("hex")}`,
      status,
      input,
      response,
    };
    this.records.push(record);
    return record;
  }

  /**
   * Ingest a thinking trace.
   */
  recordThinking(text) {
    const record = {
      _type: "thinking",
      _source_uuid: crypto.randomUUID(),
      _timestamp: new Date().toISOString(),
      text,
    };
    this.records.push(record);
    return record;
  }

  /**
   * Finalize the exchange, commit the exchange row transactionally to transcript.jsonl,
   * and return the symmetric reply + receipt packet for the Primary agent.
   */
  async commit({
    terminalText,
    status = "completed",
    model,
    effort,
    nativeProvenance,
    displayName,
  } = {}) {
    const endTime = new Date().toISOString();

    // Ensure terminal response is recorded in records[]
    if (terminalText !== undefined && terminalText !== null) {
      const hasFinalResponse = this.records.some((r) => r._type === "response" && r.phase === "final");
      if (!hasFinalResponse) {
        this.records.push({
          _type: "response",
          _source_uuid: crypto.randomUUID(),
          _timestamp: endTime,
          phase: "final",
          text: terminalText,
        });
      }
    }

    const adapter = this.adapterEngine.getAdapter(this.receiverClientId);
    const resolvedModel = model ?? (adapter ? adapter.display_name : this.receiverClientId);

    const exchangePayload = {
      exchange_id: this.xid,
      exchange_index: this.xidx,
      exchange_start: this.startTime,
      exchange_end: endTime,
      sender: this.sender,
      receiver: this.receiver,
      display_name: displayName ?? resolvedModel,
      model: resolvedModel,
      effort: effort ?? "default",
      status,
      native_provenance: nativeProvenance ?? {},
      records: this.records,
    };

    // Transactional atomic commit to the transcript file
    await this.transcriptStore.commitExchange(exchangePayload);

    const durationMs = Date.parse(endTime) - Date.parse(this.startTime);

    // Symmetric Egress Packet
    return {
      reply: terminalText ?? "",
      receipt: {
        _xid: this.xid,
        _xidx: this.xidx,
        status,
        duration_ms: durationMs,
        records_count: this.records.length,
        tool_calls: this.records.filter((r) => r._type === "tool_call").length,
        thinking_steps: this.records.filter((r) => r._type === "thinking").length,
      },
    };
  }
}
