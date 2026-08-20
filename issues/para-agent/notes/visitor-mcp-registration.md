# Registering visitor MCPs

- **Written:** 2026-08-19
- **Status:** proposal, no code. The configuration-mechanics half of the visitor-MCP question; the
  conformance half is sketched in
  [grok-visitor-mcps-in-para-agent](../discussions/grok-visitor-mcps-in-para-agent.md).
- **Related:** [session-scoped-inheritance-control](session-scoped-inheritance-control.md) — the
  same question from the participant's side.

> **Superseded first draft.** This note originally proposed adding a `visitor_mcps` array to the
> existing client config snapshot. Owner ruled two separate registries (2026-08-19). Importing a
> capability and onboarding a kind of participant are different things, and collapsing them into
> one snapshot would make the storage clear at the cost of making the concepts muddy. The
> structural parallel is real and worth exploiting — but through shared primitives, not a shared
> namespace. Rewritten accordingly.

## The dimensions this sits between

Owner's enumeration, recorded because most of it is unworked and the list is the map:

- client application boundaries
- their respective harnesses and interface semantics
- client-specific configuration and provisioning
- vendored MCPs
- role-specific configuration concepts and governance

Two of these are registries. The rest are not, and should not be pulled into one just because they
are adjacent.

## Two registries

| | Client registry | Visitor-MCP registry |
|---|---|---|
| Registers | a kind of participant para-agent can drive | a capability para-agent can make available to participants |
| Answers | "what is Grok, and how do we speak to it" | "what is nushell-mcp, and may a participant reach it" |
| Runtime | spawned per mediated turn, speaks a native stream an adapter parses | long-lived stdio JSON-RPC server, shared across turns and participants |
| Owned by para-agent | no — an external CLI | no — a sibling MCP, instrumental but not owned |
| Failure of a bad entry | a turn cannot be mediated | a tool surface is missing or wrong |
| Governance question | may this client be driven, and under what policy | may this participant reach this capability |

Separate snapshots, separate schemas, separate revisions. A visitor MCP never appears in the client
snapshot and vice versa.

## The parallel, spent correctly

The similarity is in the *mechanics*, not the subject matter. Both need: a declared closed set,
each entry schema-validated, semantic checks past what a schema can say, canonical form, a hash
over it, a freeze, and resolution from the frozen set. That is a generic capability, and it is
currently welded to the client case in `config-provider.js`.

So the parallel argues for **extracting the config-snapshot primitive**, then having two registries
use it — not for one registry with two kinds of thing in it:

| Primitive, currently client-specific | Generic form |
|---|---|
| `canonicalClientConfigJson`, `computeClientConfigSnapshotRevision`, `deepFreezeClientConfig` | canonicalise / hash / freeze any declared set |
| `assertSnapshotShape` with its hardcoded key allowlist | shape assertion parameterised by the kinds a snapshot declares |
| `assertConcreteHostPath(value, platform)` | unchanged — a visitor MCP is also a command at a concrete path |
| `assertArguments(values, allowedPlaceholders)` | unchanged — argv with a closed placeholder set |
| environment source/secret discipline | unchanged — "no literal secrets in package or session JSON" is the same rule |
| `assertUnique`, `assertUniqueNames` | unchanged |

Behaviour-preserving extraction: the client registry keeps doing exactly what it does, and the
generic layer gains a second caller. If the extraction changes any client behaviour it has gone
wrong.

## What a visitor-MCP entry declares

- **id** and how to launch it — command, args, env.
- **Which disclosure verbs it provides** — `list`, `read`, `search`, `inspect`, `status` from the
  discussion fragment. This is the conformance claim, and it belongs in the registration rather
  than in prose, so an entry that claims a verb it does not serve is a checkable error.
- **Verification** — same problem an adapter has, for the same reason: para-agent owns neither the
  binary nor its release cadence. Whatever shape the adapter evidence question settles into should
  apply here too, rather than inventing a second vocabulary for the same thing.

**Selection stays two-level**, as it already is for clients: the registry says what exists and is
permitted at all; a session profile names which of those a given session's participants may reach.
A selection naming an unregistered id fails at resolve, not at spawn.

## Binding the record

The contract binds each v2 conversation lane durably to the adapter, integration, session profile,
workspace, and `policy.session_sha256`, and `acceptExchange()` rejects any later difference with
`CONVERSATION_BINDING_CONFLICT`.

With two registries the lane wants **two revisions** — the client config snapshot's, and the
visitor-MCP snapshot's — bound separately. That is better than the merged version, not worse: the
record then says which client configuration *and* which capability set a conversation ran under,
and a change to either is attributable to the one that changed. Merged, a revision bump would only
say "something in config moved".

The property worth keeping either way: a conversation cannot silently widen the tool surface its
participants could reach. Add a visitor MCP mid-conversation and the next acceptance fails loudly,
rather than producing a transcript whose later turns had more reach than its earlier ones with
nothing in the record saying so.

## Sequencing

The client registry is bounded-green but is **not yet the production authority** —
substrate-migration items 2 and 3 (inject registry + compiler into `MediatedTurnService`; strict
`spawn` tagged union) are pending, and item 5 lands the three client profiles atomically with the
cutover.

Extracting the shared primitive touches `config-provider.js`, which the migration is about to
disturb. Doing the extraction *before* the cutover means doing it under code that is mid-move;
doing it after means one disturbance instead of two. The visitor-MCP registry itself has no reason
to precede either.

## Open

- Does a session's visitor-MCP selection live on the session profile, or on its own? The client
  answer is "session profile", but that is the client's session profile — a role-specific concept
  may not want to borrow it.
- `spawn`'s tagged union has an arm for a managed `application + sessionProfile` pane. If visitor
  MCPs are named on whatever the session-level selection turns out to be, that arm may already
  carry them, and visitor MCPs are then purely a configuration concept that never touches `spawn`.
  Worth confirming when item 3 is designed.
- Governance is unworked: who may register a visitor MCP, and is registration itself something a
  participant can request, or strictly an out-of-band act by the operator?
