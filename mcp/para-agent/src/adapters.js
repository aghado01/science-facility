/**
 * Client Adapter Engine
 *
 * Loads declarative adapter maps (*.json) conforming to `client-adapter.schema.json`
 * and normalizes client-native event streams into canonical transcript records.
 */

import fs from "node:fs/promises";
import { existsSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ADAPTERS_DIR = path.join(__dirname, "adapters");

/** Resolve a dotted path e.g. "message.content[0].text" or "foo.bar" from an object. */
export function getByPath(obj, dotPath) {
  if (!obj || !dotPath) return undefined;
  // Normalize array access like content[0].text -> content.0.text
  const normalized = dotPath.replace(/\[(\w+)\]/g, ".$1");
  const parts = normalized.split(".");
  let curr = obj;
  for (const part of parts) {
    if (curr === null || curr === undefined) return undefined;
    curr = curr[part];
  }
  return curr;
}

export class AdapterEngine {
  constructor() {
    this.adapters = new Map();
    this.initialized = false;
  }

  /** Load all adapter JSON configurations from src/adapters/ */
  async init() {
    if (this.initialized) return this;
    if (existsSync(ADAPTERS_DIR)) {
      const files = await fs.readdir(ADAPTERS_DIR);
      for (const file of files) {
        if (!file.endsWith(".json")) continue;
        const fullPath = path.join(ADAPTERS_DIR, file);
        try {
          const content = await fs.readFile(fullPath, "utf8");
          const adapterConfig = JSON.parse(content);
          if (adapterConfig.client_id) {
            this.adapters.set(adapterConfig.client_id, adapterConfig);
          }
        } catch (err) {
          console.error(`[AdapterEngine] Error loading adapter '${file}':`, err.message);
        }
      }
    }
    this.initialized = true;
    return this;
  }

  /** Get loaded adapter definition by client ID */
  getAdapter(clientId) {
    return this.adapters.get(clientId) ?? null;
  }

  /**
   * Normalize a native event into a canonical transcript record.
   * Returns null if the event doesn't map to a canonical kind.
   */
  normalizeEvent(clientId, rawEvent) {
    const adapter = this.getAdapter(clientId);
    if (!adapter) {
      // Fallback: If no adapter map exists, attempt best-effort heuristic
      return this._heuristicNormalize(rawEvent);
    }

    const mappings = adapter.record_mappings;
    const rawType = rawEvent._type ?? rawEvent.type ?? rawEvent.event;

    // Check prompt
    if (mappings.prompt?.native_type === rawType) {
      return {
        _type: "prompt",
        _source_uuid: rawEvent._source_uuid ?? crypto.randomUUID(),
        _timestamp: getByPath(rawEvent, mappings.prompt.timestamp_path) ?? new Date().toISOString(),
        _turn_id: rawEvent._turn_id ?? null,
        text: getByPath(rawEvent, mappings.prompt.text_path) ?? String(rawEvent),
      };
    }

    // Check thinking
    if (mappings.thinking?.native_type === rawType) {
      return {
        _type: "thinking",
        _source_uuid: rawEvent._source_uuid ?? crypto.randomUUID(),
        _timestamp: getByPath(rawEvent, mappings.thinking.timestamp_path) ?? new Date().toISOString(),
        _turn_id: rawEvent._turn_id ?? null,
        text: getByPath(rawEvent, mappings.thinking.text_path) ?? String(rawEvent),
      };
    }

    // Check tool_call
    if (mappings.tool_call?.native_type === rawType) {
      const tc = mappings.tool_call;
      return {
        _type: "tool_call",
        _source_uuid: rawEvent._source_uuid ?? crypto.randomUUID(),
        _timestamp: rawEvent._timestamp ?? new Date().toISOString(),
        _turn_id: rawEvent._turn_id ?? null,
        tool_name: getByPath(rawEvent, tc.tool_name_path) ?? "unknown_tool",
        tool_kind: tc.tool_kind_path ? getByPath(rawEvent, tc.tool_kind_path) : undefined,
        tool_use_id: tc.tool_use_id_path ? getByPath(rawEvent, tc.tool_use_id_path) : undefined,
        status: (tc.status_path ? getByPath(rawEvent, tc.status_path) : null) ?? "completed",
        input: getByPath(rawEvent, tc.input_path) ?? {},
        response: tc.result_path ? getByPath(rawEvent, tc.result_path) : undefined,
      };
    }

    // Check response
    if (mappings.response?.native_type === rawType) {
      return {
        _type: "response",
        _source_uuid: rawEvent._source_uuid ?? crypto.randomUUID(),
        _timestamp: getByPath(rawEvent, mappings.response.timestamp_path) ?? new Date().toISOString(),
        _turn_id: rawEvent._turn_id ?? null,
        phase: mappings.response.phase_path ? getByPath(rawEvent, mappings.response.phase_path) : "final",
        text: getByPath(rawEvent, mappings.response.text_path) ?? String(rawEvent),
      };
    }

    return null;
  }

  /** Extract provenance from raw exchange payload */
  extractProvenance(clientId, rawPayload) {
    const adapter = this.getAdapter(clientId);
    if (!adapter || !adapter.provenance_mappings) return {};

    const pm = adapter.provenance_mappings;
    return {
      thread_id: getByPath(rawPayload, pm.thread_id),
      turn_id: getByPath(rawPayload, pm.turn_id),
      model: getByPath(rawPayload, pm.model),
      effort: pm.effort ? getByPath(rawPayload, pm.effort) : undefined,
      user_label: pm.user_label ? getByPath(rawPayload, pm.user_label) : undefined,
    };
  }

  _heuristicNormalize(rawEvent) {
    if (typeof rawEvent === "string") {
      return { _type: "response", _timestamp: new Date().toISOString(), text: rawEvent };
    }
    if (rawEvent._type && ["prompt", "thinking", "tool_call", "response"].includes(rawEvent._type)) {
      return rawEvent;
    }
    return null;
  }
}
