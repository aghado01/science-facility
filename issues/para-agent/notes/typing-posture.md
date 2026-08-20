# Typing posture: where schemas are non-negotiable, and where types belong

- **Written:** 2026-08-20
- **Status:** hypothetical, traced. No code change proposed or made. May graduate later.
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

### 4. Where neither applies, deliberately

Native client streams. Adapters parse NDJSON emitted by Claude, Codex, Grok — external, untrusted,
versioned by someone else, and **discovered rather than declared**. The contract calls this
"privileged untrusted content" and requires it stay exact. There is no schema and there should not
be one; the adapter's mappings and conditions are the runtime discipline, and `unknown` is the
honest static type. Types stop at the parse boundary here by design, not by omission.

## Weighing it

**Cost is bounded and countable.** Six schemas would gain a companion type declaration at their
load boundary — not a parallel type system. The alternative, generating types from the schemas,
buys away that duplication at the price of a build step and a dependency, which is the thing the
probe just showed is otherwise unnecessary. Six hand-written declarations is likely the cheaper
trade.

**Value is concentrated where the code already churns.** The modules with the most hand-written
assertions are the ones the migration and client-onboarding tracks will keep touching.

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
