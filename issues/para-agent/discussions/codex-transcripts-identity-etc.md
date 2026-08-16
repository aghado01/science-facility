
# ok, so circling back, we have alot of good design work and planning in place, but regarding the current state of the MCP, there are several low-hanging fruit bug fixes and enhancements. can we review the session for things that are worth doing now, aside from all of the loftier design and infrastructure goals? several things surfaced in the original claude-agy transcript from earlier, and we surfaced more based on that

Yes. The current MCP has a clean near-term tranche that does not depend on the application facade, mounted artifacts, Hashish, hooks, or session continuity. I verified that the original issues are still present in the unchanged source.

## Fix now

Before changing behavior, add a small `node:test` suite; [package.json](D:/aghado01/science-facility/mcp/para-agent/package.json:10) currently has no test command.

| Priority | Work item | Why it belongs now |
|---|---|---|
| P0 | Serialize pane runs and journal writes | `journalFor()` can create two Journal instances concurrently, `_append()` is unordered, and a second `run` can dispatch while a timed-out command is still active. This can corrupt pane input or make integer cursors skip records. Add promise caching, an append queue, and a per-pane busy gate/mutex. See [index.js](D:/aghado01/science-facility/mcp/para-agent/src/index.js:41), [journal.js](D:/aghado01/science-facility/mcp/para-agent/src/journal.js:72), and [capture.js](D:/aghado01/science-facility/mcp/para-agent/src/capture.js:255). |
| P0 | Fix regex state and `body(grep)` pagination | `g`/`y` flags make repeated regex tests stateful. Grep pagination advertises `offsetLines` but never applies it, so continuations repeat page one. Nonmatching lines are also incorrectly counted as withheld query results. See [journal.js](D:/aghado01/science-facility/mcp/para-agent/src/journal.js:275) and [index.js](D:/aghado01/science-facility/mcp/para-agent/src/index.js:653). |
| P0 | Remove silent-loss paths | Missing `.out` files become successful empty output; missing referenced bodies become empty reads; malformed journal lines receive `seq:-1` and disappear beneath a normal cursor; an unreadable inbox claim becomes `""` and is then deleted; exhausted PowerShell inbox retries vanish silently. These directly violate the contract’s highest priority. See [journal.js](D:/aghado01/science-facility/mcp/para-agent/src/journal.js:107) and [ParaConsole.psm1](D:/aghado01/science-facility/mcp/para-agent/capture/ParaConsole.psm1:127). |
| P1 | Record truthful terminal state | A pane detected as dead produces only a note and leaves the turn open, despite the contract defining `exit(outcome:"died")`. Record any partial body, append the terminal exit, and settle open turns when `kill` destroys their pane. See [capture.js](D:/aghado01/science-facility/mcp/para-agent/src/capture.js:218). |
| P1 | Make summary bounded and conforming | `log` accepts `from` and `limit`, but summary ignores both and returns every turn. Its receipt lacks the promised scanned/byte/deferred-body accounting. This default orientation path will eventually become its own context-bloat source. See [journal.js](D:/aghado01/science-facility/mcp/para-agent/src/journal.js:478) and [index.js](D:/aghado01/science-facility/mcp/para-agent/src/index.js:554). |
| P1 | Add aggregate response-byte limits | `body`, `find`, `read`, and `wait` are bounded mainly by lines. One enormous line or 50,000 rows can still create a huge response. Add `maxBytes`, explicit truncation accounting, and valid continuations. |
| P1 | Stop treating eight-hex hashes as equality | `out_hash` is a 32-bit display prefix but currently drives `sameOutputAsTurn`. Keep prefixes for display/correlation, add a full digest for equality, and remove the duplicate dead dedupe implementation. `cmd_hash` should likewise remain non-authoritative. See [journal.js](D:/aghado01/science-facility/mcp/para-agent/src/journal.js:20). |
| P1 | Return executable continuations | Receipts currently recommend internal calls such as `read(...)` and `search(...)`, although the public tools are `log`, `body`, and `find`; some continuations contain placeholders. Return structured `{tool, input, covers}` continuations that validate against the actual exposed schema. |

The same correction pass should reconcile several inexpensive truthfulness issues:

- Narrow the “byte-exact” claim: PowerShell passes output through `Out-String -Stream`, while Bash uses different fidelity and does not preserve shell state across `run` calls.
- Correct the contract’s stale `Out-Default` discussion; interactive capture now uses `Start-Transcript` and observes `Write-Host`.
- Either make cooperative cancellation usable—at minimum expose the cancel path to the command—or retract the claim that the producer polls it.
- Make `exec(keepJournal:false)` actually delete its generated stream, or retain overflow under an explicit policy. It currently makes large output unreachable while leaving the files orphaned.
- Correct contract references from sidecars named by `seq` to sidecars named by `turn`.
- Stop attributing stream-level notes to whichever turn happened most recently.

One Agy finding I would not carry forward: `outcome:"completed"` with `ok:false` is coherent if `outcome` describes lifecycle completion and `ok` describes command success.

## Small enhancements immediately afterward

1. **Bounded hit materialization in `find`.** Let one search return the top matching turn bodies or selected spans under `maxBytes`. This removes the common `find → body` follow-up without requiring a general artifact engine.

2. **Batched `run`.** Accept `commands[]`; each command remains its own Console turn, but one MCP call returns ordered per-command receipts plus an aggregate receipt. Support `stopOnError`. Do this only after the pane mutex/open-turn gate exists.

3. **Caller-selected return shape.** Add a small selector such as receipt-only, inline-under-budget, tail, grep, or retained body. This is more useful now than changing the global 2 KB threshold.

## Leave out of this milestone

Do not couple these fixes to:

- Bash-to-MCP PreToolUse rewriting—the client cannot change the selected tool, and no `para-run` CLI exists;
- `cmd_hash` replay guidance or cache suppression;
- SimHash/Hashish projections;
- new ledger record kinds;
- the job-exchange, continuity, mounted-artifact, or full backend-facade work;
- eager tool consolidation.

Recommended sequence: one `0.1.1` correctness milestone covering tests and the P0/P1 items, followed by a small turn-economy milestone containing bounded `find` materialization and batched `run`. No source changes were made during this review.

---

# i think its important here to distinguish respective transcript records of agent using calls to bash or powershell vs the interface that get's launched in powershell and observed by write-host. also the journal doesn't currently attribute the author. this should be first class metadata in abstract terms of agent vs para-agent

Yes—this should move into the immediate schema work, before freezing conformance fixtures.

`origin: "run" | "exec" | "interactive"` currently describes an ingress/capture path, not authorship. Shell dialect, author, producer, and observation method are separate facts.

| Record source | Author | Producer/observer | What it proves |
|---|---|---|---|
| Harness Bash/PowerShell call | Driver agent | Client harness | The agent requested that tool call; not necessarily console/process truth |
| Para-agent MCP `run` | Driver agent | Para-agent server and capture wrapper | The MCP dispatched a command into a bound pane and observed its receipt |
| PowerShell prompt/transcript capture | Para-agent, human, or unknown | `ParaConsole` using history plus `Start-Transcript` | A command/output appeared in that persistent host; `Write-Host` visibility says nothing by itself about authorship |
| Direct TUI/agent pane observation | Usually para-agent process; input may come from driver | Pane/screen observer | Rendered screen state, not a shell transcript or byte-faithful command body |

A minimal record vocabulary could be:

```json
{
  "actor": {
    "role": "driver_agent|para_agent|human|system|unknown",
    "id": "codex|claude|agy|null",
    "binding": "configured|native|declared|unbound"
  },
  "producer": {
    "kind": "mcp_capture|powershell_prompt_capture|harness_adapter|pane_observer",
    "id": "provider instance"
  },
  "observation": {
    "plane": "harness|mcp|console",
    "method": "tool_call|wrapper_file|host_transcript|pane_screen",
    "fidelity": "request_record|rendered_text|host_transcript|screen_text"
  }
}
```

The causal `turn` record should own the actor attribution; its `out` and `exit` records inherit that actor through their explicit `turn` reference. Stream-level notes need their own actor and must no longer be attributed to the most recent turn.

For the current implementation:

- MCP `run`/`exec` can receive the driver identity from server-instance configuration, avoiding another model-facing input.
- `Initialize-ParaConsole` should accept an actor binding such as `para_agent:agy`, `human`, or `unknown`.
- If humans and agents share one prompt and the producer cannot distinguish them, it must emit `unknown`; `Write-Host`, process name, or timing must not be used to guess.
- Existing records should remain `unknown`, not be retroactively classified from `origin`.
- Keep `origin` temporarily for compatibility, but treat it as ingress and eventually rename it accordingly.

This also sharpens the immediate milestone: first define actor/producer/observation metadata, then build the fixtures around those distinctions. Otherwise the tests would fossilize the current conflation.

---

# its also important to be clear about the semantics of "para agent" which is the agent tethered to the driving agent (claude so far). roles should be agent, para-agent, human. there is no unknown case and it should resolve to one of those three, which most of the time would be 'agent' for initialization since i start a claude session and tell claude to init a session with agy, the para-agent

Agreed. My prior vocabulary was too broad. The role enum should be exactly:

```text
human | agent | para-agent
```

Semantics:

- `human`: the person directing or intervening.
- `agent`: the driving agent—currently Claude—which owns the supervisory side of the tether.
- `para-agent`: the subordinate agent attached to that driving agent—currently agy.

The MCP server, PowerShell hook, capture wrapper, shell, and harness are not actors. They are producers, transports, or observers.

The relationship should be established explicitly at initialization:

```json
{
  "kind": "session_init",
  "actor": {
    "role": "agent",
    "id": "claude"
  },
  "establishes": {
    "role": "para-agent",
    "id": "agy",
    "relation": "tethered"
  }
}
```

That correctly describes the normal sequence: the human asks Claude to initialize agy, but Claude is the immediate author of the initialization operation. Subsequent directed records can express both ends:

```json
{
  "actor": { "role": "agent", "id": "claude" },
  "target": { "role": "para-agent", "id": "agy" }
}
```

A reply from agy reverses them:

```json
{
  "actor": { "role": "para-agent", "id": "agy" },
  "target": { "role": "agent", "id": "claude" }
}
```

A direct human intervention uses `human` as the actor.

There should be no `unknown` role. Role resolution is an initialization invariant:

- the MCP server instance starts bound to its driving `agent`;
- spawning or attaching the subordinate establishes the `para-agent`;
- direct human interaction must enter through an explicitly human-bound path;
- a producer unable to resolve one of those roles has a contract/configuration error and must not emit an ambiguously attributed record.

This remains separate from observation metadata:

```json
{
  "actor": { "role": "agent", "id": "claude" },
  "producer": { "kind": "para-agent-mcp" },
  "observation": {
    "plane": "console",
    "method": "powershell-host-transcript"
  }
}
```

`Write-Host` visibility identifies the capture method, not the author. Likewise, `shell: "pwsh"` or `"bash"` identifies the execution dialect, not whether the command came from the agent or para-agent.

One additional naming constraint follows: the **para-agent MCP** is infrastructure, while a **para-agent role** is the tethered agent. The server must never assign itself the `para-agent` role merely because of its project name.

This role model should precede the conformance fixtures and become required metadata on new journal turns, summaries, messages, and initialization records. Existing role-less records would need an explicit import mapping rather than an `unknown` fallback.

---

# I dont like that schema as is. i like to think about it kind of like an old-fashioned wire communication framework, where two actors are sending messages to eachother. Wouldn't a simple "To/From" with role labels suffice?

Yes. I over-modeled it. For the communication layer, `from` and `to` are the right primitives.

```json
{
  "from": "agent",
  "to": "para-agent",
  "turn": 17,
  "kind": "turn",
  "text": "Review the implementation"
}
```

The response reverses direction:

```json
{
  "from": "para-agent",
  "to": "agent",
  "turn": 17,
  "kind": "out",
  "text": "..."
}
```

The complete role enum is:

```text
human | agent | para-agent
```

Typical traffic becomes:

```text
human → agent
agent → para-agent
para-agent → agent
agent → human
```

This records the immediate sender and recipient, not the ultimate causal chain. When you ask Claude to initialize agy, the initialization transmission is therefore:

```json
{
  "from": "agent",
  "to": "para-agent",
  "kind": "init"
}
```

A stream can bind concrete identities once:

```json
{
  "human": "azrie",
  "agent": "claude",
  "para-agent": "agy"
}
```

Individual records then need only the role labels. The stream is effectively the wire/channel, and `turn` is the exchange number.

Capture mechanics remain orthogonal:

```json
{
  "from": "para-agent",
  "to": "agent",
  "origin": "interactive",
  "shell": "pwsh",
  "capture": "host-transcript"
}
```

Here:

- `from`/`to` establish authorship and direction;
- `origin` says how the interaction entered the journal;
- `shell` says where it executed;
- `capture` distinguishes wrapper-file output, PowerShell host transcript, or pane-screen observation.

Thus an agent-side Bash/PowerShell call and para-agent output observed through `Write-Host` are distinguished primarily by wire direction, while capture metadata describes the technical evidence path.

For a normal tethered exchange:

- `turn`: `agent → para-agent`
- `out`: `para-agent → agent`
- `exit`: `para-agent → agent`, as the return receipt for that turn
- human intervention: whichever explicit human-to-agent or human-to-para-agent direction actually occurred

Backend components are not actors and never appear in `from` or `to`. They merely record or transport the wire traffic. Role resolution remains mandatory; initialization must establish the channel endpoints before records are accepted.

---

# we should be able to assign specific identities to each model in the dyad based on the model name e.g. Fable, Opus etc and Gemini Flash/Gemini Pro, whichever agy model is running at the time

Yes. `from` and `to` should identify endpoints, not merely roles. The smallest useful address is:

```json
{
  "role": "agent",
  "identity": "Opus"
}
```

A dyadic exchange then becomes:

```json
{
  "from": {
    "role": "agent",
    "identity": "Opus"
  },
  "to": {
    "role": "para-agent",
    "identity": "Gemini Flash"
  },
  "turn": 17,
  "kind": "turn"
}
```

The reply reverses the endpoints:

```json
{
  "from": {
    "role": "para-agent",
    "identity": "Gemini Flash"
  },
  "to": {
    "role": "agent",
    "identity": "Opus"
  },
  "turn": 17,
  "kind": "out"
}
```

The distinction is:

- `role` describes the endpoint’s position in the relationship.
- `identity` describes the model currently occupying that position.
- `agy` is the persistent para-agent/session name, while `Gemini Flash` or `Gemini Pro` identifies the model running as agy at that time.

The channel initialization can bind both:

```json
{
  "kind": "channel-open",
  "agent": {
    "identity": "Opus"
  },
  "para-agent": {
    "name": "agy",
    "identity": "Gemini Flash"
  }
}
```

Human messages use the same address form:

```json
{
  "from": {
    "role": "human",
    "identity": "Azrie"
  },
  "to": {
    "role": "agent",
    "identity": "Opus"
  }
}
```

If either model changes—such as agy moving from Gemini Flash to Gemini Pro—the binding must change explicitly. Historical records retain the old identity; they are never reinterpreted according to the currently running model. That can be represented as a new channel epoch or a small rebinding record:

```json
{
  "kind": "endpoint-rebind",
  "role": "para-agent",
  "name": "agy",
  "previous": "Gemini Flash",
  "identity": "Gemini Pro"
}
```

Since there is no unknown role or identity case, channel opening and rebinding should fail until both model identities are resolved. Capture method, shell, and MCP/harness provenance remain separate metadata and do not determine the endpoint identity.

---

# we shouldn't need enums for the identities though. those are something we can infer from the respective applications under the hood. "Opus 4.8" is a specific model enum in claude and we can list that or query it, or simply see it in the pane and fill communique schema with the value

Right. Only the role needs a closed enum:

```text
human | agent | para-agent
```

Model identity should be an open string populated from the underlying application:

```json
{
  "from": {
    "role": "agent",
    "identity": "Opus 4.8"
  },
  "to": {
    "role": "para-agent",
    "identity": "Gemini Pro"
  }
}
```

Para-agent should resolve those identities under the hood, preferably in this order:

1. Native application/session metadata.
2. The application’s model-list or status query.
3. A stable model declaration visible in the pane.
4. Explicit initialization configuration only when the application exposes no queryable identity.

The communique does not need to carry the resolution mechanics. Those can live in the channel-binding receipt:

```json
{
  "role": "para-agent",
  "identity": "Gemini Pro",
  "application": "agy",
  "resolved_from": "pane-status",
  "observed_at": "..."
}
```

Messages then carry only the resolved endpoint address. The identity field remains an unrestricted application-defined value, so a new Claude or Gemini model requires no para-agent schema change.

The backend should cache the binding for the channel epoch and refresh it when the application reports a model switch. Since ambiguous identity is not allowed, transmission begins only after both endpoints have resolved identities.

---

# how would getting the model name work idiomatically in claude and agy?

The idiomatic mechanism is almost identical in both clients: use their status-line callback as a machine-readable identity feed.

- Claude Code sends JSON containing `session_id`, `model.id`, and `model.display_name` to the configured `statusLine` command. It fires at session start and again after relevant state changes. [Claude Code status-line contract](https://code.claude.com/docs/en/statusline)
- Agy sends JSON containing `conversation_id` and the same `model.id` / `model.display_name` pair to its custom status-line command. [Antigravity CLI status-line contract](https://antigravity.google/docs/cli/statusline)

So para-agent can use a tiny shared adapter:

```text
Claude statusLine JSON ─┐
                        ├─> endpoint binding registry
Agy statusLine JSON ────┘
```

The registry would hold something like:

```json
{
  "role": "agent",
  "application": "claude-code",
  "session": "…",
  "model_id": "claude-opus-5",
  "identity": "Opus 5"
}
```

and:

```json
{
  "role": "para-agent",
  "application": "agy",
  "session": "…",
  "model_id": "Gemini 3.6 Flash (High)",
  "identity": "Gemini 3.6 Flash (High)"
}
```

The communique itself can remain as simple as you wanted:

```json
{
  "from": { "role": "agent", "identity": "Opus 5" },
  "to": { "role": "para-agent", "identity": "Gemini 3.6 Flash (High)" }
}
```

A few important semantics:

- `role` comes from the dyad topology, not the model vendor. Agy can run Gemini, Claude, or other models while remaining the `para-agent`.
- `identity` is an opaque application-provided string, never an enum.
- Preserve both the raw `model_id` and friendly `display_name` internally. Claude aliases such as `opus` can resolve differently over time, while a full ID pins the historical identity. [Claude model configuration](https://code.claude.com/docs/en/model-config)
- Snapshot the endpoint binding onto each communique when it is sent. A model can change during a session; Antigravity explicitly applies a mid-execution model change after the current turn finishes. [Antigravity model behavior](https://antigravity.google/docs/models?app=cli)
- Only append an identity-change event when the tuple changes. Status callbacks can fire frequently, so repeatedly journaling identical identity records would add needless overhead.
- The callback should write through a side channel to para-agent state. Anything it prints to stdout is status-line UI output and must not be mistaken for a wire communique or shell output.

For manual/debug fallback:

- Claude: `/status`; its persisted assistant records also contain the exact per-response `message.model`.
- Agy: `agy models` enumerates available names, `--model "…"` pins one at launch, and `/model` or the lower-right indicator shows the active choice. [Google’s Antigravity CLI walkthrough](https://codelabs.developers.google.com/antigravity-cli-hands-on)

Thus I would not scrape either pane. The native status-line JSON feeds provide the clean initialization and change-notification path, while transcript metadata can serve as post-hoc verification.

<oai-mem-citation>
<citation_entries>
MEMORY.md:66-69|note=[used current para-agent planning scope]
MEMORY.md:81-95|note=[used prior preference for bounded design and verified hook capabilities]
</citation_entries>
<rollout_ids>
019fed26-1882-7071-8c49-a5c35accff7f
</rollout_ids>
</oai-mem-citation>

---

# agy doesn't have an equivalent of message.model?

Correct—I was conflating active-session model state with per-message attribution.

In the current Agy implementation:

- Public `transcript.jsonl` records do not contain a `model`, `modelName`, or `model_id` field. They are step-oriented records containing fields such as `step_index`, `source`, `type`, `content`, `thinking`, and `tool_calls`.
- Agy does retain model information internally. Its private conversation SQLite database has a `gen_metadata` row per generation containing identifiers such as `gemini-3.6-flash` and the display name `Gemini 3.6 Flash (High)`.
- That SQLite value is embedded in private protobuf metadata, so it should not become a production para-agent dependency.

Therefore the current evidence hierarchy is:

| Client | Model evidence | Scope |
|---|---|---|
| Claude | `message.model` in transcript | Individual response |
| Agy | Status-line `model.id` and `model.display_name` | Active conversation/turn |
| Agy internal | SQLite `gen_metadata` | Individual generation, but private/unstable |

For para-agent, the sound Agy adapter is to capture the public status-line model at turn start and attach that identity to the resulting communiques. Agy guarantees that its selected reasoning model remains fixed for the active user turn; a model change during execution takes effect only after that turn finishes. [Antigravity model semantics](https://antigravity.google/docs/models?app=cli) The status-line feed exposes the active model alongside `conversation_id`. [Antigravity status-line contract](https://antigravity.google/docs/cli/statusline)

So we can still attribute Agy messages reliably at turn scope, but it is not presently as strong or direct as Claude’s per-response `message.model`. Ideally Agy would eventually expose the generation model in `transcript.jsonl` or each `stream-json` step/result event. Until then, we should explicitly regard its attribution as a captured turn binding, not claim it came from the message record itself.

---

# I don't think it's sound to be using transcript files backend. I think it should be all based on API streaming model.id for both, with the MCP exposing tools to toggle things like the model. Application-level provenance based on the application name "claude", "agy" etc. application profiles can be saved at schemas validated against application version. model.displayname and model.id can be transmitted transparently, we don't even need to make up codenames. the application adapters can have schemas for the relevant API surface and commands.

Agreed. My transcript-based fallback was the wrong boundary. Transcripts can remain optional audit/replay artifacts, but they should not participate in identity resolution or control.

The live stream should be authoritative:

```json
{
  "application": {
    "name": "claude",
    "version": "2.1.226",
    "profile": "claude/2.1.x"
  },
  "session_id": "...",
  "model": {
    "id": "claude-opus-5",
    "display_name": "Claude Opus 5"
  }
}
```

The values of `model.id` and `model.display_name` pass through unchanged. No codenames, normalization tables, or model enums are necessary.

A communique can consequently remain straightforward:

```json
{
  "from": {
    "role": "agent",
    "application": "claude",
    "model": {
      "id": "claude-opus-5",
      "display_name": "Claude Opus 5"
    }
  },
  "to": {
    "role": "para-agent",
    "application": "agy",
    "model": {
      "id": "gemini-3.6-flash-high",
      "display_name": "Gemini 3.6 Flash (High)"
    }
  }
}
```

The adapter boundary should own:

- Application/version detection.
- Selection of a compatible application profile.
- Validation of native streaming events.
- Preservation of raw application events where useful.
- Typed implementation of supported application commands.
- Capability reporting for that application/version.
- Translation into the small common para-agent event envelope.

An application profile would describe contracts, not model inventories:

```json
{
  "profile_schema_version": 1,
  "application": "agy",
  "application_version": {
    "range": ">=1.1.8 <1.2.0"
  },
  "transport": {
    "kind": "ndjson",
    "events": ["init", "step_update", "result"]
  },
  "operations": {
    "model.list": {
      "supported": true
    },
    "model.set": {
      "supported": true,
      "effective": "next_turn"
    }
  }
}
```

Models remain dynamically discovered opaque records. The profile validates their shape—such as requiring string `id` and `display_name`—without listing allowable identities.

The MCP can expose a small semantic control surface rather than mirroring every CLI command:

- `session.state`
- `model.list`
- `model.set`
- Possibly a broader `session.configure` for model, effort, mode, and similar settings.

Each tool delegates to the selected adapter. Claude’s streaming SDK supports a live `setModel()` operation. [Claude Agent SDK reference](https://code.claude.com/docs/en/agent-sdk/typescript) Agy currently exposes structured `init`, `step_update`, and `result` streaming events, stable model slugs, `--model`, and interactive model selection; its profile should declare precisely whether a given version applies changes immediately, at the next turn, or through a resumed session. [Antigravity changelog](https://antigravity.google/changelog?plan=free)

Most importantly, a mutation receipt should report what the next stream actually confirms:

```json
{
  "requested": {
    "model_id": "gemini-3.6-flash-high"
  },
  "effective": {
    "model": {
      "id": "gemini-3.6-flash-high",
      "display_name": "Gemini 3.6 Flash (High)"
    },
    "timing": "next_turn",
    "confirmed_by_event": 184
  }
}
```

The adapter must not infer success merely because a command was accepted. An unrecognized application version or invalid stream shape should fail profile admission rather than silently falling back to transcript archaeology.

<oai-mem-citation>
<citation_entries>
MEMORY.md:66-69|note=[used current para-agent planning scope]
MEMORY.md:93-95|note=[used prior requirement to verify actual application capabilities]
</citation_entries>
<rollout_ids>
019fed26-1882-7071-8c49-a5c35accff7f
</rollout_ids>
</oai-mem-citation>

---

# yea, but we can also programmatically use `/` commands which are very similar in both . like i can `/model` in both agy and claude

Exactly. Slash commands are another native control API and should be first-class in each application adapter.

The flow can be:

```text
MCP semantic operation
        ↓
application profile validates arguments
        ↓
adapter invokes `/model <model-id>`
        ↓
live stream confirms model.id/display_name
        ↓
MCP returns confirmed receipt
```

A profile could describe the binding:

```json
{
  "operations": {
    "model.set": {
      "command": "/model",
      "arguments": {
        "model_id": { "type": "string" }
      },
      "confirmation": {
        "event": "session_state",
        "path": "model.id"
      }
    }
  }
}
```

This suggests a useful two-level MCP surface:

- Semantic conveniences such as `model.set`, `model.list`, and `session.compact`.
- A profile-validated `application.command` for less common slash commands without manufacturing a separate MCP tool for each one.

For example:

```json
{
  "session": "agy:abc123",
  "command": "model",
  "arguments": {
    "model_id": "gemini-3.6-flash-high"
  }
}
```

The profile determines whether that becomes `/model <id>`, opens and drives a picker, invokes an SDK setter, or requires next-turn application. Claude and Agy may share command names while still differing in argument syntax, timing, output, and version availability.

These invocations should be control-plane records, not communiques. `/model`, `/compact`, `/permissions`, and similar commands are directed at an application, not messages from one actor to another. A control record can retain:

```json
{
  "kind": "control",
  "application": "agy",
  "command": "model",
  "requested_by": "agent",
  "requested": { "model_id": "gemini-3.6-flash-high" },
  "confirmed": {
    "model": {
      "id": "gemini-3.6-flash-high",
      "display_name": "Gemini 3.6 Flash (High)"
    }
  }
}
```

So the commonality of `/model` is reusable, while the adapter profiles preserve each application’s exact command contract.