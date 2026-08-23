The current issue should be remediated by separating reusable module internals from the agent-facing custom Nushell command surface designed into the MCP. That becomes the architectural pattern for subsequent modules—not merely a one-off fix for `dataspection`.

## 1. Current remediation

Choose the façade approach:

```text
dataspection-core
    ▲          ▲
    │          │
   par       jobs
    ▲          ▲
    └────┬─────┘
         │
   dataspection
```

More precisely:

- `dataspection-core`
  - Pure, dependency-safe implementations.
  - Owns `shape`, `shape each`, `schema`, `spine`, `preview`, `page`, `meta`, and `meta stamp`.
  - Does not import `par`, `jobs`, or any higher-level custom module.

- `par`
  - Imports `shape` directly from `dataspection-core`.
  - Continues to own budgeting and `par cap`.

- `jobs`
  - Imports `shape` and `meta stamp` from `dataspection-core`.
  - Explicitly imports the `par` commands it calls.
  - Never imports the `dataspection` façade.

- `dataspection`
  - Re-exports the commands from `dataspection-core`.
  - Explicitly imports `par cap` and `jobs stash`.
  - Owns in-hand `read`, because `read` is part of the dataspection discipline presented to the agent.

The agent-facing surface remains:

```nu
use dataspection *

$x | shape
$x | preview
$x | read
```

The extraction is an implementation boundary, not a conceptual relocation of `shape` or `meta` away from dataspection.

### Static dependencies, not overlay assumptions

Every module must import the custom commands it calls within its own module scope. `config.nu` preload order composes the MCP experience; it must not be treated as dependency injection into module definitions.

Therefore remove:

- Runtime `scope commands` checks intended to compensate for missing imports.
- Fallback byte calculations in `par` and `jobs`.
- Assumptions that a command loaded into the config overlay is visible from a defining module.

Once `dataspection` statically imports `jobs stash`, “jobs missing” is no longer a normal domain condition. Failure to load that dependency is an engine/module-construction failure.

## 2. Failure semantics remain unchanged

The extraction must not introduce exception-oriented command behavior.

For exported custom Nushell commands:

- Expected operational or domain failure returns `ok: false`, `error`, optional `trace`, and provenance where applicable.
- Successful `evaluate` preserves that result in `$history`.
- Errors within a `par` operation become individual `ok: false` rows.
- The batch continues and returns successful siblings alongside failed rows.
- Throws remain for parsing, loading, unresolved definitions, or genuine engine invariants.

Private helpers may use Nu errors internally when that simplifies implementation, provided the exported command boundary catches and translates expected failures into the established result convention.

The tests have a separate concern: a suite may accumulate assertion failures as structured rows, while the external test runner still marks the suite unsuccessful. That process-level status is verification plumbing, not a change to custom command semantics.

## 3. New rollout architecture for custom modules

The circularity exposes a general distinction that should govern subsequent module work:

| Layer                | Responsibility                                         | May depend on                             |
| -------------------- | ------------------------------------------------------ | ----------------------------------------- |
| Shared cores         | Reusable transformations and low-level mechanisms      | Other lower cores only                    |
| Runtime services     | Cap, jobs registry, parallel execution                 | Shared cores                              |
| Agent-facing modules | Custom command experience, receipts, quarantine policy | Runtime services and shared cores         |
| MCP host             | Transport, journaling, identity, lifecycle             | Proper MCP protocol and opaque Nu results |

Dependency direction is downward only. An agent-facing module should never become a library dependency of a runtime service.

### A module should be split when either is true

- A lower layer needs only part of its implementation.
- A downstream wrapper needs data before the module’s terminal disclosure/quarantine policy runs.

That second condition materially changes the rollout after dataspection.

## 4. Impact on planned modules

### `xq`

`xq` has two distinct responsibilities:

1. Execute and capture an external process.
2. Apply the agent-facing return and quarantine policy.

Those should become separable. A qualified lower-level command such as:

```nu
xq capture <cmd> [...args]
```

could return the complete `{stdout, stderr, exit_code, elapsed}` capture. The ordinary `xq` command would consume that capture and apply census, cap, and quarantine.

`xq capture` is deliberately unbounded, analogous to `jobs fetch` or native `^cmd | complete`; ordinary `xq` remains the safe terminal command designed for agent use.

This avoids forcing rg to consume a finalized xq envelope after stdout has already been withheld.

### `rg`

Rg should consume the capture boundary, not the terminal `xq` command:

```text
xq capture
    ↓
rg JSON-event parser
    ↓
findings + spine
    ↓
rg-specific quarantine envelope
```

Rg also imports `spine`/`shape` from `dataspection-core`, `par cap`, and the necessary jobs storage commands explicitly.

This revises “rg is xq + JSON parsing” to mean shared execution mechanics, not chaining one terminal agent-facing command through another.

### `gh`

Gh has two legitimate possibilities:

- If it simply needs safe external execution, inject `GH_TOKEN` and invoke ordinary `xq`. Its result remains the xq envelope.
- If gh promises structured parsing of `--json` output, it must consume the capture boundary and own that parsing and return policy.

The present plan mixes these: it says gh returns through xq while also promising rg-like JSON detection that xq does not perform. For v1, I recommend keeping gh focused on identity routing and returning the ordinary xq envelope unchanged.

### `nu-skills` and `nu-modules`

These remain discovery facilities. The new core module will appear in module discovery, but documentation should distinguish:

- Agent-facing modules intended for ordinary use.
- Shared implementation modules intended primarily as dependencies.

There is no need to hide the core physically or create a second discovery protocol.

### Session host

The session-host plan remains stable. It continues to issue proper MCP `evaluate` calls containing custom Nushell commands such as:

```nu
$history.<index> | shape
```

Because the `dataspection` façade preserves the surface, the host does not need to know about `dataspection-core`.

## 5. Retrieval vocabulary

`jobs fetch` is not required to repair the cycle, so it should be treated as a related semantic decision rather than smuggled into the dependency fix.

I still recommend adopting:

- `jobs inspect` — census, no body.
- `jobs read` — disclose subject to the cap.
- `jobs fetch` — retrieve the exact stored payload.

But it should be a separate pointed change immediately after layering, before xq, rg, or gh land. This keeps the remediation reviewable while preventing the downstream briefs from proliferating `jobs read --full`.

## 6. Revised rollout sequence

1. **Layering remediation**
   - Add `dataspection-core`.
   - Convert `dataspection` to the agent-facing façade.
   - Correct static imports in `par`, `jobs`, and `dataspection`.
   - Remove duplicated byte fallbacks.
   - Add module-scope and config-loaded smoke tests.

2. **Retrieval vocabulary**
   - Decide and, preferably, land `jobs fetch`.
   - Amend vocabulary, references, tests, adapters, and existing briefs.

3. **xq capture/return split**
   - Define the reusable process-capture boundary.
   - Keep ordinary `xq` as the safe agent-facing command.

4. **Rg**
   - Consume the capture boundary.
   - Parse before applying rg-specific quarantine and spine policy.

5. **Gh**
   - Route identity.
   - Use ordinary xq unless structured parsing is explicitly retained.

6. **Session host**
   - Continues independently against the stable custom Nushell command surface.

The central architectural lesson is: **custom Nushell commands designed for agent interaction are terminal composition surfaces, not automatically reusable dependency units.** When another module needs their mechanics before disclosure policy is applied, extract a lower dependency-safe boundary and retain the original command as the agent-facing façade.
