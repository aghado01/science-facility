Yes—that is the precise separation. Para-agent MCP owns a third, mediation-level transcript; it is not merely exporting either client’s native transcript.

```text
Primary native transcript
────────────────────────────────────────────
Human prompt
Primary thinking
MCP tool call { prompt: P1 }
MCP tool result { reply: R1 }
Primary thinking
MCP tool call { prompt: P2 }
MCP tool result { reply: R2 }
Primary final response to human


Para native transcript
────────────────────────────────────────────
Received P1
Para thinking/tools
Produced R1

Received P2
Para thinking/tools
Produced R2


Para-agent MCP transcript
────────────────────────────────────────────
Exchange 1: Primary --P1--> Para --R1--> Primary
Exchange 2: Primary --P2--> Para --R2--> Primary
```

Although `R1` appears in the primary transcript, it appears as an MCP tool result—a projection into the primary application’s point of view. The primary transcript does not directly contain the para client’s native turn, model observation, thinking, tools, session identity, or production provenance.

The mediation backend is uniquely positioned to assemble the complete exchange:

1. Capture the exact dialogue prompt from the MCP request, excluding control arguments.
2. Associate it with the sender’s native conversation, turn, and tool-call identifiers when observable.
3. Deliver that unchanged prompt through the receiver’s psmux pane.
4. Use the receiver’s adapter to identify its native conversation/turn and collect its reply trace.
5. Capture the terminal reply from the receiver-side authority.
6. Return that reply as the MCP tool result.
7. Commit the unified exchange envelope.

Therefore, the canonical sources are asymmetric even though the resulting schema is symmetric:

- `prompt.content` is authoritative from the mediation ingress.
- `reply.content`, model, thinking, and tools are authoritative from the receiving client’s adapter.
- The primary-side tool result is evidence that the reply was returned, not the source from which the reply should be reconstructed.
- Psmux provides the bidirectional transport and observable pane boundary; adapters interpret each client’s native events.

This also clarifies the schema split. The exchange should contain the stitched conversational result:

```json
{
  "exchange_id": "<<xid>>", // not sure about specific format
  "exchange_index": <<xidx>>, // sequence information
  "exchange_start": "2026-08-04T08:14:06.9600000Z",
  "exchange_end":"2026-08-04T08:18:04.7460000Z",
  "sender": "claude", // name of the sender application e.g. claude, codex, agy
  "display_name": "fable-5", // name of the sender model display name e.g. fable_5, gpt5.6-sol, gemini-flash-3.6
  "receiver": "agy", //
  "records": {...}, // nested jsonl structure with transcript of internal steps e.g. thinking, tool calls, tool results
  "job_id": "<<identifier>>", // not sure about this one
  "trace_ref": "trace-2", // something like this but needs to be more specific
  "status": "completed" // maybe rarely "interrupted" or other
}
```

Separate chronological tables hold how that result was established:

- Sender-side MCP invocation observation.
- Psmux delivery and completion events.
- Receiver-side native observations.
- Thinking and resolved tool facts.
- MCP result delivery observation.

Several such para exchanges can be serially embedded inside one human-facing primary turn. The primary’s eventual human-facing final response remains entirely outside the para transcript because it was never delivered through the mediated primary–para channel.

The key backend abstraction is therefore an `ExchangeAssembler` joining two application-local viewpoints around one mediated delivery—not a parser trying to infer the inter-agent conversation afterward from either native transcript alone.
