const RECORD_KINDS = ["prompt", "thinking", "tool_call", "tool_result", "response"];

const SUMMARY_SOURCE = `
get rows
| where { |row| ($row.record_type? | default null) == "transcript_exchange" }
| each { |row|
    let records = ($row.records? | default [])
    {
      xid: $row.exchange_id,
      xidx: $row.exchange_index,
      exchange_start: $row.exchange_start,
      exchange_end: $row.exchange_end,
      duration_ms: ($row.duration_ms? | default null),
      model: ($row.model? | default null),
      status: $row.status,
      steps: ($records | length),
      tools: ($records | where { |record| ($record._type? | default null) == "tool_call" } | length),
      thinking: ($records | where { |record| ($record._type? | default null) == "thinking" } | length)
    }
  }
`;

const RECORDS_SOURCE = `
let request = $in
let exchange = (
  $request.rows
  | where { |row|
      ((($row.record_type? | default null) == "transcript_exchange") and (($row.exchange_id? | default null) == $request.exchange_id))
    }
  | get 0?
)
if $exchange == null {
  []
} else {
  let records = ($exchange.records? | default [])
  if $request.kind == "all" {
    $records
  } else {
    $records | where { |record| ($record._type? | default null) == $request.kind }
  }
}
`;

const STEP_SOURCE = `
let request = $in
let exchange = (
  $request.rows
  | where { |row|
      ((($row.record_type? | default null) == "transcript_exchange") and (($row.exchange_id? | default null) == $request.exchange_id))
    }
  | get 0?
)
if $exchange == null {
  null
} else {
  let records = ($exchange.records? | default [])
  $records | get $request.step?
}
`;

function requireRows(rows) {
  if (!Array.isArray(rows)) throw new TypeError("rows must be an array");
  return rows;
}

function requireExchangeId(exchangeId) {
  if (typeof exchangeId !== "string" || exchangeId.length === 0) {
    throw new TypeError("exchangeId must be a non-empty string");
  }
  return exchangeId;
}

/**
 * Typed scrutiny provider. Sources are fixed module constants; rows and every
 * selector are passed through NuEngine's JSON stdin channel.
 */
export class TranscriptQuery {
  constructor(nuEngine) {
    if (!nuEngine || typeof nuEngine.evalStructured !== "function") {
      throw new TypeError("TranscriptQuery requires a NuEngine-compatible provider");
    }
    this.nuEngine = nuEngine;
  }

  async summary(rows) {
    return this.nuEngine.evalStructured(SUMMARY_SOURCE, { rows: requireRows(rows) });
  }

  async records(rows, { exchangeId, kind = "all" } = {}) {
    requireRows(rows);
    requireExchangeId(exchangeId);
    if (kind !== "all" && !RECORD_KINDS.includes(kind)) {
      throw new TypeError(`kind must be 'all' or one of ${RECORD_KINDS.join(", ")}`);
    }
    return this.nuEngine.evalStructured(RECORDS_SOURCE, {
      rows,
      exchange_id: exchangeId,
      kind,
    });
  }

  async step(rows, { exchangeId, step } = {}) {
    requireRows(rows);
    requireExchangeId(exchangeId);
    if (!Number.isSafeInteger(step) || step < 0) {
      throw new TypeError("step must be a zero-based safe integer");
    }
    return this.nuEngine.evalStructured(STEP_SOURCE, {
      rows,
      exchange_id: exchangeId,
      step,
    });
  }
}

export const TRANSCRIPT_RECORD_KINDS = Object.freeze([...RECORD_KINDS]);
