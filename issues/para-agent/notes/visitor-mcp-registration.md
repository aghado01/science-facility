# Registering visitor MCPs

- **Written:** 2026-08-19
- **Status:** proposal, no code. Answers the configuration-mechanics half of the visitor-MCP
  question; the conformance half is sketched in
  [grok-visitor-mcps-in-para-agent](../discussions/grok-visitor-mcps-in-para-agent.md).
- **Related:** [session-scoped-inheritance-control](session-scoped-inheritance-control.md) —
  the same field, approached from the participant side.

## The short version

Do not build a second registry. The client config snapshot already does exactly what is wanted —
declare a closed set, validate it, freeze it, hash it, resolve from it — and a visitor MCP is
another thing to declare. Adding a fourth array to the snapshot buys the tractability for free,
including one property that is easy to miss (see "What the hash buys" below).

## What already exists

`config-provider.js` loads three kinds, each against its own schema
(`DEFAULT_CLIENT_CONFIG_SCHEMA_PATHS`): integrations, host bindings, session profiles. It
canonicalises the JSON, hashes it, and deep-freezes the result.

`registry.js` takes that snapshot and resolves a registration from
`{ application, surface, mode, sessionProfile }`, after cross-checking policy keys, environment
entries, and session compatibility.

The snapshot is strict in both directions:

```js
// registry.js — assertSnapshotShape
schema_version !== 1                                  → shape_invalid
revision not /^[a-f0-9]{64}$/                         → shape_invalid
any key outside {schema_version, revision,
  integrations, host_bindings, session_profiles}      → shape_invalid
computeClientConfigSnapshotRevision(snapshot)
  !== snapshot.revision                               → revision_mismatch
```

An unknown key is rejected outright, and the revision must equal the recomputed hash of the
canonical form. Nothing can be smuggled in, and nothing can be edited without the hash changing.

## The proposal

A fourth config kind, `visitor_mcps`, with its own schema, in the same snapshot.

**Declaration** — what a visitor MCP is, per entry: id; how to launch it (command, args, env);
which of the disclosure verbs it provides (`list`, `read`, `search`, `inspect`, `status` from the
discussion fragment); and its verification block, same shape as an adapter's, because a visitor MCP
para-agent does not own has exactly the adapter version problem — pinned or not, evidenced or not.

**Selection** — a session profile names which registered visitor MCPs that session may reach. Same
two-level shape the clients already use: the registry says what exists and is permitted at all, the
session profile picks from it. A visitor MCP absent from the snapshot cannot be selected, and a
selection naming an unregistered id fails at resolve rather than at spawn.

**Reusable as-is:**

| Machinery | Why it applies unchanged |
|---|---|
| `assertConcreteHostPath(value, platform)` | a visitor MCP is a command at a concrete path |
| `assertArguments(values, allowedPlaceholders)` | argv with a closed placeholder set — same need |
| environment source/secret discipline | visitor MCPs take env; the "no literal secrets in package or session JSON" rule is the same rule |
| `assertUnique` / `assertUniqueNames` | duplicate ids and duplicate env names, same failures |
| canonicalise → hash → freeze | the whole point |

**Genuinely new, do not force into the client shape:** a client is spawned per mediated turn and
speaks a native stream an adapter parses. A visitor MCP is a long-lived stdio JSON-RPC server,
shared across turns and across participants. Different lifecycle, different failure modes,
different cleanup. The *registration* is the same problem; the *runtime* is not.

## What the hash buys

This is the part worth having.

The contract already binds each v2 conversation lane durably to the adapter, integration, session
profile, workspace, and `policy.session_sha256`, and `TranscriptStore.acceptExchange()` compares
that binding against every prior acceptance for the conversation key —
`CONVERSATION_BINDING_CONFLICT` on any difference.

Put visitor MCPs in the snapshot and they land inside that binding automatically. **A conversation
cannot silently change which MCPs its participants could reach.** Add one mid-conversation and the
next acceptance fails loudly instead of producing a transcript whose later turns had a wider tool
surface than its earlier ones — with nothing in the record saying so. That is the same defect as an
adapter citing evidence that moved: the state changes, the record does not, and nobody finds out.

No new mechanism is needed for it. It falls out of using the snapshot instead of a side channel.

## Sequencing

The registry is bounded-green but is **not yet the production authority** — substrate-migration
items 2 and 3 (inject registry + compiler into `MediatedTurnService`; strict `spawn` tagged union)
are pending, and item 5 lands the three client profiles atomically with the cutover.

So: write the schema whenever, but land `visitor_mcps` **with or after** that cutover, not before.
Landing it first means the new kind gets dragged through the migration as a fourth thing in flight,
and the snapshot shape changes twice. Adding the array also changes the strict key allowlist and
every recomputed revision, which is a one-line change but invalidates any stored snapshot — cheaper
to absorb once.

One open question that is really a client question: `spawn`'s tagged union gets a shape for
"managed `application + sessionProfile` pane". If a session's visitor MCPs are named on the session
profile, that arm already carries them and no new arm is needed. Worth confirming when item 3 is
designed, because the answer decides whether visitor MCPs are a spawn concept at all or purely a
configuration one.
