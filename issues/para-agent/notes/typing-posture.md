# Typing posture: where schemas are non-negotiable, and where types belong

- **Written:** 2026-08-20
- **Status:** direction set, not ruled. Owner's leaning as of 2026-08-20: **build the client
  integration layer in TypeScript, then use it as the model for renovating the untyped modules.**
  No code change made. Worth a decision entry once firm.
- **Purpose:** a map of para-agent's shape-handling surfaces sorted into what must stay JSON
  Schema, what is a bare object that should be typed, and where a reader would expect types if
  TypeScript is adopted — so the justification and the cost are weighable per surface rather than
  as one all-or-nothing decision.

## What the probe settled

Run on Node `v26.2.0`, 2026-08-20:

| Probe | Result |
|---|---|
| `node main.ts` | runs — no build step, no tsconfig, no dependency |
| `.ts` importing `./shape.ts` | works |
| `node --test --test-concurrency=1 t.test.ts` | ✔ 1 pass |
| `enum` (non-erasable syntax) | works — full transform, not just stripping |
| `.js` importing `./typed.ts` | works — so existing modules can consume new TS ones |
| `.ts` importing `./plain.js` | works — so a TS module can sit among JS ones |

So the usual objection — TypeScript means a build pipeline — does not apply here. `.mcp.json` could
keep launching `node src/index.ts`, and **the test harness survives untouched** because it is still
`node --test` with para-agent's own reporter. P4's runner contract does not move.

**The catch:** Node *strips* types, it does not *check* them. `node file.ts` runs code with type
errors. The benefit requires `tsc --noEmit` in the loop — a dev dependency and a check step, whose
natural home is a suite in `tests/test-manifest.json` so it is bounded like everything else. Without
that, annotations are documentation that can lie, which is worse than none. **Adopting TypeScript
without the typecheck suite is not a smaller step; it is a worse one.**

## The four surfaces

### 1. JSON Schema, non-negotiable

Six schemas exist and each is load-bearing for a reason that a type cannot satisfy.

| Schema | Why it cannot become a type |
|---|---|
| `transcript-exchange`, `transcript-header` | P3 rules JSON Schema 2020-12 as the **persistence dialect**. This is a durable format read by other processes — `quarantine-admin` already does, other languages might. A language-independent contract is the entire point |
| `client-adapter`, `client-integration-profile`, `client-host-binding`, `client-session-profile` | P11's thesis is that a fifth client is onboarded "through profiles and codecs alone". That means these are **authored by someone outside this codebase**, and a published schema gives them validation and editor completion without running para-agent |

The test is not "is this data structured?" but **"does something outside this process need to
understand the shape without executing our code?"** Yes for a durable format, yes for an artifact a
third party authors. Those two answers are the whole of bucket 1, and TypeScript changes nothing
about them.

### 2. Bare objects that should be typed and are not

Everything internal. No schema, and the shape lives in hand-written assertions — roughly 250 of them
across 21 modules:

```
environment.js    27     assembler.js       24     invocation.js      24
quarantine-admin  20     mediated-turn.js   17     transcript.js      16
raw-trace.js      16     adapters.js        16     quarantine-recon   14
config-provider   12     schema-validation   9     workspace.js        8
```

These are types written in prose. `assertSnapshotShape` enumerates five permitted keys and a hash
format; `assertEnvironmentEntries` checks names, tombstones and collisions; `assertArguments`
validates argv against a closed placeholder set. Each is a shape declaration that the compiler
cannot see, tested only where a test happens to exercise it.

This is where types pay, and it is worth naming *what* they would have caught in practice rather
than in principle:

- **`evidence[].reference` polymorphic under `kind`** — a discriminated union. The classification
  table in `adapter-conformance.test.js` becomes exhaustiveness checking: add a `kind` to the enum
  and every consumer fails to compile, instead of needing a test written to notice.
- **`verification.status` carrying two facts** (P22) — splitting it is a type change the compiler
  propagates to every site, rather than a search-and-hope.
- **The path moves of 2026-08-19** — missed call sites would have surfaced immediately instead of as
  a red suite or, worse, a dangling string nothing resolves.

Note the pattern: the failures this project actually hits are shape and variant errors, which is
precisely the class types eliminate.

### 3. Where types would be expected later

- **New modules.** A reader arriving at a mixed tree will expect the new file to be typed. Mixed
  `.ts`/`.js` is fine — Node does not care — so the boundary can be chronological rather than
  architectural.
- **The boundary casts.** Twenty `JSON.parse` sites across ten modules. Each is a point where
  `unknown` enters and a validator already runs. Typing the return once — `loadAdapterProfile(raw:
  unknown): AdapterProfile` — types everything downstream for free. This is the .NET DTO pattern
  exactly: a validating deserializer at the edge, typed objects inside.
- **Anything replacing a hand-written assertion.** If an assertion is deleted because a type now
  covers it, that is the win. If both persist, the shape is declared twice and will drift — the
  same one-fact-two-places problem P21 and P22 already describe.

**Precedent already in the tree:** `src/index.js` imports `zod` and declares 58 shapes for the MCP
tool inputs. That is already one-declaration-serving-both-roles — runtime validation plus a static
type by inference. Under TypeScript those 58 become typed for free, with nothing to write.

### 4. The door — the highest-value type in the system

> **Corrected.** This section first read "where neither applies, deliberately", on the grounds that
> native streams are undeclarable so types stop at the parse boundary. That is backwards. The
> stream is undeclarable; **the admission of that stream into the client-agnostic abstraction is
> not**, and that admission is the single most valuable thing to type.

Three layers, and only the first is out of reach:

| Layer | Static type | Why |
|---|---|---|
| Inbound native stream | `unknown` | NDJSON from Claude, Codex, Grok — external, versioned by someone else, discovered rather than declared. The contract calls it privileged untrusted content and requires it stay exact |
| **The door** — adapter mapping | **`(unknown) => NormalizedRecord`** | Entirely para-agent's own. This signature *is* the definition of client-agnostic |
| Everything downstream | fully typed | The abstraction exists precisely to absorb the variance, so past the door there is no variance left to absorb |

**The vocabulary is already declared**, as enums in `client-adapter.schema.json` constraining what an
adapter may map onto:

```
record kinds       prompt_echo | thinking | tool_call | tool_result | response
terminal outcomes  completed | failed | interrupted | timeout
```

What is missing is the in-memory shape those map *into* — the record flowing from adapter through
`ExchangeAssembler` to the transcript store, carried today by 24 hand-written assertions in
`assembler.js`. That is a discriminated union on five members, and the terminal outcome is a union
of four. Both are small, closed, and entirely under this project's control.

**Why this one matters more than the rest.** P11 rules that onboarding a fifth client through
profiles and codecs alone — with zero changes to generic services — *is* the proof the substrate
works. Type the door and that stops being a claim demonstrated by test and becomes one enforced by
construction: a new adapter either produces the union or it does not compile. An adapter that
cannot populate a normalized record is exactly the failure P11 cares about, and it would surface at
authoring time rather than during a live pilot.

The same holds for the reverse direction. Adding a sixth record kind currently means finding every
consumer; with the union it means fixing every compile error, and the compiler's list is complete
where a grep is not.

Types do not stop at the parse boundary. They **start** there — that is what a boundary is for.

## Weighing it

**Cost is bounded and countable.** Six schemas would gain a companion type declaration at their
load boundary — not a parallel type system. The alternative, generating types from the schemas,
buys away that duplication at the price of a build step and a dependency, which is the thing the
probe just showed is otherwise unnecessary. Six hand-written declarations is likely the cheaper
trade.

**Value is concentrated where the code already churns.** The modules with the most hand-written
assertions are the ones the migration and client-onboarding tracks will keep touching.

**And it is concentrated hardest at the door.** If only one thing gets typed, it should be the
normalized record and terminal outcome — five members and four, closed, fully owned, sitting exactly
where P11's extensibility proof is made. That is the smallest declaration with the largest reach,
and unlike the rest it improves a *ruled* claim rather than only the code.

**The proportionate move is not a conversion.** para-agent is 32 files of working, contract-driven
code with 223 tests and runtime validation already carrying the load. Retrofitting types buys less
here than on greenfield like mdnav_v2. Adopt for new modules, convert opportunistically when already
editing a file, and **add the typecheck suite first** so the checking is real from day one.

## The rhyme with nushell

Adopting nushell replaced text streams with structured data that can be inspected and filtered
without re-parsing. Adopting types replaces conventional object shapes with declared ones that can
be checked without re-reading the callee. Same instinct applied one layer up: make the structure a
first-class fact rather than something each reader reconstructs. The discipline is the point in both
cases, and in both cases the payoff arrives when someone else — or a later you — has to reason about
a shape they did not write.
