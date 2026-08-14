# Mediated Exchange Contract v1

**Status:** frozen for para-agent remediation  
**Schema dialect:** JSON Schema 2020-12  
**Scope:** one typed Primary-to-Para mediated turn and its durable evidence

This contract defines para-agent's third, mediation-level transcript. It does not
replace either client's native transcript and it does not extend the Console
Journal into an inter-agent protocol.

## Dependency boundary

```text
MCP delegate handler
  -> ParaApplication / MediatedTurnService
     -> ConversationGate
     -> ApplicationAdapter
     -> RawTraceSink
     -> ExchangeAssembler
     -> TranscriptStore
```

- MCP handlers validate and present. They do not construct Nu source, allocate
  transcript indexes, interpret native events, or write store files.
- Console operations (`send`, `wait`, `read`, `run`, and `exec`) remain escape
  hatches. Their activity never creates or implies mediated exchange boundaries.
- Nu is a replaceable typed-query provider. It is not schema, provenance,
  validation, storage, or identity authority.

## Identities

These identities are distinct and MUST NOT be aliased:

| Identity | Meaning | Authority |
|---|---|---|
| `transcript_id` | One para-agent mediation ledger | TranscriptStore |
| `participant_id` | Stable logical seat in that ledger | Transcript header |
| `application.id` / `application.version` | Native client application observed for an exchange | Validated live client event |
| `adapter.id` / `adapter.version` / `profile_id` | Adapter implementation and selected versioned profile | Adapter registry |
| `model.id` / `model.display_name` | Opaque receiver model identity | Validated live client event |
| native conversation and turn IDs | Client-local correlation identities, namespaced by application and adapter | Validated live client event |
| pane or process handle | Transport/execution location | Console engine |
| MCP request ID | One protocol request | Operation host |
| `exchange_id` | One durably accepted mediated turn | TranscriptStore |
| `exchange_index` | Terminal exchange commit order | Serialized transcript writer |

`sender_participant_id` and `receiver_participant_id` reference header
participants. They are not application names. Header application/adapter
bindings are defaults; exchange-time observations are authoritative.

Unknown identities remain absent or explicitly unbound. An application display
name MUST NOT substitute for `model.id`.

## Authority matrix

| Fact | Canonical source |
|---|---|
| Exact prompt content | Typed `delegate` ingress, excluding controls |
| Prompt acceptance time and digest | MediatedTurnService / acceptance WAL |
| Prompt rendering and transport emission | ApplicationAdapter receipt |
| Receiver observation of prompt | Correlated validated native event, when available |
| Model, exposed reasoning, tools, native IDs, terminal reply | Correlated validated receiver-native events |
| Raw native bytes | RawTraceSink artifact |
| Normalized records | Adapter projection linked to raw frames |
| Timings, outcome, omissions, commit and egress construction | para-agent mediation envelope |
| Primary receipt of MCP result | Unknown unless the host supplies separate evidence |

The primary-side MCP result is evidence para-agent constructed an egress packet;
it is never used to reconstruct the receiver reply. "Thinking" means only
reasoning material the client actually exposes. Completeness of internal
reasoning MUST NOT be claimed.

## Public operation

The first semantic operation is:

```text
delegate({
  handle,
  application,
  prompt,
  timeoutMs?
}) -> { reply, receipt }
```

- `prompt` is one exact UTF-8 string. Control arguments are separate fields.
- `application` selects an adapter profile; it is not provenance evidence.
- Callers cannot authoritatively supply model, reply, native conversation, or
  native turn identities.
- A completed result contains the receiver-authoritative terminal reply and a
  bounded receipt.
- Failed, interrupted, and timed-out results return an MCP error with the
  durable receipt and no fabricated reply.

The adapter must support byte-preserving stdin, file, or equivalent structured
prompt delivery. Shell-source interpolation and linewise pane typing are not
valid mediated prompt transports.

## Conversation execution lane

- Acquire a per-native-conversation or exclusive-pane gate before durable
  acceptance.
- The first implementation fails fast with `CONVERSATION_BUSY`; it does not
  queue an unbounded backlog.
- Different conversation keys may execute concurrently.
- An adapter must provide a stable conversation key before delivery, or prove
  that the target pane/process exclusively represents one conversation.
- Completion requires a turn-correlated native terminal event. Screen stability,
  prompt appearance, process silence, and pane scraping are not terminal proof.

If timeout or cancellation cannot confirm native stop, finalize honestly with
an incomplete trace, quarantine the conversation key, and reject further
delegation until reconciliation.

## Durable acceptance and terminalization

The physical write order is:

1. validate request, adapter profile, target, and conversation gate;
2. acquire the transcript writer lease;
3. append a durable acceptance WAL row and assign `exchange_id`;
4. deliver the prompt and append raw native bytes as observed;
5. normalize correlated records with exact raw source references;
6. append exactly one terminal exchange row, assigning `exchange_index` inside
   the writer lane;
7. append the WAL terminal marker;
8. construct the MCP result.

Preflight failures occur before acceptance and create no exchange. Every
durably accepted exchange reaches exactly one terminal outcome:

- `completed`
- `failed`
- `interrupted`
- `timeout`

`completed` requires a receiver-authoritative terminal reply and durable
terminal commit. `timeout` records deadline expiry; it does not assert the
receiver stopped. Late native events remain raw post-terminal evidence and do
not rewrite the terminal outcome.

On restart, recovery scans acceptance rows without terminal markers:

- if a terminal exchange already exists, append the missing WAL terminal marker;
- otherwise append an `interrupted` exchange with explicit restart omission and
  incomplete trace state, then mark the WAL terminal;
- never publish a second terminal exchange for the same `exchange_id`.

## Physical ownership

Under `.para-agent/transcripts/` use a contained internal filename derived from
a sanitized session label plus a SHA-256 suffix. Raw handles are never paths.

```text
<session-key>.jsonl              # row-0 header plus terminal exchange rows
<session-key>.acceptance.jsonl   # append-only acceptance and terminal markers
<session-key>.writer.lock        # exclusive owner and fencing identity
traces/<session-key>/<xid>.trace # exact native stream bytes
```

- Writable stores acquire an exclusive transcript-local writer lease containing
  writer identity, PID, and acquisition time. A live owner causes fail-closed
  startup. Stale leases are retained as evidence before reacquisition.
- A process-local promise lane serializes writes after lease acquisition.
- Read-only stores acquire no writer lease and create no directories or files.
- Allocate `exchange_index` as `max(valid exchange_index) + 1`, never by row or
  substring count.
- Malformed interior rows and incomplete final JSON block append. A parseable
  final row without LF is valid and the next append first restores framing.
- Validate header and exchange structure plus repository semantic invariants
  before any write.

## Raw trace and normalized projection

The raw trace is immutable evidence. Its terminal descriptor records:

- relative contained reference;
- SHA-256 digest and byte count;
- native format and observed application/profile;
- frame count when the format is framed;
- `complete` plus explicit omissions or malformed-frame counts.

Receiver-derived normalized records contain a source reference to the trace and
frame index or byte span, a para-agent observation time, and the native timestamp
only when supplied. Generated UUIDs or current timestamps may identify
para-agent observations; they MUST NOT masquerade as native provenance.

Keep one canonical ingress prompt record. A receiver prompt echo is delivery
evidence. Prefer separate `tool_call` and `tool_result` observations correlated
by native ID; do not fabricate a fused completed call.

## Delivery evidence

Delivery stages are monotonic only when their evidence exists:

```text
rendered -> adapter_emitted -> host_acknowledged -> receiver_observed -> model_visible
```

Each stage carries its evidence reference. Construction of an MCP result is a
separate egress stage. Model comprehension or compliance is never inferable.

## Persisted schema rules

- Compile all persisted schemas in Ajv 2020 strict mode with `ajv-formats`.
- Make both packages direct runtime dependencies.
- Close composed record variants with outer `unevaluatedProperties: false`.
  Do not put `additionalProperties: false` inside a subtype composed with a base.
- Keep top-level closure and explicit namespaced extension points.
- Validate semantic invariants not expressible portably in JSON Schema:
  participant references exist and differ; participant IDs are unique; exactly
  one first ingress prompt exists; completed exchanges contain exactly one final
  receiver response; timestamps are ordered; exchange IDs and indexes are
  unique; and model claims have native source evidence.

## Query and scrutiny

Scrutiny accepts typed selectors only: exchange summary, `exchange_id`, record
kind, or zero-based record step. User values and paths are data, never generated
Nu source. Strict structured queries either return the declared JSON value or
throw a typed error; raw text is a separate explicit mode.

Unknown-session scrutiny returns an empty/not-found result without initializing
a transcript. Provider errors become MCP `isError: true` and never successful
pseudo-JSON.

## Verification and false-green contract

Tests live in `mcp/tests/para-agent/`. `test-manifest.json` explicitly enumerates
bounded and live suites; discovery globs are not authoritative.

The PowerShell runner MUST fail when the manifest is empty, a listed file is
missing, zero tests execute, a child exits nonzero, a suite aborts, discovered
and completed counts differ, or a machine-readable terminal summary is absent.
A terminating runner error emits the literal marker `SUITE-ABORTED`.

The mandatory named regression `NU-SCRUTINY-FALSE-SUCCESS` proves that a Nu
runtime/query error becomes MCP `isError: true`, never returns pseudo-JSON as
data, and leaves transcript bytes unchanged.

## Deferred work

This contract does not add Hashish, Session Continuity, a general Artifact
engine, control-mode transport, model mutation operations, or post-hoc exchange
inference from console activity.
