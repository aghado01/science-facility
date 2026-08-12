# Stop Your AI Agent Forgetting User Preferences: Key-Value Memory

[#ai](/t/ai) [#programming](/t/programming) [#tutorial](/t/tutorial) [#python](/t/python)

## [Stop AI Agents from Losing Memory (2 Part Series)](/elizabethfuentes12/series/42345) [1 AI Agent Memory Types: Your Agent Forgets Everything. Fix It](/aws/ai-agent-memory-types-your-agent-forgets-everything-fix-it-pcc "Published Jul 22") [2 Stop Your AI Agent Forgetting User Preferences: Key-Value Memory](/aws/stop-your-ai-agent-forgetting-user-preferences-key-value-memory-a13 "Published Aug 4")

Here's a test most AI agents fail. A brand-new user searches flights, books one in business class, and asks: _"what do you recommend based on what you know about me?"_ The agent answers beautifully: business class, non-stop, exactly their taste. Then the process restarts. Same user, same question, and now the answer is generic: the cheapest economy fare. Everything the agent "knew" is gone.

[![Cartoon: an AI assistant offers a personalized business-class ticket, then after one restart offers the same user the cheapest economy fare — the transcript is not memory](https://media2.dev.to/dynamic/image/width=800%2Cheight=%2Cfit=scale-down%2Cgravity=auto%2Cformat=auto/https%3A%2F%2Fdev-to-uploads.s3.us-east-2.amazonaws.com%2Fuploads%2Farticles%2F980b7u6sk36i84rliyu2.png)](https://media2.dev.to/dynamic/image/width=800%2Cheight=%2Cfit=scale-down%2Cgravity=auto%2Cformat=auto/https%3A%2F%2Fdev-to-uploads.s3.us-east-2.amazonaws.com%2Fuploads%2Farticles%2F980b7u6sk36i84rliyu2.png)

**Persistent memory for an AI agent means storing structured facts outside the conversation, in a store that outlives the process.** This post builds that for the most common case, user preferences, with the smallest memory that works: a key-value store, measured climbing a durability ladder from process state to local disk to Amazon S3. Everything below runs from the [companion repo](https://github.com/elizabethfuentes12/stop-ai-agents-losing-memory-sample-for-aws) with live flight data, so the numbers come from real runs, not slideware.

_(This is post 1 of a series; the [intro post](https://dev.to/aws/ai-agent-memory-types-your-agent-forgets-everything-fix-it-pcc) maps all the memory types. The code uses [Strands Agents](https://strandsagents.com/?trk=87c4c426-cddf-4799-a299-273337552ad8&sc_channel=el), an open source SDK; the pattern carries over to any agent framework.)_

---

## [#isnt-the-conversation-history-already-memory](#isnt-the-conversation-history-already-memory) Isn't the conversation history already memory?

Within a session, yes, and that's exactly what fools people. The common claim is "stateless agents forget between turns." That claim is false, and you can prove it in four lines. Agent frameworks keep the conversation history between calls on the same agent instance (in Strands it's `agent.messages`) and send it to the model on every turn. So an agent with zero memory tooling still "remembers":

```
User: Book the cheapest business option.
Agent: Your flight from JFK to Paris CDG has been booked... ✅

User (2 turns later): ...what do you recommend based on what you know about me?
Agent: here are some business class options... ✅  ← personalized!

agent.state.get("user_preferences")  → None      ← nothing was learned
len(agent.messages)                  → 12        ← the booking lives ONLY here
```

That's a real run. The agent personalized turn 3 because "business class" was still sitting in the transcript. Don't let that fool you into thinking it learned something. Three problems hide under that lucky answer:

1. **Nothing structured exists.** There is no profile to query, rank offers by, display to the user, or persist. The knowledge is prose inside a transcript.
2. **The transcript gets trimmed.** Long sessions need a sliding window or summarization, and the booking scrolls out with the old messages.
3. **The transcript dies with the process.** In production, every new request may be a new process. Restart the agent and ask the same question:

```
[after restart] User: ...what do you recommend based on what you know about me?
[after restart] Agent: I recommend the Iberia flight for $366.85...  ← cheapest economy. Generic.
```

[![Why AI agents forget after a restart: within a session the transcript carries the preference, after a restart only agent.state with a session manager survives](https://media2.dev.to/dynamic/image/width=800%2Cheight=%2Cfit=scale-down%2Cgravity=auto%2Cformat=auto/https%3A%2F%2Fdev-to-uploads.s3.us-east-2.amazonaws.com%2Fuploads%2Farticles%2Flsnhs7v98o87o9nhps85.png)](https://media2.dev.to/dynamic/image/width=800%2Cheight=%2Cfit=scale-down%2Cgravity=auto%2Cformat=auto/https%3A%2F%2Fdev-to-uploads.s3.us-east-2.amazonaws.com%2Fuploads%2Farticles%2Flsnhs7v98o87o9nhps85.png)

The research literature calls this cross-session loss **memory decay** ([MemoryOS](https://arxiv.org/abs/2506.06326), Kang et al. 2025). The model isn't broken; models are stateless by design. Memory belongs to the harness you build around them.

So the honest framing is this: **the transcript is a context mechanism, not a memory system.** A memory system needs structure (facts you can query) and durability (facts that survive the process). Key-value state gives you both.

---

## [#what-does-the-experiment-measure](#what-does-the-experiment-measure) What does the experiment measure?

One variable. Same model, same three-turn conversation, same live flight data (the [Duffel](https://duffel.com) sandbox: real offers, real carriers). The only thing that changes between tests is where memory lives:

| Test | Memory wiring          | Structured profile | Survives restart |
| ---- | ---------------------- | ------------------ | ---------------- |
| 1    | none (transcript only) | No                 | No               |
| 2    | `agent.state`          | Yes                | No               |
| 3    | + `FileSessionManager` | Yes                | Yes (local disk) |
| 4    | + `S3SessionManager`   | Yes                | Yes (Amazon S3)  |

[![The durability ladder for AI agent key-value memory: transcript only dies on restart, agent.state adds a structured profile, FileSessionManager persists it to disk, S3SessionManager persists it to the cloud](https://media2.dev.to/dynamic/image/width=800%2Cheight=%2Cfit=scale-down%2Cgravity=auto%2Cformat=auto/https%3A%2F%2Fdev-to-uploads.s3.us-east-2.amazonaws.com%2Fuploads%2Farticles%2F6qs6lg0ceqa6pe985tyl.png)](https://media2.dev.to/dynamic/image/width=800%2Cheight=%2Cfit=scale-down%2Cgravity=auto%2Cformat=auto/https%3A%2F%2Fdev-to-uploads.s3.us-east-2.amazonaws.com%2Fuploads%2Farticles%2F6qs6lg0ceqa6pe985tyl.png)

The conversation, verbatim in every test:

> **Turn 1:** "Find me flights from JFK to Paris CDG on 2026-09-15, business class."
> **Turn 2:** "Book the cheapest business option." ← _the memory moment_
> **Turn 3:** "Now I need Paris CDG to Tokyo Haneda — what do you recommend based on what you know about me?"

---

## [#how-does-the-agent-learn-preferences-without-a-form](#how-does-the-agent-learn-preferences-without-a-form) How does the agent learn preferences without a form?

From actions. Nobody fills in a "preferences" form; the user _books a flight_, and that action reveals their cabin, their tolerance for stops, their price band, their carrier. The stateful `book_flight` tool captures all of it as a side effect of doing its job:

```
from strands import Agent, tool, ToolContext

@tool(context=True)
def book_flight(offer_id: str, tool_context: ToolContext) -> str:
    """Confirm a booking AND learn the user's preferences from their choice."""
    offer = flights_api.get_offer(offer_id)          # the REAL chosen offer

    # First booking ever? state returns None → start an empty profile.
    prefs = tool_context.agent.state.get("user_preferences") or {}

    # The choice reveals the preferences. No form involved:
    prefs["preferred_cabin"] = offer["cabin"]                      # "business"
    prefs["prefers_nonstop"] = all(s["stops"] == 0 for s in offer["slices"])
    prefs["typical_price"]   = {"min": ..., "max": ...}            # price band

    tool_context.agent.state.set("user_preferences", prefs)
    return json.dumps({"status": "CONFIRMED", "preferences_updated": prefs})
```

Two Strands pieces make this work:

- **`@tool(context=True)`** injects a `ToolContext`, which carries a reference to the running agent.
- **`tool_context.agent.state`** is the key-value store: "key-value storage for stateful information that exists **outside of the conversation context**" ([Strands agent state docs](https://strandsagents.com/docs/user-guide/concepts/agents/state/?trk=87c4c426-cddf-4799-a299-273337552ad8&sc_channel=el)). It is _not_ sent to the model; tools read and write it directly.

And the read path: the next `search_flights` call loads the profile and **ranks real offers with deterministic code**, instead of hoping the model re-reads the transcript:

```
prefs = tool_context.agent.state.get("user_preferences") or {}
offers = flights_api.search_offers(origin, destination, date,
                                   prefs.get("preferred_cabin") or cabin_class)
if prefs:
    offers.sort(key=score_by_profile, reverse=True)   # nonstop +10, in budget +5...
```

The baseline (Test 1) uses the _same tools with the state lines removed_: plain `@tool`, no `ToolContext`. Identical business logic; no way to remember. That's the whole difference between the failing agent and the learning one.

After Test 2, this profile exists, and it's inspectable, queryable, and persistable:

```
{
  "preferred_cabin": "business",
  "prefers_nonstop": true,
  "carriers_flown": ["British Airways"],
  "typical_price": {"min": 1382.22, "max": 1382.22}
}
```

[![An AI agent learning user preferences from a booking action instead of a form: the chosen flight offer flows through the book_flight tool into a structured user_preferences profile in agent.state](https://media2.dev.to/dynamic/image/width=800%2Cheight=%2Cfit=scale-down%2Cgravity=auto%2Cformat=auto/https%3A%2F%2Fdev-to-uploads.s3.us-east-2.amazonaws.com%2Fuploads%2Farticles%2F692l1228ww04bl2gdf23.png)](https://media2.dev.to/dynamic/image/width=800%2Cheight=%2Cfit=scale-down%2Cgravity=auto%2Cformat=auto/https%3A%2F%2Fdev-to-uploads.s3.us-east-2.amazonaws.com%2Fuploads%2Farticles%2F692l1228ww04bl2gdf23.png)

---

## [#how-does-persistent-memory-survive-restarts-the-durability-ladder](#how-does-persistent-memory-survive-restarts-the-durability-ladder) How does persistent memory survive restarts? The durability ladder

`agent.state` fixed structure, but it lives in the Python process. Restart and it's gone, exactly like the transcript. Durability is a separate decision, and in Strands it's one constructor argument.

### [#rung-2-%E2%86%92-3-survive-a-restart-local-disk](#rung-2-%E2%86%92-3-survive-a-restart-local-disk) Rung 2 → 3: survive a restart (local disk)

```
from strands.session import FileSessionManager

agent = Agent(
    model=MODEL,
    tools=[search_flights, book_flight],
    session_manager=FileSessionManager(
        session_id="traveler-demo",     # same id = same user
        storage_dir="./sessions",
    ),
)
```

The demo simulates the restart honestly: agent A books (building the profile), then a **brand-new agent instance** with the same `session_id` is created. Measured output:

```
Session A learned:  {"preferred_cabin": "business", "prefers_nonstop": true, ...}
Session B restored: {"preferred_cabin": "business", "prefers_nonstop": true, ...}
State survived restart: True
```

Agent B answers turn 3 personalized, _without the conversation that taught it_. The knowledge moved from the transcript to the store.

### [#rung-3-%E2%86%92-4-survive-in-the-cloud-amazon-s3](#rung-3-%E2%86%92-4-survive-in-the-cloud-amazon-s3) Rung 3 → 4: survive in the cloud (Amazon S3)

```
from strands.session import S3SessionManager

agent = Agent(
    model=MODEL,
    tools=[search_flights, book_flight],
    session_manager=S3SessionManager(
        session_id="traveler-demo",
        bucket="your-sessions-bucket",   # plain JSON objects — no vectors
        prefix="kv-memory-demo",
    ),
)
```

Same interface, same test, same `True`, except now the session is plain JSON objects in a bucket. Why this is the production rung: **nothing to provision or mount** (a durable filesystem on Lambda or Fargate means wiring up EFS: VPC, mount targets, security groups), and **any compute instance can restore the session**. The state stops being tied to one machine.

Note what this is _not_: no embeddings, no vector database, no similarity search. Regular S3. A user profile is a fact you know the name of (`user_preferences`), and key lookup is exact, instant, and free of embedding costs.

---

## [#what-do-the-measured-results-show](#what-do-the-measured-results-show) What do the measured results show?

From the repo's four-test run (live Duffel + Open-Meteo calls):

| Test                                  | Memory wiring         | Learned prefs | Survived restart |
| ------------------------------------- | --------------------- | ------------- | ---------------- |
| 1 — no memory tools (transcript only) | `agent.messages` only | False         | **False**        |
| 2 — `agent.state`                     | key-value in process  | True          | —                |
| 3 — + `FileSessionManager`            | key-value on disk     | True          | **True**         |
| 4 — + `S3SessionManager`              | key-value in S3       | True          | **True**         |

The line that matters is Test 1's restart: the same model that personalized perfectly two turns earlier recommended a $366 economy fare to the same user after one process restart. Memory is wiring, not model.

---

## [#when-is-keyvalue-memory-the-wrong-choice](#when-is-keyvalue-memory-the-wrong-choice) When is key-value memory the wrong choice?

When the question doesn't name a key. Key-value memory answers **questions that map to a known name**. Store `dietary_notes: "vegetarian, severe shellfish allergy"` and ask _"what are my dietary notes?"_: found. Ask _"what should I avoid eating at dinner?"_: no key matches, and the answer sits in the store unreachable. That failure needs retrieval **by meaning** (vector memory, the next post in this series), and questions that hop across relationships need a graph. The [intro post](https://dev.to/aws/ai-agent-memory-types-your-agent-forgets-everything-fix-it-pcc) maps all four types.

Also outside this pattern's scope: deciding _what's worth storing_ (selective memory), keeping poisoned content _out_ of the store (hygiene), and remembering _why_ the agent decided (decision traces). Later posts cover each, in the same measured format.

**Start here anyway.** Profile, preferences, settings, counters: facts with obvious names cover more of production personalization than people expect, with zero retrieval infrastructure.

---

## [#how-do-you-ask-an-ai-coding-assistant-to-build-this](#how-do-you-ask-an-ai-coding-assistant-to-build-this) How do you ask an AI coding assistant to build this?

Most agent code today is written _with_ an AI assistant, and the quality of the memory you get depends on the design decisions you name in the prompt. If you don't name them, the assistant defaults to the transcript, and you ship the Test 1 agent. These five instructions encode everything this post measured; paste them into your assistant and adapt the domain:

1. **"Store user facts in the agent's key-value state, not in the conversation."** Name the store (in Strands, `agent.state`); otherwise the assistant will 'remember' by re-reading the transcript.
2. **"Learn preferences from user actions inside the tools."** The booking/purchase/rejection tool writes what the choice reveals. If you don't say this, you get a "save preference" tool the model may never call.
3. **"Read the profile back in code, not in the prompt."** Search and recommendation tools load the stored profile and rank deterministically, instead of hoping the model notices.
4. **"Persist state with a session manager keyed by user id."** This is the one line that survives the restart. Ask for local files in development and object storage (Amazon S3) in production.
5. **"Prove it: build a test where a brand-new agent instance with the same session id still knows the user."** If the assistant can't show that test passing, the memory isn't persistent, whatever the code claims.

That's the whole technique. The demo below is those five instructions, implemented and measured, so you can compare what your assistant produces against a working reference.

---

## [#how-do-you-run-the-demo](#how-do-you-run-the-demo) How do you run the demo?

```
git clone https://github.com/elizabethfuentes12/stop-ai-agents-losing-memory-sample-for-aws
cd stop-ai-agents-losing-memory-sample-for-aws/01-key-value-memory-demo
uv venv && uv pip install -r requirements.txt
uv run python test_key_value_memory.py
```

Needs `OPENAI_API_KEY` (or swap one line for Amazon Bedrock; the README shows how) and a free [Duffel sandbox token](https://app.duffel.com) for live flight data. Test 4 additionally needs AWS credentials and a bucket name; the demo creates the bucket if it doesn't exist and skips gracefully if not configured. There's an interactive notebook version with the same tests.

---

## [#faq](#faq) FAQ

**How do I give an AI agent persistent memory?**
Store structured facts outside the conversation (a key-value store your tools write), then persist that store beyond the process: session files on disk for development, objects in cloud storage such as Amazon S3 for production. The conversation transcript alone is not persistent; it dies with the process.

**Why does my AI agent forget everything after a restart?**
Because the only place the information existed was the conversation history, which lives in process memory. Models are stateless; frameworks keep the transcript between calls but not between processes. Anything worth keeping must be written to an external store during the conversation.

**Why not keep the whole conversation in the context window?**
Within one session it behaves like memory, since the model re-reads it every turn. But it's unstructured (you can't query or rank by it), it gets trimmed as the conversation grows, you pay to re-process the same tokens every turn, and it's gone on restart. Treat it as a context mechanism, not a memory system.

**Do I need a vector database to remember user preferences?**
No. Preferences are facts with known names, and key lookup is exact and instant, with no embedding costs. Vector databases earn their keep when questions stop matching keys ("what should I avoid eating?"), which is the next post in this series.

**How do AI agents learn user preferences without asking?**
From actions. A booking, a purchase, or a rejection carries more reliable signal than a form. Design tools so that doing their job also writes what the action reveals (cabin, price band, carrier) into the agent's state.

**Where is the memory actually stored?**
In this pattern, three places depending on the durability rung: in-process state (a Python dict, gone on restart), JSON session files on local disk, or plain JSON objects in an Amazon S3 bucket. No vectors and no embeddings at any rung; a profile is a named fact, not a similarity search.
